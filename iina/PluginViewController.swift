//
//  PluginViewController.swift
//  iina
//
//  Created by Hechen Li on 11/11/24.
//  Copyright © 2024 lhc. All rights reserved.
//

fileprivate let ui = UIHelper.shared

private let airPlayVideoPluginIdentifier = "dev.faruk.iina-airplay"


extension SidebarViewController.TabType {
  static let pluginPlaceholder = SidebarViewController.TabType(
    0, NSLocalizedString("sidebar.plugins", comment: ""), .puzzlepieceExtensionFill)
}

class PluginViewController: SidebarViewController {
  private struct AirPlayVideoPluginIdentity: Equatable {
    let object: ObjectIdentifier
    let rootPath: String
    let version: String

    init(_ plugin: JavascriptPlugin) {
      object = ObjectIdentifier(plugin)
      rootPath = plugin.root.standardizedFileURL.path
      version = plugin.version
    }
  }

  private enum AirPlayVideoUpdateCheckState: Equatable {
    case checking
    case current
    case updateAvailable
    case retry
    case unavailable
  }

  override var sidebarType: SidebarController.ViewType {
    .plugins
  }
  override var leadingPrefKey: Preference.Key {
    .sidebarPluginsDisplayAtLeading
  }

  private lazy var allTabs_: [(id: String, name: String)] = getAllTabs()

  override var allTabs: [TabType] {
    [.pluginPlaceholder] + allTabs_.enumerated().map { (i, tuple) in
      TabType(i + 1, tuple.id, .puzzlepieceExtensionFill)
    }
  }
  override var defaultTab: TabType { .pluginPlaceholder }
  override var useTabView: Bool { false }

  private var pluginContentContainerView: NSView!
  private var placeholderView: NSView!
  private var airPlayVideoActionButton: NSButton!
  private var airPlayVideoStatusLabel: NSTextField!
  private var airPlayVideoUpdateInProgress = false
  private let airPlayVideoCheckGeneration = AirPlayPackageCheckGeneration()
  private var airPlayVideoCheckedIdentity: AirPlayVideoPluginIdentity?
  private var airPlayVideoUpdateCheckState: AirPlayVideoUpdateCheckState?

  private var pluginMenu = NSMenu()

  private func getPluginIcon(isSmall: Bool) -> NSImage {
    let config = isSmall ? compactIconConfig : iconConfig
    return NSImage.sf("puzzlepiece.extension.fill", withConfiguration: config) ?? .puzzlepieceExtensionFill
  }

  override func setupTabs() {
    pluginMenu.minimumWidth = 200
    pluginMenu.delegate = self

    self.pluginContentContainerView = NSView()
    pluginContentContainerView.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(pluginContentContainerView)

    pluginContentContainerView.padding(.bottom, .horizontal)
      .spacing(.top(1), to: tabButtonsStackView)

    self.placeholderView = NSView()
    placeholderView.translatesAutoresizingMaskIntoConstraints = false

    let airPlayVideoTitle = ui.label(
      "sidebar.plugins_airplay_video_title",
      font: .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold),
      canCompress: false
    )
    let airPlayVideoDescription = ui.label(
      "sidebar.plugins_airplay_video_description",
      wrapping: true,
      isSmall: true,
      isSecondary: true,
      canCompress: false
    )
    let airPlayVideoIcon = NSImageView()
    airPlayVideoIcon.image = NSImage.sf("airplayvideo", "airplay", withConfiguration: .sidebarIconConfig)
    airPlayVideoIcon.contentTintColor = .controlAccentColor
    airPlayVideoIcon.imageScaling = .scaleProportionallyDown
    airPlayVideoIcon.size(width: 20, height: 20)

    airPlayVideoActionButton = NSButton()
    airPlayVideoActionButton.bezelStyle = .rounded
    airPlayVideoActionButton.target = self
    airPlayVideoActionButton.action = #selector(airPlayVideoCardAction(_:))
    airPlayVideoStatusLabel = ui.label(
      "sidebar.plugins_airplay_video_status_empty",
      wrapping: true,
      isSmall: true,
      isSecondary: true,
      canCompress: false
    )
    airPlayVideoStatusLabel.isHidden = true

