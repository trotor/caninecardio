# CanineCardio

**English** · [Suomeksi](README_fi.md)

An open-source iOS research app for finding out whether an iPhone resting gently on a dog's chest can detect individual heartbeats, and measure beat-to-beat intervals accurately enough to observe respiratory sinus arrhythmia.

> [!WARNING]
> **CanineCardio is experimental research software.**
> It is **not** a medical or veterinary device and **has not been validated for canine diagnostics**.
> It **cannot replace a veterinary ECG** or examination by a veterinarian.
> Do not use it to make any decision about an animal's health.

## Status

| Phase | Scope | State |
|---|---|---|
| 1 | Raw signal acquisition, live display, local storage, CSV/WAV export | **Implemented and in use on an iPhone 16e.** |
| 2 | Signal processing (filters, peak detection, intervals, quality) | Implemented and tested. Runs on recorded sessions in the app (experimental beat analysis). Tuned only on synthetic data so far. |
| 3 | Analysis (rate, IBI series, RMSSD/SDNN, respiration) | Partly: interval statistics exist behind a reliability gate. Respiration estimation not started. |
| 4 | Analysis UI | Partly: beat analysis with candidate beats, intervals, a reliability verdict and manual corrections; raw and filtered signals. No live heart rate during recording. |
| 5 | Validation | Synthetic scenarios, scoring against ground truth, Python analysis, first real recordings (below). No reference-based validation yet. |

## Screenshots

| Sessions | Session details | Recorded signal |
|---|---|---|
| <img src="docs/images/app-sessions.png" width="250" alt="List of recorded sessions with sampling rates"> | <img src="docs/images/app-detail.png" width="250" alt="Session details with sampling statistics"> | <img src="docs/images/app-signals.png" width="250" alt="Accelerometer signal of a dog recording with overview and zoomed window"> |

| Beat analysis, human chest | Beat analysis, dog |
|---|---|
| <img src="docs/images/app-beats-human.png" width="250" alt="Beat analysis of a human chest recording: 74 per minute, beat markers on every vibration burst"> | <img src="docs/images/app-beats-dog.png" width="250" alt="Beat analysis of a dog recording: insufficient confidence, with the reasons listed"> |

Screenshots from the iOS Simulator, showing real recordings copied from the iPhone. The app reports a rate for the human recording, but for the dog recording it reports **insufficient confidence** and gives its reasons rather than a number.

## Preliminary results (21 November 2026)

These are the first real recordings: an iPhone 16e (iOS 27.2.1), one adult human (the developer) and one calm dog lying on its side. **No reference ECG or pulse count was recorded at the same time.** The results show which signals are present. They do not show how accurately heartbeats are detected. The full log is in [docs/VALIDATION.md](docs/VALIDATION.md) and [docs/SYNCHRONIZATION.md](docs/SYNCHRONIZATION.md).

### Recording quality

| Check | Result |
|---|---|
| Motion sampling | 100.2 Hz effective (100 Hz requested), intervals 9.973–9.981 ms, no gaps in any recording |
| Clock check | Samples arrive 5.2 ms (median) after their sensor timestamp, so the motion and audio clocks agree |
| Noise floor, phone at rest on a table | ~0.45 mg RMS in the 5–30 Hz band |
| Audio | 48 kHz, no dropouts, sample-clock drift −15 ppm |
| Audio vs motion (tap test, 5 taps) | The accelerometer responds ~5 ms after the sound starts (peak ~16 ms) |

### Chest vibrations: table vs human vs dog

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/images/signals-dark.png">
  <img src="docs/images/signals-light.png" alt="Accelerometer 5-30 Hz band over 8 seconds: flat on a table, regular bursts on a human chest, bursts of similar size on a dog">
</picture>

The 5–30 Hz band of the accelerometer, 8 s each, all on the same scale. On a table the trace is flat. On a human chest (sternum, breath held) there is a burst at every heartbeat, about 5–10 mg, which is 10–20× the noise floor. On the dog (phone resting freely on the side of the chest), bursts of similar size appear throughout the 56 s quiet part of the recording.

### Beat-to-beat intervals: the open question

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/images/intervals-dark.png">
  <img src="docs/images/intervals-light.png" alt="Candidate beat intervals: smooth changes in the human recording, highly irregular in the dog recording">
</picture>

Intervals between *candidate* beats, from an exploratory offline detector. In the human recording they change smoothly during the breath-hold. In the dog recording they jump between ~0.5 and ~1.5 s. The operator also felt the dog's pulse by hand as very irregular, which suggests the rhythm really varies; marked sinus arrhythmia is common in dogs. Without a reference, though, detection errors cannot be ruled out, and the data does not give a single heart rate: a spectral estimate gives about 56/min, the median interval about 71/min. A separate recording with the phone on the dog's shoulder gave a clearer rhythm of about 83/min.

