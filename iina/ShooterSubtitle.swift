//
//  ShooterSubtitle.swift
//  iina
//
//  Created by lhc on 10/1/2017.
//  Copyright © 2017 lhc. All rights reserved.
//

import Foundation
import PromiseKit

class Shooter {
  class Subtitle: OnlineSubtitle {
    var desc: String
    var delay: Int
    var files: [SubFile]
    private let downloadCache = BuiltinSubtitleCache(provider: "shooter")

    struct SubFile {
      var ext: String
      var path: String
    }

    init(index: Int, desc: String, delay: Int, files: [SubFile]) {
      self.desc = desc
      self.delay = delay
      self.files = files
      super.init(index: index)
    }

    override func download() -> Promise<[URL]> {
      download(cancellation: SubtitleAudioMatcher.Cancellation())
    }

    override func download(cancellation: SubtitleAudioMatcher.Cancellation) -> Promise<[URL]> {
      cancellation.onCancel { [weak self] in self?.discardCachedDownload() }
      guard !cancellation.isCancelled, let file = files.first else {
        return Promise(error: cancellation.isCancelled ? OnlineSubtitle.CommonError.dismissed :
                         OnlineSubtitle.CommonError.networkError(nil))
      }
      guard let rawRemoteURL = URL(string: file.path),
            let remoteURL = BuiltinSubtitleProviderURLPolicy.shooterDownloadURL(rawRemoteURL) else {
        return Promise(error: OnlineSubtitle.CommonError.networkError(nil))
      }
      var request = URLRequest(url: remoteURL)
      request.timeoutInterval = 30
      return Promise { resolver in
        let transfer = BuiltinSubtitleHTTPTransfer(request: request,
                                                  maximumBytes: BuiltinSubtitleResponseLimit.subtitleBytes,
                                                  cancellation: cancellation,
                                                  allowsURL: { BuiltinSubtitleProviderURLPolicy.allowsShooter($0) }) { result in
          guard !cancellation.isCancelled else {
            self.discardCachedDownload()
            resolver.reject(OnlineSubtitle.CommonError.dismissed)
            return
          }
          switch result {
          case .success(let (data, response)) where (200..<300).contains(response.statusCode):
            do {
              let url = try self.downloadCache.store(data,
                                                     suggestedFileName: "[\(self.index)]\(response.suggestedFilename ?? "subtitle")",
                                                     cancellation: cancellation)
              resolver.fulfill([url])
            } catch {
              self.discardCachedDownload()
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
  }

  enum Error: Swift.Error {
    case cannotReadFile(Swift.Error)
    case fileTooSmall(Int)
  }

  class Fetcher: OnlineSubtitle.DefaultFetcher, OnlineSubtitleFetcher {
    typealias Subtitle = Shooter.Subtitle

    struct FileInfo {
      var hashValue: String
      var path: String

      var dictionary: [String: Any] {
        return [
          "filehash": hashValue,
          "pathinfo": path,
          "format": "json"
        ]
      }
    }

    typealias ResponseData = [[String: Any]]
    typealias ResponseFilesData = [[String: String]]

    private static let minimumFileSize = 12288

    private let chunkSize: Int = 4096
    private let apiPath = "https://www.shooter.cn/api/subapi.php"

    private var language: String?

    func fetch(from url: URL, withProviderID id: String, playerCore player: PlayerCore) -> Promise<[Subtitle]> {
      fetch(from: url, withProviderID: id, playerCore: player,
            cancellation: SubtitleAudioMatcher.Cancellation())
    }

    func fetch(from url: URL, withProviderID id: String, playerCore player: PlayerCore,
               cancellation: SubtitleAudioMatcher.Cancellation) -> Promise<[Subtitle]> {
      guard !cancellation.isCancelled else { return Promise(error: OnlineSubtitle.CommonError.dismissed) }
      return hash(url, cancellation: cancellation).then { self.request($0, cancellation: cancellation) }
    }

    private func hash(_ url: URL,
                      cancellation: SubtitleAudioMatcher.Cancellation) -> Promise<FileInfo> {
      return Promise { resolver in
        guard !cancellation.isCancelled else {
          resolver.reject(OnlineSubtitle.CommonError.dismissed)
          return
        }
        let file: FileHandle
        do {
          file = try FileHandle(forReadingFrom: url)
        } catch {
          resolver.reject(Error.cannotReadFile(error))
          return
        }
        defer { file.closeFile() }

        file.seekToEndOfFile()
        let fileSize: UInt64 = file.offsetInFile

        guard fileSize >= Shooter.Fetcher.minimumFileSize else {
          resolver.reject(Error.fileTooSmall(Shooter.Fetcher.minimumFileSize))
          return
        }

        let offsets: [UInt64] = [
          4096,
          fileSize / 3 * 2,
          fileSize / 3,
          fileSize - 8192
        ]

        let hash = offsets.map { offset -> String in
          file.seek(toFileOffset: offset)
          return file.readData(ofLength: chunkSize).md5
          }.joined(separator: ";")

        guard !cancellation.isCancelled else {
          resolver.reject(OnlineSubtitle.CommonError.dismissed)
          return
        }
        resolver.fulfill(FileInfo(hashValue: hash, path: url.path))
      }
    }

    private func request(_ info: FileInfo,
                         cancellation: SubtitleAudioMatcher.Cancellation) -> Promise<[Subtitle]> {
      guard !cancellation.isCancelled else { return Promise(error: OnlineSubtitle.CommonError.dismissed) }
      let parameters = info.dictionary
      var components = URLComponents(string: apiPath)!
      components.queryItems = parameters.keys.sorted().compactMap { key in
        guard let value = parameters[key] as? String else { return nil }
        return URLQueryItem(name: key, value: value)
      }
      var request = URLRequest(url: components.url!)
      request.httpMethod = "POST"
      request.timeoutInterval = 10
      return Promise { resolver in
        let transfer = BuiltinSubtitleHTTPTransfer(request: request,
                                                  maximumBytes: BuiltinSubtitleResponseLimit.searchBytes,
                                                  cancellation: cancellation,
                                                  allowsURL: { BuiltinSubtitleProviderURLPolicy.allowsShooter($0) }) { result in
          guard !cancellation.isCancelled else {
            resolver.reject(OnlineSubtitle.CommonError.dismissed)
            return
          }
          guard case .success(let (data, response)) = result,
                (200..<300).contains(response.statusCode),
                let json = try? JSONSerialization.jsonObject(with: data) as? ResponseData else {
            resolver.reject(OnlineSubtitle.CommonError.noResult)
            return
          }

          var subtitles: [Subtitle] = []
          var index = 1

          json.prefix(30).forEach { sub in
            guard let filesDic = sub["Files"] as? ResponseFilesData else { return }
            let files = filesDic.compactMap { file -> Subtitle.SubFile? in
              guard let ext = file["Ext"], let path = file["Link"], !path.isEmpty else { return nil }
              return Subtitle.SubFile(ext: ext, path: path)
            }
            guard !files.isEmpty else { return }
            let desc = sub["Desc"] as? String ?? ""
            let delay = sub["Delay"] as? Int ?? 0

            subtitles.append(Subtitle(index: index, desc: desc, delay: delay, files: files))
            index += 1
          }
          resolver.fulfill(subtitles)
        }
        transfer.start()
      }
    }
  }
}

extension Logger.Sub {
  static let shooter = Logger.makeSubsystem("sub.shooter")
}
