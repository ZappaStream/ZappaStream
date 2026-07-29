import Foundation
import AVFoundation
#if os(macOS)
import Bass
import BassMix
#endif

// MARK: - DVR Ring Buffer Playback (macOS only)

/// Captures the recording-time origin of a DVR segment at sync registration time.
/// Passed as the BASS `user` pointer so the MIXTIME callback can compute `endedAt`
/// race-free — no shared mutable state from the audio thread.
private class DVREndSyncContext {
    weak var player: BASSRadioPlayer?
    let segOriginTime: Double   // recording seconds at the start of the segment file
    init(_ player: BASSRadioPlayer, segOriginTime: Double) {
        self.player = player
        self.segOriginTime = segOriginTime
    }
}

extension BASSRadioPlayer {

    // MARK: - DVR Public Interface

    /// The effective buffer window for the current session, in seconds.
    /// Reads the live StreamBuffer's actual maxSegments so the UI denominator always
    /// reflects what the session is truly using — important when a decrease has been deferred.
    var dvrMaxBufferSeconds: Double {
        Double(streamBuffer?.maxSegments ?? 0) * 60.0
    }

    /// Apply a changed buffer-window setting from Settings.
    /// - Live state: recreates StreamBuffer entirely.
    /// - Paused/playing state: applies the new value if it still covers everything already
    ///   recorded (both increases and safe decreases). Defers only if the new value would
    ///   be smaller than what the user has already saved in this session.
    func updateDVRBufferSize() {
        guard let buffer = streamBuffer else { return }
        let dvrMins = UserDefaults.standard.integer(forKey: "dvrBufferMinutes")
        let newMax  = dvrMins > 0 ? dvrMins : 15
        guard newMax != buffer.maxSegments else { return }

        switch BASSRadioPlayerLogic.dvrBufferResize(isLive: dvrState == .live,
                                                    newMaxSeconds: Double(newMax) * 60.0,
                                                    recordedSeconds: behindLiveSeconds) {
        case .recreate:
            buffer.stop()
            buffer.cleanup()
            streamBuffer = StreamBuffer(maxMinutes: newMax)
            streamBuffer?.start()
            #if DEBUG
            print("📼 DVR buffer resized to \(newMax) min (live)")
            #endif
        case .applyImmediately:
            // New window still covers everything already recorded.
            buffer.updateMaxSegments(newMax)
            #if DEBUG
            print("📼 DVR buffer adjusted to \(newMax) min (recorded=\(Int(behindLiveSeconds))s, safe)")
            #endif
        case .deferToGoLive:
            // New value would truncate content the user could still play back — defer to next go-live.
            #if DEBUG
            print("📼 DVR buffer decrease deferred (recorded \(Int(behindLiveSeconds / 60))min > new \(newMax)min)")
            #endif
        }
    }

    /// Pause live output while keeping the stream + recording alive.
    /// Saves the current recording timestamp so `dvrResume()` plays from here.
    func dvrPause() {
        guard dvrState == .live else { return }
        guard mixerHandle != 0, preMixerHandle != 0 else { return }

        dvrPauseTimestamp = streamBuffer?.currentTimestamp ?? 0
        dvrPauseBufferedAtPause = streamBuffer?.bufferedDuration ?? 0
        dvrState = .paused
        startBehindTimer()   // begin counting up how far behind live the user is

        // Register the pause segment as protected so the ring buffer stops cleanly before
        // overwriting it. When the ring fills, onBufferFull fires handleDVRBufferFull on main.
        if let buffer = streamBuffer {
            let segDur      = buffer.segmentDuration
            let maxSegs     = buffer.maxSegments
            let pauseSegIdx = Int(dvrPauseTimestamp / segDur) % maxSegs
            let maxSecs     = Double(maxSegs) * segDur
            buffer.setStopBeforeSegment(index: pauseSegIdx) { [weak self] in
                guard let self, self.dvrState == .paused else { return }
                self.handleDVRBufferFull(maxSecs: maxSecs)
            }
        }

        // Fade the live source channel vol to 0; the output mixer vol stays at 1.0.
        // This avoids BASS output-mixer buffer smoothing that caused a double fade-in
        // when the user paused and quickly resumed (mid-fade mixer vol + DVR stream
        // ch-vol fade = two simultaneous fade-ins on non-FLAC's old 0.5s single mixer).
        let liveSource = preMixerHandle
        startFadeOut(mixer: liveSource) { [weak self] in
            BASS_ChannelSetAttribute(liveSource, DWORD(BASS_ATTRIB_VOL), 0)
            guard let self else { return }
            // Pause the output mixer so CoreAudio stops producing audio output.
            // This causes iOS to recognise the paused state, fixing AirPods/lock screen.
            // The recording DSP on preMixerHandle only fires when something reads from it,
            // so we start a background pump that keeps pulling decoded audio into /dev/null
            // while the output mixer is paused, ensuring WAV segments keep being written.
            BASS_ChannelPause(self.mixerHandle)
            self.startDVRRecordingPump()
            // Keepalive (silent AVAudioPlayer) is NOT started here. In the foreground it would
            // make iOS see active audio output and route AirPods/lock screen to pauseCommand
            // (a no-op when already paused), breaking resume. It's only needed in the background
            // (foreground apps are never suspended by iOS); ContentView_iOS's scenePhase/dvrState
            // handlers request it, and startSilenceKeepalive() centrally suppresses it whenever
            // the app is in the foreground (guard on isAppInForeground).
        }
        #if DEBUG
        print("⏸️ DVR paused at t=\(String(format: "%.2f", dvrPauseTimestamp))s")
        logDVRDiag("pause")   // baseline snapshot at the moment of pause
        #endif
    }

