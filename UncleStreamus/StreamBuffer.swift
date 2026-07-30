import Foundation
#if os(macOS)
import Bass
#endif

// MARK: - StreamBuffer
//
// Rolling WAV ring buffer for DVR "pause live stream" feature.
//
// Architecture:
//   DSP audio thread → append() → in-memory ring buffer (os_unfair_lock)
//                                      ↓ drain at ~50 Hz on write queue
//                              WAV segment files on disk (15 × 60 s)
//
// Storage: 16-bit PCM, 44100 Hz, stereo → ~10.1 MiB/segment → ~151 MiB (15 min default), ~303 MiB (30 min max).
// WAV header uses placeholder data size (0xFFFFFFFF) — BASS reads to EOF fine.

final class StreamBuffer {

    // MARK: - Constants

    private(set) var maxSegments: Int  // 1 segment per minute; set from Settings (5–30)
    let segmentDuration: Double    // seconds per segment (60 in production; short in tests)
    let sampleRate: Int32 = 44100
    let numChannels: Int32 = 2

    var bytesPerSecond: Int64  { Int64(sampleRate) * Int64(numChannels) * 2 }          // 176 400 B/s
    // Multiply before the Int64 conversion: a sub-second test segmentDuration would
    // otherwise truncate to 0. Still exactly 5_292_000 at the production 60 s.
    var samplesPerSegment: Int64 {
        Int64(segmentDuration * Double(sampleRate)) * Int64(numChannels)
    }

    private let wavHeaderSize: Int64 = 44

    // MARK: - In-memory ring buffer (write: audio thread, read: write queue)

    // 512 K Float32 samples ≈ 5.8 s of stereo audio @ 44.1 kHz.
    // Acts as a lock-free-style bridge; os_unfair_lock keeps critical sections <10 µs.
    private let memCapacity = 524_288          // Float32 samples
    private var memBuffer:  [Float]
    private var memWritePos = 0
    private var memReadPos  = 0
    private var memAvailable = 0
    private var lock = os_unfair_lock()

    // MARK: - Disk state (write queue only)

    private var currentSegmentIndex: Int   = 0        // ring slot being written (0..<maxSegments)
    /// Absolute number of the segment being written — unlike `currentSegmentIndex` this never
    /// wraps, so it says which segment number each ring slot currently holds. Playback maps a
    /// timestamp to `Int(t / segmentDuration)`, an absolute number too; comparing the two is
    /// what stops a read past the end of the recording from wrapping onto a live slot.
    private(set) var currentSegmentNumber: Int = 0
    private var samplesInCurrentSegment: Int64 = 0
    private(set) var totalSamplesWritten:  Int64 = 0  // cumulative, never reset

    private var fileHandle: FileHandle?
    private let writeQueue = DispatchQueue(label: "com.unclestreamus.dvr", qos: .utility)
    private var isRunning  = false

    private let tempDir: URL

    // MARK: - Buffer-full protection
    // Set by BASSRadioPlayer when the user pauses: the write queue will NOT rotate into this
    // segment index (which would overwrite the oldest pause-point data). Instead it stops
    // cleanly and fires onBufferFull so the full ring can be played back from dvrPauseTimestamp.
    private var stopBeforeSegmentIndex: Int? = nil
    private var onBufferFull: (() -> Void)? = nil

    /// Tell the ring to stop before overwriting `index` (called from any thread; dispatched
    /// to write queue for serialisation). `onFull` fires on the main thread when triggered.
    func setStopBeforeSegment(index: Int, onFull: @escaping () -> Void) {
        writeQueue.async { [weak self] in
            self?.stopBeforeSegmentIndex = index
            self?.onBufferFull = onFull
        }
    }

    /// Remove the stop-before protection so the ring rolls freely.
    /// Call when DVR playback resumes: the pause-point content no longer needs protecting
    /// because the user is now advancing past it, and old segments can be safely overwritten.
    func clearStopBeforeSegment() {
        writeQueue.async { [weak self] in
            self?.stopBeforeSegmentIndex = nil
            self?.onBufferFull = nil
        }
    }

