//
//  PlaybackController.swift
//  UncleStreamus
//
//  iOS-only app-lifetime owner of the audio player and playback wiring.
//
//  Why this exists: on iOS the app can be cold-launched *into the background* by
//  CarPlay (connecting to a car, or tapping the app icon on the CarPlay dashboard)
//  without ever connecting the SwiftUI `WindowGroup` scene. When that happens
//  `ContentView_iOS.onAppear` never fires, so any playback wiring that lived there —
//  the audio session, `MPRemoteCommandCenter` handlers, the `CarPlayBridge` command
//  closures, `MPNowPlayingInfoCenter` — would never be set up and the CarPlay
//  transport/buttons would be dead.
//
//  This singleton moves that ownership to app scope. It is bootstrapped once from
//  `UncleStreamusApp.init()` (which runs on every launch regardless of which scene
//  connects, and is the only place with the SwiftData containers before a scene),
//  so playback control is live before either the window or the CarPlay scene
//  connects. `ContentView_iOS` consumes it instead of owning `@State bassPlayer`.
//
//  This is the iOS equivalent of the macOS `AppDelegate` command-ownership pattern.
//

#if os(iOS)
import Foundation
import Observation
import SwiftData
import AVFoundation
import MediaPlayer
import UIKit

@MainActor
@Observable
final class PlaybackController {
    static let shared = PlaybackController()
    private init() {}

    // MARK: - Owned playback state (moved out of ContentView_iOS)

    let bassPlayer = BASSRadioPlayer()
    /// Shared runtime state (track/show pipeline). See RadioViewModel.
    let vm = RadioViewModel()
    var isPlaying = false
    var selectedStream: Stream?
    var showDataManager: ShowDataManager?
    var fzShowsDB: FZShowsDatabase?

    let streams = [
        Stream(name: "MP3 (128 kbit/s)", url: "https://shoutcast.norbert.de/zappa.mp3", format: "MP3"),
        Stream(name: "OGG (90 kbit/s)", url: "https://shoutcast.norbert.de/zappa.ogg", format: "OGG"),
        Stream(name: "AAC (256 kbit/s)", url: "https://shoutcast.norbert.de/zappa.aac", format: "AAC"),
        Stream(name: "FLAC (750 kbit/s)", url: "https://shoutcast.norbert.de/zappa.flac", format: "FLAC")
    ]

    // Idempotency guards (promoted from ContentView_iOS's per-view flags): the
    // window scene and the CarPlay scene can both drive `activate()`, and both
    // can appear/reappear, so one-shot setup must not run twice.
    private var didBootstrap = false
    private var didAttemptAutoResume = false
    private var didSetupSystemObservers = false
    // Opaque tokens for the app-lifetime UIApplication + AVAudioSession observers. Held
    // only so registration stays a one-shot; unlike the old view-scoped observers these
    // are never removed — the controller lives for the whole process.
    private var systemObservers: [NSObjectProtocol] = []

    // When the audio route last changed. AirPods in-ear detection and accessory
    // connect/disconnect make iOS synthesize a remote transport command aimed at the
    // current Now Playing app — which we deliberately remain while buffer-paused, so that
    // an AirPods/lock-screen press can resume. Timestamping route changes is what lets the
    // remote handlers tell those synthesized commands from a real press.
    private var lastRouteChangeAt: Date = .distantPast

    /// True when a remote play/pause/toggle arrived close enough to an audio route change
    /// that it is almost certainly iOS's own synthesized command (AirPods ear detection,
    /// accessory connect or disconnect) rather than a user press — a deliberate press is
    /// never coincident with one. Only ever used to suppress commands that would *start*
    /// audio; a command that stops audio is always honoured, whatever its origin.
    private var isLikelyRouteSynthesizedCommand: Bool {
        Date().timeIntervalSince(lastRouteChangeAt) < 2.0
    }

    // Read AppStorage-backed preferences straight from UserDefaults so this
    // app-scope object doesn't need the view's @AppStorage wrappers.
    private var dvrEnabled: Bool {
        UserDefaults.standard.object(forKey: "dvrEnabled") as? Bool ?? true
    }
    private var lastStreamFormat: String {
        UserDefaults.standard.string(forKey: "lastStreamFormat") ?? "OGG"
    }

    // MARK: - Bootstrap / activate

