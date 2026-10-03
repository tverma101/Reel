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

private final class SubDLHTTPTransfer: NSObject, URLSessionDataDelegate, URLSessionDownloadDelegate {
  enum Payload {
    case data(Data, HTTPURLResponse)
    case file(URL, HTTPURLResponse)
  }

  enum TransferError: Error {
    case invalidResponse
    case tooLarge
    case invalidDownload
  }

  private let request: URLRequest
  private let allowedHost: String
  private let maximumBytes: Int64
  private let fileExtension: String?
  private let completion: (Swift.Result<Payload, Swift.Error>) -> Void
  private var session: URLSession?
  private var response: HTTPURLResponse?
  private var body = Data()
  private var fileURL: URL?
  private var failure: Swift.Error?
  private var finished = false

  init(request: URLRequest,
       allowedHost: String,
       maximumBytes: Int64,
       fileExtension: String? = nil,
       completion: @escaping (Swift.Result<Payload, Swift.Error>) -> Void) {
    self.request = request
    self.allowedHost = allowedHost
    self.maximumBytes = maximumBytes
    self.fileExtension = fileExtension
    self.completion = completion
  }

  func start() {
    guard let url = request.url, SubDLSearchResultParser.allowsHTTPSOrigin(url, host: allowedHost) else {
      finish(.failure(TransferError.invalidResponse))
      return
    }
    let configuration = URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForRequest = request.timeoutInterval > 0 ? request.timeoutInterval : 20
    configuration.timeoutIntervalForResource = max(configuration.timeoutIntervalForRequest + 10, 30)
    let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    self.session = session
    if fileExtension == nil {
      session.dataTask(with: request).resume()
    } else {
      session.downloadTask(with: request).resume()
    }
  }

  func urlSession(_ session: URLSession,
                  dataTask: URLSessionDataTask,
                  didReceive response: URLResponse,
                  completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
    guard let http = response as? HTTPURLResponse,
          let url = response.url,
          SubDLSearchResultParser.allowsHTTPSOrigin(url, host: allowedHost) else {
      failure = TransferError.invalidResponse
      completionHandler(.cancel)
      return
    }
    if response.expectedContentLength > maximumBytes {
      failure = TransferError.tooLarge
      completionHandler(.cancel)
      return
    }
    self.response = http
    completionHandler(.allow)
  }

  func urlSession(_ session: URLSession,
                  task: URLSessionTask,
                  willPerformHTTPRedirection response: HTTPURLResponse,
                  newRequest request: URLRequest,
                  completionHandler: @escaping (URLRequest?) -> Void) {
    guard let url = request.url,
          SubDLSearchResultParser.allowsHTTPSOrigin(url, host: allowedHost) else {
      failure = TransferError.invalidResponse
      completionHandler(nil)
      return
    }
    completionHandler(request)
  }

