import Foundation

func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
  guard condition() else {
    fputs("FAIL: \(message)\n", stderr)
    exit(1)
  }
}

final class FakeEventListener: EventCallable {
  let ownerIdentifier: String?
  private let action: (@escaping (Result<Void, Error>) -> Void) -> Void
  private let shutdownAction: (([Any], @escaping (Result<Void, Error>) -> Void) -> Void)?
  private(set) var synchronousCalls = 0
  private(set) var shutdownCalls = 0

  init(ownerIdentifier: String?,
       shutdownAction: (([Any], @escaping (Result<Void, Error>) -> Void) -> Void)? = nil,
       action: @escaping (@escaping (Result<Void, Error>) -> Void) -> Void) {
    self.ownerIdentifier = ownerIdentifier
    self.shutdownAction = shutdownAction
    self.action = action
  }

  func call(withArguments args: [Any]) {
    synchronousCalls += 1
  }

  func callAndWaitForPromise(withArguments args: [Any],
                             completion: @escaping (Result<Void, Error>) -> Void) {
    action(completion)
  }

  func callAfterPlayerShutdown(withArguments args: [Any],
                               completion: @escaping (Result<Void, Error>) -> Void) {
    shutdownCalls += 1
    guard let shutdownAction else {
      completion(.failure(EventController.AsyncEventError.listenerRejected("missing test shutdown action")))
      return
    }
    shutdownAction(args, completion)
  }
}

enum HarnessError: Error {
  case rejected
  case timedOut
}

func runUnloadBarrier(_ controllers: [EventController], identifier: String,
                      timeout: TimeInterval,
                      completion: @escaping (Result<Void, Error>) -> Void) {
  let completionOnce = EventPromiseCompletionOnce(completion)
  let timeoutWork = DispatchWorkItem {
    completionOnce.finish(.failure(HarnessError.timedOut))
  }
  DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timeoutWork)

  guard !controllers.isEmpty else {
    timeoutWork.cancel()
    completionOnce.finish(.success(()))
    return
  }
  let barrier = EventPromiseBarrier(count: controllers.count) { result in
    timeoutWork.cancel()
    completionOnce.finish(result)
  }
  for controller in controllers {
    controller.emitAndWaitForPluginPromises(.pluginWillUnload,
                                             pluginIdentifier: identifier,
                                             data: [identifier]) { result in
      barrier.receive(result)
    }
  }
}

func awaitResult(_ launch: (@escaping (Result<Void, Error>) -> Void) -> Void,
                 timeout: TimeInterval = 2) -> Result<Void, Error>? {
  let semaphore = DispatchSemaphore(value: 0)
  var result: Result<Void, Error>?
  launch {
    result = $0
    semaphore.signal()
  }
  guard semaphore.wait(timeout: .now() + timeout) == .success else { return nil }
  return result
}

func makeController(identifier: String,
                    action: @escaping (@escaping (Result<Void, Error>) -> Void) -> Void) -> EventController {
  let controller = EventController()
  _ = controller.addListener(FakeEventListener(ownerIdentifier: identifier, action: action),
                             for: .pluginWillUnload)
  return controller
}

func emitHostUnloadIfNeeded(_ controller: EventController,
                            identifier: String,
                            unloadPermitHeld: Bool) {
  // Mirror PlayerCore.emitPluginWillUnload: the permit has already dispatched and awaited the
  // callback, so commit-time cleanup must not dispatch it again.
  guard !unloadPermitHeld else { return }
  controller.emit(.pluginWillUnload, data: identifier)
}

final class SimulatedPlayerContext {
  enum State: Equatable {
    case live
    case shuttingDown
    case shutDown
  }

  let controller: EventController
  private let lock = NSLock()
  private var storedState: State
  private var storedTimerCount = 3
  private var storedPluginRetained = true

  init(state: State, controller: EventController) {
    storedState = state
    self.controller = controller
  }

  var state: State {
    lock.lock()
    defer { lock.unlock() }
    return storedState
  }

  var timerCount: Int {
    lock.lock()
    defer { lock.unlock() }
    return storedTimerCount
  }

