func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
  guard condition() else {
    fputs("FAIL: \(message)\n", stderr)
    exit(1)
  }
}

let root = FileManager.default.temporaryDirectory
  .appendingPathComponent("airplay-package-integrity-\(UUID().uuidString)", isDirectory: true)
let bin = root.appendingPathComponent("bin", isDirectory: true)
try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: root) }

let helper = root.appendingPathComponent(AirPlayPackageIntegrity.helperPath)
let ffmpeg = root.appendingPathComponent(AirPlayPackageIntegrity.ffmpegPath)
try Data("synthetic helper payload".utf8).write(to: helper)
try Data("synthetic ffmpeg payload".utf8).write(to: ffmpeg)
try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper.path)
try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: ffmpeg.path)

guard let helperDigest = AirPlayPackageIntegrity.sha256(fileAt: helper),
      let ffmpegDigest = AirPlayPackageIntegrity.sha256(fileAt: ffmpeg) else {
  fatalError("Could not hash synthetic executable files")
}
let versions = Data("helper_sha256=\(helperDigest)\nffmpeg_sha256=\(ffmpegDigest)\n".utf8)
guard let expected = AirPlayPackageIntegrity.parseVersions(versions) else {
  fatalError("Valid VERSIONS manifest did not parse")
}
expect(AirPlayPackageIntegrity.matchesExecutables(at: root, expectedDigests: expected),
       "clean executable payloads should match their manifest")
let packageSnapshotFiles: [String: Data] = [
  "Info.json": Data("{\"identifier\":\"dev.faruk.iina-airplay\"}".utf8),
  "main.js": Data("synthetic plugin entry".utf8),
  "sidebar.html": Data("synthetic sidebar".utf8),
  "bin/VERSIONS": versions,
]
for (path, data) in packageSnapshotFiles {
  try data.write(to: root.appendingPathComponent(path))
}
expect(AirPlayPackageIntegrity.matchesPackageSnapshot(
         at: root, expectedFiles: packageSnapshotFiles, expectedDigests: expected
       ), "a clean staged package should pass the same complete gate used by fresh installation")
try Data("corrupt plugin entry".utf8).write(to: root.appendingPathComponent("main.js"))
expect(!AirPlayPackageIntegrity.matchesPackageSnapshot(
         at: root, expectedFiles: packageSnapshotFiles, expectedDigests: expected
       ), "fresh installation must reject a staged package with a corrupted plugin entry")
try packageSnapshotFiles["main.js"]!.write(to: root.appendingPathComponent("main.js"))
try FileManager.default.removeItem(at: root.appendingPathComponent("sidebar.html"))
expect(!AirPlayPackageIntegrity.matchesPackageSnapshot(
         at: root, expectedFiles: packageSnapshotFiles, expectedDigests: expected
       ), "fresh installation must reject a staged package with a missing expected file")
try packageSnapshotFiles["sidebar.html"]!.write(to: root.appendingPathComponent("sidebar.html"))
try Data("corrupt helper payload".utf8).write(to: helper)
expect(!AirPlayPackageIntegrity.matchesPackageSnapshot(
         at: root, expectedFiles: packageSnapshotFiles, expectedDigests: expected
       ), "fresh installation must reject executable bytes that differ from VERSIONS")
try Data("synthetic helper payload".utf8).write(to: helper)
let replacementFFmpegPrefix = ffmpegDigest.first == "0" ? "1" : "0"
let mismatchedFFmpegDigest = replacementFFmpegPrefix + String(ffmpegDigest.dropFirst())
let mismatchedFFmpegVersions = Data(
  "helper_sha256=\(helperDigest)\nffmpeg_sha256=\(mismatchedFFmpegDigest)\n".utf8
)
guard let mismatchedFFmpegExpected = AirPlayPackageIntegrity.parseVersions(mismatchedFFmpegVersions) else {
  fatalError("Well-formed mismatched FFmpeg digest should parse before byte verification")
}
expect(!AirPlayPackageIntegrity.matchesExecutables(at: root, expectedDigests: mismatchedFFmpegExpected),
       "a well-formed VERSIONS digest that does not match FFmpeg bytes must fail integrity check")
