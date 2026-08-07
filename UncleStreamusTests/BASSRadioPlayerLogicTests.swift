#if os(macOS)
import XCTest
@testable import UncleStreamus

/// Tests for the pure decision logic extracted out of BASSRadioPlayer's
/// hardware-bound methods (checkStreamStatus, scheduleReconnect, restartStream,
/// updateDVRBufferSize). See BASSRadioPlayerLogic.swift.
final class BASSRadioPlayerLogicTests: XCTestCase {

    // MARK: - playbackState(forActiveStatus:)

    func testPlaybackState_playing() {
        XCTAssertEqual(BASSRadioPlayerLogic.playbackState(forActiveStatus: 1), .playing)
    }

    func testPlaybackState_stalled() {
        XCTAssertEqual(BASSRadioPlayerLogic.playbackState(forActiveStatus: 3), .stalled)
    }

    func testPlaybackState_stopped() {
        XCTAssertEqual(BASSRadioPlayerLogic.playbackState(forActiveStatus: 0), .stopped)
    }

    func testPlaybackState_pausedOrOther_treatedAsConnecting() {
        // 2 = BASS_ACTIVE_PAUSED, 4 = BASS_ACTIVE_PAUSED_DEVICE — both map to connecting.
        XCTAssertEqual(BASSRadioPlayerLogic.playbackState(forActiveStatus: 2), .connecting)
        XCTAssertEqual(BASSRadioPlayerLogic.playbackState(forActiveStatus: 4), .connecting)
    }

    // MARK: - isAACUnderrun

    func testAACUnderrun_true_whenDrainedAfterProgress() {
        XCTAssertTrue(BASSRadioPlayerLogic.isAACUnderrun(
            statusIsPlaying: true, bufferedBytes: 0, positionBytes: 150_000))
    }

    func testAACUnderrun_false_whenBufferHasData() {
        XCTAssertFalse(BASSRadioPlayerLogic.isAACUnderrun(
            statusIsPlaying: true, bufferedBytes: 4096, positionBytes: 150_000))
    }

    func testAACUnderrun_false_beforeMeaningfulProgress() {
        // At/under the 100 KB threshold this is start-up, not an underrun.
        XCTAssertFalse(BASSRadioPlayerLogic.isAACUnderrun(
            statusIsPlaying: true, bufferedBytes: 0, positionBytes: 100_000))
    }

    func testAACUnderrun_false_whenNotPlaying() {
        XCTAssertFalse(BASSRadioPlayerLogic.isAACUnderrun(
            statusIsPlaying: false, bufferedBytes: 0, positionBytes: 150_000))
    }

    // MARK: - positionStaleness

    func testStaleness_advanced_whenPositionMoves() {
        let r = BASSRadioPlayerLogic.positionStaleness(
            positionBytes: 200, lastKnownBytes: 100, lastAdvanceTime: 10,
            now: 100, stallThreshold: 4, isReconnecting: false)
        XCTAssertEqual(r, .advanced)
    }

    func testStaleness_stale_whenFrozenPastThreshold() {
        let r = BASSRadioPlayerLogic.positionStaleness(
            positionBytes: 100, lastKnownBytes: 100, lastAdvanceTime: 10,
            now: 15, stallThreshold: 4, isReconnecting: false)
        XCTAssertEqual(r, .stale)
    }

    func testStaleness_holding_whenFrozenWithinThreshold() {
        let r = BASSRadioPlayerLogic.positionStaleness(
            positionBytes: 100, lastKnownBytes: 100, lastAdvanceTime: 10,
            now: 12, stallThreshold: 4, isReconnecting: false)
        XCTAssertEqual(r, .holding)
    }

    func testStaleness_holding_atExactThreshold() {
        // Strictly greater-than: exactly at threshold is not yet stale.
        let r = BASSRadioPlayerLogic.positionStaleness(
            positionBytes: 100, lastKnownBytes: 100, lastAdvanceTime: 10,
            now: 14, stallThreshold: 4, isReconnecting: false)
        XCTAssertEqual(r, .holding)
    }

    func testStaleness_holding_whenNoBaselineYet() {
        // lastKnownBytes == 0 means we have no advance baseline; never declare stale.
        let r = BASSRadioPlayerLogic.positionStaleness(
            positionBytes: 0, lastKnownBytes: 0, lastAdvanceTime: 0,
            now: 999, stallThreshold: 4, isReconnecting: false)
        XCTAssertEqual(r, .holding)
    }

