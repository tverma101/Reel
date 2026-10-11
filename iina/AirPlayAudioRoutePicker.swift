//
//  AirPlayAudioRoutePicker.swift
//  iina
//
//  The on-screen AirPlay button selects an output for this Reel player through mpv. This keeps
//  routing attached to Reel's CoreAudio output instead of relying on an AVPlayer route picker.
//

import Cocoa

final class AirPlayAudioRoutePicker: NSObject {
  private weak var player: PlayerCore?

  init(player: PlayerCore) {
    self.player = player
    super.init()
  }

  func makePickerView() -> NSButton {
    let button = NSButton()
    button.image = Preference.ToolBarButton.airPlay.image()
    button.imagePosition = .imageOnly
    button.isBordered = false
    button.target = self
    button.action = #selector(presentAudioOutputs(_:))
    button.toolTip = NSLocalizedString("osc_toolbar.airplay", comment: "Reel audio output")
    button.setAccessibilityLabel(button.toolTip ?? "Audio Output")
    return button
  }

  @objc private func presentAudioOutputs(_ sender: NSButton) {
    guard let player else { return }
    let menu = NSMenu()
    menu.autoenablesItems = false

    let heading = NSMenuItem(title: NSLocalizedString("osc_toolbar.airplay_output.heading",
                                                      comment: "Heading for Reel's audio output menu"),
                             action: nil, keyEquivalent: "")
    heading.isEnabled = false
    menu.addItem(heading)

    let currentDevice = player.mpv.getString(MPVProperty.audioDevice) ?? "auto"
    let automatic = NSMenuItem(title: NSLocalizedString("osc_toolbar.airplay_output.default",
                                                        comment: "Use the system default audio output"),
                               action: #selector(selectAudioOutput(_:)), keyEquivalent: "")
    automatic.target = self
    automatic.representedObject = "auto"
    automatic.state = currentDevice == "auto" ? .on : .off
    menu.addItem(automatic)

    let devices = player.getAudioDevices().filter { $0.name != "auto" }
    if devices.isEmpty {
      let empty = NSMenuItem(title: NSLocalizedString("osc_toolbar.airplay_output.empty",
                                                      comment: "No audio output devices are available"),
                             action: nil, keyEquivalent: "")
      empty.isEnabled = false
      menu.addItem(empty)
    } else {
      menu.addItem(.separator())
      for device in devices {
        let item = NSMenuItem(title: device.desc, action: #selector(selectAudioOutput(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = device.name
        item.state = device.name == currentDevice ? .on : .off
        menu.addItem(item)
      }
    }

    menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height), in: sender)
  }

  @objc private func selectAudioOutput(_ sender: NSMenuItem) {
    guard let player, let name = sender.representedObject as? String else { return }
    let message: String
    if player.setAudioDevice(name) {
      message = String(format: NSLocalizedString("osc_toolbar.airplay_output.requested",
                                                 comment: "Reel's requested audio output"), sender.title)
    } else {
      message = NSLocalizedString("osc_toolbar.airplay_output.failed",
                                  comment: "Reel could not request the selected audio output")
    }
    player.sendOSD(.custom(message))
  }
}
