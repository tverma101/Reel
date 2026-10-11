//
//  AppDelegate.swift
//  iina
//
//  Created by lhc on 8/7/16.
//  Copyright © 2016 lhc. All rights reserved.
//

import Cocoa
import CryptoKit
import Darwin
import MediaPlayer

let IINA_ENABLE_PLUGIN_SYSTEM = true

/** Max time interval for repeated `application(_:openFile:)` calls. */
fileprivate let OpenFileRepeatTime = TimeInterval(0.2)
/** Tags for "Open File/URL" menu item when "Always open file in new windows" is off. Vice versa. */
fileprivate let NormalMenuItemTag = 0
/** Tags for "Open File/URL in New Window" when "Always open URL" when "Open file in new windows" is off. Vice versa. */
fileprivate let AlternativeMenuItemTag = 1

/// A private, atomic acknowledgement that AppDelegate handed a managed resume
/// snapshot to PlayerCore.openURLs. This does not claim that mpv consumed it.
private enum TotalDramaPlaylistOpenAcknowledgement {
  private static let maximumPlaylistBytes: off_t = 4 * 1024 * 1024
  private static let maximumAcknowledgementBytes = 1_024
  private static let cacheURL = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Caches/TotalDramaPlayer", isDirectory: true)

  private struct SnapshotIdentity: Equatable {
    let device: Int64
    let inode: Int64
    let size: Int64
    let modifiedNanoseconds: Int64

    var jsonObject: [String: Int64] {
      ["dev": device, "ino": inode, "size": size, "mtime_ns": modifiedNanoseconds]
    }
  }

  private struct Request {
    let token: String
    let path: String
    let identity: SnapshotIdentity

    var acknowledgementPath: String {
      cacheURL.appendingPathComponent(".playlist-accepted-\(token).json").path
    }

    var data: Data? {
      let object: [String: Any] = [
        "version": 1,
        "token": token,
        "path": path,
        "snapshot": identity.jsonObject,
      ]
      return try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }
  }

  static func acknowledge(_ urls: [URL]) {
    for url in urls {
      guard let request = makeRequest(for: url), let data = request.data,
            data.count <= maximumAcknowledgementBytes else { continue }
      do {
        try publish(data, for: request)
      } catch {
        // The launcher fails closed when the matching acknowledgement is
        // absent or invalid; logging here keeps ordinary file opens quiet.
        NSLog("Could not publish managed playlist acceptance: %@", String(describing: error))
      }
    }
  }

