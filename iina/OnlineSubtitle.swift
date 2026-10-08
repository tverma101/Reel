//
//  OnlineSubtitle.swift
//  iina
//
//  Created by lhc on 10/1/2017.
//  Copyright © 2017 lhc. All rights reserved.
//

import Foundation
import PromiseKit

fileprivate protocol ProviderProtocol {
  associatedtype F: OnlineSubtitleFetcher
  var id: String { get }
  var name: String { get }
  var origin: OnlineSubtitle.Origin { get }
  func getFetcher() -> F
  func fetchSubtitles(url: URL, player: PlayerCore) -> Promise<[URL]>
}

protocol OnlineSubtitleFetcher {
  associatedtype Subtitle: OnlineSubtitle
  var loggedIn: Bool { get }
  func fetch(from url: URL, withProviderID id: String, playerCore player: PlayerCore) -> Promise<[Subtitle]>
  func logout(timeout: TimeInterval?) -> Promise<Void>
}

class OnlineSubtitle: NSObject {
  enum CommonError: Error {
    case noResult
    case canceled
    case dismissed
    case cannotConnect(Error)
    case networkError(Error?)
    case timedOut(Error)
    case fsError
  }

  static var loggedIn: Bool {
    let id = Preference.string(for: .onlineSubProvider) ?? Providers.openSub.id
    switch id {
    case Providers.openSub.id:
      return Providers.openSub.getFetcher().loggedIn
    case Providers.subDL.id:
      return Providers.subDL.getFetcher().loggedIn
    case Providers.shooter.id:
      return Providers.shooter.getFetcher().loggedIn
    case Providers.assrt.id:
      return Providers.assrt.getFetcher().loggedIn
    default:
      guard let provider = Providers.fromPlugin[id] else {
        return Providers.openSub.getFetcher().loggedIn
      }
      return provider.getFetcher().loggedIn
    }
  }

  /** Prepend a number before file name to avoid overwriting. */
  var index: Int

  /**
   The name of the release this subtitle was authored for, e.g. `Movie.2019.1080p.BluRay.x264-GROUP`.

   Providers override this so IINA can score how well a result matches the media being played.
   `nil` means the provider cannot describe its results, and such results never auto-select.
   */
  var releaseName: String? { nil }

  /// Whether this provider result has independent evidence beyond uploader-controlled names.
  /// Providers must opt in explicitly; exact filename matches alone are not proof of content.
  var canAutomaticallySelect: Bool { false }

  /// Provider-supplied preference for chooser preselection, without changing result ordering.
  var verifiedSelectionBoost: Int { 0 }

  init(index: Int) {
    self.index = index
  }

  /// Check if the given error indicates IINA was unable to connect to the subtitle server.
  /// - Parameter error: the error object to inspect
  /// - Returns: `true` if the error represents a connection failure; otherwise `false`.
  static func isConnectFailure(_ error: Error?) -> Bool {
    guard let nsError = (error as NSError?) else { return false }
    return nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCannotConnectToHost
  }

  /// Check if the given error indicates IINA timed out while trying to connect to the subtitle server.
  /// - Parameter error: the error object to inspect
  /// - Returns: `true` if the error represents a timed out failure; otherwise `false`.
  static func isTimedOutFailure(_ error: Error?) -> Bool {
    guard let nsError = (error as NSError?) else { return false }
    return nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorTimedOut
  }

  func download() -> Promise<[URL]> { return .value([]) }
  func getDescription() -> (name: String, left: String, right: String) { return("", "", "") }

  class DefaultFetcher {
    var loggedIn: Bool { false }
    func logout(timeout: TimeInterval?) -> Promise<Void> { .value }
    required init() {}
  }

  class Providers {
    static let subDL = Provider<SubDL.Fetcher>(id: ":subdl", name: "SubDL")
    static let shooter = Provider<Shooter.Fetcher>(id: ":shooter", name: "shooter.cn")
    static let openSub = Provider<OpenSub.Fetcher>(id: ":opensubtitles", name: "opensubtitles.com")
    static let assrt = Provider<Assrt.Fetcher>(id: ":assrt", name: "assrt.net")

