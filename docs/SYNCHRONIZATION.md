# Timing and cross-stream synchronisation

## Clocks

| Quantity | Source | Clock |
|---|---|---|
| Motion sample time `t_uptime_s` | `CMLogItem.timestamp` | Seconds since boot, mach-absolute-time base (pauses during device sleep) |
| Motion delivery time `received_uptime_s` | `ProcessInfo.systemUptime` in the handler | Same |
| Audio buffer time | `AVAudioTime.hostTime` → `AVAudioTime.seconds(forHostTime:)` | Same (mach host time) |
| Audio frame within a file | frame index / `sampleRateHz` | Audio sample clock |
| `createdAt` | `Date()` | Wall clock, for labelling only |

All three timing columns are monotonic and share one time base. Wall-clock time is never used to align anything.

**Check this assumption on every recording.** `metadata.json` stores `medianDeliveryLatencyS` for each motion stream, which is (delivery uptime − sensor timestamp). It should be a small positive number, a few milliseconds up to the Core Motion batching interval. A large or negative value would mean `CMLogItem.timestamp` is not on the uptime clock on that device or OS. In that case, cross-stream alignment must not be trusted.

## Motion

- Samples are recorded at the instants Core Motion reports. Nothing is resampled at recording time. `SamplingStatistics` reports the effective rate, the interval mean, SD, minimum and maximum, the number of gaps (intervals longer than 1.5× the median) and an estimate of how many samples are missing.
- The accelerometer and gyroscope are separate streams with their own timestamps. Do not assume row *i* of one file matches row *i* of the other.
- The 100 Hz request is a request, not a guarantee. Use the measured rate.

## Audio

- The tap delivers buffers of about 100 ms. For each buffer, the host time of its first frame gives that frame's uptime. Every later frame is placed by sample count. The app records:
  - `firstFrameUptimeS`: the uptime of the first frame written to the file (after trimming to the gate);
  - `firstFrameSampleTime`: the audio engine's sample counter at that frame;
  - `sampleTimeDiscontinuities` / `discontinuityFrames`: places where a buffer did not follow on from the previous one. Any value other than 0 means the file has missing audio, and timing after that point is off by the missing frames;
  - `sampleClockDriftPPM`: the difference between the host clock and frame-count time over the recording. With no discontinuities it should be within a few tens of ppm;
  - `inputLatencyS` and `ioBufferDurationS` from `AVAudioSession`.
- **Input latency is recorded but not applied.** It is unclear whether the tap's `hostTime` already accounts for hardware input latency, and this can differ between devices.

## Uncertainty budget (expected, to be measured)

| Component | Expected magnitude | How to reduce or measure |
|---|---|---|
| Core Motion timestamp jitter | ~0.1–2 ms (visible in interval SD) | Use timestamps, not row index; resample offline |
| Motion sample period (100 Hz) | ±5 ms quantisation of event times | Sub-sample peak interpolation |
| Audio host-time stamp of buffer | unknown; likely < 1 ms | Tap test (below) |
| Audio input latency (not applied) | typically 1–10 ms; reported per session | Tap test; apply if the tap test shows it is not already included |
| Audio/host clock drift | < ~50 ppm → < 6 ms over 120 s | Reported as `sampleClockDriftPPM` |

Until it is measured, treat the **audio-to-motion alignment as uncertain by roughly ±10 ms**. That is good enough to relate heart sounds to chest-wall vibrations at the scale of a whole beat, but not to measure intervals between them that are only a few milliseconds long.

## Measuring the actual offset: tap test

1. Lay the phone on a table and start a 30 s recording with audio.
2. Tap the table (or the phone case) sharply with a pen about 10 times, a few seconds apart.
3. In the analysis, find each tap's onset in the accelerometer (high-pass filtered magnitude) and in the audio envelope. The median of (audio onset − motion onset) estimates the cross-stream offset, and the spread shows its uncertainty. Sound travels through the table in well under 0.1 ms over these distances, so the travel delay can be ignored.
4. Repeat on each device model used for measurements and record the results in this document.

## Measured results

### iPhone 16e (iPhone17,5), iOS 27.2.1, 2026-11-21

**On-table baseline** (60 s):
- Core Motion delivered 100.23 Hz, with intervals between 9.973 and 9.981 ms and no gaps.
- The accelerometer and gyroscope share identical timestamps.
- Median delivery latency was 5.2 ms, so `CMLogItem.timestamp` is on the uptime clock.
- Audio: 48 kHz from the bottom microphone, no discontinuities, sample-clock drift −15 ppm.
- Noise floor (RMS): about 0.45 mg in 5–30 Hz, about 0.17 mg in 0.6–4 Hz and about 0.11 mg in 0.1–1 Hz. The accelerometer quantum is 15 µg.

**Tap test** (30 s, pen taps on the table). Only the 5 taps whose motion peak exceeded 10× the noise floor were used. Weaker taps did not rise clearly above the accelerometer noise, and the first tap was cut off by the start of the recording.

| Measure | Audio − motion, median | SD |
|---|---|---|
| Onset (first threshold crossing, interpolated) | −5 ms | ~2 ms |
| Peak of motion response vs audio onset | −16 ms | ~2 ms |

The motion stream lags the audio by about 5 ms at onset and about 16 ms at peak. The most likely causes are the accelerometer's internal low-pass and decimation filter and the 10 ms sample spacing. The reported audio input latency is only 0.6 ms.

Implications:
- Intervals measured within one stream are unaffected by this offset.
- To compare the timing of heart sounds and chest vibrations, shift motion timestamps 5 ms earlier (±3 ms). The peak-based lag also matters, because filtering delays the peak of a motion event.
- The result is based on only 5 taps. Repeat with more, and stronger, taps before relying on it.
