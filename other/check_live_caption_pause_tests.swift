@main
struct LiveCaptionPauseChecks {
  private static var checks = 0

  private static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    checks += 1
    guard condition() else {
      fputs("FAIL: \(message)\n", stderr)
      exit(1)
    }
  }

  static func main() {
    let decodeQueue = DispatchQueue(label: "live-caption-pause-order-check")
    let decodeOrder = LiveCaptionDecodeQueueOrder(queue: decodeQueue)
    let readStarted = DispatchSemaphore(value: 0)
    let finishRead = DispatchSemaphore(value: 0)
    let resumedReadFinished = DispatchSemaphore(value: 0)
    let queueProbe = DecodeQueueProbe()
    decodeOrder.enqueueRead {
      queueProbe.record("decode-started")
      readStarted.signal()
      _ = finishRead.wait(timeout: .now() + 2)
      queueProbe.record("decode-finished")
    }
    check(readStarted.wait(timeout: .now() + 2) == .success,
          "the simulated FFmpeg read reaches its queue-owned active section")
    // This is the same admission path production uses. Serial queue ordering must drain the active
    // decode, release its reader, and only then run resumed work.
    decodeOrder.enqueueReaderRetirement {
      queueProbe.retireReader()
    }
    decodeOrder.enqueueRead {
      queueProbe.record(queueProbe.readerIsActive ? "resumed-with-reader" : "resumed-after-retirement")
      resumedReadFinished.signal()
    }
    finishRead.signal()
    check(resumedReadFinished.wait(timeout: .now() + 2) == .success,
          "resumed decode reaches the queue after pause cleanup")
    check(queueProbe.events == ["decode-started", "decode-finished", "reader-retired",
                                "resumed-after-retirement"] && !queueProbe.readerIsActive,
          "pause retirement runs after the active decode and before a resumed read")

    let admissionQueue = DispatchQueue(label: "live-caption-bounded-admission-check")
    let admission = LiveCaptionDecodeQueueOrder(queue: admissionQueue)
    let admissionProbe = DecodeQueueProbe()
    let activeReadStarted = DispatchSemaphore(value: 0)
    let releaseActiveRead = DispatchSemaphore(value: 0)
    let latestReadFinished = DispatchSemaphore(value: 0)
    admission.enqueueRead {
      admissionProbe.record("blocked-decode-started")
      activeReadStarted.signal()
      _ = releaseActiveRead.wait(timeout: .now() + 3)
      admissionProbe.record("blocked-decode-finished")
    }
    check(activeReadStarted.wait(timeout: .now() + 2) == .success,
          "the bounded-admission fixture holds one fake FFmpeg decode active")
    for cycle in 0..<500 {
      let cycleID = cycle
      admission.enqueueReaderRetirement {
        admissionProbe.record("reader-retired-\(cycleID)")
      }
      admission.enqueueRead {
        admissionProbe.record("read-\(cycleID)")
        latestReadFinished.signal()
      }
    }
    check(admission.pendingOperationCountForTesting == 2,
          "500 pause/resume cycles retain at most one coalesced retirement and one latest read")
    releaseActiveRead.signal()
    check(latestReadFinished.wait(timeout: .now() + 2) == .success,
          "the newest resumed read runs after the blocked decode drains")
    check(admissionProbe.events == ["blocked-decode-started", "blocked-decode-finished",
                                    "reader-retired-499", "read-499"],
          "rapid pause/resume drops stale queued reads and retires the reader before the latest read")

    let pauseQueue = DispatchQueue(label: "live-caption-pending-read-cancel-check")
    let pauseAdmission = LiveCaptionDecodeQueueOrder(queue: pauseQueue)
    let pauseProbe = DecodeQueueProbe()
    let pauseReadStarted = DispatchSemaphore(value: 0)
    let releasePauseRead = DispatchSemaphore(value: 0)
    let pauseRetirementFinished = DispatchSemaphore(value: 0)
    pauseAdmission.enqueueRead {
      pauseReadStarted.signal()
      _ = releasePauseRead.wait(timeout: .now() + 3)
    }
    check(pauseReadStarted.wait(timeout: .now() + 2) == .success,
          "the pause fixture starts one active fake decode")
    pauseAdmission.enqueueRead { pauseProbe.record("stale-read") }
    pauseAdmission.enqueueReaderRetirement {
      pauseProbe.record("paused-reader-retired")
      pauseRetirementFinished.signal()
    }
    check(pauseAdmission.pendingOperationCountForTesting == 1,
          "pause removes a pending resumed read while retaining one reader retirement")
    releasePauseRead.signal()
    check(pauseRetirementFinished.wait(timeout: .now() + 2) == .success &&
          pauseProbe.events == ["paused-reader-retired"],
          "a pause with no later resume retires the reader without running stale pending work")

    var state = LiveCaptionWorkState()
    state.requestedStart = 30
    let oldWorkToken = state.generation
    check(state.accepts(oldWorkToken), "the current caption generation accepts its own work token")

    state.pause()
    check(!state.accepts(oldWorkToken) && state.requestedStart == nil,
          "pause retires callbacks and clears the in-flight excerpt")
    check(state.nextStart(position: 47, chunkDuration: 10) == 40,
          "resume begins with the excerpt covering the current playhead")

    state.requestedStart = state.nextStart(position: 47, chunkDuration: 10)
    check(state.nextStart(position: 49, chunkDuration: 10) == 50,
          "after the retried excerpt, normal chunk scheduling advances once")

    let pausedToken = state.generation
    state.pause()
    check(!state.accepts(pausedToken) && state.requestedStart == nil &&
          state.nextStart(position: 9, chunkDuration: 10) == 0,
          "repeated pause/resume cycles continue to invalidate stale work and reselect by playhead")

    var legacySpeech = LiveCaptionLegacySpeechTaskState()
    guard let legacyIdentifier = legacySpeech.begin() else {
      check(false, "an idle legacy Speech task slot admits its first task")
      return
    }
    for _ in 0..<10_000 {
      check(legacySpeech.begin() == nil && legacySpeech.hasActiveTask,
            "repeated resume attempts stay behind the still-canceling legacy task")
    }
    check(!legacySpeech.finish(UUID()) && legacySpeech.hasActiveTask,
          "a stale legacy Speech callback cannot release another task's admission slot")
    check(legacySpeech.finish(legacyIdentifier) && !legacySpeech.hasActiveTask &&
          legacySpeech.begin() != nil,
          "only the terminal callback releases the slot for the next legacy Speech task")

    let selectedInternal = LiveCaptionAudioStreamSelection.resolve(
      selectedTrackID: 3, candidateTrackID: 3, isExternal: false, streamIndex: 1)
    check(selectedInternal == LiveCaptionAudioStreamSelection(trackID: 3, streamIndex: 1),
          "the selected internal mpv track maps to its FFmpeg stream index")
    check(LiveCaptionAudioStreamSelection.resolve(
      selectedTrackID: 3, candidateTrackID: 2, isExternal: false, streamIndex: 0) == nil,
          "a different default stream cannot substitute for the selected mpv track")
    check(LiveCaptionAudioStreamSelection.resolve(
      selectedTrackID: 3, candidateTrackID: 3, isExternal: true, streamIndex: 1) == nil,
          "external audio is rejected instead of captioning an unrelated embedded stream")
    check(LiveCaptionAudioStreamSelection.resolve(
      selectedTrackID: 3, candidateTrackID: 3, isExternal: false, streamIndex: nil) == nil &&
          LiveCaptionAudioStreamSelection.resolve(
            selectedTrackID: 0, candidateTrackID: 0, isExternal: false, streamIndex: 1) == nil,
          "none or unmappable audio selections fail closed")

    let mediaURL = URL(fileURLWithPath: "/tmp/live-caption-locale-test.mov")
    var locales = LiveCaptionLocaleLookupState()
    let initialRequest = LiveCaptionLocaleLookupRequest(localeID: "en-US", mediaURL: mediaURL,
                                                        generation: 1)
    guard let activeLookup = locales.request(initialRequest) else {
      check(false, "the initial locale lookup is admitted")
      return
    }
    check(locales.activeLookupID == activeLookup.id,
          "locale discovery retains the currently active lookup identity")

    var latestRequest = initialRequest
    for cycle in 0..<10_000 {
      check(locales.cancel() == activeLookup.id,
            "cancellation invalidates the active result without freeing its lookup slot")
      latestRequest = LiveCaptionLocaleLookupRequest(localeID: cycle.isMultiple(of: 2) ? "en-US" : "fr-FR",
                                                     mediaURL: mediaURL, generation: cycle + 2)
      check(locales.request(latestRequest) == nil && locales.activeLookupID == activeLookup.id,
            "rapid resume coalesces behind the still-suspended system lookup")
    }
    guard case .start(let resumedLookup)? = locales.finish(activeLookup.id) else {
      check(false, "the suspended lookup starts only the latest coalesced request when it returns")
      return
    }
    check(resumedLookup.request == latestRequest && resumedLookup.id != activeLookup.id,
          "completion starts the newest locale and generation after the old request retires")
    guard case .publish(let publishedRequest)? = locales.finish(resumedLookup.id) else {
      check(false, "the resumed lookup can publish after it completes")
      return
    }
    check(publishedRequest == latestRequest && locales.activeLookupID == nil,
          "only the latest lookup publishes and releases the slot")

    let localeChange = LiveCaptionLocaleLookupRequest(localeID: "en-US", mediaURL: mediaURL,
                                                     generation: 20_000)
    let changedLocale = LiveCaptionLocaleLookupRequest(localeID: "de-DE", mediaURL: mediaURL,
                                                       generation: 20_000)
    let latestLocale = LiveCaptionLocaleLookupRequest(localeID: "ja-JP", mediaURL: mediaURL,
                                                     generation: 20_000)
    guard let localeLookup = locales.request(localeChange) else {
      check(false, "locale-change fixture starts an idle lookup")
      return
    }
    check(locales.request(changedLocale) == nil && locales.request(latestLocale) == nil,
          "locale changes replace the pending desired request instead of starting more lookups")
    guard case .start(let latestLocaleLookup)? = locales.finish(localeLookup.id) else {
      check(false, "a changed locale starts after the in-flight locale lookup retires")
      return
    }
    check(latestLocaleLookup.request == latestLocale,
          "only the latest selected locale is retained for the next lookup")
    guard case .publish(let finalLocale)? = locales.finish(latestLocaleLookup.id) else {
      check(false, "the latest selected locale can finish")
      return
    }
    check(finalLocale == latestLocale && locales.activeLookupID == nil,
          "locale lookup state returns to idle after final publication")

    let oneXSize = 55 * LiveCaptionDisplayScale.unitScale(
      videoHeight: 720, backingScale: 1, scalesWithWindow: false, subtitleScale: 1)
    let twoXSize = 55 * LiveCaptionDisplayScale.unitScale(
      videoHeight: 720, backingScale: 2, scalesWithWindow: false, subtitleScale: 1)
    check(oneXSize == 55 && twoXSize == 27.5,
          "same-size unscaled captions recompute their size when backing scale changes")
    let windowScaledAtOneX = LiveCaptionDisplayScale.unitScale(
      videoHeight: 720, backingScale: 1, scalesWithWindow: true, subtitleScale: 1)
    let windowScaledAtTwoX = LiveCaptionDisplayScale.unitScale(
      videoHeight: 720, backingScale: 2, scalesWithWindow: true, subtitleScale: 1)
    check(windowScaledAtOneX == windowScaledAtTwoX,
          "window-scaled caption geometry remains tied to video bounds instead of backing scale")

    let bottomAt100 = LiveCaptionVerticalPosition.bottomConstraintConstant(
      position: 100, videoHeight: 720, captionHeight: 80, marginY: 22,
      edgeInset: 22, minimumGap: 8)
    let bottomAt110 = LiveCaptionVerticalPosition.bottomConstraintConstant(
      position: 110, videoHeight: 720, captionHeight: 80, marginY: 22,
      edgeInset: 22, minimumGap: 8)
    let bottomAt150 = LiveCaptionVerticalPosition.bottomConstraintConstant(
      position: 150, videoHeight: 720, captionHeight: 80, marginY: 22,
      edgeInset: 22, minimumGap: 8)
    check(bottomAt100 < bottomAt110 && bottomAt110 < bottomAt150,
          "bottom-aligned subtitle position remains adjustable above the default 100")
    check(bottomAt100 == -22 && bottomAt150 == -8,
          "bottom-aligned positions preserve the configured baseline and stay inside the edge inset")
    let tinyVideoPosition = LiveCaptionVerticalPosition.bottomConstraintConstant(
      position: 150, videoHeight: 18, captionHeight: 18, marginY: 50,
      edgeInset: 16, minimumGap: 4)
    check(tinyVideoPosition == -4,
          "extreme position and caption height remain bounded on a tiny video surface")

    let shortVideoHeight: CGFloat = 18
    let shortVideoInset = LiveCaptionVerticalBounds.edgeInset(
      videoHeight: shortVideoHeight, requestedInset: 16)
    let shortVideoMaximumHeight = LiveCaptionVerticalBounds.maximumCaptionHeight(
      videoHeight: shortVideoHeight, edgeInset: shortVideoInset)
    let clippedLongCaption = LiveCaptionVerticalBounds.renderedCaptionHeight(
      measuredHeight: 500, maximumHeight: shortVideoMaximumHeight)
    check(shortVideoInset == 8.5 && shortVideoMaximumHeight == 1 && clippedLongCaption == 1,
          "a long caption on an 18-point video is constrained to its one-point safe area")

    let shortBottomPositions = [CGFloat(100), CGFloat(110), CGFloat(150)].map {
      LiveCaptionVerticalPosition.bottomConstraintConstant(
        position: $0, videoHeight: shortVideoHeight, captionHeight: clippedLongCaption,
        marginY: shortVideoInset, edgeInset: shortVideoInset, minimumGap: 4)
    }
    check(shortBottomPositions[0] < shortBottomPositions[1] &&
          shortBottomPositions[1] < shortBottomPositions[2],
          "100, 110, and 150 remain distinct with a long caption in a short video")
    check(shortBottomPositions.allSatisfy {
      let top = shortVideoHeight + $0 - clippedLongCaption
      let bottom = shortVideoHeight + $0
      return top >= shortVideoInset && bottom <= shortVideoHeight - 4
    }, "short-video positions remain within the fitted caption and visible-edge limits")

    print("\(checks) live-caption pause checks passed")
  }
}

private final class DecodeQueueProbe {
  private let lock = NSLock()
  private var active = true
  private var recordedEvents: [String] = []

  var readerIsActive: Bool {
    lock.lock()
    defer { lock.unlock() }
    return active
  }

  var events: [String] {
    lock.lock()
    defer { lock.unlock() }
    return recordedEvents
  }

  func record(_ event: String) {
    lock.lock()
    recordedEvents.append(event)
    lock.unlock()
  }

  func retireReader() {
    lock.lock()
    active = false
    recordedEvents.append("reader-retired")
    lock.unlock()
  }
}
