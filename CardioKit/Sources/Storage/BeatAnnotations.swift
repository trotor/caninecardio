import CardioCore
import Foundation
import SignalProcessing

/// Saved beat analysis of a session (`beats.json`): which axis and algorithm were used, the
/// automatically detected beats, and the operator's manual corrections. Times are uptime seconds.
public struct BeatAnnotations: Codable, Sendable, Equatable {
    public static let fileName = "beats.json"
    public static let currentFormatVersion = 1

    public var formatVersion = BeatAnnotations.currentFormatVersion
    public var algorithm = "CandidateBeatPipeline (experimental, not validated)"
    public var axis: MotionAxis
    public var detectedUptimeS: [Double]
    public var edits: BeatEdits
    public var updatedAt: Date

    public init(axis: MotionAxis, detectedUptimeS: [Double], edits: BeatEdits, updatedAt: Date = Date()) {
        self.axis = axis
        self.detectedUptimeS = detectedUptimeS
        self.edits = edits
        self.updatedAt = updatedAt
    }

    public var finalBeatsUptimeS: [Double] { edits.apply(to: detectedUptimeS) }
}

extension SessionStore {
    public func loadBeatAnnotations(id: String) -> BeatAnnotations? {
        let url = directory(for: id).appendingPathComponent(BeatAnnotations.fileName)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? Self.decoder.decode(BeatAnnotations.self, from: data)
    }

    public func saveBeatAnnotations(_ annotations: BeatAnnotations, id: String) throws {
        let url = directory(for: id).appendingPathComponent(BeatAnnotations.fileName)
        try Self.encoder.encode(annotations).write(to: url, options: .atomic)
    }

    public func deleteBeatAnnotations(id: String) {
        try? FileManager.default.removeItem(at: directory(for: id).appendingPathComponent(BeatAnnotations.fileName))
    }
}
