import CardioCore
import Foundation
import SwiftUI

enum Fmt {
    static func hz(_ v: Double?) -> String {
        guard let v, v.isFinite else { return "–" }
        return v >= 1000 ? String(format: "%.1f kHz", v / 1000) : String(format: "%.1f Hz", v)
    }

    static func ms(_ seconds: Double?, digits: Int = 2) -> String {
        guard let seconds, seconds.isFinite else { return "–" }
        return String(format: "%.\(digits)f ms", seconds * 1000)
    }

    static func clock(_ seconds: Double?) -> String {
        guard let seconds, seconds.isFinite else { return "--:--" }
        let s = max(0, Int(seconds.rounded(.down)))
        return String(format: "%02d:%02d", s / 60, s % 60)
    }

    static func duration(_ seconds: Double) -> String {
        String(format: "%.1f s", seconds)
    }

    static func number(_ v: Double?, digits: Int = 1) -> String {
        guard let v, v.isFinite else { return "–" }
        return String(format: "%.\(digits)f", v)
    }

    static let dateTime: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .medium
        return f
    }()
}

extension MotionLevel {
    var label: String {
        switch self {
        case .unknown: "–"
        case .still: "Still"
        case .slight: "Slight motion"
        case .moving: "Moving"
        }
    }

    var color: Color {
        switch self {
        case .unknown: .secondary
        case .still: .green
        case .slight: .yellow
        case .moving: .red
        }
    }
}

extension SessionMetadata.EndReason {
    var label: String {
        switch self {
        case .completed: "Completed"
        case .stoppedByUser: "Stopped early"
        case .interrupted: "Interrupted"
        case .failed: "Failed"
        }
    }
}

/// Small label/value row in monospaced digits, used across instrument-style screens.
struct ValueRow: View {
    let label: String
    let value: String

    init(_ label: String, _ value: String) {
        self.label = label
        self.value = value
    }

    var body: some View {
        LabeledContent(label) {
            Text(value).monospacedDigit().foregroundStyle(.primary)
        }
        .font(.callout)
    }
}