    /// Pause DVR playback (while in .playing state).
    /// Saves the current playback position as the new pause point so dvrResume() picks up from here.
    func dvrPausePlayback() {
        guard dvrState == .playing, let buffer = streamBuffer else { return }

        let posBytes = BASS_ChannelGetPosition(dvrPlaybackStream, DWORD(BASS_POS_BYTE))
        let posSecs  = BASS_ChannelBytes2Seconds(dvrPlaybackStream, posBytes)
        let currentRecordingTime = Double(dvrCurrentSegNum) * buffer.segmentDuration + posSecs

        // Stash the live BASS handles in dvrPausedStreams so they stay active during
        // the fade-out (the mixer needs an audio source to fade). They are freed in the
        // fade completion callback, or by dvrResume()/goLive()/freeStream() if the user
        // acts before the fade finishes.
        dvrPausedStreams = [dvrPlaybackStream, dvrNextStream].filter { $0 != 0 }
        dvrPlaybackStream = 0
        dvrNextStream = 0
        dvrMetadataTimer?.invalidate()
        dvrMetadataTimer = nil

        dvrPauseTimestamp = currentRecordingTime
        dvrPauseBufferedAtPause = buffer.bufferedDuration
        dvrState = .paused   // prevents handleDVRStreamEndMixtime from advancing the segment
        startBehindTimer()

        // Protect the pause segment so the ring buffer stops before overwriting it —
        // same logic as dvrPause(). Without this the ring rolls freely and behindLiveSeconds
        // grows without bound. dvrResume() calls clearStopBeforeSegment() to lift protection.
        let segDur      = buffer.segmentDuration
        let maxSegs     = buffer.maxSegments
        let pauseSegIdx = Int(dvrPauseTimestamp / segDur) % maxSegs
        let maxSecs     = Double(maxSegs) * segDur
        buffer.setStopBeforeSegment(index: pauseSegIdx) { [weak self] in
            guard let self, self.dvrState == .paused else { return }
            self.handleDVRBufferFull(maxSecs: maxSecs)
        }

        // Fade out the mixer, then free the streams and zero the mixer in the completion.
        let ph = mixerHandle
        startFadeOut(mixer: ph) { [weak self] in
            guard let self else { return }
            for s in self.dvrPausedStreams {
                self.dvrSyncContexts.removeValue(forKey: s)
                BASS_StreamFree(s)
            }
            self.dvrPausedStreams.removeAll()
            BASS_ChannelSetAttribute(ph, DWORD(BASS_ATTRIB_VOL), 0)
            BASS_ChannelPause(ph)
            self.startDVRRecordingPump()
            // Keepalive deferred to background transition — see dvrPause() comment.
        }
        #if DEBUG
        print("⏸️ DVR playback paused at recording t=\(String(format: "%.2f", currentRecordingTime))s")
        #endif
    }

    /// Start DVR playback from the saved pause timestamp.
    /// The live stream stays muted and continues recording.
    func dvrResume() {
        guard dvrState == .paused, let buffer = streamBuffer else {
            #if DEBUG
            print("⚠️ dvrResume guard failed: dvrState=\(dvrState) hasBuffer=\(streamBuffer != nil)")
            #endif
            return
        }
        // Staleness gate. If recording froze while we were backgrounded (the keepalive died
        // and iOS suspended us), the buffer holds only a few seconds against hours of wall
        // clock. Playing that sliver gives ~5-10 s of audio, an end-of-buffer retry storm and
        // an eventual fall-through to live — so skip straight to live instead. Placed inside
        // dvrResume() so every entry point (remote commands, resumeOrOfferBuffer, both
        // ContentViews) is covered.
        let wallSincePause = dvrPauseWallTime == .distantPast
            ? 0 : Date().timeIntervalSince(dvrPauseWallTime)
        let recordedSincePause = max(0, buffer.bufferedDuration - dvrPauseBufferedAtPause)
        if BASSRadioPlayerLogic.dvrResumeAction(wallSecondsSincePause: wallSincePause,
                                                recordedSecondsSincePause: recordedSincePause,
                                                bufferIsFull: dvrBufferFull) == .goLiveStale {
            #if DEBUG
            print("⏱️ DVR resume: buffer is stale (wall=\(Int(wallSincePause))s recorded=\(Int(recordedSincePause))s) — going live")
            logDVRDiag("resume-stale")
            #endif
            // Full restart: after hours suspended the live BASS stream is dead, so the
            // fade-in path would produce silence rather than audio.
            goLive(forceFullRestart: true)
            return
        }

        let stream = buffer.createPlaybackStream(from: dvrPauseTimestamp)
        guard stream != 0 else {
            #if DEBUG
            print("❌ DVR: failed to create playback stream at t=\(dvrPauseTimestamp)")
            logDVRDiag("resume-failed")
            #endif
            // The buffer is unplayable. Returning here would leave the player latched in
            // .paused with no audio and no way out but another play press, so go live —
            // strictly better than a dead state.
            goLive()
            return
        }

        // Only now that a playable stream exists: mark the full-buffer episode as draining
        // (so a later mid-drain pause/resume won't re-prompt the play-vs-live choice) and
        // hand recording duty back over. Both must happen before the mixer is unpaused
        // below, so the pump and the mixer never pull from the pre-mixer at the same time.
        if dvrBufferFull { dvrFullBufferDrainStarted = true }
        stopDVRRecordingPump()
        #if os(iOS)
        stopSilenceKeepalive()   // real DVR audio takes over as the keepalive
        #endif

        dvrPlaybackStream = stream
        dvrCurrentSegNum  = BASSRadioPlayerLogic.dvrSegmentIndex(pauseTimestamp: dvrPauseTimestamp,
                                                                segmentDuration: buffer.segmentDuration)

        // Register gapless end-sync and pre-load the following segment.
        // segOriginTime is the recording-time start of the segment file — captured here
        // so the MIXTIME callback never needs to read dvrCurrentSegNum from the audio thread.
        let segOriginTime = Double(dvrCurrentSegNum) * buffer.segmentDuration
        registerDVREndSync(on: stream, segOriginTime: segOriginTime)
        preloadDVRNextSegment()

        // Now that playback is starting, lift the ring-buffer stop-before protection.
        // The protection was set at pause time to preserve the pause-point segment in case
        // the ring filled while the user was paused. Once playback is rolling, old segments
        // behind the playback head can be safely overwritten, so the ring should keep
        // rolling freely — this lets DVR stay behind live indefinitely rather than halting
        // after one full buffer's worth of content.
        // Do not clear for the buffer-full case: recording has already stopped and the user
        // is playing through a fixed snapshot of the ring.
        if !dvrBufferFull {
            buffer.clearStopBeforeSegment()
        }

        // Route DVR audio through the FX output mixer so EQ/compressor/stereo/limiter apply.
        // The recording DSP is on the pre-FX source (streamHandle/preMixerHandle), so it
        // continues capturing the live stream without picking up the DVR audio.
        // Silence the live source channel so only DVR audio is heard through the mixer.
        //
        // Free any streams that dvrPausePlayback() kept alive for its fade-out, in case
        // the user resumed before the fade completed (which cancels the completion callback).
        for s in dvrPausedStreams {
            dvrSyncContexts.removeValue(forKey: s)
            BASS_StreamFree(s)
        }
        dvrPausedStreams.removeAll()
        //
        // Cancel any in-progress fade, then silence the live source so it doesn't
        // bleed through when the mixer comes back up.
        cancelFade()
        let liveSource: DWORD = preMixerHandle != 0 ? preMixerHandle : streamHandle
        if liveSource != 0 {
            BASS_ChannelSetAttribute(liveSource, DWORD(BASS_ATTRIB_VOL), 0.0)
        }
        // Set stream vol to 0 before adding so no burst occurs if the mixer is already
        // active (e.g. unpaused by partialRestartLiveChannel between pause and resume).
        BASS_ChannelSetAttribute(stream, DWORD(BASS_ATTRIB_VOL), 0)
        BASS_Mixer_StreamAddChannel(mixerHandle, stream,
                                    DWORD(BASS_MIXER_CHAN_BUFFER | BASS_MIXER_CHAN_NORAMPIN))
        // Bring the stream to full vol now — the mixer output vol is the gate.
        BASS_ChannelSetAttribute(stream, DWORD(BASS_ATTRIB_VOL), 1.0)
        // Gate: set mixer output to 0 before unpausing. This blocks any audio from
        // reaching the speaker at the resume moment regardless of channel vol state —
        // stale BASS internal buffer content, BASS_MIXER_END replay, race-condition
        // renders, or any other unexpected source.
        BASS_ChannelSetAttribute(mixerHandle, DWORD(BASS_ATTRIB_VOL), 0)
        BASS_ChannelPlay(mixerHandle, 0)
        // Fade the mixer OUTPUT volume (the gate) from 0→1.
        startFadeInOnMainThread(mixer: mixerHandle)
        dvrState = .playing
        startBehindTimer()
        startDVRMetadataPolling()
        #if DEBUG
        print("▶️  DVR playback started from t=\(String(format: "%.2f", dvrPauseTimestamp))s")
        #endif
        #if DEBUG
        logDVRDiag("resume")   // state at the moment playback resumes — compare buffered vs the paused tick
        #endif
    }

