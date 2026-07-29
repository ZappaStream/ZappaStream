import Foundation
import Network
#if os(macOS)
import Bass
import BassFLAC
import BassFX
import BassMix
#else
import UIKit
import AVFoundation
#endif
// On iOS: BASS symbols are globally available via BASSBridgingHeader.h

// MARK: - Playback State

enum PlaybackState: Equatable {
    case stopped
    case connecting
    case playing
    case buffering
    case stalled
    case error(Int32)
}

// MARK: - BASS Audio Constants

/// Centralized BASS engine constants that were previously repeated as literals
/// across the playback/DVR/init paths. Same values, named once — no behavior change.
enum BASSConfig {
    /// Mixer sample rate (Hz). Matches the stream/output sample rate.
    static let sampleRate: DWORD = 44100
    /// Stereo channel count for the mixers.
    static let channels: DWORD = 2
    /// Network download buffer (ms) for normal streams.
    static let netBufferMs: DWORD = 25000
    /// Larger network buffer (ms) used while creating the FLAC stream.
    static let netBufferMsFLAC: DWORD = 30000
    /// Default network read timeout (ms).
    static let netTimeoutMs: DWORD = 10000
    /// Short network timeout (ms) used so a stalled read fails fast instead of
    /// blocking the polling queue for the full default.
    static let netTimeoutFastMs: DWORD = 3000
}

// MARK: - BASSRadioPlayer

@Observable class BASSRadioPlayer: NSObject {

    // MARK: - Constants

    /// User-Agent header for HTTP requests to identify the app to servers
    static let userAgentString: String = {
        #if os(macOS)
        let platform = "macOS"
        #else
        let platform = "iOS"
        #endif
        return "UncleStreamus/1.0 (\(platform))"
    }()

    // MARK: - Public Interface

    /// Raw metadata string callback — same format as the old IcecastStreamReader callback.
    /// Called on main thread. UncleStreamus uses this to drive ParsedTrackInfo parsing.
    var onMetadataUpdate: ((String) -> Void)?

    var isPlaying: Bool = false
    var playbackState: PlaybackState = .stopped

    /// Currently active format ("MP3", "OGG", "AAC", "FLAC")
    var currentQuality: String = ""

    /// Show date of the currently playing show; set by ContentView on every show load.
    /// Used by saveFXToDefaults() to write per-show FX snapshots.
    var currentShowDate: String? = nil

    /// AAC only: armed when the metadata reaches the last setlist track, meaning the
    /// next track change (AAC restarts the stream every track) crosses into a new show.
    /// On the next `restartStream()` we reset FX to defaults early, beating the
    /// metadata lag that otherwise lets the old show's FX bleed over the new audio.
    var pendingAACShowChangeReset = false

    /// Transient guard so a programmatic non-persisting FX reset doesn't write to the
    /// old show's per-show snapshot during the AAC metadata-lag window.
    var suppressPerShowSave = false

    /// AAC carry-over window: true between the early FX reset firing and the incoming
    /// show's fetch resolving. While active, FX edits belong to the INCOMING show.
    var aacCarryoverActive = false
    /// Whether the user adjusted FX during the carry-over window (gates carry-over —
    /// if they touched nothing, the incoming show is handled normally).
    var aacCarryoverFXAdjusted = false

    // MARK: - BASS Handles

    var streamHandle: DWORD = 0
    var mixerHandle: DWORD = 0
    var preMixerHandle: DWORD = 0  // All formats: DECODE-mode pre-mixer; stutter buffer (3s FLAC, 0.3s others) + click guard
    var preBufferProgress: Double = 0.0    // 0.0–1.0 during FLAC pre-buffer; drives UI progress bar
    var preBufferTimer: Timer?     // updates preBufferProgress every 100ms during FLAC pre-buffer wait
    var stallSync: HSYNC = 0
    var endSync: HSYNC = 0
    var oggChangeSync: HSYNC = 0
    var metaChangeSync: HSYNC = 0

    // MARK: - Metadata State

    var activeFormat = ""
    var lastFlacTitle: String?
    var lastOGGVorbisTitle: String?
    var lastIcecastTitle: String?
    var lastPublishedTitle: String?
    var oggStopConfirmed = false

    // MARK: - Timers

    var metadataTimer: Timer?
    var stateTimer: Timer?
    var fadeTimer: Timer?
    var fadeGeneration: Int = 0   // incremented by cancelFade(); guards stale async dispatches
    let bassPollingQueue = DispatchQueue(label: "com.unclestreamus.bass-polling", qos: .utility)
    let metaPollInterval: TimeInterval = 3.0
    let statePollInterval: TimeInterval = 2.0
    let fadeInDuration: TimeInterval = 0.5
    let fadeOutDuration: TimeInterval = 0.4

    // MARK: - Network Resilience

