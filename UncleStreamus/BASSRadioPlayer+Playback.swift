import Foundation
import Network
#if os(macOS)
import Bass
import BassFLAC
import BassFX
import BassMix
#elseif os(iOS)
import UIKit
import AVFoundation
#endif

// MARK: - Stream Lifecycle, Network Resilience & Fade

extension BASSRadioPlayer {

    // MARK: - Stream Creation

    func switchQuality(_ format: String) {
        guard let entry = qualities.first(where: { $0.format == format }) else { return }
        initBASS()  // no-op after first call; runs BASS_Init against the already-configured audio session
        isUserIntendedPlay = true
        cancelReconnectTimer()
        reconnectAttempt = 0
        DispatchQueue.main.async { self.isReconnecting = false }
        // A format change ends any open AAC carry-over window.
        aacCarryoverActive = false
        aacCarryoverFXAdjusted = false
        #if DEBUG
        print("\n🔊 ── SWITCHING TO \(format) ──────────────────────────")
        print("   URL: \(entry.url)")
        #endif

        freeStream()

        guard let cURL = entry.url.cString(using: .utf8) else { return }

        // FLAC needs a larger download pre-buffer due to ~900kbps bitrate
        if format == "FLAC" {
            BASS_SetConfig(DWORD(BASS_CONFIG_NET_BUFFER), BASSConfig.netBufferMsFLAC)
            BASS_SetConfig(DWORD(BASS_CONFIG_NET_PREBUF), 50)
        }

        let streamFlags = DWORD(BASS_STREAM_STATUS) | DWORD(BASS_SAMPLE_FLOAT) | DWORD(BASS_STREAM_DECODE)
        streamHandle = BASS_StreamCreateURL(cURL, 0, streamFlags, nil, nil)

        if format == "FLAC" {
            BASS_SetConfig(DWORD(BASS_CONFIG_NET_BUFFER), BASSConfig.netBufferMs)
            BASS_SetConfig(DWORD(BASS_CONFIG_NET_PREBUF), 50)
        }

        if streamHandle == 0 {
            let err = BASS_ErrorGetCode()
            #if DEBUG
            print("❌  Stream creation failed (error \(err)) — scheduling reconnect")
            #endif
            scheduleReconnect()
            return
        }

        if format == "FLAC" {
            // Two-mixer pipeline: DECODE-mode pre-mixer (3.0s stutter buffer + click guard)
            // feeds into the output post-mixer (0.1s FX latency). All DSP/FX live on the post-mixer.
            preMixerHandle = BASS_Mixer_StreamCreate(BASSConfig.sampleRate, BASSConfig.channels,
                DWORD(BASS_MIXER_END) | DWORD(BASS_SAMPLE_FLOAT) | DWORD(BASS_STREAM_DECODE))
            BASS_Mixer_StreamAddChannel(preMixerHandle, streamHandle,
                DWORD(BASS_MIXER_CHAN_BUFFER) | DWORD(BASS_MIXER_CHAN_NORAMPIN))
            mixerHandle = BASS_Mixer_StreamCreate(BASSConfig.sampleRate, BASSConfig.channels,
                DWORD(BASS_MIXER_END) | DWORD(BASS_SAMPLE_FLOAT))
            BASS_Mixer_StreamAddChannel(mixerHandle, preMixerHandle,
                DWORD(BASS_MIXER_CHAN_BUFFER))
        } else {
            // Two-mixer pipeline for all formats: stream → DECODE-mode pre-mixer (0.3s buffer)
            // → FX output mixer (0.1s buffer). Uniform with FLAC; enables channel-vol fading
            // for DVR pause/resume without BASS output-mixer vol unreliability.
            preMixerHandle = BASS_Mixer_StreamCreate(BASSConfig.sampleRate, BASSConfig.channels,
                DWORD(BASS_MIXER_END) | DWORD(BASS_SAMPLE_FLOAT) | DWORD(BASS_STREAM_DECODE))
            BASS_Mixer_StreamAddChannel(preMixerHandle, streamHandle,
                DWORD(BASS_MIXER_CHAN_BUFFER) | DWORD(BASS_MIXER_CHAN_NORAMPIN))
            mixerHandle = BASS_Mixer_StreamCreate(BASSConfig.sampleRate, BASSConfig.channels,
                DWORD(BASS_MIXER_END) | DWORD(BASS_SAMPLE_FLOAT))
            BASS_Mixer_StreamAddChannel(mixerHandle, preMixerHandle,
                DWORD(BASS_MIXER_CHAN_BUFFER))
        }

        // Bail if the mixer pipeline failed to build (e.g. resource exhaustion):
        // proceeding would leave the stream silently never playing. Fail loudly into
        // the existing reconnect path, matching the BASS_StreamCreateURL check above.
        guard preMixerHandle != 0, mixerHandle != 0 else {
            let err = BASS_ErrorGetCode()
            #if DEBUG
            print("❌  Mixer pipeline creation failed (error \(err)) — scheduling reconnect")
            #endif
            scheduleReconnect()
            return
        }

        activeFormat = format

        // Start DVR recording before attaching DSPs so no audio is missed.
        let dvrMins = UserDefaults.standard.integer(forKey: "dvrBufferMinutes")
        streamBuffer = StreamBuffer(maxMinutes: dvrMins > 0 ? dvrMins : 15)
        streamBuffer?.start()

        configureStreamAttributes(format: format, handle: streamHandle)
        setupSyncs(for: streamHandle)

        let ph = playbackHandle
        DispatchQueue.main.async {
            self.currentQuality = format
            self.isPlaying = true
            self.playbackState = .connecting
        }

        if format == "FLAC" {
            // Delay mixer start by 10s so the download ring buffer fills with compressed data.
            // BASS_StreamCreateURL returns quickly (async); during the wait the server sends
            // ~1.125 MB of FLAC (~10s × 900 kbps/8), giving the pre-mixer a larger ring buffer
            // reserve at startup. Metadata polling starts after the mixer plays — avoids false
            // STOPPED detection. preBufferProgress drives the UI loading bar (0→1 over 10s).
            BASS_ChannelSetAttribute(ph, DWORD(BASS_ATTRIB_VOL), 0)
            flacPendingFadeIn = true
            let capturedPH = ph
            let capturedSH = streamHandle
            let totalDelay: TimeInterval = 10.0
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.preBufferProgress = 0.0
                self.preBufferTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                    guard let self = self else { return }
                    self.preBufferProgress = min(self.preBufferProgress + 0.1 / totalDelay, 1.0)
                }
            }
            #if DEBUG
            print("   handle=\(capturedSH) mixer=\(mixerHandle) preMix=\(preMixerHandle) playback=\(capturedPH) — pre-buffering \(Int(totalDelay))s before mixer start…")
            #endif
            #if os(iOS)
            beginFlacPrebufBackgroundTask()
            #endif
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + totalDelay) { [weak self] in
                guard let self = self, self.streamHandle == capturedSH else { return }
                DispatchQueue.main.async {
                    self.preBufferTimer?.invalidate()
                    self.preBufferTimer = nil
                }
                #if DEBUG
                print("   🎬 FLAC pre-buffer complete — calling BASS_ChannelPlay")
                #endif
                BASS_ChannelPlay(capturedPH, 0)
                DispatchQueue.main.async { self.startMetadataPolling() }
                #if os(iOS)
                self.endFlacPrebufBackgroundTask()
                #endif
            }
        } else {
            #if DEBUG
            print("   handle=\(streamHandle) preMix=\(preMixerHandle) mixer=\(mixerHandle) playback=\(ph) — calling BASS_ChannelPlay…")
            #endif
            BASS_ChannelSetAttribute(ph, DWORD(BASS_ATTRIB_VOL), 0)
            BASS_ChannelPlay(ph, 0)
            startFadeIn(mixer: ph)
            startMetadataPolling()
        }
    }

    // MARK: - Stream Teardown

    func freeStream() {
        fxRampTimer?.invalidate()
        fxRampTimer = nil
        cancelFade()
        stopMetadataPolling()
        oggStopConfirmed = false
        trackChangeCount = 0
        isRefillPausing  = false
        lastFlacTitle = nil
        lastOGGVorbisTitle = nil
        lastIcecastTitle = nil
        lastMetaSyncTitle = nil

        // Stop DVR playback and timers before freeing channels.
        // Ordering: stop timer → free DVR stream → stop BASS channels (stops DSP) → cleanup buffer.
        stopDVRRecordingPump()
        dvrBehindTimer?.invalidate()
        dvrBehindTimer = nil
        dvrMetadataTimer?.invalidate()
        dvrMetadataTimer = nil
        if dvrPlaybackStream != 0 {
            BASS_StreamFree(dvrPlaybackStream)
            dvrPlaybackStream = 0
        }
        if dvrNextStream != 0 {
            BASS_StreamFree(dvrNextStream)
            dvrNextStream = 0
        }
        for s in dvrPausedStreams { BASS_StreamFree(s) }
        dvrPausedStreams.removeAll()
        dvrSyncContexts.removeAll()

        if mixerHandle != 0 {
            BASS_ChannelStop(mixerHandle)     // stops DSP callbacks including recordingDSP
            BASS_StreamFree(mixerHandle)
            #if DEBUG
            print("⏹  mixer freed (handle was \(mixerHandle))")
            #endif
            mixerHandle = 0
        }
        preBufferTimer?.invalidate()
        preBufferTimer = nil
        DispatchQueue.main.async { self.preBufferProgress = 0.0 }
        #if os(iOS)
        endFlacPrebufBackgroundTask()
        #endif
        if preMixerHandle != 0 {
            BASS_ChannelStop(preMixerHandle)
            BASS_StreamFree(preMixerHandle)
            #if DEBUG
            print("⏹  pre-mixer freed (handle was \(preMixerHandle))")
            #endif
            preMixerHandle = 0
        }
        if streamHandle != 0 {
            // For FLAC direct playback the stream IS the playback channel (already stopped/freed
            // above if mixerHandle pointed at it — but in direct mode mixerHandle == 0, so we
            // stop/free the stream here).
            BASS_ChannelStop(streamHandle)
            BASS_StreamFree(streamHandle)
            #if DEBUG
            print("⏹  stream freed (handle was \(streamHandle))")
            #endif
            streamHandle = 0
        }
        eqLowFX  = 0
        eqMidFX  = 0
        eqHighFX = 0
        compressorFX = 0
        levelMeterDSP = 0
        stereoDSP = 0
        limiterDSP = 0
        inputGainDSP = 0
        subBassDSP = 0
        rmsAccumulator = 0
        rmsSampleCount = 0
        lastAppliedThreshold = 0
        clickGuardDSP = 0
        cgFadeBuffersRemaining = 0
        cgMP3ScanActive = false
        cgMP3ScanEnd = 0
        cgMP3ScanEMA    = 0
        cgMP3ScanRMSEMA = 0
        cgScanPrevL     = 0
        cgScanPrevPrevL = 0
        cgMP3SpikeCount = 0
        cgSyncTime = 0
        cgLastGuardTime = 0
        flacPendingFadeIn = false
        flacRebufferingAfterRecovery = false
        // Signal that this teardown happened — restartStream() captures and re-checks this
        // to detect a concurrent restart and discard its stale BASS_StreamCreateURL result.
        streamGeneration &+= 1
        lastKnownStreamBytes = 0
        lastPositionAdvanceTime = 0

        if recoveryStreamHandle != 0 {
            BASS_Mixer_ChannelRemove(recoveryStreamHandle)
            BASS_StreamFree(recoveryStreamHandle)
            recoveryStreamHandle = 0
        }
        isAttemptingRecovery = false
        recoveryStartTime = nil

        // Channels are now stopped — safe to tear down StreamBuffer.
        recordingDSP = 0
        streamBuffer?.stop()
        streamBuffer?.cleanup()
        streamBuffer = nil
        dvrState = .live
        dvrBufferFull = false
        dvrReturnOfferPending = false
        dvrFullBufferDrainStarted = false
        behindLiveSeconds = 0
        dvrCurrentSegNum = 0
        dvrNextSegNum    = 0
        dvrPauseTimestamp = 0
        dvrMetadataJournal.removeAll()
        lastDVRPublishedMetadata = nil
    }

    // MARK: - Stream Attributes

    func configureStreamAttributes(format: String, handle: DWORD) {
        let ph = playbackHandle  // Always mixerHandle when playing (output post-mixer for FLAC, single mixer for others)

        let netResume: Float = 25
        BASS_ChannelSetAttribute(handle, DWORD(BASS_ATTRIB_NET_RESUME), netResume)

        // All formats use two-mixer pipeline: pre-mixer gets a stutter-protection buffer;
        // the FX output mixer gets 0.1s so EQ/compressor changes are heard within ~100ms.
        // FLAC: 3.0s — absorbs decode jitter from high-bitrate FLAC frames.
        // OGG: 1.5s — OGG bitstream chain boundaries cause a ~0.4s decoder reinit gap
        //   (BASS fires two OGG_CHANGE events ~0.4s apart while headers are processed).
        //   0.3s was smaller than this gap, causing pre-mixer underruns → stutter.
        // MP3/AAC: 0.3s — no bitstream boundaries; 0.3s is ample.
        if mixerHandle != 0 {
            let preMixBuf: Float = format == "FLAC" ? 3.0 : (format == "OGG" ? 1.5 : 0.3)
            BASS_ChannelSetAttribute(preMixerHandle, DWORD(BASS_ATTRIB_BUFFER), preMixBuf)
            BASS_ChannelSetAttribute(mixerHandle,    DWORD(BASS_ATTRIB_BUFFER), 0.1)
            #if DEBUG
            print("⚙️  configureStreamAttributes format=\(format) preMixBuf=\(preMixBuf)s fxMixBuf=0.1s")
            #endif
        } else {
            #if DEBUG
            print("⚙️  configureStreamAttributes format=\(format) — no mixer (direct mode)")
            #endif
        }

        // Click guard always on preMixerHandle: fires before the FX output mixer,
        // giving click-clean recordings since the recording DSP at priority -3 runs after.
        applyEffects(to: ph, clickGuardOn: preMixerHandle)
    }

    // MARK: - BASS Syncs

    func setupSyncs(for handle: DWORD) {
        let userData = Unmanaged.passUnretained(self).toOpaque()

        stallSync = BASS_ChannelSetSync(
            handle,
            DWORD(BASS_SYNC_STALL),
            0,
            { _, channel, data, user in
                guard data == 0, let user = user else { return }
                let player = Unmanaged<BASSRadioPlayer>.fromOpaque(user).takeUnretainedValue()
                player.handleStallSync(channel: channel)
            },
            userData
        )

        endSync = BASS_ChannelSetSync(
            handle,
            DWORD(BASS_SYNC_END),
            0,
            { _, channel, _, user in
                guard let user = user else { return }
                let player = Unmanaged<BASSRadioPlayer>.fromOpaque(user).takeUnretainedValue()
                player.handleEndSync(channel: channel)
            },
            userData
        )

        if activeFormat == "OGG" || activeFormat == "FLAC" {
            // Both OGG and FLAC use mixer path. BASS_Mixer_ChannelSetSync with BASS_SYNC_MIXTIME
            // fires during the mixer's render of the boundary buffer — sample-accurate.
            oggChangeSync = BASS_Mixer_ChannelSetSync(
                handle,
                DWORD(BASS_SYNC_OGG_CHANGE) | DWORD(BASS_SYNC_MIXTIME),
                0,
                { _, channel, _, user in
                    guard let user = user else { return }
                    let player = Unmanaged<BASSRadioPlayer>.fromOpaque(user).takeUnretainedValue()
                    player.handleOggChangeSync(channel: channel)
                },
                userData
            )
            #if DEBUG
            print("🔗 Syncs registered — stall=\(stallSync) end=\(endSync) oggChange=\(oggChangeSync) (mixer, mixtime)")
            #endif
        } else if activeFormat == "MP3" {
            // MP3: use BASS_SYNC_META to detect ICY metadata changes as a proxy
            // for track boundaries. Arms the same click guard DSP used by OGG/FLAC.
            metaChangeSync = BASS_Mixer_ChannelSetSync(
                handle,
                DWORD(BASS_SYNC_META) | DWORD(BASS_SYNC_MIXTIME),
                0,
                { _, channel, _, user in
                    guard let user = user else { return }
                    let player = Unmanaged<BASSRadioPlayer>.fromOpaque(user).takeUnretainedValue()
                    player.handleMetaChangeSync(channel: channel)
                },
                userData
            )
            #if DEBUG
            print("🔗 Syncs registered — stall=\(stallSync) end=\(endSync) metaChange=\(metaChangeSync) (mixer, mixtime)")
            #endif
        } else {
            // AAC: no bitstream boundaries or ICY metadata; no click guard.
            #if DEBUG
            print("🔗 Syncs registered — stall=\(stallSync) end=\(endSync)")
            #endif
        }
    }

    func handleStallSync(channel: DWORD) {
        guard channel == streamHandle, streamHandle != 0 else { return }
        let bytes = BASS_ChannelGetPosition(channel, DWORD(BASS_POS_BYTE))
        let secs  = BASS_ChannelBytes2Seconds(channel, bytes)
        let dlBuf = BASS_StreamGetFilePosition(channel, DWORD(5))
        let dlEnd = BASS_StreamGetFilePosition(channel, DWORD(2))
        let rebuf = BASS_StreamGetFilePosition(channel, DWORD(9))
        #if DEBUG
        print("⏸️  STALL pos=\(String(format: "%.2f", secs))s dlBuf=\(dlBuf)/\(dlEnd) rebuffering=\(rebuf)%")
        #endif
        // Arm at the first stall signal — maximises the window before iOS can suspend the app.
        armReconnectBackgroundProtection()
        DispatchQueue.main.async { [weak self] in
            self?.playbackState = .buffering
        }
    }

    func handleEndSync(channel: DWORD) {
        guard channel == streamHandle, streamHandle != 0 else { return }
        if activeFormat == "OGG" || activeFormat == "FLAC" {
            #if DEBUG
            print("🏁  BASS_SYNC_END fired for \(activeFormat) channel \(channel) — deferring to status poll")
            #endif
            return
        }
        guard dvrState == .live else {
            #if DEBUG
            print("🏁  BASS_SYNC_END fired during DVR mode — ignoring")
            #endif
            return
        }
        #if DEBUG
        print("🏁  BASS_SYNC_END fired for channel \(channel) — event-based restart")
        #endif
        bassPollingQueue.async { [weak self] in
            self?.restartStream()
        }
    }

    func handleMetaChangeSync(channel: DWORD) {
        guard channel == streamHandle, streamHandle != 0 else { return }

        // Read current ICY metadata from the stream
        guard let ptr = BASS_ChannelGetTags(channel, DWORD(BASS_TAG_META)) else { return }
        guard let title = parseICYTitle(String(cString: ptr)), !title.isEmpty else { return }

        // Only arm guard when title actually changes
        guard title != lastMetaSyncTitle else { return }
        lastMetaSyncTitle = title

        // Debounce (same 1.5s window as OGG/FLAC)
        let now = ProcessInfo.processInfo.systemUptime
        if now - cgLastGuardTime < 1.5 { return }
        cgLastGuardTime = now

        // Phase 1: immediate gate covers subtle/undetectable artifacts at the SYNC position.
        // Phase 2: post-gate scan watches for late detectable artifacts (absolute spike > 4.0
        //   OR relative spike > 3× EMA — catches local outliers like a 2.0 spike vs 0.4 baseline).
        cgFadeBuffersRemaining = cgSilenceBufferCount + cgFadeBufferCount  // immediate ~60ms gate
        cgMP3ScanActive = true
        cgMP3ScanEnd = now + 1.2   // 1200ms scan window (covers ~650ms observed metadata-to-splice lead)
        cgMP3ScanEMA    = 1.0       // primed high to prevent false trigger on very first buffer
        cgMP3ScanRMSEMA = 1.0       // primed high to prevent false trigger on very first buffer
        cgScanPrevL     = 0         // reset cross-buffer d2 state; gate's last fade-in will overwrite
        cgScanPrevPrevL = 0
        cgMP3SpikeCount = 0
        cgSyncTime = now
        #if DEBUG
        print("🛡️  MP3 guard armed (60ms + scan) — title: \(title)")
        #endif
    }

    func handleOggChangeSync(channel: DWORD) {
        guard channel == streamHandle, streamHandle != 0 else { return }

        // Debounce: OGG fires 2 events per track change (~0.4s apart). Ignore the second.
        // FLAC may fire 1 or 2 — debounce handles both correctly.
        let now = ProcessInfo.processInfo.systemUptime
        if now - cgLastGuardTime < 1.5 { return }
        cgLastGuardTime = now

        // Arm the guard: silence + fade-in starting immediately.
        cgFadeBuffersRemaining = cgSilenceBufferCount + cgFadeBufferCount

        // FLAC only: check if download buffer is low and a refill pause is due.
        if activeFormat == "FLAC" {
            trackChangeCount += 1
            if trackChangeCount >= bufferRefillTrackInterval, !isRefillPausing {
                let dlFill = BASS_StreamGetFilePosition(streamHandle, DWORD(5))           // BASS_FILEPOS_BUFFER
                let dlSize = BASS_StreamGetFilePosition(streamHandle, DWORD(BASS_FILEPOS_END))
                let dlPct  = dlSize > 0 ? Double(dlFill) / Double(dlSize) * 100 : 100.0
                if dlPct < bufferRefillThreshold {
                    trackChangeCount = 0
                    DispatchQueue.main.async { [weak self] in self?.performRefillPause() }
                }
            }
        }
    }

    func performRefillPause() {
        guard activeFormat == "FLAC", !isRefillPausing else { return }
        let ph = playbackHandle
        let sh = streamHandle
        guard ph != 0, sh != 0, case .playing = playbackState else { return }
        isRefillPausing = true
        #if DEBUG
        print("⏸️ FLAC dlBuf low — freezing stream in pre-mixer \(bufferRefillDuration)s to refill")
        #endif
        // Mute the output mixer so the user hears silence.
        BASS_ChannelSetAttribute(ph, DWORD(BASS_ATTRIB_VOL), 0)
        // Freeze the stream channel inside the pre-mixer — BASS stops consuming the download
        // buffer while the pre-mixer itself keeps running (recording DSP unaffected).
        // The pre-mixer has a 3s buffer; bufferRefillDuration must stay < 3s to avoid silence
        // reaching the recording DSP. We use 2.5s (0.5s safety margin).
        BASS_Mixer_ChannelFlags(sh, DWORD(BASS_MIXER_CHAN_PAUSE), DWORD(BASS_MIXER_CHAN_PAUSE))
        DispatchQueue.main.asyncAfter(deadline: .now() + bufferRefillDuration) { [weak self] in
            guard let self = self else { return }
            self.isRefillPausing = false
            guard case .playing = self.playbackState, self.playbackHandle == ph, self.streamHandle == sh else { return }
            // Unfreeze the stream — resume consuming download buffer from where it left off.
            BASS_Mixer_ChannelFlags(sh, 0, DWORD(BASS_MIXER_CHAN_PAUSE))
            self.startFadeIn(mixer: ph)
        }
    }

    // MARK: - FLAC Network Recovery

    /// Called when dlBuf drops below 20% during FLAC playback. Creates a new HTTP stream
    /// and adds it muted to the existing pre-mixer so it can download in the background
    /// while the old buffer plays out. Called on bassPollingQueue.
    func startFlacRecovery() {
        guard activeFormat == "FLAC",
              streamHandle != 0,
              preMixerHandle != 0,
              let current = qualities.first(where: { $0.format == "FLAC" }),
              let cURL = current.url.cString(using: .utf8) else {
            isAttemptingRecovery = false
            recoveryStartTime = nil
            return
        }

        #if DEBUG
        print("🔄 FLAC recovery: pre-creating recovery stream")
        #endif

        BASS_SetConfig(DWORD(BASS_CONFIG_NET_BUFFER), BASSConfig.netBufferMsFLAC)
        BASS_SetConfig(DWORD(BASS_CONFIG_NET_PREBUF), 0)    // return immediately after connect; fill in background
        BASS_SetConfig(DWORD(BASS_CONFIG_NET_TIMEOUT), BASSConfig.netTimeoutFastMs) // fail fast; 10s default blocks bassPollingQueue
        let streamFlags = DWORD(BASS_STREAM_STATUS) | DWORD(BASS_SAMPLE_FLOAT) | DWORD(BASS_STREAM_DECODE)
        let newHandle = BASS_StreamCreateURL(cURL, 0, streamFlags, nil, nil)
        let streamErr = BASS_ErrorGetCode()  // capture before SetConfig overwrites it
        BASS_SetConfig(DWORD(BASS_CONFIG_NET_BUFFER), BASSConfig.netBufferMs)
        BASS_SetConfig(DWORD(BASS_CONFIG_NET_PREBUF), 50)    // restore for normal stream creation
        BASS_SetConfig(DWORD(BASS_CONFIG_NET_TIMEOUT), BASSConfig.netTimeoutMs) // restore

        guard newHandle != 0 else {
            #if DEBUG
            print("❌ FLAC recovery: stream creation failed (err=\(streamErr)) — will fall back to normal restart")
            #endif
            isAttemptingRecovery = false
            recoveryStartTime = nil
            return
        }

        // Add to pre-mixer paused — BASS_MIXER_CHAN_PAUSE prevents decoding so the download
        // ring buffer accumulates without being consumed. Volume is also zeroed as a safety net.
        BASS_Mixer_StreamAddChannel(preMixerHandle, newHandle,
            DWORD(BASS_MIXER_CHAN_BUFFER) | DWORD(BASS_MIXER_CHAN_NORAMPIN) | DWORD(BASS_MIXER_CHAN_PAUSE))
        BASS_ChannelSetAttribute(newHandle, DWORD(BASS_ATTRIB_VOL), 0)

        recoveryStreamHandle = newHandle
        #if DEBUG
        print("🔄 FLAC recovery: stream \(newHandle) added to pre-mixer (muted) — downloading…")
        #endif
    }

    /// Swaps the pre-created recovery stream in place of the exhausted old stream.
    /// Avoids the full 10s pre-buffer restart. Called on bassPollingQueue.
    func activateRecoveryStream(handle: DWORD) {
        let elapsed = recoveryStartTime.map { ProcessInfo.processInfo.systemUptime - $0 } ?? 0
        recoveryStartTime = nil
        #if DEBUG
        print("🔄 FLAC recovery: activating stream \(handle) (downloaded \(String(format:"%.1f", elapsed))s)")
        #endif

        // Remove and free the exhausted old stream from the pre-mixer.
        let oldHandle = streamHandle
        if oldHandle != 0 {
            BASS_Mixer_ChannelRemove(oldHandle)
            BASS_ChannelStop(oldHandle)
            BASS_StreamFree(oldHandle)
            #if DEBUG
            print("🔄 FLAC recovery: old stream \(oldHandle) freed")
            #endif
        }

        // Swap in the recovery stream.
        streamHandle = handle

        // Re-register syncs on the new stream handle (old syncs auto-removed when stream was freed).
        setupSyncs(for: handle)

        // Reset metadata dedup so the new stream's first track fires a callback.
        lastFlacTitle = nil
        lastOGGVorbisTitle = nil
        lastIcecastTitle = nil

        // If the output mixer has stopped (BASS_MIXER_END fired while the download buffer
        // drained to 0%), a simple vol-swap won't work — the pre-mixer is also in an ended
        // state and returning 0 bytes, so the output mixer would stop again immediately.
        // Rebuild the full mixer pipeline around the recovery stream to restore playback.
        if mixerHandle != 0, BASS_ChannelIsActive(mixerHandle) == 0 {
            #if DEBUG
            print("⚠️  FLAC recovery: output mixer stopped — rebuilding mixer pipeline")
            #endif
            // Detach recovery stream from the stopped pre-mixer before freeing it.
            BASS_Mixer_ChannelRemove(handle)
            BASS_StreamFree(mixerHandle)
            BASS_StreamFree(preMixerHandle)

            let newPreMixer = BASS_Mixer_StreamCreate(BASSConfig.sampleRate, BASSConfig.channels,
                DWORD(BASS_MIXER_END) | DWORD(BASS_SAMPLE_FLOAT) | DWORD(BASS_STREAM_DECODE))
            BASS_Mixer_StreamAddChannel(newPreMixer, handle,
                DWORD(BASS_MIXER_CHAN_BUFFER) | DWORD(BASS_MIXER_CHAN_NORAMPIN) | DWORD(BASS_MIXER_CHAN_PAUSE))
            let newMixer = BASS_Mixer_StreamCreate(BASSConfig.sampleRate, BASSConfig.channels,
                DWORD(BASS_MIXER_END) | DWORD(BASS_SAMPLE_FLOAT))
            BASS_Mixer_StreamAddChannel(newMixer, newPreMixer, DWORD(BASS_MIXER_CHAN_BUFFER))

            preMixerHandle = newPreMixer
            mixerHandle = newMixer

            // Bail if the rebuilt mixer pipeline failed; otherwise recovery would
            // silently produce no audio. Fail loudly into the reconnect path.
            guard newPreMixer != 0, newMixer != 0 else {
                let err = BASS_ErrorGetCode()
                #if DEBUG
                print("❌  FLAC recovery: mixer rebuild failed (error \(err)) — scheduling reconnect")
                #endif
                scheduleReconnect()
                return
            }

            // configureStreamAttributes sets buffer sizes and re-attaches all DSP/FX.
            // Recovery stream was added with PAUSE; the mixer runs but produces silence
            // until checkStreamStatus unpauses it after the download buffer refills.
            configureStreamAttributes(format: "FLAC", handle: handle)
            BASS_ChannelSetAttribute(mixerHandle, DWORD(BASS_ATTRIB_VOL), 0)
            BASS_ChannelPlay(mixerHandle, 0)
            flacRebufferingAfterRecovery = true
            DispatchQueue.main.async { [weak self] in
                self?.preBufferProgress = 0.0
                self?.playbackState = .connecting
            }
            #if DEBUG
            print("⏳ FLAC recovery (rebuilt mixers): stream \(handle) active — rebuffering")
            #endif
            return
        }

        // Normal case: mixers are still running (proactive recovery pre-created the stream
        // while the old stream was alive, keeping BASS_MIXER_END from firing). The recovery
        // stream is already paused in the pre-mixer (BASS_MIXER_CHAN_PAUSE set in startFlacRecovery).
        // Mute output and wait for the download ring buffer to refill before starting audio.
        BASS_ChannelSetAttribute(playbackHandle, DWORD(BASS_ATTRIB_VOL), 0)
        flacRebufferingAfterRecovery = true
        DispatchQueue.main.async { [weak self] in
            self?.preBufferProgress = 0.0
            self?.playbackState = .connecting
        }
        #if DEBUG
        print("⏳ FLAC recovery: stream \(handle) active — rebuffering (channel paused in mixer)")
        #endif
    }

    // MARK: - Stream Restart

    func restartStream() {
        #if DEBUG
        print("🔄 Restarting \(activeFormat) stream...")
        #endif

        // AAC restarts the stream on every track change, so a restart while armed means
        // the audio is crossing into a new show. Reset FX to defaults early to beat the
        // metadata lag (the correct per-show FX is recalled later by fetchShowInfo once
        // metadata catches up). Non-persisting: currentShowDate is still the OLD show.
        if activeFormat == "AAC", pendingAACShowChangeReset {
            pendingAACShowChangeReset = false
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.suppressPerShowSave = true
                self.resetAllFX()
                self.suppressPerShowSave = false
                // Open the carry-over window: from here until the incoming show's fetch
                // resolves, any FX the user dials in belongs to the INCOMING show, not
                // the outgoing one whose date `currentShowDate` still holds.
                self.aacCarryoverActive = true
                self.aacCarryoverFXAdjusted = false
                #if DEBUG
                print("🎚️ AAC show-change heuristic: reset FX to defaults early")
                #endif
            }
        }

        // freeStream() resets dvrState → .live and cleans up DVR playback/recording.
        freeStream()

        // Capture generation AFTER our own freeStream() so concurrent restarts that also
        // called freeStream() will have incremented it, allowing us to detect the race.
        let myGeneration = streamGeneration

        guard let current = qualities.first(where: { $0.format == activeFormat }),
              let cURL = current.url.cString(using: .utf8) else { return }

        if current.format == "FLAC" {
            BASS_SetConfig(DWORD(BASS_CONFIG_NET_BUFFER), BASSConfig.netBufferMsFLAC)
            BASS_SetConfig(DWORD(BASS_CONFIG_NET_PREBUF), 50)
        }
        // Graduated connect timeout (see BASSRadioPlayerLogic.reconnectConnectTimeoutMs):
        //   attempt 0 — 10s: first staleness-triggered try; network may just be flaky
        //   attempt 1 — 5s:  NWPathMonitor restarts (path just reported satisfied) + first retry
        //   attempt 2+ — 3s: fast-fail subsequent retries to cycle through budget quickly
        // Always restore to the 10s default after BASS_StreamCreateURL returns.
        let reconnectTimeout = BASSRadioPlayerLogic.reconnectConnectTimeoutMs(attempt: reconnectAttempt)
        BASS_SetConfig(DWORD(BASS_CONFIG_NET_TIMEOUT), reconnectTimeout)

        let streamFlags = DWORD(BASS_STREAM_STATUS) | DWORD(BASS_SAMPLE_FLOAT) | DWORD(BASS_STREAM_DECODE)
        let newHandle = BASS_StreamCreateURL(cURL, 0, streamFlags, nil, nil)

        if current.format == "FLAC" {
            BASS_SetConfig(DWORD(BASS_CONFIG_NET_BUFFER), BASSConfig.netBufferMs)
            BASS_SetConfig(DWORD(BASS_CONFIG_NET_PREBUF), 50)
        }
        BASS_SetConfig(DWORD(BASS_CONFIG_NET_TIMEOUT), BASSConfig.netTimeoutMs)  // always restore

        guard newHandle != 0 else {
            let err = BASS_ErrorGetCode()
            #if DEBUG
            print("❌ restartStream: BASS_StreamCreateURL failed (err=\(err)) — scheduling reconnect")
            #endif
            scheduleReconnect()
            return
        }

        // Guard against a concurrent restart that ran freeStream() while we were blocked in
        // BASS_StreamCreateURL (e.g. switchQuality() on main thread, or NWPathMonitor +
        // checkStreamStatus both firing simultaneously). The other restart's freeStream()
        // incremented streamGeneration, so our generation is now stale — discard our handle.
        guard streamGeneration == myGeneration else {
            #if DEBUG
            print("⏭ restartStream: stale generation (concurrent restart) — discarding handle \(newHandle)")
            #endif
            BASS_StreamFree(newHandle)
            return
        }

        reconnectAttempt = 0
        DispatchQueue.main.async { self.isReconnecting = false }
        #if os(iOS)
        // Stream URL connected — audio will start rendering shortly, handing off
        // background execution to the audio background mode. Safe to end tasks.
        endBackgroundReconnectTask()
        stopSilenceKeepalive()
        #endif

        streamHandle = newHandle
        if current.format == "FLAC" {
            preMixerHandle = BASS_Mixer_StreamCreate(BASSConfig.sampleRate, BASSConfig.channels,
                DWORD(BASS_MIXER_END) | DWORD(BASS_SAMPLE_FLOAT) | DWORD(BASS_STREAM_DECODE))
            BASS_Mixer_StreamAddChannel(preMixerHandle, streamHandle,
                DWORD(BASS_MIXER_CHAN_BUFFER) | DWORD(BASS_MIXER_CHAN_NORAMPIN))
            mixerHandle = BASS_Mixer_StreamCreate(BASSConfig.sampleRate, BASSConfig.channels,
                DWORD(BASS_MIXER_END) | DWORD(BASS_SAMPLE_FLOAT))
            BASS_Mixer_StreamAddChannel(mixerHandle, preMixerHandle,
                DWORD(BASS_MIXER_CHAN_BUFFER))
        } else {
            preMixerHandle = BASS_Mixer_StreamCreate(BASSConfig.sampleRate, BASSConfig.channels,
                DWORD(BASS_MIXER_END) | DWORD(BASS_SAMPLE_FLOAT) | DWORD(BASS_STREAM_DECODE))
            BASS_Mixer_StreamAddChannel(preMixerHandle, streamHandle,
                DWORD(BASS_MIXER_CHAN_BUFFER) | DWORD(BASS_MIXER_CHAN_NORAMPIN))
            mixerHandle = BASS_Mixer_StreamCreate(BASSConfig.sampleRate, BASSConfig.channels,
                DWORD(BASS_MIXER_END) | DWORD(BASS_SAMPLE_FLOAT))
            BASS_Mixer_StreamAddChannel(mixerHandle, preMixerHandle,
                DWORD(BASS_MIXER_CHAN_BUFFER))
        }

        // Bail if the mixer pipeline failed to rebuild on restart; otherwise the
        // restarted stream would be silently dead. Fail loudly into the reconnect path.
        guard preMixerHandle != 0, mixerHandle != 0 else {
            let err = BASS_ErrorGetCode()
            #if DEBUG
            print("❌  restartStream: mixer pipeline creation failed (error \(err)) — scheduling reconnect")
            #endif
            scheduleReconnect()
            return
        }

        // Recreate StreamBuffer so recording resumes after restart (freeStream() cleared it).
        let dvrMins2 = UserDefaults.standard.integer(forKey: "dvrBufferMinutes")
        streamBuffer = StreamBuffer(maxMinutes: dvrMins2 > 0 ? dvrMins2 : 15)
        streamBuffer?.start()

        configureStreamAttributes(format: current.format, handle: streamHandle)
        setupSyncs(for: streamHandle)

        let ph = playbackHandle
        if current.format == "FLAC" {
            // Same 10s pre-buffer as initial play — lets the ring buffer fill before decode starts.
            BASS_ChannelSetAttribute(ph, DWORD(BASS_ATTRIB_VOL), 0)
            flacPendingFadeIn = true
            let capturedPH = ph
            let capturedSH = newHandle
            let totalDelay: TimeInterval = 10.0
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.preBufferProgress = 0.0
                self.preBufferTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                    guard let self = self else { return }
                    self.preBufferProgress = min(self.preBufferProgress + 0.1 / totalDelay, 1.0)
                }
            }
            #if DEBUG
            print("   🔄 FLAC restart: pre-buffering \(Int(totalDelay))s — handle=\(capturedSH) mixer=\(mixerHandle) preMix=\(preMixerHandle)")
            #endif
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + totalDelay) { [weak self] in
                guard let self = self, self.streamHandle == capturedSH else { return }
                DispatchQueue.main.async {
                    self.preBufferTimer?.invalidate()
                    self.preBufferTimer = nil
                }
                #if DEBUG
                print("   🎬 FLAC restart pre-buffer complete — calling BASS_ChannelPlay")
                #endif
                BASS_ChannelPlay(capturedPH, 0)
                #if DEBUG
                print("✅ Restarted handle=\(capturedSH) playback=\(capturedPH)")
                #endif
                DispatchQueue.main.async {
                    self.playbackState = .playing
                    self.startMetadataPolling()
                }
            }
        } else {
            BASS_ChannelPlay(ph, 0)
            #if DEBUG
            print("✅ Restarted handle=\(newHandle) preMix=\(preMixerHandle) mixer=\(mixerHandle) playback=\(ph)")
            #endif
            DispatchQueue.main.async {
                self.playbackState = .playing
                self.startMetadataPolling()
            }
        }
    }

    // MARK: - Network Resilience

    #if os(iOS)
    /// Requests background execution time so reconnect timers keep firing after audio output stops
    /// (e.g. network lost while device is locked). Safe to call repeatedly — no-ops if task already active.
    /// Must be called from any thread; UIApplication call is marshalled to main.
    func beginBackgroundReconnectTaskIfNeeded() {
        guard bgReconnectTask == .invalid else { return }
        // UIApplication.beginBackgroundTask is callable from any thread per Apple docs,
        // but dispatch to main to be safe and avoid races on bgReconnectTask.
        DispatchQueue.main.async { [weak self] in
            guard let self = self, self.bgReconnectTask == .invalid else { return }
            self.bgReconnectTask = UIApplication.shared.beginBackgroundTask(withName: "stream-reconnect") { [weak self] in
                #if DEBUG
                print("⚠️ iOS background reconnect task expired")
                #endif
                self?.endBackgroundReconnectTask()
            }
            #if DEBUG
            print("📱 Background reconnect task started (id=\(self.bgReconnectTask.rawValue))")
            #endif
        }
    }

    /// Ends the background execution task. Safe to call when no task is active.
    func endBackgroundReconnectTask() {
        let task = bgReconnectTask
        guard task != .invalid else { return }
        bgReconnectTask = .invalid
        DispatchQueue.main.async {
            UIApplication.shared.endBackgroundTask(task)
            #if DEBUG
            print("📱 Background reconnect task ended")
            #endif
        }
    }

    /// Requests background execution time to cover the FLAC pre-buffer window
    /// (before BASS_ChannelPlay starts the audio unit and iOS permits background audio).
    func beginFlacPrebufBackgroundTask() {
        guard bgFlacPrebufTask == .invalid else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self = self, self.bgFlacPrebufTask == .invalid else { return }
            self.bgFlacPrebufTask = UIApplication.shared.beginBackgroundTask(withName: "flac-prebuffer") { [weak self] in
                #if DEBUG
                print("⚠️ iOS FLAC pre-buffer background task expired")
                #endif
                self?.endFlacPrebufBackgroundTask()
            }
            #if DEBUG
            print("📱 FLAC pre-buffer background task started (id=\(self.bgFlacPrebufTask.rawValue))")
            #endif
        }
    }

    func endFlacPrebufBackgroundTask() {
        let task = bgFlacPrebufTask
        guard task != .invalid else { return }
        bgFlacPrebufTask = .invalid
        DispatchQueue.main.async {
            UIApplication.shared.endBackgroundTask(task)
            #if DEBUG
            print("📱 FLAC pre-buffer background task ended")
            #endif
        }
    }

    /// Start a silent looping AVAudioPlayer to keep the AVAudioSession active during reconnect.
    /// iOS will not suspend an app that has an active .playback session with audio output,
    /// even at volume 0.0 — this prevents suspension for tunnels longer than ~30s.
    /// Safe to call repeatedly; no-ops if already running.
    func startSilenceKeepalive() {
        #if os(iOS)
        // The keepalive only prevents *background* suspension. In the foreground iOS never suspends
        // us, and an active silent player makes iOS believe audio is rendering — which (because we
        // lack the private com.apple.mediaremote.set-playback-state entitlement) routes the
        // AirPods/lock-screen button to pauseCommand even while DVR-paused, silently breaking resume.
        guard !isAppInForeground else { return }
        #endif
        // A player that exists but has stopped is worse than no player at all. An interruption
        // (call, Siri, another app claiming the session) stops the AVAudioPlayer without nil-ing
        // it, so the old `== nil` guard blocked every restart for the rest of the session — iOS
        // then suspended us and the recording pump froze mid-pause. Rebuild a stopped player.
        if let existing = silenceKeepalivePlayer {
            guard !existing.isPlaying else { return }
            existing.stop()
            silenceKeepalivePlayer = nil
        }
        guard let data = Self.silentWAVData,
              let player = try? AVAudioPlayer(data: data, fileTypeHint: AVFileType.wav.rawValue)
        else {
            #if DEBUG
            print("⚠️ Silence keepalive: failed to create AVAudioPlayer")
            #endif
            return
        }
        player.numberOfLoops = -1
        player.volume = 0.0
        player.prepareToPlay()
        // play() returns false when the session isn't usable yet — typically right after an
        // interruption ends, before the session has been reactivated. Best-effort reactivate
        // and retry rather than silently leaving the app unprotected against suspension.
        guard player.play() else {
            #if DEBUG
            print("⚠️ Silence keepalive: play() refused — reactivating session and retrying")
            #endif
            player.stop()
            try? AVAudioSession.sharedInstance().setActive(true)
            scheduleSilenceKeepaliveRetry()
            return
        }
        silenceKeepalivePlayer = player
        silenceKeepaliveRetryCount = 0
        #if DEBUG
        print("🔇 Silence keepalive started — audio session stays alive during reconnect")
        logDVRDiag("keepalive-start")
        #endif
    }

    /// Retry a refused keepalive start up to 3 times, 1 s apart. Abandoned as soon as the
    /// conditions that need it are gone (playback resumed, or we came back to the foreground).
    private func scheduleSilenceKeepaliveRetry() {
        guard silenceKeepaliveRetryCount < 3 else {
            #if DEBUG
            print("⚠️ Silence keepalive: giving up after \(silenceKeepaliveRetryCount) retries")
            #endif
            return
        }
        silenceKeepaliveRetryCount += 1
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self, self.dvrState == .paused, !self.isAppInForeground else { return }
            self.startSilenceKeepalive()
        }
    }

    /// Re-arm the keepalive after something outside our control may have killed it: an
    /// interruption, a route change, or an AVAudioPlayer death we get no notification for.
    /// Resets the retry budget — this is a new episode, not a continuation of the last burst.
    /// No-op unless we're actually backgrounded, DVR-paused, and not already keeping alive.
    func rearmSilenceKeepaliveIfNeeded() {
        guard !isAppInForeground, dvrState == .paused else { return }
        guard silenceKeepalivePlayer?.isPlaying != true else { return }
        silenceKeepaliveRetryCount = 0
        startSilenceKeepalive()
        #if DEBUG
        logDVRDiag("keepalive-rearm")
        #endif
    }

    /// Stop the silence keepalive. Called when real audio resumes or playback is explicitly stopped.
    func stopSilenceKeepalive() {
        silenceKeepaliveRetryCount = 0   // cancels any in-flight retry burst
        guard let player = silenceKeepalivePlayer else { return }
        player.stop()
        silenceKeepalivePlayer = nil
        #if DEBUG
        print("🔇 Silence keepalive stopped")
        #endif
    }

    /// Minimal 1-second silent mono 16-bit WAV, built in memory — no bundle file required.
    /// 44-byte RIFF/WAVE/fmt /data header + 88200 zero bytes (44.1 kHz, 1 channel, 16-bit PCM).
    private static let silentWAVData: Data? = {
        let sampleRate: UInt32 = 44100
        let numChannels: UInt16 = 1
        let bitsPerSample: UInt16 = 16
        let numSamples = sampleRate               // 1 second
        let dataSize = UInt32(numSamples) * UInt32(numChannels) * UInt32(bitsPerSample / 8)
        let byteRate = sampleRate * UInt32(numChannels) * UInt32(bitsPerSample / 8)
        let blockAlign = numChannels * (bitsPerSample / 8)

        var wav = Data()
        wav.reserveCapacity(44 + Int(dataSize))

        func appendLE<T: FixedWidthInteger>(_ value: T) {
            var v = value.littleEndian
            wav.append(contentsOf: withUnsafeBytes(of: &v, Array.init))
        }

        // RIFF chunk
        wav.append(contentsOf: "RIFF".utf8)
        appendLE(UInt32(36 + dataSize))
        wav.append(contentsOf: "WAVE".utf8)
        // fmt  sub-chunk
        wav.append(contentsOf: "fmt ".utf8)
        appendLE(UInt32(16))          // sub-chunk size (PCM)
        appendLE(UInt16(1))           // audio format (1 = PCM)
        appendLE(numChannels)
        appendLE(sampleRate)
        appendLE(byteRate)
        appendLE(blockAlign)
        appendLE(bitsPerSample)
        // data sub-chunk
        wav.append(contentsOf: "data".utf8)
        appendLE(dataSize)
        wav.append(Data(count: Int(dataSize)))   // all zeros = silence

        return wav
    }()

    #endif

    func startNetworkMonitoring() {
        let monitor = NWPathMonitor()
        pathMonitor = monitor
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self = self else { return }
            guard path.status == .satisfied, self.isUserIntendedPlay else { return }
            self.bassPollingQueue.async {
                // Re-check on the serial queue so we don't start multiple restarts
                // if NWPathMonitor fires several times before handles are set.
                guard !self.isStreamActive else { return }
                #if DEBUG
                print("🌐 Network restored — triggering immediate reconnect")
                #endif
                self.cancelReconnectTimer()
                // Reset to 1 (not 0): gets the 5s graduated timeout rather than 10s,
                // since the OS has just confirmed the path is satisfied and connection
                // should be fast. Also resets the retry budget to ~12 fresh attempts.
                self.reconnectAttempt = 1
                self.restartStream()
            }
        }
        monitor.start(queue: networkMonitorQueue)
    }

    /// Keep the app alive while audio output is absent (network loss while locked). Without
    /// this, iOS suspends the app within seconds of the audio stopping and every recovery
    /// mechanism freezes with it — the polling queue, the reconnect timer, and even the
    /// NWPathMonitor callback that would notice the new network. Nothing then resumes until
    /// the user foregrounds the app.
    ///
    /// Must be armed **before** a restart is attempted, not after the first failure:
    /// `BASS_StreamCreateURL` can block for up to 10 s against a network in transition, which
    /// is more than enough time to be suspended mid-connect.
    ///
    /// Idempotent, and `startSilenceKeepalive()` self-suppresses in the foreground.
    /// No-op on macOS, which never suspends us.
    func armReconnectBackgroundProtection() {
        #if os(iOS)
        beginBackgroundReconnectTaskIfNeeded()
        startSilenceKeepalive()
        #endif
    }

    func scheduleReconnect() {
        guard isUserIntendedPlay else { return }
        armReconnectBackgroundProtection()
        guard !BASSRadioPlayerLogic.shouldGiveUpReconnect(attempt: reconnectAttempt, maxAttempts: reconnectMaxAttempts) else {
            #if DEBUG
            print("❌ Reconnect giving up after \(reconnectMaxAttempts) attempts (~1 minute)")
            #endif
            DispatchQueue.main.async {
                self.isReconnecting = false
                self.playbackState = .stopped
            }
            return
        }
        let delay = reconnectRetryInterval
        reconnectAttempt += 1
        #if DEBUG
        print("⏳ Reconnect attempt \(reconnectAttempt)/\(reconnectMaxAttempts) scheduled in \(Int(delay))s")
        #endif
        DispatchQueue.main.async {
            self.isReconnecting = true
            self.playbackState = .connecting
        }
        cancelReconnectTimer()
        let timer = DispatchSource.makeTimerSource(queue: bassPollingQueue)
        timer.schedule(deadline: .now() + delay)
        timer.setEventHandler { [weak self] in
            guard let self = self, self.isUserIntendedPlay else { return }
            // Skip if a concurrent source (e.g. triggerImmediateReconnect) already
            // created a new stream while this timer was waiting in the queue.
            guard !self.isStreamActive else {
                #if DEBUG
                print("⏩ Reconnect timer fired but stream already active — skipping")
                #endif
                return
            }
            self.restartStream()
        }
        timer.resume()
        reconnectTimer = timer
    }

    func cancelReconnectTimer() {
        reconnectTimer?.cancel()
        reconnectTimer = nil
    }

    // MARK: - Fade In / Fade Out

    func cancelFade() {
        fadeTimer?.invalidate()
        fadeTimer = nil
        fadeGeneration &+= 1
    }

    func startFadeIn(mixer: DWORD) {
        let gen = fadeGeneration
        DispatchQueue.main.async { [weak self] in
            guard let self, self.fadeGeneration == gen else { return }
            self.startFadeInOnMainThread(mixer: mixer)
        }
    }

    func startFadeInOnMainThread(mixer: DWORD) {
        cancelFade()
        guard mixer != 0 else { return }

        BASS_ChannelSetAttribute(mixer, DWORD(BASS_ATTRIB_VOL), 0)

        var currentVolume: Float = 0
        let startTime = ProcessInfo.processInfo.systemUptime
        let tickInterval: TimeInterval = 1.0 / 60.0  // ~60Hz

        fadeTimer = Timer.scheduledTimer(withTimeInterval: tickInterval, repeats: true) { [weak self] _ in
            guard let self = self, mixer != 0 else { return }

            let elapsed = ProcessInfo.processInfo.systemUptime - startTime
            let progress = min(elapsed / self.fadeInDuration, 1.0)
            currentVolume = Float(progress)

            BASS_ChannelSetAttribute(mixer, DWORD(BASS_ATTRIB_VOL), currentVolume)

            if progress >= 1.0 {
                self.cancelFade()
            }
        }
    }

    func startFadeOut(mixer: DWORD, completion: @escaping () -> Void) {
        let gen = fadeGeneration
        DispatchQueue.main.async { [weak self] in
            guard let self, self.fadeGeneration == gen else { return }
            self.startFadeOutOnMainThread(mixer: mixer, completion: completion)
        }
    }

    func startFadeOutOnMainThread(mixer: DWORD, completion: @escaping () -> Void) {
        cancelFade()
        guard mixer != 0 else {
            completion()
            return
        }

        var currentVolume: Float = 1.0
        BASS_ChannelGetAttribute(mixer, DWORD(BASS_ATTRIB_VOL), &currentVolume)
        guard currentVolume > 0 else { completion(); return }
        let startVolume = currentVolume
        let startTime = ProcessInfo.processInfo.systemUptime
        let tickInterval: TimeInterval = 1.0 / 60.0  // ~60Hz

        fadeTimer = Timer.scheduledTimer(withTimeInterval: tickInterval, repeats: true) { [weak self] _ in
            guard let self = self, mixer != 0 else { return }

            let elapsed = ProcessInfo.processInfo.systemUptime - startTime
            let progress = min(elapsed / self.fadeOutDuration, 1.0)
            let newVolume = startVolume * Float(1.0 - progress)

            BASS_ChannelSetAttribute(mixer, DWORD(BASS_ATTRIB_VOL), newVolume)

            if progress >= 1.0 {
                self.cancelFade()
                completion()
            }
        }
    }
}