    /// Exit DVR mode and return to the live stream immediately.
    /// The live stream is unmuted with a fade-in.
    ///
    /// - Parameter forceFullRestart: Discard the buffer and rebuild the live stream from
    ///   scratch instead of fading the existing one back in. Used by the stale-resume path,
    ///   where the live stream has been dead for hours and a fade-in would yield silence.
    func goLive(forceFullRestart: Bool = false) {
        guard dvrState != .live else { return }
        stopDVRRecordingPump()
        #if os(iOS)
        stopSilenceKeepalive()   // live stream resumes real audio output
        #endif

        // Stop DVR playback (freeing the stream auto-removes it from mixerHandle).
        if dvrPlaybackStream != 0 {
            dvrSyncContexts.removeValue(forKey: dvrPlaybackStream)
            BASS_StreamFree(dvrPlaybackStream)
            dvrPlaybackStream = 0
        }
        if dvrNextStream != 0 {
            dvrSyncContexts.removeValue(forKey: dvrNextStream)
            BASS_StreamFree(dvrNextStream)
            dvrNextStream = 0
        }
        // Free any streams kept alive for a dvrPausePlayback() fade-out that was cancelled.
        for s in dvrPausedStreams {
            dvrSyncContexts.removeValue(forKey: s)
            BASS_StreamFree(s)
        }
        dvrPausedStreams.removeAll()
        // Restore live source volume (was silenced when DVR playback started).
        let liveSource: DWORD = preMixerHandle != 0 ? preMixerHandle : streamHandle
        if liveSource != 0 {
            BASS_ChannelSetAttribute(liveSource, DWORD(BASS_ATTRIB_VOL), 1.0)
        }
        dvrBehindTimer?.invalidate()
        dvrBehindTimer = nil
        dvrMetadataTimer?.invalidate()
        dvrMetadataTimer = nil
        behindLiveSeconds = 0
        dvrState = .live
        lastPublishedTitle = nil
        lastIcecastTitle = nil
        lastDVRPublishedMetadata = nil

        // If the buffer filled (stream was paused to stop network activity), clean up the
        // WAV files and recreate StreamBuffer so DVR recording restarts immediately from live.
        let wasBufferFull = dvrBufferFull
        dvrReturnOfferPending = false
        dvrFullBufferDrainStarted = false
        if dvrBufferFull || forceFullRestart {
            dvrBufferFull = false
            streamBuffer?.stop()          // no-op if the ring already stopped itself
            streamBuffer?.cleanup()       // delete the preserved WAV segment files
            let dvrMins = UserDefaults.standard.integer(forKey: "dvrBufferMinutes")
            streamBuffer = StreamBuffer(maxMinutes: dvrMins > 0 ? dvrMins : 15)
            streamBuffer?.start()
        } else {
            // Lift the stop-before protection armed at pause time. Only dvrResume() used to
            // clear it, so pause → Go Live left the ring armed to stop cleanly the next time
            // it wrapped to that segment — recording would silently freeze later in the
            // session, long after the pause that caused it.
            streamBuffer?.clearStopBeforeSegment()
        }

        // FLAC always restarts from scratch. Non-FLAC also restarts when the live stream was
        // paused (buffer-full) or when the caller forced it (stale resume): the paused or
        // long-suspended channel has no usable download buffer, so a fresh connect is
        // identical to a normal play-from-stopped experience.
        if activeFormat == "FLAC" || wasBufferFull || forceFullRestart {
            bassPollingQueue.async { [weak self] in self?.restartStream() }
            #if DEBUG
            print("📡 DVR → LIVE (full restart)")
            #endif
            return
        }

        // Normal DVR unpause (stream was never paused): resume mixer then unmute with a fade-in.
        bassPollingQueue.async { [weak self] in self?.pollMetadata() }
        if mixerHandle != 0 { BASS_ChannelPlay(mixerHandle, 0) }
        if preMixerHandle != 0 {
            cancelFade()                       // cancel any DVR stream ch-vol fade; advance generation
            startFadeIn(mixer: preMixerHandle) // fade live source ch-vol from 0→1
        }
        #if DEBUG
        print("📡 DVR → LIVE")
        #endif
    }