    var pathMonitor: NWPathMonitor?
    let networkMonitorQueue = DispatchQueue(label: "com.unclestreamus.network-monitor", qos: .utility)

    /// Background task token used on iOS to keep the app alive during reconnect
    /// after audio output stops (network loss while locked).
    #if os(iOS)
    var bgReconnectTask: UIBackgroundTaskIdentifier = .invalid
    /// Background task token used on iOS to keep the app alive during the FLAC
    /// pre-buffer window, before BASS_ChannelPlay starts the audio unit.
    var bgFlacPrebufTask: UIBackgroundTaskIdentifier = .invalid
    /// Silent looping AVAudioPlayer that keeps the AVAudioSession active while reconnecting.
    /// iOS will not suspend an app with an active .playback session producing audio output,
    /// even at volume 0.0 — so this prevents suspension during tunnels > ~30s.
    var silenceKeepalivePlayer: AVAudioPlayer?
    #endif

    /// Incremented by freeStream() each time handles are torn down. Captured by restartStream()
    /// before the blocking BASS_StreamCreateURL call and checked afterward — if another
    /// freeStream() ran concurrently (concurrent restarts from different queues), the generation
    /// will have changed and the stale handle is discarded instead of overwriting a live stream.
    var streamGeneration: Int = 0

    /// Last decode byte position seen in checkStreamStatus(). Used to detect streams that BASS
    /// keeps in PLAYING state but where decode has frozen (e.g. AAC AudioToolbox ReadBytes loop).
    var lastKnownStreamBytes: UInt64 = 0
    /// systemUptime when lastKnownStreamBytes last changed. Zero until the stream first decodes data.
    var lastPositionAdvanceTime: TimeInterval = 0

    /// True only while the user intends playback to be active.
    /// Set true in switchQuality(); false only in stop() / stopWithFadeOut().
    /// freeStream() and restartStream() must NOT touch this.
    var isUserIntendedPlay: Bool = false

    #if os(iOS)
    /// Tracks whether the app is in the foreground (`scenePhase == .active`). Updated from
    /// ContentView_iOS's scenePhase handler. Used to suppress the silence keepalive in the
    /// foreground, where it is unnecessary (foreground apps are never suspended) and harmful
    /// (active silent audio makes iOS route the AirPods/lock-screen button to pauseCommand).
    var isAppInForeground = true
    #endif

    /// Timestamp of the last user-initiated play or stop. Used to debounce rapid double-taps.
    private var lastUserActionTime: Date = .distantPast

    /// True while a reconnect attempt is scheduled or in-flight (drives UI).
    var isReconnecting: Bool = false

    /// Current attempt number (1-based). Reset to 0 on success or explicit stop.
    var reconnectAttempt: Int = 0

    var reconnectTimer: DispatchSourceTimer?

    // Pumps the decode-only pre-mixer while the output mixer is paused during DVR pause.
    // Keeps the recording DSP firing so WAV segments continue to be written to disk.
    var dvrRecordingPumpSource: DispatchSourceTimer?
    var dvrRecordingPumpBuf = [UInt8](repeating: 0, count: 35280) // 100ms at 44.1kHz stereo float32

    #if DEBUG
    // Diagnostics for the DVR background-recording investigation (see plan
    // cosmic-doodling-sifakis). Track recording-pump liveness so we can detect when iOS
    // suspended the app (pump gap) vs the stream stalling. Reset each time the pump starts.
    var dvrPumpLastTick: Date = .distantPast
    var dvrPumpTickCount: Int = 0
    #endif

    // 3s retry interval, giving up after 12 attempts (~1 minute total).
    let reconnectRetryInterval: TimeInterval = 3
    let reconnectMaxAttempts: Int = 12
    /// How long to run FLAC muted before unmuting, giving the mixer output buffer time to fill.
    /// FLAC fade-in is triggered by checkStreamStatus() when playback buffer is sufficiently filled,
    /// not by a fixed timer. This flag tracks whether we're waiting for that condition.
    var flacPendingFadeIn = false

    // MARK: - Stream URLs

    let qualities: [(format: String, url: String)] = [
        ("MP3",       "https://shoutcast.norbert.de/zappa.mp3"),
        ("OGG",       "https://shoutcast.norbert.de/zappa.ogg"),
        ("AAC",       "https://shoutcast.norbert.de/zappa.aac"),
        ("FLAC",      "https://shoutcast.norbert.de/zappa.flac"),
    ]

    // MARK: - Audio Effects

    var eqLowFX:  HFX = 0   // BASS_BFX_BQF_LOWSHELF  @ 90 Hz
    var eqMidFX:  HFX = 0   // BASS_BFX_BQF_PEAKINGEQ @ 2700 Hz
    var eqHighFX: HFX = 0   // BASS_BFX_BQF_HIGHSHELF @ 7500 Hz
    var compressorFX: HFX = 0
    var levelMeterDSP: HDSP = 0
    var stereoDSP: HDSP = 0
    var limiterDSP: HDSP = 0
    var clickGuardDSP: HDSP = 0
    var inputGainDSP: HDSP = 0
    var subBassDSP: HDSP = 0

