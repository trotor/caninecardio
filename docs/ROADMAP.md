# Roadmap

## Next: Polar H10 chest strap as an ECG reference (planned, 2026-11-21)

**Why:** the first dog recordings show clear periodic chest vibrations, but without a reference it cannot be shown which bursts are heartbeats. The dog's rhythm is also genuinely irregular when palpated. An ECG-based chest strap provides R-R intervals, and possibly the raw ECG, recorded at the same time as the phone.

**Plan:**
1. **Hardware:** a Polar H10 strap around the dog's chest just behind the elbows, on wetted fur or with electrode gel.
2. **Read the strap from the app over Bluetooth LE**, with no third-party SDK:
   - the standard Heart Rate Service (0x180D, measurement characteristic 0x2A37) gives heart rate and R-R intervals in units of 1/1024 s;
   - optionally, the raw ECG at 130 Hz through Polar's documented measurement-data (PMD) service, for exact R-peak times.
3. **Synchronisation:** stamp each received packet with the same uptime clock as the motion and audio data. R-R values arrive in batches, roughly once per second, so absolute beat times are rebuilt from the cumulative R-R sum. Check the alignment against the raw ECG or a tap that is visible in all streams.
4. **Storage:** a new `polar_rr.csv` (and `polar_ecg.csv`) in the session folder, described in `metadata.json`.
5. **Analysis:**
   - use the strap's beats as the reference in `analyze_session.py --reference` and in `BeatMatcher`;
   - report sensitivity, PPV, the electromechanical delay distribution, and interval agreement (Bland–Altman);
   - test whether the mechanical intervals reproduce the respiratory modulation seen in the R-R series.
6. **Later, if it works:** record the strap's R-R intervals and the GPS track during activity, for example a hunting dog's run and its recovery afterwards. The phone-on-chest method only works at rest.

**Until the strap arrives:** the operator palpates the pulse in the axilla and makes a tongue click at every beat, so the app's microphone records reference marks on the same clock.

## Longer-term goal: activity monitoring for sport and working dogs (decided 2026-11-21)

**Goal:** heart rate, R-R intervals, movement and route recorded during real activity (running, hunting, sport training), with **the data exportable in open formats** for analysis. This is exploratory monitoring of exercise and recovery, not diagnosis.

### What works in motion, and what does not

| Method | At rest | During running | Notes |
|---|---|---|---|
| Chest vibration (accelerometer, this app) | Yes, a clear signal | **No** | Running produces several g of motion; cardiac vibrations are 5–15 mg. |
| Radar (mmWave, e.g. Acconeer A121, Infineon BGT60) | Yes, through fur | **No** | Measures the same mechanical motion, and has the same problem telling beats apart. |
| Optical PPG | Poor through fur and pigment | No | Not pursued. |
| **ECG through electrodes on the skin** | Yes | **Yes, if contact holds** | The only method that gives true R-R intervals during exercise. |

**Conclusion:** use **ECG** for heart rate in motion, an **IMU** for movement and gait, and **GNSS** for route and speed. Chest vibration and radar remain useful for resting and recovery measurements.

### Getting electrodes past the fur

1. **Wetted fur or electrode gel + strap**, e.g. Polar H10. Cheap and available now. Contact may degrade as the fur dries or the strap shifts.
2. **Spiked (comb) dry electrodes**: flexible pins that reach the skin through the coat. The approach comes from EEG through hair (e.g. g.tec g.SAHARA). This is the most promising option for a harness worn during activity.
3. **Capacitive electrodes**: no skin contact needed, but sensitive to motion. Mostly research-grade.

### Recommended architecture for the motion use case

```
Harness (chest girth, behind the elbows)
 ├─ ECG: 2–3 spiked or wetted electrodes → MAX30003 (low-power ECG, built-in R-R detection) or ADS1292R
 ├─ IMU: TDK ICM-42688-P (accelerometer + gyroscope, low noise) — movement, gait, activity intensity
 ├─ GNSS: u-blox MAX-M10S (multi-constellation, low power, 1–10 Hz)
 ├─ MCU: Nordic nRF52840 / nRF5340 (BLE, low power; ESP32-S3 is easier but drains the battery faster)
 ├─ Storage: flash or microSD, recording on the device (store-and-forward; BLE range in the field is short)
 └─ Power: 500–1000 mAh LiPo + charger; 3D-printed, splash-proof enclosure on the harness
Phone app (this project): configure, live view when in range, download, sync and export
```

- **Timing:** all streams are stamped by the device's single clock. GNSS time anchors it to UTC, and a shared marker event (a tap) links it to phone recordings.
- **Data out:**
  - per-session folders like today's: CSV for ECG/R-R, IMU and GNSS, plus `metadata.json`;
  - GPX/FIT export of the route with heart rate for existing sports tools;
  - a documented format, so data can be analysed in Python or R.
- **Exploratory metrics:**
  - heart rate and R-R over time, heart-rate recovery after effort, time in intensity zones;
  - distance, speed, gait and activity classification from the IMU;
  - all with signal-quality flags, for example when electrode contact is lost.

### Step-by-step plan

1. **Off-the-shelf first.**
   - Polar H10 (wetted fur): the app records its R-R intervals over BLE together with the phone's GNSS during real runs.
   - Measure how often electrode contact drops out, which strap positions work, and what the data looks like.
   - Alternative or complement: **Movesense** (Finnish, ECG + IMU + BLE, programmable).
2. **Harness prototype.**
   - Seeed XIAO nRF52840 Sense (or similar) + ICM-42688-P + MAX30003 + u-blox M10 + flash.
   - Spiked electrodes compared with wetted ones on the same dog.
3. **Validation in motion.** Compare the prototype's R-R intervals with a reference (Polar H10 on the same run, or a veterinary Holter ECG). Report data coverage (the % of time with usable ECG) as a primary outcome.
4. **Field use.** Battery life, durability (water, mud, brush), weight and comfort for the dog. Export of a full training session.

### Open questions

- Electrode placement and contact during galloping, swimming and in dense or long coats.
- Acceptable device weight and placement for different breeds, and the dog's comfort and safety.
- GNSS accuracy under forest canopy at low update rates.
- Battery life for a full hunting day with GNSS running continuously.

**Hardware details above are from memory and must be checked for current availability before buying.**
