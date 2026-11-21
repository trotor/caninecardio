import CardioCore
import SwiftUI

/// Lightweight live waveform drawn with `Canvas`.
///
/// Swift Charts is used for recorded data; for the live view a Canvas path is far cheaper to
/// redraw at display rate. Only the last `windowS` seconds are copied from the ring buffer, then
/// min/max-decimated to the pixel width, so redraw cost does not grow with recording length.
struct WaveformView: View {
    struct Series {
        var values: [Double]
        var color: Color
    }

    let times: [Double]
    let series: [Series]
    let windowEnd: Double
    let windowS: Double
    /// Minimum half-range of the y axis, so that sensor noise is not magnified to full height.
    let minHalfRange: Double
    let unit: String
    /// Scale factor applied to the displayed scale label (e.g. 1000 for g -> mg).
    let labelScale: Double
    let symmetric: Bool

    var body: some View {
        let range = yRange()
        ZStack(alignment: .topLeading) {
            Canvas { ctx, size in
                // Grid: one vertical line per second, plus the zero/mid line.
                var grid = Path()
                let start = windowEnd - windowS
                var s = start.rounded(.up)
                while s < windowEnd {
                    let x = (s - start) / windowS * size.width
                    grid.move(to: CGPoint(x: x, y: 0))
                    grid.addLine(to: CGPoint(x: x, y: size.height))
                    s += 1
                }
                grid.move(to: CGPoint(x: 0, y: size.height / 2))
                grid.addLine(to: CGPoint(x: size.width, y: size.height / 2))
                ctx.stroke(grid, with: .color(.secondary.opacity(0.25)), lineWidth: 0.5)

                guard times.count > 1 else { return }
                for ser in series {
                    var path = Path()
                    for (i, t) in times.enumerated() {
                        let x = (t - start) / windowS * size.width
                        let y = (1 - (ser.values[i] - range.lowerBound) / (range.upperBound - range.lowerBound)) * size.height
                        let p = CGPoint(x: x, y: min(max(y, 0), size.height))
                        if i == 0 { path.move(to: p) } else { path.addLine(to: p) }
                    }
                    ctx.stroke(path, with: .color(ser.color), lineWidth: 1)
                }
            }
            Text(scaleLabel(range))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
                .padding(4)
        }
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private func yRange() -> ClosedRange<Double> {
        let all = series.flatMap(\.values)
        guard let lo = all.min(), let hi = all.max() else { return -minHalfRange...minHalfRange }
        if symmetric {
            let h = max(minHalfRange, abs(lo), abs(hi)) * 1.1
            return -h...h
        }
        let mid = (lo + hi) / 2, h = max(minHalfRange, (hi - lo) / 2) * 1.1
        return (mid - h)...(mid + h)
    }

    private func scaleLabel(_ r: ClosedRange<Double>) -> String {
        let half = (r.upperBound - r.lowerBound) / 2 * labelScale
        return symmetric ? String(format: "±%.3g %@", half, unit) : String(format: "%.3g–%.3g %@", r.lowerBound * labelScale, r.upperBound * labelScale, unit)
    }
}

extension LiveSnapshot {
    /// Each channel with its own mean removed (display only: shows small vibrations on top of
    /// the ~1 g gravity component).
    func meanRemoved() -> LiveSnapshot {
        LiveSnapshot(times: times, channels: channels.map { ch in
            guard !ch.isEmpty else { return ch }
            let m = ch.reduce(0, +) / Double(ch.count)
            return ch.map { $0 - m }
        })
    }
}