  var pluginRetained: Bool {
    lock.lock()
    defer { lock.unlock() }
    return storedPluginRetained
  }

  func finishShutdown() {
    lock.lock()
    storedState = .shutDown
    lock.unlock()
  }

  func prepareForPlayerShutdown(identifier: String) {
    guard state == .live else { return }
    controller.emitToPlugin(.pluginWillUnload, identifier: identifier, data: [identifier])
    controller.removeAllListeners()
    lock.lock()
    storedTimerCount = 0
    storedPluginRetained = false
    storedState = .shuttingDown
    lock.unlock()
  }

  func retireAfterShutdown() {
    guard state == .shutDown else { return }
    controller.removeAllListeners()
    lock.lock()
    storedTimerCount = 0
    storedPluginRetained = false
    lock.unlock()
  }
}

func runPlayerContextUnloadBarrier(_ contexts: [SimulatedPlayerContext],
                                   identifier: String,
                                   timeout: TimeInterval,
                                   completion: @escaping (Result<Void, Error>) -> Void) {
  // Mirror the host rule: never invoke JS for a shutting-down context and never treat its later
  // disappearance as proof that the helper stopped. Retire fully dead state without callbacks.
  let completionOnce = EventPromiseCompletionOnce(completion)
  let deadline = DispatchTime.now() + timeout
  let timeoutWork = DispatchWorkItem { completionOnce.finish(.failure(HarnessError.timedOut)) }
  DispatchQueue.global().asyncAfter(deadline: deadline, execute: timeoutWork)

  func inspectContexts() {
    guard DispatchTime.now() < deadline else { return }
    contexts.filter { $0.state == .shutDown }.forEach { $0.retireAfterShutdown() }
    guard !contexts.contains(where: { $0.state == .shuttingDown }) else {
      timeoutWork.cancel()
      completionOnce.finish(.failure(EventController.AsyncEventError.playerUnavailable(identifier)))
      return
    }
    let liveControllers = contexts.filter { $0.state == .live }.map(\.controller)
    let remaining = max(0.01, Double(deadline.uptimeNanoseconds - DispatchTime.now().uptimeNanoseconds) / 1_000_000_000)
    runUnloadBarrier(liveControllers, identifier: identifier, timeout: remaining) { result in
      timeoutWork.cancel()
      completionOnce.finish(result)
    }
  }

  inspectContexts()
}

let startupGate = PluginContextStartupGate()
startupGate.close()
var playerContextsLoaded = false
let startupWasDeferred = startupGate.continueWhenOpen { playerContextsLoaded = true }
expect(startupWasDeferred && !playerContextsLoaded,
       "player/plugin startup must remain deferred while cold migration is unresolved")
startupGate.open()
expect(playerContextsLoaded,
       "startup continuation should run only after cold migration has settled")
expect(!startupGate.continueWhenOpen { playerContextsLoaded = false } && playerContextsLoaded,
       "launch after migration completion should continue immediately without re-deferral")
expect(!PluginOperationErrorPolicy.shouldShowInstallationError(
         PluginOperationCancellationError.applicationTerminating, whileTerminating: true),
       "Quit cancellation must not present an installation-error alert")
expect(PluginOperationErrorPolicy.shouldShowInstallationError(
         PluginOperationCancellationError.applicationTerminating, whileTerminating: false),
       "the termination sentinel outside Quit should remain visible to the user")
expect(PluginOperationErrorPolicy.shouldShowInstallationError(CancellationError(), whileTerminating: true),
       "an unrelated cancellation must remain visible even if Quit begins concurrently")
expect(PluginOperationErrorPolicy.shouldShowInstallationError(HarnessError.timedOut, whileTerminating: true),
       "a genuine stop timeout must remain visible even if Quit begins concurrently")
expect(PluginOperationErrorPolicy.shouldShowInstallationError(HarnessError.rejected, whileTerminating: true),
       "a real plugin stop failure should remain visible during termination")

