#if os(macOS)
import XCTest
@testable import UncleStreamus

final class StreamBufferTests: XCTestCase {

    // MARK: - init clamping

    func testInit_clampsMinimum() {
        let buf = StreamBuffer(maxMinutes: 3)
        XCTAssertEqual(buf.maxSegments, 5)
    }

    func testInit_clampsMaximum() {
        let buf = StreamBuffer(maxMinutes: 35)
        XCTAssertEqual(buf.maxSegments, 30)
    }

    func testInit_withinRange() {
        let buf = StreamBuffer(maxMinutes: 15)
        XCTAssertEqual(buf.maxSegments, 15)
    }

    func testInit_lowerBound() {
        let buf = StreamBuffer(maxMinutes: 5)
        XCTAssertEqual(buf.maxSegments, 5)
    }

    func testInit_upperBound() {
        let buf = StreamBuffer(maxMinutes: 30)
        XCTAssertEqual(buf.maxSegments, 30)
    }

    func testInit_defaultValue() {
        let buf = StreamBuffer()
        XCTAssertEqual(buf.maxSegments, 15)
    }

    // MARK: - bufferedDuration formula

    func testBufferedDuration_zero() {
        let buf = StreamBuffer(maxMinutes: 15)
        XCTAssertEqual(buf.bufferedDuration, 0.0)
    }

    func testBytesPerSecond_correct() {
        let buf = StreamBuffer(maxMinutes: 15)
        // 44100 Hz * 2 channels * 2 bytes/sample (Int16) = 176400 B/s
        XCTAssertEqual(buf.bytesPerSecond, 176_400)
    }

    func testSamplesPerSegment_correct() {
        let buf = StreamBuffer(maxMinutes: 15)
        // 60 s * 44100 Hz * 2 channels = 5_292_000 samples
        XCTAssertEqual(buf.samplesPerSegment, 5_292_000)
    }

    func testCurrentTimestamp_aliasesBufferedDuration() {
        let buf = StreamBuffer(maxMinutes: 15)
        XCTAssertEqual(buf.currentTimestamp, buf.bufferedDuration)
    }

    // MARK: - WAV header structure

    func testWAVHeader_magic() throws {
        let buf = StreamBuffer(maxMinutes: 5)
        buf.start()
        defer {
            buf.stop()
            buf.cleanup()
        }

        // Give the write queue a moment to open the segment and write the header
        Thread.sleep(forTimeInterval: 0.15)

        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("zappastream_dvr_seg_0.wav").path

        guard let data = FileManager.default.contents(atPath: path), data.count >= 44 else {
            XCTFail("Segment file not created or too small (path: \(path))")
            return
        }

        // Bytes 0-3: "RIFF"
        XCTAssertEqual(data[0], UInt8(ascii: "R"))
        XCTAssertEqual(data[1], UInt8(ascii: "I"))
        XCTAssertEqual(data[2], UInt8(ascii: "F"))
        XCTAssertEqual(data[3], UInt8(ascii: "F"))

        // Bytes 8-11: "WAVE"
        XCTAssertEqual(data[8],  UInt8(ascii: "W"))
        XCTAssertEqual(data[9],  UInt8(ascii: "A"))
        XCTAssertEqual(data[10], UInt8(ascii: "V"))
        XCTAssertEqual(data[11], UInt8(ascii: "E"))

        // Bytes 12-15: "fmt "
        XCTAssertEqual(data[12], UInt8(ascii: "f"))
        XCTAssertEqual(data[13], UInt8(ascii: "m"))
        XCTAssertEqual(data[14], UInt8(ascii: "t"))
        XCTAssertEqual(data[15], UInt8(ascii: " "))
    }

    func testWAVHeader_PCMFormat() throws {
        let buf = StreamBuffer(maxMinutes: 5)
        buf.start()
        defer {
            buf.stop()
            buf.cleanup()
        }

        Thread.sleep(forTimeInterval: 0.15)

        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("zappastream_dvr_seg_0.wav").path

        guard let data = FileManager.default.contents(atPath: path), data.count >= 44 else {
            XCTFail("Segment file not created or too small")
            return
        }

        // Bytes 20-21: audio format = 1 (PCM), little-endian
        XCTAssertEqual(data[20], 1)
        XCTAssertEqual(data[21], 0)

        // Bytes 22-23: channels = 2, little-endian
        XCTAssertEqual(data[22], 2)
        XCTAssertEqual(data[23], 0)

        // Bytes 24-27: sample rate = 44100 = 0x0000AC44, little-endian
        XCTAssertEqual(data[24], 0x44)
        XCTAssertEqual(data[25], 0xAC)
        XCTAssertEqual(data[26], 0x00)
        XCTAssertEqual(data[27], 0x00)

        // Bytes 34-35: bits per sample = 16, little-endian
        XCTAssertEqual(data[34], 16)
        XCTAssertEqual(data[35], 0)
    }

