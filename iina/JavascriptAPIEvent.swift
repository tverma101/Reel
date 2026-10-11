//
//  JavascriptAPIEvent.swift
//  iina
//
//  Created by Collider LI on 11/9/2018.
//  Copyright © 2018 lhc. All rights reserved.
//

import Foundation
import JavaScriptCore

@objc protocol JavascriptAPIEventExportable: JSExport {
  func on(_ event: String, _ callback: JSValue) -> String?
  func off(_ event: String, _ id: String)
}

// Examples:
// event.on("mpv.file-start")
// event.on("mpv.fullscreen.changed")
// event.on("iina.window-resized")
// event.on("iina.pip.changed")

class JavascriptAPIEvent: JavascriptAPI, JavascriptAPIEventExportable {
  private var addedListeners: [(String, EventController.Name)] = []

  @objc func on(_ event: String, _ callback: JSValue) -> String? {
    guard let player, player.info.state != .shuttingDown && player.info.state != .shutDown else { return nil }
    let splitted = event.split(separator: ".")
    let isEventListener = splitted.count == 2
    let isPropertyChangedListener = splitted.count == 3 && splitted[2] == "changed"
    let isMpv = splitted[0] == "mpv"
    let isIINA = splitted[0] == "iina"
    guard (isEventListener || isPropertyChangedListener) && (isMpv || isIINA) else {
      throwError(withMessage: "Incorrect event name syntax: \"\(event)\"")
      return nil
    }
    let eventName = String(splitted[1])
    let name = EventController.Name(event)
    if name == .playerShutdown && !pluginInstance.isManagedBundledAirPlayPlugin {
      throwError(withMessage: "iina.player-shutdown is reserved for Reel's bundled AirPlay helper cleanup")
      return nil
    }
    if isMpv && isPropertyChangedListener && player.mpv.observeProperties[eventName] == nil {
      player.mpv.observe(property: eventName)
    }
    let id = player.events.addListener(
      JavascriptAPIEventCallback(callback,
                                 ownerIdentifier: pluginInstance.plugin.identifier,
                                 player: player,
                                 canHandlePlayerShutdown: pluginInstance.isManagedBundledAirPlayPlugin),
      for: name)
    addedListeners.append((id, name))
    return id
  }

  @objc func off(_ event: String,_ id: String) {
    guard let player, player.info.state != .shuttingDown && player.info.state != .shutDown else { return }
    if !player.events.removeListener(id, for: .init(event)) {
      log("Event listener not found for id \(id)", level: .warning)
    }
  }

  override func cleanUp(_ instance: JavascriptPluginInstance) {
    addedListeners.forEach { (id, name) in
      player!.events.removeListener(id, for: name)
    }
    addedListeners.removeAll()
  }
}

class JavascriptAPIEventCallback: EventCallable {
  private var callback: JSValue?
  private weak var player: PlayerCore?
  let ownerIdentifier: String?
  private let canHandlePlayerShutdown: Bool

  init(_ callback: JSValue,
       ownerIdentifier: String?,
       player: PlayerCore,
       canHandlePlayerShutdown: Bool) {
    self.callback = callback
    self.ownerIdentifier = ownerIdentifier
    self.player = player
    self.canHandlePlayerShutdown = canHandlePlayerShutdown
  }

  func call(withArguments args: [Any]) {
    guard playerCanReceiveCallbacks else { return }
    _ = invoke(withArguments: args)
  }