let identifier = "dev.faruk.iina-airplay"
let quitFlushController = EventController()
let quitFlushListener = FakeEventListener(ownerIdentifier: identifier) { done in done(.success(())) }
let unrelatedQuitListener = FakeEventListener(ownerIdentifier: "other.plugin") { done in done(.success(())) }
_ = quitFlushController.addListener(quitFlushListener, for: .pluginWillUnload)
_ = quitFlushController.addListener(unrelatedQuitListener, for: .pluginWillUnload)
let quitFlushContext = SimulatedPlayerContext(state: .live, controller: quitFlushController)
quitFlushContext.prepareForPlayerShutdown(identifier: identifier)
expect(quitFlushListener.synchronousCalls == 1,
       "player shutdown emits the plugin-unload event before removing generic event listeners")
expect(unrelatedQuitListener.synchronousCalls == 0,
       "player shutdown does not run unrelated plugin callbacks while flushing one plugin")
expect(quitFlushContext.state == .shuttingDown && quitFlushContext.timerCount == 0 &&
       !quitFlushContext.pluginRetained && !quitFlushController.hasListener(for: .pluginWillUnload),
       "player shutdown then clears timers, listeners, and the retained plugin context")

let root = FileManager.default.temporaryDirectory
  .appendingPathComponent("plugin-unload-barrier-\(UUID().uuidString)", isDirectory: true)
let plugins = root.appendingPathComponent("Plugins", isDirectory: true)
let installed = plugins.appendingPathComponent("\(identifier).iinaplugin", isDirectory: true)
let staged = plugins.appendingPathComponent(".temp.test", isDirectory: true)
let dataDirectory = plugins.appendingPathComponent(".data/\(identifier)", isDirectory: true)
let preferencesDirectory = plugins.appendingPathComponent(".preferences", isDirectory: true)
let preferences = preferencesDirectory.appendingPathComponent("\(identifier).plist")
try FileManager.default.createDirectory(at: installed, withIntermediateDirectories: true)
try FileManager.default.createDirectory(at: staged, withIntermediateDirectories: true)
try FileManager.default.createDirectory(at: dataDirectory, withIntermediateDirectories: true)
try FileManager.default.createDirectory(at: preferencesDirectory, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: root) }

let dataBytes = Data("saved cast state".utf8)
let preferenceBytes = Data("saved LAN address preference".utf8)
try Data("old package".utf8).write(to: installed.appendingPathComponent("main.js"))
try Data("staged package".utf8).write(to: staged.appendingPathComponent("main.js"))
try dataBytes.write(to: dataDirectory.appendingPathComponent("state.json"))
try preferenceBytes.write(to: preferences)

let otherIdentifier = "example.other-plugin"
let otherListener = FakeEventListener(ownerIdentifier: otherIdentifier) { done in done(.success(())) }
let filteredController = EventController()
_ = filteredController.addListener(otherListener, for: .pluginWillUnload)
_ = filteredController.addListener(
  FakeEventListener(ownerIdentifier: identifier) { done in done(.success(())) },
  for: .pluginWillUnload)

var observedOriginalDuringPartialStop = false
let delayOne = makeController(identifier: identifier) { done in
  DispatchQueue.global().asyncAfter(deadline: .now() + 0.08) {
    if let partialPackage = try? Data(contentsOf: installed.appendingPathComponent("main.js")) {
      observedOriginalDuringPartialStop = partialPackage == Data("old package".utf8)
    }
    done(.success(()))
  }
}
let delayTwo = makeController(identifier: identifier) { done in
  DispatchQueue.global().asyncAfter(deadline: .now() + 0.16) { done(.success(())) }
}
var movedAfterSuccess = false
let delayedResult = awaitResult({ done in
  runUnloadBarrier([filteredController, delayOne, delayTwo], identifier: identifier, timeout: 1) { result in
    if case .success = result {
      do {
        let backup = plugins.appendingPathComponent(".backup.test", isDirectory: true)
        try FileManager.default.moveItem(at: installed, to: backup)
        try FileManager.default.moveItem(at: staged, to: installed)
        movedAfterSuccess = true
      } catch {
        done(.failure(error))
        return
      }
    }
    done(result)
  }
})
expect(delayedResult != nil, "delayed multi-context unload should settle")
if case .success? = delayedResult {
  expect(observedOriginalDuringPartialStop,
         "installed package must remain untouched while another PlayerCore is still stopping")
  expect(movedAfterSuccess, "package replacement should happen only after every context resolves")
  let installedBytes = try String(contentsOf: installed.appendingPathComponent("main.js"), encoding: .utf8)
  let preservedData = try Data(contentsOf: dataDirectory.appendingPathComponent("state.json"))
  let preservedPreferences = try Data(contentsOf: preferences)
  expect(installedBytes == "staged package",
         "success should install staged package")
  expect(preservedData == dataBytes,
         "package replacement must preserve plugin data")
  expect(preservedPreferences == preferenceBytes,
         "package replacement must preserve identifier-keyed preferences")
} else {
  fatalError("Delayed unload unexpectedly failed: \(String(describing: delayedResult))")
}
expect(otherListener.synchronousCalls == 1,
       "non-target listeners should receive the event without joining the awaited barrier")

