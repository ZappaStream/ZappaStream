# DVR Ring Buffer Hardening (Tier-1) — fix "5–10s buffer + confused resume"

## Context

On-the-go iPhone use: pause via AirPods removal / lock screen, return hours–days later →
transport shows only ~5–10s buffered, and play seems confused between the buffer sliver and
live. Root-caused (2026-07-29, main @ 552f450) to a chain of pre-existing defects — no recent
regression. User decisions (final): **tier-1 hardening** of the existing silent-player
keepalive + recording pump (the tier-2 mixer-keepalive redesign stays deferred), and stale
resumes should **go straight to live** (healthy pauses keep buffer-first resume unchanged).

## Root cause chain (verified in code)

1. AirPods removal is handled correctly: `handleHeadphoneRemoval` (`PlaybackController.swift:659`)
   → `dvrPause()` (`BASSRadioPlayer+DVR.swift:71`) → output mixer paused, 100ms recording pump
   started, silent-AVAudioPlayer keepalive started via the dvrState observer
   (`PlaybackController.swift:494-496`).
2. **Keepalive is fragile**: `startSilenceKeepalive()` guards `silenceKeepalivePlayer == nil`
   (`BASSRadioPlayer+Playback.swift:922`) — any audio interruption (call/Siri/other app) stops
   the player without nil-ing it, permanently blocking restart; interruption-`.ended`
   (`PlaybackController.swift:645-656`) never re-arms it; `play()` result unchecked (`:941`).
3. Dead keepalive → iOS suspends the app ~5–10s after audio stops → pump freezes →
   `bufferedDuration` flatlines. StreamBuffer's in-memory ring (~5.94s) drains → UI shows
   `behindLiveSeconds = bufferedDuration − dvrPauseTimestamp` ≈ 5–10s frozen. **The symptom.**
4. `dvrResume()` (`+DVR.swift:176`) stops pump (`:186`) + keepalive (`:188`) **before**
   `createPlaybackStream` (`:191`); failure (`:196`) bare-returns → self-latched dead state.
5. Successful resume on a stale sliver: plays 5–10s → end → `continueDVRFrom` retries ~5.5s →
   falls to `goLive()` — the "confused" feel. No staleness check exists.
6. Secondary: `handleDVRBufferFull` (`:352`) never stops the pump; pre-mixer has
   `BASS_MIXER_END` with no end-detection in the pump; pump buffer is exactly 100ms (zero
   headroom, `BASSRadioPlayer.swift:184`); no launch sweep of stale `zappastream_dvr_seg_*.wav`
   (~300MB after force-quit); **latent bug found during planning**: `goLive()` on the normal
   (non-bufferFull) path never calls `clearStopBeforeSegment()` — a pause → Go Live leaves the
   ring armed to silently stop recording when it wraps to that segment later in the session.

## Implementation — branch `feature/dvr-buffer-hardening`, 5 commits

New stored state on `BASSRadioPlayer` (near the DVR block ~:356-402):
`dvrPauseBufferedAtPause: Double` (snapshot at pause), `dvrPumpDeadTickCount: Int`,
`dvrPumpLastRecoveryAttempt: TimeInterval`, `#if os(iOS)` `silenceKeepaliveRetryCount: Int`.
Existing `dvrPauseWallTime` (set in `startBehindTimer()`, `+DVR.swift:384`) supplies wall time.

### Commit 1 — `Fix(dvr): sweep stale buffer segment files at launch; prefix-based cleanup`
- `StreamBuffer.swift`: add `static func sweepStaleSegmentFiles()` deleting every
  `zappastream_dvr_seg_*.wav` in the temp dir by **prefix match** (catches indices orphaned by
  a lowered `dvrBufferMinutes`); rewrite `cleanup()` (`:111-115`) to use it.
- `BASSRadioPlayer.swift` `init()`: call sweep on `.utility` global queue, guarded by the
  existing `XCTestBundlePath` env pattern (see `PlaybackController.swift:92`) so
  `StreamBufferTests` stay deterministic. Player is created once at app scope before any
  StreamBuffer exists — nothing to race.
- Unit test in `StreamBufferTests`: dummy segment files + unrelated file → only segments swept.

