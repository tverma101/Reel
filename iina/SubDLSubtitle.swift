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

  /// Accept only subtitle download links on SubDL's documented download host.
  static func downloadURL(_ raw: String) -> URL? {
    let url = raw.hasPrefix("/") ? URL(string: "https://dl.subdl.com\(raw)") : URL(string: raw)
    guard let url, url.scheme == "https", url.host == "dl.subdl.com",
          url.path.hasPrefix("/subtitle/"), !url.pathComponents.contains("..") else { return nil }
    return url
  }

  final class Subtitle: OnlineSubtitle {
    let fileName: String
    let language: String
    let remoteURL: URL
    private let providerReleaseName: String?

    init(index: Int, fileName: String, language: String, releaseName: String?, remoteURL: URL) {
      self.fileName = fileName
      self.language = language
      self.providerReleaseName = releaseName
      self.remoteURL = remoteURL
      super.init(index: index)
    }

    override var releaseName: String? { providerReleaseName ?? fileName }

    override func getDescription() -> (name: String, left: String, right: String) {
      (fileName, "SubDL", language.uppercased())
    }

    override func download() -> Promise<[URL]> {
      Promise { resolver in
        URLSession.shared.dataTask(with: remoteURL) { data, response, error in
          if let error {
            resolver.reject(OnlineSubtitle.CommonError.networkError(error))
            return
          }
          guard let response = response as? HTTPURLResponse, response.statusCode == 200,
                let data, !data.isEmpty, data.count <= 10 * 1024 * 1024,
                !data.starts(with: [0x50, 0x4b]) else {
            resolver.reject(Error.invalidDownload)
            return
          }
          let safeName = URL(fileURLWithPath: self.fileName).lastPathComponent
            .replacingOccurrences(of: "/", with: "_")
          let suffix = (safeName as NSString).pathExtension.isEmpty ? ".srt" : ""
          let name = "subdl-\(UUID().uuidString)-\(safeName.prefix(120))\(suffix)"
          guard let url = data.saveToFolder(Utility.tempDirURL, filename: name) else {
            resolver.reject(OnlineSubtitle.CommonError.fsError)
            return
          }
          resolver.fulfill([url])
        }.resume()
      }
    }
  }

  final class Fetcher: OnlineSubtitle.DefaultFetcher, OnlineSubtitleFetcher {
    override var loggedIn: Bool { SubDL.apiKey != nil }

    func fetch(from url: URL, withProviderID id: String, playerCore player: PlayerCore) -> Promise<[Subtitle]> {
      guard let key = SubDL.apiKey else { return Promise(error: Error.missingAPIKey) }
      // Keep the string the search is based on so the results can be matched back against it.
      let mediaName = url.isFileURL ? url.deletingPathExtension().lastPathComponent : player.getMediaTitle()
      var components = URLComponents(string: "https://api.subdl.com/api/v2/subtitles/search")!
      let name = url.isFileURL ? url.lastPathComponent : player.getMediaTitle()
      var query = [URLQueryItem(name: "file_name", value: name),
                   URLQueryItem(name: "unpack", value: "1"),
                   URLQueryItem(name: "subs_per_page", value: "20")]
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
        URLSession.shared.dataTask(with: request) { data, response, error in
          if let error {
            resolver.reject(OnlineSubtitle.CommonError.networkError(error))
            return
          }
          guard let response = response as? HTTPURLResponse else {
            resolver.reject(Error.invalidResponse)
            return
          }
          guard response.statusCode == 200 else {
            resolver.reject(Error.requestFailed(response.statusCode))
            return
          }
          guard let data else {
            resolver.reject(Error.invalidResponse)
            return
          }
          do {
            let subtitles = try Self.parseResults(data)
            resolver.fulfill(subtitles)
          } catch {
            resolver.reject(error)
          }
        }.resume()
      }.then { subs in
        OnlineSubtitle.resolveSelection(subs, mediaName: mediaName,
                                        expectedURL: url,
                                        player: player, chooser: SubChooseViewController(), context: self)
      }
    }

    /// Flatten unpacked files so the player never has to execute an archive extractor on a
    /// provider response. A pack without a documented raw-file URL remains a manual website case.
    static func parseResults(_ data: Data) throws -> [Subtitle] {
      guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            json["status"] as? Bool == true else {
        throw Error.invalidResponse
      }
      // A successful search may omit `subtitles` when no files matched the title.
      guard let rawEntries = json["subtitles"] else { return [] }
      guard let entries = rawEntries as? [[String: Any]] else { throw Error.invalidResponse }
      var results: [Subtitle] = []
      for entry in entries {
        let unpacked = entry["unpack_files"] as? [[String: Any]]
        let files = unpacked?.isEmpty == false ? unpacked! : [entry]
        for file in files {
          guard results.count < 20 else { return results }
          guard let rawURL = file["url"] as? String,
                let remoteURL = SubDL.downloadURL(rawURL),
                remoteURL.pathExtension.lowercased() != "zip" else { continue }
          let rawName = (file["name"] as? String) ?? (entry["name"] as? String) ?? "subtitle.srt"
          let fileName = URL(fileURLWithPath: rawName).lastPathComponent
          let format = (file["format"] as? String)?.lowercased() ?? "srt"
          guard ["srt", "ass", "ssa", "vtt", "sub", "txt"].contains(format) else { continue }
          let language = (file["language"] as? String) ?? (entry["lang"] as? String) ?? ""
          let release = (file["release_name"] as? String) ?? (entry["release_name"] as? String)
          results.append(Subtitle(index: results.count, fileName: fileName,
                                  language: language, releaseName: release, remoteURL: remoteURL))
        }
      }
      return results
    }
  }
}