    /// One-time launch setup, called from `UncleStreamusApp.init()` — the only
    /// context guaranteed to run before any scene connects and to have the
    /// SwiftData containers. Deliberately does NOT activate the audio session:
    /// registering commands/observers must not duck/interrupt other audio on a
    /// background CarPlay launch. `playStream()`/the remote play handler own
    /// `configureAudioSession()` (Apple: configure the session *before* you play).
    func bootstrap(historyContainer: ModelContainer, cacheContainer: ModelContainer) {
        guard !didBootstrap else { return }
        didBootstrap = true

        showDataManager = ShowDataManager(modelContext: historyContainer.mainContext)

        let db = FZShowsDatabase(modelContext: ModelContext(cacheContainer))
        fzShowsDB = db
        // Guard the network kick under tests, mirroring UncleStreamusApp.init().
        if ProcessInfo.processInfo.environment["XCTestBundlePath"] == nil {
            if db.totalCachedShows == 0 {
                db.downloadAllPages()
            } else {
                db.refreshStalePages()
            }
        }

        if selectedStream == nil {
            selectedStream = streams.first { $0.format == lastStreamFormat } ?? streams.first
        }

        // Populate the CarPlay format picker here (not only from the view's onAppear)
        // so it isn't empty on a CarPlay-first launch.
        CarPlayBridge.shared.availableFormats = streams.map { .init(format: $0.format, label: $0.name) }

        setupPlayer()           // also calls setupRemoteCommandCenter()
        setupCarPlayHandlers()
        startObservingPlayerState()
        setupAppLifecycleObservers()
        setupInterruptionHandler()
        updateNowPlayingInfo()
        syncCarPlayBridge()
    }

    /// Idempotent per-scene activation, called whenever a scene connects (the
    /// window via `ContentView_iOS.onAppear`, or CarPlay via
    /// `CarPlaySceneDelegate.didConnect`). Bootstrap has already run from
    /// `App.init`, so this only performs the one-shot auto-resume and a fresh
    /// now-playing/bridge publish so the newly-connected scene isn't stale.
    func activate() {
        performAutoResumeIfNeeded()
        updateNowPlayingInfo()
        syncCarPlayBridge()
    }

