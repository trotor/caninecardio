import CardioCore
import Foundation

/// Motion CSV format (one file per sensor):
///
/// ```
/// index,t_rel_s,t_uptime_s,received_uptime_s,x_g,y_g,z_g          (accelerometer, units g)
/// index,t_rel_s,t_uptime_s,received_uptime_s,x_rad_s,y_rad_s,z_rad_s (gyroscope, rad/s)
/// ```
///
/// * `t_uptime_s`: sensor timestamp on the monotonic uptime clock (`CMLogItem.timestamp`).
/// * `t_rel_s`: `t_uptime_s - referenceUptimeS` from metadata.json.
/// * `received_uptime_s`: uptime when the app received the sample (delivery latency diagnostics).
///
/// Rows are in arrival order; timestamps are *not* resampled and may be irregular.
public enum MotionCSV {
    public static func header(for kind: MotionSensorKind) -> String {
        let suffix = kind == .accelerometer ? "g" : "rad_s"
        return "index,t_rel_s,t_uptime_s,received_uptime_s,x_\(suffix),y_\(suffix),z_\(suffix)"
    }

    public static func encode(_ series: MotionSeries, referenceUptimeS: Double) -> String {
        var out = header(for: series.kind) + "\n"
        out.reserveCapacity(series.samples.count * 80)
        for (i, s) in series.samples.enumerated() {
            out += String(format: "%d,%.6f,%.6f,%.6f,%.7f,%.7f,%.7f\n",
                          i, s.t - referenceUptimeS, s.t, s.receivedAt, s.x, s.y, s.z)
        }
        return out
    }

    public static func write(_ series: MotionSeries, referenceUptimeS: Double, to url: URL) throws {
        try Data(encode(series, referenceUptimeS: referenceUptimeS).utf8).write(to: url, options: .atomic)
    }

    public enum ParseError: Error, LocalizedError, Equatable {
        case missingHeader
        case unexpectedHeader(String)
        case badRow(line: Int)

        public var errorDescription: String? {
            switch self {
            case .missingHeader: "CSV file is empty."
            case .unexpectedHeader(let h): "Unrecognised CSV header: \(h)"
            case .badRow(let line): "Malformed CSV row at line \(line)."
            }
        }
    }

    public static func decode(_ text: String, kind: MotionSensorKind) throws -> MotionSeries {
        var lines = text.split(whereSeparator: \.isNewline).makeIterator()
        guard let headerLine = lines.next() else { throw ParseError.missingHeader }
        guard String(headerLine) == header(for: kind) else {
            throw ParseError.unexpectedHeader(String(headerLine))
        }
        var samples = [Vector3Sample]()
        var lineNo = 1
        while let line = lines.next() {
            lineNo += 1
            let f = line.split(separator: ",", omittingEmptySubsequences: false)
            guard f.count == 7,
                  let t = Double(f[2]), let r = Double(f[3]),
                  let x = Double(f[4]), let y = Double(f[5]), let z = Double(f[6])
            else { throw ParseError.badRow(line: lineNo) }
            samples.append(Vector3Sample(t: t, x: x, y: y, z: z, receivedAt: r))
        }
        return MotionSeries(kind: kind, samples: samples)
    }

    public static func read(_ url: URL, kind: MotionSensorKind) throws -> MotionSeries {
        try decode(String(contentsOf: url, encoding: .utf8), kind: kind)
    }
}
