//
//  JavascriptPluginInstance.swift
//  iina
//
//  Created by Collider LI on 11/9/2018.
//  Copyright © 2018 lhc. All rights reserved.
//

import Foundation
import JavaScriptCore

class JavascriptPluginInstance {
  var apis: [String: JavascriptAPI]!
  private var polyfill: JavascriptPolyfill!
  private var didPrepareForPlayerShutdown = false
  private var didRetireAfterPlayerShutdown = false

  lazy var js: JSContext = createJSContext()
  var logHandler: ((String, Logger.Level) -> Void)?

  weak var player: PlayerCore!
  weak var plugin: JavascriptPlugin!
  let isGlobal: Bool

  lazy var overlayView: PluginOverlayView = {
    let view = PluginOverlayView.create(pluginInstance: self)
    view.attachTo(windowController: player.mainWindow)
    return view
  }()
  var overlayViewLoaded = false

  lazy var standaloneWindow: PluginStandaloneWindow = {
    let window = PluginStandaloneWindow.create(pluginInstance: self)
    standaloneWindowCreated = true
    return window
  }()
  var standaloneWindowCreated = false

  lazy var sidebarTabView: PluginSidebarView = {
    let view = PluginSidebarView.create(pluginInstance: self)
    return view
  }()

  var menuItems: [JavascriptPluginMenuItem] = []
  
  let input = PluginInputManager()

  lazy var queue: DispatchQueue = {
    DispatchQueue(label: "com.colliderli.iina.plugin.\(plugin.identifier)", qos: .background)
  }()

  lazy var subsystem = Logger.makeSubsystem("\(isGlobal ? "global" : "player\(player.label!)") - \(plugin.name)", ["puzzlepiece.extension"])

  var currentFile: URL? {
    currentFileStack.last
  }
  private var currentFileStack: [URL] = []

  init(player: PlayerCore?, plugin: JavascriptPlugin) {
    self.plugin = plugin

    if let player {
      // normal plugin instance
      self.player = player
      isGlobal = false
      evaluateFile(plugin.entryURL)
    } else {
      // if player is nil, the plugin instance is a global controller
      isGlobal = true
      evaluateFile(plugin.globalEntryURL!)
    }
  }

  deinit {
    if let plugin = self.plugin {
      Logger.log("Unload \(plugin.name)", level: .debug, subsystem: subsystem)
    }
    polyfill.removeAllTimers()
    guard !didPrepareForPlayerShutdown && !didRetireAfterPlayerShutdown else { return }
    let mpvIsAvailable = player != nil && player.info.state != .shuttingDown && player.info.state != .shutDown
    apis.values.forEach { api in
      // JavascriptAPIMpv.cleanUp removes hooks through mpv. A context can be released while its
      // PlayerCore is shutting down, so never let deinit reach that API after shutdown begins.
      guard mpvIsAvailable || !(api is JavascriptAPIMpv) else { return }
      api.cleanUp(self)
    }
  }

  /// Quiesces plugin resources before normal mpv shutdown, while the mpv APIs are still valid.
  func prepareForPlayerShutdown() {
    guard !isGlobal, !didPrepareForPlayerShutdown, !didRetireAfterPlayerShutdown,
          let player, player.info.state != .shuttingDown && player.info.state != .shutDown else { return }
    didPrepareForPlayerShutdown = true
    if let identifier = plugin?.identifier {
      // Notify plugins while the player and JavaScript context are still live. Synchronous listeners
      // can flush local state before timers and generic event callbacks are removed for app quit.
      player.events.emitToPlugin(.pluginWillUnload, identifier: identifier, data: [identifier])
    }
    polyfill.removeAllTimers()
    apis.values.forEach { $0.cleanUp(self) }
  }

  /// Retires per-player resources once mpv is gone. JS timers and event callbacks are removed,
  /// AppKit-backed plugin UI is cleaned up, and the mpv API cleanup hook is intentionally skipped.
  func retireAfterPlayerShutdown() {
    guard !isGlobal, !didRetireAfterPlayerShutdown,
          let player, player.info.state == .shutDown else { return }
    didRetireAfterPlayerShutdown = true
    guard !didPrepareForPlayerShutdown else { return }
    polyfill.removeAllTimers()
    apis.values.forEach { api in
      guard !(api is JavascriptAPIMpv) else { return }
      api.cleanUp(self)
    }
  }

  /// Prevents plugin timers from reaching a PlayerCore whose mpv core disappeared without
  /// IINA's normal pre-shutdown path. This deliberately leaves event callbacks and non-mpv APIs
  /// alive until the bundled AirPlay helper-stop Promise settles or times out.
  func quiesceAfterUnexpectedPlayerShutdown() {
    guard !isGlobal, !didRetireAfterPlayerShutdown else { return }
    polyfill.removeAllTimers()
  }