  func callAndWaitForPromise(withArguments args: [Any],
                             completion: @escaping (Result<Void, Error>) -> Void) {
    guard playerCanReceiveCallbacks, let player else {
      completion(.failure(EventController.AsyncEventError.playerUnavailable(ownerIdentifier ?? "unknown")))
      return
    }
    guard let callback, let result = invoke(withArguments: args),
          !result.isNull, !result.isUndefined, result.isObject,
          let isThenable = callback.context.evaluateScript(
            "(function (value) { return !!value && typeof value.then === 'function'; })"
          )?.call(withArguments: [result]).toBool(), isThenable,
          let then = result.objectForKeyedSubscript("then") else {
      completion(.failure(EventController.AsyncEventError.listenerDidNotReturnPromise))
      return
    }

    let once = EventPromiseCompletionOnce { completion($0) }
    let listenerOwner = ownerIdentifier ?? "unknown"
    let resolve: @convention(block) () -> Void = { [weak player] in
      guard let player, player.info.state != .shuttingDown && player.info.state != .shutDown else {
        once.finish(.failure(EventController.AsyncEventError.playerUnavailable(listenerOwner)))
        return
      }
      once.finish(.success(()))
    }
    let reject: @convention(block) (JSValue?) -> Void = { [weak player] value in
      guard let player, player.info.state != .shuttingDown && player.info.state != .shutDown else {
        once.finish(.failure(EventController.AsyncEventError.playerUnavailable(listenerOwner)))
        return
      }
      once.finish(.failure(EventController.AsyncEventError.listenerRejected(
        value?.toString() ?? "Plugin unload listener rejected")))
    }
    let resolveValue = JSValue(object: resolve, in: result.context)
    let rejectValue = JSValue(object: reject, in: result.context)
    guard let resolveValue, let rejectValue else {
      completion(.failure(EventController.AsyncEventError.listenerDidNotReturnPromise))
      return
    }
    _ = then.call(withArguments: [resolveValue, rejectValue])
  }

  /// The only callback allowed after mpv shutdown is the bundled AirPlay helper-stop listener.
  /// Its Promise must be independent of mpv; settlement intentionally does not consult PlayerCore.
  func callAfterPlayerShutdown(withArguments args: [Any],
                               completion: @escaping (Result<Void, Error>) -> Void) {
    guard canHandlePlayerShutdown,
          ownerIdentifier == "dev.faruk.iina-airplay",
          let callback,
          let result = invokeAfterPlayerShutdown(callback, withArguments: args),
          !result.isNull, !result.isUndefined, result.isObject,
          let isThenable = callback.context.evaluateScript(
            "(function (value) { return !!value && typeof value.then === 'function'; })"
          )?.call(withArguments: [result]).toBool(), isThenable,
          let then = result.objectForKeyedSubscript("then") else {
      completion(.failure(EventController.AsyncEventError.listenerDidNotReturnPromise))
      return
    }

    let once = EventPromiseCompletionOnce { completion($0) }
    let resolve: @convention(block) () -> Void = { once.finish(.success(())) }
    let reject: @convention(block) (JSValue?) -> Void = { value in
      once.finish(.failure(EventController.AsyncEventError.listenerRejected(
        value?.toString() ?? "AirPlay helper stop rejected")))
    }
    guard let resolveValue = JSValue(object: resolve, in: result.context),
          let rejectValue = JSValue(object: reject, in: result.context) else {
      completion(.failure(EventController.AsyncEventError.listenerDidNotReturnPromise))
      return
    }
    _ = then.call(withArguments: [resolveValue, rejectValue])
  }

  private func invokeAfterPlayerShutdown(_ callback: JSValue, withArguments args: [Any]) -> JSValue? {
    guard canHandlePlayerShutdown, ownerIdentifier == "dev.faruk.iina-airplay" else { return nil }
    return callback.call(withArguments: args.map { arg in
      if let rect = arg as? CGRect {
        return JSValue(rect: rect, in: callback.context)!
      } else {
        return arg
      }
    })
  }

  private func invoke(withArguments args: [Any]) -> JSValue? {
    guard playerCanReceiveCallbacks, let callback else { return nil }
    return callback.call(withArguments: args.map { arg in
      if let rect = arg as? CGRect {
        return JSValue(rect: rect, in: callback.context)!
      } else {
        return arg
      }
    })
  }

  private var playerCanReceiveCallbacks: Bool {
    guard let player else { return false }
    return player.info.state != .shuttingDown && player.info.state != .shutDown
  }
}