    // MARK: - Init

    /// - Parameters:
    ///   - maxMinutes: How many minutes of audio to retain (5–30). Defaults to 15.
    ///   - segmentDuration: Seconds per WAV segment. Production always uses the 60 s default;
    ///     tests pass a fraction of a second so hundreds of segment rotations (and the ring
    ///     wrapping) can be exercised in milliseconds instead of hours.
    init(maxMinutes: Int = 15, segmentDuration: Double = 60.0) {
        maxSegments          = max(5, min(30, maxMinutes))
        self.segmentDuration = segmentDuration
        tempDir              = FileManager.default.temporaryDirectory
        memBuffer            = [Float](repeating: 0, count: 524_288)
    }

    // MARK: - Lifecycle

    func start() {
        isRunning = true
        openSegment(index: 0)
        scheduleWriteTick()
    }

    /// Flush remaining samples and close the current segment file.
    /// Blocks the caller briefly (write-queue sync flush).
    /// Idempotent: returns immediately if already stopped (e.g., by stopBeforeSegmentIndex trigger).
    func stop() {
        guard isRunning else { return }
        isRunning = false
        writeQueue.sync {
            self.drainAndWrite()
            self.closeCurrentSegment()
        }
    }

    /// Delete all temporary WAV segment files.
    func cleanup() {
        Self.sweepStaleSegmentFiles()
    }

    /// Delete every DVR segment WAV in the temp directory, matched on the shared filename
    /// prefix rather than `0..<maxSegments`. Prefix matching also catches high indices
    /// orphaned by a lowered `dvrBufferMinutes` (30 → 5 leaves segments 5–29 behind) and
    /// files left by a previous process that was force-quit mid-recording — up to ~300 MB
    /// that would otherwise sit in tmp until iOS decides to purge it.
    /// Called at launch from `BASSRadioPlayer.init()` and by `cleanup()`.
    static func sweepStaleSegmentFiles() {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory
        guard let names = try? fm.contentsOfDirectory(atPath: tmp.path) else { return }
        for name in names where name.hasPrefix(segmentFilePrefix) && name.hasSuffix(".wav") {
            try? fm.removeItem(at: tmp.appendingPathComponent(name))
        }
    }

    /// Update the ring buffer window while recording is active (increase or safe decrease).
    /// Dispatched onto the write queue so it's serialised with segment rotation.
    /// `completion` (if given) runs on the write queue once the change has been applied.
    func updateMaxSegments(_ newMax: Int, completion: (() -> Void)? = nil) {
        writeQueue.async { [weak self] in
            self?.maxSegments = newMax
            completion?()
        }
    }

    // MARK: - Audio Thread Interface (non-blocking)

    /// Called from the BASS DSP callback on the audio thread.
    /// Copies Float32 samples into the in-memory ring buffer without blocking.
    /// Excess samples are silently dropped when the buffer is full (should not happen normally).
    func append(buffer: UnsafeRawPointer, length: Int) {
        let floats = buffer.assumingMemoryBound(to: Float.self)
        let count  = length / MemoryLayout<Float>.size

        os_unfair_lock_lock(&lock)
        let space = memCapacity - memAvailable
        let n     = min(count, space)
        for i in 0..<n {
            memBuffer[memWritePos] = floats[i]
            memWritePos = (memWritePos &+ 1) % memCapacity
        }
        memAvailable += n
        os_unfair_lock_unlock(&lock)
    }

    // MARK: - Timing

    /// Total seconds of audio recorded since start().
    var bufferedDuration: Double {
        Double(totalSamplesWritten) / Double(sampleRate) / Double(numChannels)
    }

    /// Alias for `bufferedDuration`; represents the recording timestamp at the write head.
    var currentTimestamp: Double { bufferedDuration }

    /// Recording time of the oldest audio still on disk. Everything before this has been
    /// overwritten by the ring, so a read here would silently return much newer audio.
    var oldestAvailableTimestamp: Double {
        Double(max(0, currentSegmentNumber - maxSegments + 1)) * segmentDuration
    }

    // MARK: - Playback Stream Creation

