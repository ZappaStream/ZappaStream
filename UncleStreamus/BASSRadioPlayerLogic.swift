//
//  BASSRadioPlayerLogic.swift
//  UncleStreamus
//
//  Pure, BASS-free decision logic extracted from BASSRadioPlayer and its
//  extensions. These functions were previously inline in checkStreamStatus(),
//  scheduleReconnect(), restartStream(), updateDVRBufferSize(),
//  applyCompressorParams(), applyAdaptiveCompressor(), isFXBeingUsed and the
//  DVR timing call sites — places that can't be unit-tested directly because
//  they touch the BASS C API and live audio hardware. The predicates and
//  arithmetic, however, are pure: given a few scalar inputs they return a
//  decision. They live here so there is a single, testable source of truth,
//  mirroring the ContentViewShared.swift pattern.
//
//  Nothing here imports BASS or mutates state — the BASSRadioPlayer methods keep
//  their thin shells (read BASS values in, apply side effects out) and call into
//  these for every branch decision. Behavior is unchanged.
//

import Foundation

enum BASSRadioPlayerLogic {

    // MARK: - Playback State Mapping

    /// Maps a raw `BASS_ChannelIsActive` status to the app's `PlaybackState`.
    /// BASS status values: 0 = stopped, 1 = playing, 3 = stalled; anything else
    /// (paused / paused-device) is treated as still connecting.
    static func playbackState(forActiveStatus status: UInt32) -> PlaybackState {
        switch Int32(status) {
        case 1:  return .playing
        case 3:  return .stalled
        case 0:  return .stopped
        default: return .connecting
        }
    }

    // MARK: - Auto-Restart Predicates

    /// AAC buffer-underrun signal: BASS still reports PLAYING but the download
    /// buffer has fully drained after we'd already decoded a meaningful amount.
    /// `bufferedBytes == 0` after `positionBytes > 100 KB` reliably means the
    /// network feed died mid-stream. (The caller separately bails if a reconnect
    /// is already in flight.)
    static func isAACUnderrun(statusIsPlaying: Bool,
                              bufferedBytes: UInt64,
                              positionBytes: UInt64) -> Bool {
        statusIsPlaying
            && bufferedBytes == 0
            && positionBytes > 100_000
    }

    /// Outcome of the decode-position staleness check: catches network loss where
    /// BASS keeps the stream PLAYING but the decode position stops advancing (the
    /// canonical AAC + AudioToolbox "can't decode this packet" loop).
    enum PositionStaleness: Equatable {
        case advanced  // position moved; caller should record (positionBytes, now)
        case stale     // frozen past the threshold; trigger a restart
        case holding   // not advanced yet, but not stale either
    }

    /// Decides whether the decode position has gone stale.
    /// - `stallThreshold`: seconds of no advance before declaring a stall (4s =
    ///   2× the state-poll interval; AAC's tiny pre-mixer buffer freezes within a
    ///   fraction of a second on network loss, so two missed polls is safe).
    static func positionStaleness(positionBytes: UInt64,
                                  lastKnownBytes: UInt64,
                                  lastAdvanceTime: TimeInterval,
                                  now: TimeInterval,
                                  stallThreshold: TimeInterval,
                                  isReconnecting: Bool) -> PositionStaleness {
        if positionBytes > lastKnownBytes {
            return .advanced
        }
        if lastKnownBytes > 0,
           lastAdvanceTime > 0,
           now - lastAdvanceTime > stallThreshold,
           !isReconnecting {
            return .stale
        }
        return .holding
    }

    // MARK: - FLAC Buffer Health

    /// Download-buffer fill (0–100) at which a FLAC recovery stream has rebuffered
    /// enough to unpause (mirrors the ~10s initial-connect wait).
    static let flacRebufferThresholdPct: Double = 40

    /// True once the FLAC recovery stream's download buffer has refilled enough to
    /// resume decoding.
    static func flacRebufferComplete(downloadPct: Double,
                                     threshold: Double = flacRebufferThresholdPct) -> Bool {
        downloadPct >= threshold
    }

    /// Proactive FLAC recovery: pre-create a backup stream when the download buffer
    /// drops below 10% while disconnected and no recovery is already underway.
    /// Normal dlBuf sits at 17–20%, so <10% reliably signals genuine network loss.
    static func shouldStartFlacProactiveRecovery(downloadPct: Double,
                                                 isConnected: Bool,
                                                 isAttemptingRecovery: Bool,
                                                 hasRecoveryStream: Bool,
                                                 isRebuffering: Bool) -> Bool {
        downloadPct >= 0
            && downloadPct < 10
            && !isConnected
            && !isAttemptingRecovery
            && !hasRecoveryStream
            && !isRebuffering
    }

    // MARK: - Reconnect Backoff