// mpv-initiated shutdown dispatches only the exact bundled AirPlay helper callback. It must not
// invoke the generic event path or any other plugin's shutdown callback.
var shutdownStopArgs: [Any] = []
let postMpvShutdownController = EventController()
let unrelatedShutdownListener = FakeEventListener(ownerIdentifier: otherIdentifier,
  shutdownAction: { _, done in done(.success(())) }) { _ in }
let airPlayShutdownListener = FakeEventListener(ownerIdentifier: identifier,
  shutdownAction: { args, done in
    shutdownStopArgs = args
    DispatchQueue.global().asyncAfter(deadline: .now() + 0.03) { done(.success(())) }
  }) { _ in
    fatalError("post-shutdown dispatch must not call the generic listener")
  }
_ = postMpvShutdownController.addListener(unrelatedShutdownListener, for: .playerShutdown)
_ = postMpvShutdownController.addListener(airPlayShutdownListener, for: .playerShutdown)
let postShutdownStop = awaitResult({ done in
  postMpvShutdownController.emitAndWaitForBundledAirPlayShutdown(timeout: 1, completion: done)
})
if case .success? = postShutdownStop {
  expect(airPlayShutdownListener.shutdownCalls == 1,
         "mpv shutdown should call the managed AirPlay helper callback exactly once")
  expect(airPlayShutdownListener.synchronousCalls == 0,
         "mpv shutdown must bypass generic plugin callbacks")
  expect(unrelatedShutdownListener.shutdownCalls == 0 && unrelatedShutdownListener.synchronousCalls == 0,
         "mpv shutdown must not call another plugin")
  expect((shutdownStopArgs.first as? String) == identifier,
         "shutdown callback should receive only the exact AirPlay plugin identifier")
} else {
  fatalError("Bundled AirPlay helper stop should complete after mpv shutdown")
}

let rejectingPostShutdown = EventController()
let rejectingShutdownListener = FakeEventListener(ownerIdentifier: identifier,
  shutdownAction: { _, done in done(.failure(HarnessError.rejected)) }) { _ in
    fatalError("rejected post-shutdown helper stop must not use the generic callback")
  }
_ = rejectingPostShutdown.addListener(rejectingShutdownListener, for: .playerShutdown)
let failedPostShutdown = awaitResult({ done in
  rejectingPostShutdown.emitAndWaitForBundledAirPlayShutdown(timeout: 1, completion: done)
})
if case .failure? = failedPostShutdown {
  expect(rejectingShutdownListener.shutdownCalls == 1 && rejectingShutdownListener.synchronousCalls == 0,
         "helper stop rejection should be observed without generic plugin dispatch")
} else {
  fatalError("Post-shutdown helper failure must be reported")
}

let timedOutPostShutdown = EventController()
let delayedShutdownListener = FakeEventListener(ownerIdentifier: identifier,
  shutdownAction: { _, done in
    DispatchQueue.global().asyncAfter(deadline: .now() + 0.15) { done(.success(())) }
  }) { _ in
    fatalError("timed-out post-shutdown helper stop must not use the generic callback")
  }