    // MARK: - Click Guard (OGG/FLAC/MP3)
    // OGG/FLAC: BASS_SYNC_OGG_CHANGE (MIXTIME) fires at bitstream boundaries — sample-accurate.
    //   Guard = silence (1 buf ~20ms) + fade-in (2 bufs ~40ms) = ~60ms total.
    // MP3: BASS_SYNC_META (MIXTIME) fires on ICY metadata change — NOT sample-accurate.
    //   Two-phase guard:
    //   Phase 1 — Immediate gate: 1 silence buf + 2 fade-in bufs (~60ms total) fires the moment
    //     SYNC triggers, covering subtle artifacts (MDCT overlap, DC step) near the metadata
    //     position. These produce spikes ≤2.0 and can't be reliably detected; the unconditional
    //     gate is the only safe approach (same strategy as OGG/FLAC).
    //   Phase 2 — Post-gate scan: after the initial gate completes, a 600ms scan window watches
    //     for late-arriving detectable artifacts (spike > 4.0 via max|d2|/RMS). When one is
    //     found, a second identical gate fires. If nothing is found, scan expires silently.
    //   Together these cover both immediate-position artifacts and late-arriving MDCT splices.
    // AAC: no click guard.
    var lastMetaSyncTitle: String?    // tracks last ICY title seen by BASS_SYNC_META callback
    let cgFadeBufferCount    = 1      // OGG/FLAC/MP3 fade-in buffers (~20ms)
    let cgSilenceBufferCount = 1      // OGG/FLAC/MP3 silent buffers: buf 1 = fade-out (~20ms); no hard-zero (scan catches late splices)
    var cgFadeBuffersRemaining: Int = 0   // gate buffers remaining (OGG/FLAC/MP3 shared)
    var cgMP3ScanActive: Bool       = false
    var cgMP3ScanEnd:    Double     = 0   // systemUptime when scan expires
    var cgMP3ScanEMA:    Float      = 0   // EMA of D2 spike values (primed at 1.0 on arm)
    var cgMP3ScanRMSEMA: Float      = 0   // EMA of per-buffer RMS (primed at 1.0 on arm)
    var cgScanPrevL:     Float      = 0   // last L sample of previous scan buffer (cross-buffer d2)
    var cgScanPrevPrevL: Float      = 0   // second-to-last L sample (cross-buffer d2)
    var cgMP3SpikeCount: Int        = 0   // consecutive scan buffers with spike > 1.0 (sustained detector)
    var cgSyncTime:      Double     = 0   // systemUptime when SYNC fired (for logging)
    var cgLastGuardTime: Double     = 0   // debounce: systemUptime of last armed guard

    // MARK: - FLAC Download Buffer Refill Pause
    // When dlBuf falls below a threshold at a track boundary, freeze the stream channel
    // inside the pre-mixer so the download buffer can refill without interrupting recording.
    let bufferRefillThreshold: Double   = 4.0   // dlBuf% below which to trigger
    let bufferRefillTrackInterval: Int  = 3     // minimum track changes between pauses
    let bufferRefillDuration: TimeInterval = 2.5 // must stay < 3.0s (FLAC pre-mixer buffer) to avoid recording gaps
    var trackChangeCount: Int           = 0
    var isRefillPausing: Bool           = false

    // MARK: - FLAC Network Recovery
    // When dlBuf drops below 20% while playing FLAC, a recovery stream is pre-created
    // so it can start downloading while the old buffer plays out. When the old stream
    // goes STOPPED, the recovery stream is activated in-place (no 10s pre-buffer).
    var recoveryStreamHandle: DWORD = 0
    var isAttemptingRecovery: Bool  = false
    var recoveryStartTime: TimeInterval? = nil
    /// True while the recovery stream's download ring buffer is filling back up after a network
    /// drop. The recovery stream is paused (BASS_MIXER_CHAN_PAUSE) in the pre-mixer so no data
    /// is consumed until the buffer reaches the target threshold, matching initial-connect behaviour.
    var flacRebufferingAfterRecovery = false

    var eqLowGain:  Float = 0
    var eqMidGain:  Float = 0
    var eqHighGain: Float = 0

    // MARK: - Master Volume

    var masterVolume: Float = {
        guard UserDefaults.standard.object(forKey: "masterVolume") != nil else { return 1.0 }
        return UserDefaults.standard.float(forKey: "masterVolume")
    }()

    func setMasterVolume(_ volume: Float) {
        masterVolume = max(0.0, min(1.0, volume))
        UserDefaults.standard.set(masterVolume, forKey: "masterVolume")
        if bassInitialized {
            BASS_SetConfig(DWORD(BASS_CONFIG_GVOL_STREAM), DWORD(masterVolume * 10000))
        }
    }