  /// The post-mpv helper-only callback is reserved for Reel's managed official AirPlay package.
  /// An external/developer plugin or a same-ID package outside the managed Plugins directory
  /// must not receive a callback after mpv APIs have become unavailable.
  var isManagedBundledAirPlayPlugin: Bool {
    guard !isGlobal, let plugin,
          plugin.identifier == "dev.faruk.iina-airplay",
          plugin.githubRepo == "ozykhan/iina-airplay",
          !plugin.isExternal,
          plugin.root.pathExtension == "iinaplugin" else { return false }
    let root = plugin.root.standardizedFileURL.resolvingSymlinksInPath()
    let pluginsDirectory = Utility.pluginsURL.standardizedFileURL.resolvingSymlinksInPath()
    guard root.deletingLastPathComponent() == pluginsDirectory else { return false }
    let rootName = root.deletingPathExtension().lastPathComponent
    if rootName == plugin.identifier { return true }
    let suffixPrefix = plugin.identifier + "-"
    guard rootName.hasPrefix(suffixPrefix),
          let suffix = Int(rootName.dropFirst(suffixPrefix.count)) else { return false }
    return suffix >= 2
  }

  func canAccess(url: URL) -> Bool {
    guard let host = url.host else {
      return false
    }
    guard plugin.domainList.contains(where: { domain -> Bool in
      if domain == "*" {
        return true
      } else if domain.hasPrefix("*.") {
        return host.hasSuffix(domain.dropFirst())
      } else {
        return domain == host
      }
    }) else {
      return false
    }
    return true
  }

  @objc func menuItemAction(_ sender: NSMenuItem) {
    guard let item = sender.representedObject as? JavascriptPluginMenuItem else { return }
    if !item.callAction() {
      Logger.log("Action of the menu item \"\(item.title)\" is not a function", level: .error, subsystem: subsystem)
    }
  }

  @objc func playlistMenuItemAction(_ sender: NSMenuItem) {
    guard let item = sender.representedObject as? JavascriptPluginMenuItem else { return }
    if !item.callAction() {
      Logger.log("Action of the menu item \"\(item.title)\" is not a function", level: .error, subsystem: subsystem)
    }
  }

  @discardableResult
  func evaluateFile(_ url: URL, asModule: Bool = false) -> JSValue! {
    currentFileStack.append(url)
    guard let content = try? String(contentsOf: url) else {
      Logger.log("Cannot read script \(url.path)", level: .error, subsystem: subsystem)
      return JSValue(nullIn: js)
    }
    let script: String
    if asModule {
      script =
      """
      (function() {
      const module = {};
      \(content)
      return module.exports;
      })();
      """
    } else {
      script =
      """
      \(content)
      """
    }
    let result = js.evaluateScript(script, withSourceURL: url)
    currentFileStack.removeLast()
    return result
  }

  private func createJSContext() -> JSContext {
    let ctx = JSContext()!
    ctx.name = "\(isGlobal ? "Global" : "Main") — \(plugin.name)"
    ctx.exceptionHandler = { [unowned self] context, exception in
      let message = exception?.toString() ?? "Unknown exception"
      let stack = exception?.objectForKeyedSubscript("stack")?.toString() ?? "???"
      Logger.log(
        "\(message)\n---Stack Trace---\n\(stack)\n-----------------",
        level: .error,
        subsystem: self.subsystem
      )
    }

    apis = [
      "menu": JavascriptAPIMenu(context: ctx, pluginInstance: self),
      "standaloneWindow": JavascriptAPIStandaloneWindow(context: ctx, pluginInstance: self),
      "utils": JavascriptAPIUtils(context: ctx, pluginInstance: self),
      "file": JavascriptAPIFile(context: ctx, pluginInstance: self),
      "preferences": JavascriptAPIPreferences(context: ctx, pluginInstance: self),
      "console": JavascriptAPIConsole(context: ctx, pluginInstance: self),
      "http": JavascriptAPIHttp(context: ctx, pluginInstance: self)
    ]

    if !isGlobal {
      apis["core"] = JavascriptAPICore(context: ctx, pluginInstance: self)
      apis["mpv"] = JavascriptAPIMpv(context: ctx, pluginInstance: self)
      apis["event"] = JavascriptAPIEvent(context: ctx, pluginInstance: self)
      apis["overlay"] = JavascriptAPIOverlay(context: ctx, pluginInstance: self)
      apis["sidebar"] = JavascriptAPISidebarView(context: ctx, pluginInstance: self)
      apis["playlist"] = JavascriptAPIPlaylist(context: ctx, pluginInstance: self)
      apis["subtitle"] = JavascriptAPISubtitle(context: ctx, pluginInstance: self)
      apis["input"] = JavascriptAPIInput(context: ctx, pluginInstance: self)
    }
    apis["ws"] = JavascriptAPIWebSocketController(context: ctx, pluginInstance: self)

    if player == nil {
      // it's a global instance
      apis["global"] = JavascriptAPIGlobalController(context: ctx, pluginInstance: self)
    } else if let globalAPI = plugin.globalInstance?.apis["global"] as? JavascriptAPIGlobalController {
      // it's a normal instance
      let childAPI = JavascriptAPIGlobalChild(context: ctx, pluginInstance: self)
      childAPI.parentAPI = globalAPI
      apis["global"] = childAPI
    }

    ctx.setObject(apis, forKeyedSubscript: "iina" as NSString)
    apis.values.forEach { $0.extraSetup() }

    polyfill = JavascriptPolyfill(pluginInstance: self)
    polyfill.register(inContext: ctx)

    return ctx
  }
}