_ = timedOutPostShutdown.addListener(delayedShutdownListener, for: .playerShutdown)
let timedOutShutdown = awaitResult({ done in
  timedOutPostShutdown.emitAndWaitForBundledAirPlayShutdown(timeout: 0.03, completion: done)
})
if case .failure? = timedOutShutdown {
  Thread.sleep(forTimeInterval: 0.18)
  expect(delayedShutdownListener.shutdownCalls == 1 && delayedShutdownListener.synchronousCalls == 0,
         "late stop resolution after host timeout must not invoke any new callback")
} else {
  fatalError("Post-shutdown helper wait must be bounded")
}

let missingPostShutdown = EventController()
let missingPostShutdownResult = awaitResult({ done in
  missingPostShutdown.emitAndWaitForBundledAirPlayShutdown(timeout: 1, completion: done)
})
if case .failure? = missingPostShutdownResult {
  expect(missingPostShutdown.listeners.isEmpty,
         "missing AirPlay shutdown listener should fail closed without dispatching generic events")
} else {
  fatalError("Missing shutdown listener must not count as successful helper stop")
}

// A rejected stop must leave the installed directory and sidecar data untouched.
let beforeRejectedPackage = try Data(contentsOf: installed.appendingPathComponent("main.js"))
let beforeRejectedData = try Data(contentsOf: dataDirectory.appendingPathComponent("state.json"))
let rejecting = makeController(identifier: identifier) { done in
  DispatchQueue.global().asyncAfter(deadline: .now() + 0.03) { done(.failure(HarnessError.rejected)) }
}
let rejectedResult = awaitResult({ done in
  runUnloadBarrier([rejecting], identifier: identifier, timeout: 1) { result in
    if case .success = result {
      try? FileManager.default.removeItem(at: installed)
    }
    done(result)
  }
})
expect(rejectedResult != nil, "rejected stop should settle")
if case .failure? = rejectedResult {
  let stillInstalled = try Data(contentsOf: installed.appendingPathComponent("main.js"))
  let stillHasData = try Data(contentsOf: dataDirectory.appendingPathComponent("state.json"))
  expect(stillInstalled == beforeRejectedPackage,
         "rejected stop must not remove or replace installed package")
  expect(stillHasData == beforeRejectedData,
         "rejected stop must preserve plugin data")
} else {
  fatalError("Rejected stop was accepted")
}

let uninstallPackage = plugins.appendingPathComponent("\(identifier)-uninstall.iinaplugin", isDirectory: true)
try FileManager.default.createDirectory(at: uninstallPackage, withIntermediateDirectories: true)
try Data("package queued for uninstall".utf8).write(to: uninstallPackage.appendingPathComponent("main.js"))
var packagePresentWhileUninstallPending = false
let delayedUninstall = makeController(identifier: identifier) { done in
  DispatchQueue.global().asyncAfter(deadline: .now() + 0.08) {
    packagePresentWhileUninstallPending = FileManager.default.fileExists(atPath: uninstallPackage.path)
    done(.success(()))
  }
}
let uninstallResult = awaitResult({ done in
  runUnloadBarrier([delayedUninstall], identifier: identifier, timeout: 1) { result in
    if case .success = result { try? FileManager.default.removeItem(at: uninstallPackage) }
    done(result)
  }
})
if case .success? = uninstallResult {
  expect(packagePresentWhileUninstallPending,
         "uninstall must leave the old package in place until stop resolves")
  expect(!FileManager.default.fileExists(atPath: uninstallPackage.path),
         "successful stop should allow uninstall to remove the package")
  let dataAfterUninstall = try Data(contentsOf: dataDirectory.appendingPathComponent("state.json"))
  let preferencesAfterUninstall = try Data(contentsOf: preferences)
  expect(dataAfterUninstall == dataBytes,
         "uninstall must preserve plugin data")
  expect(preferencesAfterUninstall == preferenceBytes,
         "uninstall must preserve identifier-keyed preferences")
} else {
  fatalError("Delayed uninstall stop unexpectedly failed")
}

