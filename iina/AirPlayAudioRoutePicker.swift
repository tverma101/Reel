//
//  AirPlayAudioRoutePicker.swift
//  iina
//
//  The AirPlay button in the on-screen controller. It is Apple's route picker without a player, so
//  it lists the system audio routes (this Mac and any AirPlay speakers, several at once for
//  multi-room). Choosing speakers changes the system output, and mpv follows it as long as the
//  Audio Device setting is Auto. Video keeps playing in the window.
//

import AVKit
import Cocoa

final class AirPlayAudioRoutePicker: NSObject, AVRoutePickerViewDelegate {
  private weak var player: PlayerCore?

  init(player: PlayerCore) {
    self.player = player
    super.init()
  }

  func makePickerView() -> AVRoutePickerView {
    let picker = AVRoutePickerView()
    picker.delegate = self
    picker.isRoutePickerButtonBordered = false
    picker.setRoutePickerButtonColor(.labelColor, for: .normal)
    picker.setRoutePickerButtonColor(.secondaryLabelColor, for: .normalHighlighted)
    picker.setRoutePickerButtonColor(.controlAccentColor, for: .active)
    picker.setRoutePickerButtonColor(.controlAccentColor, for: .activeHighlighted)
    picker.toolTip = Preference.ToolBarButton.airPlay.localizedDescription()
    return picker
  }

  func routePickerViewWillBeginPresentingRoutes(_ routePickerView: AVRoutePickerView) {
    // A device chosen under Audio > Audio Device bypasses the system output, so the speakers picked
    // here would not be heard from this player.
    guard let player, let device = player.mpv.getString(MPVProperty.audioDevice), device != "auto" else { return }
    player.log("AirPlay picker opened while audio-device is pinned to \(device)")
    player.sendOSD(.customWithDetail(
      NSLocalizedString("osd.airplay_pinned_device", comment: "AirPlay needs Audio Device set to Auto"),
      NSLocalizedString("osd.airplay_pinned_device_detail", comment: "How to switch to Auto")))
  }
}
