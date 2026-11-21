#!/usr/bin/env python3
"""Renders the preliminary-result figures in docs/images/ (light and dark variants).

Usage:
    python analysis/make_readme_figures.py <sessions-dir> docs/images

<sessions-dir> must contain the session folders listed in SESSIONS below. The recordings are
not part of the repository; the figures document what they showed.
"""
from __future__ import annotations

import sys
from pathlib import Path

import numpy as np
from scipy import signal
from scipy.io import wavfile
from scipy.ndimage import maximum_filter1d
import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt  # noqa: E402

SESSIONS = {
    "table": "20261121T102324Z-4650",   # phone at rest on a table
    "tap": "20261121T102951Z-43B3",     # tap test
    "human": "20261121T103406Z-F110",   # adult, supine, sternum, breath-hold
    "dog": "20261121T105129Z-871C",     # dog lying on its side, phone resting on chest side
}

THEMES = {
    "light": dict(surface="#fcfcfb", text="#0b0b0b", text2="#52514e", grid="#e4e3df",
                  s1="#2a78d6", s2="#eb6834", s3="#1baf7a"),
    "dark": dict(surface="#1a1a19", text="#f0efec", text2="#c3c2b7", grid="#383835",
                 s1="#3987e5", s2="#d95926", s3="#199e70"),
}


def load(sdir: Path, sid: str):
    a = np.genfromtxt(sdir / sid / "accelerometer.csv", delimiter=",", names=True)
    t = a["t_rel_s"]
    return t, a, 1 / np.median(np.diff(t))


def bandpass(x, lo, hi, fs):
    sos = np.vstack([signal.butter(2, lo, "high", fs=fs, output="sos"),
                     signal.butter(2, hi, "low", fs=fs, output="sos")])
    return signal.sosfiltfilt(sos, x, padlen=min(len(x) - 1, int(3 * fs / lo)))


def style(ax, th):
    ax.set_facecolor(th["surface"])
    for side in ("top", "right"):
        ax.spines[side].set_visible(False)
    for side in ("left", "bottom"):
        ax.spines[side].set_color(th["grid"])
    ax.tick_params(colors=th["text2"], labelsize=9, length=0)
    ax.grid(axis="y", color=th["grid"], lw=0.6)
    ax.set_axisbelow(True)
    ax.xaxis.label.set_color(th["text2"])
    ax.yaxis.label.set_color(th["text2"])


def candidates(t, x, fs):
    """Exploratory candidate beats: RMS envelope of the 5-30 Hz band, adaptive threshold."""
    v = bandpass(signal.detrend(x), 5, 30, fs)
    env = np.convolve(np.sqrt(np.convolve(v ** 2, np.ones(8) / 8, "same")), np.ones(5) / 5, "same")
    thr = 0.4 * maximum_filter1d(env, int(2 * fs))
    pk, _ = signal.find_peaks(env, height=thr, distance=int(0.45 * fs))
    return t[pk]


def fig_signals(sdir, out, th, name):
    rows = [("Phone at rest on a table", "table", "z", 20, 28),
            ("Human chest (sternum), breath-hold", "human", "x", 18, 26),
            ("Dog, phone resting on the side of the chest", "dog", "x", 20, 28)]
    fig, axs = plt.subplots(3, 1, figsize=(9, 6.4), sharex=True, sharey=True, facecolor=th["surface"])
    for ax, (title, key, axis, t0, t1) in zip(axs, rows):
        t, a, fs = load(sdir, SESSIONS[key])
        v = bandpass(signal.detrend(a[axis + "_g"]), 5, 30, fs) * 1e3
        sel = (t >= t0) & (t <= t1)
        ax.plot(t[sel] - t0, v[sel], color=th["s1"], lw=1.0)
        style(ax, th)
        ax.set_title(title, loc="left", color=th["text"], fontsize=11)
        ax.set_ylim(-20, 20)
        ax.set_yticks([-20, -10, 0, 10, 20])
    axs[1].set_ylabel("acceleration, 5–30 Hz band (mg)")
    axs[-1].set_xlabel("seconds")
    fig.tight_layout()
    fig.savefig(out / f"{name}-{th['mode']}.png", dpi=130, facecolor=th["surface"])
    plt.close(fig)


