//
//  SubDLSubtitle.swift
//  iina
//
//  SubDL's documented API requires a free account key for searches. Download links returned by
//  a search can be fetched without an account; the key is never put in a URL or a log message.
//

import CoreFoundation
import Foundation
import PromiseKit

class SubDL {
  enum Error: LocalizedError {
    case missingAPIKey
    case invalidResponse
    case requestFailed(Int)
    case invalidDownload

    var errorDescription: String? {
      switch self {
      case .missingAPIKey: return "Add a free SubDL API key in Settings › Subtitles."
      case .invalidResponse: return "SubDL returned an unreadable search response."
      case .requestFailed(let status): return "SubDL request failed (HTTP \(status))."
      case .invalidDownload: return "SubDL did not return a usable subtitle file."
      }
    }
  }

  static var apiKey: String? {
    guard let value = try? KeychainAccess.read(username: "subdl", forService: .subDLAPIKey).password,
          !value.isEmpty else { return nil }
    return value
  }

  final class Subtitle: OnlineSubtitle {
    let fileName: String
    let language: String
    let remoteURL: URL
    let matchScore: Double?
    private let providerReleaseName: String?
    private let downloadCache = BuiltinSubtitleCache(provider: "subdl")

    init(index: Int, fileName: String, language: String, releaseName: String?,
         remoteURL: URL, matchScore: Double?) {
      self.fileName = fileName
      self.language = language
      self.providerReleaseName = releaseName
      self.remoteURL = remoteURL
      self.matchScore = matchScore
      super.init(index: index)
    }

    override var releaseName: String? { providerReleaseName ?? fileName }

    /// SubDL labels each file with a language name (`english`) or a code, depending on the endpoint
    /// version; both are reduced to a language subtag before comparison.
    override var languageHint: String? { language }

    /// SubDL defines 0.8+ as a confident release match. The shared scorer still requires an exact
    /// title and year/episode anchor before this candidate can be auto-selected.
    override var canAutomaticallySelect: Bool { SubDLSearchResultParser.isConfidentMatch(matchScore) }

    override func getDescription() -> (name: String, left: String, right: String) {
      (fileName, "SubDL", language.uppercased())
    }

    override func download() -> Promise<[URL]> {
      download(cancellation: SubtitleAudioMatcher.Cancellation())
    }

