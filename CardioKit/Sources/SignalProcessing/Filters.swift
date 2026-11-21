import Foundation

/// One second-order section, normalised so a0 = 1:
/// H(z) = (b0 + b1 z^-1 + b2 z^-2) / (1 + a1 z^-1 + a2 z^-2)
public struct Biquad: Sendable, Equatable {
    public var b0, b1, b2, a1, a2: Double

    public init(b0: Double, b1: Double, b2: Double, a1: Double, a2: Double) {
        self.b0 = b0; self.b1 = b1; self.b2 = b2; self.a1 = a1; self.a2 = a2
    }

    /// DC gain H(1).
    public var dcGain: Double { (b0 + b1 + b2) / (1 + a1 + a2) }

    /// |H(e^{jw})| at frequency `f` for sample rate `fs`.
    public func magnitude(at f: Double, fs: Double) -> Double {
        let w = 2 * Double.pi * f / fs
        let (c1, s1, c2, s2) = (cos(w), sin(w), cos(2 * w), sin(2 * w))
        let nr = b0 + b1 * c1 + b2 * c2, ni = -(b1 * s1 + b2 * s2)
        let dr = 1 + a1 * c1 + a2 * c2, di = -(a1 * s1 + a2 * s2)
        return ((nr * nr + ni * ni) / (dr * dr + di * di)).squareRoot()
    }
}

/// A cascade of second-order sections (like scipy's `sos` representation).
public struct SOSFilter: Sendable, Equatable {
    public var sections: [Biquad]

    public init(sections: [Biquad]) { self.sections = sections }

    public func cascaded(with other: SOSFilter) -> SOSFilter {
        SOSFilter(sections: sections + other.sections)
    }

    public func magnitude(at f: Double, fs: Double) -> Double {
        sections.reduce(1) { $0 * $1.magnitude(at: f, fs: fs) }
    }

    /// Causal filtering (direct form II transposed). With `steadyStateInit`, section states start
    /// as if the input had been constant at `x[0]` forever (like scipy's `lfilter_zi`).
    public func filter(_ x: [Double], steadyStateInit: Bool = true) -> [Double] {
        guard !x.isEmpty else { return [] }
        var y = x
        var level = x[0]
        for s in sections {
            var z1 = 0.0, z2 = 0.0
            if steadyStateInit {
                let out = s.dcGain * level
                z2 = s.b2 * level - s.a2 * out
                z1 = out - s.b0 * level
                level = out
            }
            let (b0, b1, b2, a1, a2) = (s.b0, s.b1, s.b2, s.a1, s.a2)
            y.withUnsafeMutableBufferPointer { buf in
                for i in 0..<buf.count {
                    let xi = buf[i]
                    let yi = b0 * xi + z1
                    z1 = b1 * xi - a1 * yi + z2
                    z2 = b2 * xi - a2 * yi
                    buf[i] = yi
                }
            }
        }
        return y
    }

    /// Zero-phase forward-backward filtering (like scipy `sosfiltfilt`), with odd reflection
    /// padding of `padLength` samples at each end. The effective magnitude response is squared.
    public func filtfilt(_ x: [Double], padLength: Int? = nil) -> [Double] {
        let n = x.count
        guard n > 1 else { return x }
        let pad = min(n - 1, padLength ?? 3 * (2 * sections.count + 1))
        var ext = [Double]()
        ext.reserveCapacity(n + 2 * pad)
        for i in stride(from: pad, through: 1, by: -1) { ext.append(2 * x[0] - x[i]) }
        ext.append(contentsOf: x)
        for i in 1...max(1, pad) where pad > 0 { ext.append(2 * x[n - 1] - x[n - 1 - i]) }
        var y = filter(ext)
        y.reverse()
        y = filter(y)
        y.reverse()
        return Array(y[pad..<(pad + n)])
    }
}

/// Butterworth filter design via the bilinear transform with frequency pre-warping
/// (the same analog prototype and warping as `scipy.signal.butter`).
public enum Butterworth {
    public enum DesignError: Error, Equatable {
        case invalidOrder
        case invalidCutoff
    }

    public static func lowpass(order: Int, cutoffHz: Double, sampleRateHz: Double) throws -> SOSFilter {
        try design(order: order, cutoffHz: cutoffHz, fs: sampleRateHz, highpass: false)
    }

