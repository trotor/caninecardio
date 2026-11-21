import CardioCore
import Foundation

/// A fully loaded session (motion data in memory, audio referenced by URL).
public struct RecordedSession: Sendable {
    public var metadata: SessionMetadata
    public var directory: URL
    public var accelerometer: MotionSeries?
    public var gyroscope: MotionSeries?

    public var audioURL: URL? {
        metadata.audio.map { directory.appendingPathComponent($0.fileName) }
    }

    /// All files in the folder that are useful to export.
    public var exportURLs: [URL] {
        var names = [SessionStore.metadataFileName]
        if let a = metadata.accelerometer { names.append(a.fileName) }
        if let g = metadata.gyroscope { names.append(g.fileName) }
        if let au = metadata.audio { names.append(au.fileName) }
        names.append(BeatAnnotations.fileName)
        return names.map { directory.appendingPathComponent($0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }
}

public struct SessionSummary: Sendable, Identifiable, Equatable {
    public var metadata: SessionMetadata
    public var directory: URL
    public var id: String { metadata.id }
}

/// Stores each session as a folder `<root>/<id>/` containing
/// `metadata.json`, `accelerometer.csv`, `gyroscope.csv` and optionally `audio.wav`.
///
/// `metadata.json` is written last, so a folder without it is an incomplete recording.
public struct SessionStore: Sendable {
    public static let metadataFileName = "metadata.json"
    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    /// `<Documents>/Sessions`, visible in the Files app when file sharing is enabled.
    public static func defaultStore() throws -> SessionStore {
        let docs = try FileManager.default.url(for: .documentDirectory, in: .userDomainMask,
                                               appropriateFor: nil, create: true)
        return SessionStore(root: docs.appendingPathComponent("Sessions", isDirectory: true))
    }

    public static func makeSessionID(date: Date = Date(), synthetic: Bool = false) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        let suffix = String(UInt16.random(in: 0...UInt16.max), radix: 16, uppercase: true)
        let id = "\(f.string(from: date))-\(String(repeating: "0", count: 4 - suffix.count))\(suffix)"
        return synthetic ? "SYNTHETIC-\(id)" : id
    }

    public func directory(for id: String) -> URL {
        root.appendingPathComponent(id, isDirectory: true)
    }

    /// Creates the folder for a new session (audio is streamed into it while recording).
    @discardableResult
    public func createSessionDirectory(id: String) throws -> URL {
        let dir = directory(for: id)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Writes motion CSVs, then metadata (which marks the session complete).
    public func finalize(metadata: SessionMetadata, accelerometer: MotionSeries?,
                         gyroscope: MotionSeries?) throws {
        let dir = try createSessionDirectory(id: metadata.id)
        if let accelerometer {
            try MotionCSV.write(accelerometer, referenceUptimeS: metadata.referenceUptimeS,
                                to: dir.appendingPathComponent(MotionSensorKind.accelerometer.fileName))
        }
        if let gyroscope {
            try MotionCSV.write(gyroscope, referenceUptimeS: metadata.referenceUptimeS,
                                to: dir.appendingPathComponent(MotionSensorKind.gyroscope.fileName))
        }
        try Self.encoder.encode(metadata).write(
            to: dir.appendingPathComponent(Self.metadataFileName), options: .atomic)
    }

    public func list() throws -> [SessionSummary] {
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }
        let dirs = try FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
        return dirs.compactMap { dir in
            guard let data = try? Data(contentsOf: dir.appendingPathComponent(Self.metadataFileName)),
                  let meta = try? Self.decoder.decode(SessionMetadata.self, from: data)
            else { return nil }
            return SessionSummary(metadata: meta, directory: dir)
        }
        .sorted { $0.metadata.createdAt > $1.metadata.createdAt }
    }

    /// Folders without metadata.json (e.g. the app was killed while recording).
    public func incompleteSessionDirectories() throws -> [URL] {
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil,
                                                           options: [.skipsHiddenFiles])
            .filter { !FileManager.default.fileExists(atPath: $0.appendingPathComponent(Self.metadataFileName).path) }
    }

    public func load(id: String) throws -> RecordedSession {
        let dir = directory(for: id)
        let meta = try Self.decoder.decode(
            SessionMetadata.self, from: Data(contentsOf: dir.appendingPathComponent(Self.metadataFileName)))
        let accel = try meta.accelerometer.map {
            try MotionCSV.read(dir.appendingPathComponent($0.fileName), kind: .accelerometer)
        }
        let gyro = try meta.gyroscope.map {
            try MotionCSV.read(dir.appendingPathComponent($0.fileName), kind: .gyroscope)
        }
        return RecordedSession(metadata: meta, directory: dir, accelerometer: accel, gyroscope: gyro)
    }

    public func delete(id: String) throws {
        try FileManager.default.removeItem(at: directory(for: id))
    }

    public static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    public static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}