### Synchronising audio and motion

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/images/tap-test-dark.png">
  <img src="docs/images/tap-test-light.png" alt="A pen tap: the microphone responds at 0 ms, the accelerometer rises over the next 5 to 16 ms">
</picture>

A pen tap on the table as recorded by both sensors, on the shared clock. The microphone reacts immediately. The accelerometer follows within one or two of its 10 ms samples.

### What this shows, and what it does not

- ✅ The phone and the app capture a clear chest-wall vibration (seismocardiogram) from a human, and similar periodic vibrations from a resting dog.
- ✅ Timing is regular and the two sensors can be aligned to within a few milliseconds.
- ❌ It is not yet shown that each detected burst on the dog is one heartbeat, or that the intervals are accurate.
- Next steps:
  1. The operator feels the dog's pulse (e.g. in the axilla) and makes a tongue click at every beat, so the app's microphone records a reference on the same clock.
  2. After that, a Polar H10 ECG chest strap read directly by the app over Bluetooth; see [docs/ROADMAP.md](docs/ROADMAP.md).
- Longer term: heart rate, movement and route monitoring for sport and working dogs during activity, with an ECG harness, IMU and GNSS and open data export. The plan is in [docs/ROADMAP.md](docs/ROADMAP.md).

## What the app does (Phase 1)

- Records the **raw accelerometer** (g, gravity included) and **gyroscope** (rad/s) through `CMMotionManager` at a requested 100 Hz. Each sample keeps its own sensor timestamp, and the app reports the effective sampling rate, interval jitter and gaps. It never assumes the samples are evenly spaced.
- Records **unprocessed microphone audio** at the hardware sample rate (typically 48 kHz). It uses `AVAudioEngine` with `AVAudioSession` mode `.measurement`, which turns off automatic gain and voice processing.
- Offers recording durations of 30, 60 or 120 s and a start delay of 0, 5 or 10 s, so you can place the phone before recording begins. A live **Preview** mode shows the signals without recording.
- Shows live acceleration, rotation rate and microphone level, plus a timer, measured sampling rates and a gross-motion indicator (Still / Slight motion / Moving). The motion indicator reflects movement only, not cardiac signal quality.
- Stop and Cancel must be **held for one second**, so that placing the phone on a chest does not end the recording by accident.
- Saves each session locally and exports it as CSV (motion), WAV (audio) and `metadata.json`, using the share sheet or the Files app.
- Lists past sessions with sampling diagnostics. Each session can be inspected as a raw or band-pass-filtered waveform with a zoomable window.
- **Beat analysis (experimental)** of each recorded session:
  - candidate beats from the 5–30 Hz chest vibration on each axis, with the most reliable axis chosen automatically;
  - beat markers on the waveform and a beat-to-beat interval chart;
  - a rate, SD and RMSSD shown **only when the reliability checks pass**; otherwise "insufficient confidence" with the reasons;
  - tapping the waveform rejects a beat or adds one at the nearest vibration peak. Corrections are saved as `beats.json` in the session folder and included in the export.
- Has no accounts, analytics, network access or third-party SDKs.

## Requirements