    /// Whether `timestamp` falls inside the audio currently on disk.
    ///
    /// The upper bound matters because `segNum % maxSegments` wraps: a read past the write head
    /// would otherwise return the *oldest* segment instead of failing. That is the end-of-buffer
    /// bug — the DVR preloader asked for the segment after the last one and got the start of the
    /// buffer, so playback spliced it in and replayed rather than going live. Overwritten history
    /// (below `oldestAvailableTimestamp`) wraps the same way, handing back much newer audio.
    ///
    /// Split out from `createPlaybackStream` so it can be unit-tested: the test process never
    /// calls `BASS_Init`, so `BASS_StreamCreateFile` cannot succeed there and the stream-creating
    /// path can only be asserted on in its failing direction.
    func canPlay(from timestamp: Double) -> Bool {
        guard timestamp >= 0,
              timestamp < bufferedDuration,
              timestamp >= oldestAvailableTimestamp else { return false }
        return Int(timestamp / segmentDuration) <= currentSegmentNumber
    }

    /// Create a BASS file stream starting at `timestamp` seconds into the recording.
    /// The caller must call `BASS_StreamFree` when done.
    /// Returns 0 if the segment file does not exist or the timestamp is out of range.
    func createPlaybackStream(from timestamp: Double) -> DWORD {
        guard canPlay(from: timestamp) else { return 0 }

        let segNum     = Int(timestamp / segmentDuration)
        let segIdx     = segNum % maxSegments
        let offsetSecs = timestamp - Double(segNum) * segmentDuration

        let path = segmentPath(index: segIdx).path
        guard FileManager.default.fileExists(atPath: path),
              let cPath = path.cString(using: .utf8) else { return 0 }

        // BASS_STREAM_DECODE: required so the stream can be added to a mixer via
        // BASS_Mixer_StreamAddChannel. Without it the call silently fails and the mixer
        // produces silence. BASS_SAMPLE_FLOAT: keep samples as Float32 matching the mixer.
        let stream = BASS_StreamCreateFile(0, cPath, 0, 0, DWORD(BASS_SAMPLE_FLOAT | BASS_STREAM_DECODE))
        guard stream != 0 else {
            #if DEBUG
            print("❌ DVR: BASS_StreamCreateFile failed (err=\(BASS_ErrorGetCode())) path=\(path)")
            #endif
            return 0
        }

        if offsetSecs > 0 {
            let seekPos = BASS_ChannelSeconds2Bytes(stream, offsetSecs)
            BASS_ChannelSetPosition(stream, seekPos, DWORD(BASS_POS_BYTE))
        }

        return stream
    }

    // MARK: - Private — Segment Management

    /// Shared filename prefix for every on-disk segment; the sweep matches on it.
    static let segmentFilePrefix = "zappastream_dvr_seg_"

    private func segmentPath(index: Int) -> URL {
        tempDir.appendingPathComponent("\(Self.segmentFilePrefix)\(index).wav")
    }

    private func openSegment(index: Int) {
        let path = segmentPath(index: index)
        try? FileManager.default.removeItem(at: path)       // overwrite ring-buffer slot
        FileManager.default.createFile(atPath: path.path, contents: nil)
        fileHandle = try? FileHandle(forWritingTo: path)
        // Placeholder data size 0xFFFFFFFF: BASS reads to EOF regardless of the header value.
        fileHandle?.write(makeWAVHeader(dataSize: 0xFFFF_FFFF))
        samplesInCurrentSegment = 0
    }

    private func closeCurrentSegment() {
        fileHandle?.closeFile()
        fileHandle = nil
    }

    // MARK: - Private — Write Loop

    private func scheduleWriteTick() {
        writeQueue.asyncAfter(deadline: .now() + 0.02) { [weak self] in
            guard let self, self.isRunning else { return }
            self.drainAndWrite()
            self.scheduleWriteTick()
        }
    }

