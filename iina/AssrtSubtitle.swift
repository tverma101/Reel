//
//  AssrtSubtitle.swift
//  iina
//
//  Created by Collider LI on 26/2/2018.
//  Copyright © 2018 lhc. All rights reserved.
//

import Foundation
import PromiseKit

class Assrt {
  class Subtitle: OnlineSubtitle {
    /// Stand-in used when the provider returns a subtitle with no name.
    static let untitledPlaceholder = "[No title]"

    struct File {
      var url: URL
      var filename: String
    }

    var id: Int
    var nativeName: String
    var uploadTime: String
    var subType: String

    var subLang: String?
    var title: String?
    var filename: String?
    var size: String?
    var url: URL?
    var fileList: [File]?
    private let downloadCache = BuiltinSubtitleCache(provider: "assrt")

    init(index: Int, id: Int, nativeName: String, uploadTime: String, subType: String?, subLang: String?) {
      self.id = id
      self.nativeName = nativeName
      if self.nativeName.isEmpty {
        self.nativeName = Self.untitledPlaceholder
      }
      self.uploadTime = uploadTime
      if let subType = subType {
        self.subType = subType
      } else {
        self.subType = "Unknown"
      }
      self.subLang = subLang
      super.init(index: index)
    }

    /// assrt.net names each subtitle after the release it was made for.
    ///
    /// The placeholder `init` substitutes for a missing name is not a real release name, so it is
    /// reported as unknown rather than being matched against.
    override var releaseName: String? {
      nativeName == Self.untitledPlaceholder ? nil : nativeName
    }

    override func download() -> Promise<[URL]> {
      download(cancellation: SubtitleAudioMatcher.Cancellation())
    }

    override func download(cancellation: SubtitleAudioMatcher.Cancellation) -> Promise<[URL]> {
      cancellation.onCancel { [weak self] in self?.discardCachedDownload() }
      guard !cancellation.isCancelled else {
        return Promise(error: OnlineSubtitle.CommonError.dismissed)
      }
      if let fileList = fileList {
        // download from file list
        var fileGenerator = fileList.makeIterator()
        let generator = AnyIterator<Promise<URL>> {
          guard let file = fileGenerator.next() else {
            return nil
          }
          guard !cancellation.isCancelled else { return Promise(error: CancellationError()) }
          return self.downloadFile(file.url, fileName: file.filename, cancellation: cancellation)
        }

        return when(fulfilled: generator, concurrently: 2).recover { error -> Promise<[URL]> in
          self.discardCachedDownload()
          if cancellation.isCancelled { throw OnlineSubtitle.CommonError.dismissed }
          throw error
        }
      } else if let url = url, let filename = filename {
        return downloadFile(url, fileName: filename, cancellation: cancellation)
          .map { [$0] }
          .recover { error -> Promise<[URL]> in
            self.discardCachedDownload()
            if cancellation.isCancelled { throw OnlineSubtitle.CommonError.dismissed }
            throw error
          }
      } else {
        return Promise(error: OnlineSubtitle.CommonError.networkError(nil))
      }
    }

    private func downloadFile(_ remoteURL: URL, fileName: String,
                              cancellation: SubtitleAudioMatcher.Cancellation) -> Promise<URL> {
      guard !cancellation.isCancelled else { return Promise(error: CancellationError()) }
      guard BuiltinSubtitleProviderURLPolicy.allowsAssrtDownload(remoteURL) else {
        return Promise(error: OnlineSubtitle.CommonError.networkError(nil))
      }
      let request = URLRequest(url: remoteURL)
      return Promise { resolver in
        let transfer = BuiltinSubtitleHTTPTransfer(request: request,
                                                  maximumBytes: BuiltinSubtitleResponseLimit.subtitleBytes,
                                                  cancellation: cancellation,
                                                  allowsURL: { BuiltinSubtitleProviderURLPolicy.allowsAssrtDownload($0) }) { result in
          guard !cancellation.isCancelled else {
            resolver.reject(OnlineSubtitle.CommonError.dismissed)
            return
          }
          switch result {
          case .success(let (data, response)) where (200..<300).contains(response.statusCode):
            do {
              resolver.fulfill(try self.downloadCache.store(data,
                                                            suggestedFileName: "[\(self.index)]\(fileName)",
                                                            cancellation: cancellation))
            } catch {
              resolver.reject(cancellation.isCancelled ? OnlineSubtitle.CommonError.dismissed :
                                OnlineSubtitle.CommonError.fsError)
            }
          case .success(let (_, response)):
            resolver.reject(OnlineSubtitle.CommonError.networkError(
              NSError(domain: NSURLErrorDomain, code: response.statusCode)))
          case .failure(let error):
            resolver.reject(OnlineSubtitle.CommonError.networkError(error))
          }
        }
        transfer.start()
      }
    }