expect(AirPlayPackageIntegrity.verifiedNewerInstallStatus(at: root, versionsData: versions) == .newerThanBundle,
       "a newer installed package with verified executable bytes should be retained")
expect(AirPlayPackageIntegrity.verifiedNewerInstallStatus(at: root, versionsData: nil) == .unrepairableNewer,
       "a newer installed package with a missing manifest must fail closed without offering a retry")
expect(AirPlayPackageIntegrity.verifiedNewerInstallStatus(
         at: root, versionsData: Data("helper_sha256=bad\nffmpeg_sha256=bad\n".utf8)
       ) == .unrepairableNewer,
       "a newer installed package with malformed digests must fail closed without offering a retry")

let previousOrder = ["other.plugin", "dev.faruk.iina-airplay", "last.plugin"]
guard let updatedOrder = AirPlayPluginUpdatePreservation.replacing(
  previousOrder, at: 1, with: "dev.faruk.iina-airplay"
) else {
  fatalError("Valid plugin replacement index was rejected")
}
expect(updatedOrder == previousOrder, "replacing the same plugin ID must preserve its list position")
expect(AirPlayPluginUpdatePreservation.replacing(previousOrder, at: 3, with: "invalid") == nil,
       "replacement helper must reject an invalid order index")
expect(AirPlayPluginUpdatePreservation.shouldRemainEnabled(
         wasEnabled: true, previousPermissions: ["filesystem"], updatedPermissions: ["filesystem"]
       ), "an enabled plugin with unchanged permissions should stay enabled")
expect(!AirPlayPluginUpdatePreservation.shouldRemainEnabled(
         wasEnabled: true, previousPermissions: ["filesystem"], updatedPermissions: ["filesystem", "network"]
       ), "an enabled plugin with added permissions must remain disabled")
expect(!AirPlayPluginUpdatePreservation.shouldRemainEnabled(
         wasEnabled: false, previousPermissions: ["filesystem"], updatedPermissions: ["filesystem"]
       ), "an already disabled plugin must remain disabled after update")

// Exercise the production root-move helper with identifier-keyed state beside the package.
let layoutRoot = root.appendingPathComponent("preservation-layout", isDirectory: true)
let pluginsDirectory = layoutRoot.appendingPathComponent("plugins", isDirectory: true)
let pluginIdentifier = "dev.faruk.iina-airplay"
let installedPackage = pluginsDirectory.appendingPathComponent("\(pluginIdentifier).iinaplugin", isDirectory: true)
let stagedPackage = pluginsDirectory.appendingPathComponent(".temp.preservation-test", isDirectory: true)
let backupPackage = pluginsDirectory.appendingPathComponent(".airplay-update-backup.preservation-test", isDirectory: true)
let pluginDataDirectory = pluginsDirectory.appendingPathComponent(".data/\(pluginIdentifier)", isDirectory: true)
let pluginPreferencesFile = pluginsDirectory.appendingPathComponent(".preferences/\(pluginIdentifier).plist")
try FileManager.default.createDirectory(at: installedPackage, withIntermediateDirectories: true)
try FileManager.default.createDirectory(at: stagedPackage, withIntermediateDirectories: true)
try FileManager.default.createDirectory(at: pluginDataDirectory, withIntermediateDirectories: true)
try FileManager.default.createDirectory(at: pluginPreferencesFile.deletingLastPathComponent(), withIntermediateDirectories: true)
try Data("old package".utf8).write(to: installedPackage.appendingPathComponent("main.js"))
try Data("new package".utf8).write(to: stagedPackage.appendingPathComponent("main.js"))
let storedPluginData = Data("saved plugin data".utf8)
let storedPluginPreferences = Data("{lanAddress:192.168.1.18}".utf8)
try storedPluginData.write(to: pluginDataDirectory.appendingPathComponent("state.json"))
try storedPluginPreferences.write(to: pluginPreferencesFile)

