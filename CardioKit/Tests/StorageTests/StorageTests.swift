import CardioCore
import SignalProcessing
import XCTest
@testable import Storage

final class StorageTests: XCTestCase {
    var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("CardioKitTests-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func series(_ kind: MotionSensorKind, n: Int = 50) -> MotionSeries {
        MotionSeries(kind: kind, samples: (0..<n).map { i in
            let t = 1234.5 + Double(i) * 0.0101
            return Vector3Sample(t: t, x: 0.0123456 * Double(i), y: -0.5, z: -0.9987654, receivedAt: t + 0.012)
        })
    }

    private func metadata(id: String, created: Date = Date(timeIntervalSince1970: 1_800_000_000)) -> SessionMetadata {
        let a = series(.accelerometer), g = series(.gyroscope)
        return SessionMetadata(
            id: id, isSynthetic: true, createdAt: created, label: "unit test", requestedDurationS: 30,
            recordedDurationS: 0.5, endReason: .stoppedByUser, referenceUptimeS: 1234.5, requestedMotionRateHz: 100,
            accelerometer: .summarize(a), gyroscope: .summarize(g), audio: nil,
            device: DeviceInfo(modelIdentifier: "test", systemName: "test", systemVersion: "0"),
            appVersion: "test", notes: ["note"])
    }

    func testCSVRoundTrip() throws {
        let s = series(.accelerometer)
        let text = MotionCSV.encode(s, referenceUptimeS: 1234.5)
        XCTAssertTrue(text.hasPrefix("index,t_rel_s,t_uptime_s,received_uptime_s,x_g,y_g,z_g\n0,0.000000,1234.500000,1234.512000,"))
        let back = try MotionCSV.decode(text, kind: .accelerometer)
        XCTAssertEqual(back.samples.count, s.samples.count)
        for (a, b) in zip(back.samples, s.samples) {
            XCTAssertEqual(a.t, b.t, accuracy: 1e-6)
            XCTAssertEqual(a.receivedAt, b.receivedAt, accuracy: 1e-6)
            XCTAssertEqual(a.x, b.x, accuracy: 1e-7)
            XCTAssertEqual(a.z, b.z, accuracy: 1e-7)
        }
    }

    func testGyroHeaderAndWrongHeaderRejected() throws {
        let text = MotionCSV.encode(series(.gyroscope), referenceUptimeS: 0)
        XCTAssertTrue(text.hasPrefix("index,t_rel_s,t_uptime_s,received_uptime_s,x_rad_s,y_rad_s,z_rad_s\n"))
        XCTAssertThrowsError(try MotionCSV.decode(text, kind: .accelerometer))
        XCTAssertThrowsError(try MotionCSV.decode(MotionCSV.header(for: .gyroscope) + "\n1,2,3\n", kind: .gyroscope))
    }

    func testFinalizeListLoadDelete() throws {
        let store = SessionStore(root: root)
        let older = metadata(id: "A", created: Date(timeIntervalSince1970: 1_700_000_000))
        let newer = metadata(id: "B")
        try store.finalize(metadata: older, accelerometer: series(.accelerometer), gyroscope: series(.gyroscope))
        try store.finalize(metadata: newer, accelerometer: series(.accelerometer), gyroscope: nil)
        try store.createSessionDirectory(id: "C-incomplete")

        XCTAssertEqual(try store.list().map(\.id), ["B", "A"])
        XCTAssertEqual(try store.incompleteSessionDirectories().map(\.lastPathComponent), ["C-incomplete"])

        let loaded = try store.load(id: "A")
        XCTAssertEqual(loaded.metadata, older)
        XCTAssertEqual(loaded.accelerometer?.samples.count, 50)
        XCTAssertEqual(loaded.gyroscope?.samples.count, 50)
        XCTAssertEqual(Set(loaded.exportURLs.map(\.lastPathComponent)), ["metadata.json", "accelerometer.csv", "gyroscope.csv"])

        try store.delete(id: "A")
        XCTAssertEqual(try store.list().map(\.id), ["B"])
    }

    func testSessionIDFormat() {
        let id = SessionStore.makeSessionID(date: Date(timeIntervalSince1970: 0))
        XCTAssertTrue(id.hasPrefix("19700101T000000Z-"))
        XCTAssertTrue(SessionStore.makeSessionID(synthetic: true).hasPrefix("SYNTHETIC-"))
    }

    func testBeatAnnotationsRoundTripAndExport() throws {
        let store = SessionStore(root: root)
        try store.finalize(metadata: metadata(id: "A"), accelerometer: series(.accelerometer), gyroscope: series(.gyroscope))
        XCTAssertNil(store.loadBeatAnnotations(id: "A"))
        let ann = BeatAnnotations(axis: .y, detectedUptimeS: [1, 2, 3], edits: BeatEdits(removed: [2], added: [2.4]),
                                  updatedAt: Date(timeIntervalSince1970: 1_800_000_000))
        try store.saveBeatAnnotations(ann, id: "A")
        XCTAssertEqual(store.loadBeatAnnotations(id: "A"), ann)
        XCTAssertEqual(ann.finalBeatsUptimeS, [1, 2.4, 3])
        XCTAssertTrue(try store.load(id: "A").exportURLs.map(\.lastPathComponent).contains("beats.json"))
        store.deleteBeatAnnotations(id: "A")
        XCTAssertNil(store.loadBeatAnnotations(id: "A"))
    }
}