    let airPlayVideoCardContent = ui.vStack(
      spacing: .sidebarItemSpacing,
      ui.hStack(align: .top, spacing: 10, airPlayVideoIcon,
                ui.vStack(spacing: 4, airPlayVideoTitle, airPlayVideoDescription)),
      ui.hStack(ui.flexibleSpace(), airPlayVideoActionButton),
      airPlayVideoStatusLabel
    )
    let airPlayVideoCard = SidebarScrollView.Container(airPlayVideoCardContent) {
      $0.padding(.all(.sidebarContainerPadding))
    }

    let message = SidebarScrollView.Container(
      ui.label("sidebar.plugins_placeholder",
               wrapping: true, isSmall: true, isSecondary: true, canCompress: false)
    ) {
      $0.padding(.all(.sidebarContainerPadding))
    }
    let placeholderStack = ui.vStack(spacing: .sidebarStackViewSpacing, airPlayVideoCard, message)
    placeholderView.addSubview(placeholderStack)
    placeholderStack.padding(.horizontal(.sidebarMargin), .vertical(.sidebarMargin))

    let bottomBorder = ui.separator()
    view.addSubview(bottomBorder)
    bottomBorder.padding(.horizontal).spacing(.bottom, to: pluginContentContainerView)

    tabButtonsSegmentControl.segmentCount = 2
    tabButtonsSegmentControl.trackingMode = .momentary

    updatePluginTabs()
    updateTabActiveStatus()
    installView()