def fig_intervals(sdir, out, th, name):
    sets = [("Human, breath-hold (smooth change)", "human", "x", 1, 35),
            ("Dog (irregular: arrhythmia or detection errors?)", "dog", "x", 2.5, 58.5)]
    fig, axs = plt.subplots(1, 2, figsize=(9, 3.4), sharey=True, facecolor=th["surface"])
    for ax, (title, key, axis, t0, t1) in zip(axs, sets):
        t, a, fs = load(sdir, SESSIONS[key])
        sel = (t >= t0) & (t <= t1)
        bt = candidates(t[sel], a[axis + "_g"][sel], fs)
        ibi = np.diff(bt) * 1e3
        ax.plot((bt[1:] - bt[0]), ibi, "-o", color=th["s1"], lw=1.2, ms=4,
                markeredgecolor=th["surface"], markeredgewidth=1)
        style(ax, th)
        ax.set_title(title, loc="left", color=th["text"], fontsize=10)
        ax.set_xlabel("seconds")
    axs[0].set_ylabel("candidate interval (ms)")
    axs[0].set_ylim(300, 1700)
    fig.tight_layout()
    fig.savefig(out / f"{name}-{th['mode']}.png", dpi=130, facecolor=th["surface"])
    plt.close(fig)


def fig_tap(sdir, out, th, name, tap_at=5.8676):
    t, a, fs = load(sdir, SESSIONS["tap"])
    import json
    meta = json.loads((sdir / SESSIONS["tap"] / "metadata.json").read_text())
    mag = np.sqrt(a["x_g"] ** 2 + a["y_g"] ** 2 + a["z_g"] ** 2)
    hp = signal.sosfiltfilt(signal.butter(2, 5, "high", fs=fs, output="sos"), mag)
    fa, w = wavfile.read(sdir / SESSIONS["tap"] / "audio.wav")
    w = w.astype(float)
    ta = meta["audio"]["firstFrameUptimeS"] - meta["referenceUptimeS"] + np.arange(w.size) / fa
    wh = signal.sosfilt(signal.butter(4, 200, "high", fs=fa, output="sos"), w)
    sa = (ta > tap_at - 0.03) & (ta < tap_at + 0.08)
    sm = (t > tap_at - 0.03) & (t < tap_at + 0.08)
    fig, ax = plt.subplots(figsize=(9, 3.2), facecolor=th["surface"])
    ax.plot((ta[sa] - tap_at) * 1e3, np.abs(wh[sa]) / np.abs(wh[sa]).max(), color=th["s2"], lw=0.8, label="microphone")
    ax.plot((t[sm] - tap_at) * 1e3, np.abs(hp[sm]) / np.abs(hp[sm]).max(), "-o", color=th["s1"], lw=1.6, ms=5,
            markeredgecolor=th["surface"], markeredgewidth=1, label="accelerometer")
    style(ax, th)
    ax.set_xlabel("milliseconds from the start of the tap sound")
    ax.set_ylabel("normalised |signal|")
    leg = ax.legend(frameon=False, loc="upper right", fontsize=9)
    for txt in leg.get_texts():
        txt.set_color(th["text2"])
    fig.tight_layout()
    fig.savefig(out / f"{name}-{th['mode']}.png", dpi=130, facecolor=th["surface"])
    plt.close(fig)


def main():
    sdir, out = Path(sys.argv[1]), Path(sys.argv[2])
    out.mkdir(parents=True, exist_ok=True)
    for mode, th in THEMES.items():
        th = dict(th, mode=mode)
        fig_signals(sdir, out, th, "signals")
        fig_intervals(sdir, out, th, "intervals")
        fig_tap(sdir, out, th, "tap-test")
    print("figures written to", out)


if __name__ == "__main__":
    main()