    func volumeUp() { setMasterVolume(masterVolume + 0.1) }
    func volumeDown() { setMasterVolume(masterVolume - 0.1) }

    var compressorOn:     Bool  = false
    var compressorAmount: Float = 0.25

    // MARK: - Adaptive Compressor (program-dependent threshold)
    // A level-measurement DSP computes a slow-moving RMS average of the input signal.
    // The compressor threshold is set relative to this average, so it compresses
    // proportionally regardless of whether the track is quiet or loud.
    var measuredRMSdB: Float = -20.0       // Current program level (dBFS), slow-moving
    var rmsAccumulator: Float = 0.0        // Running sum-of-squares for current window
    var rmsSampleCount: Int = 0            // Samples accumulated so far
    let rmsWindowSamples: Int = 66150      // ~1.5s window @ 44.1 kHz (stereo frames)
    var lastAppliedThreshold: Float = 0.0  // Avoid redundant BASS_FXSetParameters calls

    var stereoWidth: Float = 0.75
    var stereoPan:   Float = 0.5

    var eqEnabled:          Bool = true
    var stereoWidthEnabled: Bool = true
    var masterBypassEnabled: Bool = false

    // MARK: - Stereo DSP Parameter Smoothing
    // Per-buffer exponential smoothing with linear interpolation within each buffer
    // prevents pops/clicks from abrupt parameter jumps at buffer boundaries.
    var smoothedStereoCoeff: Float = 1.0   // Tracks stereoWidthCoeff
    var smoothedPanOffset:   Float = 0.0   // Tracks (stereoPan - 0.5) * 2.0

    // MARK: - Frequency-Dependent Stereo Processing (400 Hz and 3.5 kHz crossovers)
    var centerSpreadLPFState:  Float = 0.0  // Low-pass filter state for mono center channel
    var sideChannelLPFState:   Float = 0.0  // Low-pass filter state for side channel (low/mid crossover ~400 Hz)
    var sideChannelMidLPFState: Float = 0.0 // Low-pass filter state for side channel (mid/high crossover ~3.5 kHz)
    let centerSpreadCrossoverHz: Float = 400.0
    // alpha = 2*pi*f / (2*pi*f + sr) ≈ 0.0556 for 400 Hz @ 44.1 kHz
    let centerSpreadLPFAlpha: Float = 0.0556
    // alpha = 2*pi*3500 / (2*pi*3500 + 44100) ≈ 0.333 for 3.5 kHz @ 44.1 kHz
    let sideChannelMidLPFAlpha: Float = 0.333

    // MARK: - Mono Stereo Synthesis (2-stage APF cascade for broad phase coverage)
    // Two APF stages in series (both g = -0.75) double the phase accumulation,
    // shifting the 90° crossover from ~5 kHz to ~2.5 kHz (centre of the audible band).
    // Above ~5 kHz the cascade exceeds 180°, biasing slightly right — balancing the
    // below-2.5 kHz left bias. Net result: much more even spread L and R across typical music.
    // Classic L+=, R-= M/S synthesis is retained; the cascade output drives both.
    var synthAPFInput:   Float = 0.0   // Stage 1 x[n-1]
    var synthAPFOutput:  Float = 0.0   // Stage 1 y[n-1]
    var synthAPF2Input:  Float = 0.0   // Stage 2 x[n-1]
    var synthAPF2Output: Float = 0.0   // Stage 2 y[n-1]
    var smoothedMonoFraction: Float = 0.0  // Per-buffer mono detection (0=stereo, 1=mono)
    let synthAPFCoeff: Float = -0.75   // APF coefficient for both stages
    // High-pass filter applied to M before the APF cascade — shapes widening by frequency:
    //   < 100 Hz → −12 dB (barely spread)   ~400 Hz → −3 dB (somewhat)   > 1 kHz → < −1 dB (most)
    // α = fs / (fs + 2π·fc) = 44100 / (44100 + 2π·400) ≈ 0.946
    var synthHPFInput:  Float = 0.0
    var synthHPFOutput: Float = 0.0
    let synthHPFAlpha:  Float = 0.9461

    // MARK: - Center Spread APF (symmetric high-freq spread for right channel)
    // R channel gets APF-shifted M_highFreq rather than -M_highFreq so it also
    // gains high-frequency content (decorrelated from L) instead of losing it.
    var spreadAPFInput:  Float = 0.0
    var spreadAPFOutput: Float = 0.0

    // MARK: - DVR
    // macOS only at runtime; properties must be unconditionally declared so @Observable
    // macro can generate correct accessor code (macro-expanded files have no #if guards).

    enum DVRState { case live, paused, playing }

    /// Current DVR mode. `.live` = normal streaming, `.paused` = live stream muted
    /// while recording continues, `.playing` = playing back from WAV ring buffer.
    /// Always `.live` on iOS (DVR feature not implemented there yet).
    var dvrState: DVRState = .live