    static var fromPlugin: [String: Provider<JSPluginSub.Fetcher>] = [:]

    static func registerFromPlugin(_ pluginID: String, _ pluginName: String, id: String, name: String) {
      let providerID = "plugin:\(pluginID):\(id)"
      fromPlugin[providerID] = Provider(id: id,
                                        name: name,
                                        providerID: providerID,
                                        origin: .plugin(id: pluginID, name: pluginName))
    }

    static func removeAllFromPlugin(_ pluginID: String) {
      let prefix = "plugin:\(pluginID):"
      for key in fromPlugin.keys.filter({ $0.hasPrefix(prefix) }) {
        fromPlugin.removeValue(forKey: key)
      }
    }

    static func nameForID(_ id: String) -> String {
      switch id {
      case Providers.subDL.id:
        return Providers.subDL.name
      case Providers.openSub.id:
        return Providers.openSub.name
      case Providers.shooter.id:
        return Providers.shooter.name
      case Providers.assrt.id:
        return Providers.assrt.name
      default:
        return Providers.fromPlugin[id]?.name ?? Providers.openSub.name
      }
    }
  }

  enum Origin {
    case legacy
    case plugin(id: String, name: String)
  }

  class Provider<F: OnlineSubtitleFetcher>: ProviderProtocol where F: DefaultFetcher {
    let id: String
    let providerID: String
    let name: String
    let origin: Origin

    init(id: String, name: String, providerID: String? = nil, origin: Origin = .legacy) {
      self.id = id
      self.providerID = providerID ?? id
      self.name = name
      self.origin = origin
    }

    func getFetcher() -> F {
      return F()
    }

    func fetchSubtitles(url: URL, player: PlayerCore) -> Promise<[URL]> {
      return getFetcher().fetch(from: url, withProviderID: providerID, playerCore: player)
      .get { [self] subtitles in
        if subtitles.isEmpty {
          throw OnlineSubtitle.CommonError.noResult
        } else {
          player.sendOSD(.downloadingSub(subtitles.count, name))
        }
      }.thenFlatMap { subtitle in
        subtitle.download()
      }
    }
  }

  static func logout(timeout: TimeInterval? = nil) {
    let id = Preference.string(for: .onlineSubProvider) ?? Providers.openSub.id
    switch id {
    case Providers.subDL.id:
      _logout(using: Providers.subDL, timeout: timeout)
    case Providers.openSub.id:
      _logout(using: Providers.openSub, timeout: timeout)
    case Providers.shooter.id:
      _logout(using: Providers.shooter, timeout: timeout)
    case Providers.assrt.id:
      _logout(using: Providers.assrt, timeout: timeout)
    default:
      guard let provider = Providers.fromPlugin[id] else {
        _logout(using: Providers.openSub, timeout: timeout)
        return
      }
      _logout(using: provider, timeout: timeout)
    }
  }

  fileprivate static func _logout<P: ProviderProtocol>(using provider: P, timeout: TimeInterval? = nil) {
    provider.getFetcher().logout(timeout: timeout).catch { err in
      let prefix = "Failed to log out of \(provider.name). "
      switch err {
      case CommonError.cannotConnect(let cause):
        log("\(prefix)\(cause.localizedDescription)", level: .error)
      case CommonError.networkError(let cause):
        let error = cause ?? err
        log("\(prefix)\(error.localizedDescription)", level: .error)
      case CommonError.timedOut(let cause):
        log("\(prefix)\(cause.localizedDescription)", level: .error)
      case JSPluginSub.Error.pluginError(let message):
        log("\(prefix)\(message)", level: .error)
      default:
        log("\(prefix)\(err.localizedDescription)", level: .error)
      }
    }.finally {
      NotificationCenter.default.post(Notification(name: .iinaLogoutCompleted, object: self))
    }
  }