try AirPlayPluginUpdatePreservation.movePackageDirectory(
  from: installedPackage, to: backupPackage, under: pluginsDirectory
)
try AirPlayPluginUpdatePreservation.movePackageDirectory(
  from: stagedPackage, to: installedPackage, under: pluginsDirectory
)
let pluginDataAfterUpdate = try Data(contentsOf: pluginDataDirectory.appendingPathComponent("state.json"))
let pluginPreferencesAfterUpdate = try Data(contentsOf: pluginPreferencesFile)
expect(pluginDataAfterUpdate == storedPluginData,
       "package update must leave identifier-keyed plugin data byte-identical")
expect(pluginPreferencesAfterUpdate == storedPluginPreferences,
       "package update must leave the identifier-keyed preference plist byte-identical")
expect(updatedOrder == previousOrder, "package update must not reorder the saved plugin identifiers")

try AirPlayPluginUpdatePreservation.movePackageDirectory(
  from: installedPackage, to: stagedPackage, under: pluginsDirectory
)
try AirPlayPluginUpdatePreservation.movePackageDirectory(
  from: backupPackage, to: installedPackage, under: pluginsDirectory
)
let pluginDataAfterRollback = try Data(contentsOf: pluginDataDirectory.appendingPathComponent("state.json"))
let pluginPreferencesAfterRollback = try Data(contentsOf: pluginPreferencesFile)
expect(pluginDataAfterRollback == storedPluginData,
       "package rollback must leave identifier-keyed plugin data byte-identical")
expect(pluginPreferencesAfterRollback == storedPluginPreferences,
       "package rollback must leave the identifier-keyed preference plist byte-identical")
do {
  try AirPlayPluginUpdatePreservation.movePackageDirectory(
    from: installedPackage, to: layoutRoot.appendingPathComponent("escaped.iinaplugin"), under: pluginsDirectory
  )
  fatalError("Package move helper accepted a destination outside the plugins directory")
} catch AirPlayPluginUpdatePreservation.MoveError.outsidePluginDirectory {
  // Expected: managed swaps are confined to sibling package roots.
} catch {
  fatalError("Package move failed unexpectedly: \(error)")
}

expect(AirPlayPackageIntegrity.parseVersions(Data("helper_sha256=\(helperDigest)\n".utf8)) == nil,
       "manifest missing FFmpeg digest must fail closed")
expect(AirPlayPackageIntegrity.parseVersions(Data("helper_sha256=bad\nffmpeg_sha256=\(ffmpegDigest)\n".utf8)) == nil,
       "malformed digest must fail closed")
expect(AirPlayPackageIntegrity.parseVersions(Data("helper_sha256=\(helperDigest)\nhelper_sha256=\(helperDigest)\nffmpeg_sha256=\(ffmpegDigest)\n".utf8)) == nil,
       "duplicate manifest key must fail closed")

let preferencesPageManifest = Data("{\"preferencesPage\":\"preferences.html\"}".utf8)
guard let preferencePackageEntries = AirPlayPackageIntegrity.packageEntryPaths(forManifestData: preferencesPageManifest) else {
  fatalError("A safe local preferences page should be included in the package snapshot")
}
expect(preferencePackageEntries.contains("preferences.html"),
       "local preferences page must participate in managed package identity")
expect(AirPlayPackageIntegrity.packageEntryPaths(
         forManifestData: Data("{\"preferencesPage\":\"../outside.html\"}".utf8)
       ) == nil,
       "package snapshot must reject preferences pages that escape the package root")
