//
//  EventController.swift
//  iina
//
//  Created by Collider LI on 17/9/2018.
//  Copyright © 2018 lhc. All rights reserved.
//

import Foundation

protocol EventCallable {
  var ownerIdentifier: String? { get }
  func call(withArguments args: [Any])
  func callAndWaitForPromise(withArguments args: [Any],
                             completion: @escaping (Result<Void, Error>) -> Void)
  func callAfterPlayerShutdown(withArguments args: [Any],
                               completion: @escaping (Result<Void, Error>) -> Void)
}

extension EventCallable {
  var ownerIdentifier: String? { nil }

  func callAndWaitForPromise(withArguments args: [Any],
                             completion: @escaping (Result<Void, Error>) -> Void) {
    call(withArguments: args)
    completion(.success(()))
  }

  func callAfterPlayerShutdown(withArguments args: [Any],
                               completion: @escaping (Result<Void, Error>) -> Void) {
    completion(.failure(EventController.AsyncEventError.listenerRejected(
      "Listener does not support the helper-only player-shutdown callback")))
  }
}

class EventController {

  enum AsyncEventError: Error, LocalizedError {
    case missingListener(String)
    case playerUnavailable(String)
    case listenerDidNotReturnPromise
    case listenerRejected(String)

    var errorDescription: String? {
      switch self {
      case .missingListener(let identifier):
        if identifier == "dev.faruk.iina-airplay" {
          return "The installed AirPlay plugin has no stop-confirmation listener. Reel left it enabled and its package unchanged. Stop casting in the AirPlay tab, then quit and reopen Reel to retry the cold-start migration. If Stop or Quit is blocked, force quit and reopen; Reel replaces only the recognized official package after confirming no matching helper is running, and otherwise keeps the package and its settings unchanged. External or developer installs are not migrated automatically."
        }
        return "Plugin \(identifier) has no unload listener to confirm shutdown"
      case .playerUnavailable(let identifier):
        return "Player context for plugin \(identifier) is shutting down. Reel did not call into it; retry after shutdown completes."
      case .listenerDidNotReturnPromise:
        return "Plugin unload listener did not return a Promise"
      case .listenerRejected(let message):
        return message
      }
    }
  }

  struct Name: RawRepresentable, Hashable {
    typealias RawValue = String
    var rawValue: String

    var hashValue: Int {
      return rawValue.hashValue
    }

    init(_ string: String) { self.rawValue = string }
    init?(rawValue: RawValue) { self.rawValue = rawValue }

    // IINA events
    
    // Window related
    static let windowLoaded = Name("iina.window-loaded")
    static let windowSizeAdjusted = Name("iina.window-size-adjusted")
    static let windowMoved = Name("iina.window-moved")
    static let windowResized = Name("iina.window-resized")
    static let windowFullscreenChanged = Name("iina.window-fs.changed")
    static let windowScreenChanged = Name("iina.window-screen.changed")
    static let windowMiniaturized = Name("iina.window-miniaturized")
    static let windowDeminiaturized = Name("iina.window-deminiaturized")
    static let pluginWillUnload = Name("iina.plugin-will-unload")
    static let playerShutdown = Name("iina.player-shutdown")
    
    static let windowMainStatusChanged = Name("iina.window-main.changed")
    static let windowWillClose = Name("iina.window-will-close")

    static let musicModeChanged = Name("iina.music-mode.changed")
    static let pipChanged = Name("iina.pip.changed")

    static let fileLoaded = Name("iina.file-loaded")
    static let fileStarted = Name("iina.file-started")
    
    static let mpvInitialized = Name("iina.mpv-initialized")
    static let thumbnailsReady = Name("iina.thumbnails-ready")
    static let pluginOverlayLoaded = Name("iina.plugin-overlay-loaded")

    static let menuUpdate = Name("iina.menu-update")
  }

  var listeners: [Name: [String: EventCallable]] = [:]

  func hasListener(for name: Name) -> Bool {
    return listeners[name] != nil
  }

  func addListener(_ listener: EventCallable, for name: Name) -> String {
    let uuid = UUID().uuidString
    listeners[name, default: [:]][uuid] = listener
    return uuid
  }

  @discardableResult
  func removeListener(_ id: String, for name: Name) -> Bool {
    guard let t = listeners[name], let _ = t[id] else { return false }
    listeners[name]![id] = nil
    return true
  }

  /// Drops listener references without invoking callbacks. Used after mpv shutdown, when plugin
  /// callbacks may reach APIs whose backing player no longer exists.
  func removeAllListeners() {
    listeners.removeAll()
  }

  func emit(_ eventName: Name, data: Any...) {
    guard let listeners = listeners[eventName] else { return }
    for listener in listeners.values {
      listener.call(withArguments: data)
    }
  }

  /// Invoke only one plugin's synchronous listeners. Used during player shutdown to let a bundled
  /// plugin flush state without running arbitrary callbacks from every installed plugin.
  func emitToPlugin(_ eventName: Name, identifier: String, data: [Any]) {
    let snapshot = (listeners[eventName] ?? [:]).values.filter { $0.ownerIdentifier == identifier }
    for listener in snapshot {
      listener.call(withArguments: data)
    }
  }