  private static func makeRequest(for url: URL) -> Request? {
    guard url.isFileURL else { return nil }
    let standardizedCache = cacheURL.standardizedFileURL.path
    let pathURL = url.standardizedFileURL
    guard pathURL.deletingLastPathComponent().path == standardizedCache,
          cacheURL.resolvingSymlinksInPath().path == standardizedCache,
          let directory = lstatPath(standardizedCache), isPrivateDirectory(directory) else { return nil }
    let name = pathURL.lastPathComponent
    let prefix = "playlist-resume-"
    let suffix = ".m3u8"
    guard name.hasPrefix(prefix), name.hasSuffix(suffix) else { return nil }
    let token = String(name.dropFirst(prefix.count).dropLast(suffix.count))
    guard token.utf8.count == 8,
          token.utf8.allSatisfy({
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95
          }),
          let before = lstatPath(pathURL.path), isPrivatePlaylist(before) else { return nil }

    let descriptor = pathURL.path.withCString {
      Darwin.open($0, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
    }
    guard descriptor >= 0 else { return nil }
    defer { _ = Darwin.close(descriptor) }
    var opened = stat()
    guard Darwin.fstat(descriptor, &opened) == 0, isPrivatePlaylist(opened),
          snapshotIdentity(opened) == snapshotIdentity(before),
          let after = lstatPath(pathURL.path), isPrivatePlaylist(after),
          snapshotIdentity(after) == snapshotIdentity(opened) else {
      return nil
    }
    return Request(token: token, path: pathURL.path, identity: snapshotIdentity(opened))
  }

  private static func publish(_ data: Data, for request: Request) throws {
    guard let current = makeRequest(for: URL(fileURLWithPath: request.path)), current.token == request.token,
          current.identity == request.identity else {
      throw POSIXError(.ESTALE)
    }
    let destination = request.acknowledgementPath
    if let existing = try existingAcknowledgement(at: destination) {
      guard existing == data else { throw POSIXError(.EEXIST) }
      return // Duplicate openFile callbacks are idempotent.
    }

    var template = Array(cacheURL.appendingPathComponent(".playlist-accepted-tmp-XXXXXX").path.utf8CString)
    let descriptor = template.withUnsafeMutableBufferPointer { buffer in
      Darwin.mkstemp(buffer.baseAddress!)
    }
    guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    let temporaryPath = template.withUnsafeBufferPointer { buffer in
      String(cString: buffer.baseAddress!)
    }
    defer {
      _ = Darwin.close(descriptor)
      _ = temporaryPath.withCString { Darwin.unlink($0) }
    }
    guard Darwin.fchmod(descriptor, 0o600) == 0 else {
      throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    try writeAll(data, to: descriptor)
    guard Darwin.fsync(descriptor) == 0 else {
      throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    let linkResult = temporaryPath.withCString { source in
      destination.withCString { target in Darwin.link(source, target) }
    }
    if linkResult != 0 {
      let code = errno
      if code == EEXIST, try existingAcknowledgement(at: destination) == data { return }
      throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
    }
    // Drop the temporary hardlink immediately. The receiver requires a single
    // link before accepting the acknowledgement; while both names exist it
    // recognizes only this exact temp-name/inode publication window.
    guard temporaryPath.withCString({ Darwin.unlink($0) }) == 0 else {
      throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    let directoryDescriptor = standardizedCacheDescriptor()
    if directoryDescriptor >= 0 {
      // The complete, fsynced file is already atomically visible at its final
      // name. A directory fsync is best-effort on filesystems that support it.
      _ = Darwin.fsync(directoryDescriptor)
      _ = Darwin.close(directoryDescriptor)
    }
  }

  private static func writeAll(_ data: Data, to descriptor: Int32) throws {
    var offset = 0
    while offset < data.count {
      let count = data.count - offset
      let written = data.withUnsafeBytes { bytes in
        Darwin.write(descriptor, bytes.baseAddress!.advanced(by: offset), count)
      }
      if written < 0 {
        if errno == EINTR { continue }
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
      }
      guard written > 0 else { throw POSIXError(.EIO) }
      offset += written
    }
  }

  private static func existingAcknowledgement(at path: String) throws -> Data? {
    var before = stat()
    let lstatResult = path.withCString { Darwin.lstat($0, &before) }
    if lstatResult != 0 {
      if errno == ENOENT { return nil }
      throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    guard isPrivateRegularFile(before, maximumSize: Int64(maximumAcknowledgementBytes)), before.st_size > 0 else {
      throw POSIXError(.EPERM)
    }
    let descriptor = path.withCString { Darwin.open($0, O_RDONLY | O_NOFOLLOW | O_NONBLOCK) }
    guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    defer { _ = Darwin.close(descriptor) }
    var opened = stat()
    guard Darwin.fstat(descriptor, &opened) == 0,
          isPrivateRegularFile(opened, maximumSize: Int64(maximumAcknowledgementBytes)),
          sameFileVersion(before, opened) else { throw POSIXError(.ESTALE) }
    let count = Int(opened.st_size)
    var bytes = [UInt8](repeating: 0, count: count)
    var offset = 0
    while offset < count {
      let remaining = count - offset
      let readCount = bytes.withUnsafeMutableBytes { buffer in
        Darwin.read(descriptor, buffer.baseAddress!.advanced(by: offset), remaining)
      }
      if readCount < 0 {
        if errno == EINTR { continue }
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
      }
      guard readCount > 0 else { throw POSIXError(.EIO) }
      offset += readCount
    }
    var after = stat()
    guard Darwin.fstat(descriptor, &after) == 0, sameFileVersion(opened, after),
          let pathAfter = lstatPath(path), sameFileVersion(after, pathAfter) else {
      throw POSIXError(.ESTALE)
    }
    return Data(bytes)
  }

  private static func standardizedCacheDescriptor() -> Int32 {
    cacheURL.path.withCString {
      Darwin.open($0, O_RDONLY | O_NOFOLLOW | O_DIRECTORY)
    }
  }

  private static func lstatPath(_ path: String) -> stat? {
    var value = stat()
    let result = path.withCString { Darwin.lstat($0, &value) }
    return result == 0 ? value : nil
  }

  private static func isPrivateDirectory(_ value: stat) -> Bool {
    (value.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR)
      && value.st_uid == uid_t(getuid())
      && (value.st_mode & 0o077) == 0
  }

  private static func isPrivatePlaylist(_ value: stat) -> Bool {
    isPrivateRegularFile(value, maximumSize: Int64(maximumPlaylistBytes))
      && value.st_size > 0
  }

  private static func isPrivateRegularFile(_ value: stat, maximumSize: Int64) -> Bool {
    (value.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG)
      && value.st_uid == uid_t(getuid())
      && value.st_nlink == 1
      && (value.st_mode & 0o077) == 0
      && (value.st_mode & 0o600) == 0o600
      && value.st_size >= 0
      && value.st_size <= maximumSize
  }

  private static func snapshotIdentity(_ value: stat) -> SnapshotIdentity {
    SnapshotIdentity(
      device: Int64(value.st_dev),
      inode: Int64(value.st_ino),
      size: Int64(value.st_size),
      modifiedNanoseconds: Int64(value.st_mtimespec.tv_sec) * 1_000_000_000
        + Int64(value.st_mtimespec.tv_nsec)
    )
  }

  private static func sameFileVersion(_ lhs: stat, _ rhs: stat) -> Bool {
    lhs.st_dev == rhs.st_dev && lhs.st_ino == rhs.st_ino && lhs.st_size == rhs.st_size
      && lhs.st_mtimespec.tv_sec == rhs.st_mtimespec.tv_sec
      && lhs.st_mtimespec.tv_nsec == rhs.st_mtimespec.tv_nsec
  }
}


enum BundledAirPlayPluginUpdateResult {
  case updated(permissionsChanged: Bool)
  case unavailable
  case failed
}

// BEGIN AIRPLAY PACKAGE INTEGRITY SUPPORT
enum BundledAirPlayPluginUpdateCheckResult: Equatable {
  case current
  case updateAvailable
  case notManaged
  case newerThanBundle
  case unrepairableNewer
  case unavailable
  case stale
}

/// Shared scheduler for expensive package extraction and recursive file cleanup.
/// Model changes still return to the main queue before touching plugin instances.
enum AirPlayPackageBackgroundWork {
  static func perform(_ operation: @escaping () -> Void) {
    DispatchQueue.global(qos: .utility).async(execute: operation)
  }
}

/// Package updates only move the plugin root. Its identifier-keyed preferences/data and saved
/// plugin order live beside the package and must not be part of the directory transaction.
enum AirPlayPluginUpdatePreservation {
  enum MoveError: Error {
    case outsidePluginDirectory
  }

  static func movePackageDirectory(from source: URL, to destination: URL,
                                   under pluginsDirectory: URL,
                                   fileManager: FileManager = .default) throws {
    let pluginsRoot = pluginsDirectory.standardizedFileURL
    guard source.standardizedFileURL.deletingLastPathComponent() == pluginsRoot,
          destination.standardizedFileURL.deletingLastPathComponent() == pluginsRoot else {
      throw MoveError.outsidePluginDirectory
    }
    try fileManager.moveItem(at: source, to: destination)
  }

  static func replacing<T>(_ elements: [T], at index: Int, with replacement: T) -> [T]? {
    guard elements.indices.contains(index) else { return nil }
    var result = elements
    result[index] = replacement
    return result
  }

  static func shouldRemainEnabled(wasEnabled: Bool, previousPermissions: Set<String>,
                                  updatedPermissions: Set<String>) -> Bool {
    wasEnabled && previousPermissions == updatedPermissions
  }
}

/// Hashes only the two executable payloads, using bounded chunks and requiring
/// regular executable files. Kept independent of the plugin model so the exact
/// checker can be exercised with synthetic package trees.
enum AirPlayPackageIntegrity {
  static let helperPath = "bin/airplay-helper"
  static let ffmpegPath = "bin/ffmpeg"
  private static let corePackageEntryPaths = ["Info.json", "main.js", "sidebar.html", "bin/VERSIONS"]
  private static let requiredPaths = [helperPath, ffmpegPath]

  static func packageEntryPaths(forManifestData data: Data) -> [String]? {
    guard let manifest = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
    var paths = corePackageEntryPaths
    if let preferencesPage = manifest["preferencesPage"] as? String,
       !preferencesPage.hasPrefix("http://"), !preferencesPage.hasPrefix("https://") {
      guard isSafePackageEntryPath(preferencesPage) else { return nil }
      if !paths.contains(preferencesPage) { paths.append(preferencesPage) }
    }
    return paths
  }

  static func matchesPackageEntries(at root: URL, expectedFiles: [String: Data]) -> Bool {
    expectedFiles.allSatisfy { path, expected in
      guard let actual = try? Data(contentsOf: root.appendingPathComponent(path), options: .mappedIfSafe) else {
        return false
      }
      return actual == expected
    }
  }

  /// Verifies the staged files and both executable payloads before a bundled package is installed
  /// or replaces an existing package. Keep this check shared by first install, migration, and update.
  static func matchesPackageSnapshot(at root: URL, expectedFiles: [String: Data],
                                    expectedDigests: [String: String]) -> Bool {
    matchesPackageEntries(at: root, expectedFiles: expectedFiles)
      && matchesExecutables(at: root, expectedDigests: expectedDigests)
  }

  static func parseVersions(_ data: Data) -> [String: String]? {
    guard let text = String(data: data, encoding: .utf8) else { return nil }
    var values: [String: String] = [:]
    for rawLine in text.split(whereSeparator: \.isNewline) {
      let line = String(rawLine)
      guard let separator = line.firstIndex(of: "=") else { return nil }
      let key = line[..<separator].trimmingCharacters(in: .whitespaces)
      let value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespaces)
      guard !key.isEmpty, !value.isEmpty, values[key] == nil else { return nil }
      values[key] = value
    }

    guard let helperDigest = values["helper_sha256"], isSHA256Digest(helperDigest),
          let ffmpegDigest = values["ffmpeg_sha256"], isSHA256Digest(ffmpegDigest) else {
      return nil
    }
    return [helperPath: helperDigest, ffmpegPath: ffmpegDigest]
  }

  static func matchesExecutables(at root: URL, expectedDigests: [String: String]) -> Bool {
    guard Set(expectedDigests.keys) == Set(requiredPaths),
          requiredPaths.allSatisfy({ path in
            guard let expected = expectedDigests[path], isSHA256Digest(expected) else { return false }
            let url = root.appendingPathComponent(path)
            guard isRegularExecutableFile(at: url), let actual = sha256(fileAt: url) else { return false }
            return actual == expected
          }) else { return false }
    return true
  }

  static func verifiedNewerInstallStatus(at root: URL,
                                         versionsData: Data?) -> BundledAirPlayPluginUpdateCheckResult {
    guard let versionsData,
          let expectedDigests = parseVersions(versionsData),
          matchesExecutables(at: root, expectedDigests: expectedDigests) else {
      return .unrepairableNewer
    }
    return .newerThanBundle
  }

  static func sha256(fileAt url: URL) -> String? {
    guard let file = try? FileHandle(forReadingFrom: url) else { return nil }
    defer { try? file.close() }
    var hasher = SHA256()
    do {
      while let chunk = try file.read(upToCount: 1 << 20), !chunk.isEmpty {
        hasher.update(data: chunk)
      }
    } catch {
      return nil
    }
    return hasher.finalize().map { String(format: "%02x", Int($0)) }.joined()
  }

  private static func isRegularExecutableFile(at url: URL) -> Bool {
    guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
          attributes[.type] as? FileAttributeType == .typeRegular,
          let permissions = (attributes[.posixPermissions] as? NSNumber)?.intValue else {
      return false
    }
    // Managed package files are owned by the current user, so the owner's execute
    // bit is the permission the app relies on when launching these payloads.
    return permissions & 0o100 != 0
  }

  private static func isSHA256Digest(_ value: String) -> Bool {
    let bytes = value.utf8
    return bytes.count == 64 && bytes.allSatisfy {
      (48...57).contains($0) || (97...102).contains($0)
    }
  }

  private static func isSafePackageEntryPath(_ path: String) -> Bool {
    guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\\") else { return false }
    let components = path.split(separator: "/", omittingEmptySubsequences: false)
    return !components.isEmpty && components.allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
  }
}

/// Invalidates older asynchronous package checks when the Plugins sidebar
/// starts a newer one. Calls are made on the main thread by the view controller.
final class AirPlayPackageCheckGeneration {
  private(set) var value: UInt64 = 0

  func begin() -> UInt64 {
    value &+= 1
    return value
  }

  func isCurrent(_ generation: UInt64) -> Bool {
    generation == value
  }
}
// END AIRPLAY PACKAGE INTEGRITY SUPPORT

/// Installs Reel's pinned AirPlay package and offers explicit updates for managed installs.
/// Existing packages are never replaced at launch; their preferences and data live outside the
/// package directory and remain keyed by the stable plugin identifier.
enum BundledAirPlayPluginManager {
  static let identifier = "dev.faruk.iina-airplay"
  private static let officialRepository = "ozykhan/iina-airplay"

  enum LegacyMigrationIssue: Equatable {
    case helperMayBeRunning
    case updateUnavailable
  }

  private static let coldStartGate = PluginContextStartupGate()
  private(set) static var coldStartMigrationPending = false
  private(set) static var legacyMigrationIssue: LegacyMigrationIssue?
  private static let coldStartMigrationLock = NSLock()
  private static var coldStartMigrationGeneration: UInt64 = 0

  private static func beginColdStartMigrationGeneration() -> UInt64 {
    coldStartMigrationLock.lock()
    coldStartMigrationGeneration &+= 1
    let generation = coldStartMigrationGeneration
    coldStartMigrationLock.unlock()
    coldStartMigrationPending = true
    return generation
  }

  private static func isColdStartMigrationCurrent(_ generation: UInt64) -> Bool {
    coldStartMigrationLock.lock()
    defer { coldStartMigrationLock.unlock() }
    return coldStartMigrationGeneration == generation
  }

  private struct PackageSnapshot {
    let version: String
    let permissions: Set<String>
    let files: [String: Data]
    let binaryDigests: [String: String]

    func matches(at root: URL) -> Bool {
      AirPlayPackageIntegrity.matchesPackageSnapshot(
        at: root, expectedFiles: files, expectedDigests: binaryDigests
      )
    }
  }

  private struct ParsedVersion: Comparable {
    let major: Int
    let minor: Int
    let patch: Int
    let reelRevision: Int?

    static func < (lhs: ParsedVersion, rhs: ParsedVersion) -> Bool {
      if lhs.major != rhs.major { return lhs.major < rhs.major }
      if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
      if lhs.patch != rhs.patch { return lhs.patch < rhs.patch }
      switch (lhs.reelRevision, rhs.reelRevision) {
      case (nil, nil): return false
      case (nil, .some): return true
      case (.some, nil): return false
      case let (.some(lhsRevision), .some(rhsRevision)): return lhsRevision < rhsRevision
      }
    }
  }

  // Core runtime entries plus any locally declared plugin preferences page identify this package.
  // Helper and FFmpeg bytes are streamed through SHA-256 off-main.
  private static let packageSnapshot: PackageSnapshot? = loadPackageSnapshot()

  private static var bundledPackageURL: URL? {
    Bundle.main.resourceURL?.appendingPathComponent("plugins/iina-airplay.iinaplgz")
  }

  /// Installs a new copy when no package is present. A narrowly recognized official 0.4.0 / gh
  /// release-6 package is migrated before applicationDidFinishLaunching creates player contexts;
  /// external, developer, and unknown packages remain untouched.
  static func installIfNeeded() {
    guard let packageURL = bundledPackageURL,
          FileManager.default.fileExists(atPath: packageURL.path) else { return }

    let migrationKey = FirstRunManager.Key("installedBundledAirPlayPlugin")
    let migrationMarker = Utility.appSupportDirUrl.appendingPathComponent(".\(migrationKey.rawValue)")
    if let installed = JavascriptPlugin.plugins.first(where: { $0.identifier == identifier }) {
      if isRecognizedLegacyOfficialInstall(installed) {
        beginColdStartMigration(of: installed, packageURL: packageURL, migrationKey: migrationKey)
        return
      }
      // Preserve unknown/current installs; this marker is only for the first-install path.
      _ = FirstRunManager.isFirstRun(for: migrationKey)
      Logger.log("Bundled AirPlay plugin ID is already installed; preserving its package and state")
      return
    }

    guard !FileManager.default.fileExists(atPath: migrationMarker.path) else { return }

    AirPlayPackageBackgroundWork.perform {
      do {
        let stagedRoot = try extractPackageToStagingDirectory(from: packageURL)
        guard let packageSnapshot, packageSnapshot.matches(at: stagedRoot) else {
          removeStagingDirectory(stagedRoot)
          Logger.log("Staged bundled AirPlay package failed integrity validation", level: .error)
          return
        }
        DispatchQueue.main.async {
          guard !JavascriptPlugin.plugins.contains(where: { $0.identifier == identifier }) else {
            // Another installer won while the archive was being extracted. Keep its state and
            // mark this one-time migration handled without replacing it.
            _ = FirstRunManager.isFirstRun(for: migrationKey)
            removeStagingDirectoryInBackground(stagedRoot)
            return
          }
          guard let plugin = JavascriptPlugin(filename: stagedRoot.lastPathComponent),
                plugin.identifier == identifier else {
            removeStagingDirectoryInBackground(stagedRoot)
            Logger.log("Unable to load staged bundled AirPlay plugin", level: .error)
            return
          }
          do {
            try installNewPackage(plugin)
            // Write the marker only after the filesystem/model transaction commits. Extraction
            // or a failed install can retry on the next launch.
            _ = FirstRunManager.isFirstRun(for: migrationKey)
            Logger.log("Installed bundled AirPlay plugin disabled pending permission approval")
          } catch {
            removeStagingDirectoryInBackground(stagedRoot)
            Logger.log("Unable to install bundled AirPlay plugin: \(error.localizedDescription)", level: .error)
          }
        }
      } catch {
        Logger.log("Unable to stage bundled AirPlay plugin: \(error.localizedDescription)", level: .error)
      }
    }
  }

  /// Queues AppKit's did-finish launch work only while the recognized cold-start package migration
  /// is in flight. The callback is run on main after the old package is either safely replaced or
  /// deliberately retained.
  @discardableResult
  static func continueLaunchWhenMigrationSettles(_ completion: @escaping () -> Void) -> Bool {
    coldStartGate.continueWhenOpen(completion)
  }

  private static func isRecognizedLegacyOfficialInstall(_ plugin: JavascriptPlugin) -> Bool {
    guard isManagedInstall(plugin),
          plugin.githubRepo == officialRepository,
          plugin.githubVersion == 6,
          plugin.version == "0.4.0",
          parseVersion(plugin.version) != nil else { return false }
    return true
  }

  private static func beginColdStartMigration(of installed: JavascriptPlugin,
                                               packageURL: URL,
                                               migrationKey: FirstRunManager.Key) {
    guard !coldStartMigrationPending else { return }
    let identity = ObjectIdentifier(installed)
    let originalRoot = installed.root.standardizedFileURL
    let originalVersion = installed.version
    let generation = beginColdStartMigrationGeneration()
    legacyMigrationIssue = nil
    coldStartGate.close()

    // Let startup continue if package inspection stalls. A generation check makes a late worker
    // cleanup-only, so it cannot replace the package after this timeout.
    DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 45) {
      finishColdStartMigration(generation: generation, issue: .updateUnavailable,
                               message: "AirPlay cold-start migration timed out; the installed package was retained")
    }

    AirPlayPackageBackgroundWork.perform {
      let stagedRoot: URL
      do {
        stagedRoot = try extractPackageToStagingDirectory(from: packageURL)
      } catch {
        finishColdStartMigration(generation: generation, issue: .updateUnavailable,
                                 message: "Unable to stage the bundled AirPlay plugin: \(error.localizedDescription)")
        return
      }

      guard isColdStartMigrationCurrent(generation) else {
        removeStagingDirectory(stagedRoot)
        return
      }

      guard let packageSnapshot,
            let legacyVersion = parseVersion(originalVersion),
            let bundledVersion = parseVersion(packageSnapshot.version),
            legacyVersion < bundledVersion,
            packageSnapshot.matches(at: stagedRoot) else {
        removeStagingDirectory(stagedRoot)
        finishColdStartMigration(generation: generation, issue: .updateUnavailable,
                                 message: "The staged AirPlay package failed integrity validation")
        return
      }

      guard probeLegacyAirPlayRuntimeIsInactive(packageRoot: originalRoot) else {
        removeStagingDirectory(stagedRoot)
        finishColdStartMigration(generation: generation, issue: .helperMayBeRunning,
                                 message: "An AirPlay helper is active or could not be checked; retaining the installed package")
        return
      }

      DispatchQueue.main.async {
        guard isColdStartMigrationCurrent(generation) else {
          removeStagingDirectoryInBackground(stagedRoot)
          return
        }
        guard ObjectIdentifier(installed) == identity,
              installed.root.standardizedFileURL == originalRoot,
              installed.version == originalVersion,
              JavascriptPlugin.plugins.contains(where: { $0 === installed }),
              isManagedInstall(installed),
              isRecognizedLegacyOfficialInstall(installed),
              !PlayerCore.hasAnyPluginContext(identifier: identifier) else {
          removeStagingDirectoryInBackground(stagedRoot)
          finishColdStartMigration(generation: generation, issue: .updateUnavailable,
                                   message: "AirPlay changed during cold-start migration; retaining the installed package")
          return
        }
        guard let candidate = JavascriptPlugin(filename: stagedRoot.lastPathComponent),
              candidate.identifier == identifier,
              candidate.version == packageSnapshot.version,
              Set(candidate.permissions.map(\.rawValue)) == packageSnapshot.permissions else {
          removeStagingDirectoryInBackground(stagedRoot)
          finishColdStartMigration(generation: generation, issue: .updateUnavailable,
                                   message: "The staged AirPlay manifest failed validation")
          return
        }

        let result = replace(installed, with: candidate)
        switch result {
        case .updated(_):
          _ = FirstRunManager.isFirstRun(for: migrationKey)
          Logger.log("Migrated the recognized official AirPlay package before loading player contexts")
          finishColdStartMigration(generation: generation, issue: nil, message: nil)
        case .unavailable, .failed:
          removeStagingDirectoryInBackground(stagedRoot)
          finishColdStartMigration(generation: generation, issue: .updateUnavailable,
                                   message: "Cold-start AirPlay replacement failed; the previous package was retained")
        }
      }
    }
  }

  private static func finishColdStartMigration(generation: UInt64,
                                               issue: LegacyMigrationIssue?, message: String?) {
    let finish = {
      coldStartMigrationLock.lock()
      guard coldStartMigrationGeneration == generation else {
        coldStartMigrationLock.unlock()
        return
      }
      coldStartMigrationGeneration &+= 1
      coldStartMigrationLock.unlock()
      legacyMigrationIssue = issue
      coldStartMigrationPending = false
      if let message {
        Logger.log(message, level: issue == nil ? .debug : .warning)
      }
      coldStartGate.open()
    }
    if Thread.isMainThread {
      finish()
    } else {
      DispatchQueue.main.async(execute: finish)
    }
  }

  /// Uses the macOS process table and the plugin temp directory without signaling or modifying
  /// anything. A package swap is permitted only when the complete bounded PID snapshot succeeds,
  /// no matching helper/FFmpeg process exists, and the existing HLS path is not a symlink or an
  /// unexpected file type. Old output files are deliberately left in place.
  private static func probeLegacyAirPlayRuntimeIsInactive(packageRoot: URL) -> Bool {
    let tempRoot = Utility.tempDirURL.appendingPathComponent("iina-\(identifier)", isDirectory: true)
    let hlsRoot = tempRoot.appendingPathComponent("hls", isDirectory: true)
    if FileManager.default.fileExists(atPath: hlsRoot.path) {
      guard let values = try? hlsRoot.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
            values.isDirectory == true, values.isSymbolicLink != true else { return false }
    }

    let maxProcessCount = 16_384
    var pids = [pid_t](repeating: 0, count: maxProcessCount)
    let bytes = pids.withUnsafeMutableBytes { buffer in
      proc_listpids(UInt32(PROC_ALL_PIDS), 0, buffer.baseAddress, Int32(buffer.count))
    }
    let byteCount = Int(bytes)
    guard byteCount > 0, byteCount < pids.count * MemoryLayout<pid_t>.size else { return false }
    let count = byteCount / MemoryLayout<pid_t>.size
    let expectedExecutables = ["bin/airplay-helper", "bin/ffmpeg"].map {
      packageRoot.appendingPathComponent($0).standardizedFileURL.resolvingSymlinksInPath().path
    }
    var pathBuffer = [CChar](repeating: 0, count: 4096)
    for pid in pids.prefix(count) where pid > 0 {
      let pathLength = pathBuffer.withUnsafeMutableBufferPointer { buffer in
        proc_pidpath(pid, buffer.baseAddress, UInt32(buffer.count))
      }
      guard pathLength > 0 else { continue }
      let processPath = String(cString: pathBuffer)
      let resolvedPath = URL(fileURLWithPath: processPath).standardizedFileURL.resolvingSymlinksInPath().path
      if expectedExecutables.contains(resolvedPath) { return false }
    }
    return true
  }

  /// Hash checks run on a utility queue. The callback always returns on main and
  /// reports stale if the installed plugin changed while the bytes were read.
  static func checkUpdateAvailability(for plugin: JavascriptPlugin,
                                      completion: @escaping (BundledAirPlayPluginUpdateCheckResult) -> Void) {
    let pluginRoot = plugin.root.standardizedFileURL
    let pluginVersion = plugin.version
    let managed = isManagedInstall(plugin)
    let identity = ObjectIdentifier(plugin)

    AirPlayPackageBackgroundWork.perform {
      let result = assessUpdate(root: pluginRoot, version: pluginVersion, isManaged: managed)
      DispatchQueue.main.async {
        guard ObjectIdentifier(plugin) == identity,
              plugin.root.standardizedFileURL == pluginRoot,
              plugin.version == pluginVersion,
              JavascriptPlugin.plugins.contains(where: { $0 === plugin }) else {
          completion(.stale)
          return
        }
        completion(result)
      }
    }
  }

  /// Package extraction runs off the main thread. The directory swap and plugin reload happen on
  /// the main thread so the host's unload callbacks run before the old package is moved.
  static func update(_ plugin: JavascriptPlugin,
                     completion: @escaping (BundledAirPlayPluginUpdateResult) -> Void) {
    let installedRoot = plugin.root.standardizedFileURL
    let installedVersion = plugin.version
    let identity = ObjectIdentifier(plugin)
    let managed = isManagedInstall(plugin)

    AirPlayPackageBackgroundWork.perform {
      do {
        guard managed, assessUpdate(root: installedRoot, version: installedVersion, isManaged: managed) == .updateAvailable,
              let packageURL = bundledPackageURL,
              let packageSnapshot else {
          DispatchQueue.main.async { completion(.unavailable) }
          return
        }
        let stagedRoot = try extractPackageToStagingDirectory(from: packageURL)
        guard packageSnapshot.matches(at: stagedRoot) else {
          removeStagingDirectory(stagedRoot)
          Logger.log("Staged AirPlay package failed integrity validation", level: .error)
          DispatchQueue.main.async { completion(.failed) }
          return
        }
        DispatchQueue.main.async {
          guard ObjectIdentifier(plugin) == identity,
                plugin.root.standardizedFileURL == installedRoot,
                plugin.version == installedVersion,
                JavascriptPlugin.plugins.contains(where: { $0 === plugin }),
                isManagedInstall(plugin) else {
            removeStagingDirectoryInBackground(stagedRoot)
            completion(.unavailable)
            return
          }
          guard let candidate = JavascriptPlugin(filename: stagedRoot.lastPathComponent),
                candidate.identifier == identifier,
                candidate.version == packageSnapshot.version,
                Set(candidate.permissions.map(\.rawValue)) == packageSnapshot.permissions else {
            removeStagingDirectoryInBackground(stagedRoot)
            Logger.log("Staged AirPlay package manifest failed validation", level: .error)
            completion(.failed)
            return
          }
          PlayerCore.acquirePluginUnloadPermit(identifier: identifier) { unloadResult in
            switch unloadResult {
            case .success(let permit):
              let result = replace(plugin, with: candidate)
              permit.release()
              completion(result)
            case .failure(let error):
              removeStagingDirectoryInBackground(stagedRoot)
              Logger.log("Unable to stop the installed AirPlay plugin before update: \(error.localizedDescription)",
                         level: .error)
              if let unloadError = error as? EventController.AsyncEventError,
                 case .missingListener(let missingIdentifier) = unloadError,
                 missingIdentifier == identifier {
                AppDelegate.shared.presentPluginLifecycleFailure(error)
              }
              completion(.failed)
            }
          }
        }
      } catch {
        Logger.log("Unable to stage bundled AirPlay update: \(error.localizedDescription)", level: .error)
        DispatchQueue.main.async { completion(.failed) }
      }
    }
  }

  private enum InstallerError: Error {
    case unexpectedIdentifier(String)
    case cannotChooseDestination
    case cannotRebasePlugin
    case cannotExtractPackage
    case extractorDidNotExit
  }

  private final class ProcessTerminationSignal {
    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private var didExit = false
    private var deferredCleanup: (() -> Void)?

    func markExited() {
      lock.lock()
      didExit = true
      let cleanup = deferredCleanup
      deferredCleanup = nil
      lock.unlock()
      semaphore.signal()
      if let cleanup {
        DispatchQueue.global(qos: .utility).async(execute: cleanup)
      }
    }

    func wait(until deadline: DispatchTime) -> Bool {
      semaphore.wait(timeout: deadline) == .success
    }

    /// Returns true if exit already happened and the caller should run cleanup now.
    func cleanupAfterExit(_ cleanup: @escaping () -> Void) -> Bool {
      lock.lock()
      if didExit {
        lock.unlock()
        return true
      }
      deferredCleanup = cleanup
      lock.unlock()
      return false
    }
  }

  private static func runExtractor(_ process: Process, timeout: TimeInterval,
                                   cleanupIfUnreaped: @escaping () -> Void) throws {
    let signal = ProcessTerminationSignal()
    process.terminationHandler = { _ in signal.markExited() }
    try process.run()
    guard !signal.wait(until: .now() + timeout) else { return }

    process.terminate()
    if signal.wait(until: .now() + 2) {
      throw InstallerError.cannotExtractPackage
    }
    if process.isRunning {
      _ = Darwin.kill(process.processIdentifier, SIGKILL)
    }
    if signal.wait(until: .now() + 3) {
      throw InstallerError.cannotExtractPackage
    }

    // Do not race a still-writing child by deleting its directories. It will clean them after
    // termination; if it never exits, keeping a hidden staging tree is safer than mutating it.
    if signal.cleanupAfterExit(cleanupIfUnreaped) {
      cleanupIfUnreaped()
    }
    throw InstallerError.extractorDidNotExit
  }

  private static func loadPackageSnapshot() -> PackageSnapshot? {
    guard let packageURL = bundledPackageURL,
          FileManager.default.fileExists(atPath: packageURL.path),
          let infoData = readArchiveEntry("Info.json", from: packageURL),
          let packageEntryPaths = AirPlayPackageIntegrity.packageEntryPaths(forManifestData: infoData) else { return nil }
    var files: [String: Data] = ["Info.json": infoData]
    for path in packageEntryPaths where path != "Info.json" {
      guard let data = readArchiveEntry(path, from: packageURL) else { return nil }
      files[path] = data
    }
    guard let manifest = try? JSONSerialization.jsonObject(with: infoData) as? [String: Any],
          manifest["identifier"] as? String == identifier,
          let version = manifest["version"] as? String,
          let permissionsList = manifest["permissions"] as? [String],
          let versionsData = files["bin/VERSIONS"],
          let binaryDigests = AirPlayPackageIntegrity.parseVersions(versionsData) else { return nil }
    let permissions = Set(permissionsList)
    return PackageSnapshot(version: version, permissions: permissions, files: files,
                           binaryDigests: binaryDigests)
  }

  private static func assessUpdate(root: URL, version: String,
                                  isManaged: Bool) -> BundledAirPlayPluginUpdateCheckResult {
    guard isManaged else { return .notManaged }
    guard let packageSnapshot,
          let currentVersion = parseVersion(version),
          let bundledVersion = parseVersion(packageSnapshot.version) else { return .unavailable }
    if bundledVersion < currentVersion {
      let versionsURL = root.appendingPathComponent("bin/VERSIONS")
      return AirPlayPackageIntegrity.verifiedNewerInstallStatus(
        at: root,
        versionsData: try? Data(contentsOf: versionsURL)
      )
    }
    if currentVersion < bundledVersion { return .updateAvailable }
    return packageSnapshot.matches(at: root) ? .current : .updateAvailable
  }

  private static func readArchiveEntry(_ path: String, from packageURL: URL) -> Data? {
    let process = Process()
    let outputURL = Utility.tempDirURL.appendingPathComponent(".airplay-entry-\(UUID().uuidString)")
    guard FileManager.default.createFile(atPath: outputURL.path, contents: nil),
          let output = try? FileHandle(forWritingTo: outputURL) else { return nil }
    process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
    process.arguments = ["-p", packageURL.path, path]
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice
    let cleanup = {
      try? output.close()
      try? FileManager.default.removeItem(at: outputURL)
    }
    do {
      try runExtractor(process, timeout: 10, cleanupIfUnreaped: cleanup)
      try output.close()
      let data = try Data(contentsOf: outputURL, options: .mappedIfSafe)
      try? FileManager.default.removeItem(at: outputURL)
      return process.terminationStatus == 0 ? data : nil
    } catch {
      if let installerError = error as? InstallerError,
         case .extractorDidNotExit = installerError {
        return nil // termination handler owns deferred cleanup
      }
      cleanup()
      Logger.log("Unable to inspect bundled AirPlay package: \(error.localizedDescription)", level: .error)
      return nil
    }
  }

  /// Unzips the bundled archive on a utility queue without constructing or mutating a plugin
  /// model there. The caller creates `JavascriptPlugin` from this completed tree on main.
  private static func extractPackageToStagingDirectory(from packageURL: URL) throws -> URL {
    let fileManager = FileManager.default
    let pluginsRoot = Utility.pluginsURL
    let stagingName = ".temp.\(UUID().uuidString)"
    let stagingRoot = pluginsRoot.appendingPathComponent(stagingName, isDirectory: true)
    let extractionRoot = pluginsRoot.appendingPathComponent("\(stagingName)-extract", isDirectory: true)
    do {
      try fileManager.createDirectory(at: stagingRoot, withIntermediateDirectories: false)
      try fileManager.createDirectory(at: extractionRoot, withIntermediateDirectories: false)
      let process = Process()
      process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
      process.arguments = ["-q", packageURL.path, "-d", extractionRoot.path]
      process.standardOutput = FileHandle.nullDevice
      process.standardError = FileHandle.nullDevice
      try runExtractor(process, timeout: 35) {
        removeStagingDirectory(stagingRoot)
        removeStagingDirectory(extractionRoot)
      }
      guard process.terminationStatus == 0 else { throw InstallerError.cannotExtractPackage }

      let entries = try fileManager.contentsOfDirectory(at: extractionRoot, includingPropertiesForKeys: nil)
      guard !entries.isEmpty else { throw InstallerError.cannotExtractPackage }
      for entry in entries {
        let name = entry.lastPathComponent
        guard name != "." && name != "..",
              entry.standardizedFileURL.deletingLastPathComponent() == extractionRoot.standardizedFileURL else {
          throw InstallerError.cannotExtractPackage
        }
        try fileManager.moveItem(at: entry, to: stagingRoot.appendingPathComponent(name))
      }
      try fileManager.removeItem(at: extractionRoot)
      return stagingRoot
    } catch {
      if let installerError = error as? InstallerError,
         case .extractorDidNotExit = installerError {
        throw error
      }
      try? fileManager.removeItem(at: extractionRoot)
      try? fileManager.removeItem(at: stagingRoot)
      throw error
    }
  }

  private static func parseVersion(_ value: String) -> ParsedVersion? {
    let parts = value.split(separator: "-", omittingEmptySubsequences: false)
    guard parts.count <= 2 else { return nil }
    let components = parts[0].split(separator: ".", omittingEmptySubsequences: false)
    guard components.count == 3,
          let major = Int(components[0]), major >= 0,
          let minor = Int(components[1]), minor >= 0,
          let patch = Int(components[2]), patch >= 0 else { return nil }

    var reelRevision: Int?
    if parts.count == 2 {
      let suffix = parts[1].split(separator: ".", omittingEmptySubsequences: false)
      guard suffix.count == 2, suffix[0] == "reel",
            let revision = Int(suffix[1]), revision >= 0 else { return nil }
      reelRevision = revision
    }
    return ParsedVersion(major: major, minor: minor, patch: patch, reelRevision: reelRevision)
  }

  private static func isManagedInstall(_ plugin: JavascriptPlugin) -> Bool {
    guard plugin.identifier == identifier, !plugin.isExternal else { return false }
    let pluginsDirectory = Utility.pluginsURL.standardizedFileURL
    let root = plugin.root.standardizedFileURL
    guard root.pathExtension == "iinaplugin",
          root.resolvingSymlinksInPath().deletingLastPathComponent()
            == pluginsDirectory.resolvingSymlinksInPath() else { return false }

    let rootName = root.deletingPathExtension().lastPathComponent
    if rootName == identifier { return true }
    let suffixPrefix = identifier + "-"
    guard rootName.hasPrefix(suffixPrefix),
          let suffix = Int(rootName.dropFirst(suffixPrefix.count)) else { return false }
    return suffix >= 2
  }

  private static func installNewPackage(_ plugin: JavascriptPlugin) throws {
    guard let destination = newInstallDestination() else {
      throw InstallerError.cannotChooseDestination
    }
    let fileManager = FileManager.default
    let stagedRoot = plugin.root
    do {
      try AirPlayPluginUpdatePreservation.movePackageDirectory(
        from: stagedRoot, to: destination, under: Utility.pluginsURL, fileManager: fileManager
      )
      guard rebase(plugin, to: destination) else { throw InstallerError.cannotRebasePlugin }
      // A newly bundled copy always starts disabled until the user approves its filesystem
      // permission, even if stale defaults remain from a package that was previously removed.
      plugin.commitEnabledState(false)
      JavascriptPlugin.plugins.append(plugin)
      JavascriptPlugin.savePluginOrder()
    } catch {
      if fileManager.fileExists(atPath: destination.path) {
        do {
          try AirPlayPluginUpdatePreservation.movePackageDirectory(
            from: destination, to: stagedRoot, under: Utility.pluginsURL, fileManager: fileManager
          )
        } catch {
          Logger.log("Unable to roll back staged AirPlay package: \(error.localizedDescription)", level: .error)
        }
      }
      throw error
    }
  }

  private static func newInstallDestination() -> URL? {
    let directory = Utility.pluginsURL
    let fileManager = FileManager.default
    let first = directory.appendingPathComponent("\(identifier).iinaplugin", isDirectory: true)
    if !fileManager.fileExists(atPath: first.path) { return first }
    for suffix in 2..<10_000 {
      let candidate = directory.appendingPathComponent("\(identifier)-\(suffix).iinaplugin", isDirectory: true)
      if !fileManager.fileExists(atPath: candidate.path) { return candidate }
    }
    return nil
  }

  private static func replace(_ installedPlugin: JavascriptPlugin,
                              with candidate: JavascriptPlugin) -> BundledAirPlayPluginUpdateResult {
    let fileManager = FileManager.default
    guard isManagedInstall(installedPlugin),
          let index = JavascriptPlugin.plugins.firstIndex(where: { $0 === installedPlugin }),
          candidate.root.deletingLastPathComponent().standardizedFileURL == Utility.pluginsURL.standardizedFileURL,
          candidate.root.lastPathComponent.hasPrefix(".temp.") else {
      removeStagingDirectoryInBackground(candidate.root)
      return .unavailable
    }

    let permissionsChanged = installedPlugin.permissions != candidate.permissions
    let wasEnabled = installedPlugin.enabled
    let previousRoot = installedPlugin.root
    let stagedRoot = candidate.root
    let backupRoot = Utility.pluginsURL.appendingPathComponent(
      ".airplay-update-backup.\(UUID().uuidString)", isDirectory: true)
    var movedOldPackage = false
    var movedNewPackage = false

    // The unload Promise was confirmed while the old code and helper path still existed. Restore
    // the old enabled state if the directory transaction fails.
    if wasEnabled { installedPlugin.commitEnabledState(false) }

    do {
      try AirPlayPluginUpdatePreservation.movePackageDirectory(
        from: previousRoot, to: backupRoot, under: Utility.pluginsURL, fileManager: fileManager
      )
      movedOldPackage = true
      try AirPlayPluginUpdatePreservation.movePackageDirectory(
        from: stagedRoot, to: previousRoot, under: Utility.pluginsURL, fileManager: fileManager
      )
      movedNewPackage = true
      guard rebase(candidate, to: previousRoot) else { throw InstallerError.cannotRebasePlugin }

      let plugins = JavascriptPlugin.plugins
      guard let replacedPlugins = AirPlayPluginUpdatePreservation.replacing(plugins, at: index, with: candidate) else {
        throw InstallerError.cannotRebasePlugin
      }
      JavascriptPlugin.plugins = replacedPlugins
      JavascriptPlugin.savePluginOrder()

      let shouldRemainEnabled = AirPlayPluginUpdatePreservation.shouldRemainEnabled(
        wasEnabled: wasEnabled,
        previousPermissions: Set(installedPlugin.permissions.map(\.rawValue)),
        updatedPermissions: Set(candidate.permissions.map(\.rawValue))
      )
      // The stable identifier reuses the existing preference key. Reassert the selected state even
      // when the staged model loaded a stale value before the old model was disabled.
      candidate.commitEnabledState(shouldRemainEnabled, forceReload: true)

      // The old package can contain hundreds of megabytes of FFmpeg/source data. Cleanup must not
      // block the UI after the atomic package/model swap has committed.
      AirPlayPackageBackgroundWork.perform {
        do {
          try fileManager.removeItem(at: backupRoot)
        } catch {
          // Retain the recoverable old package if cleanup fails; the committed update stays active.
          Logger.log("Unable to remove AirPlay update backup at \(backupRoot.path): \(error.localizedDescription)", level: .error)
        }
      }
      return .updated(permissionsChanged: permissionsChanged)
    } catch {
      var oldPackageRestored = !movedOldPackage
      if movedNewPackage {
        do {
          try AirPlayPluginUpdatePreservation.movePackageDirectory(
            from: previousRoot, to: stagedRoot, under: Utility.pluginsURL, fileManager: fileManager
          )
        } catch {
          let recoveryRoot = Utility.pluginsURL.appendingPathComponent(
            ".airplay-failed-update.\(UUID().uuidString)", isDirectory: true)
          do {
            try AirPlayPluginUpdatePreservation.movePackageDirectory(
              from: previousRoot, to: recoveryRoot, under: Utility.pluginsURL, fileManager: fileManager
            )
          } catch {
            Logger.log("Unable to preserve failed AirPlay update package: \(error.localizedDescription)", level: .error)
          }
        }
      }
      if movedOldPackage {
        do {
          try AirPlayPluginUpdatePreservation.movePackageDirectory(
            from: backupRoot, to: previousRoot, under: Utility.pluginsURL, fileManager: fileManager
          )
          oldPackageRestored = true
        } catch {
          oldPackageRestored = false
          Logger.log("Unable to restore previous AirPlay package from \(backupRoot.path): \(error.localizedDescription)", level: .error)
        }
      }
      if oldPackageRestored {
        removeStagingDirectoryInBackground(stagedRoot)
        if wasEnabled && !installedPlugin.enabled { installedPlugin.commitEnabledState(true) }
      } else {
        Logger.log("AirPlay update rollback was incomplete; plugin remains disabled and backup was preserved", level: .error)
      }
      Logger.log("Unable to replace bundled AirPlay plugin: \(error.localizedDescription)", level: .error)
      return .failed
    }
  }

  private static func rebase(_ plugin: JavascriptPlugin, to root: URL) -> Bool {
    guard let entryURL = resolveLocalPath(plugin.entryPath, root: root) else { return false }
    var globalURL: URL?
    if let path = plugin.globalEntryPath {
      guard let resolved = resolveLocalPath(path, root: root) else { return false }
      globalURL = resolved
    }
    let preferencesURL = resolveLocalPath(plugin.preferencesPage, root: root)
    let helpURL = resolvePluginPath(plugin.helpPage, root: root, allowNetwork: true)
    plugin.root = root
    plugin.entryURL = entryURL
    plugin.globalEntryURL = globalURL
    plugin.preferencesPageURL = preferencesURL
    plugin.helpPageURL = helpURL
    return true
  }

  private static func resolveLocalPath(_ path: String?, root: URL) -> URL? {
    guard let path else { return nil }
    return resolvePluginPath(path, root: root, allowNetwork: false)
  }

  private static func resolvePluginPath(_ path: String?, root: URL, allowNetwork: Bool) -> URL? {
    guard let path else { return nil }
    if path.hasPrefix("http://") || path.hasPrefix("https://") {
      return allowNetwork ? URL(string: path) : nil
    }
    let resolvedRoot = root.standardizedFileURL
    let url = root.appendingPathComponent(path).standardizedFileURL
    guard url.path.hasPrefix(resolvedRoot.path + "/"),
          FileManager.default.fileExists(atPath: url.path) else { return nil }
    return url
  }

  private static func removeStagingDirectory(_ url: URL) {
    let root = url.standardizedFileURL
    guard root.deletingLastPathComponent() == Utility.pluginsURL.standardizedFileURL,
          root.lastPathComponent.hasPrefix(".temp.") else { return }
    do {
      if FileManager.default.fileExists(atPath: root.path) {
        try FileManager.default.removeItem(at: root)
      }
    } catch {
      Logger.log("Unable to remove staged AirPlay package at \(root.path): \(error.localizedDescription)", level: .error)
    }
  }

  private static func removeStagingDirectoryInBackground(_ url: URL) {
    AirPlayPackageBackgroundWork.perform {
      removeStagingDirectory(url)
    }
  }
}

@NSApplicationMain
class AppDelegate: NSObject, NSApplicationDelegate {

  /// The `AppDelegate` singleton object.
  static var shared: AppDelegate { NSApp.delegate as! AppDelegate }

  /** Whether performed some basic initialization, like bind menu items. */
  var isReady = false
  /**
   Becomes true once `application(_:openFile:)` or `droppedText()` is called.
   Mainly used to distinguish normal launches from others triggered by drag-and-dropping files.
   */
  var openFileCalled = false
  var shouldIgnoreOpenFile = false
  /** Cached URL when launching from URL scheme. */
  var pendingURL: String?

  /** Cached file paths received in `application(_:openFile:)`. */
  private var pendingFilesForOpenFile: [String] = []
  /** The timer for `OpenFileRepeatTime` and `application(_:openFile:)`. */
  private var openFileTimer: Timer?

  private var allPlayersHaveShutdown = false

  private var commandLineStatus = CommandLineStatus()

  private var isTerminating = false
  private var terminationBarrierPending = false
  private var terminationBarrierCompleted = false

  /// Longest time to wait for asynchronous shutdown tasks to finish before giving up on waiting and proceeding with termination.
  ///
  /// Ten seconds was chosen to provide plenty of time for termination and yet not be long enough that users start thinking they will
  /// need to force quit IINA. As termination may involve logging out of an online subtitles provider it can take a while to complete if
  /// the provider is slow to respond to the logout request.
  private let terminationTimeout: TimeInterval = 10

  // Windows

  lazy var openURLWindow: OpenURLWindowController = OpenURLWindowController()
  lazy var aboutWindow: AboutWindowController = AboutWindowController()
  lazy var fontPicker: FontPickerWindowController = FontPickerWindowController()
  lazy var inspector: InspectorWindowController = InspectorWindowController()
  lazy var historyWindow: HistoryWindowController = HistoryWindowController()
  lazy var guideWindow: GuideWindowController = GuideWindowController()
  lazy var logWindow: LogWindowController = LogWindowController()

  lazy var vfWindow: FilterWindowController = {
    let w = FilterWindowController(filterType: MPVProperty.vf, autosaveName: Constants.WindowAutosaveName.videoFilters)
    return w
  }()

  lazy var afWindow: FilterWindowController = {
    let w = FilterWindowController(filterType: MPVProperty.af, autosaveName: Constants.WindowAutosaveName.audioFilters)
    return w
  }()

  lazy var preferenceWindowController: PreferenceWindowController = {
    var list: [NSViewController & PreferenceWindowEmbeddable] = [
      PrefGeneralViewController(),
      PrefUIViewController(),
      PrefCodecViewController(),
      PrefSubViewController(),
      PrefNetworkViewController(),
      PrefControlViewController(),
      PrefKeyBindingViewController(),
      PrefAdvancedViewController(),
      // PrefPluginViewController(),
      PrefUtilsViewController(),
    ]

    if IINA_ENABLE_PLUGIN_SYSTEM {
      list.insert(PrefPluginViewController(), at: 8)
    }
    return PreferenceWindowController(viewControllers: list)
  }()

  /// Whether the shutdown sequence timed out.
  private var timedOut = false

  @IBOutlet var menuController: MenuController!

  @IBOutlet weak var dockMenu: NSMenu!

  private func getReady() {
    menuController.bindMenuItems()
    PlayerCore.loadKeyBindings()
    isReady = true
  }

  // MARK: - Logs
  private let observedPrefKeys: [Preference.Key] = [.logLevel, .thumbnailWidth]

  override func observeValue(forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey : Any]?, context: UnsafeMutableRawPointer?) {
    guard let keyPath, let change else { return }

    switch keyPath {
    case Preference.Key.logLevel.rawValue:
      if let newValue = change[.newKey] as? Int {
        Logger.Level.preferred = Logger.Level(rawValue: newValue.clamped(to: 0...3))!
      }
    case Preference.Key.thumbnailWidth.rawValue:
      ThumbnailCache.clearThumbnailCache()

    default:
      return
    }
  }


  /// Log details about when and from what sources IINA was built.
  ///
  /// For developers that take a development build to other machines for testing it is useful to log information that can be used to
  /// distinguish between development builds.
  ///
  /// In support of this the build populated `Info.plist` with keys giving:
  /// - The build date
  /// - The git branch
  /// - The git commit
  private func logBuildDetails() {
    guard let date = InfoDictionary.shared.buildDate,
          let sdk = InfoDictionary.shared.buildSDK,
          let xcode = InfoDictionary.shared.buildXcode else { return }
    let toString = DateFormatter()
    toString.dateStyle = .medium
    toString.timeStyle = .medium
    // Always use the en_US locale for dates in the log file.
    toString.locale = Locale(identifier: "en_US")
    Logger.log("Built using Xcode \(xcode) and macOS SDK \(sdk) on \(toString.string(from: date))")
    guard let branch = InfoDictionary.shared.buildBranch,
          let commit = InfoDictionary.shared.buildCommit else { return }
    Logger.log("From branch \(branch), commit \(commit)")
  }

  /// Log details about the Mac IINA is running on.
  ///
  /// Certain IINA capabilities, such as hardware acceleration, are contingent upon aspects of the Mac IINA is running on. If available,
  /// this method will log:
  /// - macOS version
  /// - Model identifier of the Mac
  /// - Kind of processor chip
  /// - Amount of physical memory
  /// - Thermal state
  /// - Whether low power mode is active
  /// - Note: At this time IINA does not listen for changes to the thermal state or whether low power mode is active or not. For now
  ///         this information is only logged at startup. That might change if some correlation between these states and IINA's
  ///         behavior is seen.
  private func logPlatformDetails() {
    Logger.log("Running under macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")
    if let cpu = Sysctl.shared.machineCpuBrandString, let model = Sysctl.shared.hwModel {
      let memory = ProcessInfo.processInfo.physicalMemory / 1073741824
      Logger.log("On a \(model) with an \(cpu) processor and \(memory) GiB of RAM")
    }
    let thermalState = ProcessInfo.processInfo.thermalState
    if thermalState != .nominal {
      Logger.log("Thermal state: \(thermalState)")
    }
    if #available(macOS 12, *), ProcessInfo.processInfo.isLowPowerModeEnabled {
      Logger.log("Low Power Mode is active")
    }
  }

  /// Log all the available [screens](https://developer.apple.com/documentation/appkit/nsscreen) and all the
  /// connected displays.
  private func logScreenDetails() {
    DisplayController.shared.addNewDisplays()
    NSScreen.screens.enumerated().forEach { screen in
      NSScreen.log("NSScreen.screens[\(screen.offset)]" , screen.element)
    }
  }

  // MARK: - App Delegate

  func applicationWillFinishLaunching(_ notification: Notification) {
    // Must setup preferences before logging so log level is set correctly.
    registerUserDefaultValues()

    observedPrefKeys.forEach { key in
      UserDefaults.standard.addObserver(self, forKeyPath: key.rawValue, options: .new, context: nil)
    }

    // Start the log file by logging the version of IINA producing the log file.
    let (version, build) = InfoDictionary.shared.version
    let type = InfoDictionary.shared.buildTypeIdentifier
    Logger.log("IINA \(version) Build \(build)" + (type == nil ? "" : " " + type!))

    // The copyright is used in the Finder "Get Info" window which is a narrow window so the
    // copyright consists of multiple lines.
    let copyright = InfoDictionary.shared.copyright
    copyright.enumerateLines { line, _ in
      Logger.log(line)
    }

    // Useful to know the versions of significant dependencies that are being used so log that
    // information as well when it can be obtained.
    Logger.log(MPVOptionDefaults.shared.mpvVersion)
    Logger.log("FFmpeg \(String(cString: av_version_info()))")
    // FFmpeg libraries and their versions in alphabetical order.
    let libraries: [(name: String, version: UInt32)] = [("libavcodec", avcodec_version()), ("libavformat", avformat_version()), ("libavutil", avutil_version()), ("libswscale", swscale_version())]
    for library in libraries {
      // The version of FFmpeg libraries is encoded into an unsigned integer in a proprietary
      // format which needs to be decoded into a string for display.
      Logger.log("  \(library.name) \(AppDelegate.versionAsString(library.version))")
    }
    Logger.log("libass \(MPVOptionDefaults.shared.libassVersion)")

    logBuildDetails()
    logPlatformDetails()
    logScreenDetails()
    Preference.logSettings()

    Logger.log("App will launch")

    // Start asynchronously gathering and caching information about the hardware decoding
    // capabilities of this Mac.
    HardwareDecodeCapabilities.shared.checkCapabilities()

    // Workaround macOS Sonoma clearing the recent documents list when the IINA code is not signed
    // with IINA's certificate as is the case for developer and nightly builds.
    restoreRecentDocuments()

    // register for url event
    NSAppleEventManager.shared().setEventHandler(self, andSelector: #selector(self.handleURLEvent(event:withReplyEvent:)), forEventClass: AEEventClass(kInternetEventClass), andEventID: AEEventID(kAEGetURL))

    // Check for legacy pref entries and migrate them to their modern equivalents.
    LegacyMigration.shared.migrateLegacyPreferences()
    LegacyMigration.shared.migrateToneMappingTargetPeak()

    // guide window
    switch InfoDictionary.shared.buildType {
    case .release, .beta:
      if FirstRunManager.isFirstRun(for: .init("firstLaunchAfter\(version)")) {
        guideWindow.show(pages: [.highlights])
      }
    default:
      break
    }

    // Hide Window > "Enter Full Screen" menu item, because this is already present in the Video menu
    UserDefaults.standard.set(false, forKey: "NSFullScreenMenuItemEverywhere")

    // Install plugins
    if FirstRunManager.isFirstRun(for: .init("installedDefaultPlugins")) {
      var hasError = false
      Logger.log("Installing default plugins")
      if let pluginPath = Bundle.main.resourcePath?.appending("/plugins"),
         FileManager.default.fileExists(atPath: pluginPath),
         let contents = try? FileManager.default.contentsOfDirectory(atPath: pluginPath) {
        contents.filter { $0.hasSuffix(".iinaplgz") }
          .forEach {
            do {
              let path = pluginPath.appending("/\($0)")
              let plugin = try JavascriptPlugin.create(fromPackageURL: URL(fileURLWithPath: path))
              if JavascriptPlugin.plugins.contains(where: { $0.identifier == plugin.identifier }) {
                Logger.log("Skipped \(plugin.identifier), already installed")
                return
              }
              let requiresExplicitAirPlayConsent = plugin.identifier == "dev.faruk.iina-airplay"
              if requiresExplicitAirPlayConsent {
                plugin.commitEnabledState(false)
              }
              plugin.normalizePath()
              JavascriptPlugin.plugins.append(plugin)
              if !requiresExplicitAirPlayConsent {
                plugin.enabled = true
              }
              Logger.log("Installed \(plugin.identifier)\(requiresExplicitAirPlayConsent ? " disabled pending permission approval" : "")")
            } catch let error {
              hasError = true
              Logger.log(error.localizedDescription, level: .error)
            }
          }
      } else {
        hasError = true
        Logger.log("Cannot find default plugins", level: .error)
      }

      if hasError {
        FirstRunManager.unsetFirstRun(for: .init("installedDefaultPlugins"))
      }
    }

    installBundledAirPlayPluginIfNeeded()

    // handle arguments
    let arguments = ProcessInfo.processInfo.arguments.dropFirst()
    guard arguments.count > 0 else { return }

    var iinaArgs: [String] = []
    var iinaArgFilenames: [String] = []
    var dropNextArg = false

    Logger.log("Command-line args: \(arguments)")
    for arg in arguments {
      if dropNextArg {
        dropNextArg = false
        continue
      }
      if arg.first == "-" {
        let indexAfterDash = arg.index(after: arg.startIndex)
        if indexAfterDash == arg.endIndex {
          // single '-'
          commandLineStatus.isStdin = true
        } else if arg[indexAfterDash] == "-" {
          // args starting with --
          iinaArgs.append(arg)
        } else {
          // args starting with -
          dropNextArg = true
        }
      } else {
        // assume args starting with nothing is a filename
        iinaArgFilenames.append(arg)
      }
    }

    commandLineStatus.parseArguments(iinaArgs)
    Logger.log("Filenames from args: \(iinaArgFilenames)")
    Logger.log("Derived mpv properties from args: \(commandLineStatus.mpvArguments)")

    print("IINA \(version) Build \(build)")

    guard !iinaArgFilenames.isEmpty || commandLineStatus.isStdin else {
      print("This binary is not intended for being used as a command line tool. Please use the bundled iina-cli.")
      print("Please ignore this message if you are running in a debug environment.")
      return
    }

    shouldIgnoreOpenFile = true
    commandLineStatus.isCommandLine = true
    commandLineStatus.filenames = iinaArgFilenames
  }

  /// Install the bundled AirPlay plugin for existing users, migrating only a recognized official
  /// legacy package before plugin contexts load.
  private func installBundledAirPlayPluginIfNeeded() {
    BundledAirPlayPluginManager.installIfNeeded()
  }

  deinit {
    ObjcUtils.silenced {
      for key in self.observedPrefKeys {
        UserDefaults.standard.removeObserver(self, forKeyPath: key.rawValue)
      }
    }
  }

  func applicationDidFinishLaunching(_ aNotification: Notification) {
    if BundledAirPlayPluginManager.continueLaunchWhenMigrationSettles({ [weak self] in
      self?.finishApplicationDidFinishLaunching(aNotification)
    }) {
      return
    }
    finishApplicationDidFinishLaunching(aNotification)
  }

  private func finishApplicationDidFinishLaunching(_ aNotification: Notification) {
    Logger.log("App launched")

    let removedSubtitleCacheEntries = BuiltinSubtitleCache.removeStaleEntries()
    if removedSubtitleCacheEntries > 0 {
      Logger.log("Removed \(removedSubtitleCacheEntries) expired built-in subtitle cache entries",
                 level: .debug, subsystem: Logger.Sub.onlinesub)
    }

    if !isReady {
      getReady()
    }

    // show alpha in color panels
    NSColorPanel.shared.showsAlpha = true

    // other initializations at App level
    NSApp.isAutomaticCustomizeTouchBarMenuItemEnabled = false
    NSWindow.allowsAutomaticWindowTabbing = false

    JavascriptPlugin.loadGlobalInstances()

    let mpv = PlayerCore.active.mpv!
    Logger.log("Configuration when building mpv: \(mpv.getString(MPVProperty.mpvConfiguration)!)", level: .verbose)

    // if have pending open request
    if let url = pendingURL {
      parsePendingURL(url)
    }

    if !commandLineStatus.isCommandLine {
      // check whether showing the welcome window after 0.1s
      Timer.scheduledTimer(timeInterval: TimeInterval(0.1), target: self, selector: #selector(self.checkForShowingInitialWindow), userInfo: nil, repeats: false)
    } else {
      var lastPlayerCore: PlayerCore? = nil
      let getNewPlayerCore = { [self] () -> PlayerCore in
        let pc = PlayerCore.newPlayerCore
        commandLineStatus.applyMPVArguments(to: pc)
        lastPlayerCore = pc
        return pc
      }
      if commandLineStatus.isStdin {
        getNewPlayerCore().openURLString("-")
      } else {
        let validFileURLs: [URL] = commandLineStatus.filenames.compactMap { filename in
          if Regex.url.matches(filename) {
            return URL(string: filename.addingPercentEncoding(withAllowedCharacters: .urlAllowed) ?? filename)
          } else {
            return FileManager.default.fileExists(atPath: filename) ? URL(fileURLWithPath: filename) : nil
          }
        }
        if commandLineStatus.openSeparateWindows {
          validFileURLs.forEach { url in
            getNewPlayerCore().openURL(url)
          }
        } else {
          getNewPlayerCore().openURLs(validFileURLs)
        }
      }

      if let pc = lastPlayerCore {
        if commandLineStatus.enterMusicMode {
          if commandLineStatus.enterPIP {
            // PiP is not supported in music mode. Combining these options is not permitted and is
            // rejected by iina-cli. The IINA executable must have been invoked directly with
            // arguments.
            Logger.log("Cannot specify both --music-mode and --pip", level: .error)
            // Command line usage error.
            exit(EX_USAGE)
          }
          pc.switchToMiniPlayer()
        } else if commandLineStatus.enterPIP {
          pc.mainWindow.enterPIP()
        }
      }
    }

    NSRunningApplication.current.activate(options: [.activateIgnoringOtherApps, .activateAllWindows])

    NSApplication.shared.servicesProvider = self

    AppDelegate.shared.menuController?.updatePluginMenu()

    MemoryUsage.shared.logUsage("after launching finished")
  }

  /** Show welcome window if `application(_:openFile:)` wasn't called, i.e. launched normally. */
  @objc
  func checkForShowingInitialWindow() {
    if !openFileCalled {
      showWelcomeWindow()
    }
  }

  private func showWelcomeWindow(checkingForUpdatedData: Bool = false) {
    let actionRawValue = Preference.integer(for: .actionAfterLaunch)
    let action: Preference.ActionAfterLaunch = Preference.ActionAfterLaunch(rawValue: actionRawValue) ?? .welcomeWindow
    switch action {
    case .welcomeWindow:
      let window = PlayerCore.first.initialWindow!
      window.showWindow(nil)
      if checkingForUpdatedData {
        window.loadLastPlaybackInfo()
        window.reloadData()
      }
    case .openPanel:
      openFile(self)
    default:
      break
    }
  }

  func applicationShouldAutomaticallyLocalizeKeyEquivalents(_ application: NSApplication) -> Bool {
    // Do not re-map keyboard shortcuts based on keyboard position in different locales
    return false
  }

  /// Returns a Boolean value that indicates if the app terminates once the last window closes.
  ///
  /// IINA will not quit when the last window is closed unless the `Quit after all windows are closed` setting is enabled.
  /// - Note: When the welcome window is enabled this method will be called during the transition from showing the welcome
  ///     window to playing media. This happens because the welcome window will be closed before the player window is opened as
  ///     opening the player window is delayed until mpv reports the window size required. For this reason the state of the active
  ///     player core must be checked as it could be preparing to open a window.
  /// - Parameter sender: The application object whose last window was closed.
  /// - Returns: `false` if the application should not be terminated when its last window is closed; otherwise, `true` to
  ///     terminate the application.
  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    // If the user has not enabled the setting then no need to check anything else.
    guard Preference.bool(for: .quitWhenNoOpenedWindow) else { return false }
    let player = PlayerCore.active
    guard !player.info.state.active else { return false }
    guard player.mainWindow.loaded || player.initialWindow.loaded else { return false }
    return !player.mainWindow.isWindowHidden
  }

  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    let airPlayIdentifier = BundledAirPlayPluginManager.identifier
    if !terminationBarrierCompleted && PlayerCore.hasLivePluginContext(identifier: airPlayIdentifier) {
      guard !terminationBarrierPending else { return .terminateLater }
      terminationBarrierPending = true
      PlayerCore.acquirePluginUnloadPermit(identifier: airPlayIdentifier) { result in
        self.terminationBarrierPending = false
        switch result {
        case .success(let permit):
          self.terminationBarrierCompleted = true
          let reply = self.beginApplicationTermination(sender)
          permit.release(reloadDeferredContexts: false)
          if case .terminateNow = reply {
            NSApp.reply(toApplicationShouldTerminate: true)
          }
        case .failure(let error):
          // Nothing has been closed or disabled yet, so cancellation leaves the existing player
          // and plugin context available for the user's retry action.
          NSApp.reply(toApplicationShouldTerminate: false)
          self.presentPluginLifecycleFailure(error)
        }
      }
      return .terminateLater
    }
    if PlayerCore.hasAnyPluginContext(identifier: airPlayIdentifier) {
      // An mpv-initiated shutdown may already have destroyed the player API. Do not invoke a plugin
      // callback that might touch that API; its helper's own lifecycle timeout is the only safe
      // cleanup available at this boundary.
      Logger.log("AirPlay plugin context belongs to an already shut down player; skipping unsafe unload callback",
                 level: .warning)
    }
    return beginApplicationTermination(sender)
  }

  private func beginApplicationTermination(_ sender: NSApplication) -> NSApplication.TerminateReply {
    Logger.log("App should terminate")
    isTerminating = true
    MemoryUsage.shared.logUsage("before terminating")

    // Normally termination happens fast enough that the user does not have time to initiate
    // additional actions, however to be sure shutdown further input from the user.
    Logger.log("Disabling all menus")
    menuController.disableAllMenus()
    // Remove custom menu items added by IINA to the dock menu. AppKit does not allow the dock
    // supplied items to be changed by an application so there is no danger of removing them.
    // The menu items are being removed because setting the isEnabled property to false had no
    // effect under macOS 12.6.
    removeAllMenuItems(dockMenu)
    // Disable all remote media commands. This also removes IINA from the Now Playing widget.
    RemoteCommandController.shared.disable()

    // The first priority was to shutdown any new input from the user. The second priority is to
    // send a logout request if logged into an online subtitles provider as that needs time to
    // complete.
    if OnlineSubtitle.loggedIn {
      // Force the logout request to timeout earlier than the overall termination timeout. This
      // request taking too long does not represent an error in the shutdown code, whereas the
      // intention of the overall termination timeout is to recover from some sort of hold up in the
      // shutdown sequence that should not occur.
      OnlineSubtitle.logout(timeout: terminationTimeout - 1)
    }

    // Close all windows. When a player window is closed it will send a stop command to mpv to stop
    // playback and unload the file.
    Logger.log("Closing all windows")
    for window in NSApp.windows {
      window.close()
    }

    // Check if there are any players that are not shutdown. If all players are already shutdown
    // then application termination can proceed immediately. This will happen if there is only one
    // player and shutdown was initiated by sending a quit command directly to mpv through it's IPC
    // interface causing mpv and the player to shutdown before application termination is initiated.
    allPlayersHaveShutdown = true
    for player in PlayerCore.playerCores {
      if player.info.state != .shutDown {
        allPlayersHaveShutdown = false
        break
      }
    }
    if allPlayersHaveShutdown {
      Logger.log("All players have shutdown")
    } else {
      // Shutdown of player cores involves sending the stop and quit commands to mpv. Even though
      // these commands are sent to mpv using the synchronous API mpv executes them asynchronously.
      // This requires IINA to wait for mpv to finish executing these commands.
      Logger.log("Waiting for players to stop and shutdown")
    }

    // Usually will have to wait for logout request to complete if logged into an online subtitle
    // provider.
    var canTerminateNow = allPlayersHaveShutdown
    if OnlineSubtitle.loggedIn {
      canTerminateNow = false
      Logger.log("Waiting for log out of online subtitles provider to complete")
    }

    if HistoryController.shared.tasksOutstanding != 0 {
      canTerminateNow = false
      Logger.log("Waiting for saving of playback history to complete")
    }

    // If the user pressed Q and mpv initiated the termination then players will already be
    // shutdown and it may be possible to proceed with termination.
    if canTerminateNow {
      Logger.log("Proceeding with application termination")
      // Tell Cocoa that it is ok to immediately proceed with termination.
      return .terminateNow
    }

    // To ensure termination completes and the user is not required to force quit IINA, impose an
    // arbitrary timeout that forces termination to complete. The expectation is that this timeout
    // is never triggered. If a timeout warning is logged during termination then that needs to be
    // investigated.
    let timer = Timer(timeInterval: terminationTimeout, repeats: false) { [unowned self] _ in
      timedOut = true
      if !allPlayersHaveShutdown {
        Logger.log("Timed out waiting for players to stop and shutdown", level: .warning)
        // For debugging list players that have not terminated.
        for player in PlayerCore.playerCores {
          let label = player.label ?? "unlabeled"
          if player.info.state == .stopping {
            Logger.log("Player \(label) failed to stop", level: .warning)
          } else if player.info.state == .shuttingDown {
            Logger.log("Player \(label) failed to shutdown", level: .warning)
          }
        }
        // For debugging purposes we do not remove observers in case players stop or shutdown after
        // the timeout has fired as knowing that occurred maybe useful for debugging why the
        // termination sequence failed to complete on time.
        Logger.log("Not waiting for players to shutdown; proceeding with application termination",
                   level: .warning)
      }
      if OnlineSubtitle.loggedIn {
        // The request to log out of the online subtitles provider has not completed. This should not
        // occur as the logout request uses a timeout that is shorter than the termination timeout to
        // avoid this occurring. Therefore if this message is logged something has gone wrong with the
        // shutdown code.
        Logger.log("Timed out waiting for log out of online subtitles provider to complete",
                   level: .warning)
      }
      Logger.log("Proceeding with application termination due to time out", level: .warning)
      // Tell Cocoa to proceed with termination.
      NSApp.reply(toApplicationShouldTerminate: true)
    }

    RunLoop.main.add(timer, forMode: .common)

    // Establish an observer for a player core stopping.
    let center = NotificationCenter.default
    var observers: [NSObjectProtocol] = []
    var observer = center.addObserver(forName: .iinaPlayerStopped, object: nil, queue: .main) { note in
      guard !self.timedOut else {
        // The player has stopped after IINA already timed out, gave up waiting for players to
        // shutdown, and told Cocoa to proceed with termination. AppKit will continue to process
        // queued tasks during application termination even after AppKit has called
        // applicationWillTerminate. So this observer can be called after IINA has told Cocoa to
        // proceed with termination. When the termination sequence times out IINA does not remove
        // observers as it may be useful for debugging purposes to know that a player stopped after
        // the timeout as that indicates the stopping was proceeding as opposed to being permanently
        // blocked. Log that this has occurred and take no further action as it is too late to
        // proceed with the normal termination sequence.  If the log file has already been closed
        // then the message will only be printed to the console.
        Logger.log("Player stopped after application termination timed out", level: .warning)
        return
      }
      guard let player = note.object as? PlayerCore else { return }
      // Now that the player has stopped it is safe to instruct the player to terminate. IINA MUST
      // wait for the player to stop before instructing it to terminate because sending the quit
      // command to mpv while it is still asynchronously executing the stop command can result in a
      // watch later file that is missing information such as the playback position. See issue #3939
      // for details.
      player.shutdown()
    }
    observers.append(observer)

    /// Proceed with termination if all outstanding shutdown tasks have completed.
    ///
    /// This method is called when an observer receives a notification that a player has shutdown or an online subtitles provider logout
    /// request has completed. If there are no other termination tasks outstanding then this method will instruct AppKit to proceed with
    /// termination.
    func proceedWithTermination() {
      if !allPlayersHaveShutdown {
        // If any player has not shutdown then continue waiting.
        for player in PlayerCore.playerCores {
          guard player.info.state == .shutDown else { return }
        }
        allPlayersHaveShutdown = true
        // All players have shutdown.
        Logger.log("All players have shutdown")
      }
      // If still logged in to subtitle providers then continue waiting.
      guard !OnlineSubtitle.loggedIn else { return }
      // If still still saving playback history then continue waiting.
      guard HistoryController.shared.tasksOutstanding == 0 else { return }
      // All players have shutdown. No longer logged into an online subtitles provider and saving of
      // playback history has finished.
      Logger.log("Proceeding with application termination")
      // No longer need the timer that forces termination to proceed.
      timer.invalidate()
      // No longer need the observers for players stopping and shutting down, along with the
      // observer for logout requests completing and saving of playback history finishing.
      ObjcUtils.silenced {
        observers.forEach {
          NotificationCenter.default.removeObserver($0)
        }
      }
      // Tell AppKit to proceed with termination.
      NSApp.reply(toApplicationShouldTerminate: true)
    }

    // Establish an observer for a player core shutting down.
    observer = center.addObserver(forName: .iinaPlayerShutdown, object: nil, queue: .main) { _ in
      guard !self.timedOut else {
        // The player has shutdown after IINA already timed out, gave up waiting for players to
        // shutdown, and told Cocoa to proceed with termination. AppKit will continue to process
        // queued tasks during application termination even after AppKit has called
        // applicationWillTerminate. So this observer can be called after IINA has told Cocoa to
        // proceed with termination. When the termination sequence times out IINA does not remove
        // observers as it may be useful for debugging purposes to know that a player shutdown after
        // the timeout as that indicates shutdown was proceeding as opposed to being permanently
        // blocked. Log that this has occurred and take no further action as it is too late to
        // proceed with the normal termination sequence. If the log file has already been closed
        // then the message will only be printed to the console.
        Logger.log("Player shutdown after application termination timed out", level: .warning)
        return
      }
      proceedWithTermination()
    }
    observers.append(observer)

    // Establish an observer for logging out of the online subtitle provider.
    observer = center.addObserver(forName: .iinaLogoutCompleted, object: nil, queue: .main) { _ in
      guard !self.timedOut else {
        // The request to log out of the online subtitles provider has completed after IINA already
        // timed out, gave up waiting for players to shutdown, and told Cocoa to proceed with
        // termination. This should not occur as the logout request uses a timeout that is shorter
        // than the termination timeout to avoid this occurring. Therefore if this message is logged
        // something has gone wrong with the shutdown code.
        Logger.log(
          "Log out of online subtitles provider completed after application termination timed out",
          level: .warning)
        return
      }
      proceedWithTermination()
    }
    observers.append(observer)

    // Establish an observer for saving of playback history finishing.
    observer = center.addObserver(forName: .iinaHistoryTaskFinished, object: nil, queue: .main) { _ in
      guard !self.timedOut else {
        // Saving of playback history finished after IINA already timed out, gave up waiting, and
        // told Cocoa to proceed with termination. This is a problem as it indicates playback
        // history might be being lost.
        Logger.log("Saving of playback history finished after application termination timed out",
          level: .warning)
        return
      }
      // If there are still tasks outstanding then must continue waiting.
      guard HistoryController.shared.tasksOutstanding == 0 else { return }
      Logger.log("Saving of playback history finished")
      proceedWithTermination()
    }
    observers.append(observer)

    // Instruct any players that are already stopped to start shutting down.
    for player in PlayerCore.playerCores {
      if player.info.state == .idle {
        player.shutdown()
      }
    }

    // Tell AppKit that it is ok to proceed with termination, but wait for our reply.
    return .terminateLater
  }

  func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
    // Once termination starts subsystems such as mpv are being shutdown. Accessing mpv
    // once it has been instructed to shutdown can trigger a crash. MUST NOT permit
    // reopening once termination has started.
    guard !isTerminating else { return false }
    guard !flag else { return true }
    Logger.log("Handle reopen")
    showWelcomeWindow(checkingForUpdatedData: true)
    return true
  }