    public static func highpass(order: Int, cutoffHz: Double, sampleRateHz: Double) throws -> SOSFilter {
        try design(order: order, cutoffHz: cutoffHz, fs: sampleRateHz, highpass: true)
    }

    /// Band-pass built as a high-pass (`lowHz`) cascaded with a low-pass (`highHz`), each of
    /// `order`. Equivalent in scipy to concatenating `butter(order, lowHz, 'high', output='sos')`
    /// and `butter(order, highHz, 'low', output='sos')`.
    public static func bandpass(order: Int, lowHz: Double, highHz: Double, sampleRateHz: Double) throws -> SOSFilter {
        guard lowHz < highHz else { throw DesignError.invalidCutoff }
        return try highpass(order: order, cutoffHz: lowHz, sampleRateHz: sampleRateHz)
            .cascaded(with: lowpass(order: order, cutoffHz: highHz, sampleRateHz: sampleRateHz))
    }

    private static func design(order: Int, cutoffHz: Double, fs: Double, highpass: Bool) throws -> SOSFilter {
        guard (1...12).contains(order) else { throw DesignError.invalidOrder }
        guard cutoffHz > 0, cutoffHz < fs / 2 else { throw DesignError.invalidCutoff }
        let k = tan(Double.pi * cutoffHz / fs)     // pre-warped analog cutoff (bilinear, T = 2)
        var sections = [Biquad]()
        // Pole pairs of the normalised analog prototype: s^2 + 2 sin(theta) s + 1.
        for i in 0..<(order / 2) {
            let theta = Double.pi * Double(2 * i + 1) / Double(2 * order)
            let q = 1 / (2 * sin(theta))
            let norm = 1 / (1 + k / q + k * k)
            let a1 = 2 * (k * k - 1) * norm
            let a2 = (1 - k / q + k * k) * norm
            if highpass {
                sections.append(Biquad(b0: norm, b1: -2 * norm, b2: norm, a1: a1, a2: a2))
            } else {
                let b0 = k * k * norm
                sections.append(Biquad(b0: b0, b1: 2 * b0, b2: b0, a1: a1, a2: a2))
            }
        }
        if order % 2 == 1 {                        // real pole: first-order section
            let norm = 1 / (1 + k)
            let a1 = (k - 1) * norm
            if highpass {
                sections.append(Biquad(b0: norm, b1: -norm, b2: 0, a1: a1, a2: 0))
            } else {
                sections.append(Biquad(b0: k * norm, b1: k * norm, b2: 0, a1: a1, a2: 0))
            }
        }
        return SOSFilter(sections: sections)
    }
}

/// Candidate frequency bands. These are starting points for exploration, not validated choices.
public struct FrequencyBand: Sendable, Equatable, Hashable, Identifiable {
    public var name: String
    public var lowHz: Double
    public var highHz: Double
    public var id: String { name }

    public init(name: String, lowHz: Double, highHz: Double) {
        self.name = name
        self.lowHz = lowHz
        self.highHz = highHz
    }

    /// Breathing: roughly 6-60 breaths/min.
    public static let respiration = FrequencyBand(name: "Respiration 0.1–1 Hz", lowHz: 0.1, highHz: 1.0)
    /// Low-frequency whole-body cardiac motion (ballistocardiogram-like), 36-240 beats/min fundamental.
    public static let cardiacPulse = FrequencyBand(name: "Cardiac pulse 0.6–4 Hz", lowHz: 0.6, highHz: 4.0)
    /// Chest-wall vibrations from valve events (seismocardiogram-like). Upper edge limited by
    /// the ~100 Hz motion sampling rate.
    public static let cardiacVibration = FrequencyBand(name: "Cardiac vibration 5–30 Hz", lowHz: 5, highHz: 30)

    public static let motionPresets: [FrequencyBand] = [.respiration, .cardiacPulse, .cardiacVibration]

    public func filter(order: Int = 2, sampleRateHz: Double) throws -> SOSFilter {
        try Butterworth.bandpass(order: order, lowHz: lowHz, highHz: highHz, sampleRateHz: sampleRateHz)
    }

    /// Reflection padding long enough for the slowest edge's transient (3 periods of `lowHz`).
    public func padLength(sampleRateHz: Double) -> Int {
        Int((3 * sampleRateHz / lowHz).rounded(.up))
    }
}
