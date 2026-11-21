# Architecture

## Goals that shape the design

- **Acquisition, processing and UI are separate.** Every analysis step runs on recorded data and none needs live sensors, so all of it can be tested on a Mac and reproduced offline.
- **Real sensors only in the production path.** `AppModel` always builds `CoreMotionSource` and `MicrophoneSource`. Fakes exist only in test targets. Synthetic data lives in its own module, and every synthetic session is labelled `isSynthetic`.
- **Sensor callbacks do only cheap work.** No disk I/O, no UI updates and no allocation while recording.

## Modules

```
            ┌───────────────┐
            │  CanineCardio │  SwiftUI app: RecordView, SessionListView, SessionDetailView
            └──────┬────────┘
   ┌───────────────┼──────────────────┬──────────────────┐
   ▼               ▼                  ▼                  ▼
Acquisition     Storage        SignalProcessing     SyntheticData
   │               │                  │                  │
   └───────────────┴──────► CardioCore ◄─────────────────┘
```

| Module | Responsibility | Platform |
|---|---|---|
| `CardioCore` | `Vector3Sample`, `MotionSeries`, `SessionMetadata`, `SamplingStatistics`, `LiveRingBuffer`, `MotionLevel` | iOS + macOS |
| `Acquisition` | `MotionSource` / `AudioSource` protocols, `CoreMotionSource`, `MicrophoneSource`, `MicrophonePermission` (iOS only); `CaptureGate`, `MotionCapture`, `AudioTapProcessor`, `MeasurementSession` (cross-platform, unit tested) | iOS (+ macOS for tests) |
| `Storage` | `SessionStore` (session folders), `MotionCSV` | iOS + macOS |
| `SignalProcessing` | `Butterworth`/`SOSFilter` (incl. `filtfilt`), `Resampler`, `Detrend`, `Envelope`, `Periodicity`, `PeakDetector`, `BeatIntervals`, `IntervalSummary`, `MotionArtifactDetector`, `BeatMatcher`, `CandidateBeatPipeline` | iOS + macOS |
| `SyntheticData` | `SyntheticGenerator`, `SyntheticScenario` (labelled synthetic signals with ground truth) | iOS + macOS |

## Recording data flow

```
CMMotionManager (OperationQueue, ~100 Hz/sensor)          AVAudioEngine input tap (~10 Hz buffers)
        │  Vector3Sample(t: sensor timestamp)                       │  AVAudioPCMBuffer + AVAudioTime
        ▼                                                           ▼
  MotionCapture.append ── LiveRingBuffer (accel, gyro)      AudioTapProcessor.process
        │   (Mutex, pre-reserved arrays)                         ├─ 10 ms RMS/peak → LiveRingBuffer
        │                                                        ├─ sampleTime continuity check
        └── keep if t ∈ CaptureGate window                       └─ write frames ∈ CaptureGate window → audio.wav
                                    ▲
                                    │ open(start, end) / close(at:)
                          MeasurementSession (@MainActor, @Observable)
                                    │ after window + 0.3 s delivery margin
                                    ▼
                    SessionStore.finalize → accelerometer.csv, gyroscope.csv, metadata.json (last)
```

- **`CaptureGate`** holds the recording window on the uptime clock, and motion and audio share it. Sensors can run before the window opens (preview, start delay) without their samples being recorded. Audio is cut to the exact frame at both edges.
- **Live display** pulls from the ring buffers. A `TimelineView` refreshes at 15 Hz, copies only the last 5 s, min/max-decimates it to about 600 points and draws it with `Canvas`. Callbacks never push to SwiftUI.
- **Swift 6 isolation.** The Core Motion handlers and the audio tap block are built in `nonisolated static` functions. If they were written inside `@MainActor` code they would inherit main-actor isolation and trap at runtime when Core Motion or Core Audio calls them on a background thread.
- **Saving** happens off the main actor in a detached task.

## Signal processing pipeline (experimental)

`CandidateBeatPipeline` produces *candidate* mechanical beats from one accelerometer axis:

1. Linear resampling of irregular timestamps onto a 100 Hz grid. Samples inside gaps longer than 2.5 sample periods are marked invalid.
2. Linear detrend.
3. A zero-phase Butterworth band-pass, built as a high-pass cascaded with a low-pass in second-order sections and applied forward and backward with odd reflection padding and steady-state initial conditions. Its magnitude response is checked against `scipy.signal` in `FilterTests`.
4. An RMS envelope over a 60 ms window.
5. A motion artifact mask: 0.5 s windows whose broadband RMS exceeds 4× the median.
6. Peak detection with a threshold adaptive to the local maximum and a refractory period (default 0.35 s). Peak times are refined with parabolic interpolation.
7. Interval flags: outside the 250–2000 ms range, more than 35 % deviation from the local median, or overlapping an artifact or gap.
8. A reliability summary. It reports a rate, SD or RMSSD only when there are at least 10 accepted intervals, at least 80 % of intervals are accepted, the envelope periodicity is at least 0.3, artifacts or gaps cover at most 30 % of the recording, **and** the median interval agrees within 25 % with the envelope's dominant period. The last check catches consistently doubled detection, which the interval-to-interval checks cannot see.

Every parameter is in a `Config` struct. The defaults are starting points chosen on *synthetic* data and are not validated on dogs.

## Testing

- `swift test` in `CardioKit/` runs every library test on macOS. `xcodebuild test -scheme CardioKit-Package` runs the same tests on an iOS Simulator.
- `ValidationTests` scores the pipeline against ground truth for each synthetic scenario. It also asserts the key safety property: *whenever the pipeline reports sufficient reliability, the result is accurate*. This is checked over every scenario with several noise seeds.
- The DEBUG app build accepts the launch argument `-CCAudioSelfTest`. It runs the real microphone path (engine, tap, gating, WAV writing) for 2 s and logs the result through NSLog. Use it on a device.