    override func discardCachedDownload() {
      downloadCache.discard()
    }

    override func getDescription() -> (name: String, left: String, right: String) {
      (
        nativeName,
        subType + " " + (subLang ?? ""),
        uploadTime
      )
    }
  }

  enum Error: Int, Swift.Error {
    case noSuchUser = 1
    case queryTooShort = 101
    case missingArg = 20000
    case invalidToken = 20001
    case endPointNotFound = 20400
    case subNotFound = 20900
    case serverError = 30000
    case databaseError = 30001
    case searchEngineError = 30002
    case tempUnavailable = 30300
    case exceedLimit = 30900

    case userCanceled = 80000
    // lower level error
    case wrongResponseFormat = 90000
    case networkError = 90001
  }

  class Fetcher: OnlineSubtitle.DefaultFetcher, OnlineSubtitleFetcher {
    typealias Subtitle = Assrt.Subtitle

    private let searchApi = "https://api.assrt.net/v1/sub/search"
    private let detailApi = "https://api.assrt.net/v1/sub/detail"

    var token: String
    var usesUserToken = false

    private let subChooseViewController = SubChooseViewController()

    required init() {
      let userToken = Preference.string(for: .assrtToken)
      if let token = userToken, token.count == 32 {
        self.token = token
        usesUserToken = true
      } else {
        self.token = "5IzWrb2J099vmA96ECQXwdRSe9xdoBUv"
      }
    }

    func fetch(from url: URL, withProviderID id: String, playerCore player: PlayerCore) -> Promise<[Subtitle]> {
      fetch(from: url, withProviderID: id, playerCore: player,
            cancellation: SubtitleAudioMatcher.Cancellation())
    }

    func fetch(from url: URL, withProviderID id: String, playerCore player: PlayerCore,
               cancellation: SubtitleAudioMatcher.Cancellation) -> Promise<[Subtitle]> {
      guard !cancellation.isCancelled else {
        return Promise(error: OnlineSubtitle.CommonError.dismissed)
      }
      let mediaName = url.deletingPathExtension().lastPathComponent
      return firstly { () -> Promise<[Subtitle]> in
        guard !cancellation.isCancelled else { throw OnlineSubtitle.CommonError.dismissed }
        if !self.checkToken() {
          throw OnlineSubtitle.CommonError.canceled
        }
        return self.search(mediaName, cancellation: cancellation)
      }.then { subs in
        guard !cancellation.isCancelled else { throw OnlineSubtitle.CommonError.dismissed }
        return self.showSubSelectWindow(with: subs, mediaName: mediaName, expectedURL: url, player: player)
      }.then { selected -> Promise<[Subtitle]> in
        guard !cancellation.isCancelled else { throw OnlineSubtitle.CommonError.dismissed }
        let searchID = player.onlineSubtitleSearchID
        let restoreCancellation = {
          guard player.onlineSubtitleSearchID == searchID else {
            cancellation.cancel()
            return
          }
          player.cancelOnlineSubtitleSearch = { cancellation.cancel() }
        }
        if Thread.isMainThread {
          restoreCancellation()
        } else {
          DispatchQueue.main.sync(execute: restoreCancellation)
        }
        guard !cancellation.isCancelled else { throw OnlineSubtitle.CommonError.dismissed }
        return self.loadDetails(selected, at: 0, cancellation: cancellation)
      }.recover { error -> Promise<[Subtitle]> in
        if cancellation.isCancelled { throw OnlineSubtitle.CommonError.dismissed }
        throw error
      }
    }