    func testStaleness_holding_whenReconnecting() {
        let r = BASSRadioPlayerLogic.positionStaleness(
            positionBytes: 100, lastKnownBytes: 100, lastAdvanceTime: 10,
            now: 100, stallThreshold: 4, isReconnecting: true)
        XCTAssertEqual(r, .holding)
    }

    // MARK: - FLAC buffer health

    func testFlacRebufferComplete_atThreshold() {
        XCTAssertTrue(BASSRadioPlayerLogic.flacRebufferComplete(downloadPct: 40))
        XCTAssertTrue(BASSRadioPlayerLogic.flacRebufferComplete(downloadPct: 55))
    }

    func testFlacRebufferComplete_belowThreshold() {
        XCTAssertFalse(BASSRadioPlayerLogic.flacRebufferComplete(downloadPct: 39.9))
    }

    func testFlacProactiveRecovery_true_whenDrainingAndDisconnected() {
        XCTAssertTrue(BASSRadioPlayerLogic.shouldStartFlacProactiveRecovery(
            downloadPct: 8, isConnected: false, isAttemptingRecovery: false,
            hasRecoveryStream: false, isRebuffering: false))
    }

    func testFlacProactiveRecovery_false_whenHealthy() {
        XCTAssertFalse(BASSRadioPlayerLogic.shouldStartFlacProactiveRecovery(
            downloadPct: 18, isConnected: true, isAttemptingRecovery: false,
            hasRecoveryStream: false, isRebuffering: false))
    }

    func testFlacProactiveRecovery_false_whenStillConnected() {
        XCTAssertFalse(BASSRadioPlayerLogic.shouldStartFlacProactiveRecovery(
            downloadPct: 5, isConnected: true, isAttemptingRecovery: false,
            hasRecoveryStream: false, isRebuffering: false))
    }

    func testFlacProactiveRecovery_false_whenAlreadyRecovering() {
        XCTAssertFalse(BASSRadioPlayerLogic.shouldStartFlacProactiveRecovery(
            downloadPct: 5, isConnected: false, isAttemptingRecovery: true,
            hasRecoveryStream: false, isRebuffering: false))
        XCTAssertFalse(BASSRadioPlayerLogic.shouldStartFlacProactiveRecovery(
            downloadPct: 5, isConnected: false, isAttemptingRecovery: false,
            hasRecoveryStream: true, isRebuffering: false))
    }

    func testFlacProactiveRecovery_false_whenDownloadPctUnknown() {
        // dlPct < 0 is the "not measurable" sentinel; never act on it.
        XCTAssertFalse(BASSRadioPlayerLogic.shouldStartFlacProactiveRecovery(
            downloadPct: -1, isConnected: false, isAttemptingRecovery: false,
            hasRecoveryStream: false, isRebuffering: false))
    }

    // MARK: - reconnect backoff

    func testReconnectTimeout_graduatedByAttempt() {
        XCTAssertEqual(BASSRadioPlayerLogic.reconnectConnectTimeoutMs(attempt: 0), 10_000)
        XCTAssertEqual(BASSRadioPlayerLogic.reconnectConnectTimeoutMs(attempt: 1), 5_000)
        XCTAssertEqual(BASSRadioPlayerLogic.reconnectConnectTimeoutMs(attempt: 2), 3_000)
        XCTAssertEqual(BASSRadioPlayerLogic.reconnectConnectTimeoutMs(attempt: 9), 3_000)
    }

    func testGiveUpReconnect_atAndBeyondBudget() {
        XCTAssertFalse(BASSRadioPlayerLogic.shouldGiveUpReconnect(attempt: 11, maxAttempts: 12))
        XCTAssertTrue(BASSRadioPlayerLogic.shouldGiveUpReconnect(attempt: 12, maxAttempts: 12))
        XCTAssertTrue(BASSRadioPlayerLogic.shouldGiveUpReconnect(attempt: 13, maxAttempts: 12))
    }

    // MARK: - DVR buffer resize

    func testDVRResize_liveRecreates() {
        XCTAssertEqual(
            BASSRadioPlayerLogic.dvrBufferResize(isLive: true, newMaxSeconds: 600, recordedSeconds: 1200),
            .recreate)
    }

    func testDVRResize_growApplyImmediately() {
        // New window (20 min) still covers everything recorded (10 min).
        XCTAssertEqual(
            BASSRadioPlayerLogic.dvrBufferResize(isLive: false, newMaxSeconds: 1200, recordedSeconds: 600),
            .applyImmediately)
    }