    /// How many seconds behind live the current DVR playback position is.
    var behindLiveSeconds: TimeInterval = 0

    var streamBuffer:       StreamBuffer?  = nil
    var recordingDSP:       DWORD          = 0
    var dvrPlaybackStream:  DWORD          = 0
    var dvrNextStream:      DWORD          = 0   // pre-loaded next segment (gapless)
    var dvrPausedStreams:   [DWORD]        = []  // streams kept alive during dvrPausePlayback() fade-out
    var dvrPauseTimestamp:  Double         = 0
    var dvrPauseWallTime:   Date           = .distantPast  // wall clock when DVR was (re-)paused
    /// `streamBuffer.bufferedDuration` at the moment of the pause. Subtracting it from the
    /// current value gives how much was actually recorded while paused, which compared against
    /// elapsed wall time is what detects a frozen recording pump (see `dvrResume()`).
    var dvrPauseBufferedAtPause: Double    = 0
    var dvrPauseOffset:     Double         = 0             // behindLiveSeconds at the moment of pause
    var dvrCurrentSegNum:   Int            = 0
    var dvrNextSegNum:      Int            = 0
    var dvrBehindTimer:     Timer?         = nil

    // DVR metadata journal — maps recording timestamps to raw metadata strings.
    // Populated by publishTitle() during live streaming; consulted during DVR playback
    // to replay track-change notifications at the correct recorded position.
    // All reads/writes happen on the main thread (append dispatched from publishTitle).
    var dvrMetadataJournal: [(timestamp: Double, metadata: String)] = []
    var lastDVRPublishedMetadata: String? = nil
    var dvrMetadataTimer: Timer? = nil
    var dvrBufferFull: Bool = false        // set when recording fills the window
    /// Set true when the user presses play on a full, paused buffer, so the UI can offer
    /// "play the buffered audio or go live?". Cleared once the user chooses.
    var dvrReturnOfferPending: Bool = false
    /// One-shot guard: true once buffer playback has begun for the current full-buffer episode.
    /// Distinguishes the first play press after the buffer filled (offer the choice) from a
    /// mid-drain pause/resume (resume directly — no re-prompt), since both share dvrState == .paused.
    /// Set in dvrResume() when dvrBufferFull; reset wherever dvrBufferFull is reset (goLive/freeStream).
    var dvrFullBufferDrainStarted: Bool = false

    // Keeps DVREndSyncContext objects alive while BASS holds raw pointers to them.
    // Keys are DVR stream handles; values are the context objects. Entries removed
    // when the corresponding stream is freed (so objects outlive their BASS channels).
    var dvrSyncContexts: [DWORD: AnyObject] = [:]

    // MARK: - FX Blend (smooth on/off transitions)
    // Ramp blend 0→1 (passthrough→active) over ~83ms when toggling compressor/EQ or master bypass.
    // Prevents clicks/pops caused by abrupt compressor state jumps or filter coefficient changes.
    var compressorBlend: Float = 0.0     // 0 = passthrough, 1 = fully active
    var compressorBlendGoal: Float = 0.0 // desired target
    var eqBlend: Float = 1.0             // 0 = all bands at 0 dB, 1 = active gains
    var eqBlendGoal: Float = 1.0
    var fxRampTimer: Timer?

    // MARK: - Sub Bass (musical octave-down synthesis)
    // Single on/off effect that synthesises low-frequency depth for thin tape/AUD
    // sources. A band-pass isolates the existing bass fundamental (~90 Hz); a
    // zero-crossing divide-by-two follower generates a pitch-consonant tone one
    // octave below, gated by the band's envelope so it tracks the music and goes
    // silent when there's no bass. Hybrid voicing: the octave-down fundamental
    // (felt on good headphones/speakers) plus its low harmonics (perceived on
    // small phone speakers via the missing-fundamental effect). Internal gains are
    // fixed/subtle — no user slider. Output rides subBassBlend for click-free
    // toggling and is added equally to L+R (bass is centred). Inserted before the
    // limiter so peaks stay protected.
    var subBassEnabled: Bool   = false
    var subBassBlend: Float    = 0.0   // 0 = silent, 1 = fully mixed in
    var subBassBlendGoal: Float = 0.0
    // DSP state (single-threaded inside the BASS render callback)
    var subBassSVFLow:  Float = 0.0    // Chamberlin state-variable filter low state
    var subBassSVFBand: Float = 0.0    // ...band-pass state (≈72 Hz band)
    var subBassEnv:     Float = 0.0    // envelope follower on the band-pass output
    var subBassPolarity: Float = 1.0   // ±1 square, flips each rising zero-crossing
    var subBassPrevPositive: Bool = true
    var subBassLPAState: Float = 0.0   // ~70 Hz low-pass → octave-down fundamental
    var subBassLPBState: Float = 0.0   // ~200 Hz low-pass → fundamental + low harmonics
    // Fixed coefficients (44.1 kHz). f = 2·sin(π·fc/fs); LP α = 2π·fc/(2π·fc+fs).
    let subBassSVFf: Float        = 0.010258  // band-pass centre ≈72 Hz
    let subBassSVFq: Float        = 0.714     // 1/Q (Q ≈ 1.4) — narrow, focuses kick/bass
    let subBassEnvAttack: Float   = 0.0045    // ~5 ms
    let subBassEnvRelease: Float  = 0.00019   // ~120 ms
    let subBassLPAAlpha: Float    = 0.0099    // ~70 Hz
    let subBassLPBAlpha: Float    = 0.0281    // ~200 Hz
    let subBassFundGain: Float    = 0.8       // octave-down fundamental level
    let subBassHarmGain: Float    = 0.20      // harmonic-layer level
    let subBassOutputGain: Float  = 0.6       // overall subtle mix gain

