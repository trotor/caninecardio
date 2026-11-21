import Foundation

public enum AcquisitionError: Error, LocalizedError, Equatable {
    case accelerometerUnavailable
    case microphonePermissionDenied
    case microphoneUnavailable(String)
    case audioSessionFailed(String)
    case audioFileFailed(String)
    case storageFailed(String)
    case alreadyRunning

    public var errorDescription: String? {
        switch self {
        case .accelerometerUnavailable:
            "The accelerometer is not available. Motion recording requires a physical iPhone; the Simulator has no motion sensors."
        case .microphonePermissionDenied:
            "Microphone access is denied. Enable it in Settings › Privacy & Security › Microphone, or turn off audio recording to record motion only."
        case .microphoneUnavailable(let detail):
            "No usable microphone input: \(detail)"
        case .audioSessionFailed(let detail):
            "Could not configure the audio session: \(detail)"
        case .audioFileFailed(let detail):
            "Could not write the audio file: \(detail)"
        case .storageFailed(let detail):
            "Could not save the recording: \(detail)"
        case .alreadyRunning:
            "A recording is already in progress."
        }
    }
}
