import CardioCore
import Charts
import SignalProcessing
import Storage
import SwiftUI

/// Experimental beat analysis of a recorded session: runs `CandidateBeatPipeline` on each
/// accelerometer axis, shows candidate beats and intervals, reports a rate only when the
/// reliability gate passes, and lets the operator reject or add beats (saved as `beats.json`).
struct BeatAnalysisSection: View {
    let session: RecordedSession
    let store: SessionStore

    enum AxisChoice: Hashable {
        case auto
        case axis(MotionAxis)
    }

    @State private var choice: AxisChoice = .auto
    @State private var results: [MotionAxis: CandidateBeatPipeline.Result]?
    @State private var edits = BeatEdits()
    @State private var editsAxis: MotionAxis?
    @State private var error: String?
    @State private var saveError: String?
    @State private var windowStart = 0.0
    @State private var windowLength = 10.0

    private let config = CandidateBeatPipeline.Config()
    private var reference: Double { session.metadata.referenceUptimeS }

    var body: some View {
        Section {
            if let error {
                Text(error).foregroundStyle(.red).font(.footnote)
            } else if let results, let axis = activeAxis(results), let result = results[axis] {
                content(result: result, axis: axis)
            } else {
                HStack {
                    ProgressView()
                    Text("Analysing…").foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("Beat analysis (experimental)")
        } footer: {
            Text("Candidate beats from chest-wall vibration (5–30 Hz). These are mechanical intervals, not ECG R-R intervals, and the method has not been validated against a reference. Tap the waveform to reject a beat or to add one at the nearest vibration peak.")
        }
        .task(id: session.metadata.id) { await analyse() }
    }

    // MARK: - Content

    @ViewBuilder
    private func content(result: CandidateBeatPipeline.Result, axis: MotionAxis) -> some View {
        let detected = result.beatTimes
        let activeEdits = editsAxis == axis ? edits : BeatEdits()
        let beats = activeEdits.apply(to: detected)
        let (intervals, summary) = result.evaluate(beatTimes: beats, config: config)

        Picker("Axis", selection: $choice) {
            Text("Auto (\(CandidateBeatPipeline.chooseAxis(results ?? [:])?.rawValue ?? "–"))").tag(AxisChoice.auto)
            ForEach([MotionAxis.x, .y, .z]) { Text($0.rawValue).tag(AxisChoice.axis($0)) }
        }
        .pickerStyle(.segmented)

        VerdictView(summary: summary, beatCount: beats.count, edits: activeEdits)

        waveform(result: result, detected: detected, edits: activeEdits, beats: beats, axis: axis)

        intervalChart(intervals)

        if !activeEdits.isEmpty {
            Button("Reset manual corrections", role: .destructive) {
                edits = BeatEdits()
                store.deleteBeatAnnotations(id: session.metadata.id)
            }
        }
        if let saveError { Text(saveError).font(.caption).foregroundStyle(.red) }
    }

    private func waveform(result: CandidateBeatPipeline.Result, detected: [Double], edits: BeatEdits,
                          beats: [Double], axis: MotionAxis) -> some View {
        let duration = result.raw.durationS
        let start = windowStart, end = windowStart + windowLength
        let fs = result.raw.sampleRateHz
        let offset = result.raw.startTime - reference
        let i0 = max(0, Int((start - offset) * fs)), i1 = min(result.filtered.count, Int((end - offset) * fs) + 1)
        let points = i0 < i1 ? (i0..<i1).map { WavePoint(id: $0, t: offset + Double($0) / fs, v: result.filtered[$0] * 1000) } : []
        let top = max(1, points.map { abs($0.v) }.max() ?? 1) * 1.15
        let inWindow: (Double) -> Bool = { ($0 - reference) >= start && ($0 - reference) <= end }
        let kept = beats.filter(inWindow).map { $0 - reference }
        let rejected = edits.removed.filter(inWindow).map { $0 - reference }
        let added = Set(edits.added.map { $0 - reference })
        let excludedSpans = spans(of: result.excluded, offset: offset, fs: fs).filter { $0.upperBound > start && $0.lowerBound < end }

        return VStack(alignment: .leading, spacing: 6) {
            Chart {
                ForEach(Array(excludedSpans.enumerated()), id: \.offset) { _, span in
                    RectangleMark(xStart: .value("s", max(span.lowerBound, start)), xEnd: .value("e", min(span.upperBound, end)))
                        .foregroundStyle(.gray.opacity(0.2))
                }
                LinePlot(points, x: .value("Time (s)", \.t), y: .value("mg", \.v))
                    .lineStyle(StrokeStyle(lineWidth: 1))
                    .foregroundStyle(.secondary)
                ForEach(kept, id: \.self) { t in
                    RuleMark(x: .value("Beat", t))
                        .lineStyle(StrokeStyle(lineWidth: 1))
                        .foregroundStyle(added.contains(t) ? Color.orange.opacity(0.6) : Color.accentColor.opacity(0.6))
                    PointMark(x: .value("Beat", t), y: .value("mg", top))
                        .symbol(added.contains(t) ? .diamond : .circle)
                        .symbolSize(70)
                        .foregroundStyle(added.contains(t) ? Color.orange : Color.accentColor)
                }
                ForEach(rejected, id: \.self) { t in
                    PointMark(x: .value("Rejected", t), y: .value("mg", top))
                        .symbol { Image(systemName: "xmark").font(.caption2.bold()).foregroundStyle(.gray) }
                }
            }
            .chartXScale(domain: start...end)
            .chartYScale(domain: -top * 1.05...top * 1.1)
            .chartYAxisLabel("mg (axis \(axis.rawValue), 5–30 Hz)")
            .chartOverlay { proxy in
                GeometryReader { geo in
                    Rectangle().fill(.clear).contentShape(Rectangle())
                        .onTapGesture { location in
                            guard let frame = proxy.plotFrame else { return }
                            let x = location.x - geo[frame].origin.x
                            if let t: Double = proxy.value(atX: x) {
                                toggle(at: t + reference, result: result, detected: detected, axis: axis)
                            }
                        }
                }
            }
            .frame(height: 200)

            HStack {
                Slider(value: $windowStart, in: 0...max(0.001, duration - windowLength))
                Picker("Window", selection: $windowLength) {
                    ForEach([5.0, 10.0, 20.0], id: \.self) { Text("\(Int($0)) s").tag($0) }
                }
                .labelsHidden()
            }
            HStack(spacing: 12) {
                legendItem(Color.accentColor, "detected")
                legendItem(.orange, "added")
                legendItem(.gray, "rejected")
                legendItem(.gray.opacity(0.4), "excluded")
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
    }

    private func intervalChart(_ intervals: [BeatInterval]) -> some View {
        let points = intervals.map {
            IntervalPoint(t: $0.endTime - reference, ms: $0.milliseconds, status: $0.isAccepted ? "accepted" : "flagged")
        }
        return VStack(alignment: .leading, spacing: 4) {
            Text("Beat-to-beat intervals").font(.caption).foregroundStyle(.secondary)
            Chart(points) { p in
                PointMark(x: .value("Time (s)", p.t), y: .value("ms", p.ms))
                    .foregroundStyle(by: .value("Status", p.status))
                    .symbolSize(30)
            }
            .chartForegroundStyleScale(["accepted": Color.accentColor, "flagged": Color.orange])
            .chartYAxisLabel("ms")
            .chartXAxisLabel("s")
            .frame(height: 150)
        }
    }

    private func legendItem(_ color: Color, _ label: String) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(label)
        }
    }

    // MARK: - Actions

    private func activeAxis(_ results: [MotionAxis: CandidateBeatPipeline.Result]) -> MotionAxis? {
        switch choice {
        case .auto: CandidateBeatPipeline.chooseAxis(results)
        case .axis(let a): a
        }
    }

    private func toggle(at time: Double, result: CandidateBeatPipeline.Result, detected: [Double], axis: MotionAxis) {
        if editsAxis != axis {
            edits = BeatEdits()
            editsAxis = axis
        }
        edits.toggle(near: time, detected: detected, addAt: result.nearestEnvelopePeak(to: time))
        do {
            try store.saveBeatAnnotations(BeatAnnotations(axis: axis, detectedUptimeS: detected, edits: edits),
                                          id: session.metadata.id)
            saveError = nil
        } catch {
            saveError = "Could not save corrections: \(error.localizedDescription)"
        }
    }

    private func analyse() async {
        guard let accel = session.accelerometer, accel.samples.count > 200 else {
            error = "Not enough accelerometer data to analyse."
            return
        }
        let config = self.config
        do {
            results = try await Task.detached(priority: .userInitiated) {
                var out = [MotionAxis: CandidateBeatPipeline.Result]()
                for axis in [MotionAxis.x, .y, .z] {
                    var c = config
                    c.axis = axis
                    out[axis] = try CandidateBeatPipeline(config: c).run(accel)
                }
                return out
            }.value
        } catch {
            self.error = "Analysis failed: \(error)"
            return
        }
        if let saved = store.loadBeatAnnotations(id: session.metadata.id) {
            choice = .axis(saved.axis)
            edits = saved.edits
            editsAxis = saved.axis
        }
    }

    private func spans(of mask: [Bool], offset: Double, fs: Double) -> [ClosedRange<Double>] {
        var out = [ClosedRange<Double>]()
        var startIndex: Int?
        for (i, m) in mask.enumerated() {
            if m, startIndex == nil { startIndex = i }
            if !m, let s = startIndex {
                out.append((offset + Double(s) / fs)...(offset + Double(i) / fs))
                startIndex = nil
            }
        }
        if let s = startIndex { out.append((offset + Double(s) / fs)...(offset + Double(mask.count) / fs)) }
        return out
    }
}

private struct WavePoint: Identifiable {
    var id: Int
    var t: Double
    var v: Double
}

private struct IntervalPoint: Identifiable {
    var id: Double { t }
    var t: Double
    var ms: Double
    var status: String
}

private struct VerdictView: View {
    let summary: IntervalSummary
    let beatCount: Int
    let edits: BeatEdits

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            switch summary.reliability {
            case .sufficient:
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(Fmt.number(summary.meanRateBPM, digits: 0))
                        .font(.system(size: 40, weight: .medium, design: .monospaced))
                    Text("/min").foregroundStyle(.secondary)
                }
                Text("Mechanical rate estimate (exploratory)").font(.caption).foregroundStyle(.secondary)
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 2) {
                    GridRow { Text("Mean interval").foregroundStyle(.secondary); Text("\(Fmt.number(summary.meanIntervalMs, digits: 0)) ms") }
                    GridRow { Text("Interval SD").foregroundStyle(.secondary); Text("\(Fmt.number(summary.sdMs, digits: 0)) ms") }
                    GridRow { Text("RMSSD").foregroundStyle(.secondary); Text("\(Fmt.number(summary.rmssdMs, digits: 0)) ms") }
                }
                .font(.caption.monospacedDigit())
            case .insufficient(let reasons):
                Label("Insufficient confidence", systemImage: "exclamationmark.triangle.fill")
                    .font(.headline)
                    .foregroundStyle(.orange)
                Text("No rate is reported, because:").font(.caption).foregroundStyle(.secondary)
                ForEach(reasons, id: \.self) { Text("• \($0)").font(.caption) }
            }
            Text("\(beatCount) beats · \(summary.acceptedCount)/\(summary.intervalCount) intervals pass plausibility checks"
                 + (edits.isEmpty ? "" : " · \(edits.removed.count) rejected, \(edits.added.count) added by hand"))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }
}