    var stereoWidthCoeff: Float {
        // Below the "Original" snap (0.75): mono→original maps linearly to coeff 0→1.
        // Above it: the top quarter of the slider spans only 75% of the former widening
        // boost, so the slider maximum caps at coeff 1.75 instead of 2.0 (gentler widest).
        stereoWidth <= 0.75
            ? stereoWidth / 0.75
            : 1.0 + (stereoWidth - 0.75) / 0.25 * 0.75
    }

    /// Whether any FX unit is actively being used (not at default values).
    /// Returns true if FX Bypass is off AND at least one unit is "being used":
    /// - EQ: enabled AND at least one gain is not at 0 dB
    /// - Compressor: on (always counts as used when enabled)
    /// - Stereo: enabled AND at least one control is not at default (width ≠ 0.75 OR pan ≠ 0.5)
    var isFXBeingUsed: Bool {
        BASSRadioPlayerLogic.isFXBeingUsed(
            masterBypassEnabled: masterBypassEnabled,
            eqEnabled: eqEnabled, eqLowGain: eqLowGain, eqMidGain: eqMidGain, eqHighGain: eqHighGain,
            compressorOn: compressorOn,
            stereoWidthEnabled: stereoWidthEnabled, stereoWidth: stereoWidth, stereoPan: stereoPan,
            subBassEnabled: subBassEnabled)
    }

    // MARK: - Init / Deinit

    override init() {
        super.init()
        // BASS_Init is deferred to the first switchQuality() call (via initBASS()) so it runs
        // after configureAudioSession() has set .playback + .allowBluetoothA2DP. Running it
        // here — before the audio session is configured — causes BASS to open its RemoteIO
        // output unit against the default .soloAmbient session, producing garbled or misrouted
        // audio on AirPods when a new build is installed over a running one.
        startNetworkMonitoring()
        // Delete buffer segment WAVs orphaned by a previous run (a force-quit or crash while
        // recording leaves the whole ring on disk — up to ~300 MB). The player is created once
        // at app scope before any StreamBuffer exists, so there is nothing live to race with.
        // Skipped under XCTest so StreamBufferTests' own segment files stay deterministic.
        if ProcessInfo.processInfo.environment["XCTestBundlePath"] == nil {
            DispatchQueue.global(qos: .utility).async { StreamBuffer.sweepStaleSegmentFiles() }
        }
    }

    /// Initialize BASS against the current AVAudioSession. Called once from switchQuality()
    /// before any stream is created, guaranteeing the audio session is configured first.
    private var bassInitialized = false

    func initBASS() {
        guard !bassInitialized else { return }
        bassInitialized = true

        BASS_SetConfig(DWORD(BASS_CONFIG_UPDATEPERIOD), 20)
        BASS_SetConfig(DWORD(BASS_CONFIG_UPDATETHREADS), 2)
        BASS_SetConfig(DWORD(BASS_CONFIG_DEV_BUFFER), 500)
        BASS_SetConfig(DWORD(BASS_CONFIG_NET_BUFFER), BASSConfig.netBufferMs)
        BASS_SetConfig(DWORD(BASS_CONFIG_NET_PREBUF), 50)
        BASS_SetConfig(DWORD(BASS_CONFIG_NET_TIMEOUT), BASSConfig.netTimeoutMs)
        BASS_SetConfig(DWORD(BASS_CONFIG_BUFFER), 15000)
        #if os(iOS)
        BASS_SetConfig(DWORD(BASS_CONFIG_IOS_SESSION), DWORD(BASS_IOS_SESSION_DISABLE))
        #endif
        guard BASS_Init(-1, BASSConfig.sampleRate, 0, nil, nil) != 0 else {
            #if DEBUG
            print("❌  BASS_Init failed — error: \(BASS_ErrorGetCode())")
            #endif
            bassInitialized = false
            return
        }
        BASS_Start()
        BASS_SetConfig(DWORD(BASS_CONFIG_GVOL_STREAM), DWORD(masterVolume * 10000))
        #if DEBUG
        print("✅  BASS initialised")
        #endif

        let pluginPaths = ["bassflac", "libbassflac.dylib", "libbassflac"]
        for path in pluginPaths {
            let h = BASS_PluginLoad(path, 0)
            if h != 0 {
                #if DEBUG
                print("✅  FLAC plugin loaded via BASS_PluginLoad(\"\(path)\") — handle \(h)")
                #endif
                break
            }
        }
    }

