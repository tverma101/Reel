//
//  SubChooseViewController.swift
//  iina
//
//  Created by Collider LI on 4/3/2018.
//  Copyright © 2018 lhc. All rights reserved.
//

import Cocoa
import PromiseKit

class SubChooseViewController: NSViewController {
  override var nibName: NSNib.Name {
    return NSNib.Name("SubChooseViewController")
  }

  @IBOutlet weak var tableView: NSTableView!
  @IBOutlet weak var downloadBtn: NSButton!

  var subtitles: [OnlineSubtitle] = []

  /// Row to select once the table has been populated, letting the best match be downloaded without
  /// an extra click. `nil` leaves the selection empty.
  var preselectedRow: Int?

  var userDoneAction: (([OnlineSubtitle]) -> Void)?
  var userCanceledAction: (() -> Void)?

  var context: Any?
  weak var player: PlayerCore?

  override func viewDidLoad() {
    super.viewDidLoad()

    if let scrollView = tableView.enclosingScrollView {
      scrollView.wantsLayer = true
      scrollView.layer?.cornerRadius = 6
    }

    tableView.delegate = self
    tableView.dataSource = self

    // Download subtitle when table view row is double clicked
    tableView.target = self
    tableView.doubleAction = #selector(downloadBtnAction(_:))
  }

  /// Reload the table and apply `preselectedRow`, if any.
  func reload() {
    tableView.reloadData()
    let valid = preselectedRow.map { subtitles.indices.contains($0) } ?? false
    if let preselectedRow, valid {
      tableView.selectRowIndexes(IndexSet(integer: preselectedRow), byExtendingSelection: false)
    }
    // `reloadData` drops the selection without reliably posting a selection change, and the button
    // is otherwise only ever driven from that callback, so set it here for both outcomes. Leaving
    // it enabled with nothing selected would resolve an empty choice.
    downloadBtn.isEnabled = valid
  }

  @IBAction func downloadBtnAction(_ sender: Any) {
    guard let userDoneAction else { return }
    // A double click on a row sends the table view rather than the button, and the clicked row is
    // not necessarily the selected one. Select it first, otherwise choosing a different row by
    // double clicking would download the previously selected row instead.
    if let table = sender as? NSTableView, table.clickedRow >= 0 {
      table.selectRowIndexes(IndexSet(integer: table.clickedRow), byExtendingSelection: false)
    }
    userDoneAction(tableView.selectedRowIndexes.map { subtitles[$0] })
    player?.hideOSD()
    context = nil
  }

  @IBAction func cancelBtnAction(_ sender: Any) {
    guard let userCanceledAction else { return }
    userCanceledAction()
    player?.hideOSD()
    context = nil
  }
}


extension SubChooseViewController: NSTableViewDelegate, NSTableViewDataSource {

  func numberOfRows(in tableView: NSTableView) -> Int {
    return subtitles.count
  }

  func tableView(_ tableView: NSTableView, objectValueFor tableColumn: NSTableColumn?, row: Int) -> Any? {
    let (name, left, right) = subtitles[row].getDescription()
    return ["name": name, "left": left, "right": right]
  }

  func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
    return tableView.makeView(withIdentifier: NSUserInterfaceItemIdentifier(rawValue: "SubCell"), owner: self)
  }

  func tableViewSelectionDidChange(_ notification: Notification) {
    downloadBtn.isEnabled = tableView.selectedRow != -1
  }
}


// MARK: - Choosing which search result to download

extension OnlineSubtitle {