  static func search(forFile url: URL, player: PlayerCore, providerID: String? = nil, callback: @escaping ([URL]) -> Void) {
    let id = providerID ?? Preference.string(for: .onlineSubProvider) ?? Providers.openSub.id
    switch id {
    case Providers.subDL.id:
      _search(using: Providers.subDL, forFile: url, player, callback)
    case Providers.openSub.id:
      _search(using: Providers.openSub, forFile: url, player, callback)
    case Providers.shooter.id:
      _search(using: Providers.shooter, forFile: url, player, callback)
    case Providers.assrt.id:
      _search(using: Providers.assrt, forFile: url, player, callback)
    default:
      if let provider = Providers.fromPlugin[id] {
        _search(using: provider, forFile: url, player, callback)
      } else {
        _search(using: Providers.openSub, forFile: url, player, callback)
      }
    }
  }

  fileprivate static func _search<P: ProviderProtocol>(using provider: P, forFile url: URL, _ player: PlayerCore, _ callback: @escaping ([URL]) -> Void) {
    log("Search subtitle from \(provider.name)...")
    player.sendOSD(.startFindingSub(provider.name), autoHide: false)
    let searchID = player.onlineSubtitleSearchID

    provider.fetchSubtitles(url: url, player: player).done {
      guard player.onlineSubtitleSearchID == searchID else { return }
      callback($0)
    }.ensure {
      guard player.onlineSubtitleSearchID == searchID else { return }
      player.hideOSD()
    }.catch { err in
      guard player.onlineSubtitleSearchID == searchID else { return }
      let osdMessage: OSDMessage
      let prefix = "Failed to obtain subtitles for \(url) from \(provider.name). "
      switch err {
      case CommonError.noResult:
        // Not an error.
        log("No subtitles found")
        callback([])
        return
      case CommonError.cannotConnect(let cause):
        osdMessage = .cannotConnect
        log("\(prefix)\(cause.localizedDescription)", level: .error)
      case CommonError.networkError(let cause):
        let error = cause ?? err
        osdMessage = osdMessageForDetailedError(error, fallback: .networkError, providerName: provider.name)
        log("\(prefix)\(error.localizedDescription)", level: .error)
      case CommonError.timedOut(let cause):
        osdMessage = .timedOut
        log("\(prefix)\(cause.localizedDescription)", level: .error)
      case OpenSubClient.Error.errorResponse(let response):
        osdMessage = osdMessageForOpenSubErrorResponse(response, fallback: .networkError, providerName: provider.name)
        log("\(prefix)\(response.message)", level: .error)
      case Shooter.Error.cannotReadFile(let cause),
           OpenSub.Error.cannotReadFile(let cause):
        osdMessage = .fileError
        log("\(prefix)Cannot get file handle. \(cause)", level: .error)
      case Shooter.Error.fileTooSmall(let minimumFileSize),
           OpenSub.Error.fileTooSmall(let minimumFileSize):
        osdMessage = .fileError
        log("\(prefix)File is too small. Minimum file size supported by the site is \(minimumFileSize)",
            level: .error)
      case OpenSub.Error.emptyFile(let reason):
        osdMessage = .fileError
        log("\(prefix)Invalid file, \(reason)", level: .error)
      case OpenSub.Error.loginFailed(let reason):
        osdMessage = .cannotLogin
        log("\(prefix)Login failed, \(reason)", level: .error)
      case SubDL.Error.missingAPIKey:
        osdMessage = .customWithDetail(err.localizedDescription, provider.name)
        log("\(prefix)SubDL API key has not been configured", level: .warning)
      case let subDLError as SubDL.Error:
        osdMessage = .customWithDetail(subDLError.localizedDescription, provider.name)
        log("\(prefix)\(subDLError.localizedDescription)", level: .warning)
      case JSPluginSub.Error.pluginError(let message):
        osdMessage = .customWithDetail(message, provider.name)
        log("\(prefix)\(message)", level: .error)
      case CommonError.canceled:
        osdMessage = .canceled
        // Not an error.
        log("User canceled download of subtitles")
      case CommonError.dismissed:
        // Operation dismissed by, for example, a plugin with custom implementation.
        log("Default subtitle search wokflow dismissed")
        player.isSearchingOnlineSubtitle = false
        player.onlineSubtitleSearchID = nil
        return
      default:
        osdMessage = .networkError
        log("\(prefix)\(err.localizedDescription)", level: .error)
      }
      let timeout: Float? = shouldExtendTimeout(for: osdMessage) ? 5 : nil
      player.sendOSD(osdMessage, forcedTimeout: timeout)
      player.isSearchingOnlineSubtitle = false
      player.onlineSubtitleSearchID = nil
    }
  }