  func applicationWillTerminate(_ notification: Notification) {
    Logger.log("App will terminate")
    Logger.closeLogFile()
  }

  /**
   When dragging multiple files to App icon, cocoa will simply call this method repeatedly.
   Therefore we must cache all possible calls and handle them together.
   */
  func application(_ sender: NSApplication, openFile filename: String) -> Bool {
    openFileCalled = true
    openFileTimer?.invalidate()
    pendingFilesForOpenFile.append(filename)
    openFileTimer = Timer.scheduledTimer(timeInterval: OpenFileRepeatTime, target: self, selector: #selector(handleOpenFile), userInfo: nil, repeats: false)
    return true
  }

  /** Handle pending file paths if `application(_:openFile:)` not being called again in `OpenFileRepeatTime`. */
  @objc
  func handleOpenFile() {
    if !isReady {
      getReady()
    }
    // if launched from command line, should ignore openFile once
    if shouldIgnoreOpenFile {
      shouldIgnoreOpenFile = false
      return
    }
    let urls = pendingFilesForOpenFile.map { URL(fileURLWithPath: $0) }
    pendingFilesForOpenFile.removeAll()

    // if installing a plugin package
    if let pluginPackageURL = urls.first(where: { $0.pathExtension == "iinaplgz" }) {
      if Preference.enableNewSettings {
        SettingsWindow.default.installPlugin(localPackageURL: pluginPackageURL)
      } else {
        preferenceWindowController.performAction(.installPlugin(url: pluginPackageURL))
      }
      return
    }

    // open pending files
    let openResult = PlayerCore.openURLs(urls)
    if openResult == 0 {
      Utility.showAlert("nothing_to_open")
    } else {
      // This confirms AppDelegate handed the matching immutable resume path to
      // PlayerCore.openURLs; playlist parsing/consumption is asynchronous.
      TotalDramaPlaylistOpenAcknowledgement.acknowledge(urls)
    }
  }

  /// Method to opt-in to secure restorable state.
  ///
  /// From the `Restorable State` section of the [AppKit Release Notes for macOS 14](https://developer.apple.com/documentation/macos-release-notes/appkit-release-notes-for-macos-14#Restorable-State):
  ///
  /// Secure coding is automatically enabled for restorable state for applications linked on the macOS 14.0 SDK. Applications that
  /// target prior versions of macOS should implement `NSApplicationDelegate.applicationSupportsSecureRestorableState()`
  /// to return`true` so it’s enabled on all supported OS versions.
  ///
  /// This is about conformance to [NSSecureCoding](https://developer.apple.com/documentation/foundation/nssecurecoding)
  /// which protects against object substitution attacks. If an application does not implement this method then a warning will be emitted
  /// reporting secure coding is not enabled for restorable state.
  @available(macOS 12.0, *)
  @MainActor func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

  // MARK: - Accept dropped string and URL

  @objc
  func droppedText(_ pboard: NSPasteboard, userData:String, error: NSErrorPointer) {
    if let url = pboard.string(forType: .string) {
      openFileCalled = true
      PlayerCore.active.openURLString(url)
    }
  }

  // MARK: - Dock menu

  func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
    return dockMenu
  }

