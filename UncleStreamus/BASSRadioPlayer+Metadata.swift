import Foundation
#if os(macOS)
import Bass
import BassMix
#endif

// MARK: - Metadata Polling & Publishing

extension BASSRadioPlayer {

    // MARK: - Polling Lifecycle

    func startMetadataPolling() {
        stopMetadataPolling()
        bassPollingQueue.async { [weak self] in self?.pollMetadata() }
        metadataTimer = Timer.scheduledTimer(withTimeInterval: metaPollInterval, repeats: true) { [weak self] _ in
            self?.bassPollingQueue.async { self?.pollMetadata() }
        }
        startStatePolling()
    }

    func stopMetadataPolling() {
        metadataTimer?.invalidate()
        metadataTimer = nil
        stopStatePolling()
    }

    func startStatePolling() {
        stopStatePolling()
        stateTimer = Timer.scheduledTimer(withTimeInterval: statePollInterval, repeats: true) { [weak self] _ in
            self?.bassPollingQueue.async { self?.checkStreamStatus() }
        }
    }

    func stopStatePolling() {
        stateTimer?.invalidate()
        stateTimer = nil
    }

    // MARK: - Metadata Polling

    func pollMetadata() {
        guard streamHandle != 0 else { return }

        // 1. ICY / Shoutcast (MP3)
        if let ptr = BASS_ChannelGetTags(streamHandle, DWORD(BASS_TAG_META)) {
            let raw = String(cString: ptr)
            if !raw.isEmpty, let title = parseICYTitle(raw), !title.isEmpty {
                #if DEBUG
                print("📋  [ICY] \(title)")
                #endif
                publishTitle(title)
                return
            }
        }

        // 2. Ogg Vorbis comments (OGG / FLAC)
        if let ptr = BASS_ChannelGetTags(streamHandle, DWORD(BASS_TAG_OGG)) {
            if let title = extractVorbisTitle(ptr) {
                if activeFormat == "FLAC" {
                    handleFlacTitleChange(shortTitle: title)
                    // Don't return: fall through to Icecast fetch below.
                    // The Vorbis tag can lag behind the actual track change by one poll cycle,
                    // so we always query Icecast as well. If the Vorbis title did change,
                    // handleFlacTitleChange already fires its own Icecast request; the second
                    // concurrent request is harmless (dedup'd by lastIcecastTitle).
                } else if activeFormat == "OGG" {
                    // OGG: publish Vorbis title immediately for fast per-track updates (Format A shows).
                    // For Format B shows (static venue/date tag that never changes per track), this fires
                    // once then is deduped by lastOGGVorbisTitle; the Icecast fetch below supersedes it
                    // with the correct per-track title within one network round-trip.
                    if title != lastOGGVorbisTitle {
                        lastOGGVorbisTitle = title
                        publishTitle(title)
                    }
                }
            }
        }

        // 3. AAC / FLAC / OGG: fetch from Icecast JSON endpoint
        if activeFormat == "AAC" || activeFormat == "FLAC" || activeFormat == "OGG" {
            fetchIcecastMetadata()
        }
    }

    // MARK: - Stream Status Polling