  private static func osdMessageForOpenSubErrorResponse(_ response: OpenSubClient.ErrorResponse,
                                                        fallback: OSDMessage,
                                                        providerName: String) -> OSDMessage {
    guard providerName == Providers.openSub.name, response.remaining == -1 else { return fallback }
    let resetTime = response.resetTimeUtc.map {
      DateFormatter.localizedString(from: $0, dateStyle: .none, timeStyle: .short)
    }
    return .onlineSubQuotaExceeded(resetTime)
  }

  private static func osdMessageForDetailedError(_ error: Swift.Error,
                                                 fallback: OSDMessage,
                                                 providerName: String) -> OSDMessage {
    switch error {
    case OpenSubClient.Error.errorResponse(let response):
      return osdMessageForOpenSubErrorResponse(response, fallback: fallback, providerName: providerName)
    default:
      return fallback
    }
  }

  private static func shouldExtendTimeout(for osdMessage: OSDMessage) -> Bool {
    switch osdMessage {
    case .onlineSubQuotaExceeded:
      return true
    default:
      return false
    }
  }

  static func populateMenu(_ menu: NSMenu, action: Selector? = nil, insertSeparator: Bool = true) {
    let defaultProviders = [
      (Providers.subDL.name, Providers.subDL.id),
      (Providers.openSub.name, Providers.openSub.id),
      (Providers.assrt.name, Providers.assrt.id),
      (Providers.shooter.name, Providers.shooter.id)
    ]
    menu.removeAllItems()
    for (name, id) in defaultProviders {
      menu.addItem(withTitle: name, action: action, tag: nil, obj: id)
    }
    if insertSeparator {
      menu.addItem(.separator())
    }
    for (id, provider) in OnlineSubtitle.Providers.fromPlugin {
      guard case .plugin(_, let pluginName) = provider.origin else { break }
      menu.addItem(withTitle: provider.name + " — " + pluginName, action: action, tag: nil, obj: id)
    }
  }

  private static func log(_ message: @autoclosure () -> String, level: Logger.Level = .debug) {
    Logger.log(message, level: level, subsystem: Logger.Sub.onlinesub)
  }
}

extension Logger {
  struct Sub {
    static let onlinesub = Logger.makeSubsystem("onlinesub")
  }
}


// MARK: - Matching a search result against the current media

/// Scores how well an online subtitle's release name matches the media being played.
///
/// Only a score of `100` may trigger automatic download and selection, and it is awarded
/// conservatively. The release name is untrusted input — it is whatever name the uploader of a
/// remote subtitle chose — so a name-based comparison can never be treated as proof that a
/// subtitle belongs to a file. `100` therefore requires **all** of the following:
///
/// 1. Both names reduce to exactly the same title, token for token. Tokens are compared as a
///    sequence; comparing them with separators removed is not safe, because shifting a word
///    boundary by one character (`The.Matrix` vs `t.hematrix`) would then look like a match.
/// 2. Both names carry the same set of *identity anchors* — a release year, or an episode marker —
///    and that set is not empty. The anchors are read from the whole name, not from the reduced
///    title, so a release cannot escape comparison simply by omitting them.
/// 3. Neither name is empty after reduction.
///
/// Requirement 2 is what separates a remake from its original: `The.Thing.1982` and
/// `The.Thing.2011` share a title but not a year, so they never auto-select. It is also why a file
/// with no year and no episode marker in its name — `Movie.mkv` — is never auto-selected: with no
/// anchor there is nothing to corroborate the title with, and the title alone is not evidence.
///
/// A name-based check cannot be made proof against a deliberately crafted release name, because
/// `The.Matrix.1999.1080p.Sinners` is indistinguishable from a legitimate
/// `The.Matrix.1999.1080p.BluRay`. That is why automatic selection is opt-in, why the result is
/// still only ever a *default* the user can change, and why anything short of `100` is capped
/// below it.
enum SubtitleMatchScorer {