let preferencesPageURL = root.appendingPathComponent("preferences.html")
let bundledPreferencesPage = Data("<html>bundled preferences</html>".utf8)
try bundledPreferencesPage.write(to: preferencesPageURL)
let preferencesPageSnapshot = ["preferences.html": bundledPreferencesPage]
expect(AirPlayPackageIntegrity.matchesPackageEntries(at: root, expectedFiles: preferencesPageSnapshot),
       "clean preferences page should match the managed package snapshot")
try Data("tampered preferences page".utf8).write(to: preferencesPageURL)
expect(!AirPlayPackageIntegrity.matchesPackageEntries(at: root, expectedFiles: preferencesPageSnapshot),
       "changed preferences page must make the managed package repairable")

try Data("tampered helper payload".utf8).write(to: helper)
expect(!AirPlayPackageIntegrity.matchesExecutables(at: root, expectedDigests: expected),
       "changed helper bytes must fail integrity check")
try Data("synthetic helper payload".utf8).write(to: helper)
try Data("tampered ffmpeg payload".utf8).write(to: ffmpeg)
expect(!AirPlayPackageIntegrity.matchesExecutables(at: root, expectedDigests: expected),
       "changed FFmpeg bytes must fail integrity check")
try Data("synthetic ffmpeg payload".utf8).write(to: ffmpeg)
try FileManager.default.setAttributes([.posixPermissions: 0o051], ofItemAtPath: helper.path)
expect(!AirPlayPackageIntegrity.matchesExecutables(at: root, expectedDigests: expected),
       "execute bits without owner execute permission must fail integrity check")
try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper.path)
try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: helper.path)
expect(!AirPlayPackageIntegrity.matchesExecutables(at: root, expectedDigests: expected),
       "non-executable helper must fail integrity check")
try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper.path)
try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: ffmpeg.path)
expect(!AirPlayPackageIntegrity.matchesExecutables(at: root, expectedDigests: expected),
       "non-executable FFmpeg must fail integrity check")
try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: ffmpeg.path)
try FileManager.default.removeItem(at: helper)
expect(!AirPlayPackageIntegrity.matchesExecutables(at: root, expectedDigests: expected),
       "missing helper must fail integrity check")
try Data("synthetic helper payload".utf8).write(to: helper)
try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper.path)
try FileManager.default.removeItem(at: ffmpeg)
expect(!AirPlayPackageIntegrity.matchesExecutables(at: root, expectedDigests: expected),
       "missing FFmpeg must fail integrity check")

let generation = AirPlayPackageCheckGeneration()
let firstRequest = generation.begin()
let secondRequest = generation.begin()
expect(!generation.isCurrent(firstRequest), "older asynchronous check must become stale")
expect(generation.isCurrent(secondRequest), "latest asynchronous check must remain current")

let cleanupRoot = root.appendingPathComponent(".temp.delayed-cleanup", isDirectory: true)
let nestedCleanupRoot = cleanupRoot.appendingPathComponent("bin/nested", isDirectory: true)
try FileManager.default.createDirectory(at: nestedCleanupRoot, withIntermediateDirectories: true)
try Data(repeating: 0x5a, count: 64 * 1024).write(
  to: nestedCleanupRoot.appendingPathComponent("synthetic-payload.bin")
)
let cleanupCompleted = DispatchSemaphore(value: 0)
var cleanupRanOnMainThread = true
AirPlayPackageBackgroundWork.perform {
  cleanupRanOnMainThread = Thread.isMainThread
  Thread.sleep(forTimeInterval: 0.1)
  try? FileManager.default.removeItem(at: cleanupRoot)
  cleanupCompleted.signal()
}
expect(cleanupCompleted.wait(timeout: .now() + 2) == .success,
       "delayed recursive cleanup should finish within the bounded harness deadline")
expect(!cleanupRanOnMainThread, "delayed recursive cleanup must run away from the main thread")
expect(!FileManager.default.fileExists(atPath: cleanupRoot.path),
       "delayed cleanup should remove the synthetic nested staging tree")

print("AirPlay package integrity checks passed")