  /// Remove all menu items in the given menu and any submenus.
  ///
  /// This method recursively descends through the entire tree of menu items removing all items.
  /// - Parameter menu: Menu to remove items from
  private func removeAllMenuItems(_ menu: NSMenu) {
    for item in menu.items {
      if item.hasSubmenu {
        removeAllMenuItems(item.submenu!)
      }
      menu.removeItem(item)
    }
  }

  // MARK: - URL Scheme

  @objc func handleURLEvent(event: NSAppleEventDescriptor, withReplyEvent replyEvent: NSAppleEventDescriptor) {
    openFileCalled = true
    guard let url = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue else { return }
    Logger.log("URL event: \(url)")
    if isReady {
      parsePendingURL(url)
    } else {
      pendingURL = url
    }
  }


  /**
   Parses the pending iina:// url.
   - Parameter url: the pending URL.
   - Note:
   The iina:// URL scheme currently supports the following actions:

   __/open__
   - `url`: a url or string to open.
   - `new_window`: 0 or 1 (default) to indicate whether open the media in a new window.
   - `enqueue`: 0 (default) or 1 to indicate whether to add the media to the current playlist.
   - `full_screen`: 0 (default) or 1 to indicate whether open the media and enter fullscreen.
   - `pip`: 0 (default) or 1 to indicate whether open the media and enter pip.
   - `mpv_*`: additional mpv options to be passed. e.g. `mpv_volume=20`.
     Options starting with `no-` are not supported.
   */
  private func parsePendingURL(_ url: String) {
    Logger.log("Parsing URL \(url)")
    guard let parsed = URLComponents(string: url) else {
      Logger.log("Cannot parse URL using URLComponents", level: .warning)
      return
    }
    
    if parsed.scheme != "iina" {
      // try to open the URL directly
      PlayerCore.activeOrNewForMenuAction(isAlternative: false).openURLString(url)
      return
    }
    
    // handle url scheme
    guard let host = parsed.host else { return }

    if host == "open" || host == "weblink" {
      // open a file or link
      guard let queries = parsed.queryItems else { return }
      let queryDict = [String: String](uniqueKeysWithValues: queries.map { ($0.name, $0.value ?? "") })

      // url
      guard let urlValue = queryDict["url"], !urlValue.isEmpty else {
        Logger.log("Cannot find parameter \"url\", stopped")
        return
      }

      // new_window
      let player: PlayerCore
      if let newWindowValue = queryDict["new_window"], newWindowValue == "1" {
        player = PlayerCore.newPlayerCore
      } else {
        player = PlayerCore.activeOrNewForMenuAction(isAlternative: false)
      }

      // enqueue
      let playlistEmpty = PlayerCore.lastActive.info.$playlist.withLock { $0.isEmpty }
      if let enqueueValue = queryDict["enqueue"], enqueueValue == "1", !playlistEmpty {
        PlayerCore.lastActive.appendToPlaylist(urlValue)
        PlayerCore.lastActive.postNotification(.iinaPlaylistChanged)
        PlayerCore.lastActive.sendOSD(.addToPlaylist(1))
      } else {
        player.openURLString(urlValue)
      }

      // presentation options
      if let fsValue = queryDict["full_screen"], fsValue == "1" {
        // full_screen
        player.mpv.setFlag(MPVOption.Window.fullscreen, true)
      } else if let pipValue = queryDict["pip"], pipValue == "1" {
        // pip
        player.mainWindow.enterPIP()
      }

      // mpv options
      for query in queries {
        if query.name.hasPrefix("mpv_") {
          let mpvOptionName = String(query.name.dropFirst(4))
          guard AppData.safeMPVOptions.contains(mpvOptionName) else {
            Logger.log("mpv option \(mpvOptionName) rejected when parsing URL", level: .warning)
            continue
          }
          guard let mpvOptionValue = query.value else { continue }
          Logger.log("Setting \(mpvOptionName) to \(mpvOptionValue)")
          player.mpv.setString(mpvOptionName, mpvOptionValue)
        }
      }

      Logger.log("Finished URL scheme handling")
    }
  }