    deinit {
        // Use the synchronous teardown only. `stop()` schedules `DispatchQueue.main.async`
        // closures that capture `self`; from `deinit` the refcount is already 0, so those
        // closures would dereference a freed object when the main queue drains
        // (EXC_BAD_ACCESS). The async hops exist solely to push @Observable UI-state updates
        // onto the main thread, which is meaningless for an object that's going away.
        stopSync()
        if bassInitialized { BASS_Free() }
    }

    // MARK: - Public Playback Interface

    /// Start playing the stream with the given format.
    /// `format` must be one of "MP3", "OGG", "AAC", "FLAC".
    /// `url` is accepted for API compatibility but the quality table is the source of truth.
    /// Returns true and records the timestamp if enough time has passed since the last user action.
    /// Call this once at the top of any user-initiated playback control (button, media key, etc.).
    /// If it returns false, discard the action entirely — do not update any UI state.
    func checkUserActionAllowed() -> Bool {
        let now = Date()
        let elapsed = now.timeIntervalSince(lastUserActionTime)
        #if DEBUG
        print("🔒 checkUserActionAllowed: elapsed=\(String(format: "%.4f", elapsed))s thread=\(Thread.isMainThread ? "main" : "bg") allowed=\(elapsed >= 0.8)")
        #endif
        guard elapsed >= 1.2 else { return false }
        lastUserActionTime = now
        return true
    }

    func play(format: String, url: String) {
        switchQuality(format)
    }

    /// Stop playback and reset state.
    func stop() {
        stopSync()
        // Push the @Observable UI-state resets onto the main thread for runtime callers
        // (which may invoke `stop()` off-main). Never call this path from `deinit` — see
        // `stopSync()` and the `deinit` comment.
        DispatchQueue.main.async {
            self.isReconnecting = false
            self.currentQuality = ""
            self.isPlaying = false
            self.playbackState = .stopped
        }
    }

    /// Synchronous teardown shared by `stop()` and `deinit`. Tears down timers, the stream,
    /// and resets non-UI bookkeeping without scheduling any async work that captures `self`,
    /// so it is safe to call while the object is being deallocated.
    private func stopSync() {
        isUserIntendedPlay = false
        cancelReconnectTimer()
        reconnectAttempt = 0
        #if os(iOS)
        endBackgroundReconnectTask()
        stopSilenceKeepalive()
        #endif
        freeStream()
        activeFormat = ""
        lastIcecastTitle = nil
        lastPublishedTitle = nil
        lastFlacTitle = nil
        // Close any open AAC carry-over window so it can't leak into a later show.
        aacCarryoverActive = false
        aacCarryoverFXAdjusted = false
    }

    /// Stop playback with a fade-out effect (user-initiated stop only).
    func stopWithFadeOut() {
        isUserIntendedPlay = false
        cancelReconnectTimer()
        reconnectAttempt = 0
        DispatchQueue.main.async { self.isReconnecting = false }
        let ph = playbackHandle
        guard ph != 0 else { stop(); return }
        startFadeOut(mixer: ph) { [weak self] in
            self?.stop()
        }
    }