    func checkStreamStatus() {
        guard streamHandle != 0 else { return }

        let status = BASS_ChannelIsActive(streamHandle)
        let bytes  = BASS_ChannelGetPosition(streamHandle, DWORD(BASS_POS_BYTE))
        let secs   = BASS_ChannelBytes2Seconds(streamHandle, bytes)
        let bufferedBytes = BASS_StreamGetFilePosition(streamHandle, DWORD(5))

        DispatchQueue.main.async { [weak self] in
            guard let self, !self.flacRebufferingAfterRecovery else { return }
            self.playbackState = BASSRadioPlayerLogic.playbackState(forActiveStatus: status)
        }

        // FLAC rebuffering after recovery: stream is active and downloading but the channel
        // is paused in the pre-mixer (BASS_MIXER_CHAN_PAUSE) so no data is consumed until the
        // download ring buffer reaches the target threshold, matching initial-connect behaviour.
        if activeFormat == "FLAC", flacRebufferingAfterRecovery {
            let dlBufFill = BASS_StreamGetFilePosition(streamHandle, DWORD(5))
            let dlBufSize = BASS_StreamGetFilePosition(streamHandle, DWORD(BASS_FILEPOS_END))
            let dlPct = dlBufSize > 0 ? Double(dlBufFill) / Double(dlBufSize) * 100 : 100

            let threshold = BASSRadioPlayerLogic.flacRebufferThresholdPct  // ~10s at 900 kbps in a 25s ring buffer (matches initial connect ~10s wait)
            #if DEBUG
            print("⏳ FLAC rebuffer: \(String(format:"%.0f",dlPct))% / \(Int(threshold))%")
            #endif
            DispatchQueue.main.async { [weak self] in
                self?.preBufferProgress = min(dlPct / threshold, 1.0)
            }

            if BASSRadioPlayerLogic.flacRebufferComplete(downloadPct: dlPct) {
                flacRebufferingAfterRecovery = false
                // Unpause the recovery stream so the pre-mixer starts decoding audio.
                BASS_Mixer_ChannelFlags(streamHandle, 0, DWORD(BASS_MIXER_CHAN_PAUSE))
                BASS_ChannelSetAttribute(streamHandle, DWORD(BASS_ATTRIB_VOL), 1.0)
                // Ensure the output mixer is running (might have stopped in the rebuild path
                // while waiting; the proactive path already has it running with silence).
                let ph = playbackHandle
                if BASS_ChannelIsActive(ph) == 0 { BASS_ChannelPlay(ph, 0) }
                flacPendingFadeIn = true
                DispatchQueue.main.async { [weak self] in self?.preBufferProgress = 0.0 }
                #if DEBUG
                print("🔊 FLAC rebuffer complete (\(String(format:"%.0f",dlPct))%) — unpausing stream, fade-in pending")
                #endif
            }
            return  // Skip other health checks while rebuffering
        }

        // FLAC buffer health: log download buffer and FX output buffer levels.
        // Note: BASS_DATA_AVAILABLE returns 0xFFFFFFFF for DECODE-mode channels (the pre-mixer),
        // so we only measure the output post-mixer (fxBuf) which has a real 0.1s fill buffer.
        if activeFormat == "FLAC", status == BASS_ACTIVE_PLAYING {
            let dlBufFill = BASS_StreamGetFilePosition(streamHandle, DWORD(5))
            let dlBufSize = BASS_StreamGetFilePosition(streamHandle, DWORD(BASS_FILEPOS_END))
            let dlPct = dlBufSize > 0 ? Double(dlBufFill) / Double(dlBufSize) * 100 : -1

            // FX output buffer: readable fill level on the playing post-mixer (0.1s target).
            let ph = playbackHandle
            let fxAvail = ph != 0 ? BASS_ChannelGetData(ph, nil, DWORD(BASS_DATA_AVAILABLE)) : 0
            // BASS_ChannelGetData returns 0xFFFFFFFF (DWORD) on error (e.g. stopped mixer).
            // Treat as signed so the error sentinel reads -1, not ~12 billion ms.
            let fxBufMs = Int32(bitPattern: fxAvail) > 0 ? Double(fxAvail) / (44100.0 * 2 * 4) * 1000 : 0

            #if DEBUG
            print("📊 FLAC health: pos=\(String(format:"%.1f",secs))s dlBuf=\(String(format:"%.0f",dlPct))% fxBuf=\(String(format:"%.0f",fxBufMs))ms")
            #endif

            // Trigger fade-in once the FX output buffer has ≥80ms of audio (80% of its 0.1s
            // capacity). This fires on the first health poll after BASS_ChannelPlay succeeds,
            // confirming that data is flowing from the pre-mixer through the FX chain.
            if flacPendingFadeIn, fxBufMs >= 80 {
                flacPendingFadeIn = false
                #if DEBUG
                print("🔊 FLAC buffer ready (fxBuf=\(String(format:"%.0f",fxBufMs))ms) — starting fade-in")
                #endif
                DispatchQueue.main.async { [weak self] in
                    self?.preBufferProgress = 0.0  // dismiss loading bar
                    self?.startFadeIn(mixer: ph)
                }
            }

            // Proactive recovery: pre-create a backup stream when dlBuf drops below 10%.
            // Normal dlBuf sits at 17–20% during stable operation, so <10% reliably signals
            // genuine network loss. Starting early keeps the pre-mixer alive (the muted
            // recovery stream prevents BASS_MIXER_END from firing), enabling a seamless
            // vol-swap when the old stream finally runs out.
            let isConnected = BASS_StreamGetFilePosition(streamHandle, DWORD(BASS_FILEPOS_CONNECTED)) != 0
            if BASSRadioPlayerLogic.shouldStartFlacProactiveRecovery(downloadPct: dlPct,
                                                                     isConnected: isConnected,
                                                                     isAttemptingRecovery: isAttemptingRecovery,
                                                                     hasRecoveryStream: recoveryStreamHandle != 0,
                                                                     isRebuffering: flacRebufferingAfterRecovery) {
                isAttemptingRecovery = true
                recoveryStartTime = ProcessInfo.processInfo.systemUptime
                bassPollingQueue.async { [weak self] in self?.startFlacRecovery() }
            }
        }

        if activeFormat == "AAC",
           BASSRadioPlayerLogic.isAACUnderrun(statusIsPlaying: status == BASS_ACTIVE_PLAYING,
                                              bufferedBytes: UInt64(bufferedBytes),
                                              positionBytes: UInt64(bytes)) {
            guard !isReconnecting else { return }
            if dvrState == .live {
                #if DEBUG
                print("🔄 AAC buffer underrun detected (pos=\(String(format:"%.0f",secs)) buffered=0) — fast restart")
                #endif
                // AAC is the format that most needs this: its 0.3 s pre-mixer buffer drains
                // to zero the instant the network drops (a Wi-Fi → cellular handover is the
                // canonical case), and BASS's stall sync — which arms protection on the other
                // formats — frequently never fires for AAC at all. Audio output has already
                // stopped by the time we get here, so the suspension countdown is running.
                armReconnectBackgroundProtection()
                bassPollingQueue.async { [weak self] in self?.restartStream() }
            } else {
                #if DEBUG
                print("🔄 AAC buffer underrun in DVR mode — partial live restart")
                #endif
                bassPollingQueue.async { [weak self] in self?.partialRestartLiveChannel() }
            }
            return
        }

        if status == BASS_ACTIVE_STOPPED {
            guard !isReconnecting else { return }
            // Arm here, at the first sighting of a stopped stream, rather than in each of the
            // branches below: OGG/FLAC return early for a second confirming poll, and the FLAC
            // recovery-stream path returns too, so all of them would otherwise spend the whole
            // window unprotected. Live only — while DVR-paused the keepalive is already the
            // pause's own responsibility, and while DVR-playing real audio is still rendering.
            if dvrState == .live { armReconnectBackgroundProtection() }
            if activeFormat == "OGG" || activeFormat == "FLAC" {
                if !oggStopConfirmed {
                    oggStopConfirmed = true
                    #if DEBUG
                    print("⏸️  \(activeFormat) STOPPED detected — confirming in next poll…")
                    #endif
                    // FLAC: if recovery hasn't started yet (dlBuf was already < 20% when the
                    // network dropped, bypassing the health-check trigger), start it now.
                    // The 2s confirmation window gives the recovery stream time to connect.
                    if activeFormat == "FLAC", !isAttemptingRecovery, recoveryStreamHandle == 0 {
                        isAttemptingRecovery = true
                        recoveryStartTime = ProcessInfo.processInfo.systemUptime
                        bassPollingQueue.async { [weak self] in self?.startFlacRecovery() }
                    }
                    return
                }
                oggStopConfirmed = false
            }

            // FLAC recovery: if a recovery stream was pre-created while dlBuf was draining,
            // activate it now instead of doing a full 10s restart.
            if activeFormat == "FLAC", recoveryStreamHandle != 0 {
                let rh = recoveryStreamHandle
                let elapsed = recoveryStartTime.map { ProcessInfo.processInfo.systemUptime - $0 } ?? 0
                recoveryStreamHandle = 0
                isAttemptingRecovery = false
                #if DEBUG
                print("🔄 FLAC recovery: old stream STOPPED — activating recovery stream \(rh) (downloaded \(String(format:"%.1f", elapsed))s)")
                #endif
                bassPollingQueue.async { [weak self] in self?.activateRecoveryStream(handle: rh) }
                return
            }

            let err = BASS_ErrorGetCode()
            if dvrState == .live {
                #if DEBUG
                print("🔄 Stream STOPPED (err=\(err)) — fast auto restart")
                #endif
                bassPollingQueue.async { [weak self] in self?.restartStream() }
            } else {
                #if DEBUG
                print("🔄 Stream STOPPED (err=\(err)) in DVR mode — partial live restart")
                #endif
                bassPollingQueue.async { [weak self] in self?.partialRestartLiveChannel() }
            }
            return
        } else {
            oggStopConfirmed = false

            // Position staleness: catches network loss where BASS keeps the stream in
            // PLAYING state but the decode position stops advancing.  The canonical case
            // is AAC + iOS AudioToolbox "ReadBytes failed" loop — the download buffer
            // still shows data (so bufferedBytes != 0), but AudioToolbox can't decode it,
            // so neither BASS_SYNC_STALL nor the bufferedBytes==0 check ever fires.
            // 4s threshold (2× statePollInterval): AAC's 0.3s pre-mixer buffer depletes
            // almost instantly on network loss, so position freezes within a fraction of
            // a second. Two missed polls (4s) is safe against any realistic decode jitter.
            let now = ProcessInfo.processInfo.systemUptime
            switch BASSRadioPlayerLogic.positionStaleness(positionBytes: bytes,
                                                          lastKnownBytes: lastKnownStreamBytes,
                                                          lastAdvanceTime: lastPositionAdvanceTime,
                                                          now: now,
                                                          stallThreshold: 4.0,
                                                          isReconnecting: isReconnecting) {
            case .advanced:
                lastKnownStreamBytes = bytes
                lastPositionAdvanceTime = now
            case .holding:
                break
            case .stale:
                // Decode position frozen while BASS still reports PLAYING and the download buffer
                // has data — the canonical AAC + AudioToolbox "can't decode this packet" loop
                // (device log: "Packet with multiple raw data blocks - unsupported" /
                // "ScanForPackets (AAC) failed"). A fresh connection resyncs past the bad frame.
                // This must ALSO fire during DVR pause/playback: there the recording pump drives
                // decode, so a stall freezes the ring buffer (bufferedDuration stops growing) with
                // no other recovery — the observed multi-minute DVR stall. Use the DVR-aware
                // partial restart so the ring buffer survives; restartStream() would destroy it.
                #if DEBUG
                print("🔄 Stream stale: pos stuck at \(bytes)B for \(String(format:"%.1f", now - lastPositionAdvanceTime))s (dvrState=\(dvrState)) — restarting")
                #endif
                if dvrState == .live {
                    armReconnectBackgroundProtection()
                    DispatchQueue.main.async { [weak self] in
                        self?.isReconnecting = true
                        self?.playbackState = .buffering
                    }
                    bassPollingQueue.async { [weak self] in self?.restartStream() }
                } else {
                    // partialRestartLiveChannel() resets lastKnownStreamBytes/lastPositionAdvanceTime
                    // so the fresh (position-0) stream doesn't immediately re-trigger this check.
                    bassPollingQueue.async { [weak self] in self?.partialRestartLiveChannel() }
                }
            }
        }
    }