  // MARK: - Menu actions

  @IBAction func openFile(_ sender: AnyObject) {
    Logger.log("Menu - Open file")
    let panel = NSOpenPanel()
    panel.title = NSLocalizedString("alert.choose_media_file.title", comment: "Choose Media File")
    panel.canCreateDirectories = false
    panel.canChooseFiles = true
    panel.canChooseDirectories = true
    panel.allowsMultipleSelection = true
    if panel.runModal() == .OK {
      if Preference.bool(for: .recordRecentFiles) {
        for url in panel.urls {
          noteNewRecentDocumentURL(url)
        }
      }
      if PlayerCore.openURLs(panel.urls) == 0 {
        Utility.showAlert("nothing_to_open")
      }
    }
  }

  @IBAction func openURL(_ sender: AnyObject) {
    Logger.log("Menu - Open URL")
    openURLWindow.isAlternativeAction = sender.tag == AlternativeMenuItemTag
    openURLWindow.showWindow(nil)
    openURLWindow.resetWindowState()
  }

  @IBAction func menuNewWindow(_ sender: Any) {
    PlayerCore.newPlayerCore.initialWindow.showWindow(nil)
  }

  @IBAction func menuOpenScreenshotFolder(_ sender: NSMenuItem) {
    let screenshotPath = Preference.string(for: .screenshotFolder)!
    let absoluteScreenshotPath = NSString(string: screenshotPath).expandingTildeInPath
    let url = URL(fileURLWithPath: absoluteScreenshotPath, isDirectory: true)
      NSWorkspace.shared.open(url)
  }

