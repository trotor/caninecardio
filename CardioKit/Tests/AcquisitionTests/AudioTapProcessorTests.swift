import AVFoundation
import CardioCore
import XCTest
@testable import Acquisition

final class AudioTapProcessorTests: XCTestCase {
    let fs = 8000.0   // lowest rate the WAV writer supports
    let frames = 800  // 100 ms buffers
    var url: URL!

    override func setUp() {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("tap-\(UUID().uuidString).wav")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: url)
    }

    /// Host time in microseconds so the injected converter is exact.
    private func makeProcessor(gate: CaptureGate) -> AudioTapProcessor {
        AudioTapProcessor(sampleRate: fs, channelCount: 1, live: LiveRingBuffer(capacity: 1000, channelCount: 2),
                          gate: gate, hostTimeToSeconds: { Double($0) / 1e6 })
    }

    /// Buffer `k` holds 100 ms of frames whose values equal their global frame index.
    private func feed(_ p: AudioTapProcessor, buffers: [Int]) {
        let format = AVAudioFormat(standardFormatWithSampleRate: fs, channels: 1)!
        for k in buffers {
            let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
            buf.frameLength = AVAudioFrameCount(frames)
            for i in 0..<frames { buf.floatChannelData![0][i] = Float(k * frames + i) }
            let start = Double(k) * 0.1
            let time = AVAudioTime(hostTime: UInt64((start * 1e6).rounded()), sampleTime: AVAudioFramePosition(k * frames), atRate: fs)
            p.process(buf, time: time, receivedAt: start + 0.12)
        }
    }

    private func readBack() throws -> [Float] {
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        XCTAssertEqual(file.fileFormat.sampleRate, fs)
        let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
        try file.read(into: buf)
        return Array(UnsafeBufferPointer(start: buf.floatChannelData![0], count: Int(buf.frameLength)))
    }

    func testWritesExactlyTheGatedFrames() throws {
        let gate = CaptureGate()
        gate.open(start: 0.25, end: 0.75)
        let p = makeProcessor(gate: gate)
        try p.openFile(url: url)
        feed(p, buffers: Array(0..<10))
        let summary = try XCTUnwrap(p.closeFile())
        XCTAssertEqual(summary.framesWritten, 4000)
        XCTAssertEqual(summary.firstFrameUptime!, 0.25, accuracy: 1e-9)
        XCTAssertEqual(summary.firstFrameSampleTime, 2000)
        XCTAssertEqual(summary.discontinuities, 0)
        XCTAssertEqual(summary.driftPPM ?? 0, 0, accuracy: 1e-3)
        XCTAssertEqual(summary.medianDeliveryLatency!, 0.12, accuracy: 1e-9)
        let samples = try readBack()
        XCTAssertEqual(samples.count, 4000)
        XCTAssertEqual(samples.first, 2000)
        XCTAssertEqual(samples.last, 5999)
    }

    func testNothingWrittenWhileGateClosed() throws {
        let p = makeProcessor(gate: CaptureGate())
        try p.openFile(url: url)
        feed(p, buffers: [0, 1, 2])
        XCTAssertEqual(p.closeFile()?.framesWritten, 0)
        XCTAssertEqual(p.live.totalAppended, 30, "live envelope runs regardless of gate (10 ms chunks)")
    }

    func testCountsSampleTimeDiscontinuities() throws {
        let gate = CaptureGate()
        gate.open(start: 0, end: 10)
        let p = makeProcessor(gate: gate)
        try p.openFile(url: url)
        feed(p, buffers: [0, 1, 2, 4, 5])     // buffer 3 lost
        let s = try XCTUnwrap(p.closeFile())
        XCTAssertEqual(s.discontinuities, 1)
        XCTAssertEqual(s.discontinuityFrames, 800)
        XCTAssertEqual(s.framesWritten, 4000)
        XCTAssertNil(s.driftPPM, "drift is not estimated across discontinuities")
    }

    func testLiveEnvelopeValues() throws {
        let p = makeProcessor(gate: CaptureGate())
        feed(p, buffers: [0])
        let snap = p.live.snapshot()
        XCTAssertEqual(snap.times.first!, 0.005, accuracy: 1e-9)
        XCTAssertEqual(snap.channels[1].first, 79, "peak of frames 0...79")
    }
}
