// swift-tools-version: 6.0
// CardioKit: the sensor-independent, testable core of CanineCardio.
//
//  CardioCore        shared value types, sampling statistics, live ring buffers
//  SignalProcessing  filtering, resampling, peak detection, beat intervals, scoring
//  Storage           session folders, CSV/JSON persistence
//  Acquisition       Core Motion / AVAudioEngine recorders + session orchestration
//                    (hardware code is iOS-only; orchestration is testable on macOS)
//  SyntheticData     clearly-labelled synthetic signals for tests and previews
//  cardio-synth      CLI that writes synthetic example sessions to disk

import PackageDescription

let package = Package(
    name: "CardioKit",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "CardioCore", targets: ["CardioCore"]),
        .library(name: "SignalProcessing", targets: ["SignalProcessing"]),
        .library(name: "Storage", targets: ["Storage"]),
        .library(name: "Acquisition", targets: ["Acquisition"]),
        .library(name: "SyntheticData", targets: ["SyntheticData"]),
        .executable(name: "cardio-synth", targets: ["cardio-synth"]),
    ],
    targets: [
        .target(name: "CardioCore"),
        .target(name: "SignalProcessing", dependencies: ["CardioCore"]),
        .target(name: "Storage", dependencies: ["CardioCore"]),
        .target(name: "Acquisition", dependencies: ["CardioCore", "Storage"]),
        .target(name: "SyntheticData", dependencies: ["CardioCore"]),
        .executableTarget(name: "cardio-synth", dependencies: ["CardioCore", "Storage", "SyntheticData"]),

        .testTarget(name: "CardioCoreTests", dependencies: ["CardioCore"]),
        .testTarget(name: "SignalProcessingTests", dependencies: ["SignalProcessing", "CardioCore"]),
        .testTarget(name: "StorageTests", dependencies: ["Storage", "CardioCore"]),
        .testTarget(name: "AcquisitionTests", dependencies: ["Acquisition", "Storage", "CardioCore"]),
        .testTarget(name: "ValidationTests", dependencies: ["SignalProcessing", "SyntheticData", "CardioCore"]),
    ],
    swiftLanguageModes: [.v6]
)