// Timeout wins once; a late Promise result cannot trigger a package mutation.
let timeoutListener = makeController(identifier: identifier) { done in
  DispatchQueue.global().asyncAfter(deadline: .now() + 0.18) { done(.success(())) }
}
let timedOutResult = awaitResult({ done in
  runUnloadBarrier([timeoutListener], identifier: identifier, timeout: 0.04) { result in
    if case .success = result {
      try? FileManager.default.removeItem(at: installed)
    }
    done(result)
  }
})
expect(timedOutResult != nil, "timeout should settle")
if case .failure? = timedOutResult {
  Thread.sleep(forTimeInterval: 0.22)
  expect(FileManager.default.fileExists(atPath: installed.path),
         "late stop success after timeout must not mutate package")
} else {
  fatalError("Unresolved stop should time out")
}

let missingController = EventController()
let legacyPackageBytes = try Data(contentsOf: installed.appendingPathComponent("main.js"))
var legacyPluginEnabled = true
let missingResult = awaitResult({ done in
  runUnloadBarrier([missingController], identifier: identifier, timeout: 1) { result in
    if case .success = result {
      legacyPluginEnabled = false
      try? FileManager.default.removeItem(at: installed)
    }
    done(result)
  }
})
if case .failure(let error)? = missingResult {
  expect(legacyPluginEnabled, "legacy package without a stop listener must stay enabled")
  let packageAfterLegacyFailure = try Data(contentsOf: installed.appendingPathComponent("main.js"))
  expect(packageAfterLegacyFailure == legacyPackageBytes,
         "legacy update must leave the installed package unchanged")
  expect(error.localizedDescription.contains("Stop casting in the AirPlay tab") &&
         error.localizedDescription.contains("package unchanged") &&
         error.localizedDescription.contains("External or developer installs are not migrated automatically"),
         "legacy AirPlay failure must give safe recovery steps and explain package preservation")
} else {
  fatalError("Missing AirPlay unload listener should fail closed")
}

let duplicateCompletion = makeController(identifier: identifier) { done in
  done(.success(()))
  done(.failure(HarnessError.rejected))
}
let duplicateResult = awaitResult({ done in
  runUnloadBarrier([duplicateCompletion], identifier: identifier, timeout: 1, completion: done)
})
if case .success? = duplicateResult {
  // The first settlement wins and the second callback is ignored.
} else {
  fatalError("Repeated Promise callbacks must settle the host barrier only once")
}

let commitListener = EventController()
let commitCallback = FakeEventListener(ownerIdentifier: identifier) { done in done(.success(())) }
_ = commitListener.addListener(commitCallback, for: .pluginWillUnload)
let commitResult = awaitResult({ done in
  runUnloadBarrier([commitListener], identifier: identifier, timeout: 1, completion: done)
})
if case .success? = commitResult {
  emitHostUnloadIfNeeded(commitListener, identifier: identifier, unloadPermitHeld: true)
  expect(commitCallback.synchronousCalls == 0,
         "permit commit must not synchronously dispatch a duplicate unload callback")
  emitHostUnloadIfNeeded(commitListener, identifier: identifier, unloadPermitHeld: false)
  expect(commitCallback.synchronousCalls == 1,
         "ordinary unload after permit release may emit the callback")
} else {
  fatalError("Commit-time duplicate callback fixture failed to acquire permit")
}

// A stale mpv-initiated shutdown must not block a live context from completing ordinary disable
// and forced-reload work. The stale listener represents JS/API cleanup that would be unsafe now.
var staleDisableListenerCalled = false
var liveDisableListenerCalled = false
let staleDisableContext = SimulatedPlayerContext(state: .shutDown,
  controller: makeController(identifier: identifier) { done in
    staleDisableListenerCalled = true
    done(.failure(HarnessError.rejected))
  })
let liveDisableContext = SimulatedPlayerContext(state: .live,
  controller: makeController(identifier: identifier) { done in
    DispatchQueue.global().asyncAfter(deadline: .now() + 0.06) {
      liveDisableListenerCalled = true
      done(.success(()))
    }
  })