    func testDVRResize_shrinkBelowRecordedDefers() {
        // New window (5 min) would truncate the 10 min already recorded.
        XCTAssertEqual(
            BASSRadioPlayerLogic.dvrBufferResize(isLive: false, newMaxSeconds: 300, recordedSeconds: 600),
            .deferToGoLive)
    }

    func testDVRResize_exactFitAppliesImmediately() {
        XCTAssertEqual(
            BASSRadioPlayerLogic.dvrBufferResize(isLive: false, newMaxSeconds: 600, recordedSeconds: 600),
            .applyImmediately)
    }

    // MARK: - compressorParams(amount:measuredRMSdB:)

    private let cAccuracy: Float = 1e-4

    func testCompressor_gentle_amountZero() {
        // t = 0 → headroom 6 dB, threshold = RMS + 6, ratio 1.5.
        let p = BASSRadioPlayerLogic.compressorParams(amount: 0, measuredRMSdB: -20)
        XCTAssertEqual(p.threshold, -14, accuracy: cAccuracy)   // -20 + 6
        XCTAssertEqual(p.ratio,     1.5, accuracy: cAccuracy)
        XCTAssertEqual(p.attack,    25,  accuracy: cAccuracy)
        XCTAssertEqual(p.release,   300, accuracy: cAccuracy)
        // gain = 14 * (1 - 1/1.5) * (0.5 + 0) = 14 * (1/3) * 0.5
        XCTAssertEqual(p.gain, 14 * (1 - 1/1.5) * 0.5, accuracy: cAccuracy)
    }

    func testCompressor_heavy_amountOne() {
        // t = 0.75 → headroom 6 - 3.75 = 2.25 dB, threshold = RMS + 2.25.
        let p = BASSRadioPlayerLogic.compressorParams(amount: 1.0, measuredRMSdB: -20)
        XCTAssertEqual(p.threshold, -17.75, accuracy: cAccuracy)   // -20 + 2.25
        XCTAssertEqual(p.ratio,     1.5 + 6.5 * 0.75, accuracy: cAccuracy)
        XCTAssertEqual(p.attack,    25 - 22 * 0.75, accuracy: cAccuracy)
        XCTAssertEqual(p.release,   300 - 220 * 0.75, accuracy: cAccuracy)
    }

    func testCompressor_thresholdClampedHigh() {
        // Very loud program: RMS -1 + 6 = +5 would exceed the -2 dBFS ceiling.
        let p = BASSRadioPlayerLogic.compressorParams(amount: 0, measuredRMSdB: -1)
        XCTAssertEqual(p.threshold, -2, accuracy: cAccuracy)
    }

    func testCompressor_thresholdClampedLow() {
        // Near-silent program: RMS -80 + 6 = -74 would exceed the -40 dBFS floor.
        let p = BASSRadioPlayerLogic.compressorParams(amount: 0, measuredRMSdB: -80)
        XCTAssertEqual(p.threshold, -40, accuracy: cAccuracy)
    }

    // MARK: - shouldReapplyCompressor(newThreshold:lastAppliedThreshold:)

    func testReapplyCompressor_true_whenChangeExceedsHalfDB() {
        XCTAssertTrue(BASSRadioPlayerLogic.shouldReapplyCompressor(newThreshold: -14, lastAppliedThreshold: -14.6))
    }

    func testReapplyCompressor_false_whenChangeAtOrBelowHalfDB() {
        // Exactly 0.5 dB is not "> 0.5" — no re-apply.
        XCTAssertFalse(BASSRadioPlayerLogic.shouldReapplyCompressor(newThreshold: -14, lastAppliedThreshold: -14.5))
        XCTAssertFalse(BASSRadioPlayerLogic.shouldReapplyCompressor(newThreshold: -14, lastAppliedThreshold: -14.3))
    }

    // MARK: - isFXBeingUsed(...)

    private func fxUsed(masterBypass: Bool = false,
                        eqEnabled: Bool = true, low: Float = 0, mid: Float = 0, high: Float = 0,
                        compressorOn: Bool = false,
                        stereoEnabled: Bool = true, width: Float = 0.75, pan: Float = 0.5,
                        subBass: Bool = false) -> Bool {
        BASSRadioPlayerLogic.isFXBeingUsed(
            masterBypassEnabled: masterBypass,
            eqEnabled: eqEnabled, eqLowGain: low, eqMidGain: mid, eqHighGain: high,
            compressorOn: compressorOn,
            stereoWidthEnabled: stereoEnabled, stereoWidth: width, stereoPan: pan,
            subBassEnabled: subBass)
    }

