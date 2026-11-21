import CardioCore
import Charts
import SignalProcessing
import Storage
import SwiftUI

struct SessionDetailView: View {
    let sessionID: String
    var onDelete: () -> Void = {}

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var session: RecordedSession?
    @State private var loadError: String?
    @State private var confirmDelete = false

    var body: some View {
        Group {
            if let session {
                content(session)
            } else if let loadError {
                ContentUnavailableView("Could not open session", systemImage: "exclamationmark.triangle",
                                       description: Text(loadError))
            } else {
                ProgressView("Loading…")
            }
        }
        .navigationTitle(session?.metadata.label.isEmpty == false ? session!.metadata.label : "Session")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: sessionID) { await load() }
    }

    private func load() async {
        let store = model.store
        let id = sessionID
        do {
            session = try await Task.detached(priority: .userInitiated) { try store.load(id: id) }.value
        } catch {
            loadError = error.localizedDescription
        }
    }

    @ViewBuilder
    private func content(_ s: RecordedSession) -> some View {
        let m = s.metadata
        ScrollViewReader { proxy in
        List {
            if m.isSynthetic {
                Section {
                    Label(m.syntheticDescription ?? "Synthetic data — not a measurement.", systemImage: "exclamationmark.triangle")
                        .font(.footnote).foregroundStyle(.purple)
                }
            }
            Section("Recording") {
                ValueRow("Session", m.id)
                ValueRow("Started", Fmt.dateTime.string(from: m.createdAt))
                ValueRow("Duration", "\(Fmt.duration(m.recordedDurationS)) of \(Fmt.duration(m.requestedDurationS))")
                ValueRow("End", m.endReason.label)
                ValueRow("Device", "\(m.device.modelIdentifier) · \(m.device.systemName) \(m.device.systemVersion)")
                ValueRow("App", m.appVersion)
            }
            if !m.notes.isEmpty {
                Section("Notes") {
                    ForEach(m.notes, id: \.self) { Text($0).font(.footnote) }
                }
            }
            BeatAnalysisSection(session: s, store: model.store)
                .id("beats")
            if let a = m.accelerometer { MotionStreamSection(title: "Accelerometer", info: a, requested: m.requestedMotionRateHz) }
            if let g = m.gyroscope { MotionStreamSection(title: "Gyroscope", info: g, requested: m.requestedMotionRateHz) }
            if let au = m.audio { AudioSection(info: au, referenceUptime: m.referenceUptimeS) }

            if let accel = s.accelerometer, accel.samples.count > 10 {
                Section {
                    SignalExplorer(series: accel, referenceUptime: m.referenceUptimeS)
                        .id("signals")
                } header: {
                    Text("Accelerometer signal")
                } footer: {
                    Text("Filter bands are exploratory candidates. Peaks in a filtered trace are not necessarily heartbeats.")
                }
            }
            if let url = s.audioURL, let au = m.audio {
                Section("Microphone level") {
                    AudioEnvelopeChart(url: url, info: au, referenceUptime: m.referenceUptimeS)
                }
            }
            Section("Export") {
                ShareLink(items: s.exportURLs) {
                    Label("Share CSV, WAV and metadata", systemImage: "square.and.arrow.up")
                }
                Text("Files: \(s.exportURLs.map(\.lastPathComponent).joined(separator: ", ")). Also available in the Files app under CanineCardio › Sessions › \(m.id).")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Delete session", role: .destructive) { confirmDelete = true }
            }
        }
        .task {
            #if DEBUG
            // DEBUG-only: `-CCScrollTo beats|signals` for Simulator screenshots.
            if let target = UserDefaults.standard.string(forKey: "CCScrollTo") {
                try? await Task.sleep(for: .milliseconds(800))
                proxy.scrollTo(target, anchor: .top)
            }
            #endif
        }
        }
        .confirmationDialog("Delete this session and all its files?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                try? model.store.delete(id: m.id)
                onDelete()
                dismiss()
            }
        }
    }
}

private struct MotionStreamSection: View {
    let title: String
    let info: MotionStreamInfo
    let requested: Double

    var body: some View {
        let s = info.sampling
        Section(title) {
            ValueRow("Samples", "\(s.sampleCount)")
            ValueRow("Effective rate", "\(Fmt.hz(s.effectiveRateHz)) (requested \(Fmt.hz(requested)))")
            ValueRow("Interval mean ± SD", "\(Fmt.ms(s.meanIntervalS)) ± \(Fmt.ms(s.stdIntervalS))")
            ValueRow("Interval min / max", "\(Fmt.ms(s.minIntervalS)) / \(Fmt.ms(s.maxIntervalS))")
            ValueRow("Gaps > \(Fmt.number(s.gapFactor))× median", "\(s.gapCount) (≈\(s.estimatedMissingSamples) samples missing)")
            if s.nonIncreasingIntervals > 0 { ValueRow("Non-increasing timestamps", "\(s.nonIncreasingIntervals)") }
            ValueRow("Median delivery latency", Fmt.ms(info.medianDeliveryLatencyS, digits: 1))
        }
    }
}

private struct AudioSection: View {
    let info: AudioStreamInfo
    let referenceUptime: Double