    // MARK: - DVR Private Helpers

    /// Called when the recording ring buffer has been completely filled.
    /// Stops recording (flushing and closing segment files) but keeps the WAV files on disk
    /// indefinitely so the user can play back the full buffer whenever they choose — there is
    /// no expiry. The play-the-buffer-vs-go-live choice is offered when the user next presses
    /// play (see `resumeOrOfferBuffer()` in the ContentViews), not automatically.
    func handleDVRBufferFull(maxSecs: Double) {
        dvrBehindTimer?.invalidate()
        dvrBehindTimer = nil
        // Freeze at actual playable content from the pause point. StreamBuffer has already
        // adjusted totalSamplesWritten to a clean segment boundary (overshoot removed), so
        // bufferedDuration - dvrPauseTimestamp is the exact playable window from the pause
        // point. Using bufferedDuration (not maxSecs - dvrPauseTimestamp) is correct for
        // both dvrPause() (small timestamp, e.g. 9s) and dvrPausePlayback() (large
        // absolute timestamp, e.g. 1399s) where the old formula gave a negative result.
        behindLiveSeconds = BASSRadioPlayerLogic.behindLivePaused(
            bufferedDuration: streamBuffer?.bufferedDuration ?? 0,
            pauseTimestamp: dvrPauseTimestamp)
        dvrBufferFull = true
        streamBuffer?.stop()          // idempotent: StreamBuffer already stopped itself via stopBeforeSegmentIndex
        // Nothing is being recorded any more, so the pump has no purpose — it would just keep
        // draining the pre-mixer (and, with the dead-source detection above, eventually
        // "recover" a channel we deliberately pause below). The keepalive stays running: it is
        // what keeps the lock-screen play affordance alive so the user can accept the offer.
        stopDVRRecordingPump()
        // Stop metadata + state polling (includes FLAC health check) — no longer needed, and
        // with the download channel intentionally paused below the staleness watchdog could
        // only ever false-positive and trigger pointless restarts.
        stopMetadataPolling()
        // Pause the live download channel for all formats to stop network activity.
        // goLive() will do a full stream restart (restartStream()) when wasBufferFull is true.
        if streamHandle != 0 {
            BASS_ChannelPause(streamHandle)
        }
        // The buffer is preserved indefinitely — no expiry timer. The user is offered a
        // play-back-vs-go-live choice the next time they press play (resumeOrOfferBuffer()).
        #if DEBUG
        print("📼 DVR buffer full (\(Int(maxSecs / 60)) min) — recording stopped; buffer preserved until the user presses play")
        #endif
    }