  /// Emits an event to all listeners, but waits for Promise results from one plugin's listeners.
  /// This is used before an enabled plugin is disabled, reloaded, or replaced so a plugin can
  /// finish bounded external-process cleanup while its JavaScript context is still live.
  ///
  /// - Returns: whether at least one listener belonging to `pluginIdentifier` was found.
  @discardableResult
  func emitAndWaitForPluginPromises(_ eventName: Name,
                                   pluginIdentifier: String,
                                   data: [Any],
                                   completion: @escaping (Result<Void, Error>) -> Void) -> Bool {
    let snapshot = (listeners[eventName] ?? [:]).sorted { $0.key < $1.key }.map(\.value)
    let ownedListeners = snapshot.filter { $0.ownerIdentifier == pluginIdentifier }
    guard !ownedListeners.isEmpty else {
      snapshot.forEach { $0.call(withArguments: data) }
      completion(.failure(AsyncEventError.missingListener(pluginIdentifier)))
      return false
    }

    let barrier = EventPromiseBarrier(count: ownedListeners.count, completion: completion)
    for listener in snapshot {
      if listener.ownerIdentifier == pluginIdentifier {
        let once = EventPromiseCompletionOnce { result in barrier.receive(result) }
        listener.callAndWaitForPromise(withArguments: data) { result in once.finish(result) }
      } else {
        listener.call(withArguments: data)
      }
    }
    return true
  }

  /// Runs only the bundled AirPlay helper-stop listener after mpv has already shut down.
  /// Generic plugin event callbacks are never invoked on this path because they may call mpv.
  @discardableResult
  func emitAndWaitForBundledAirPlayShutdown(timeout: TimeInterval,
                                             completion: @escaping (Result<Void, Error>) -> Void) -> Bool {
    guard Thread.isMainThread else {
      completion(.failure(AsyncEventError.listenerRejected(
        "Bundled AirPlay shutdown callbacks must be invoked on the main thread")))
      return false
    }
    let identifier = "dev.faruk.iina-airplay"
    let matching = (listeners[.playerShutdown] ?? [:]).sorted { $0.key < $1.key }
      .map(\.value).filter { $0.ownerIdentifier == identifier }
    guard matching.count == 1, let listener = matching.first else {
      if matching.isEmpty {
        completion(.failure(AsyncEventError.missingListener(identifier)))
      } else {
        completion(.failure(AsyncEventError.listenerRejected(
          "Bundled AirPlay registered multiple player-shutdown listeners")))
      }
      return false
    }

    var timeoutWork: DispatchWorkItem!
    let once = EventPromiseCompletionOnce { result in
      timeoutWork.cancel()
      completion(result)
    }
    timeoutWork = DispatchWorkItem {
      once.finish(.failure(AsyncEventError.listenerRejected(
        "Timed out waiting for the bundled AirPlay helper to stop after mpv shutdown")))
    }
    DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout,
                                                   execute: timeoutWork)
    listener.callAfterPlayerShutdown(withArguments: [identifier]) { result in
      once.finish(result)
    }
    return true
  }
}

final class EventPromiseCompletionOnce {
  private let lock = NSLock()
  private var completion: ((Result<Void, Error>) -> Void)?

  init(_ completion: @escaping (Result<Void, Error>) -> Void) {
    self.completion = completion
  }

  func finish(_ result: Result<Void, Error>) {
    lock.lock()
    let handler = completion
    completion = nil
    lock.unlock()
    handler?(result)
  }
}

final class EventPromiseBarrier {
  private let lock = NSLock()
  private var remaining: Int
  private var firstError: Error?
  private var completion: ((Result<Void, Error>) -> Void)?

  init(count: Int, completion: @escaping (Result<Void, Error>) -> Void) {
    remaining = count
    self.completion = completion
  }

  func receive(_ result: Result<Void, Error>) {
    lock.lock()
    if case .failure(let error) = result, firstError == nil {
      firstError = error
    }
    remaining -= 1
    guard remaining == 0 else {
      lock.unlock()
      return
    }
    let handler = completion
    completion = nil
    let finalResult: Result<Void, Error> = firstError.map(Result.failure) ?? .success(())
    lock.unlock()
    handler?(finalResult)
  }
}

/// Defers startup continuations while a plugin migration is being checked and committed.
/// `open()` invokes queued work after releasing the lock so launch code can safely re-enter the
/// gate and observe that it is already open.
final class PluginContextStartupGate {
  private let lock = NSLock()
  private var isOpen = true
  private var continuations: [() -> Void] = []

  func close() {
    lock.lock()
    isOpen = false
    lock.unlock()
  }

  /// Returns true when the continuation was queued behind a closed gate.
  @discardableResult
  func continueWhenOpen(_ continuation: @escaping () -> Void) -> Bool {
    lock.lock()
    guard !isOpen else {
      lock.unlock()
      return false
    }
    continuations.append(continuation)
    lock.unlock()
    return true
  }

  func open() {
    lock.lock()
    guard !isOpen else {
      lock.unlock()
      return
    }
    isOpen = true
    let pending = continuations
    continuations.removeAll()
    lock.unlock()
    pending.forEach { $0() }
  }
}

/// Marks plugin work that the application intentionally canceled as part of Quit.
enum PluginOperationCancellationError: Error {
  case applicationTerminating
}

/// Avoid presenting a plugin installation error for work that Quit intentionally canceled.
enum PluginOperationErrorPolicy {
  static func shouldShowInstallationError(_ error: Error, whileTerminating isTerminating: Bool) -> Bool {
    guard isTerminating,
          let cancellation = error as? PluginOperationCancellationError else { return true }
    switch cancellation {
    case .applicationTerminating:
      return false
    }
  }
}