    /// Graduated connect timeout (ms) by attempt number:
    ///   attempt 0 → 10s (first try; network may just be flaky)
    ///   attempt 1 → 5s  (path just reported satisfied + first retry)
    ///   attempt 2+ → 3s (fast-fail to burn through the budget quickly)
    static func reconnectConnectTimeoutMs(attempt: Int) -> UInt32 {
        switch attempt {
        case 0:  return 10_000
        case 1:  return 5_000
        default: return 3_000
        }
    }

    /// Whether the reconnect loop has exhausted its budget and should give up
    /// (transition to `.stopped`).
    static func shouldGiveUpReconnect(attempt: Int, maxAttempts: Int) -> Bool {
        attempt >= maxAttempts
    }

    // MARK: - DVR Buffer Resize

    /// What to do when the user changes the DVR buffer-size preference.
    enum DVRBufferResize: Equatable {
        case recreate          // live: tear down and rebuild the ring at the new size
        case applyImmediately  // paused/playing but new window still covers everything recorded
        case deferToGoLive     // shrinking would truncate playable content; wait until next go-live
    }

    /// Decides how to apply a DVR buffer-size change.
    /// - `recordedSeconds`: how much is currently behind the live edge (`behindLiveSeconds`).
    static func dvrBufferResize(isLive: Bool,
                                newMaxSeconds: Double,
                                recordedSeconds: Double) -> DVRBufferResize {
        if isLive {
            return .recreate
        }
        if newMaxSeconds >= recordedSeconds {
            return .applyImmediately
        }
        return .deferToGoLive
    }

    // MARK: - Compressor Parameters

    /// Fully-derived adaptive-compressor settings. Every coefficient that shapes the
    /// compressor curve lives here so a refactor can't silently alter the sound — the
    /// BASS-touching `applyCompressorParams()` is just a thin shell that copies these
    /// into a `BASS_BFX_COMPRESSOR2` and pushes it.
    struct CompressorParams: Equatable {
        var threshold: Float   // dBFS
        var ratio: Float
        var attack: Float      // ms
        var release: Float     // ms
        var gain: Float        // makeup gain, dB
    }

    /// Derives the adaptive compressor parameters from the slider and the measured level.
    /// - `amount`: raw slider value (0…1); scaled ×0.75 internally so the max maps to the
    ///   old tamer ceiling.
    /// - `measuredRMSdB`: slow-moving program level from the level-meter DSP.
    /// The threshold sits `headroom` dB above the measured RMS (6 dB at gentle → 2.25 dB
    /// at heavy) and is clamped to [-40, -2] dBFS.
    static func compressorParams(amount: Float, measuredRMSdB: Float) -> CompressorParams {
        let t = amount * 0.75
        let headroom: Float = 6.0 - 5.0 * t
        let threshold = max(min(measuredRMSdB + headroom, -2.0), -40.0)
        let ratio: Float = 1.5 + 6.5 * t
        return CompressorParams(
            threshold: threshold,
            ratio:     ratio,
            attack:    25 - 22 * t,
            release:   300 - 220 * t,
            gain:      (-threshold) * (1.0 - 1.0 / ratio) * (0.5 + 0.25 * t)
        )
    }

    /// Minimum threshold change (dB) worth pushing to BASS — avoids churning
    /// `BASS_FXSetParameters` on sub-audible level drift.
    static let compressorReapplyThresholdDB: Float = 0.5

    /// Whether a freshly-computed threshold differs enough from the last-applied one to
    /// justify re-applying the compressor.
    static func shouldReapplyCompressor(newThreshold: Float,
                                        lastAppliedThreshold: Float,
                                        minChangeDB: Float = compressorReapplyThresholdDB) -> Bool {
        abs(newThreshold - lastAppliedThreshold) > minChangeDB
    }

    // MARK: - FX Active Predicate

    /// Whether any effect is audibly engaged — drives the FX-active UI indicator.
    /// Master bypass wins outright. Stereo counts only when enabled *and* moved off its
    /// defaults (width 0.75 = "original" stereo, pan 0.5 = centre); EQ counts only when
    /// enabled *and* at least one band is non-zero.
    static func isFXBeingUsed(masterBypassEnabled: Bool,
                              eqEnabled: Bool,
                              eqLowGain: Float, eqMidGain: Float, eqHighGain: Float,
                              compressorOn: Bool,
                              stereoWidthEnabled: Bool,
                              stereoWidth: Float, stereoPan: Float,
                              subBassEnabled: Bool) -> Bool {
        guard !masterBypassEnabled else { return false }
        let eqIsUsed = eqEnabled && (eqLowGain != 0 || eqMidGain != 0 || eqHighGain != 0)
        let stereoIsUsed = stereoWidthEnabled && (stereoWidth != 0.75 || stereoPan != 0.5)
        return eqIsUsed || compressorOn || stereoIsUsed || subBassEnabled
    }

    // MARK: - DVR Behind-Live Timing