    /// Public entry point for ContentViews to request an immediate reconnect
    /// (e.g., foreground resume, AVAudioSession interruption end, macOS wake).
    func triggerImmediateReconnect() {
        guard isUserIntendedPlay else { return }
        #if DEBUG
        print("🔄 triggerImmediateReconnect called")
        #endif
        cancelReconnectTimer()
        reconnectAttempt = 0
        DispatchQueue.main.async { self.isReconnecting = true }
        bassPollingQueue.async { [weak self] in
            guard let self = self else { return }
            // Skip if stream is already active and playing — avoids disrupting a healthy
            // stream or double-restarting when both scenePhase and NWPathMonitor fire together.
            if self.isStreamActive && BASS_ChannelIsActive(self.streamHandle) == DWORD(BASS_ACTIVE_PLAYING) {
                // For FLAC: use the network-change signal as the earliest possible trigger to
                // pre-create a recovery stream in the background. This gives it the full remaining
                // download-buffer lifetime (e.g. ~8s at dlBuf=32%) to refill before we need it,
                // minimising the rebuffer wait after the old stream drains.
                if self.activeFormat == "FLAC", !self.isAttemptingRecovery, self.recoveryStreamHandle == 0,
                   !self.flacRebufferingAfterRecovery {
                    #if DEBUG
                    print("🔄 triggerImmediateReconnect: FLAC stream playing — pre-starting recovery stream")
                    #endif
                    self.isAttemptingRecovery = true
                    self.recoveryStartTime = ProcessInfo.processInfo.systemUptime
                    self.startFlacRecovery()
                } else {
                    #if DEBUG
                    print("🔄 triggerImmediateReconnect: stream already playing — skipping")
                    #endif
                }
                DispatchQueue.main.async { self.isReconnecting = false }
                return
            }
            // If FLAC recovery is already in progress (stream stalled/stopped while recovery
            // stream is downloading or rebuffering), don't disrupt it with a full restart —
            // the STOPPED handler and rebuffer logic will complete the handoff.
            if self.activeFormat == "FLAC",
               self.isAttemptingRecovery || self.recoveryStreamHandle != 0 || self.flacRebufferingAfterRecovery {
                #if DEBUG
                print("🔄 triggerImmediateReconnect: FLAC recovery in progress — skipping restart")
                #endif
                DispatchQueue.main.async { self.isReconnecting = false }
                return
            }
            // Preserve the DVR ring buffer and playback state when the live channel dies
            // during DVR pause or DVR playback. partialRestartLiveChannel() rebuilds only
            // the network download + pre-mixer layers while keeping mixerHandle and any
            // DVR playback stream intact. restartStream() would call freeStream() and
            // destroy the ring buffer, losing everything the user paused to save.
            if self.dvrState != .live {
                #if DEBUG
                print("🔄 triggerImmediateReconnect: DVR active — partial live restart (ring buffer preserved)")
                #endif
                DispatchQueue.global(qos: .userInitiated).async { [weak self] in self?.partialRestartLiveChannel() }
            } else {
                self.restartStream()
            }
        }
    }

    // MARK: - Internal Helpers

    /// The handle to use for playback control (volume, play/stop, FX, DSP).
    /// All formats use the mixer, so this is always mixerHandle when playing.
    var playbackHandle: DWORD { mixerHandle != 0 ? mixerHandle : streamHandle }

    /// True when BASS has a valid stream set up (not torn down).
    var isStreamActive: Bool { streamHandle != 0 && mixerHandle != 0 }

    /// Restart the output mixer if it has stopped (e.g. after an iOS audio route change).
    /// Called from the remote play command when dvrState == .playing but audio is silent.
    /// BASS_ChannelPlay with restart=0 is a no-op for an already-playing channel, so this
    /// is safe to call speculatively.
    func ensureOutputPlaying() {
        let ph = playbackHandle
        guard ph != 0 else { return }
        let status = BASS_ChannelIsActive(ph)
        #if DEBUG
        print("🔊 ensureOutputPlaying: mixerState=\(status)")
        #endif
        if status != DWORD(BASS_ACTIVE_PLAYING) {
            #if DEBUG
            print("🔊 ensureOutputPlaying: mixer not playing — restarting")
            #endif
            BASS_ChannelPlay(ph, 0)
        }
    }

    /// Force BASS's RemoteIO output unit to reconnect to the current AVAudioSession route.
    /// Safe to call any time — DECODE-mode channels and network downloads are unaffected.
    /// Call after AVAudioSession.setActive(true) on iOS to guarantee the output unit is
    /// bound to the active session before BASS_ChannelPlay. Without this, after
    /// BASS_ChannelPause (DVR pause/resume cycle) + freeStream + new stream start, BASS
    /// can report ACTIVE_PLAYING while its RemoteIO unit outputs silence.
    func reconnectOutputToAudioSession() {
        guard bassInitialized else { return }
        BASS_Stop()
        BASS_Start()
    }

    /// Called when a new audio output device (AirPod, headphones) becomes available.
    /// With BASS_CONFIG_IOS_SESSION_DISABLE, BASS doesn't intercept route changes itself.
    /// After a route change, BASS's RemoteIO unit may still be pointed at the old device
    /// (e.g. iPhone speaker) even though AVAudioSession is now routing to AirPods. BASS
    /// reports ACTIVE_PLAYING but outputs silence on the new device.
    /// BASS_Stop/Start forces RemoteIO to reconnect to the current AVAudioSession route.
    /// DECODE-mode pre-mixer and network download are unaffected by BASS_Stop.
    func restartOutputAfterRouteChange() {
        guard mixerHandle != 0 else { return }
        BASS_Stop()
        BASS_Start()
        // Kick the output mixer back if it was actively streaming. For DVR-paused state,
        // leave it paused — dvrResume() will call BASS_ChannelPlay when the user presses play.
        if dvrState == .playing || dvrState == .live {
            BASS_ChannelPlay(mixerHandle, 0)
        }
        #if DEBUG
        print("🔊 BASS output reconnected to new audio route (dvrState=\(dvrState))")
        #endif
    }

}
