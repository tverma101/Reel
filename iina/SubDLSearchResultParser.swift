import CoreFoundation
import Foundation

struct SubDLSearchResult {
  let fileName: String
  let language: String
  let releaseName: String?
  let remoteURL: URL
  let matchScore: Double?
}

enum SubDLSearchResultParser {
  enum ParseError: Error {
    case invalidResponse
  }

  static let maximumResults = 30
  private static let supportedFormats: Set<String> = ["srt", "ass", "ssa", "vtt", "sub", "txt"]

  static func parse(_ data: Data) throws -> [SubDLSearchResult] {
    guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
          json["status"] as? Bool == true else {
      throw ParseError.invalidResponse
    }
    guard let rawSubtitles = json["subtitles"] else {
      throw ParseError.invalidResponse
    }
    guard let subtitles = rawSubtitles as? [[String: Any]] else {
      throw ParseError.invalidResponse
    }

    return subtitles.prefix(maximumResults).compactMap { entry in
      guard let rawURL = entry["url"] as? String,
            let remoteURL = downloadURL(rawURL),
            remoteURL.pathExtension.lowercased() != "zip" else { return nil }

      let rawName = (entry["file_name"] as? String)
        ?? (entry["name"] as? String)
        ?? remoteURL.lastPathComponent
      let component = rawName.split(whereSeparator: { $0 == "/" || $0 == "\\" })
        .last.map(String.init) ?? ""
      let safeName = ["", ".", ".."].contains(component) ? remoteURL.lastPathComponent : component
      let fileExtension = URL(fileURLWithPath: safeName).pathExtension
      let rawFormat = entry["format"] as? String
      let format: String
      if let rawFormat, !rawFormat.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        guard let normalized = normalizedFormat(rawFormat) else { return nil }
        format = normalized
      } else if !fileExtension.isEmpty {
        guard let normalized = normalizedFormat(fileExtension) else { return nil }
        format = normalized
      } else if !remoteURL.pathExtension.isEmpty {
        guard let normalized = normalizedFormat(remoteURL.pathExtension) else { return nil }
        format = normalized
      } else {
        // The v2 raw-file URLs may be opaque numeric IDs without a suffix. SubDL's search
        // endpoint returns text subtitle files; when both format and suffix are absent, retain
        // the long-standing SRT fallback. Explicit unsupported formats are rejected above.
        format = "srt"
      }

      let rawStem = URL(fileURLWithPath: safeName).deletingPathExtension().lastPathComponent
      let stem = String((rawStem.isEmpty || rawStem == "." || rawStem == ".." ? "subtitle" : rawStem).prefix(180))
      let fileName = "\(stem.isEmpty ? "subtitle" : stem).\(format)"
      let language = (entry["lang"] as? String) ?? (entry["language"] as? String) ?? ""
      let releaseName = entry["release_name"] as? String
      let score = matchScore(from: entry["match_score"])
      return SubDLSearchResult(fileName: fileName, language: language,
                               releaseName: releaseName, remoteURL: remoteURL,
                               matchScore: score)
    }
  }

  /// SubDL's documented raw-file URL is either absolute on `dl.subdl.com` or a
  /// `/subtitle/...` path. The user's API key is sent only in the search Authorization header.
  static func downloadURL(_ raw: String) -> URL? {
    let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !value.isEmpty else { return nil }
    let url = value.hasPrefix("/") ? URL(string: "https://dl.subdl.com\(value)") : URL(string: value)
    guard let url, allowsHTTPSOrigin(url, host: "dl.subdl.com"),
          url.path.hasPrefix("/subtitle/"), url.fragment == nil else { return nil }
    let decodedPath = url.path.removingPercentEncoding ?? url.path
    guard !decodedPath.split(separator: "/").contains(where: { $0 == ".." || $0 == "." }) else { return nil }
    return url
  }

  static func allowsHTTPSOrigin(_ url: URL, host: String) -> Bool {
    url.scheme?.lowercased() == "https" && url.host?.lowercased() == host &&
      url.port == nil && url.user == nil && url.password == nil && url.fragment == nil
  }

  private static func normalizedFormat(_ raw: String?) -> String? {
    guard let raw else { return nil }
    let value = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    let format: String
    switch value {
    case "subrip": format = "srt"
    case "webvtt": format = "vtt"
    case "substation alpha": format = "ass"
    default: format = value
    }
    return supportedFormats.contains(format) ? format : nil
  }

  private static func matchScore(from raw: Any?) -> Double? {
    guard let number = raw as? NSNumber,
          CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
    let value = number.doubleValue
    guard value.isFinite, (0...1).contains(value) else { return nil }
    return value
  }

  static func isConfidentMatch(_ score: Double?) -> Bool {
    guard let score, score.isFinite else { return false }
    return (0.8...1).contains(score)
  }
}