    // MARK: - updateMaxSegments

    func testUpdateMaxSegments_updatesValue() {
        let buf = StreamBuffer(maxMinutes: 15)
        buf.start()
        defer {
            buf.stop()
            buf.cleanup()
        }

        // updateMaxSegments applies the change asynchronously on the write queue.
        // Assert only after its completion fires so the test is deterministic on
        // loaded CI runners (a fixed sleep was racy) and free of a cross-thread read.
        let expectation = XCTestExpectation(description: "maxSegments updated to 20")
        buf.updateMaxSegments(20) { expectation.fulfill() }
        wait(for: [expectation], timeout: 2.0)

        XCTAssertEqual(buf.maxSegments, 20)
    }

    // MARK: - sweepStaleSegmentFiles

    func testSweep_removesSegmentFilesAndLeavesOthers() throws {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory
        // Index 42 stands in for a segment orphaned by lowering the buffer-minutes setting:
        // a 0..<maxSegments loop would never reach it, the prefix sweep must.
        let segments = [0, 7, 42].map {
            tmp.appendingPathComponent("\(StreamBuffer.segmentFilePrefix)\($0).wav")
        }
        let unrelated = tmp.appendingPathComponent("unclestreamus_sweep_test_keepme.wav")
        for url in segments + [unrelated] {
            try Data([0x01, 0x02]).write(to: url)
        }
        defer { try? fm.removeItem(at: unrelated) }

        StreamBuffer.sweepStaleSegmentFiles()

        for url in segments {
            XCTAssertFalse(fm.fileExists(atPath: url.path), "segment not swept: \(url.lastPathComponent)")
        }
        XCTAssertTrue(fm.fileExists(atPath: unrelated.path), "sweep deleted an unrelated file")
    }

    // MARK: - Segment-boundary exactness
    //
    // These drive the ring with a sub-second segmentDuration so hundreds of rotations (and
    // the ring wrapping) happen in milliseconds. 0.25 s is chosen deliberately: it is exactly
    // representable in binary *and* 0.25 × 44100 is a whole number of frames, so
    // `bufferedDuration` and `Int(t / segmentDuration)` stay exact and the assertions below
    // are testing the buffer, not float error.

    private static let testSegDur = 0.25              // 11025 frames → 22050 samples/segment

    /// Append `sampleCount` samples in bursts, mimicking the DSP callback.
    private func append(_ sampleCount: Int, to buf: StreamBuffer, burst: Int = 7000) {
        var remaining = sampleCount
        let chunk = [Float](repeating: 0.25, count: burst)
        while remaining > 0 {
            let n = min(remaining, burst)
            chunk.withUnsafeBytes { raw in
                buf.append(buffer: raw.baseAddress!, length: n * MemoryLayout<Float>.size)
            }
            remaining -= n
            // Let the 20 ms write tick keep up so the in-memory ring never overflows.
            if remaining > 0 { Thread.sleep(forTimeInterval: 0.005) }
        }
    }