    func testFXUsed_falseAtAllDefaults() {
        XCTAssertFalse(fxUsed())
    }

    func testFXUsed_masterBypassWinsOverEverything() {
        XCTAssertFalse(fxUsed(masterBypass: true, mid: 6, compressorOn: true, width: 1.0, subBass: true))
    }

    func testFXUsed_eqCountsOnlyWhenEnabledAndNonZero() {
        XCTAssertTrue(fxUsed(mid: 3))                       // enabled + non-zero band
        XCTAssertFalse(fxUsed(eqEnabled: false, mid: 3))    // gain set but EQ off → not used
    }

    func testFXUsed_compressorOnAlwaysCounts() {
        XCTAssertTrue(fxUsed(compressorOn: true))
    }

    func testFXUsed_stereoCountsOnlyWhenMovedOffDefaults() {
        XCTAssertTrue(fxUsed(width: 1.0))                       // width off default
        XCTAssertTrue(fxUsed(pan: 0.3))                         // pan off default
        XCTAssertFalse(fxUsed(stereoEnabled: false, width: 1.0)) // moved but disabled
    }

    func testFXUsed_subBassCounts() {
        XCTAssertTrue(fxUsed(subBass: true))
    }

    // MARK: - behindLivePaused(...)

    private let dAccuracy: Double = 1e-9

    func testBehindLivePaused_uncapped() {
        // handleDVRBufferFull path: no cap.
        XCTAssertEqual(BASSRadioPlayerLogic.behindLivePaused(bufferedDuration: 1399, pauseTimestamp: 9),
                       1390, accuracy: dAccuracy)
    }

    func testBehindLivePaused_clampedToZero() {
        // Pause point ahead of buffered content → never negative.
        XCTAssertEqual(BASSRadioPlayerLogic.behindLivePaused(bufferedDuration: 5, pauseTimestamp: 20),
                       0, accuracy: dAccuracy)
    }

    func testBehindLivePaused_cappedAtMax() {
        // Paused-tick path: capped at the buffer max (900 s).
        XCTAssertEqual(BASSRadioPlayerLogic.behindLivePaused(bufferedDuration: 2000, pauseTimestamp: 0, cappedAt: 900),
                       900, accuracy: dAccuracy)
    }

    // MARK: - behindLivePlaying(...)

    func testBehindLivePlaying_headMinusPlaybackPosition() {
        // Recording head at 1200 s; playing seg 3 (×60) + 25 s in = 205 s → 995 behind.
        XCTAssertEqual(
            BASSRadioPlayerLogic.behindLivePlaying(bufferedDuration: 1200, currentSegNum: 3,
                                                   segmentDuration: 60, positionSeconds: 25),
            995, accuracy: dAccuracy)
    }

    func testBehindLivePlaying_clampedToZero() {
        XCTAssertEqual(
            BASSRadioPlayerLogic.behindLivePlaying(bufferedDuration: 100, currentSegNum: 3,
                                                   segmentDuration: 60, positionSeconds: 0),
            0, accuracy: dAccuracy)
    }

    // MARK: - dvrSegmentIndex(...)

    func testDVRSegmentIndex_floorsToSegment() {
        XCTAssertEqual(BASSRadioPlayerLogic.dvrSegmentIndex(pauseTimestamp: 185, segmentDuration: 60), 3)
        XCTAssertEqual(BASSRadioPlayerLogic.dvrSegmentIndex(pauseTimestamp: 0,   segmentDuration: 60), 0)
        XCTAssertEqual(BASSRadioPlayerLogic.dvrSegmentIndex(pauseTimestamp: 59,  segmentDuration: 60), 0)
    }

    func testDVRSegmentIndex_zeroDurationGuarded() {
        XCTAssertEqual(BASSRadioPlayerLogic.dvrSegmentIndex(pauseTimestamp: 100, segmentDuration: 0), 0)
    }

    // MARK: - shouldPreloadNextSegment(...)

    func testPreload_true_whenNextSegmentHasEnoughLead() {
        // seg 2 → nextTs = 3×60 = 180; buffered 183 → 3 s lead ≥ 2.
        let nextTs = BASSRadioPlayerLogic.dvrNextSegmentTimestamp(currentSegNum: 2, segmentDuration: 60)
        XCTAssertEqual(nextTs, 180, accuracy: dAccuracy)
        XCTAssertTrue(BASSRadioPlayerLogic.shouldPreloadNextSegment(bufferedDuration: 183, nextSegmentTimestamp: nextTs))
    }