var pluginDisabledAndReloaded = false
let disableResult = awaitResult({ done in
  runPlayerContextUnloadBarrier([staleDisableContext, liveDisableContext],
                                identifier: identifier,
                                timeout: 1) { result in
    if case .success = result { pluginDisabledAndReloaded = true }
    done(result)
  }
})
if case .success? = disableResult {
  expect(liveDisableListenerCalled, "disable/reload must await the live PlayerCore")
  expect(!staleDisableListenerCalled, "disable/reload must not call into a shut-down PlayerCore")
  expect(staleDisableContext.timerCount == 0 && !staleDisableContext.pluginRetained,
         "stale shutdown must release timers and the retained plugin instance")
  expect(!staleDisableContext.controller.hasListener(for: .pluginWillUnload),
         "stale shutdown must drop event listener references without invoking them")
  expect(pluginDisabledAndReloaded, "disable/reload may commit after live contexts confirm stop")
} else {
  fatalError("A stale shut-down context must not block disable/reload")
}

// App Quit closes windows and begins ordinary player shutdown without waiting for the
// AirPlay unload Promise. If that Promise later resolves, the update's termination guard
// must leave the installed package untouched and discard its staging directory.
let quitRaceStaged = plugins.appendingPathComponent(".temp.quit-race", isDirectory: true)
try FileManager.default.createDirectory(at: quitRaceStaged, withIntermediateDirectories: true)
try Data("quit race candidate".utf8).write(to: quitRaceStaged.appendingPathComponent("main.js"))
let packageBeforeQuitRace = try Data(contentsOf: installed.appendingPathComponent("main.js"))
var pendingQuitRaceStop: ((Result<Void, Error>) -> Void)?
var applicationIsTerminating = false
var windowsClosedForQuit = false
var updateBlockedByTermination = false
var quitCancellationWouldShowAlert = false
let updateSettled = DispatchSemaphore(value: 0)
let quitRaceContext = SimulatedPlayerContext(state: .live,
  controller: makeController(identifier: identifier) { done in pendingQuitRaceStop = done })
runPlayerContextUnloadBarrier([quitRaceContext], identifier: identifier, timeout: 1) { result in
  if case .success = result {
    if applicationIsTerminating {
      updateBlockedByTermination = true
      quitCancellationWouldShowAlert = PluginOperationErrorPolicy.shouldShowInstallationError(
        PluginOperationCancellationError.applicationTerminating,
        whileTerminating: applicationIsTerminating)
      try? FileManager.default.removeItem(at: quitRaceStaged)
    } else {
      try? FileManager.default.removeItem(at: installed)
      try? FileManager.default.moveItem(at: quitRaceStaged, to: installed)
    }
  }
  updateSettled.signal()
}
expect(pendingQuitRaceStop != nil, "managed update should be waiting for the exact stop Promise")
let quitDuringUpdate = awaitResult { done in
  applicationIsTerminating = true
  windowsClosedForQuit = true
  done(.success(()))
}
expect(quitDuringUpdate != nil && windowsClosedForQuit,
       "Quit must start window/player shutdown while the plugin stop Promise is still pending")
expect(updateSettled.wait(timeout: .now() + .milliseconds(20)) == .timedOut,
       "the fixture must still have an unresolved stop when Quit proceeds")
pendingQuitRaceStop?(.success(()))
expect(updateSettled.wait(timeout: .now() + 1) == .success,
       "the pending update should settle after its stop Promise resolves")
expect(updateBlockedByTermination,
       "a late successful stop must be rejected as an update once app termination begins")
expect(!quitCancellationWouldShowAlert,
       "a pending update canceled by Quit must not present an installation-error alert")
let packageAfterQuitRace = try Data(contentsOf: installed.appendingPathComponent("main.js"))
expect(packageAfterQuitRace == packageBeforeQuitRace,
       "Quit racing a late stop must leave the installed package unchanged")
expect(!FileManager.default.fileExists(atPath: quitRaceStaged.path),
       "Quit racing an update must discard its staging directory")

// A shutting-down core is never called, waited out, or counted as a successful stop. The caller
// must retain the old package/state and let shutdown retire the context; a later retry can then
// barrier whatever live contexts remain.
var shuttingContextCallbackCalled = false
let shuttingContext = SimulatedPlayerContext(state: .shuttingDown,
  controller: makeController(identifier: identifier) { done in
    shuttingContextCallbackCalled = true
    done(.failure(HarnessError.rejected))
  })