  @IBAction func menuSelectAudioDevice(_ sender: NSMenuItem) {
    if let name = sender.representedObject as? String {
      PlayerCore.active.setAudioDevice(name)
    }
  }

  @IBAction func showPreferences(_ sender: AnyObject) {
    if Preference.enableNewSettings {
      SettingsWindow.default.show()
    } else {
      preferenceWindowController.showWindow(self)
    }
  }

  @objc func showPluginPreferences(_ sender: NSMenuItem) {
    if Preference.enableNewSettings {
      SettingsWindow.default.show()
      SettingsWindow.default.navigateTo(page: "plugin")
    } else {
      preferenceWindowController.openPreferenceView(withNibName: "PrefPluginViewController")
    }
  }

  @IBAction func showVideoFilterWindow(_ sender: AnyObject) {
    vfWindow.showWindow(self)
  }

  @IBAction func showAudioFilterWindow(_ sender: AnyObject) {
    afWindow.showWindow(self)
  }

  @IBAction func showAboutWindow(_ sender: AnyObject) {
    aboutWindow.showWindow(self)
  }

  @IBAction func showHistoryWindow(_ sender: AnyObject) {
    historyWindow.showWindow(self)
  }

  @IBAction func showLogWindow(_ sender: AnyObject) {
    logWindow.showWindow(self)
  }