### Commit 2 — `Fix(dvr): pure stale-resume decision in BASSRadioPlayerLogic + tests`
- `BASSRadioPlayerLogic.swift` (next to `behindLivePaused`, `:228`): add
  `enum DVRResumeAction { case resumeFromBuffer, goLiveStale }` and
  `dvrResumeAction(wallSecondsSincePause:recordedSecondsSincePause:bufferIsFull:...)`.
  Stale iff `wall − recorded > 120s` **AND** `recorded < 0.5 × wall`; `bufferIsFull == true`
  always returns `.resumeFromBuffer` (a full buffer legitimately stopped recording — keep the
  existing offer/drain flow). The AND keeps overnight flaky-network pauses (large valid buffer,
  small ratio loss) resumable while catching the frozen-pump case (seconds recorded vs hours).
- Unit tests in `BASSRadioPlayerLogicTests`: frozen-pump, flaky-overnight, short-pause-freeze,
  boundaries, bufferFull override, negative-input clamps (~8 cases).

### Commit 3 — `Fix(player): stale buffer resumes straight to live; failed resume no longer latches`
All in `BASSRadioPlayer+DVR.swift`:
- **`dvrResume()`**:
  1. Staleness gate at top (after the `.paused` guard): compute
     `wall = Date().timeIntervalSince(dvrPauseWallTime)`,
     `recorded = max(0, buffer.bufferedDuration − dvrPauseBufferedAtPause)`; if
     `.goLiveStale` → `logDVRDiag("resume-stale")`, `goLive(forceFullRestart: true)`, return.
  2. Move `stopDVRRecordingPump()` / `stopSilenceKeepalive()` / the
     `dvrFullBufferDrainStarted` set to **after** the `createPlaybackStream` guard succeeds
     (before `BASS_ChannelPlay(mixerHandle, 0)` so pump and mixer never double-pull).
  3. Failure branch (`:196`): replace bare return with `logDVRDiag("resume-failed")` +
     `goLive()` — the buffer is unplayable; live is strictly better than the latched dead state.
- **`goLive()`** → `goLive(forceFullRestart: Bool = false)` (all call sites compile unchanged):
  include `forceFullRestart` in the buffer-recreate condition (`:314`) and the full-restart
  condition (`:325`) — stale resume discards the sliver and does `restartStream()` (the live
  BASS stream is dead after hours suspended; the fade-in path would produce silence).
- **Latent-bug fix**: in `goLive()`'s non-bufferFull path add `streamBuffer?.clearStopBeforeSegment()`.
- `dvrPause()` / `dvrPausePlayback()`: snapshot `dvrPauseBufferedAtPause`.
- Gate lives inside `dvrResume()` → automatically covers every entry point (remote commands
  `PlaybackController.swift:218/:250/:293`, `resumeOrOfferBuffer()`, both ContentViews).
  No user-facing text added (and never say "DVR" in UI).

### Commit 4 — `Fix(player): background buffer recording survives interruptions and route changes`
iOS-only (`#if os(iOS)` / PlaybackController):
- `startSilenceKeepalive()` (`+Playback.swift:921`): exists-AND-playing guard (stop + nil a
  stopped player, then recreate); keep the `!isAppInForeground` guard (`:928`) — load-bearing.
  Check `play()` result; on failure best-effort `setActive(true)` + up to 3 retries at 1s
  (guarded on still `.paused` + backgrounded); `logDVRDiag("keepalive-start")` on success.
  `stopSilenceKeepalive()` resets the retry counter.
- `handleAudioInterruption` `.ended` (`PlaybackController.swift:645`): inside the
  `.shouldResume` branch, re-arm keepalive when `dvrState == .paused && !isAppInForeground`.
  Deliberately NOT re-armed without `.shouldResume` (user chose other audio; reactivating our
  non-mixable session would interrupt it — the Commit 3 stale gate degrades gracefully).
  Keep `triggerImmediateReconnect()` while paused (it routes to buffer-preserving
  `partialRestartLiveChannel()` and restores recording after a call) but skip it when
  `dvrState == .paused && dvrBufferFull` (recording intentionally over; comment the reasoning).
- `handleHeadphoneRemoval` `case .paused` and end of `handleBluetoothReconnect`: re-check
  keepalive when backgrounded (a route change while already background-paused can stop the player).
- **Periodic health check** piggybacked on the pump: every ~100 ticks (~10s), main-queue check —
  backgrounded + `.paused` + keepalive not playing → `startSilenceKeepalive()` +
  `logDVRDiag("keepalive-rearm")`. Covers AVAudioPlayer deaths with no notification; costs one
  main-hop per 10s. Promote the DEBUG `dvrPumpTickCount` to non-DEBUG for the counter.