    player.observe(.iinaPluginChanged) { [unowned self] _ in
      updatePluginTabs()
    }
  }

  private func getAllTabs() -> [(id: String, name: String)] {
    player.plugins
      .filter { $0.plugin.sidebarTabName != nil }
      .map { ($0.plugin.identifier, $0.plugin.sidebarTabName!) }
  }

  func updatePluginTabs() {
    guard isViewLoaded else { return }
    allTabs_ = getAllTabs()
    updateAirPlayVideoAction()

    pluginMenu.removeAllItems()
    // Keep the built-in setup card reachable after opening a plugin sidebar tab.
    // Its name is also the placeholder TabType's name, so menuItemAction can use
    // the same tab lookup as it does for plugin identifiers.
    pluginMenu.addItem(
      withTitle: TabType.pluginPlaceholder.name,
      action: #selector(menuItemAction),
      target: self,
      obj: TabType.pluginPlaceholder.name
    )
    if !allTabs_.isEmpty {
      pluginMenu.addItem(.separator())
    }
    allTabs_.forEach { tab in
      pluginMenu.addItem(
        withTitle: tab.name,
        action: #selector(menuItemAction),
        target: self,
        obj: tab.id
      )
    }
  }

  private func updateAirPlayVideoAction(forceCheck: Bool = false) {
    guard airPlayVideoActionButton != nil else { return }
    let installedPlugin = JavascriptPlugin.plugins.first { $0.identifier == airPlayVideoPluginIdentifier }
    let pluginIsEnabled = allTabs_.contains { $0.id == airPlayVideoPluginIdentifier }
    let updateState: AirPlayVideoUpdateCheckState
    if let installedPlugin {
      let identity = AirPlayVideoPluginIdentity(installedPlugin)
      if forceCheck || airPlayVideoCheckedIdentity != identity {
        airPlayVideoCheckedIdentity = identity
        airPlayVideoUpdateCheckState = .checking
        let generation = airPlayVideoCheckGeneration.begin()
        BundledAirPlayPluginManager.checkUpdateAvailability(for: installedPlugin) { [weak self] result in
          guard let self,
                self.airPlayVideoCheckGeneration.isCurrent(generation),
                self.airPlayVideoCheckedIdentity == identity else { return }
          switch result {
          case .current, .notManaged, .newerThanBundle:
            self.airPlayVideoUpdateCheckState = .current
          case .updateAvailable:
            self.airPlayVideoUpdateCheckState = .updateAvailable
          case .unavailable, .unrepairableNewer:
            self.airPlayVideoUpdateCheckState = .unavailable
            self.showAirPlayVideoStatus("sidebar.plugins_airplay_video_update_unavailable")
          case .stale:
            self.airPlayVideoUpdateCheckState = .retry
          }
          self.updateAirPlayVideoAction()
        }
      }
      updateState = airPlayVideoUpdateCheckState ?? .checking
    } else {
      _ = airPlayVideoCheckGeneration.begin()
      airPlayVideoCheckedIdentity = nil
      airPlayVideoUpdateCheckState = nil
      updateState = .current
    }
    let canRepair = updateState == .updateAvailable || updateState == .retry
    let titleKey: String
    if airPlayVideoUpdateInProgress {
      titleKey = "sidebar.plugins_airplay_video_updating"
    } else if canRepair {
      titleKey = "sidebar.plugins_airplay_video_update"
    } else {
      titleKey = pluginIsEnabled
        ? "sidebar.plugins_airplay_video_open"
        : "sidebar.plugins_airplay_video_setup"
    }
    airPlayVideoActionButton.title = ui.localized(titleKey)
    airPlayVideoActionButton.setAccessibilityLabel(airPlayVideoActionButton.title)
    airPlayVideoActionButton.isEnabled = !airPlayVideoUpdateInProgress
    airPlayVideoActionButton.toolTip = ui.localized(
      canRepair
        ? "sidebar.plugins_airplay_video_update_help"
        : pluginIsEnabled
          ? "sidebar.plugins_airplay_video_open_help"
          : "sidebar.plugins_airplay_video_setup_help"
    )
    switch BundledAirPlayPluginManager.legacyMigrationIssue {
    case .helperMayBeRunning:
      showAirPlayVideoStatus("sidebar.plugins_airplay_video_legacy_helper_running")
    case .updateUnavailable:
      showAirPlayVideoStatus("sidebar.plugins_airplay_video_legacy_update_unavailable")
    case nil:
      break
    }
  }

  @objc private func airPlayVideoCardAction(_ sender: NSButton) {
    allTabs_ = getAllTabs()
    let installedPlugin = JavascriptPlugin.plugins.first { $0.identifier == airPlayVideoPluginIdentifier }
    if let installedPlugin,
       airPlayVideoUpdateCheckState == .updateAvailable || airPlayVideoUpdateCheckState == .retry {
      airPlayVideoUpdateInProgress = true
      _ = airPlayVideoCheckGeneration.begin()
      airPlayVideoStatusLabel.isHidden = true
      updateAirPlayVideoAction()
      BundledAirPlayPluginManager.update(installedPlugin) { [weak self] result in
        guard let self else { return }
        self.airPlayVideoUpdateInProgress = false
        self.airPlayVideoCheckedIdentity = nil
        self.airPlayVideoUpdateCheckState = nil
        switch result {
        case .updated(let permissionsChanged):
          self.showAirPlayVideoStatus(
            permissionsChanged
              ? "sidebar.plugins_airplay_video_updated_permissions_changed"
              : "sidebar.plugins_airplay_video_updated"
          )
        case .unavailable:
          self.showAirPlayVideoStatus("sidebar.plugins_airplay_video_update_unavailable")
        case .failed:
          self.showAirPlayVideoStatus("sidebar.plugins_airplay_video_update_failed")
        }
        self.allTabs_ = self.getAllTabs()
        self.updateAirPlayVideoAction(forceCheck: true)
      }
      return
    }

    guard allTabs_.contains(where: { $0.id == airPlayVideoPluginIdentifier }) else {
      openAirPlayPluginSettings()
      return
    }
    updateAirPlayVideoAction()
    mainWindow.sidebars.show(sidebar: .plugins, tab: airPlayVideoPluginIdentifier,
                             force: true, hideIfAlreadyShown: false)
  }

  private func showAirPlayVideoStatus(_ key: String) {
    let status = ui.localized(key)
    airPlayVideoStatusLabel.stringValue = status
    airPlayVideoStatusLabel.setAccessibilityLabel(status)
    airPlayVideoStatusLabel.isHidden = false
  }

  private func openAirPlayPluginSettings() {
    if Preference.enableNewSettings {
      SettingsWindow.default.show()
      SettingsWindow.default.navigateTo(page: "plugin")
    } else {
      AppDelegate.shared.preferenceWindowController
        .openPreferenceView(withNibName: "PrefPluginViewController")
    }
  }

  override func updateTabActiveStatus() {
    let name = if currentTab.tag == 0 {
      TabType.pluginPlaceholder.name
    } else {
      allTabs_[currentTab.tag - 1].name
    }
    tabButtonsSegmentControl.setLabel(name, forSegment: 0)
  }

  override func updateTabButtonSize() {
    // on macOS 26, window corner radius will be larger with a regular toolbar.
    // should use the normal (non-compact) height if the sidebar is on the leading side.
    let largeLeadingHeight = if #available(macOS 26.0, *) { isLeading } else { false }
    let height: CGFloat = (isCompact && !largeLeadingHeight) ? 48 : 52
    tabButtonsHeightConstraint.constant = height

    if #available(macOS 26.0, *), !isCompact {
      tabButtonsSegmentControl.controlSize = .extraLarge
    } else {
      tabButtonsSegmentControl.controlSize = .large
    }
    tabButtonsSegmentControl.setImage(getPluginIcon(isSmall: isCompact), forSegment: 0)
    tabButtonsSegmentControl.setImage(.sf("chevron.down"), forSegment: 1)

    closeSidebarBtnSizeConstraint.constant =  isCompact ? 28 : 36
  }

  override func switchToTab(_ tab: SidebarViewController.TabType) {
    guard isViewLoaded else { return }

    currentTab = tab
    installView()
    updateTabActiveStatus()
  }

  private func installView() {
    if currentTab.tag == 0 {
      pluginContentContainerView.subviews.forEach { $0.removeFromSuperview() }
      pluginContentContainerView.addSubview(placeholderView)
      placeholderView.padding(.all)
    } else {
      let id = currentTab.name
      if let plugin = player.plugins.first(where: { $0.plugin.identifier == id }) {
        pluginContentContainerView.subviews.forEach { $0.removeFromSuperview() }
        pluginContentContainerView.addSubview(plugin.sidebarTabView)
        plugin.sidebarTabView.padding(.all)
      }
    }
  }

  func removePluginTab(withIdentifier identifier: String) {
    guard isViewLoaded else { return }
    if currentTab.name == identifier {
      pluginContentContainerView.subviews.forEach { $0.removeFromSuperview() }
      switchToTab(.pluginPlaceholder)
    }
    if let item = pluginMenu.items
      .first(where: { $0.representedObject as? String == identifier }) {
      pluginMenu.removeItem(item)
    }
  }

  override func tabBtnSegmentControlAction(_ sender: NSSegmentedControl) {
    pluginMenu.minimumWidth = tabButtonsSegmentControl.frame.width
    let currentItem = pluginMenu.items.first(where: {
      currentTab.name == $0.representedObject as? String
    })
    if sender.selectedSegment == 1 {
      pluginMenu.popUp(positioning: currentItem, at: .zero, in: sender)
    }
  }

  @objc private func menuItemAction(_ sender: NSMenuItem) {
    guard let id = sender.representedObject as? String,
          let tab = allTabs.first(where: { $0.name == id }) else { return }
    switchToTab(tab)
  }
}


extension PluginViewController: NSMenuDelegate {
  func menuWillOpen(_ menu: NSMenu) {
    for item in menu.items {
      if currentTab.name == item.representedObject as? String {
        item.state = .on
      } else {
        item.state = .off
      }
    }
  }
}