    var body: some View {
        Section("Microphone") {
            ValueRow("Sample rate", Fmt.hz(info.sampleRateHz))
            ValueRow("Frames", "\(info.frameCount) (\(Fmt.duration(info.durationS)))")
            ValueRow("Channels", "\(info.channelCount)")
            ValueRow("First frame vs motion t=0", Fmt.ms(info.firstFrameUptimeS.map { $0 - referenceUptime }, digits: 2))
            ValueRow("Input latency (not applied)", Fmt.ms(info.inputLatencyS, digits: 1))
            ValueRow("IO buffer", Fmt.ms(info.ioBufferDurationS, digits: 1))
            ValueRow("Discontinuities", "\(info.sampleTimeDiscontinuities) (\(info.discontinuityFrames) frames)")
            ValueRow("Sample-clock drift", info.sampleClockDriftPPM.map { String(format: "%.1f ppm", $0) } ?? "–")
            ValueRow("Input", [info.inputPortName, info.inputDataSource].compactMap { $0 }.joined(separator: " · "))
            ValueRow("Session mode", info.sessionMode)
        }
    }
}

/// Plots one accelerometer axis over the whole recording plus a zoomed, optionally filtered window.
private struct SignalExplorer: View {
    let series: MotionSeries
    let referenceUptime: Double

    enum BandChoice: Hashable, Identifiable {
        case raw
        case band(FrequencyBand)
        var id: String { label }
        var label: String {
            switch self {
            case .raw: "Raw (detrended)"
            case .band(let b): b.name
            }
        }
    }

    @State private var axis: MotionAxis = .z
    @State private var band: BandChoice = .raw
    @State private var windowStart = 0.0
    @State private var windowLength = 10.0
    @State private var processed: Processed?
    @State private var error: String?

    struct Processed: Sendable {
        var t: [Double]          // seconds relative to recording start
        var overview: [Point]    // decimated, whole recording
        var values: [Double]     // full resolution, processed
    }

    struct Point: Identifiable, Sendable {
        var id: Int
        var t: Double
        var v: Double
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Axis", selection: $axis) {
                ForEach(MotionAxis.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            Picker("Band", selection: $band) {
                Text(BandChoice.raw.label).tag(BandChoice.raw)
                ForEach(FrequencyBand.motionPresets) { Text($0.name).tag(BandChoice.band($0)) }
            }
            if let error { Text(error).foregroundStyle(.red).font(.footnote) }
            if let p = processed, let last = p.t.last {
                Chart {
                    LinePlot(p.overview, x: .value("Time (s)", \.t), y: .value("g", \.v))
                        .lineStyle(StrokeStyle(lineWidth: 0.7))
                    RectangleMark(xStart: .value("s", windowStart), xEnd: .value("e", min(last, windowStart + windowLength)))
                        .foregroundStyle(.tint.opacity(0.15))
                }
                .chartXAxisLabel("s")
                .chartYAxisLabel("g")
                .frame(height: 100)

                Chart {
                    LinePlot(windowPoints(p), x: .value("Time (s)", \.t), y: .value("Acceleration (mg)", \.v))
                        .lineStyle(StrokeStyle(lineWidth: 1))
                }
                .chartXScale(domain: windowStart...(windowStart + windowLength))
                .chartYAxisLabel("mg")
                .frame(height: 200)

                HStack {
                    Text("Window").font(.caption)
                    Slider(value: $windowStart, in: 0...max(0.001, last - windowLength))
                    Picker("Length", selection: $windowLength) {
                        ForEach([3.0, 10.0, 30.0], id: \.self) { Text("\(Int($0)) s").tag($0) }
                    }
                    .labelsHidden()
                }
            } else {
                ProgressView().frame(maxWidth: .infinity, minHeight: 100)
            }
        }
        .task(id: "\(axis.rawValue)-\(band.label)") { await process() }
    }

    private func windowPoints(_ p: Processed) -> [Point] {
        let fs = 100.0
        let a = max(0, Int(windowStart * fs)), b = min(p.values.count, Int((windowStart + windowLength) * fs) + 1)
        guard b > a else { return [] }
        return (a..<b).map { Point(id: $0, t: p.t[$0], v: p.values[$0] * 1000) }
    }

    private func process() async {
        let series = self.series, axis = self.axis, band = self.band, ref = referenceUptime
        do {
            processed = try await Task.detached(priority: .userInitiated) { () throws -> Processed in
                let u = Resampler.linear(times: series.timestamps, values: series.values(axis), rateHz: 100)
                var v = Detrend.linear(u.values)
                if case .band(let b) = band {
                    v = try b.filter(order: 2, sampleRateHz: 100).filtfilt(v, padLength: b.padLength(sampleRateHz: 100))
                }
                let t = (0..<v.count).map { u.startTime - ref + Double($0) / 100 }
                let dec = LiveSnapshot(times: t, channels: [v]).decimated(buckets: 600)
                let overview = dec.times.indices.map { Point(id: $0, t: dec.times[$0], v: dec.channels[0][$0]) }
                return Processed(t: t, overview: overview, values: v)
            }.value
            error = nil
        } catch {
            self.error = "Filtering failed: \(error)"
        }
    }
}