    private func drainAndWrite() {
        // Process in chunks; keep stereo alignment (even sample count).
        let maxChunkSamples = 8192
        while true {
            os_unfair_lock_lock(&lock)
            let available = memAvailable
            os_unfair_lock_unlock(&lock)
            guard available >= 2 else { break }

            // Never write past the segment boundary. Without this clamp the chunk that crosses
            // the boundary lands entirely in the outgoing file, so every segment runs up to one
            // chunk (~93 ms) long while playback still maps time → segment as `t / segmentDuration`.
            // That error accumulated over the whole session — hours of streaming drifted
            // `bufferedDuration` seconds past `segmentsWritten * segmentDuration`, and the DVR
            // preloader read the surplus as "one more segment exists", wrapping onto the oldest
            // slot and replaying the buffer instead of going live.
            // `samplesPerSegment` and `samplesInCurrentSegment` are both even, so the clamp keeps
            // chunks stereo-aligned; it is ≥ 2 here because rotation fires the moment the boundary
            // is reached.
            let remainingInSegment = Int(samplesPerSegment - samplesInCurrentSegment)
            let chunkSamples = min(available & ~1, maxChunkSamples, remainingInSegment)
            var chunk = [Float](repeating: 0, count: chunkSamples)

            os_unfair_lock_lock(&lock)
            for i in 0..<chunkSamples {
                chunk[i]   = memBuffer[memReadPos]
                memReadPos = (memReadPos &+ 1) % memCapacity
            }
            memAvailable -= chunkSamples
            os_unfair_lock_unlock(&lock)

            // Float32 → Int16 conversion (clamp then scale)
            var pcm16 = [Int16](repeating: 0, count: chunkSamples)
            for i in 0..<chunkSamples {
                pcm16[i] = Int16(max(-32_768.0, min(32_767.0, chunk[i] * 32_767.0)))
            }

            let data = pcm16.withUnsafeBufferPointer { Data(buffer: $0) }
            fileHandle?.write(data)

            samplesInCurrentSegment += Int64(chunkSamples)
            totalSamplesWritten     += Int64(chunkSamples)

            // Rotate to next segment when the current one is full. The chunk clamp above means
            // this is always an exact hit, so `totalSamplesWritten` lands on a clean segment
            // boundary and `bufferedDuration == segmentsWritten * segmentDuration`.
            if samplesInCurrentSegment >= samplesPerSegment {
                closeCurrentSegment()
                let nextIdx = (currentSegmentIndex + 1) % maxSegments
                // If the next slot is protected (pause segment), stop cleanly without
                // overwriting it — the full ring content from dvrPauseTimestamp is intact.
                if let stopBefore = stopBeforeSegmentIndex, nextIdx == stopBefore {
                    isRunning = false
                    let cb = onBufferFull
                    DispatchQueue.main.async { cb?() }
                    return
                }
                currentSegmentIndex   = nextIdx
                currentSegmentNumber += 1
                openSegment(index: currentSegmentIndex)
            }
        }
    }

    // MARK: - Private — WAV Header

    private func makeWAVHeader(dataSize: UInt32) -> Data {
        var h = Data(capacity: 44)

        let sr  = UInt32(sampleRate)
        let ch  = UInt16(numChannels)
        let bps: UInt16 = 16
        let ba  = ch * bps / 8
        let br  = sr * UInt32(ba)

        func u16(_ v: UInt16) -> [UInt8] { [UInt8(v & 0xFF), UInt8(v >> 8)] }
        func u32(_ v: UInt32) -> [UInt8] {
            [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8(v >> 24)]
        }

        h.append(contentsOf: Array("RIFF".utf8))
        h.append(contentsOf: u32(dataSize &+ 36))   // RIFF chunk size
        h.append(contentsOf: Array("WAVE".utf8))
        h.append(contentsOf: Array("fmt ".utf8))
        h.append(contentsOf: u32(16))               // fmt chunk size
        h.append(contentsOf: u16(1))                // PCM
        h.append(contentsOf: u16(ch))
        h.append(contentsOf: u32(sr))
        h.append(contentsOf: u32(br))
        h.append(contentsOf: u16(ba))
        h.append(contentsOf: u16(bps))
        h.append(contentsOf: Array("data".utf8))
        h.append(contentsOf: u32(dataSize))

        return h
    }
}
