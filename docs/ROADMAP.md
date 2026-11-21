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