  @IBAction func showHighlights(_ sender: AnyObject) {
    guideWindow.show(pages: [.highlights])
  }

  @IBAction func helpAction(_ sender: AnyObject) {
    NSWorkspace.shared.open(URL(string: AppData.helpLink)!)
  }

  @IBAction func githubAction(_ sender: AnyObject) {
    NSWorkspace.shared.open(URL(string: AppData.githubLink)!)
  }

  @IBAction func websiteAction(_ sender: AnyObject) {
    NSWorkspace.shared.open(URL(string: AppData.websiteLink)!)
  }

  @objc func reloadAllPlugins(_ sender: NSMenuItem) {
    PlayerCore.acquirePluginUnloadPermit(identifier: BundledAirPlayPluginManager.identifier) { result in
      switch result {
      case .success(let permit):
        self.reloadAllPluginsAfterUnloadBarrier()
        permit.release()
      case .failure(let error):
        Logger.log("Unable to reload plugins because AirPlay did not stop: \(error.localizedDescription)",
                   level: .error)
        self.presentPluginLifecycleFailure(error)
      }
    }
  }

  private func reloadAllPluginsAfterUnloadBarrier() {
    // Remove the developer tool menu item that retains the plugin instance
    AppDelegate.shared.menuController.pluginMenu.items
      .compactMap { $0.submenu }.flatMap { $0.items }
      .forEach { $0.representedObject = nil }
    AppDelegate.shared.menuController.pluginMenu.removeAllItems()

    for player in PlayerCore.playerCores {
      player.clearPlugins()
    }

    JavascriptPlugin.recreateAllPlugins()
    JavascriptPlugin.loadGlobalInstances()

    for player in PlayerCore.playerCores {
      for plugin in JavascriptPlugin.plugins {
        player.reloadPlugin(plugin, forced: true)
      }
      // Try to emit the events that are already emitted.
      // Of course this is not exhaustive, so users shouldn't rely on this function
      if player.mainWindow.loaded {
        player.events.emit(.windowLoaded)
      }
      player.events.emit(.mpvInitialized)
      if player.info.state == .playing {
        player.events.emit(.fileLoaded)
        player.events.emit(.fileStarted)
      }
    }
  }

  func presentPluginLifecycleFailure(_ error: Error) {
    Utility.showAlert("plugin.install_error", arguments: [error.localizedDescription], style: .warning,
                      sheetWindow: NSApp.keyWindow)
  }
  
  @objc func toggleNewSettings(_ sender: AnyObject) {
    Preference.enableNewSettings = !Preference.enableNewSettings
  }

  /// Dump contents of all player cores to a txt file. Strictly for debugging. No localization needed.
  @IBAction func dumpDebugInfo(_ sender: AnyObject) {
    struct FileStream: TextOutputStream {
      let handle: FileHandle
      mutating func write(_ string: String) {
        handle.write(Data(string.utf8))
      }
    }

    let alert = NSAlert()
    let path = NSString(string: "~/Downloads/iina-debug-dump-\(Date.timeIntervalSinceReferenceDate).txt").expandingTildeInPath
    let url = URL(fileURLWithPath: path)
    FileManager.default.createFile(atPath: path, contents: nil)
    guard let handle = try? FileHandle(forWritingTo: url) else {
      alert.messageText = "Error"
      alert.informativeText = "Cannot get file handle at \(path)."
      alert.alertStyle = .critical
      alert.runModal()
      return
    }

    var stream = FileStream(handle: handle)
    for player in PlayerCore.playerCores {
      dump(player, to: &stream)
      stream.write("\n\n")
    }

    alert.messageText = "Completed"
    alert.informativeText = """
      Dumped debug info to \(path).\n
      The file contains filenames and URLs in your playlist! \
      For your privacy, please consider removing them before sharing.
      """
    alert.alertStyle = .informational
    alert.runModal()
  }

  private func registerUserDefaultValues() {
    UserDefaults.standard.register(defaults: [String: Any](uniqueKeysWithValues: Preference.defaultPreference.map { ($0.0.rawValue, $0.1) }))
  }

  // MARK: - FFmpeg version parsing

  /// Extracts the major version number from the given FFmpeg encoded version number.
  ///
  /// This is a Swift implementation of the FFmpeg macro `AV_VERSION_MAJOR`.
  /// - Parameter version: Encoded version number in FFmpeg proprietary format.
  /// - Returns: The major version number
  private static func avVersionMajor(_ version: UInt32) -> UInt32 {
    version >> 16
  }

  /// Extracts the minor version number from the given FFmpeg encoded version number.
  ///
  /// This is a Swift implementation of the FFmpeg macro `AV_VERSION_MINOR`.
  /// - Parameter version: Encoded version number in FFmpeg proprietary format.
  /// - Returns: The minor version number
  private static func avVersionMinor(_ version: UInt32) -> UInt32 {
    (version & 0x00FF00) >> 8
  }

  /// Extracts the micro version number from the given FFmpeg encoded version number.
  ///
  /// This is a Swift implementation of the FFmpeg macro `AV_VERSION_MICRO`.
  /// - Parameter version: Encoded version number in FFmpeg proprietary format.
  /// - Returns: The micro version number
  private static func avVersionMicro(_ version: UInt32) -> UInt32 {
    version & 0xFF
  }

  /// Forms a string representation from the given FFmpeg encoded version number.
  ///
  /// FFmpeg returns the version number of its libraries encoded into an unsigned integer. The FFmpeg source
  /// `libavutil/version.h` describes FFmpeg's versioning scheme and provides C macros for operating on encoded
  /// version numbers. Since the macros can't be used in Swift code we've had to code equivalent functions in Swift.
  /// - Parameter version: Encoded version number in FFmpeg proprietary format.
  /// - Returns: A string containing the version number.
  private static func versionAsString(_ version: UInt32) -> String {
    let major = AppDelegate.avVersionMajor(version)
    let minor = AppDelegate.avVersionMinor(version)
    let micro = AppDelegate.avVersionMicro(version)
    return "\(major).\(minor).\(micro)"
  }

  // MARK: - Recent Documents

  /// Empties the recent documents list for the application.
  ///
  /// This is part of a workaround for macOS Sonoma clearing the list of recent documents. See the method
  /// `restoreRecentDocuments` and the issue [#4688](https://github.com/iina/iina/issues/4688) for more
  /// information..
  /// - Parameter sender: The object that initiated the clearing of the recent documents.
  @IBAction
  func clearRecentDocuments(_ sender: Any?) {
    NSDocumentController.shared.clearRecentDocuments(sender)
    saveRecentDocuments()
  }

  /// Adds or replaces an Open Recent menu item corresponding to the data located by the URL.
  ///
  /// This is part of a workaround for macOS Sonoma clearing the list of recent documents. See the method
  /// `restoreRecentDocuments` and the issue [#4688](https://github.com/iina/iina/issues/4688) for more
  /// information..
  /// - Parameter url: The URL to evaluate.
  func noteNewRecentDocumentURL(_ url: URL) {
    NSDocumentController.shared.noteNewRecentDocumentURL(url)
    saveRecentDocuments()
  }

  /// Restore the list of recently opened files.
  ///
  /// For macOS Sonoma `sharedfilelistd` was changed to tie the list of recent documents to the app based on its certificate.
  /// if `sharedfilelistd` determines the list is being accessed by a different app then it clears the list. See issue
  /// [#4688](https://github.com/iina/iina/issues/4688) for details. Apple has now applied this change to macOS
  /// Ventura as well.
  ///
  /// This new behavior does not cause a problem when the code is signed with IINA's certificate. However developer and nightly
  /// builds use an ad hoc certificate. This causes the list of recently opened files to be cleared each time a different unsigned IINA build
  /// is run. As a workaround a copy of the list of recent documents is saved in IINA's preference file to preserve the list and allow it to
  /// be restored when `sharedfilelistd` clears its list.
  ///
  /// If the following is true:
  /// - Workaround has been enabled by setting `enableRecentDocumentsWorkaround`
  /// - Running under macOS Ventura and above
  /// - Recording of recent files is enabled
  /// - The list in  [NSDocumentController.shared.recentDocumentURLs](https://developer.apple.com/documentation/appkit/nsdocumentcontroller/1514976-recentdocumenturls) is empty
  /// - The list in the IINA setting `recentDocuments` is not empty
  ///
  /// Then this method assumes that the macOS daemon `sharedfilelistd` cleared the list and it populates the list of recent
  /// document URLs with the list stored in IINA's settings.
  /// - Note: This workaround can cause significant slowdown at startup if the list of recent documents contains files on a mounted
  ///         volume that is unreachable. For this reason the workaround is disabled by default and must be enabled by running the
  ///         following command in [Terminal](https://support.apple.com/guide/terminal/welcome/mac):
  ///         `defaults write com.colliderli.iina enableRecentDocumentsWorkaround true`
  private func restoreRecentDocuments() {
    guard Preference.bool(for: .enableRecentDocumentsWorkaround),
          #available(macOS 13, *), Preference.bool(for: .recordRecentFiles),
          NSDocumentController.shared.recentDocumentURLs.isEmpty,
          let recentDocuments = Preference.array(for: .recentDocuments),
          !recentDocuments.isEmpty else { return }
    var foundStale = false
    for document in recentDocuments {
      var isStale = false
      // Recent documents are normally stored as bookmark data.
      guard let asData = document as? Data else {
        guard let asString = document as? String, let url = URL(string: asString) else {
          // Should never occur. This is an internal error.
          Logger.log("Saved recent document is of unrecognized type: \(type(of: document))",
                     level: .error)
          continue
        }
        // Saving as a bookmark must have failed and instead the URL was saved as a string.
        NSDocumentController.shared.noteNewRecentDocumentURL(url)
        continue
      }
      // Must not cause macOS to prompt the user to mount a volume when the list contains files that
      // are on volumes that are not currently mounted.
      guard let bookmark = try? URL(resolvingBookmarkData: asData,
                                    options: [.withoutMounting, .withoutUI],
                                    bookmarkDataIsStale: &isStale) else {
        // Creating a URL from a bookmark fails if the original file can not be located or is on a
        // volume that is not mounted. Form a URL from the path contained in the bookmark.
        guard let resource = URL.resourceValues(forKeys: [.pathKey], fromBookmarkData: asData),
              let path = resource.path, let url = URL(string: path) else {
          Logger.log("Unable to obtain obtain the path from a bookmark", level: .error)
          continue
        }
        Logger.log("Unable to create a bookmark, creating URL from path for: \(path)", level: .verbose)
        NSDocumentController.shared.noteNewRecentDocumentURL(url)
        continue
      }
      foundStale = foundStale || isStale
      NSDocumentController.shared.noteNewRecentDocumentURL(bookmark)
    }
    Logger.log("Restored list of recent documents")
    guard foundStale else { return }
    Logger.log("Found stale bookmarks in saved recent documents")
    // Save the recent documents in order to refresh stale bookmarks.
    saveRecentDocuments()
  }

