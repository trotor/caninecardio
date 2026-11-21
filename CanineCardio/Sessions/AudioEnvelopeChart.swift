import AVFoundation
import Accelerate
import CardioCore
import Charts
import SwiftUI

/// Microphone RMS level over the whole recording, read from the WAV file in chunks.
struct AudioEnvelopeChart: View {
    let url: URL
    let info: AudioStreamInfo
    let referenceUptime: Double

    struct Point: Identifiable, Sendable {
        var id: Int
        var t: Double
        var v: Double
    }

    @State private var points: [Point]?
    @State private var error: String?

    var body: some View {
        Group {
            if let points {
                Chart {
                    LinePlot(points, x: .value("Time (s)", \.t), y: .value("RMS (FS)", \.v))
                        .foregroundStyle(.orange)
                        .lineStyle(StrokeStyle(lineWidth: 0.7))
                }
                .chartXAxisLabel("s (motion time base)")
                .frame(height: 120)
            } else if let error {
                Text(error).font(.footnote).foregroundStyle(.red)
            } else {
                ProgressView().frame(maxWidth: .infinity, minHeight: 60)
            }
        }
        .task(id: url) { await load() }
    }

    private func load() async {
        let url = self.url
        let offset = (info.firstFrameUptimeS ?? referenceUptime) - referenceUptime
        do {
            points = try await Task.detached(priority: .utility) { try Self.envelope(url: url, offset: offset) }.value
        } catch {
            self.error = "Could not read audio: \(error.localizedDescription)"
        }
    }

    /// 10 ms RMS of channel 0, min/max decimated to ~1200 points.
    nonisolated static func envelope(url: URL, offset: Double) throws -> [Point] {
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        let fs = file.processingFormat.sampleRate
        let hop = max(1, Int(fs / 100))
        let chunk = AVAudioFrameCount(hop * 100)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: chunk) else { return [] }
        var times = [Double](), values = [Double]()
        var frame = 0
        while file.framePosition < file.length {
            try file.read(into: buffer, frameCount: chunk)
            let n = Int(buffer.frameLength)
            guard n > 0, let ch = buffer.floatChannelData?[0] else { break }
            var i = 0
            while i < n {
                let len = min(hop, n - i)
                var rms: Float = 0
                vDSP_rmsqv(ch + i, 1, &rms, vDSP_Length(len))
                times.append(offset + Double(frame + i) / fs)
                values.append(Double(rms))
                i += len
            }
            frame += n
        }
        let dec = LiveSnapshot(times: times, channels: [values]).decimated(buckets: 600)
        return dec.times.indices.map { Point(id: $0, t: dec.times[$0], v: dec.channels[0][$0]) }
    }
}
