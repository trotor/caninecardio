# Validation

The project aims to **measure detection accuracy**, not to show heart rates that merely look plausible. Validation runs in three stages, and each must succeed before the next one starts.

## Stage 0 — software validation on synthetic data (done)

`CardioKit/Sources/SyntheticData` generates labelled synthetic recordings with known beat times. The waveform is a crude model: two damped vibration bursts per cycle, respiration-driven baseline movement and noise. It is **not** a validated model of canine cardiac mechanics.

| Scenario | What it tests |
|---|---|
| `regular` | Baseline accuracy |
| `respiratorySinusArrhythmia` | ±18 % respiratory modulation must be tracked, not rejected |
| `prematureAndMissingBeats` | Premature beats, compensatory pauses, beats too weak to detect → flagged intervals |
| `motionArtifacts` | Large motion bursts are excluded and no beats are reported inside them |
| `lowSNR` | Must report insufficient confidence, with no rate |
| `doublePeaks` | Two near-equal components per cycle: ambiguous, so no false confidence |
| `jitterAndDroppedSamples` | Irregular timestamps, random drops, 150 ms gaps |

Tests in `ValidationTests` score the pipeline with `BeatMatcher` (sensitivity, PPV, timing error, interval error). They also assert that a *reliable* verdict always comes with an accurate result. One defect found and fixed in this way: with a short refractory period, the double-peak scenario reported a "reliable" 181 beats/min, twice the true rate. A check that the median detected interval agrees with the envelope's dominant period now catches this.

This only shows that the software behaves as designed on its own synthetic model. **It says nothing about performance on real dogs.**

To reproduce the example files:

```sh
swift run --package-path CardioKit cardio-synth examples/synthetic
```

## Stage 1 — do the sensors capture a cardiac signal at all? (next)

Record without any reference first and look at the raw data:

1. **Phone at rest on a table** (30 s, about 5 recordings). This gives the noise floor of each axis and each band, the actual sampling behaviour, and the clock checks (`medianDeliveryLatencyS`, audio drift and discontinuities).
2. **Tap test** (see SYNCHRONIZATION.md). This measures the offset between audio and motion.
3. **Human chest, as a positive control.** The phone on the sternum of a person lying down, holding their breath for 20 s, with a finger pulse or a chest-strap heart rate monitor for comparison. Human seismocardiography is well documented, so this establishes whether this phone and app can capture it at all.
4. **Resting dogs.** Several dogs, postures and phone positions, each with a written label.

For each recording, `analysis/analyze_session.py` gives the power spectrum and band-filtered traces. The evidence that a usable signal exists is:

- a spectral peak, or a periodic envelope, at the beat rate counted by palpation or auscultation at the same time;
- repeatable waveform shapes, one per cycle, in the cardiac vibration band;
- an amplitude clearly above the on-table noise floor.

If no recording shows this, the outcome is reported as negative, and heartbeat detection is not attempted on that configuration.

## Stage 2 — comparison against a simultaneous veterinary ECG (future)

### Setup

- A standard veterinary ECG (lead II), recorded at the same time by a veterinarian or under veterinary supervision, with the dog resting in right lateral recumbency as usual.
- The phone placed on the left chest wall, so that it does not interfere with the ECG electrodes.
- **Synchronisation:** at the start and end of each recording, make a sharp tap on the table or the phone that is visible to the phone's sensors and captured by the ECG system. Use a marker channel if available, or a motion or sound artifact on an ECG lead. Two markers allow both offset and drift to be corrected. Alternatively, record a video showing both the ECG screen and the phone with a running clock. That is less accurate.

### Analysis

1. Detect R peaks in the ECG with established software, and check them manually.
2. Convert R-peak times to the phone time base using the sync markers. Write them as CSV with a `t_rel_s` column.
3. Run `python analysis/analyze_session.py <session> --reference r_peaks.csv`. The script estimates the median electromechanical delay (mechanical candidate − R peak), then matches beats within ±100 ms after correcting for it.
4. Report, for each recording and pooled (the script currently computes sensitivity, PPV and timing/delay statistics; the interval-agreement analysis below still has to be written):
   - sensitivity and positive predictive value of candidate beats;
   - the distribution of the electromechanical delay (mean, SD). Its variability limits how well mechanical intervals can stand in for R-R intervals;
   - interval agreement: mechanical IBI vs R-R for each matched consecutive pair, with Bland–Altman bias and limits of agreement in ms;
   - whether respiratory modulation of R-R is visible in the mechanical intervals: correlation of the two interval series, and comparison of SD and RMSSD;
   - the fraction of recording time the pipeline declared unreliable, and whether its reliability flag actually predicts agreement with the ECG.
5. Sample size, inclusion criteria and analysis parameters must be fixed **before** the analysis. Report results for every recording made, including failures.

### Interpretation limits

- Mechanical intervals differ from R-R intervals by the beat-to-beat change in electromechanical delay. Even with perfect detection, mechanical intervals are not R-R intervals.
- Agreement on calm, healthy dogs at rest does not carry over to dogs that are moving, panting or ill.
- No result from this project supports diagnostic use.