  /// Score of a result considered an exact match for the current media.
  static let perfectMatch = 100

  /// Longest name scored. Names arrive from a remote server and are otherwise unbounded, and every
  /// step below is linear in the token count, so this bounds the work a single result can cause.
  private static let maxNameLength = 4096

  /// File extensions that are stripped from a release name before comparing, so that `Movie.srt`
  /// and `Movie` compare equal. Only subtitle formats are stripped, which keeps titles containing
  /// a dot — `Dr. Strangelove` — intact.
  private static let subtitleExtensions: Set<String> = [
    "srt", "ass", "ssa", "sub", "vtt", "smi", "sami", "txt", "ttml", "dfxp", "mpl2", "jss", "epub",
  ]

  /// Tokens that begin the release-tag section of a name, i.e. that describe *how* a release was
  /// produced rather than *what* it is.
  ///
  /// Only the *first* such token matters for reducing a name to its title: everything from it
  /// onwards is discarded. That is what lets an arbitrary release group — `x264-NTb`, `x264-YIFY`,
  /// `x264-组` — be ignored without having to be enumerated.
  private static let releaseTagTokens: Set<String> = [
    // source
    "bluray", "blu", "brrip", "bdrip", "bdremux", "remux", "webrip", "webdl", "web", "dl", "rip",
    "hdtv", "pdtv", "dvdrip", "dvd", "dvdscr", "scr", "cam", "ts", "tc", "r5", "hc", "korsub",
    // video
    "x264", "x265", "h264", "h265", "hevc", "avc", "xvid", "divx", "vp9", "av1", "bit", "hi10p",
    "hdr", "hdr10", "dv", "dolby", "vision", "sdr",
    // audio
    "aac", "ac3", "eac3", "dd", "dts", "dtshd", "truehd", "atmos", "flac", "opus", "mp3", "lpcm",
    // edition
    "extended", "unrated", "remastered", "directors", "director", "cut", "proper", "repack",
    "internal", "limited", "complete", "season", "series", "collection", "anniversary",
    // provenance
    "multi", "dual", "subbed", "dubbed", "subs", "dubs", "retail", "imax", "sbs", "hsbs",
    "yify", "yts", "amzn", "nf", "hmax", "atvp", "criterion",
  ]

  /// Release tags that are not plain words, such as `1080p` or `4k`.
  private static let releaseTagPatterns = [
    #"^\d{3,4}[pi]$"#,  // 1080p, 576i
    #"^\d{3,4}$"#,      // 1080
    #"^\d+k$"#,         // 4k
    #"^(hd|sd|uhd|fhd|hd1080|hd720)$"#,
  ].compactMap { try? NSRegularExpression(pattern: $0) }

  /// Patterns for an episode marker, which identifies *which* episode a release belongs to.
  ///
  /// These are deliberately **not** release tags: an episode marker is part of the title, so it is
  /// always compared, and it doubles as an identity anchor. The first pattern also covers
  /// multi-episode releases such as `S01E01E02`; the dotted and hyphenated spellings that
  /// `tokenize` splits into separate `S01` / `E02` tokens are recombined by
  /// `normalizeEpisodeMarkers(_:)` before anything is compared.
  private static let episodePatterns = [
    #"^s\d+e\d+(e\d+)*$"#,  // S01E02, S01E01E02
    #"^\d+x\d+$"#,          // 1x02
  ].compactMap { try? NSRegularExpression(pattern: $0) }