### Commit 5 — `Fix(player): recording pump detects a dead source and recovers; full buffer stops the pump`
- `handleDVRBufferFull` (`+DVR.swift:352`): add `stopDVRRecordingPump()`. Do NOT stop the
  keepalive (it keeps the lock-screen play affordance alive for the offer). Keep
  `stopMetadataPolling()` — re-evaluated: with the download channel intentionally paused the
  staleness watchdog would only false-positive; comment this.
- Pump end-detection in `startDVRRecordingPump()`'s tick (`+DVR.swift:769-786`): after the
  `BASS_ChannelGetData` pull, check `BASS_ChannelIsActive(preMixerHandle)`; 10 consecutive
  STOPPED ticks (~1s) + ≥15s since last attempt (`systemUptime`) + `!isReconnecting` →
  `bassPollingQueue.async { partialRestartLiveChannel() }` (same queue as the existing
  `checkStreamStatus` callers; it already leaves the mixer paused while `.paused`). Pump reads
  `preMixerHandle` fresh each tick so it picks up the rebuilt handle.
- Pump headroom (`BASSRadioPlayer.swift:184`): buffer 35280 → 70560 bytes (200ms) so a jittered
  tick can catch up instead of drifting permanently behind wall clock.

## Verification (manual on-device is the real gate; DEBUG build, watch `logDVRDiag`)

1. **Baseline regression**: play OGG on AirPods → remove one → lock phone. Expect
   `→background keepalive=playing`, `paused-tick` climbing ~1s/s for ≥30 min, no pump-gap
   warnings. Lock-screen play → buffer-first resume as today (no `resume-stale`).
2. **Interruption recovery**: while background-paused, take a phone call / invoke Siri →
   after it ends expect `keepalive-start`/`keepalive-rearm` and `buffered` climbing again
   (pre-fix: `keepalive=stopped` forever).
3. **The user's scenario (stale → live)**: background-paused, play Music app (keepalive dies,
   no `.shouldResume`), wait >10 min, lock-screen play → expect `resume-stale` then clean
   `📡 DVR → LIVE (full restart)`; no sliver, no retry storm.
4. **Full-buffer flow unchanged**: 5-min buffer, pause until `📼 DVR buffer full` (confirm pump
   stops), wait, in-app play → offer alert → "Play Buffer" drains normally.
5. **Pre-mixer end recovery**: pause, Airplane Mode ~60s → expect throttled
   `pump-dead → partial restart`; disable → recording resumes.
6. **Launch sweep**: pause → force-quit → relaunch → no `zappastream_dvr_seg_*.wav` in tmp;
   also lower buffer minutes 30→5 and confirm high indices removed.
7. **Go-Live latent bug**: pause ~1 min → Go Live → keep playing past a full buffer window →
   a later pause still records (pre-fix: silently frozen).
8. **macOS regression**: build + run macOS (shared changes are inert there: stale gate never
   trips since wall≈recorded; keepalive code is iOS-only). Run `UncleStreamusTests`
   (`xcodebuild test -scheme UncleStreamus -destination 'platform=macOS'` via XcodeBuildMCP).

Unit tests: `dvrResumeAction` (Commit 2) and the sweep/cleanup (Commit 1); everything else is
BASS/hardware-bound.

## Files touched
- `UncleStreamus/BASSRadioPlayer+DVR.swift` (resume gate/reorder, goLive param + latent fix,
  bufferFull pump stop, pump end-detection + health check)
- `UncleStreamus/PlaybackController.swift` (interruption re-arm, route-change re-check)
- `UncleStreamus/BASSRadioPlayer+Playback.swift` (keepalive hardening)
- `UncleStreamus/BASSRadioPlayer.swift` (new state, pump buffer size, init sweep call)
- `UncleStreamus/BASSRadioPlayerLogic.swift` + `BASSRadioPlayerLogicTests` (stale predicate)
- `UncleStreamus/StreamBuffer.swift` + `StreamBufferTests` (sweep)

## Out of scope (deliberately)
- Tier-2 mixer-keepalive redesign — stays deferred on `feature/dvr-mixer-keepalive`.
- AAC metadata lag in buffer playback — documented WON'T FIX.
- Full-buffer countdown drain behavior — confirmed intended.