  /// Decide which of the search results to download.
  ///
  /// When exactly one result is an exact match for the media being played it is resolved straight
  /// away, so it is downloaded and loaded automatically. In every other case the chooser is shown
  /// exactly as before, with the best match preselected, so the user can accept it with one click or
  /// pick any other result instead.
  ///
  /// The results are deliberately **not** reordered. A provider's own ordering is meaningful:
  /// OpenSubtitles is sent both a file hash and a name query, and returns the content-verified hash
  /// matches first. Sorting by name score alone would push those below name-only matches, and in
  /// the case below it would silently select a file the hash had already ruled out. The score is
  /// used only to identify a single exact match and to choose what to preselect.
  ///
  /// Auto-selection is skipped when several results tie at a perfect match, because choosing one of
  /// them automatically would be arbitrary.
  ///
  /// - Parameters:
  ///   - subs: The search results, in provider order.
  ///   - mediaName: Name of the media being played, without extension.
  ///   - chooser: The view controller used to present the chooser. Owned by the caller.
  ///   - context: Opaque value handed back to the chooser.
  /// - Returns: The results the user agreed to download.
  static func resolveSelection<S: OnlineSubtitle>(_ subs: [S],
                                                   mediaName: String,
                                                   expectedURL: URL,
                                                   player: PlayerCore,
                                                   chooser: SubChooseViewController,
                                                   context: Any?) -> Promise<[S]> {
    // An empty result set must not reach the chooser, which would show an empty list.
    //
    // The chooser's state is not touched here. Every search gets its own `SubChooseViewController`
    // (`Provider.getFetcher()` returns a fresh `Fetcher`), so there is nothing to clear, and doing
    // so from this thread would mean mutating a view controller off the main queue.
    guard !subs.isEmpty else { return .value(subs) }

    let scores = subs.map {
      SubtitleMatchScorer.score(releaseName: $0.releaseName, mediaName: mediaName)
    }
    let perfect = scores.enumerated().filter {
      $0.element == SubtitleMatchScorer.perfectMatch && subs[$0.offset].canAutomaticallySelect
    }
    if Preference.bool(for: .autoSelectMatchingSubtitle), perfect.count == 1 {
      let best = subs[perfect[0].offset]
      // A score of 100 requires a release name, so this is never nil on this path.
      let name = best.releaseName ?? best.getDescription().name
      Logger.log("Auto-selecting subtitle \"\(name)\" for \"\(mediaName)\": exact release match",
                 level: .debug, subsystem: Logger.Sub.onlinesub)
      return .value([best])
    }

    // Preselect the highest-scoring result. `max(by:)` keeps the first maximal element, so a tie is
    // decided by the provider's own ordering. Nothing is preselected when no result resembles the
    // media at all.
    let priorities = scores.enumerated().map { $0.element + subs[$0.offset].verifiedSelectionBoost }
    let best = priorities.enumerated().max { $0.element < $1.element }
    let preselected = best.flatMap { priorities[$0.offset] > 0 ? $0.offset : nil }

    return Promise { resolver in
      // Provider requests complete on a URLSession queue, not the main thread, and everything below
      // is AppKit: loading the nib from `chooser.view` and the table/selection/button updates in
      // `reload()`. Presenting them on the calling thread was already wrong for the table reload,
      // and writing the selection made it worse, so hop to main explicitly.
      DispatchQueue.main.async {
        guard player.info.state.active, player.info.currentURL == expectedURL else {
          resolver.reject(CommonError.dismissed)
          return
        }
        chooser.subtitles = subs
        chooser.preselectedRow = preselected
        chooser.context = context
        chooser.player = player

        // Let the player abandon this search if the media changes or playback stops, so the
        // promise cannot be left pending with the chooser destroyed. Rejecting routes through the
        // normal error path, which resets `isSearchingOnlineSubtitle`.
        var settled = false
        let settle: (Bool) -> Void = { wasCancelled in
          guard !settled else { return }
          settled = true
          player.cancelOnlineSubtitleSearch = nil
          if wasCancelled {
            chooser.userDoneAction = nil
            chooser.userCanceledAction = nil
            chooser.context = nil
            player.hideOSD()
            resolver.reject(CommonError.dismissed)
          }
        }
        player.cancelOnlineSubtitleSearch = { settle(true) }

        chooser.userDoneAction = { chosen in
          settle(false)
          resolver.fulfill(chosen.compactMap { $0 as? S })
        }
        chooser.userCanceledAction = {
          settle(false)
          resolver.reject(CommonError.canceled)
        }

        player.sendOSD(.foundSub(subs.count), autoHide: false, accessoryView: chooser.view)
        chooser.reload()
      }
    }
  }
}