let liveDuringUnconfirmedShutdownListener = FakeEventListener(ownerIdentifier: identifier) { done in
  done(.success(()))
}
let liveDuringUnconfirmedShutdown = EventController()
_ = liveDuringUnconfirmedShutdown.addListener(liveDuringUnconfirmedShutdownListener,
                                               for: .pluginWillUnload)
let packageBeforeShuttingDownFailure = try Data(contentsOf: installed.appendingPathComponent("main.js"))
var disableDuringUnconfirmedShutdownCommitted = false
let shuttingResult = awaitResult({ done in
  runPlayerContextUnloadBarrier([shuttingContext,
                                 SimulatedPlayerContext(state: .live, controller: liveDuringUnconfirmedShutdown)],
                                identifier: identifier,
                                timeout: 1) { result in
    if case .success = result { disableDuringUnconfirmedShutdownCommitted = true }
    done(result)
  }
})
if case .failure(let error)? = shuttingResult {
  expect(!shuttingContextCallbackCalled, "host must never invoke plugin JS on a shutting-down core")
  expect(liveDuringUnconfirmedShutdownListener.synchronousCalls == 0,
         "a shutting-down context must fail the whole permit before other contexts are dispatched")
  expect(shuttingContext.timerCount > 0 && shuttingContext.pluginRetained,
         "failed permit must leave shutdown-owned state for the normal shutdown path to retire")
  expect(shuttingContext.controller.hasListener(for: .pluginWillUnload),
         "failed permit must not mutate listeners on the shutting-down context")
  expect(!disableDuringUnconfirmedShutdownCommitted,
         "disable/update must not commit without stop confirmation")
  let packageAfterShuttingDownFailure = try Data(contentsOf: installed.appendingPathComponent("main.js"))
  expect(packageAfterShuttingDownFailure == packageBeforeShuttingDownFailure,
         "unconfirmed shutdown must leave the installed package unchanged")
  expect(error.localizedDescription.contains("shutting down"),
         "unconfirmed shutdown error should tell the caller why the mutation was denied")
  shuttingContext.finishShutdown()
  shuttingContext.retireAfterShutdown()
  expect(shuttingContext.timerCount == 0 && !shuttingContext.pluginRetained,
         "normal shutdown cleanup must release the context without JS/mpv calls")
  expect(!shuttingContext.controller.hasListener(for: .pluginWillUnload),
         "normal shutdown cleanup must remove listeners without invoking them")
} else {
  fatalError("A shutting core must fail closed without invoking its listener")
}

// A failed multi-core plugin update remains fail-closed while the stale core's listeners are retired.
let retainedDuringCanceledTermination = SimulatedPlayerContext(state: .shutDown,
  controller: makeController(identifier: identifier) { done in
    done(.failure(HarnessError.rejected))
  })
let rejectingLiveCore = makeController(identifier: identifier) { done in
  DispatchQueue.global().asyncAfter(deadline: .now() + 0.04) { done(.failure(HarnessError.rejected)) }
}
var updateWasRejected = false
let rejectedUpdate = awaitResult({ done in
  runPlayerContextUnloadBarrier([retainedDuringCanceledTermination,
                                 SimulatedPlayerContext(state: .live, controller: rejectingLiveCore)],
                                identifier: identifier,
                                timeout: 1) { result in
    if case .failure = result { updateWasRejected = true }
    done(result)
  }
})
if case .failure? = rejectedUpdate {
  expect(updateWasRejected, "live-core stop rejection must fail the plugin update")
  expect(retainedDuringCanceledTermination.timerCount == 0 &&
         !retainedDuringCanceledTermination.pluginRetained,
         "failed update must not retain the already shut-down core's plugin state")
  let packageAfterCanceledTermination = try Data(contentsOf: installed.appendingPathComponent("main.js"))
  expect(packageAfterCanceledTermination == legacyPackageBytes,
         "failed update must leave the installed package unchanged")
} else {
  fatalError("Live-core rejection must fail closed for a package update")
}

print("PASS: unload barrier and Quit/update race, timeout/retry, shutdown contexts, and package sidecars")