  /// Save the list of recently opened files.
  ///
  /// Save the list of recent documents in [NSDocumentController.shared.recentDocumentURLs](https://developer.apple.com/documentation/appkit/nsdocumentcontroller/1514976-recentdocumenturls)
  /// to `recentDocuments` in the IINA settings property file.
  ///
  /// This is part of a workaround for macOS Sonoma clearing the list of recent documents. See the method
  /// `restoreRecentDocuments` and the issue [#4688](https://github.com/iina/iina/issues/4688) for more
  /// information..
  func saveRecentDocuments() {
    guard Preference.bool(for: .enableRecentDocumentsWorkaround), #available(macOS 13, *) else { return }
    var recentDocuments: [Any] = []
    for document in NSDocumentController.shared.recentDocumentURLs {
      guard let bookmark = try? document.bookmarkData() else {
        // Fall back to storing a string when unable to create a bookmark.
        let path = document.absoluteString
        Logger.log("Unable to create a bookmark, saving recent document as a string: \(path)")
        recentDocuments.append(path)
        continue
      }
      recentDocuments.append(bookmark)
    }
    Preference.set(recentDocuments, for: .recentDocuments)
    if recentDocuments.isEmpty {
      Logger.log("Cleared list of recent documents")
    } else {
      Logger.log("Saved list of recent documents")
    }
  }
}


struct CommandLineStatus {
  var isCommandLine = false
  var isStdin = false
  var openSeparateWindows = false
  var enterMusicMode = false
  var enterPIP = false
  var mpvArguments: [(String, String)] = []
  var iinaArguments: [(String, String)] = []
  var filenames: [String] = []

  mutating func parseArguments(_ args: [String]) {
    mpvArguments.removeAll()
    iinaArguments.removeAll()
    for arg in args {
      let splitted = arg.dropFirst(2).split(separator: "=", maxSplits: 1)
      let name = String(splitted[0])
      if (name.hasPrefix("mpv-")) {
        // mpv args
        let strippedName = String(name.dropFirst(4))
        if strippedName == "-" {
          isStdin = true
        } else {
          let argPair: (String, String)
          if splitted.count <= 1 {
            argPair = (strippedName, "yes")
          } else {
            argPair = (strippedName, String(splitted[1]))
          }
          mpvArguments.append(argPair)
        }
      } else {
        // other args
        if splitted.count <= 1 {
          iinaArguments.append((name, "yes"))
        } else {
          iinaArguments.append((name, String(splitted[1])))
        }
        if name == "stdin" {
          isStdin = true
        }
        if name == "separate-windows" {
          openSeparateWindows = true
        }
        if name == "music-mode" {
          enterMusicMode = true
        }
        if name == "pip" {
          enterPIP = true
        }
      }
    }
  }

  func applyMPVArguments(to playerCore: PlayerCore) {
    Logger.log("Setting mpv properties from arguments: \(mpvArguments)")
    for argPair in mpvArguments {
      if argPair.0 == "shuffle" && argPair.1 == "yes" {
        // Special handling for this one
        Logger.log("Found \"shuffle\" request in command-line args. Adding mpv hook to shuffle playlist")
        playerCore.addShufflePlaylistHook()
        continue
      }
      playerCore.mpv.setString(argPair.0, argPair.1)
    }
  }
}

/// Controller that supports using macOS media keys and remote commands.
///
/// The IINA setting `Use system media control` found on the `Key Bindings` tab of IINA's settings controls use of the
/// macOS [Control Center](https://support.apple.com/guide/mac-help/quickly-change-settings-mchl50f94f8f/mac)
/// Now Playing module. This class handles the use of the AppKit class
/// [MPRemoteCommandCenter](https://developer.apple.com/documentation/mediaplayer/mpremotecommandcenter)
/// which allows IINA to receive and respond to remote control events sent by external accessories and system controls. This includes
/// buttons in the Now Playing module, the media keys, access by Siri, etc.
/// - Important: As IINA is assuming control over a shared macOS feature it is critical that IINA releases control when no media is
///     open. See issue [#4331](https://github.com/iina/iina/issues/4331).
class RemoteCommandController {
  /// The `RemoteCommandController` singleton object.
  static let shared = RemoteCommandController()

  static var useSystemMediaControl: Bool = Preference.bool(for: .useMediaKeys)

  /// Remote commands supported by IINA.
  private let commands: [MPRemoteCommand]

  private var isEnabled = false

  /// Returns the value to use for the [preferredIntervals](https://developer.apple.com/documentation/mediaplayer/mpskipintervalcommand/preferredintervals) property.
  ///
  /// The [MPRemoteCommandCenter](https://developer.apple.com/documentation/MediaPlayer/MPRemoteCommandCenter)
  /// expects the media keys tied to the  [seekBackwardCommand](https://developer.apple.com/documentation/mediaplayer/mpremotecommandcenter/seekbackwardcommand) and the [seekForwardCommand](https://developer.apple.com/documentation/mediaplayer/mpremotecommandcenter/seekforwardcommand) to seek backward and
  /// forward in the current media track. The
  /// [MPSkipIntervalCommand](https://developer.apple.com/documentation/mediaplayer/mpskipintervalcommand)
  /// property [preferredIntervals](https://developer.apple.com/documentation/mediaplayer/mpskipintervalcommand/preferredintervals) provides the number of
  /// seconds pressing the key will skip.
  ///
  /// IINA allows the user to bind a mpv command to the `FORWARD` and `REWIND` media keys. This method must:
  /// - Determine if there is a key binding for the given key and if not return the default of 15 seconds
  /// - Determine if the key is bound to an IINA command and if so return an empty array indicating the property is not applicable
  /// - Determine if the key is bound to the mpv
  ///     [seek](https://mpv.io/manual/stable/#command-interface-seek-%3Ctarget%3E-[%3Cflags%3E]) command
  ///     and if not, return an empty array
  /// - Parse the `target` value of the `seek` command as an integer, if it cannot be parsed log an error and  return an empty array
  /// - If present, parse the `seek` command flags and if any flags other than `exact`, `keyframes` and `relative` are
  ///     present then return an empty array as this is not a normal seek
  /// - When all the above checks pass the key has been bound to a normal seek command and the absolute value of the seek
  ///     command target parameter can be used as the interval
  ///
  /// To see the `preferredIntervals` value open
  /// [Control Center](https://support.apple.com/guide/mac-help/quickly-change-settings-mchl50f94f8f/mac)
  /// and double click on the Now Playing module with IINA playing media. The expanded Now Playing module will contain seek
  /// backward and seek forward buttons. The interval may be shown inside the button icons.
  /// - Parameter key: Media key the value is for.
  /// - Returns: Value to use for` preferredIntervals`.
  private func formPreferredIntervalsValue(_ key: String) -> [NSNumber] {
    guard let keyBinding = PlayerCore.keyBindings[key] else { return [15] }
    guard !keyBinding.isIINACommand else { return [] }
    let action = keyBinding.action
    guard action.count > 1, action[0] == MPVCommand.seek.rawValue else { return [] }
    guard let target = Double(action[1]) else {
      log("""
          Unable to parse seek target as a Double in key binding:
              \(key) \(keyBinding.rawAction)
          """, level: .error)
      return []
    }
    if action.count > 2 {
      let allowedFlags: Set<String> = ["exact", "keyframes", "relative"]
      // Multiple flags can be composed using `+`, and each one must be valid
      let flags = action[2].split(separator: "+")

      guard flags.allSatisfy({ allowedFlags.contains(String($0)) }) else {
        log("""
            Seek flag was not one of \(allowedFlags.map({ "'\($0)'" }).joined(separator: ", ")), not setting seek interval:
                \(key) \(keyBinding.rawAction)
            """)
        return []
      }
    }
    // The seek command target may be negative to indicate seeking backwards, however the remote
    // command dictates the direction and requires that the interval to be positive.
    let seconds = abs(target)
    log("Seek interval for the \(key) key is \(seconds) s")
    return [NSNumber(value: seconds)]
  }

  func disable() {
    guard isEnabled else { return }
    commands.forEach { $0.removeTarget(nil) }
    isEnabled = false
    log("Disabled media keys and remote commands")
  }

  func enable() {
    guard RemoteCommandController.useSystemMediaControl, !isEnabled else { return }
    let remoteCommand = MPRemoteCommandCenter.shared()

    // For each command, apply a configured keybinding or fallback to default values.
    remoteCommand.playCommand.addTarget { _ in
      if let action = PlayerCore.keyBindings["PLAYONLY"] {
        PlayerCore.lastActive.mainWindow.handleKeyBinding(action)
      } else {
        PlayerCore.lastActive.resume()
      }
      return .success
    }
    remoteCommand.pauseCommand.addTarget { _ in
      if let action = PlayerCore.keyBindings["PAUSEONLY"] {
        PlayerCore.lastActive.mainWindow.handleKeyBinding(action)
      } else {
        PlayerCore.lastActive.pause()
      }
      return .success
    }
    remoteCommand.togglePlayPauseCommand.addTarget { _ in
      if let action = PlayerCore.keyBindings["PLAYPAUSE"] {
        PlayerCore.lastActive.mainWindow.handleKeyBinding(action)
      } else {
        PlayerCore.lastActive.togglePause()
      }
      return .success
    }
    remoteCommand.stopCommand.addTarget { _ in
      if let action = PlayerCore.keyBindings["STOP"] {
        PlayerCore.lastActive.mainWindow.handleKeyBinding(action)
      } else {
        PlayerCore.lastActive.stop()
      }
      return .success
    }
    remoteCommand.nextTrackCommand.addTarget { _ in
      if let action = PlayerCore.keyBindings["NEXT"] {
        PlayerCore.lastActive.mainWindow.handleKeyBinding(action)
      } else {
        PlayerCore.lastActive.navigateInPlaylist(nextMedia: true)
      }
      return .success
    }
    remoteCommand.previousTrackCommand.addTarget { _ in
      if let action = PlayerCore.keyBindings["PREV"] {
        PlayerCore.lastActive.mainWindow.handleKeyBinding(action)
      } else {
        PlayerCore.lastActive.navigateInPlaylist(nextMedia: false)
      }
      return .success
    }
    remoteCommand.skipForwardCommand.preferredIntervals = formPreferredIntervalsValue("FORWARD")
    remoteCommand.skipForwardCommand.addTarget { event in
      if let action = PlayerCore.keyBindings["FORWARD"] {
        PlayerCore.lastActive.mainWindow.handleKeyBinding(action)
      } else {
        PlayerCore.lastActive.seek(relativeSecond: (event as! MPSkipIntervalCommandEvent).interval, option: .exact)
      }
      return .success
    }
    remoteCommand.skipBackwardCommand.preferredIntervals = formPreferredIntervalsValue("REWIND")
    remoteCommand.skipBackwardCommand.addTarget { event in
      if let action = PlayerCore.keyBindings["REWIND"] {
        PlayerCore.lastActive.mainWindow.handleKeyBinding(action)
      } else {
        PlayerCore.lastActive.seek(relativeSecond: -(event as! MPSkipIntervalCommandEvent).interval, option: .exact)
      }
      return .success
    }
    remoteCommand.changeRepeatModeCommand.addTarget { _ in
      PlayerCore.lastActive.nextLoopMode()
      return .success
    }
    remoteCommand.changePlaybackRateCommand.supportedPlaybackRates = [0.5, 1, 1.5, 2]
    remoteCommand.changePlaybackRateCommand.addTarget { event in
      PlayerCore.lastActive.setSpeed(Double((event as! MPChangePlaybackRateCommandEvent).playbackRate))
      return .success
    }
    remoteCommand.changePlaybackPositionCommand.addTarget { event in
      PlayerCore.lastActive.seek(absoluteSecond: (event as! MPChangePlaybackPositionCommandEvent).positionTime)
      return .success
    }
    isEnabled = true
    log("Enabled media keys and remote commands")
  }

  // MARK: - Private Functions

  private func log(_ message: @autoclosure () -> String, level: Logger.Level = .debug) {
    Logger.log(message, level: level, subsystem: Logger.Sub.nowPlaying)
  }

  private init() {
    // Remote commands IINA supports.
    let remoteCommand = MPRemoteCommandCenter.shared()
    commands = [
      remoteCommand.changePlaybackPositionCommand,
      remoteCommand.changePlaybackRateCommand,
      remoteCommand.changeRepeatModeCommand,
      remoteCommand.nextTrackCommand,
      remoteCommand.pauseCommand,
      remoteCommand.playCommand,
      remoteCommand.previousTrackCommand,
      remoteCommand.skipBackwardCommand,
      remoteCommand.skipForwardCommand,
      remoteCommand.stopCommand,
      remoteCommand.togglePlayPauseCommand]

    NotificationCenter.default.addObserver(forName: .iinaGlobalKeyBindingsChanged, object: nil,
                                           queue: .main) { [unowned self] _ in
      guard isEnabled else { return }
      // The user has modified the key bindings, possibly changing the mpv commands associated with
      // the FORWARD and REWIND media keys. The preferredIntervals values are set based on the mpv
      // commands assigned to those keys. The Now Playing module may display the interval in the
      // seek backward and seek forward buttons causing the value displayed in the Now Playing
      // module buttons to to be out of date. Merely updating the preferredIntervals values is
      // insufficient to get the Now Playing module to update its buttons. Support for media keys
      // and remote commands must be disabled and then re-enabled.
      log("Restarting support for remote commands due to changes to key bindings")
      disable()
      // Immediately re-enabling media keys and remote commands only partially worked. The Now
      // Playing module would update buttons if the module was expanded, but the buttons shown in
      // the module's small form would still display the old interval. Work around this curious
      // Now Playing behavior by delaying the re-enabling.
      DispatchQueue.main.asyncAfter(deadline: DispatchTime.now() + 1) { self.enable() }
    }
  }
}

extension ProcessInfo.ThermalState: @retroactive CustomStringConvertible {
  public var description: String {
    switch self {
    case .nominal:
      "nominal"
    case .fair:
      "fair"
    case .serious:
      "serious"
    case .critical:
      "critical"
    @unknown default:
      "unknown"
    }
  }
}