- Xcode with Swift 6 and the iOS 18+ SDK. Developed and tested only with Xcode 27.2. `project.yml` declares Xcode 16 compatibility, but that has not been tested.
- An iPhone for real recordings. Development targeted the iPhone 15 and 16e. **The iOS Simulator has no motion sensors.** The app builds and runs there but reports the accelerometer as unavailable.
- Optional: [XcodeGen](https://github.com/yonaskolb/XcodeGen) to regenerate the project from `project.yml`.
- Optional, for offline analysis: Python 3.10+ with NumPy, SciPy and Matplotlib.

Continuous integration: `.github/workflows/ci.yml` runs the library tests, builds the app unsigned for the Simulator, and smoke-tests the Python script. It runs on GitHub-hosted macOS runners (currently Xcode 26.6), so the code is also checked with an older compiler than the Xcode 27.2 used for development.

## Build and install

```sh
git clone https://github.com/trotor/caninecardio.git
cd caninecardio
open CanineCardio.xcodeproj           # or first: xcodegen generate
```

1. Create `Config/Signing.local.xcconfig`, which git ignores, containing your own team and bundle ID:
   ```
   DEVELOPMENT_TEAM = ABCDE12345
   PRODUCT_BUNDLE_IDENTIFIER = com.yourdomain.caninecardio
   ```
   The repository itself ships only placeholders (`Config/Signing.xcconfig`).
2. Select your iPhone as the run destination and run.
3. Allow microphone access when asked. To record motion only, turn off **Record microphone audio**.

Run the tests:

```sh
cd CardioKit && swift test            # all library tests on macOS
xcodebuild test -scheme CardioKit-Package -destination 'platform=iOS Simulator,name=iPhone 17'
```

## Measurement instructions

Measure only a calm, resting dog that is comfortable being handled, with its owner's consent. Stop if the dog shows any sign of discomfort.

1. Let the dog settle lying on its side (lateral recumbency) or sternal. Note the posture in the **Label** field, along with the dog's ID and the phone position.
2. Set the duration (start with 60 s) and a 5–10 s start delay.
3. Tap **Preview** to check that the waveform responds, then tap **Record**.
4. During the countdown, place the phone **screen up** on the left chest wall just behind the elbow, over the area where the heartbeat can be felt. Use light, steady contact. If possible, take your hands off the phone; in the first recordings, the operator's own pulse could not be ruled out when the phone was held by hand.
5. Keep quiet and still until the timer ends. Panting, licking, tail wagging and handling noise will dominate both sensors.
6. Note anything relevant afterwards, such as the dog moving at a particular moment.

The app plays no sounds or haptics while recording, because they would contaminate the signals. The screen stays awake during preview and recording. If the app goes to the background or the audio session is interrupted (for example by a phone call), the recording stops. The saved session is then marked **Interrupted**.

## Data format

Each session is a folder `Documents/Sessions/<id>/`, also visible in the Files app under *On My iPhone › CanineCardio › Sessions*:

| File | Contents |
|---|---|
| `metadata.json` | Session ID, label, durations, end reason, device model and OS, app version, clock description, reference time, per-stream sampling statistics, audio timing values, notes and warnings. Written last; a folder without it is incomplete. |
| `accelerometer.csv` | `index,t_rel_s,t_uptime_s,received_uptime_s,x_g,y_g,z_g` |
| `gyroscope.csv` | `index,t_rel_s,t_uptime_s,received_uptime_s,x_rad_s,y_rad_s,z_rad_s` |
| `audio.wav` | Mono (usually) 32-bit float PCM at the hardware rate, trimmed to the recording window. |
| `beats.json` | Only after manual corrections: analysis axis, automatically detected beats, and rejected and added beats (uptime seconds). |

- `t_uptime_s` is the sensor timestamp on the device's monotonic uptime clock.
- `t_rel_s = t_uptime_s − referenceUptimeS`, so 0 is the start of the recording.
- `received_uptime_s` is when the app received the sample, used for delivery-latency diagnostics.
- Rows are raw samples in arrival order, not resampled.
- Audio frame *k* is at `audio.firstFrameUptimeS + k / sampleRateHz` on the same clock. How exactly the audio and motion streams line up is documented in [docs/SYNCHRONIZATION.md](docs/SYNCHRONIZATION.md).

The sample exports in [`examples/synthetic/`](examples/synthetic/) are **SYNTHETIC**: generated by a program, not measured. They show the file format and serve as test inputs. The real recordings described above are not published in this repository.

## Offline analysis

```sh
pip install -r analysis/requirements.txt
python analysis/analyze_session.py path/to/<session-folder>            # writes <session>/analysis/*.png + report.json
python analysis/analyze_session.py examples/synthetic/SYNTHETIC-regular  # synthetic example with ground truth
python analysis/analyze_session.py <session> --reference ecg_r_peaks.csv # compare against reference beats
```

The script recomputes sampling diagnostics and plots raw and filtered signals, Welch spectra and the microphone envelope on the motion time base. Given reference beat times (synthetic ground truth or ECG R peaks), it scores *candidate* beats by sensitivity, PPV and timing error. `analysis/make_readme_figures.py` produced the figures above.

## Architecture

```
CanineCardio/            iOS app (SwiftUI): Record, Sessions, About
CardioKit/               Swift package with the testable modules
  CardioCore             value types, sampling statistics, lock-protected live ring buffers
  Acquisition            Core Motion + AVAudioEngine sources (iOS), CaptureGate, MeasurementSession
  Storage                session folders, CSV/JSON persistence
  SignalProcessing       Butterworth SOS filters, filtfilt, resampling, envelopes, peak detection,
                         beat intervals, artifact masks, reliability summary, BeatMatcher scoring
  SyntheticData          labelled synthetic signals with ground truth (tests/previews only)
  cardio-synth           CLI that writes the synthetic example sessions
analysis/                Python offline analysis and figure scripts
design/                  app icon generator
docs/                    architecture, synchronisation, validation plan and results log
examples/synthetic/      synthetic example sessions (sample CSV export)
```

The analysis code depends only on recorded data, never on live sensors. See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

## Mechanical beats are not ECG R-R intervals

Any interval this project produces comes from **mechanical** chest-wall events: vibrations from valve closure and ejection, and whole-body recoil. These intervals are not electrical R-R intervals. The delay between electrical activation and mechanical events (the electromechanical delay or pre-ejection period) changes from beat to beat. Mechanical intervals therefore differ from ECG intervals, and the size of that difference is one of the things to be measured. The project uses the terms "rhythm variability" and "possible respiratory modulation". It does not diagnose arrhythmias or any other condition.

## Licence

MIT — see [LICENSE](LICENSE).