  /// Season and episode halves, matched separately so that `S01.E02` and `S01-E02` can be
  /// recombined into the single anchor `s01e02`.
  private static let seasonPatterns = [
    #"^s\d+$"#,  // S01
  ].compactMap { try? NSRegularExpression(pattern: $0) }

  private static let episodeHalfPatterns = [
    #"^e\d+$"#,  // E02
  ].compactMap { try? NSRegularExpression(pattern: $0) }

  /// - Parameters:
  ///   - releaseName: The release the subtitle was authored for, e.g.
  ///     `Movie.2019.1080p.BluRay.x264-GROUP.srt`. Untrusted input.
  ///   - mediaName: The name of the media being played, without extension.
  /// - Returns: A score from `0` (no useful resemblance) to `100` (same title, same year or
  ///   episode), where only a `100` may trigger automatic selection.
  static func score(releaseName: String?, mediaName: String) -> Int {
    score(releaseName: releaseName, mediaTokens: prepareMediaName(mediaName))
  }

  static func prepareMediaName(_ mediaName: String) -> [String] {
    normalizeEpisodeMarkers(tokenize(clip(mediaName)))
  }

  static func score(releaseName: String?, mediaTokens: [String]) -> Int {
    guard let releaseName, !releaseName.isEmpty, !mediaTokens.isEmpty else { return 0 }
    let release = normalizeEpisodeMarkers(tokenize(clip(stripSubtitleExtension(from: releaseName))))
    let media = mediaTokens
    guard !release.isEmpty, !media.isEmpty else { return 0 }

    if isIdenticalTitleAndAnchor(release, media) { return perfectMatch }

    // Partial resemblance, used only to order and preselect in the chooser. Capped below
    // `perfectMatch` so it can never trigger automatic selection.
    //
    // A release whose title matches but whose anchor differs — a remake, or an extra year hiding a
    // different film — is ranked just below a real match rather than being lumped in with
    // unrelated results, so it still surfaces near the top for the user to judge.
    let shared = Set(media).intersection(release).count
    guard shared > 0 else { return 0 }
    var value = Int(((2.0 * Double(shared)) / Double(media.count + release.count) * 100).rounded())
    let releaseTitle = titleTokens(of: release)
    let mediaTitle = titleTokens(of: media)
    if releaseTitle == mediaTitle, !releaseTitle.isEmpty {
      value = max(value, 90)
    }
    return min(95, value)
  }

  /// Whether `release` and `media` describe the same title *and* agree on their identity anchors.
  private static func isIdenticalTitleAndAnchor(_ release: [String], _ media: [String]) -> Bool {
    let releaseTitle = titleTokens(of: release)
    let mediaTitle = titleTokens(of: media)
    // An empty title means the very first token was a release tag, which says nothing about the
    // title — the film "1917" reduces to nothing.
    guard !releaseTitle.isEmpty, !mediaTitle.isEmpty else { return false }
    // Compared as an ordered sequence. Joining the tokens instead would treat "The.Matrix" and
    // "t.hematrix" as equal, which is not a property worth having.
    guard releaseTitle == mediaTitle else { return false }
    // Release names are uploader-controlled. A real release tail contains technical tags and at
    // most one arbitrary release-group token; multiple unknown words after the first tag can be a
    // second title inserted after an otherwise matching filename.
    guard hasSafeReleaseTail(release) else { return false }
    // Read from the full names, so a release cannot dodge the comparison by leaving its year or
    // episode out, and so a second year or episode cannot be smuggled in after a release tag.
    let releaseAnchors = identityAnchors(in: release)
    let mediaAnchors = identityAnchors(in: media)
    return !mediaAnchors.isEmpty && releaseAnchors == mediaAnchors
  }