    // MARK: - Icecast JSON Metadata

    func fetchIcecastMetadata() {
        guard let url = URL(string: "https://shoutcast.norbert.de/status-json.xsl") else { return }

        var request = URLRequest(url: url)
        request.setValue(Self.userAgentString, forHTTPHeaderField: "User-Agent")

        URLSession.shared.dataTask(with: request) { [weak self] data, _, error in
            guard let self = self, let data = data, error == nil else { return }
            guard self.activeFormat == "AAC" || self.activeFormat == "FLAC" || self.activeFormat == "OGG" else { return }

            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let icestats = json["icestats"] as? [String: Any] else { return }

            let sources: [[String: Any]]
            if let arr = icestats["source"] as? [[String: Any]] {
                sources = arr
            } else if let obj = icestats["source"] as? [String: Any] {
                sources = [obj]
            } else {
                return
            }

            let mp3Source = sources.first { ($0["listenurl"] as? String)?.hasSuffix(".mp3") == true }
            let source = mp3Source ?? sources.first

            guard let title = source?["title"] as? String, !title.isEmpty else { return }

            if title != self.lastIcecastTitle {
                self.lastIcecastTitle = title
                #if DEBUG
                print("🛰️  [ICECAST] \(title)")
                #endif
                DispatchQueue.main.async {
                    self.publishTitle(title)
                }
            }
        }.resume()
    }