    @discardableResult
    private func waitUntil(timeout: TimeInterval = 10, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            Thread.sleep(forTimeInterval: 0.02)
        }
        return condition()
    }

    /// The invariant the DVR playback mapping depends on: N segments of audio must produce
    /// exactly N rotations, so `bufferedDuration == currentSegmentNumber * segmentDuration`.
    ///
    /// Before the boundary clamp, the chunk that crossed a boundary was written whole into the
    /// outgoing segment (rotation only checked `>=` afterwards), so each segment ran up to one
    /// chunk long. Playback still mapped time → segment as `t / segmentDuration`, so the two
    /// drifted apart for the whole session — which let the DVR preloader read the surplus as
    /// "one more segment exists" and wrap onto the oldest ring slot.
    func testDrainAndWrite_segmentBoundariesAreExact() {
        let segDur = Self.testSegDur
        let buf = StreamBuffer(maxMinutes: 5, segmentDuration: segDur)
        buf.start()
        defer {
            buf.stop()
            buf.cleanup()
        }

        let segments = 20
        append(segments * Int(buf.samplesPerSegment), to: buf)
        XCTAssertTrue(waitUntil { buf.currentSegmentNumber >= segments },
                      "write queue never reached \(segments) rotations (got \(buf.currentSegmentNumber))")

        XCTAssertEqual(buf.currentSegmentNumber, segments,
                       "each segment must consume exactly samplesPerSegment — no overshoot")
        XCTAssertEqual(buf.bufferedDuration, Double(segments) * segDur, accuracy: 1e-9,
                       "recording time drifted from the segment grid playback assumes")
    }

    /// Reading past the write head must fail rather than wrap onto the oldest ring slot.
    /// This is the reported bug: at the end of a full buffer the preloader asked for the
    /// segment after the last one, `segNum % maxSegments` landed on the pause segment, and
    /// playback spliced the start of the buffer back in instead of going live.
    func testCreatePlaybackStream_refusesReadPastWriteHead() {
        let segDur = Self.testSegDur
        let buf = StreamBuffer(maxMinutes: 5, segmentDuration: segDur)
        buf.start()
        defer {
            buf.stop()
            buf.cleanup()
        }

        // Protect slot 0 the way dvrPause() does, so the ring stops itself once full.
        let full = XCTestExpectation(description: "ring reported buffer full")
        buf.setStopBeforeSegment(index: 0) { full.fulfill() }

        append(6 * Int(buf.samplesPerSegment), to: buf)
        wait(for: [full], timeout: 10.0)

        // Segments 0...4 written, then the ring stopped rather than overwrite slot 0.
        XCTAssertEqual(buf.bufferedDuration, 5 * segDur, accuracy: 1e-9)

        // The exact read preloadDVRNextSegment() makes at the end of the buffer.
        XCTAssertFalse(buf.canPlay(from: buf.bufferedDuration),
                       "end-of-buffer read must fail so DVR goes live")
        XCTAssertEqual(buf.createPlaybackStream(from: buf.bufferedDuration), 0)

        // A timestamp still inside the last segment stays playable. Asserted through canPlay
        // rather than createPlaybackStream: BASS is never initialised in the test process, so
        // BASS_StreamCreateFile returns 0 there whatever the range check decides.
        XCTAssertTrue(buf.canPlay(from: buf.bufferedDuration - segDur / 2),
                      "a timestamp inside the buffer must stay playable")
    }

    /// Audio the ring has already overwritten must fail too — the same modular mapping would
    /// otherwise hand back a much newer segment as if it were the requested history.
    func testCreatePlaybackStream_refusesOverwrittenHistory() {
        let segDur = Self.testSegDur
        let buf = StreamBuffer(maxMinutes: 5, segmentDuration: segDur)
        buf.start()
        defer {
            buf.stop()
            buf.cleanup()
        }

        let segments = 20   // wraps the 5-slot ring four times
        append(segments * Int(buf.samplesPerSegment), to: buf)
        XCTAssertTrue(waitUntil { buf.currentSegmentNumber >= segments })

        XCTAssertEqual(buf.oldestAvailableTimestamp,
                       Double(segments - buf.maxSegments + 1) * segDur, accuracy: 1e-9)

        XCTAssertFalse(buf.canPlay(from: 0),
                       "segment 0 was overwritten long ago; the read must fail, not wrap")
        XCTAssertEqual(buf.createPlaybackStream(from: 0), 0)

        XCTAssertTrue(buf.canPlay(from: buf.oldestAvailableTimestamp),
                      "the oldest intact segment must stay playable")
    }

    func testCleanup_removesSegmentFiles() throws {
        let fm = FileManager.default
        let buf = StreamBuffer(maxMinutes: 5)
        buf.start()
        Thread.sleep(forTimeInterval: 0.15)   // let the write queue open segment 0

        let seg0 = fm.temporaryDirectory
            .appendingPathComponent("\(StreamBuffer.segmentFilePrefix)0.wav")
        XCTAssertTrue(fm.fileExists(atPath: seg0.path), "segment 0 was never created")

        buf.stop()
        buf.cleanup()

        XCTAssertFalse(fm.fileExists(atPath: seg0.path))
    }
}
#endif