    func checkToken() -> Bool {
      if usesUserToken {
        return true
      }
      // show alert for unregistered users
      let alert = NSAlert()
      alert.messageText = NSLocalizedString("alert.title_warning", comment: "Warning")
      alert.informativeText = String(format: NSLocalizedString("alert.assrt_register", comment: "alert.assrt_register"))
      alert.alertStyle = .warning
      alert.addButton(withTitle: NSLocalizedString("alert.assrt_register.register", comment: "alert.assrt_register.register"))
      alert.addButton(withTitle: NSLocalizedString("alert.assrt_register.try", comment: "alert.assrt_register.try"))
      let result = alert.runModal()
      if result == .alertFirstButtonReturn {
        // if user chose register
        NSWorkspace.shared.open(URL(string: AppData.assrtRegisterLink)!)
        var newToken = ""
        if Utility.quickPromptPanel("assrt_token_prompt", callback: { newToken = $0 }) {
          if newToken.count == 32 {
            Preference.set(newToken, for: .assrtToken)
            self.token = newToken
            return true
          } else {
            Utility.showAlert("assrt_token_invalid")
          }
        }
        return false
      }
      return true
    }

    func search(_ query: String) -> Promise<[Subtitle]> {
      search(query, cancellation: SubtitleAudioMatcher.Cancellation())
    }

    func search(_ query: String,
                cancellation: SubtitleAudioMatcher.Cancellation) -> Promise<[Subtitle]> {
      guard !cancellation.isCancelled else { return Promise(error: CancellationError()) }
      var components = URLComponents(string: searchApi)!
      components.queryItems = [URLQueryItem(name: "q", value: query)]
      var request = URLRequest(url: components.url!)
      request.httpMethod = "POST"
      request.timeoutInterval = 20
      header.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
      return Promise { resolver in
        let transfer = BuiltinSubtitleHTTPTransfer(request: request,
                                                  maximumBytes: BuiltinSubtitleResponseLimit.searchBytes,
                                                  cancellation: cancellation,
                                                  allowsURL: { BuiltinSubtitleProviderURLPolicy.allowsAssrtAPI($0) }) { result in
          guard !cancellation.isCancelled else {
            resolver.reject(OnlineSubtitle.CommonError.dismissed)
            return
          }
          guard case .success(let (data, response)) = result,
                (200..<300).contains(response.statusCode),
                let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            resolver.reject(Error.networkError)
            return
          }
          guard let status = json["status"] as? Int else {
            resolver.reject(Error.wrongResponseFormat)
            return
          }
          if let error = Error(rawValue: status) {
            resolver.reject(error)
            return
          }
          // handle result
          guard let subDict = json["sub"] as? [String: Any] else {
            resolver.reject(Error.wrongResponseFormat)
            return
          }
          // assrt will return `sub: {}` when no result
          if let _ = subDict["subs"] as? [String: Any] {
            resolver.fulfill([])
            return
          }
          guard let subArray = subDict["subs"] as? [[String: Any]] else {
            resolver.reject(Error.wrongResponseFormat)
            return
          }
          var subtitles: [Subtitle] = []
          var index = 0
          for sub in subArray.prefix(30) {
            guard let id = sub["id"] as? Int,
                  let nativeName = sub["native_name"] as? String,
                  let uploadTime = sub["upload_time"] as? String else {
              Logger.log("Skipping malformed AssRT search result", level: .warning, subsystem: Logger.Sub.assrt)
              continue
            }
            var subLang: String? = nil
            if let lang = sub["lang"] as? [String: Any], let desc = lang["desc"] as? String {
              subLang = desc
            }
            subtitles.append(Subtitle(index: index,
                                           id: id,
                                           nativeName: nativeName,
                                           uploadTime: uploadTime,
                                           subType: sub["subtype"] as? String,
                                           subLang: subLang))
            index += 1
          }
          resolver.fulfill(subtitles)
        }
        transfer.start()
      }
    }

