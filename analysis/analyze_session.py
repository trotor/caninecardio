#!/usr/bin/env python3
"""Offline analysis of a CanineCardio session folder.

Reads metadata.json, accelerometer.csv, gyroscope.csv and audio.wav exported by the app (or
written by `cardio-synth`), and produces:

  * sampling diagnostics (effective rate, interval jitter, gaps) recomputed from timestamps,
  * raw and band-pass filtered accelerometer traces (respiration / cardiac pulse / cardiac
    vibration candidate bands, same Butterworth design as the app),
  * Welch power spectra of each axis (look for a peak at the expected beat rate and harmonics),
  * the microphone RMS envelope on the motion time base,
  * optionally, a comparison of candidate beats with reference beat times (synthetic ground truth
    `truth_beats.csv`, or a simultaneous ECG via --reference).

Everything here is exploratory. Candidate peaks are NOT validated heartbeats.

Usage:
    python analyze_session.py <session_dir> [--axis z] [--window 20 30] [--out DIR]
                              [--reference beats.csv] [--candidates] [--show]
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

import numpy as np
from scipy import signal
from scipy.io import wavfile

import matplotlib

FS = 100.0  # uniform resampling rate for motion data (Hz)
BANDS = {
    "respiration": (0.1, 1.0),
    "cardiac_pulse": (0.6, 4.0),
    "cardiac_vibration": (5.0, 30.0),
}


# ---------------------------------------------------------------------------- loading

def load_motion(path: Path) -> dict[str, np.ndarray] | None:
    if not path.exists():
        return None
    data = np.genfromtxt(path, delimiter=",", names=True)
    cols = data.dtype.names
    return {
        "t_rel": data["t_rel_s"],
        "t_uptime": data["t_uptime_s"],
        "received": data["received_uptime_s"],
        "x": data[cols[4]],
        "y": data[cols[5]],
        "z": data[cols[6]],
    }


def load_reference(path: Path) -> np.ndarray:
    """Reference beat times in seconds relative to the session start (column t_rel_s)."""
    data = np.genfromtxt(path, delimiter=",", names=True)
    return np.atleast_1d(data["t_rel_s"]).astype(float)


# ---------------------------------------------------------------------------- processing

def sampling_stats(t: np.ndarray) -> dict:
    dt = np.diff(t)
    med = float(np.median(dt))
    gaps = dt > 1.5 * med
    return {
        "samples": int(t.size),
        "span_s": float(t[-1] - t[0]),
        "effective_rate_hz": float((t.size - 1) / (t[-1] - t[0])),
        "interval_mean_ms": float(dt.mean() * 1e3),
        "interval_sd_ms": float(dt.std() * 1e3),
        "interval_min_ms": float(dt.min() * 1e3),
        "interval_max_ms": float(dt.max() * 1e3),
        "gaps": int(gaps.sum()),
        "estimated_missing_samples": int(np.sum(np.maximum(0, np.round(dt[gaps] / med) - 1))),
        "non_increasing": int(np.sum(dt <= 0)),
    }


def resample(t: np.ndarray, v: np.ndarray, fs: float = FS) -> tuple[np.ndarray, np.ndarray]:
    grid = np.arange(t[0], t[-1], 1.0 / fs)
    return grid, np.interp(grid, t, v)


def bandpass(x: np.ndarray, low: float, high: float, fs: float = FS, order: int = 2) -> np.ndarray:
    """High-pass(low) cascaded with low-pass(high), zero-phase. Matches FrequencyBand.filter in the app."""
    sos = np.vstack([
        signal.butter(order, low, "high", fs=fs, output="sos"),
        signal.butter(order, high, "low", fs=fs, output="sos"),
    ])
    padlen = min(x.size - 1, int(np.ceil(3 * fs / low)))
    return signal.sosfiltfilt(sos, x, padlen=padlen)


def rms_envelope(x: np.ndarray, window_s: float, fs: float = FS) -> np.ndarray:
    w = max(1, int(round(window_s * fs)))
    return np.sqrt(np.convolve(x * x, np.ones(w) / w, mode="same"))


def candidate_beats(x_vib: np.ndarray, t: np.ndarray, refractory_s: float = 0.35) -> np.ndarray:
    """Exploratory candidate peaks on the cardiac-vibration envelope (not validated heartbeats)."""
    env = rms_envelope(x_vib, 0.06)
    thr = 0.35 * _sliding_max(env, int(2.0 * FS))  # fraction of local max, as in the app
    peaks, _ = signal.find_peaks(env, height=thr, distance=int(refractory_s * FS))
    return t[peaks]


def _sliding_max(x: np.ndarray, width: int) -> np.ndarray:
    from scipy.ndimage import maximum_filter1d
    return maximum_filter1d(x, size=max(1, width), mode="nearest")


def match(detected: np.ndarray, reference: np.ndarray, tol: float = 0.1, offset: float = 0.0) -> dict:
    det = np.sort(detected - offset)
    used = np.zeros(det.size, bool)
    errors = []
    for r in np.sort(reference):
        idx = np.where((~used) & (np.abs(det - r) <= tol))[0]
        if idx.size:
            k = idx[np.argmin(np.abs(det[idx] - r))]
            used[k] = True
            errors.append(det[k] - r)
    tp = len(errors)
    return {
        "reference_beats": int(reference.size),
        "detected": int(detected.size),
        "true_positives": tp,
        "sensitivity": tp / reference.size if reference.size else float("nan"),
        "ppv": tp / detected.size if detected.size else float("nan"),
        "timing_error_mean_ms": float(np.mean(errors) * 1e3) if errors else float("nan"),
        "timing_error_sd_ms": float(np.std(errors) * 1e3) if errors else float("nan"),
        "offset_applied_ms": offset * 1e3,
    }


# ---------------------------------------------------------------------------- main

def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("session", type=Path)
    ap.add_argument("--axis", default="z", choices=["x", "y", "z"])
    ap.add_argument("--window", nargs=2, type=float, metavar=("START", "END"),
                    help="zoom window in seconds relative to session start (default: 10 s from 5 s)")
    ap.add_argument("--out", type=Path, help="output directory (default: <session>/analysis)")
    ap.add_argument("--reference", type=Path,
                    help="CSV with column t_rel_s of reference beat times (e.g. ECG R peaks, same time base)")
    ap.add_argument("--reference-offset-ms", type=float, default=None,
                    help="expected delay mechanical-minus-reference; default: estimated as the median lag")
    ap.add_argument("--candidates", action="store_true", help="detect and plot exploratory candidate peaks")
    ap.add_argument("--show", action="store_true", help="open interactive windows")
    args = ap.parse_args(argv)

    if not args.show:
        matplotlib.use("Agg")
    import matplotlib.pyplot as plt

    session: Path = args.session
    meta = json.loads((session / "metadata.json").read_text())
    out = args.out or session / "analysis"
    out.mkdir(parents=True, exist_ok=True)
    synthetic = bool(meta.get("isSynthetic"))
    title = f"{meta['id']}{'  [SYNTHETIC DATA]' if synthetic else ''}"
    report: dict = {"session": meta["id"], "synthetic": synthetic, "label": meta.get("label", "")}

    accel = load_motion(session / "accelerometer.csv")
    gyro = load_motion(session / "gyroscope.csv")
    if accel is None:
        print("No accelerometer.csv in", session, file=sys.stderr)
        return 1

    report["accelerometer_sampling"] = sampling_stats(accel["t_rel"])
    report["accelerometer_delivery_latency_median_ms"] = float(np.median(accel["received"] - accel["t_uptime"]) * 1e3)
    if gyro is not None:
        report["gyroscope_sampling"] = sampling_stats(gyro["t_rel"])

    t, raw = resample(accel["t_rel"], accel[args.axis])
    raw = signal.detrend(raw)
    filtered = {name: bandpass(raw, lo, hi) for name, (lo, hi) in BANDS.items()}
    w0, w1 = args.window or (5.0, 15.0)
    sel = (t >= w0) & (t <= w1)

    reference = None
    ref_label = None
    if args.reference:
        reference, ref_label = load_reference(args.reference), f"reference ({args.reference.name})"
    elif (session / "truth_beats.csv").exists():
        reference, ref_label = load_reference(session / "truth_beats.csv"), "synthetic ground truth"

    candidates = None
    if args.candidates or reference is not None:
        candidates = candidate_beats(filtered["cardiac_vibration"], t)
        report["candidate_beats"] = int(candidates.size)
    if reference is not None and candidates is not None:
        # Mechanical events lag the ECG R peak; estimate the delay as the median nearest lag.
        if args.reference_offset_ms is not None:
            offset = args.reference_offset_ms / 1e3
        else:
            lags = [candidates[np.argmin(np.abs(candidates - r))] - r for r in reference] if candidates.size else [0.0]
            lags = np.array(lags)
            offset = float(np.median(lags[np.abs(lags) < 0.3])) if np.any(np.abs(lags) < 0.3) else 0.0
        report["comparison"] = {"reference": ref_label, **match(candidates, reference, offset=offset)}

    # --- Figure 1: overview ---------------------------------------------------------------
    fig, axes = plt.subplots(5, 1, figsize=(11, 13), constrained_layout=True)
    fig.suptitle(title)
    ax = axes[0]
    for k, c in zip("xyz", ["tab:red", "tab:green", "tab:blue"]):
        ax.plot(accel["t_rel"], accel[k] - np.mean(accel[k]), lw=0.5, color=c, label=k)
    ax.set_title("Accelerometer, mean removed (g)")
    ax.legend(loc="upper right")
    ax.axvspan(w0, w1, color="0.85", zorder=0)

    for ax, name in zip(axes[1:4], BANDS):
        lo, hi = BANDS[name]
        ax.plot(t[sel], filtered[name][sel] * 1e3, lw=0.8)
        ax.set_title(f"{args.axis}: {name.replace('_', ' ')} band {lo}–{hi} Hz (mg)")
        if reference is not None:
            for r in reference[(reference >= w0) & (reference <= w1)]:
                ax.axvline(r, color="tab:green", lw=0.6, alpha=0.6)
        if name == "cardiac_vibration" and candidates is not None:
            cs = candidates[(candidates >= w0) & (candidates <= w1)]
            ax.plot(cs, np.interp(cs, t, filtered[name]) * 1e3, "rv", ms=5, label="candidate (unvalidated)")
            ax.legend(loc="upper right")
    axes[3].set_xlabel("s")

    ax = axes[4]
    dt = np.diff(accel["t_rel"]) * 1e3
    ax.hist(np.round(dt, 3), bins=100, color="0.4")
    ax.set_yscale("log")
    ax.set_title("Accelerometer sample intervals (ms)")
    fig.savefig(out / "overview.png", dpi=130)

    # --- Figure 2: spectra ------------------------------------------------------------------
    fig, axes = plt.subplots(2, 1, figsize=(11, 7), constrained_layout=True)
    fig.suptitle(title + " — Welch PSD (8 s segments)")
    for k, c in zip("xyz", ["tab:red", "tab:green", "tab:blue"]):
        _, v = resample(accel["t_rel"], accel[k])
        f, p = signal.welch(signal.detrend(v), fs=FS, nperseg=int(8 * FS))
        axes[0].semilogy(f, p, color=c, lw=0.8, label=k)
        axes[1].semilogy(f[f <= 5], p[f <= 5], color=c, lw=0.8, label=k)
    axes[0].set_xlabel("Hz"); axes[0].legend()
    axes[1].set_xlabel("Hz (0–5, beats/min = Hz × 60)")
    fig.savefig(out / "spectra.png", dpi=130)

    # --- Figure 3: audio ---------------------------------------------------------------------
    audio_meta = meta.get("audio")
    wav = session / (audio_meta or {}).get("fileName", "audio.wav")
    if audio_meta and wav.exists():
        fs_a, a = wavfile.read(wav)
        a = a.astype(np.float64)
        if a.ndim > 1:
            a = a[:, 0]
        offset = (audio_meta.get("firstFrameUptimeS") or meta["referenceUptimeS"]) - meta["referenceUptimeS"]
        hop = int(fs_a / 100)
        n = a.size // hop
        env = np.sqrt(np.mean(a[: n * hop].reshape(n, hop) ** 2, axis=1))
        ta = offset + (np.arange(n) + 0.5) * hop / fs_a
        report["audio"] = {"sample_rate_hz": int(fs_a), "frames": int(a.size), "first_frame_rel_s": offset,
                           "input_latency_ms_not_applied": (audio_meta.get("inputLatencyS") or 0) * 1e3}
        fig, axes = plt.subplots(2, 1, figsize=(11, 6), constrained_layout=True, sharex=True)
        fig.suptitle(title + " — microphone")
        axes[0].plot(ta, env, lw=0.5, color="tab:orange")
        axes[0].set_title("Audio RMS (10 ms, full scale = 1), motion time base")
        axes[1].plot(t, filtered["cardiac_vibration"] * 1e3, lw=0.5)
        axes[1].set_title(f"Accelerometer {args.axis}, cardiac vibration band (mg)")
        axes[1].set_xlabel("s")
        fig.savefig(out / "audio.png", dpi=130)

    (out / "report.json").write_text(json.dumps(report, indent=2))
    print(json.dumps(report, indent=2))
    print(f"\nFigures and report written to {out}")
    if synthetic:
        print("NOTE: this session is SYNTHETIC DATA, not a measurement.")
    if args.show:
        plt.show()
    return 0


if __name__ == "__main__":
    sys.exit(main())