    func startBehindTimer() {
        dvrBehindTimer?.invalidate()
        // Capture wall-clock snapshot so the .paused branch stays accurate even when the
        // app is backgrounded and iOS suspends the audio session (freezing bufferedDuration).
        dvrPauseWallTime = Date()
        dvrPauseOffset   = behindLiveSeconds
        // Fires on the main runloop so UI updates happen on the main thread.
        // Runs in both .paused (counts up as time elapses) and .playing (stays static).
        dvrBehindTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self = self,
                  let buffer = self.streamBuffer,
                  self.dvrState != .live else { return }

            switch self.dvrState {
            case .paused:
                // Show actual playable content from the pause point — not an optimistic
                // wall-clock guess. If background recording was suspended, this reflects the
                // smaller real buffer and matches what dvrResume()/.playing shows, so there is
                // no jump when the user presses play. Same measure as handleDVRBufferFull and
                // the .playing branch below. Capped at the buffer max as a safety bound.
                self.behindLiveSeconds = BASSRadioPlayerLogic.behindLivePaused(
                    bufferedDuration: buffer.bufferedDuration,
                    pauseTimestamp: self.dvrPauseTimestamp,
                    cappedAt: self.dvrMaxBufferSeconds)
                #if DEBUG
                // Snapshot roughly every 30 s; the timer fires ~1/s. While foregrounded `buffered`
                // should climb in step; the moment it flatlines marks where recording stopped.
                if Int(Date().timeIntervalSince(self.dvrPauseWallTime)) % 30 == 0 {
                    self.logDVRDiag("paused-tick")
                }
                #endif
            case .playing where self.dvrPlaybackStream != 0:
                // While playing, behind = live recording head minus DVR playback position.
                // Both advance at ~1 s/s, so this value stays roughly constant.
                let posBytes = BASS_ChannelGetPosition(self.dvrPlaybackStream, DWORD(BASS_POS_BYTE))
                let posSecs  = BASS_ChannelBytes2Seconds(self.dvrPlaybackStream, posBytes)
                self.behindLiveSeconds = BASSRadioPlayerLogic.behindLivePlaying(
                    bufferedDuration: buffer.bufferedDuration,
                    currentSegNum: self.dvrCurrentSegNum,
                    segmentDuration: buffer.segmentDuration,
                    positionSeconds: posSecs)

                // If the next segment wasn't available at resume time, retry now.
                // Once it's been recorded, preload it so the upcoming transition is gapless.
                if self.dvrNextStream == 0 { self.preloadDVRNextSegment() }
            default:
                break
            }
        }
    }

    /// Register a MIXTIME END sync on a DVR playback stream.
    /// BASS_SYNC_MIXTIME fires in the mixing thread at the exact sample boundary,
    /// enabling gapless segment transitions via handleDVRStreamEndMixtime.
    ///
    /// `segOriginTime` is the recording-time offset (seconds) at the start of `stream`'s
    /// segment file. It is captured in a DVREndSyncContext so the MIXTIME callback can
    /// compute `endedAt` without touching `dvrCurrentSegNum` — which is written on the
    /// main thread and would otherwise be a data race.
    func registerDVREndSync(on stream: DWORD, segOriginTime: Double) {
        let ctx = DVREndSyncContext(self, segOriginTime: segOriginTime)
        dvrSyncContexts[stream] = ctx
        let userData = Unmanaged.passUnretained(ctx).toOpaque()
        BASS_ChannelSetSync(stream, DWORD(BASS_SYNC_END | BASS_SYNC_MIXTIME), 0, { _, ch, _, user in
            guard let user = user else { return }
            let ctx = Unmanaged<DVREndSyncContext>.fromOpaque(user).takeUnretainedValue()
            ctx.player?.handleDVRStreamEndMixtime(oldStream: ch, segOriginTime: ctx.segOriginTime)
        }, userData)
    }

    /// Pre-create the stream for segment (dvrCurrentSegNum + 1) so it is ready to add
    /// to the mixer instantly when the current segment ends.  Must be called on main thread.
    func preloadDVRNextSegment() {
        if dvrNextStream != 0 {
            BASS_StreamFree(dvrNextStream)
            dvrNextStream = 0
        }
        guard let buffer = streamBuffer else { return }
        let nextSeg = dvrCurrentSegNum + 1
        let nextTs  = BASSRadioPlayerLogic.dvrNextSegmentTimestamp(currentSegNum: dvrCurrentSegNum,
                                                                  segmentDuration: buffer.segmentDuration)
        // Require at least 2 s of data in the next segment before preloading.
        // Opening a near-empty file produces a stream that fires EOF in milliseconds,
        // which causes rapid cycling and can starve the mixer — leading to a false go-live.
        guard BASSRadioPlayerLogic.shouldPreloadNextSegment(bufferedDuration: buffer.bufferedDuration,
                                                           nextSegmentTimestamp: nextTs) else { return }
        let s = buffer.createPlaybackStream(from: nextTs)
        if s != 0 {
            dvrNextStream = s
            dvrNextSegNum = nextSeg
        }
    }

    /// Called from the BASS mixing thread (MIXTIME sync) when a DVR segment stream hits EOF.
    /// Adds the pre-loaded next segment to the mixer at the exact sample boundary (no gap),
    /// then dispatches state cleanup and next-segment pre-loading to the main thread.
    ///
    /// `segOriginTime` is captured race-free from the DVREndSyncContext at registration time
    /// and represents the recording-time start of `oldStream`'s segment file. It must NOT
    /// read `dvrCurrentSegNum` here — that property is written on the main thread and reading
    /// it from the BASS audio thread is a data race.
    func handleDVRStreamEndMixtime(oldStream: DWORD, segOriginTime: Double) {
        guard dvrState == .playing else { return }

        // Only capture dvrNextStream on the audio thread — it must be added to the mixer
        // here, at the exact sample boundary, for gapless playback.
        // dvrNextSegNum is intentionally NOT read here: it is written on the main thread
        // and reading it from the BASS audio thread is a data race that can produce stale
        // segment numbers, corrupting dvrCurrentSegNum and causing premature go-live.
        let nextStream = dvrNextStream

        // Compute the exact recording-time position where this stream ended.
        // segOriginTime was captured at registerDVREndSync() call time — race-free.
        let endPosBytes = BASS_ChannelGetPosition(oldStream, DWORD(BASS_POS_BYTE))
        let endPosSecs  = BASS_ChannelBytes2Seconds(oldStream, endPosBytes)
        let endedAt     = segOriginTime + endPosSecs

        if nextStream != 0 {
            // Sample-accurate: add next stream NOW, in the mixing thread.
            // BASS_Mixer_StreamAddChannel is safe to call from MIXTIME callbacks.
            BASS_Mixer_StreamAddChannel(mixerHandle, nextStream,
                                        DWORD(BASS_MIXER_CHAN_BUFFER | BASS_MIXER_CHAN_NORAMPIN))
        }
        // Always restart the mixer here — whether or not a next stream was ready.
        // If nextStream == 0, the main thread will run continueDVRFrom; the mixer must stay
        // alive during that window so preMixerHandle keeps being processed and the recording
        // DSP keeps firing (preventing bufferedDuration from freezing during retries).
        // BASS_ChannelPlay is a no-op when the channel is already playing.
        BASS_ChannelPlay(mixerHandle, 0)

        // Non-time-critical cleanup and pre-loading on main thread.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.dvrState == .playing else {
                // Cancelled during the async hop — free the pre-loaded stream if unused.
                if nextStream != 0 { BASS_StreamFree(nextStream) }
                return
            }

            // Read dvrNextSegNum here on the main thread — race-free. At this point
            // it holds the value written by the most recent preloadDVRNextSegment() call.
            let nextSegNum = self.dvrNextSegNum

            // Remove the old stream's context before freeing — prevents dangling dict entries.
            self.dvrSyncContexts.removeValue(forKey: oldStream)
            BASS_StreamFree(oldStream)

            if nextStream != 0 {
                // Normal path: pre-loaded stream was added to mixer in MIXTIME callback.
                self.dvrPlaybackStream = nextStream
                self.dvrCurrentSegNum  = nextSegNum
                self.dvrNextStream     = 0
                let nextOrigin = Double(nextSegNum) * (self.streamBuffer?.segmentDuration ?? 60.0)
                self.registerDVREndSync(on: nextStream, segOriginTime: nextOrigin)
                self.preloadDVRNextSegment()
                #if DEBUG
                print("⏭️  DVR → segment \(nextSegNum)")
                #endif
            } else {
                // Fallback: preload was skipped or the preloaded segment had only partial data.
                // Continue from endedAt (the exact recording time where playback stopped) rather
                // than jumping to the next segment boundary. This keeps DVR alive indefinitely:
                // each re-open seeks past the already-played portion, so the user stays behind
                // live by a constant amount as long as bufferedDuration keeps growing.
                self.continueDVRFrom(recordingTime: endedAt)
            }
        }
    }

    /// Continue DVR playback from `recordingTime` seconds into the recording.
    /// Creates a new BASS file stream seeked to the right offset and adds it to the mixer.
    ///
    /// When DVR is at the live edge (close to the recording head) this retries with
    /// exponential backoff instead of immediately going live. This keeps the user
    /// indefinitely behind live as long as the ring buffer keeps accumulating new data.
    /// Goes live only after exhausting retries, which means recording genuinely stopped.
    private func continueDVRFrom(recordingTime: Double, retryCount: Int = 0) {
        guard dvrState == .playing, let buffer = streamBuffer else { return }

        // If we are at or ahead of the recording head, wait for more data before retrying.
        // This handles the live-edge case: DVR is close to live but should stay behind
        // indefinitely. Retry with increasing delays; give up and go live after ~10 s total.
        if recordingTime >= buffer.bufferedDuration - 0.5 {
            guard retryCount < 15 else {
                #if DEBUG
                print("📡 DVR end-of-buffer reached — going live")
                #endif
                goLive()
                return
            }
            // Keep the output mixer running while we wait for more data.
            // If BASS_MIXER_END stopped the mixer (because the DVR stream ended and
            // preMixerHandle briefly had no audio), recording would freeze and
            // bufferedDuration would stop growing — causing all 15 retries to fail.
            // BASS_ChannelPlay is a no-op if the mixer is already playing.
            if mixerHandle != 0 { BASS_ChannelPlay(mixerHandle, 0) }
            // Short waits first (100–200 ms), then 500 ms, so we catch up quickly when
            // only a tiny amount of new data is needed to resume seamlessly.
            let delay: TimeInterval = retryCount < 5 ? 0.2 : 0.5
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.continueDVRFrom(recordingTime: recordingTime, retryCount: retryCount + 1)
            }
            return
        }

        let stream = buffer.createPlaybackStream(from: recordingTime)
        if stream != 0 {
            BASS_Mixer_StreamAddChannel(mixerHandle, stream,
                                        DWORD(BASS_MIXER_CHAN_BUFFER | BASS_MIXER_CHAN_NORAMPIN))
            // Restart the mixer if BASS_MIXER_END stopped it while no DVR source was active.
            BASS_ChannelPlay(mixerHandle, 0)
            dvrPlaybackStream = stream
            dvrCurrentSegNum  = Int(recordingTime / buffer.segmentDuration)
            dvrNextStream     = 0
            let segOriginTime = Double(dvrCurrentSegNum) * buffer.segmentDuration
            registerDVREndSync(on: stream, segOriginTime: segOriginTime)
            preloadDVRNextSegment()
            #if DEBUG
            print("⏭️  DVR continue from t=\(String(format: "%.1f", recordingTime))s (seg \(dvrCurrentSegNum))")
            #endif
        } else if retryCount < 3 {
            // Segment file may be transiently absent while the ring buffer rotates
            // (removeItem + createFile window). Retry up to 3 times with 100 ms gaps.
            #if DEBUG
            print("⚠️  DVR segment not ready at t=\(String(format: "%.1f", recordingTime))s — retrying (\(retryCount + 1))")
            #endif
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                self?.continueDVRFrom(recordingTime: recordingTime, retryCount: retryCount + 1)
            }
        } else {
            #if DEBUG
            print("📡 DVR end-of-buffer reached — going live")
            #endif
            goLive()
        }
    }

    /// Rebuild only the live BASS stream + pre-mixer while keeping DVR state intact.
    /// Called when the live stream dies (STOPPED or buffer underrun) during DVR pause/playback.
    /// The existing StreamBuffer keeps running, so WAV segments continue to grow and DVR
    /// playback is unaffected. The new live stream starts muted.
    ///
    /// mixerHandle is preserved so the DVR playback stream stays attached throughout —
    /// no audio dropout occurs during the reconnect.
    func partialRestartLiveChannel() {
        guard activeFormat != "FLAC" else {
            // FLAC two-mixer setup is too complex for a partial restart; go live as a fallback.
            DispatchQueue.main.async { self.goLive() }
            bassPollingQueue.async { self.restartStream() }
            return
        }
        guard let current = qualities.first(where: { $0.format == activeFormat }),
              let cURL = current.url.cString(using: .utf8) else { return }

        #if DEBUG
        print("🔄 DVR partial restart: rebuilding \(current.format) live channel (DVR state preserved)")
        #endif

        cancelFade()
        stopMetadataPolling()   // also stops state polling timer
        oggStopConfirmed = false

        // Strip FX and DSPs from mixerHandle individually rather than freeing it.
        // Freeing mixerHandle removes the DVR playback stream from the output pipeline,
        // causing an audio dropout while the new pipeline is constructed.
        if eqLowFX       != 0 { BASS_ChannelRemoveFX(mixerHandle, eqLowFX);        eqLowFX       = 0 }
        if eqMidFX       != 0 { BASS_ChannelRemoveFX(mixerHandle, eqMidFX);        eqMidFX       = 0 }
        if eqHighFX      != 0 { BASS_ChannelRemoveFX(mixerHandle, eqHighFX);       eqHighFX      = 0 }
        if compressorFX  != 0 { BASS_ChannelRemoveFX(mixerHandle, compressorFX);   compressorFX  = 0 }
        if inputGainDSP  != 0 { BASS_ChannelRemoveDSP(mixerHandle, inputGainDSP);  inputGainDSP  = 0 }
        if levelMeterDSP != 0 { BASS_ChannelRemoveDSP(mixerHandle, levelMeterDSP); levelMeterDSP = 0 }
        if stereoDSP     != 0 { BASS_ChannelRemoveDSP(mixerHandle, stereoDSP);     stereoDSP     = 0 }
        if limiterDSP    != 0 { BASS_ChannelRemoveDSP(mixerHandle, limiterDSP);    limiterDSP    = 0 }
        // Must remove subBassDSP too: applyEffects (via configureStreamAttributes below)
        // re-adds it to mixerHandle. Without this removal the old sub-bass DSP stays
        // attached and a second one stacks on top — two octave-down generators sharing
        // the same filter-state vars corrupt each other, producing granular/broken audio.
        if subBassDSP    != 0 { BASS_ChannelRemoveDSP(mixerHandle, subBassDSP);    subBassDSP    = 0 }

        // Free the live source layers only. BASS_ChannelFree on preMixerHandle auto-removes
        // it from mixerHandle and removes its clickGuardDSP and recordingDSP.
        if preMixerHandle != 0 { BASS_ChannelFree(preMixerHandle); preMixerHandle = 0 }
        if streamHandle   != 0 { BASS_StreamFree(streamHandle);    streamHandle   = 0 }
        stallSync = 0; endSync = 0; oggChangeSync = 0
        recordingDSP = 0; clickGuardDSP = 0; cgFadeBuffersRemaining = 0
        // Re-baseline the decode-position staleness tracker (mirrors freeStream()). The new
        // stream starts at position 0, so without this the checkStreamStatus staleness check
        // would see bytes <= old lastKnownStreamBytes and re-fire immediately, looping restarts.
        lastKnownStreamBytes = 0
        lastPositionAdvanceTime = 0

        // Reconnect live stream.
        let streamFlags = DWORD(BASS_STREAM_STATUS) | DWORD(BASS_SAMPLE_FLOAT) | DWORD(BASS_STREAM_DECODE)
        let newHandle = BASS_StreamCreateURL(cURL, 0, streamFlags, nil, nil)
        guard newHandle != 0 else {
            let err = BASS_ErrorGetCode()
            #if DEBUG
            print("❌ DVR partial restart: BASS_StreamCreateURL failed (err=\(err)) — scheduling reconnect")
            #endif
            scheduleReconnect()
            return
        }
        reconnectAttempt = 0
        DispatchQueue.main.async { self.isReconnecting = false }

        streamHandle = newHandle
        preMixerHandle = BASS_Mixer_StreamCreate(BASSConfig.sampleRate, BASSConfig.channels,
            DWORD(BASS_MIXER_END) | DWORD(BASS_SAMPLE_FLOAT) | DWORD(BASS_STREAM_DECODE))
        // Bail if the new pre-mixer failed to build; otherwise the relinked live
        // source would be silently dead. Fail loudly into the reconnect path.
        guard preMixerHandle != 0 else {
            let err = BASS_ErrorGetCode()
            #if DEBUG
            print("❌ DVR partial restart: pre-mixer creation failed (err=\(err)) — scheduling reconnect")
            #endif
            scheduleReconnect()
            return
        }
        BASS_Mixer_StreamAddChannel(preMixerHandle, streamHandle,
            DWORD(BASS_MIXER_CHAN_BUFFER) | DWORD(BASS_MIXER_CHAN_NORAMPIN))

        // Wire new pre-mixer into the existing output mixer — no mixer recreation needed.
        // The DVR playback stream has been in mixerHandle the entire time.
        BASS_Mixer_StreamAddChannel(mixerHandle, preMixerHandle,
            DWORD(BASS_MIXER_CHAN_BUFFER))

        // Re-apply FX/DSPs to mixerHandle and recording DSP to preMixerHandle.
        // self.streamBuffer is still alive, so recording continues without interruption.
        configureStreamAttributes(format: current.format, handle: streamHandle)
        setupSyncs(for: streamHandle)

        // Mute the live source — DVR state controls when it unmutes.
        // mixerHandle vol is unchanged at 1.0; DVR stream has been playing through it.
        BASS_ChannelSetAttribute(preMixerHandle, DWORD(BASS_ATTRIB_VOL), 0)

        // DVR playback stream is still in mixerHandle — no re-attachment needed.
        // Only restart the mixer if it should be active. In DVR paused state the
        // mixer was intentionally paused by dvrPause(); unpausing it here causes
        // BASS_MIXER_END to fire when the new stream's download buffer is briefly
        // empty, stopping the mixer and halting the recording pump.
        if dvrState != .paused {
            BASS_ChannelPlay(mixerHandle, 0)
        }

        DispatchQueue.main.async {
            self.playbackState = .playing
            self.startMetadataPolling()
        }
        #if DEBUG
        print("✅ DVR partial restart complete (gapless) — dvrState=\(dvrState) seg=\(dvrCurrentSegNum)")
        #endif
    }

    // MARK: - DVR Metadata Playback

    /// Consult the journal for the current DVR playback position and fire `onMetadataUpdate`
    /// if the track has changed. Called on the main thread.
    func publishDVRMetadata() {
        guard dvrState == .playing, let buffer = streamBuffer, dvrPlaybackStream != 0 else { return }

        let posBytes = BASS_ChannelGetPosition(dvrPlaybackStream, DWORD(BASS_POS_BYTE))
        let posSecs  = BASS_ChannelBytes2Seconds(dvrPlaybackStream, posBytes)
        let currentRecordingTime = Double(dvrCurrentSegNum) * buffer.segmentDuration + posSecs

        // Find the latest journal entry at or before the current playback position.
        guard let entry = dvrMetadataJournal.last(where: { $0.timestamp <= currentRecordingTime }),
              entry.metadata != lastDVRPublishedMetadata else { return }

        lastDVRPublishedMetadata = entry.metadata
        #if DEBUG
        print("📼 DVR metadata @ t=\(String(format: "%.1f", currentRecordingTime))s → \(entry.metadata)")
        #endif
        onMetadataUpdate?(entry.metadata)
    }

    // MARK: - Recording Pump (keeps WAV recording alive while output mixer is paused)

    /// Starts a background timer that reads from the decode-only pre-mixer (~100ms/tick).
    /// The output mixer is paused during DVR pause so iOS sees no audio output (AirPods
    /// and lock screen correctly show a play button). Without this pump, the recording DSP
    /// on preMixerHandle would stop firing and WAV segments would have gaps.
    func startDVRRecordingPump() {
        stopDVRRecordingPump()
        guard preMixerHandle != 0 else { return }
        dvrPumpTickCount = 0
        dvrPumpDeadTickCount = 0
        #if DEBUG
        dvrPumpLastTick = Date()
        #endif
        let src = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .userInitiated))
        src.schedule(deadline: .now() + 0.1, repeating: .milliseconds(100), leeway: .milliseconds(10))
        src.setEventHandler { [weak self] in
            guard let self, self.preMixerHandle != 0 else { return }
            #if DEBUG
            // Pump-gap detection: the timer fires every 100 ms while the app runs. A gap far
            // larger than that means the app was suspended (iOS froze the DispatchSource), which
            // also froze the recording DSP — the smoking gun for DVR background-recording loss.
            let now = Date()
            let gap = now.timeIntervalSince(self.dvrPumpLastTick)
            if gap > 1.0 {
                print("⚠️ DVR pump gap of \(String(format: "%.1f", gap))s after \(self.dvrPumpTickCount) ticks (app likely suspended)")
            }
            self.dvrPumpLastTick = now
            #endif
            self.dvrPumpTickCount += 1
            self.dvrRecordingPumpBuf.withUnsafeMutableBytes { ptr in
                _ = BASS_ChannelGetData(self.preMixerHandle, ptr.baseAddress!, DWORD(ptr.count))
            }

            // Dead-source detection. The pre-mixer carries BASS_MIXER_END, so it stops for good
            // once the live download buffer runs dry (tunnel, Airplane Mode, dropped server).
            // The pump then happily pulls nothing forever and the buffer stops growing with no
            // other symptom. After ~1 s of consecutive STOPPED ticks, rebuild the live channel:
            // partialRestartLiveChannel() preserves the DVR state and leaves the output mixer
            // paused while we're .paused. Throttled to one attempt per 15 s so a genuinely
            // offline device doesn't spin. preMixerHandle is re-read each tick, so the rebuilt
            // handle is picked up automatically.
            //
            // Not for FLAC: partialRestartLiveChannel() can't rebuild the FLAC two-mixer
            // pipeline in place and falls back to goLive() + a full restart, which would
            // cancel the user's pause and start playing audio out loud — a nasty surprise
            // from a backgrounded device. FLAC's dead-source case is still covered by
            // checkStreamStatus while polling runs, and by the stale-resume gate on the
            // next play press.
            if BASS_ChannelIsActive(self.preMixerHandle) == DWORD(BASS_ACTIVE_STOPPED) {
                self.dvrPumpDeadTickCount += 1
            } else {
                self.dvrPumpDeadTickCount = 0
            }
            if self.dvrPumpDeadTickCount >= 10, !self.isReconnecting, self.activeFormat != "FLAC" {
                let now = ProcessInfo.processInfo.systemUptime
                if now - self.dvrPumpLastRecoveryAttempt >= 15 {
                    self.dvrPumpLastRecoveryAttempt = now
                    self.dvrPumpDeadTickCount = 0
                    #if DEBUG
                    print("⚠️ DVR pump: pre-mixer STOPPED — partial restart of the live channel")
                    #endif
                    self.bassPollingQueue.async { [weak self] in self?.partialRestartLiveChannel() }
                }
            }
            #if os(iOS)
            // Keepalive health check, every ~10 s. An AVAudioPlayer can be stopped by the
            // system without any notification we observe, and a dead keepalive means iOS
            // suspends the app and freezes this very pump. Costs one main-queue hop per 10 s.
            if self.dvrPumpTickCount % 100 == 0 {
                DispatchQueue.main.async { [weak self] in
                    self?.rearmSilenceKeepaliveIfNeeded()
                }
            }
            #endif
        }
        src.resume()
        dvrRecordingPumpSource = src
        #if DEBUG
        print("🎙️ DVR recording pump started")
        #endif
    }

    func stopDVRRecordingPump() {
        guard dvrRecordingPumpSource != nil else { return }
        dvrRecordingPumpSource?.cancel()
        dvrRecordingPumpSource = nil
        #if DEBUG
        print("🎙️ DVR recording pump stopped")
        #endif
    }

    // MARK: - DVR Diagnostics (DEBUG only)

    /// Print a one-line snapshot of all DVR/keepalive/stream state relevant to the
    /// background-recording investigation. Compile out entirely in release builds.
    ///
    /// Reading the output: the `→background`/`→foreground` pair brackets the suspended window —
    /// compare `buffered` and wall time across them. While paused-and-foregrounded `buffered`
    /// should climb ~1 s per second; the moment it flatlines is where recording stopped.
    /// `fg` shows `isAppInForeground` — `keepalive=nil` is EXPECTED while `fg=true` (it is
    /// suppressed in the foreground by design); only `fg=false` with the keepalive not playing
    /// signals a real background-suspension risk.
    func logDVRDiag(_ tag: String) {
        #if DEBUG
        let buffered = streamBuffer?.bufferedDuration ?? 0
        let recorded = max(0, buffered - dvrPauseTimestamp)
        let wallElapsed = dvrPauseWallTime == .distantPast ? 0 : Date().timeIntervalSince(dvrPauseWallTime)
        let streamActive = streamHandle != 0 ? BASS_ChannelIsActive(streamHandle) : DWORD(BASS_ACTIVE_STOPPED)
        let mixerActive  = mixerHandle  != 0 ? BASS_ChannelIsActive(mixerHandle)  : DWORD(BASS_ACTIVE_STOPPED)
        let dlBuf  = streamHandle != 0 ? BASS_StreamGetFilePosition(streamHandle, DWORD(BASS_FILEPOS_BUFFER))   : 0
        let dlTot  = streamHandle != 0 ? BASS_StreamGetFilePosition(streamHandle, DWORD(BASS_FILEPOS_DOWNLOAD)) : 0

        var line = "📊 DVR[\(tag)] state=\(dvrState) buffered=\(String(format: "%.1f", buffered))s"
            + " pauseTs=\(String(format: "%.1f", dvrPauseTimestamp))s recorded=\(String(format: "%.1f", recorded))s"
            + " wallElapsed=\(String(format: "%.1f", wallElapsed))s behind=\(String(format: "%.1f", behindLiveSeconds))s"
            + " streamActive=\(streamActive) mixerActive=\(mixerActive) dlBuf=\(dlBuf) dlTot=\(dlTot)"

        #if os(iOS)
        let kaPlaying = silenceKeepalivePlayer?.isPlaying ?? false
        let session = AVAudioSession.sharedInstance()
        line += " fg=\(isAppInForeground) keepalive=\(silenceKeepalivePlayer == nil ? "nil" : (kaPlaying ? "playing" : "stopped"))"
            + " avCat=\(session.category.rawValue) otherAudio=\(session.isOtherAudioPlaying)"
        #endif

        print(line)
        #endif
    }

    /// Start polling the metadata journal for DVR playback position every 3 s.
    /// Fires once immediately so the UI updates without waiting for the first tick.
    func startDVRMetadataPolling() {
        dvrMetadataTimer?.invalidate()
        publishDVRMetadata()   // immediate update on resume
        dvrMetadataTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            guard let self = self, self.dvrState == .playing else { return }
            self.publishDVRMetadata()
        }
    }
}