    // MARK: - FLAC Track Change

    func handleFlacTitleChange(shortTitle: String) {
        if lastFlacTitle != shortTitle {
            #if DEBUG
            print("📋  FLAC TITLE changed: '\(lastFlacTitle ?? "(none)")' -> '\(shortTitle)'")
            #endif
            lastFlacTitle = shortTitle
            publishTitle(shortTitle)
            fetchIcecastMetadata()
        }
    }

    // MARK: - Parsing Helpers

    func parseICYTitle(_ raw: String) -> String? {
        if let start = raw.range(of: "StreamTitle='"),
           let end   = raw[start.upperBound...].range(of: "';") {
            let title = String(raw[start.upperBound..<end.lowerBound])
            return title.isEmpty ? nil : title
        }
        return nil
    }

    func extractVorbisTitle(_ ptr: UnsafePointer<CChar>) -> String? {
        var offset = ptr
        while offset.pointee != 0 {
            let tag = String(cString: offset)
            if tag.lowercased().hasPrefix("title=") {
                let val = String(tag.dropFirst(6))
                if !val.isEmpty { return val }
            }
            offset = offset.advanced(by: Int(strlen(offset)) + 1)
        }
        return nil
    }

    // MARK: - Publish

    func publishTitle(_ title: String) {
        #if DEBUG
        print("🎵  \(title)")
        #endif

        // Journal every track change with its recording timestamp so DVR playback can
        // replay track info at the correct position.  All journal mutations run on the
        // main thread to keep reads (DVR timer, also main) data-race-free.
        if let buffer = streamBuffer {
            let ts = buffer.currentTimestamp
            DispatchQueue.main.async { self.dvrMetadataJournal.append((timestamp: ts, metadata: title)) }
        }

        // In DVR mode the live metadata is NOT what the user is hearing.
        // Suppress live updates; the DVR metadata timer publishes historical track info.
        guard dvrState == .live else { return }

        // Only fire callback if title actually changed (dedup repeated polls)
        guard title != lastPublishedTitle else { return }
        lastPublishedTitle = title
        DispatchQueue.main.async {
            self.isPlaying = true
            self.onMetadataUpdate?(title)
        }
    }
}