    override func download(cancellation: SubtitleAudioMatcher.Cancellation) -> Promise<[URL]> {
      cancellation.onCancel { [weak self] in self?.discardCachedDownload() }
      guard !cancellation.isCancelled else {
        return Promise(error: OnlineSubtitle.CommonError.dismissed)
      }
      return Promise<[URL]> { resolver in
        var request = URLRequest(url: remoteURL)
        request.timeoutInterval = 30
        let transfer = BuiltinSubtitleHTTPTransfer(request: request,
                                                  maximumBytes: BuiltinSubtitleResponseLimit.subtitleBytes,
                                                  cancellation: cancellation,
                                                  allowsURL: { SubDLSearchResultParser.allowsHTTPSOrigin($0,
                                                                                                       host: "dl.subdl.com") }) { result in
          guard !cancellation.isCancelled else {
            self.discardCachedDownload()
            resolver.reject(OnlineSubtitle.CommonError.dismissed)
            return
          }
          switch result {
          case .success(let (data, response)) where response.statusCode == 200:
            guard !data.isEmpty, !Self.isArchive(data) else {
              resolver.reject(Error.invalidDownload)
              return
            }
            do {
              let url = try self.downloadCache.store(data,
                                                     suggestedFileName: self.fileName,
                                                     cancellation: cancellation)
              resolver.fulfill([url])
            } catch {
              self.discardCachedDownload()
              resolver.reject(cancellation.isCancelled ? OnlineSubtitle.CommonError.dismissed :
                                OnlineSubtitle.CommonError.fsError)
            }
          case .success(let (_, response)):
            resolver.reject(Error.requestFailed(response.statusCode))
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

    private static func isArchive(_ data: Data) -> Bool {
      data.starts(with: [0x50, 0x4b]) ||
        data.starts(with: [0x52, 0x61, 0x72, 0x21]) ||
        data.starts(with: [0x37, 0x7a, 0xbc, 0xaf, 0x27, 0x1c]) ||
        data.starts(with: [0x1f, 0x8b]) ||
        data.starts(with: [0x42, 0x5a, 0x68]) ||
        data.starts(with: [0xfd, 0x37, 0x7a, 0x58, 0x5a, 0x00]) ||
        (data.count >= 262 && data[257..<262].elementsEqual("ustar".utf8))
    }
  }

  final class Fetcher: OnlineSubtitle.DefaultFetcher, OnlineSubtitleFetcher {
    override var loggedIn: Bool { SubDL.apiKey != nil }

    func fetch(from url: URL, withProviderID id: String, playerCore player: PlayerCore) -> Promise<[Subtitle]> {
      fetch(from: url, withProviderID: id, playerCore: player,
            cancellation: SubtitleAudioMatcher.Cancellation())
    }

    func fetch(from url: URL, withProviderID id: String, playerCore player: PlayerCore,
               cancellation: SubtitleAudioMatcher.Cancellation) -> Promise<[Subtitle]> {
      guard !cancellation.isCancelled else { return Promise(error: OnlineSubtitle.CommonError.dismissed) }
      guard let key = SubDL.apiKey else { return Promise(error: Error.missingAPIKey) }
      // Keep the string the search is based on so the results can be matched back against it.
      let mediaName = url.isFileURL ? url.deletingPathExtension().lastPathComponent : player.getMediaTitle()
      var components = URLComponents(string: "https://api.subdl.com/api/v2/files/search")!
      let name = url.isFileURL ? url.lastPathComponent : player.getMediaTitle()
      var query = [URLQueryItem(name: "filename", value: name),
                   URLQueryItem(name: "subs_per_page", value: String(SubDLSearchResultParser.maximumResults))]
      // SubDL takes base-language codes (`en,fa,ar`); regional preferences intentionally use
      // that language-wide fallback because the API does not document regional codes.
      let languages = SubtitleLanguagePreference.preferred(from: Preference.string(for: .subLang))
      query.append(URLQueryItem(name: "languages", value: languages.joined(separator: ",")))
      components.queryItems = query
      var request = URLRequest(url: components.url!)
      request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
      request.setValue("application/json", forHTTPHeaderField: "Accept")
      request.timeoutInterval = 20
      return Promise<[Subtitle]> { resolver in
        let transfer = BuiltinSubtitleHTTPTransfer(request: request,
                                                  maximumBytes: BuiltinSubtitleResponseLimit.searchBytes,
                                                  cancellation: cancellation,
                                                  allowsURL: { SubDLSearchResultParser.allowsHTTPSOrigin($0,
                                                                                                       host: "api.subdl.com") }) { result in
          guard !cancellation.isCancelled else {
            resolver.reject(OnlineSubtitle.CommonError.dismissed)
            return
          }
          switch result {
          case .success(let (data, response)):
            guard response.statusCode == 200 else {
              resolver.reject(Error.requestFailed(response.statusCode))
              return
            }
            do {
              let parsed = try SubDLSearchResultParser.parse(data)
              let subtitles = parsed.enumerated().map { item in
                Subtitle(index: item.offset, fileName: item.element.fileName,
                         language: item.element.language, releaseName: item.element.releaseName,
                         remoteURL: item.element.remoteURL, matchScore: item.element.matchScore)
              }
              resolver.fulfill(subtitles)
            } catch {
              resolver.reject(Error.invalidResponse)
            }
          case .failure(let error):
            resolver.reject(OnlineSubtitle.CommonError.networkError(error))
          }
        }
        transfer.start()
      }.then { subs in
        guard !cancellation.isCancelled else { throw OnlineSubtitle.CommonError.dismissed }
        return OnlineSubtitle.resolveSelection(subs, mediaName: mediaName,
                                               expectedURL: url,
                                               player: player, chooser: SubChooseViewController(), context: self)
      }
    }

  }
}