    /// Honor the existing `autoResumeOnLaunch` preference on every launch path
    /// (including a CarPlay cold-launch): auto-play only if the user enabled it
    /// and the stream was playing at last quit. One-shot via `didAttemptAutoResume`.
    private func performAutoResumeIfNeeded() {
        guard !didAttemptAutoResume else { return }
        didAttemptAutoResume = true

        let wasPlaying = UserDefaults.standard.bool(forKey: "wasPlayingOnQuit")
        let autoResumeEnabled = UserDefaults.standard.object(forKey: "autoResumeOnLaunch") as? Bool ?? false
        #if DEBUG
        print("🚀 Launch - was playing: \(wasPlaying), auto-resume enabled: \(autoResumeEnabled)")
        #endif
        if wasPlaying && autoResumeEnabled {
            // Small delay to ensure the player is fully initialized.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [self] in
                #if DEBUG
                print("▶️ Auto-playing stream...")
                #endif
                playStream()
            }
        }
    }

    // MARK: - Audio session

    func configureAudioSession() {
        let audioSession = AVAudioSession.sharedInstance()
        // setCategory is best-effort: may throw -50 during a Bluetooth route transition
        // when iOS has the session temporarily locked. The category was already set correctly
        // during playStream(), so failure here is harmless — we just need setActive(true).
        try? audioSession.setCategory(.playback, mode: .default, options: [.allowBluetoothA2DP, .allowAirPlay])
        // IO buffer duration is best-effort: can fail during hardware handover.
        try? audioSession.setPreferredIOBufferDuration(0.5)
        // setActive(true) always runs (not gated by setCategory success) so BASS's audio
        // unit gets a properly active session before BASS_ChannelPlay is called.
        do {
            try audioSession.setActive(true)
            // Reconnect BASS's RemoteIO output unit to the now-active session. After a
            // BASS_ChannelPause (DVR pause/resume cycle) + freeStream + new stream, the
            // RemoteIO unit can become stale and output silence even though BASS reports
            // ACTIVE_PLAYING. BASS_Stop/Start forces it to re-bind to the current route.
            bassPlayer.reconnectOutputToAudioSession()
            #if DEBUG
            print("✅ Audio session activated")
            #endif
        } catch {
            #if DEBUG
            print("❌ Failed to activate audio session: \(error)")
            #endif
        }
    }

    // MARK: - Player Setup

    func setupPlayer() {
        // Wire the shared view model: references it needs + platform side-effect
        // hooks (now-playing refresh + CarPlay mirror).
        vm.bassPlayer = bassPlayer
        vm.showDataManager = showDataManager
        vm.fzShowsDB = fzShowsDB
        vm.onNowPlayingShouldUpdate = { [self] in updateNowPlayingInfo() }
        vm.onShowDidLoad = { [self] in syncCarPlayBridge() }

        bassPlayer.onMetadataUpdate = { [self] metadata in
            DispatchQueue.main.async { [self] in
                vm.handleMetadata(metadata)
            }
        }

        setupRemoteCommandCenter()
    }

    // MARK: - Remote Command Center

    private func setupRemoteCommandCenter() {
        let commandCenter = MPRemoteCommandCenter.shared()

        commandCenter.playCommand.removeTarget(nil)
        commandCenter.pauseCommand.removeTarget(nil)
        commandCenter.togglePlayPauseCommand.removeTarget(nil)

        commandCenter.playCommand.isEnabled = true
        commandCenter.playCommand.addTarget { [self] _ in
            DispatchQueue.main.async { [self] in
                #if DEBUG
                print("▶️  remoteCmd PLAY — isPlaying=\(isPlaying) dvrState=\(bassPlayer.dvrState) streamActive=\(bassPlayer.isStreamActive)")
                #endif
                if bassPlayer.dvrState == .playing {
                    // iOS sent play while DVR is already in playback state — mixer may have
                    // stopped silently after an audio route change. Re-route and kick it.
                    // Deliberately NOT route-guarded: this only revives audio that is meant to
                    // be playing, and a route change is exactly when it's needed.
                    guard bassPlayer.checkUserActionAllowed() else { return }
                    configureAudioSession()
                    bassPlayer.ensureOutputPlaying()
                    updateNowPlayingInfo()
                    return
                }
                // Everything below starts audio that is currently silent. Putting AirPods in
                // makes iOS synthesize a play command aimed at us; the user paused/stopped on
                // purpose and expects that to stick. Checked BEFORE checkUserActionAllowed()
                // so a suppressed command doesn't consume the 1.2 s debounce and swallow the
                // real press that may follow it.
                guard !isLikelyRouteSynthesizedCommand else {
                    #if DEBUG
                    print("🚫 remoteCmd PLAY suppressed — arrived within 2s of a route change")
                    #endif
                    return
                }
                guard bassPlayer.checkUserActionAllowed() else { return }
                if bassPlayer.dvrState == .paused {
                    configureAudioSession()
                    bassPlayer.dvrResume()
                    updateNowPlayingInfo()
                } else if !isPlaying || !bassPlayer.isStreamActive {
                    // Start or restart: covers initial play AND the case where isPlaying is
                    // true but handles are gone (stream died in a tunnel while device was locked).
                    playStream()
                }
            }
            return .success
        }

        commandCenter.pauseCommand.isEnabled = true
        commandCenter.pauseCommand.addTarget { [self] _ in
            DispatchQueue.main.async { [self] in
                #if DEBUG
                print("⏸️  remoteCmd PAUSE — isPlaying=\(isPlaying) dvrState=\(bassPlayer.dvrState)")
                #endif
                guard isPlaying else { return }
                // If DVR is already paused, iOS routed a *resume* intent to pauseCommand: it can't
                // read our paused state (no com.apple.mediaremote.set-playback-state entitlement),
                // so once it last saw us "playing" it keeps sending pause. Treat it as resume. The
                // 1.2s debounce blocks an iOS double-fired pause right after the real pause from
                // accidentally resuming.
                if bassPlayer.dvrState == .paused {
                    // ...but only for a command the *user* sent. Taking AirPods out also makes
                    // iOS send a pause, and reading it as "resume" is how removing AirPods used
                    // to start playback out of a paused buffer. A route-coincident pause is
                    // never a resume intent.
                    guard !isLikelyRouteSynthesizedCommand else {
                        #if DEBUG
                        print("🚫 remoteCmd PAUSE→resume suppressed — arrived within 2s of a route change")
                        #endif
                        return
                    }
                    guard bassPlayer.checkUserActionAllowed() else { return }
                    configureAudioSession()
                    bassPlayer.dvrResume()
                    updateNowPlayingInfo()
                    return
                }
                guard bassPlayer.checkUserActionAllowed() else { return }
                switch bassPlayer.dvrState {
                case .live:
                    if dvrEnabled { bassPlayer.dvrPause() } else { stopStream() }
                    updateNowPlayingInfo()
                case .paused:
                    break  // unreachable; handled above
                case .playing:
                    bassPlayer.dvrPausePlayback()
                    updateNowPlayingInfo()
                }
            }
            return .success
        }

        commandCenter.togglePlayPauseCommand.isEnabled = true
        commandCenter.togglePlayPauseCommand.addTarget { [self] _ in
            DispatchQueue.main.async { [self] in
                #if DEBUG
                print("⏯️  remoteCmd TOGGLE — isPlaying=\(isPlaying) dvrState=\(bassPlayer.dvrState) streamActive=\(bassPlayer.isStreamActive)")
                #endif
                // A toggle that would START audio gets the same route-origin guard as the play
                // command; one that would PAUSE is always honoured. iOS delivers a toggle for
                // some accessory connect/disconnect events, and from a silent state that would
                // otherwise begin playback the user never asked for.
                let toggleWouldStartAudio = !isPlaying
                    || bassPlayer.dvrState == .paused
                    || !bassPlayer.isStreamActive
                if toggleWouldStartAudio, isLikelyRouteSynthesizedCommand {
                    #if DEBUG
                    print("🚫 remoteCmd TOGGLE suppressed — would start audio within 2s of a route change")
                    #endif
                    return
                }
                guard bassPlayer.checkUserActionAllowed() else { return }
                switch (isPlaying, bassPlayer.dvrState) {
                case (false, _):
                    playStream()
                case (true, .live):
                    if !bassPlayer.isStreamActive {
                        // Stream died (tunnel) — restart instead of trying to DVR pause a dead stream.
                        // Without this, the second tap would dvrResume() and create a DVR playback
                        // stream that plays simultaneously with the reconnecting live stream.
                        playStream()
                    } else if dvrEnabled {
                        bassPlayer.dvrPause()
                        updateNowPlayingInfo()
                    } else {
                        stopStream()
                    }
                case (true, .paused):
                    configureAudioSession()
                    bassPlayer.dvrResume()
                    updateNowPlayingInfo()
                case (true, .playing):
                    bassPlayer.dvrPausePlayback()
                    updateNowPlayingInfo()
                }
            }
            return .success
        }

        commandCenter.nextTrackCommand.isEnabled = false
        commandCenter.previousTrackCommand.isEnabled = false
    }

    /// Transient status text ("Reconnecting...", "Buffering...") shown in place of the
    /// track title — the only text CarPlay's Now Playing screen can display comes from
    /// MPNowPlayingInfoCenter, so this also flashes briefly on the lock screen.
    private var nowPlayingStatusOverride: String? {
        if bassPlayer.isReconnecting {
            return bassPlayer.reconnectAttempt > 1
                ? "Reconnecting (attempt \(bassPlayer.reconnectAttempt))..."
                : "Reconnecting..."
        }
        if let stream = selectedStream, stream.format == "FLAC", bassPlayer.preBufferProgress > 0 {
            return "Buffering \(stream.name)..."
        }
        return nil
    }

    func updateNowPlayingInfo() {
        var nowPlayingInfo = [String: Any]()

        if let parsed = vm.parsedTrack {
            nowPlayingInfo[MPMediaItemPropertyTitle] = parsed.trackName ?? "UncleStreamus"

            if let show = vm.currentShow {
                // Put all info in Artist line: "Frank Zappa • 1975 10 04 • Paramount Theatre, Seattle, WA"
                // The venue field already includes location, so no need to add city/state/country
                let artist = parsed.inferredArtist
                let artistLine = "\(artist) • \(show.date) • \(show.venue)"
                nowPlayingInfo[MPMediaItemPropertyArtist] = artistLine
                #if DEBUG
                print("🎵 Now Playing: \(parsed.trackName ?? "?") | \(artistLine)")
                #endif
            } else {
                nowPlayingInfo[MPMediaItemPropertyArtist] = parsed.inferredArtist
                #if DEBUG
                print("🎵 Now Playing: No show info available yet")
                #endif
            }
        } else {
            nowPlayingInfo[MPMediaItemPropertyTitle] = "UncleStreamus"
            nowPlayingInfo[MPMediaItemPropertyArtist] = "UncleStreamus"
            #if DEBUG
            print("🎵 Now Playing: Default (no parsed track)")
            #endif
        }

        if let statusOverride = nowPlayingStatusOverride {
            nowPlayingInfo[MPMediaItemPropertyTitle] = statusOverride
        }

        let dvrPaused = bassPlayer.dvrState == .paused
        let isActuallyPlaying = isPlaying && !dvrPaused
        // CarPlay/lock screen derive the big transport button's icon from which of
        // playCommand/pauseCommand is currently *enabled* — not from a passive read of
        // MPNowPlayingInfoPropertyPlaybackRate. Confirmed by debug logs: after Stop,
        // tapping the (still "pause"-shaped) button fired `pauseCommand` even though
        // isPlaying was already false, and vice versa while actively playing. Toggling
        // these in lockstep with actual state keeps the displayed icon truthful.
        let commandCenter = MPRemoteCommandCenter.shared()
        commandCenter.playCommand.isEnabled = !isActuallyPlaying
        commandCenter.pauseCommand.isEnabled = isActuallyPlaying
        // KNOWN LIMITATION (accepted — see memory ios_lockscreen_playstate_limitation.md):
        // iOS *ignores* every playbackState write below — it requires the private
        // `com.apple.mediaremote.set-playback-state` entitlement, which a third-party app
        // cannot have (device logs: "Ignoring setPlaybackState because application does not
        // contain entitlement…"). So the lock-screen/Control-Center transport icon is NOT
        // driven by playbackState. iOS falls back to (a) playbackRate below and (b) its own
        // observation of whether we're producing audio. While DVR-paused *and locked*, the
        // silence keepalive is deliberately running (it must, to keep the recording pump
        // filling the buffer in the background), so iOS sees active audio and shows the PAUSE
        // icon even though we're paused. A direct lock-screen button tap flips the icon
        // optimistically; an AirPods press does not, so the icon can lag when paused via
        // AirPods while locked. This is a cosmetic-only issue — playback pause/resume itself
        // is correct (the pauseCommand→resume branch in setupRemoteCommandCenter handles the
        // case where iOS routes the resume press to pauseCommand). We still set playbackState
        // and playbackRate because they're honored on platforms/contexts that DO read them
        // (e.g. CarPlay) and cost nothing where they're ignored.
        let nowPlayingCenter = MPNowPlayingInfoCenter.default()
        if isActuallyPlaying {
            nowPlayingCenter.playbackState = .playing
        } else if isPlaying {
            // DVR paused (or DVR playback momentarily stalled) — still "in session", not stopped.
            nowPlayingCenter.playbackState = .paused
        } else {
            nowPlayingCenter.playbackState = .stopped
        }
        nowPlayingInfo[MPNowPlayingInfoPropertyPlaybackRate] = isActuallyPlaying ? 1.0 : 0.0
        // Only set IsLiveStream=true when actively at the live edge. iOS treats
        // IsLiveStream=true as "broadcast in progress" — if left true while stopped,
        // it can block AirPods/lock screen from offering a play command (interpreted
        // as "the live broadcast ended"). Tying it to isActuallyPlaying ensures the
        // play affordance is always available when stopped or DVR-paused.
        nowPlayingInfo[MPNowPlayingInfoPropertyIsLiveStream] = isActuallyPlaying
        // Marks "now" as the playhead position for a live item — recommended for live
        // streams, and also gives the system a fresh, changing value on every publish
        // so it has a reason to re-evaluate (and not cache) the displayed transport state.
        if isActuallyPlaying {
            nowPlayingInfo[MPNowPlayingInfoPropertyCurrentPlaybackDate] = Date()
        }
        nowPlayingInfo[MPMediaItemPropertyMediaType] = MPMediaType.music.rawValue

        MPNowPlayingInfoCenter.default().nowPlayingInfo = nowPlayingInfo
    }

    // MARK: - CarPlay

    /// Mirrors current state into `CarPlayBridge.shared` and asks the CarPlay scene
    /// delegate to refresh its templates. CarPlay runs in a separate scene and can't
    /// read our state directly, so this is the one-way data path to it — the reverse
    /// path (CarPlay buttons → playback actions) is `setupCarPlayHandlers()`.
    func syncCarPlayBridge() {
        let bridge = CarPlayBridge.shared
        bridge.isPlaying = isPlaying
        bridge.dvrState = bassPlayer.dvrState
        bridge.setlist = vm.currentShow?.setlist ?? []
        bridge.currentTrackIndex = vm.currentShow != nil ? vm.currentSetlistPosition : nil
        bridge.selectedFormat = selectedStream?.format ?? lastStreamFormat
        bridge.onDataChanged?()
    }

    /// Wires `CarPlaySceneDelegate`'s buttons to playback actions via typed closures
    /// on `CarPlayBridge.shared` — mirrors how the macOS menubar drives `ContentView`
    /// through `RadioViewModel`'s command hooks.
    private func setupCarPlayHandlers() {
        let bridge = CarPlayBridge.shared

        bridge.onStop = { [self] in
            stopStream()
        }
        bridge.onGoLive = { [self] in
            bassPlayer.goLive()
            updateNowPlayingInfo()
            syncCarPlayBridge()
        }
        bridge.onSelectFormat = { [self] format in
            if let stream = streams.first(where: { $0.format == format }) {
                selectStream(stream)
            }
        }
        // CarPlay can connect after this app already published its initial Now
        // Playing state (e.g. auto-resume on launch) — force a fresh republish so
        // its transport controls never start out of sync with actual playback.
        bridge.onSceneConnect = { [self] in
            updateNowPlayingInfo()
            syncCarPlayBridge()
        }
    }

    // MARK: - Player-state observation
    //
    // Mirrors the reactions ContentView_iOS used to drive from `.onChange(of:)` on
    // `bassPlayer`. Those fire only while the SwiftUI window scene is mounted, so on a
    // CarPlay-only session (force-quit → launched from the CarPlay dashboard) they never
    // ran — which is why the CarPlay Now Playing screen stayed stale after a DVR pause
    // (no "Go Live", wrong transport icon). Running them here — self-rearming, started
    // from `bootstrap` — keeps CarPlay correct on every launch path, foreground included.
    private var observedDVRState: BASSRadioPlayer.DVRState = .live

    private func startObservingPlayerState() {
        withObservationTracking {
            _ = bassPlayer.dvrState
            _ = bassPlayer.isReconnecting
            _ = bassPlayer.playbackState
            _ = bassPlayer.preBufferProgress
        } onChange: { [weak self] in
            // onChange fires just before a tracked value changes; hop to main and re-read
            // the committed values, then re-arm for the next change.
            Task { @MainActor in
                guard let self else { return }
                self.reactToPlayerStateChange()
                self.startObservingPlayerState()
            }
        }
    }

    private func reactToPlayerStateChange() {
        // Reconnect / pre-buffer status text is surfaced through now-playing; refresh it
        // on any tracked change (covers isReconnecting + preBufferProgress).
        updateNowPlayingInfo()

        let dvr = bassPlayer.dvrState
        if dvr != observedDVRState {
            observedDVRState = dvr
            // The CarPlay mirror (transport buttons, "Go Live", paused state) is driven by
            // this — without it a CarPlay-only pause looks like a stop.
            syncCarPlayBridge()
            // Keep the recording pump filling the buffer if the app is backgrounded while
            // paused. No-op in the foreground (guarded on isAppInForeground). Matches the
            // old ContentView_iOS `.onChange(of: dvrState)` behavior.
            if dvr == .paused {
                bassPlayer.startSilenceKeepalive()
            }
        }

        // Reconnect attempts exhausted (~1 min of failures): the engine truly stopped but
        // intent-based `isPlaying` (which drives the CarPlay/lock-screen transport icon)
        // was never reset. Bring it back in sync once the engine gives up for real.
        if bassPlayer.playbackState == .stopped, isPlaying, !bassPlayer.isReconnecting,
           bassPlayer.reconnectAttempt >= bassPlayer.reconnectMaxAttempts {
            isPlaying = false
            updateNowPlayingInfo()
            syncCarPlayBridge()
        }
    }

    // MARK: - App lifecycle (moved from ContentView_iOS's `.onChange(of: scenePhase)`)
    //
    // These run at app scope, keyed off UIApplication activation notifications instead of
    // the SwiftUI window's `scenePhase`. On a CarPlay-only session the window scene never
    // connects, so the old view modifier never fired and `isAppInForeground` stayed at its
    // default `true`. That mattered: `startSilenceKeepalive()` no-ops in the foreground, so
    // a CarPlay pause while driving (app backgrounded) left the keepalive off and iOS could
    // suspend us and freeze the DVR recording pump. Tracking foreground state here fixes that.
    //
    // Mapping to the old scenePhase branches:
    //   .active              → didBecomeActiveNotification    (foreground)
    //   .inactive / .background → willResignActive / didEnterBackground (backgrounding)
    // `.inactive` and `.background` were handled identically before, so both backgrounding
    // notifications route to the same idempotent handler.

    private func setupAppLifecycleObservers() {
        guard !didSetupSystemObservers else { return }

        // Seed the initial value from the real app state: on a CarPlay-only cold launch the
        // process starts in the background and never becomes active, so we must NOT assume
        // foreground (the old static `true` default was wrong for exactly this path).
        bassPlayer.isAppInForeground = (UIApplication.shared.applicationState == .active)

        let center = NotificationCenter.default
        systemObservers.append(center.addObserver(
            forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleAppDidBecomeActive() }
        })
        for name in [UIApplication.willResignActiveNotification,
                     UIApplication.didEnterBackgroundNotification] {
            systemObservers.append(center.addObserver(
                forName: name, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.handleAppWillBackground() }
            })
        }

        didSetupSystemObservers = true
    }

    private func handleAppDidBecomeActive() {
        bassPlayer.isAppInForeground = true
        #if DEBUG
        if bassPlayer.dvrState == .paused { bassPlayer.logDVRDiag("→foreground") }
        #endif
        // Reconnect whenever the user intended to play but the stream isn't healthy — covers
        // both zero handles (suspended during reconnect backoff) and stalled/stopped handles.
        // triggerImmediateReconnect() guards internally against disrupting a healthy stream.
        // Skip while DVR-paused: reconnecting would restart the live stream and wipe a full
        // buffer (the play-buffer-vs-go-live choice is offered on the play press instead).
        if bassPlayer.dvrState == .paused {
            // no-op: leave the paused buffer intact
        } else if bassPlayer.isUserIntendedPlay {
            bassPlayer.triggerImmediateReconnect()
        }
        // Stop the keepalive on foreground resume unless still DVR-paused (the recording pump
        // must keep filling the buffer while paused; dvrResume()/goLive() stop it on play).
        if bassPlayer.dvrState != .paused {
            bassPlayer.stopSilenceKeepalive()
        }
    }

    private func handleAppWillBackground() {
        // Set foreground state FIRST so startSilenceKeepalive()'s foreground guard sees the
        // correct value when the background-keepalive start below runs.
        bassPlayer.isAppInForeground = false
        UserDefaults.standard.set(isPlaying, forKey: "wasPlayingOnQuit")
        // Start the keepalive if DVR is paused so the recording pump keeps filling the buffer
        // after iOS would otherwise suspend us. No-op if already running.
        if bassPlayer.dvrState == .paused {
            bassPlayer.startSilenceKeepalive()
        }
        #if DEBUG
        // Logged AFTER the keepalive start so the snapshot confirms it actually started for
        // the backgrounded process (the linchpin of recording survival).
        if bassPlayer.dvrState == .paused { bassPlayer.logDVRDiag("→background") }
        #endif
    }

    // MARK: - Audio Session Interruption / route changes (moved from ContentView_iOS)
    //
    // Registered once at app scope (not on the view) so a phone call, Siri, or a headphone
    // unplug is handled even on a CarPlay-only session — interruptions in a car are common,
    // and the old view-scoped observers never registered when no window scene connected.

    private func setupInterruptionHandler() {
        let center = NotificationCenter.default
        let session = AVAudioSession.sharedInstance()

        systemObservers.append(center.addObserver(
            forName: AVAudioSession.interruptionNotification, object: session, queue: .main
        ) { [weak self] notification in
            MainActor.assumeIsolated { self?.handleAudioInterruption(notification) }
        })

        // Stamp every route change, whatever the reason. Registered FIRST on purpose:
        // NotificationCenter delivers in registration order, so the timestamp is already set
        // when the two handlers below (and any remote command that follows) read it. Ear
        // detection frequently reports .routeConfigurationChange rather than a device
        // appearing/disappearing, so no reason is filtered out here.
        systemObservers.append(center.addObserver(
            forName: AVAudioSession.routeChangeNotification, object: session, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.lastRouteChangeAt = Date() }
        })

        // Pause to DVR when headphones are removed (AirPod taken out, Bluetooth disconnect,
        // wired unplug). Without this, audio routes to the iPhone speaker and the DVR ring
        // buffer never gets created.
        systemObservers.append(center.addObserver(
            forName: AVAudioSession.routeChangeNotification, object: session, queue: .main
        ) { [weak self] notification in
            MainActor.assumeIsolated { self?.handleHeadphoneRemoval(notification) }
        })

        // Re-activate the audio session when a Bluetooth device (AirPods) reconnects.
        systemObservers.append(center.addObserver(
            forName: AVAudioSession.routeChangeNotification, object: session, queue: .main
        ) { [weak self] notification in
            MainActor.assumeIsolated { self?.handleBluetoothReconnect(notification) }
        })
    }

    private func handleAudioInterruption(_ notification: Notification) {
        guard let typeValue = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue) else { return }
        if type == .began {
            #if DEBUG
            // Interruption is the prime suspect for DVR background-recording loss: another app
            // (e.g. a video call) claiming the session stops our silence keepalive, after which
            // iOS suspends us and the recording pump freezes. Snapshot to capture that moment.
            print("🔔 AVAudioSession interruption BEGAN — dvrState=\(bassPlayer.dvrState)")
            bassPlayer.logDVRDiag("interrupt-began")
            #endif
            // Stop audio immediately on interruption (phone call, Siri, another app claiming
            // the session). Use DVR-aware pause so the ring buffer keeps recording through the
            // call; the user can catch up when it ends.
            switch bassPlayer.dvrState {
            case .live:
                if dvrEnabled { bassPlayer.dvrPause() } else { bassPlayer.stopWithFadeOut() }
            case .playing:
                bassPlayer.dvrPausePlayback()
            case .paused:
                break  // already paused
            }
        } else if type == .ended {
            let opts = AVAudioSession.InterruptionOptions(
                rawValue: notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0)
            #if DEBUG
            print("🔔 AVAudioSession interruption ENDED — shouldResume=\(opts.contains(.shouldResume)) dvrState=\(bassPlayer.dvrState) userIntendedPlay=\(bassPlayer.isUserIntendedPlay)")
            bassPlayer.logDVRDiag("interrupt-ended")
            #endif
            // Deliberately only acted on with .shouldResume: without it the user chose other
            // audio, and reactivating our non-mixable session would interrupt them. A pause
            // left unprotected that way degrades gracefully — the stale-resume gate in
            // dvrResume() sends the next play press straight to live instead of into a sliver.
            if opts.contains(.shouldResume) && bassPlayer.isUserIntendedPlay {
                configureAudioSession()
                // Re-arm the keepalive: the interruption stopped the silent player, and while
                // we stay DVR-paused in the background nothing else would restart it — that is
                // exactly how iOS ends up suspending us and freezing the recording pump.
                bassPlayer.rearmSilenceKeepaliveIfNeeded()
                // Skip the reconnect once the buffer is full: recording is intentionally over
                // and the live channel is paused on purpose (the play-buffer-vs-go-live choice
                // is offered on the next play press). Otherwise reconnect — while paused it
                // routes to the buffer-preserving partialRestartLiveChannel(), which is what
                // restores recording after a call.
                if !(bassPlayer.dvrState == .paused && bassPlayer.dvrBufferFull) {
                    bassPlayer.triggerImmediateReconnect()
                }
            }
        }
    }

    private func handleHeadphoneRemoval(_ notification: Notification) {
        guard let reasonValue = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
              AVAudioSession.RouteChangeReason(rawValue: reasonValue) == .oldDeviceUnavailable else { return }

        let prevRoute = notification.userInfo?[AVAudioSessionRouteChangePreviousRouteKey]
            as? AVAudioSessionRouteDescription
        let wasHeadphones = prevRoute?.outputs.contains {
            [.headphones, .bluetoothA2DP, .bluetoothHFP].contains($0.portType)
        } ?? false

        guard wasHeadphones, bassPlayer.isUserIntendedPlay else { return }

        #if DEBUG
        print("🎧 Route change: headphones removed — DVR pause")
        #endif

        switch bassPlayer.dvrState {
        case .live:
            if dvrEnabled { bassPlayer.dvrPause() } else { bassPlayer.stopWithFadeOut() }
        case .playing:
            bassPlayer.dvrPausePlayback()
        case .paused:
            // Already paused — but a route change can stop the silent keepalive, and while
            // backgrounded that leads to suspension and a frozen recording pump. Re-check it.
            bassPlayer.rearmSilenceKeepaliveIfNeeded()
        }
    }

    private func handleBluetoothReconnect(_ notification: Notification) {
        guard let reasonValue = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
              AVAudioSession.RouteChangeReason(rawValue: reasonValue) == .newDeviceAvailable,
              bassPlayer.isUserIntendedPlay else { return }

        let session = AVAudioSession.sharedInstance()
        let hasBluetoothOutput = session.currentRoute.outputs.contains {
            [.bluetoothA2DP, .bluetoothHFP].contains($0.portType)
        }
        guard hasBluetoothOutput else { return }

        #if DEBUG
        print("🎧 Route change: Bluetooth device available — re-activating audio session")
        #endif
        // Re-set category here: on launch after a process kill (e.g. Xcode install-over), the
        // -50 session lock from the Bluetooth transition prevents setCategory from succeeding
        // in configureAudioSession(). By the time this routeChange fires the lock is released,
        // so we set it now to enable A2DP before restarting BASS.
        try? session.setCategory(.playback, mode: .default, options: [.allowBluetoothA2DP, .allowAirPlay])
        try? session.setActive(true)
        bassPlayer.restartOutputAfterRouteChange()
        // Same reasoning as the removal case: the route transition can have stopped the
        // keepalive while we were background-paused. No-op unless it's actually needed.
        bassPlayer.rearmSilenceKeepaliveIfNeeded()
    }

    // MARK: - Playback verbs

    /// Switch stream format. Centralized here (not in a view `.onChange`) so it also works
    /// when the command arrives from CarPlay on a session with no window scene: persist the
    /// choice, restart if currently playing, and refresh the CarPlay mirror. Both the phone
    /// picker and CarPlay's format list call this.
    func selectStream(_ stream: Stream) {
        selectedStream = stream
        UserDefaults.standard.set(stream.format, forKey: "lastStreamFormat")
        if isPlaying {
            playStream()
        }
        syncCarPlayBridge()
    }

    /// Resume from a paused buffer (**in-app play button only**). If the buffer has filled and the
    /// user hasn't started draining it yet, offer the play-buffer-vs-go-live choice instead of
    /// resuming directly; the alert presents on the foreground app UI. Once draining has begun
    /// (or the buffer isn't full), resume directly.
    ///
    /// CarPlay / lock screen / AirPods play presses MUST NOT come through here — they have no way
    /// to show the offer alert (on a CarPlay-only session there's no window scene at all), so
    /// routing them here would either raise an invisible prompt or leave playback stuck. Those
    /// paths go through the MPRemoteCommandCenter handlers in `setupRemoteCommandCenter()`, whose
    /// `dvrState == .paused` branches call `dvrResume()` directly — i.e. they always just play the
    /// buffer with no prompt. Keep that split; do not "unify" the remote path onto this method.
    func resumeOrOfferBuffer() {
        if bassPlayer.dvrBufferFull && !bassPlayer.dvrFullBufferDrainStarted {
            bassPlayer.dvrReturnOfferPending = true
        } else {
            configureAudioSession()
            bassPlayer.dvrResume()
            updateNowPlayingInfo()
        }
    }

    func playStream(showWarning: Bool = true) {
        guard let stream = selectedStream else { return }

        configureAudioSession()
        bassPlayer.play(format: stream.format, url: stream.url)
        isPlaying = true
        updateNowPlayingInfo()
        syncCarPlayBridge()

        UserDefaults.standard.set(true, forKey: "wasPlayingOnQuit")
    }

    func stopStream() {
        bassPlayer.stopWithFadeOut()
        isPlaying = false
        updateNowPlayingInfo()
        syncCarPlayBridge()
        UserDefaults.standard.set(false, forKey: "wasPlayingOnQuit")
        // After the 0.4s fade, deactivate the session so other audio apps (Spotify,
        // Podcasts, Music) receive interruptionNotification .ended and auto-resume.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [self] in
            guard !bassPlayer.isUserIntendedPlay else { return }
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }

    func fetchShowInfo(date: String, showTime: ShowTime = .none) {
        vm.fetchShowInfo(date: date, showTime: showTime)
    }
}
#endif