    /// Seconds of playable buffer behind the live edge, measured from the pause point.
    /// Used by `handleDVRBufferFull` (no cap) and the paused-state tick (`cappedAt` = the
    /// buffer max). `bufferedDuration` already sits on a clean segment boundary, so this
    /// is the exact playable window from the pause point for both small (`dvrPause`) and
    /// large-absolute (`dvrPausePlayback`) pause timestamps.
    static func behindLivePaused(bufferedDuration: Double,
                                 pauseTimestamp: Double,
                                 cappedAt: Double = .infinity) -> Double {
        min(max(0, bufferedDuration - pauseTimestamp), cappedAt)
    }

    /// Behind-live while DVR playback is running: the live recording head minus the
    /// current playback position (segment origin + position within the segment). Both
    /// advance ~1 s/s, so this stays roughly constant.
    static func behindLivePlaying(bufferedDuration: Double,
                                  currentSegNum: Int,
                                  segmentDuration: Double,
                                  positionSeconds: Double) -> Double {
        let currentRecordingTime = Double(currentSegNum) * segmentDuration + positionSeconds
        return max(0, bufferedDuration - currentRecordingTime)
    }

    // MARK: - Stale-Resume Decision

    /// What a play press should do when the buffer has been paused for a while.
    enum DVRResumeAction: Equatable {
        /// Normal path — play the buffered audio from the pause point.
        case resumeFromBuffer
        /// The buffer holds only a sliver relative to how long the user was away
        /// (recording froze); discard it and go straight back to live.
        case goLiveStale
    }

    /// Wall-clock/recording divergence beyond which a pause is a candidate for staleness.
    static let dvrStaleGapSeconds: Double = 120
    /// Fraction of wall time that must have been recorded for the buffer to count as healthy.
    static let dvrStaleRecordedRatio: Double = 0.5

    /// Decide whether a paused buffer is still worth resuming into.
    ///
    /// A backgrounded pause depends on the silence keepalive to stop iOS suspending the app;
    /// when that dies (an interruption the app never recovered from), the recording pump
    /// freezes and the buffer stops growing while wall time keeps running. Pressing play
    /// then yields a few seconds of audio followed by an end-of-buffer retry storm and a
    /// fall-through to live — the "confused" resume. Detecting it up front and going
    /// straight to live is strictly better.
    ///
    /// Staleness needs **both** conditions:
    /// - an absolute gap (`wall − recorded > 120 s`), so short pauses are never touched, and
    /// - a ratio miss (`recorded < 0.5 × wall`), so an overnight pause on a flaky network —
    ///   which loses chunks but still holds hours of valid audio — stays resumable.
    ///
    /// `bufferIsFull` overrides everything: a full ring stopped recording on purpose, so the
    /// gap is expected and the buffer is complete. Keep the existing offer/drain flow.
    /// Negative inputs (clock changes, an unset pause time) clamp to zero and read as healthy.
    static func dvrResumeAction(wallSecondsSincePause: Double,
                                recordedSecondsSincePause: Double,
                                bufferIsFull: Bool,
                                staleGapSeconds: Double = dvrStaleGapSeconds,
                                staleRecordedRatio: Double = dvrStaleRecordedRatio) -> DVRResumeAction {
        guard !bufferIsFull else { return .resumeFromBuffer }
        let wall     = max(0, wallSecondsSincePause)
        let recorded = max(0, recordedSecondsSincePause)
        let gapIsLarge   = wall - recorded > staleGapSeconds
        let recordedThin = recorded < staleRecordedRatio * wall
        return gapIsLarge && recordedThin ? .goLiveStale : .resumeFromBuffer
    }

    /// The ring-buffer segment index containing `pauseTimestamp` (floor via truncation;
    /// timestamps are non-negative). Guards a zero `segmentDuration` defensively — in
    /// practice it's a fixed 60 s and never zero.
    static func dvrSegmentIndex(pauseTimestamp: Double, segmentDuration: Double) -> Int {
        guard segmentDuration > 0 else { return 0 }
        return Int(pauseTimestamp / segmentDuration)
    }

    /// Recording-time start of the segment following `currentSegNum`.
    static func dvrNextSegmentTimestamp(currentSegNum: Int, segmentDuration: Double) -> Double {
        Double(currentSegNum + 1) * segmentDuration
    }

    /// Minimum data (s) that must exist in the next segment before it's safe to preload.
    /// Opening a near-empty segment file yields a stream that hits EOF within ms, causing
    /// rapid cycling that can starve the mixer into a false go-live.
    static let dvrPreloadMinLeadSeconds: Double = 2.0

    /// Whether the next DVR segment has accumulated enough data to preload gaplessly.
    static func shouldPreloadNextSegment(bufferedDuration: Double,
                                         nextSegmentTimestamp: Double,
                                         minLeadSeconds: Double = dvrPreloadMinLeadSeconds) -> Bool {
        bufferedDuration - nextSegmentTimestamp >= minLeadSeconds
    }
}