    func testPreload_true_atExactlyMinLead() {
        // Exactly 2 s lead satisfies the >= threshold.
        XCTAssertTrue(BASSRadioPlayerLogic.shouldPreloadNextSegment(bufferedDuration: 182, nextSegmentTimestamp: 180))
    }

    func testPreload_false_whenNextSegmentNearlyEmpty() {
        // 1 s lead < 2 → would cause rapid cycling / false go-live.
        XCTAssertFalse(BASSRadioPlayerLogic.shouldPreloadNextSegment(bufferedDuration: 181, nextSegmentTimestamp: 180))
    }

    // MARK: - dvrResumeAction(...)

    func testResumeAction_frozenPump_isStale() {
        // The reported failure: away 2 hours, keepalive died after ~8 s of recording.
        XCTAssertEqual(BASSRadioPlayerLogic.dvrResumeAction(
            wallSecondsSincePause: 7200, recordedSecondsSincePause: 8, bufferIsFull: false),
            .goLiveStale)
    }

    func testResumeAction_healthyBackgroundPause_resumes() {
        // Keepalive held: recorded tracks wall clock ~1 s/s.
        XCTAssertEqual(BASSRadioPlayerLogic.dvrResumeAction(
            wallSecondsSincePause: 1800, recordedSecondsSincePause: 1795, bufferIsFull: false),
            .resumeFromBuffer)
    }

    func testResumeAction_flakyOvernight_resumes() {
        // Hours of valid audio with network losses: the gap is huge but the ratio holds.
        XCTAssertEqual(BASSRadioPlayerLogic.dvrResumeAction(
            wallSecondsSincePause: 28800, recordedSecondsSincePause: 20000, bufferIsFull: false),
            .resumeFromBuffer)
    }

    func testResumeAction_shortPauseFreeze_resumes() {
        // Recorded nothing, but only 90 s elapsed — under the absolute gap, so not stale.
        XCTAssertEqual(BASSRadioPlayerLogic.dvrResumeAction(
            wallSecondsSincePause: 90, recordedSecondsSincePause: 0, bufferIsFull: false),
            .resumeFromBuffer)
    }

    func testResumeAction_gapBoundary_isExclusive() {
        // gap == 120 does not trip; just past it does (ratio fails in both cases).
        XCTAssertEqual(BASSRadioPlayerLogic.dvrResumeAction(
            wallSecondsSincePause: 130, recordedSecondsSincePause: 10, bufferIsFull: false),
            .resumeFromBuffer)
        XCTAssertEqual(BASSRadioPlayerLogic.dvrResumeAction(
            wallSecondsSincePause: 130.1, recordedSecondsSincePause: 10, bufferIsFull: false),
            .goLiveStale)
    }

    func testResumeAction_ratioBoundary_isExclusive() {
        // Exactly half of wall recorded counts as healthy despite a 300 s gap.
        XCTAssertEqual(BASSRadioPlayerLogic.dvrResumeAction(
            wallSecondsSincePause: 600, recordedSecondsSincePause: 300, bufferIsFull: false),
            .resumeFromBuffer)
        XCTAssertEqual(BASSRadioPlayerLogic.dvrResumeAction(
            wallSecondsSincePause: 600, recordedSecondsSincePause: 299, bufferIsFull: false),
            .goLiveStale)
    }

    func testResumeAction_fullBufferOverridesStaleness() {
        // Recording stopped on purpose when the ring filled — the buffer is complete.
        XCTAssertEqual(BASSRadioPlayerLogic.dvrResumeAction(
            wallSecondsSincePause: 7200, recordedSecondsSincePause: 8, bufferIsFull: true),
            .resumeFromBuffer)
    }

    func testResumeAction_negativeInputsClampToHealthy() {
        // A backwards clock change or unset pause time must not fake a stale buffer.
        XCTAssertEqual(BASSRadioPlayerLogic.dvrResumeAction(
            wallSecondsSincePause: -5000, recordedSecondsSincePause: -10, bufferIsFull: false),
            .resumeFromBuffer)
    }

    func testResumeAction_zeroWall_resumes() {
        XCTAssertEqual(BASSRadioPlayerLogic.dvrResumeAction(
            wallSecondsSincePause: 0, recordedSecondsSincePause: 0, bufferIsFull: false),
            .resumeFromBuffer)
    }
}
#endif
