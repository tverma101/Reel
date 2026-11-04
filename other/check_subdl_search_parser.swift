import Foundation

@main
struct CheckSubDLSearchResultParser {
  private static var checks = 0

  static func main() throws {
    let validEntry: [String: Any] = [
      "file_name": "The.Matrix.1999.en.vtt",
      "release_name": "The.Matrix.1999.1080p.BluRay-GROUP",
      "lang": "english",
      "match_score": 0.92,
      "url": "/subtitle/123/456",
    ]
    let valid = try SubDLSearchResultParser.parse(response([validEntry]))
    check(valid.count == 1, "valid v2 result is retained")
    check(valid[0].remoteURL.absoluteString == "https://dl.subdl.com/subtitle/123/456",
          "relative download URL is pinned to SubDL")
    check(valid[0].fileName == "The.Matrix.1999.en.vtt", "filename and text format are retained")
    check(valid[0].language == "english", "language is retained")
    check(valid[0].releaseName == "The.Matrix.1999.1080p.BluRay-GROUP", "release name is retained")
    check(valid[0].matchScore == 0.92, "documented numeric confidence is retained")
    check(SubDLSearchResultParser.isConfidentMatch(valid[0].matchScore), "0.92 is confident")
    check(!SubDLSearchResultParser.isConfidentMatch(0.79), "0.79 is below the confidence threshold")
    check(SubDLSearchResultParser.isConfidentMatch(0.8), "0.8 meets the confidence threshold")
    check(!SubDLSearchResultParser.isConfidentMatch(nil), "missing score cannot auto-select")

    for name in [".", "", ".."] {
      let pathLikeName = try SubDLSearchResultParser.parse(response([
        entry(url: "https://dl.subdl.com/subtitle/123/fallback.srt", fileName: name),
      ]))
      check(pathLikeName.first?.fileName == "fallback.srt", "invalid relative filename falls back to the URL name")
    }
    let windowsName = try SubDLSearchResultParser.parse(response([
      entry(url: "https://dl.subdl.com/subtitle/123/subtitle.srt", fileName: #"C:\\private\\sub.srt"#),
    ]))
    check(windowsName.first?.fileName == "sub.srt", "Windows path components are stripped")

    let unsupportedExplicitFormat = try SubDLSearchResultParser.parse(response([
      entry(url: "https://dl.subdl.com/subtitle/123/456", format: "zip"),
    ]))
    check(unsupportedExplicitFormat.isEmpty, "explicit archive format is rejected")

    let unsupportedExtension = try SubDLSearchResultParser.parse(response([
      entry(url: "https://dl.subdl.com/subtitle/123/456", fileName: "caption.html"),
    ]))
    check(unsupportedExtension.isEmpty, "unsupported filename extension is rejected")

    let opaqueURL = try SubDLSearchResultParser.parse(response([
      entry(url: "https://dl.subdl.com/subtitle/123/456", fileName: "456"),
    ]))
    check(opaqueURL.first?.fileName == "456.srt", "opaque raw-file IDs use the SRT fallback")

    let archiveURL = try SubDLSearchResultParser.parse(response([
      entry(url: "https://dl.subdl.com/subtitle/123/456.zip"),
    ]))
    check(archiveURL.isEmpty, "archive URL is rejected")

    let limited = try SubDLSearchResultParser.parse(response((0..<40).map { index in
      entry(url: "https://dl.subdl.com/subtitle/123/\(index).srt")
    }))
    check(limited.count == SubDLSearchResultParser.maximumResults, "result count is bounded to the API limit")

    let badBooleanScore = try SubDLSearchResultParser.parse(response([
      entry(url: "https://dl.subdl.com/subtitle/123/456.srt", score: true),
    ]))
    check(badBooleanScore.first?.matchScore == nil, "JSON booleans are not accepted as confidence")

    let outOfRangeScore = try SubDLSearchResultParser.parse(response([
      entry(url: "https://dl.subdl.com/subtitle/123/456.srt", score: 1.1),
    ]))
    check(outOfRangeScore.first?.matchScore == nil, "out-of-range confidence is ignored")

    let empty = try SubDLSearchResultParser.parse(response([]))
    check(empty.isEmpty, "successful empty result is accepted")
    checkThrows(try SubDLSearchResultParser.parse(data(["status": false, "subtitles": []])),
                "failed provider response is rejected")
    checkThrows(try SubDLSearchResultParser.parse(data(["status": true, "subtitles": "bad"])),
                "malformed result collection is rejected")

    let rejectedURLs = [
      "http://dl.subdl.com/subtitle/123/456.srt",
      "https://evil.example/subtitle/123/456.srt",
      "https://dl.subdl.com@evil.example/subtitle/123/456.srt",
      "https://dl.subdl.com:8443/subtitle/123/456.srt",
      "https://dl.subdl.com/subtitle/123/../secret.srt",
      "https://dl.subdl.com/subtitle/123/%2e%2e/secret.srt",
      "https://dl.subdl.com/subtitle/123/456.srt#fragment",
    ]
    for raw in rejectedURLs {
      check(SubDLSearchResultParser.downloadURL(raw) == nil, "unsafe download URL rejected: \(raw)")
    }
    check(SubDLSearchResultParser.downloadURL("https://dl.subdl.com/subtitle/123/456.srt?api_key=signed") != nil,
          "provider-signed download query is retained")
    check(SubDLSearchResultParser.allowsHTTPSOrigin(URL(string: "https://dl.subdl.com/redirected")!, host: "dl.subdl.com"),
          "same-host HTTPS redirects are permitted")
    check(!SubDLSearchResultParser.allowsHTTPSOrigin(URL(string: "https://evil.example/file")!, host: "dl.subdl.com"),
          "cross-host redirects are rejected")
    check(!SubDLSearchResultParser.allowsHTTPSOrigin(URL(string: "http://dl.subdl.com/file")!, host: "dl.subdl.com"),
          "HTTP redirects are rejected")
    check(!SubDLSearchResultParser.allowsHTTPSOrigin(URL(string: "https://dl.subdl.com:8443/file")!, host: "dl.subdl.com"),
          "non-standard redirect ports are rejected")

    checkThrows(try SubDLSearchResultParser.parse(data(["status": true])),
                "successful response without subtitles is a schema error")

    print("SubDL parser checks passed: \(checks)")
  }

  private static func response(_ subtitles: [[String: Any]]) -> Data {
    data(["status": true, "subtitles": subtitles])
  }

  private static func entry(url: String,
                            fileName: String = "caption.srt",
                            format: String? = nil,
                            score: Any = 0.9) -> [String: Any] {
    var result: [String: Any] = [
      "url": url,
      "file_name": fileName,
      "lang": "english",
      "match_score": score,
    ]
    if let format { result["format"] = format }
    return result
  }

  private static func data(_ object: [String: Any]) -> Data {
    try! JSONSerialization.data(withJSONObject: object)
  }

  private static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    checks += 1
    guard condition() else {
      fputs("FAIL: \(message)\n", stderr)
      exit(1)
    }
  }

  private static func checkThrows<T>(_ expression: @autoclosure () throws -> T, _ message: String) {
    do {
      _ = try expression()
      check(false, message)
    } catch {
      check(true, message)
    }
  }
}