  func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
    guard Int64(data.count) <= maximumBytes - Int64(body.count) else {
      failure = TransferError.tooLarge
      dataTask.cancel()
      return
    }
    body.append(data)
  }

  func urlSession(_ session: URLSession,
                  downloadTask: URLSessionDownloadTask,
                  didWriteData bytesWritten: Int64,
                  totalBytesWritten: Int64,
                  totalBytesExpectedToWrite: Int64) {
    if totalBytesWritten > maximumBytes || totalBytesExpectedToWrite > maximumBytes {
      failure = TransferError.tooLarge
      downloadTask.cancel()
    }
  }

  func urlSession(_ session: URLSession,
                  downloadTask: URLSessionDownloadTask,
                  didFinishDownloadingTo location: URL) {
    response = downloadTask.response as? HTTPURLResponse
    guard failure == nil, response?.statusCode == 200,
          let responseURL = response?.url,
          SubDLSearchResultParser.allowsHTTPSOrigin(responseURL, host: allowedHost),
          let fileExtension,
          let attributes = try? FileManager.default.attributesOfItem(atPath: location.path),
          let size = attributes[.size] as? NSNumber,
          size.int64Value > 0, size.int64Value <= maximumBytes,
          !Self.isArchive(location) else {
      failure = failure ?? TransferError.invalidDownload
      try? FileManager.default.removeItem(at: location)
      return
    }
    do {
      let destination = Utility.tempDirURL.appendingPathComponent(
        "subdl-\(UUID().uuidString).\(fileExtension)", isDirectory: false)
      try FileManager.default.moveItem(at: location, to: destination)
      fileURL = destination
    } catch {
      failure = OnlineSubtitle.CommonError.fsError
      try? FileManager.default.removeItem(at: location)
    }
  }

  func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Swift.Error?) {
    if let failure {
      if let fileURL { try? FileManager.default.removeItem(at: fileURL) }
      finish(.failure(failure))
      return
    }
    if let error {
      finish(.failure(error))
      return
    }
    guard let response else {
      finish(.failure(TransferError.invalidResponse))
      return
    }
    guard response.statusCode == 200 else {
      if let fileURL { try? FileManager.default.removeItem(at: fileURL) }
      finish(.failure(SubDL.Error.requestFailed(response.statusCode)))
      return
    }
    if fileExtension != nil {
      guard let fileURL else {
        finish(.failure(TransferError.invalidDownload))
        return
      }
      finish(.success(.file(fileURL, response)))
    } else {
      finish(.success(.data(body, response)))
    }
  }

  private func finish(_ result: Swift.Result<Payload, Swift.Error>) {
    guard !finished else { return }
    finished = true
    let session = self.session
    self.session = nil
    session?.finishTasksAndInvalidate()
    completion(result)
  }

  private static func isArchive(_ url: URL) -> Bool {
    guard let handle = try? FileHandle(forReadingFrom: url) else { return true }
    defer { try? handle.close() }
    let signature = (try? handle.read(upToCount: 265)) ?? Data()
    return signature.starts(with: [0x50, 0x4b]) ||
      signature.starts(with: [0x52, 0x61, 0x72, 0x21]) ||
      signature.starts(with: [0x37, 0x7a, 0xbc, 0xaf, 0x27, 0x1c]) ||
      signature.starts(with: [0x1f, 0x8b]) ||
      signature.starts(with: [0x42, 0x5a, 0x68]) ||
      signature.starts(with: [0xfd, 0x37, 0x7a, 0x58, 0x5a, 0x00]) ||
      (signature.count >= 262 && signature[257..<262].elementsEqual("ustar".utf8))
  }
}

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

    /// SubDL defines 0.8+ as a confident release match. The shared scorer still requires an exact
    /// title and year/episode anchor before this candidate can be auto-selected.
    override var canAutomaticallySelect: Bool { SubDLSearchResultParser.isConfidentMatch(matchScore) }

    override func getDescription() -> (name: String, left: String, right: String) {
      (fileName, "SubDL", language.uppercased())
    }

    override func download() -> Promise<[URL]> {
      Promise { resolver in
        var request = URLRequest(url: remoteURL)
        request.timeoutInterval = 30
        let fileExtension = (fileName as NSString).pathExtension
        let transfer = SubDLHTTPTransfer(request: request,
                                        allowedHost: "dl.subdl.com",
                                        maximumBytes: 10 * 1024 * 1024,
                                        fileExtension: fileExtension.isEmpty ? "srt" : fileExtension) { result in
          switch result {
          case .success(.file(let url, _)):
            resolver.fulfill([url])
          case .success(.data):
            resolver.reject(Error.invalidDownload)
          case .failure(let error):
            if let transferError = error as? SubDLHTTPTransfer.TransferError {
              switch transferError {
              case .invalidDownload, .tooLarge:
                resolver.reject(Error.invalidDownload)
              case .invalidResponse:
                resolver.reject(OnlineSubtitle.CommonError.networkError(error))
              }
            } else {
              resolver.reject(OnlineSubtitle.CommonError.networkError(error))
            }
          }
        }
        transfer.start()
      }
    }
  }

  final class Fetcher: OnlineSubtitle.DefaultFetcher, OnlineSubtitleFetcher {
    override var loggedIn: Bool { SubDL.apiKey != nil }

    func fetch(from url: URL, withProviderID id: String, playerCore player: PlayerCore) -> Promise<[Subtitle]> {
      guard let key = SubDL.apiKey else { return Promise(error: Error.missingAPIKey) }
      // Keep the string the search is based on so the results can be matched back against it.
      let mediaName = url.isFileURL ? url.deletingPathExtension().lastPathComponent : player.getMediaTitle()
      var components = URLComponents(string: "https://api.subdl.com/api/v2/files/search")!
      let name = url.isFileURL ? url.lastPathComponent : player.getMediaTitle()
      var query = [URLQueryItem(name: "filename", value: name),
                   URLQueryItem(name: "subs_per_page", value: String(SubDLSearchResultParser.maximumResults))]
      let languages = (Preference.string(for: .subLang) ?? "eng")
        .split(separator: ",")
        .compactMap { raw -> String? in
          let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
          guard !value.isEmpty else { return nil }
          let canonical = CFLocaleCreateCanonicalLanguageIdentifierFromString(kCFAllocatorDefault,
                                                                             value as CFString)?.rawValue as? String
          return canonical?.split(separator: "-").first.map(String.init)?.lowercased()
        }
      query.append(URLQueryItem(name: "languages", value: languages.isEmpty ? "en" : languages.joined(separator: ",")))
      components.queryItems = query
      var request = URLRequest(url: components.url!)
      request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
      request.setValue("application/json", forHTTPHeaderField: "Accept")
      request.timeoutInterval = 20
      return Promise { resolver in
        let transfer = SubDLHTTPTransfer(request: request,
                                        allowedHost: "api.subdl.com",
                                        maximumBytes: 2 * 1024 * 1024) { result in
          let data: Data
          let response: HTTPURLResponse
          switch result {
          case .success(.data(let body, let httpResponse)):
            data = body
            response = httpResponse
          case .success(.file):
            resolver.reject(Error.invalidResponse)
            return
          case .failure(let error):
            resolver.reject(OnlineSubtitle.CommonError.networkError(error))
            return
          }
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
        }
        transfer.start()
      }.then { subs in
        OnlineSubtitle.resolveSelection(subs, mediaName: mediaName,
                                        expectedURL: url,
                                        player: player, chooser: SubChooseViewController(), context: self)
      }
    }

  }
}