    func showSubSelectWindow(with subs: [Subtitle], mediaName: String, expectedURL: URL,
                             player: PlayerCore) -> Promise<[Subtitle]> {
      // `self` is assigned as the chooser's context to keep this fetcher alive for as long as the
      // chooser is on screen.
      OnlineSubtitle.resolveSelection(subs, mediaName: mediaName, expectedURL: expectedURL, player: player,
                                      chooser: subChooseViewController, context: self)
    }

    func loadDetails(forSub sub: Subtitle) -> Promise<Subtitle> {
      loadDetails(forSub: sub, cancellation: SubtitleAudioMatcher.Cancellation())
    }

    private func loadDetails(forSub sub: Subtitle,
                             cancellation: SubtitleAudioMatcher.Cancellation) -> Promise<Subtitle> {
      guard !cancellation.isCancelled else { return Promise(error: CancellationError()) }
      var components = URLComponents(string: detailApi)!
      components.queryItems = [URLQueryItem(name: "id", value: String(sub.id))]
      var request = URLRequest(url: components.url!)
      request.httpMethod = "POST"
      request.timeoutInterval = 20
      header.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
      return Promise { resolver in
        let transfer = BuiltinSubtitleHTTPTransfer(request: request,
                                                  maximumBytes: BuiltinSubtitleResponseLimit.detailBytes,
                                                  cancellation: cancellation,
                                                  allowsURL: { BuiltinSubtitleProviderURLPolicy.allowsAssrtAPI($0) }) { result in
          guard !cancellation.isCancelled else {
            resolver.reject(OnlineSubtitle.CommonError.dismissed)
            return
          }
          guard case .success(let (data, response)) = result,
                (200..<300).contains(response.statusCode),
                let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            resolver.reject(Error.networkError)
            return
          }
          guard let status = json["status"] as? Int else {
            resolver.reject(Error.wrongResponseFormat)
            return
          }
          if let error = Error(rawValue: status) {
            resolver.reject(error)
            return
          }
          guard let subDict = json["sub"] as? [String: Any] else {
            resolver.reject(Error.wrongResponseFormat)
            return
          }
          guard let subArray = subDict["subs"] as? [[String: Any]], subArray.count == 1 else {
            resolver.reject(Error.wrongResponseFormat)
            return
          }

          guard let rawURL = subArray[0]["url"] as? String,
                let url = URL(string: rawURL) else {
            resolver.reject(Error.wrongResponseFormat)
            return
          }
          sub.url = url
          sub.filename = subArray[0]["filename"] as? String

          if let fileList = subArray[0]["filelist"] as? [[String: String]] {
            let parsedFiles = fileList.prefix(20).compactMap { info -> Subtitle.File? in
              guard let rawURL = info["url"], let url = URL(string: rawURL),
                    let filename = info["f"], !filename.isEmpty else { return nil }
              return Subtitle.File(url: url, filename: filename)
            }
            if !parsedFiles.isEmpty { sub.fileList = parsedFiles }
          }

          resolver.fulfill(sub)
        }
        transfer.start()
      }
    }

    private func loadDetails(_ subtitles: [Subtitle], at index: Int,
                             cancellation: SubtitleAudioMatcher.Cancellation) -> Promise<[Subtitle]> {
      guard !cancellation.isCancelled else { return Promise(error: OnlineSubtitle.CommonError.dismissed) }
      guard index < subtitles.count else { return .value([]) }
      return loadDetails(forSub: subtitles[index], cancellation: cancellation).then { detail in
        self.loadDetails(subtitles, at: index + 1, cancellation: cancellation).map { [detail] + $0 }
      }
    }

    private var header: [String: String] {
      return ["Authorization": "Bearer \(token)"]
    }
  }
}

extension Logger.Sub {
  static let assrt = Logger.makeSubsystem("assrt")
}