  private static func hasSafeReleaseTail(_ tokens: [String]) -> Bool {
    guard let firstTag = tokens.firstIndex(where: isReleaseTag) else { return true }
    var unclassifiedTokens = 0
    for token in tokens.dropFirst(firstTag + 1) where !isReleaseDetail(token) {
      unclassifiedTokens += 1
      if unclassifiedTokens > 1 { return false }
    }
    return true
  }

  private static func isReleaseDetail(_ token: String) -> Bool {
    if isReleaseTag(token) || ["h", "ddp5", "ddp7"].contains(token) { return true }
    // Channel-count fragments such as the `1` in `DDP5.1` are split out by `tokenize`.
    return token.count <= 2 && Int(token) != nil
  }

  /// The leading tokens of `tokens` that belong to the title, discarding the token that starts the
  /// release-tag section and everything after it.
  private static func titleTokens(of tokens: [String]) -> [String] {
    for (index, token) in tokens.enumerated() where isReleaseTag(token) {
      return Array(tokens[..<index])
    }
    return tokens
  }

  /// The years and episode markers appearing anywhere in `tokens`.
  private static func identityAnchors(in tokens: [String]) -> Set<String> {
    var anchors = Set<String>()
    for token in tokens where isYear(token) || isEpisodeMarker(token) {
      anchors.insert(token)
    }
    return anchors
  }

  /// Merge a season token immediately followed by an episode token, so that the three spellings of
  /// the same marker — `S01E02`, `S01.E02` and `S01-E02` — tokenize alike. Without this the two
  /// halves would sit in the title as separate tokens and never compare equal.
  ///
  /// Requiring the season to come first keeps a title that merely contains a word like `E2` from
  /// being rewritten.
  private static func normalizeEpisodeMarkers(_ tokens: [String]) -> [String] {
    var result: [String] = []
    var index = 0
    while index < tokens.count {
      if isSeasonMarker(tokens[index]), index + 1 < tokens.count, isEpisodeHalf(tokens[index + 1]) {
        result.append(tokens[index] + tokens[index + 1])
        index += 2
      } else {
        result.append(tokens[index])
        index += 1
      }
    }
    return result
  }

  private static func isReleaseTag(_ token: String) -> Bool {
    // An episode marker is never a release tag: it identifies the episode, so it belongs to the
    // title and must always be compared.
    if isEpisodeMarker(token) { return false }
    if releaseTagTokens.contains(token) { return true }
    if isYear(token) { return true }
    return matches(releaseTagPatterns, token)
  }

  private static func isYear(_ token: String) -> Bool {
    guard token.count == 4, let value = Int(token) else { return false }
    return (1900...2099).contains(value)
  }

  private static func isEpisodeMarker(_ token: String) -> Bool {
    matches(episodePatterns, token)
  }

  private static func isSeasonMarker(_ token: String) -> Bool {
    matches(seasonPatterns, token)
  }

  private static func isEpisodeHalf(_ token: String) -> Bool {
    matches(episodeHalfPatterns, token)
  }

  private static func matches(_ patterns: [NSRegularExpression], _ token: String) -> Bool {
    let range = NSRange(token.startIndex..., in: token)
    return patterns.contains { $0.firstMatch(in: token, range: range) != nil }
  }

  /// Strip a trailing subtitle extension, keeping the rest of the path intact.
  private static func stripSubtitleExtension(from name: String) -> String {
    let ext = (name as NSString).pathExtension.lowercased()
    guard subtitleExtensions.contains(ext) else { return name }
    return (name as NSString).deletingPathExtension
  }

  /// Truncate an over-long name so that scoring stays cheap.
  private static func clip(_ name: String) -> String {
    name.count > maxNameLength ? String(name.prefix(maxNameLength)) : name
  }

  /// Lowercase, drop diacritics, and split on everything that is not a letter or a digit.
  private static func tokenize(_ name: String) -> [String] {
    let folded = name.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                               locale: Locale(identifier: "en_US_POSIX"))
    let separated = String(folded.map { $0.isLetter || $0.isNumber ? $0 : " " })
    return separated.split(separator: " ").map(String.init)
  }
}
