"""Generate synthetic benchmark WAVs with known ground truth.

These stand in for the real ~30-recording benchmark set until it is
assembled; they exercise male/female/child F0 ranges, the cardinal-ish
vowel space, an F0 glide, and additive noise. All files are 16-bit PCM
mono, 44100 Hz, written into wavs/.
"""

import json
import math
import sys
import wave
from pathlib import Path

import numpy as np

SR = 44100
OUT = Path(__file__).parent / "wavs"


def impulse_train(f0, dur_s, sr=SR, jitter=0.0, seed=987):
    """F0 may be a scalar or a callable t -> Hz (for glides).

    `jitter` perturbs each period's length by a factor drawn from
    N(1, jitter) (seeded), approximating the cycle-to-cycle irregularity
    of creaky/pressed phonation.
    """
    n = int(sr * dur_s)
    x = np.zeros(n)
    phase = 0.0
    rng = np.random.default_rng(seed)
    factor = 1.0
    for i in range(n):
        f = f0(i / sr) if callable(f0) else f0
        phase += f * factor / sr
        if phase >= 1.0:
            phase -= 1.0
            x[i] = 1.0
            if jitter > 0.0:
                factor = max(0.5, rng.normal(1.0, jitter))
    return x


def resonator(x, freq, bw, sr=SR):
    r = math.exp(-math.pi * bw / sr)
    theta = 2 * math.pi * freq / sr
    b1, b2 = 2 * r * math.cos(theta), -r * r
    y = np.zeros_like(x)
    for i in range(len(x)):
        v = x[i]
        if i >= 1:
            v += b1 * y[i - 1]
        if i >= 2:
            v += b2 * y[i - 2]
        y[i] = v
    return y


def resonator_glide(x, freq_fn, bw, sr=SR):
    """Resonator whose center frequency follows `freq_fn(t)` (Hz); the
    coefficients are recomputed per sample, which is slow but exact enough
    for benchmark synthesis of CV transitions and diphthongs."""
    r = math.exp(-math.pi * bw / sr)
    rr = -r * r
    y = np.zeros_like(x)
    for i in range(len(x)):
        b1 = 2 * r * math.cos(2 * math.pi * freq_fn(i / sr) / sr)
        v = x[i]
        if i >= 1:
            v += b1 * y[i - 1]
        if i >= 2:
            v += rr * y[i - 2]
        y[i] = v
    return y


def rosenberg_train(f0, dur_s, sr=SR, jitter=0.0, shimmer=0.0, seed=987,
                    open_q=0.6, close_q=0.3):
    """Rosenberg-B glottal flow derivative pulse train.

    Each cycle rises over `open_q` of the period and falls over `close_q`
    (the rest is closed phase); the flow derivative excites the vocal-tract
    resonators with a realistic -12 dB/oct source slope instead of the flat
    spectrum of an impulse train. `jitter` perturbs period lengths and
    `shimmer` perturbs cycle amplitudes (both N(1, x), seeded).
    """
    n = int(sr * dur_s)
    x = np.zeros(n)
    rng = np.random.default_rng(seed)
    pos = 0.0
    while True:
        f = f0(pos / sr) if callable(f0) else f0
        period = sr / f
        if jitter > 0.0:
            period *= max(0.5, rng.normal(1.0, jitter))
        amp = 1.0
        if shimmer > 0.0:
            amp = max(0.1, rng.normal(1.0, shimmer))
        start = int(round(pos))
        if start >= n:
            break
        t_open = open_q * period
        t_close = close_q * period
        # Rosenberg-B flow: raised-cosine rise, cosine fall; excite with
        # its numerical derivative.
        length = int(t_open + t_close) + 1
        flow = np.zeros(length + 1)
        for j in range(length):
            if j < t_open:
                flow[j] = 0.5 * (1 - math.cos(math.pi * j / t_open))
            elif j < t_open + t_close:
                flow[j] = math.cos(0.5 * math.pi * (j - t_open) / t_close)
        dflow = np.diff(flow)
        stop = min(n, start + len(dflow))
        x[start:stop] += amp * dflow[: stop - start]
        pos += period
    return x


def amplitude_contour(x, sr=SR, attack_s=0.06, release_s=0.12, arch=0.25):
    """Fade-in/out plus a gentle arch peaking mid-utterance, approximating
    a natural sustained-vowel intensity contour."""
    n = len(x)
    env = np.ones(n)
    a = min(n, int(attack_s * sr))
    r = min(n, int(release_s * sr))
    env[:a] *= np.linspace(0.0, 1.0, a)
    env[n - r:] *= np.linspace(1.0, 0.0, r)
    t = np.linspace(0.0, 1.0, n)
    env *= 1.0 - arch * (2 * t - 1) ** 2
    return x * env


def natural_vowel(f0, formants, dur_s=1.0, jitter=0.005, shimmer=0.03,
                  aspiration_db=-30.0, seed=987):
    """A vowel with a Rosenberg source, mild jitter/shimmer, pulse-modulated
    aspiration noise, and an amplitude contour: the 'realistic synthesis'
    tier, still with exactly known F0."""
    src = rosenberg_train(f0, dur_s, jitter=jitter, shimmer=shimmer, seed=seed)
    rng = np.random.default_rng(seed + 1)
    noise = rng.standard_normal(len(src))
    src_rms = np.sqrt(np.mean(src**2))
    asp = noise * src_rms * (10 ** (aspiration_db / 20))
    x = src + asp
    for freq, bw in formants:
        x = resonator(x, freq, bw)
    x = amplitude_contour(x)
    return x / np.max(np.abs(x)) * 0.3


def whispered_vowel(formants, dur_s=1.0, sr=SR, seed=2024):
    """Aspiration-only excitation: formant structure with no periodicity.
    Ground truth is unvoiced everywhere."""
    rng = np.random.default_rng(seed)
    x = rng.standard_normal(int(sr * dur_s))
    for freq, bw in formants:
        x = resonator(x, freq, bw, sr=sr)
    x = amplitude_contour(x, sr=sr)
    return x / np.max(np.abs(x)) * 0.3


def vowel(f0, formants, dur_s=1.0, snr_db=None, jitter=0.0, sr=SR):
    x = impulse_train(f0, dur_s, sr=sr, jitter=jitter)
    for freq, bw in formants:
        x = resonator(x, freq, bw, sr=sr)
    x = x / np.max(np.abs(x)) * 0.3
    if snr_db is not None:
        rng = np.random.default_rng(12345)
        noise = rng.standard_normal(len(x))
        sig_rms = np.sqrt(np.mean(x**2))
        noise_rms = sig_rms / (10 ** (snr_db / 20))
        x = x + noise / np.sqrt(np.mean(noise**2)) * noise_rms
        x = x / np.max(np.abs(x)) * 0.3
    return x


def write_wav(name, samples, stress=False, sr=SR):
    out = OUT / "stress" if stress else OUT
    out.mkdir(parents=True, exist_ok=True)
    path = out / name
    pcm = (np.clip(samples, -1, 1) * 32767).astype("<i2")
    with wave.open(str(path), "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(sr)
        w.writeframes(pcm.tobytes())
    print("wrote", path.name)


# (name, F0, [(F, bw), ...]) — formant values from standard vowel tables.
VOWELS = [
    ("male_a_110", 110, [(700, 80), (1220, 90), (2600, 120), (3500, 160)]),
    ("male_i_110", 110, [(300, 60), (2300, 100), (3000, 140), (3800, 180)]),
    ("male_u_110", 110, [(300, 60), (870, 90), (2240, 120), (3400, 170)]),
    ("male_e_130", 130, [(530, 70), (1840, 100), (2480, 120), (3520, 170)]),
    ("female_a_210", 210, [(850, 90), (1220, 90), (2810, 130), (3900, 180)]),
    ("female_i_210", 210, [(310, 60), (2790, 110), (3310, 150), (4200, 200)]),
    ("female_u_220", 220, [(370, 60), (950, 90), (2670, 130), (3900, 190)]),
    ("child_a_300", 300, [(1030, 100), (1370, 110), (3170, 150), (4300, 210)]),
    # High child F0 (harmonics 400+ Hz apart undersample the envelope:
    # the classic hard case for both trackers).
    ("child_i_400", 400, [(370, 70), (3200, 130), (3700, 170), (4500, 220)]),
    ("child_a_450", 450, [(1030, 100), (1370, 110), (3170, 150), (4300, 210)]),
]


# --------------------------------------------------- formant-error grid ----

# A vowel grid crossed with an F0 sweep, on the design of Shadle, Nam &
# Whalen (2016): formant targets are known because they are the synthesis
# poles, so estimation error is measurable rather than inferable from
# agreement between two estimators. The F0 sweep is the axis of Chen,
# Whalen & Shadle (2019): LPC estimates the envelope from a spectrum
# sampled at harmonics, so the error should grow with F0 as the harmonics
# thin out, and a grid crossed with F0 shows where.
#
# Two pole-count conditions are synthesised for every cell. The standard
# analysis setting asks for five formants below 5500 Hz. The 4-pole
# condition therefore has one resonance fewer than the analysis expects and
# the 5-pole condition has exactly as many, which separates estimation
# error from the label shift that a spare pole causes. Nothing else differs
# between them.
GRID_F1 = (300.0, 450.0, 600.0, 750.0)
GRID_F2 = (900.0, 1300.0, 1700.0, 2100.0, 2500.0)
GRID_F0 = (100.0, 150.0, 200.0, 250.0, 300.0, 350.0, 400.0)
GRID_MIN_SPACING = 400.0      # F2 - F1 below this is not a vowel
GRID_F3, GRID_F4, GRID_F5 = 2600.0, 3500.0, 4500.0
GRID_BW = (60.0, 90.0, 120.0, 150.0, 200.0)
GRID_DUR_S = 0.5
# Fade at each end, short enough to leave a long steady interior and long
# enough that the onset is not a click with energy at every frequency.
GRID_FADE_S = 0.02


def grid_cells():
    """(stem, f0, [(freq, bw), ...]) for every cell of the formant grid."""
    out = []
    for f1 in GRID_F1:
        for f2 in GRID_F2:
            if f2 - f1 < GRID_MIN_SPACING:
                continue
            for f0 in GRID_F0:
                for n_poles in (4, 5):
                    freqs = [f1, f2, GRID_F3, GRID_F4, GRID_F5][:n_poles]
                    poles = list(zip(freqs, GRID_BW[:n_poles]))
                    stem = (f"vg_f1{int(f1)}_f2{int(f2)}"
                            f"_f0{int(f0)}_p{n_poles}")
                    out.append((stem, f0, poles))
    return out


def grid_vowel(f0, poles, dur_s=GRID_DUR_S, sr=SR):
    """One grid cell: Rosenberg source through a cascade of resonators.

    No jitter, no shimmer and no aspiration: the question is how well an
    estimator recovers poles that are exactly known, and every source of
    irregularity added here would be charged to the estimator.
    """
    x = rosenberg_train(f0, dur_s, sr=sr)
    for freq, bw in poles:
        x = resonator(x, freq, bw, sr=sr)
    n = len(x)
    fade = min(n // 2, int(GRID_FADE_S * sr))
    env = np.ones(n)
    env[:fade] = np.linspace(0.0, 1.0, fade)
    env[n - fade:] = np.linspace(1.0, 0.0, fade)
    x = x * env
    return x / np.max(np.abs(x)) * 0.3


def write_grid():
    out = OUT / "formantgrid"
    out.mkdir(parents=True, exist_ok=True)
    cells = grid_cells()
    for i, (stem, f0, poles) in enumerate(cells, 1):
        path = out / f"{stem}.wav"
        pcm = (np.clip(grid_vowel(f0, poles), -1, 1) * 32767).astype("<i2")
        with wave.open(str(path), "wb") as w:
            w.setnchannels(1)
            w.setsampwidth(2)
            w.setframerate(SR)
            w.writeframes(pcm.tobytes())
        if i % 20 == 0 or i == len(cells):
            print(f"  {i}/{len(cells)} grid files", flush=True)
    # The truth table travels with the audio: a tier whose ground truth
    # lives only in the code that made it cannot be scored from a checkout.
    (out / "truth.json").write_text(json.dumps({
        "design": "vowel grid x F0 sweep x pole count, Klatt-style cascade",
        "duration_s": GRID_DUR_S, "sample_rate": SR,
        "fade_s": GRID_FADE_S,
        "cells": [{"stem": s, "f0_hz": f0,
                   "poles_hz": [f for f, _ in p],
                   "bandwidths_hz": [b for _, b in p]}
                  for s, f0, p in cells],
    }, indent=2))
    print(f"wrote {out / 'truth.json'} ({len(cells)} cells)")


def main():
    if "--grid" in sys.argv:
        return write_grid()
    for name, f0, formants in VOWELS:
        write_wav(f"{name}.wav", vowel(f0, formants))
    # F0 glide 100 -> 200 Hz over 1.5 s (male /a/ tract).
    glide = vowel(
        lambda t: 100 + (200 - 100) * t / 1.5,
        [(700, 80), (1220, 90), (2600, 120), (3500, 160)],
        dur_s=1.5,
    )
    write_wav("male_a_glide_100_200.wav", glide)
    # Noisy vowels (recording-condition robustness).
    write_wav(
        "male_a_110_snr20.wav",
        vowel(110, [(700, 80), (1220, 90), (2600, 120), (3500, 160)], snr_db=20),
    )
    write_wav(
        "male_a_110_snr10.wav",
        vowel(110, [(700, 80), (1220, 90), (2600, 120), (3500, 160)], snr_db=10),
        stress=True,
    )
    # Low F0 near the pitch floor with 2% cycle jitter (creaky-adjacent).
    write_wav(
        "male_a_80_jitter2.wav",
        vowel(80, [(700, 80), (1220, 90), (2600, 120), (3500, 160)], jitter=0.02),
        stress=True,
    )

    male_a = [(700, 80), (1220, 90), (2600, 120), (3500, 160)]
    female_a = [(850, 90), (1220, 90), (2810, 130), (3900, 180)]

    # Realistic-source tier: Rosenberg flow-derivative excitation with mild
    # jitter/shimmer, pulse-scaled aspiration, and an amplitude contour.
    write_wav("male_a_110_natural.wav", natural_vowel(110, male_a))
    write_wav("female_a_210_natural.wav", natural_vowel(210, female_a))

    # CV-like onset: F1/F2 glide from a stop locus into /a/ over 80 ms.
    def _ba_transition():
        src = rosenberg_train(110, 0.8)
        rise = 0.08
        x = resonator_glide(
            src, lambda t: 250 + (700 - 250) * min(t / rise, 1.0), 80
        )
        x = resonator_glide(
            x, lambda t: 900 + (1220 - 900) * min(t / rise, 1.0), 90
        )
        x = resonator(x, 2600, 120)
        x = resonator(x, 3500, 160)
        x = amplitude_contour(x)
        return x / np.max(np.abs(x)) * 0.3

    write_wav("ba_110.wav", _ba_transition())

    # Diphthong /ai/: formants glide across the whole vowel.
    def _ai_diphthong():
        dur = 0.8
        src = rosenberg_train(120, dur)
        x = resonator_glide(src, lambda t: 700 + (300 - 700) * t / dur, 80)
        x = resonator_glide(x, lambda t: 1220 + (2300 - 1220) * t / dur, 100)
        x = resonator(x, 2600, 120)
        x = resonator(x, 3500, 160)
        x = amplitude_contour(x)
        return x / np.max(np.abs(x)) * 0.3

    write_wav("ai_diphthong_120.wav", _ai_diphthong())

    # Other sample rates (recorder settings now offer 16k/48k).
    write_wav("male_a_110_sr16k.wav", vowel(110, male_a, sr=16000), sr=16000)
    write_wav("male_a_110_sr48k.wav", vowel(110, male_a, sr=48000), sr=48000)

    # Whispered /a/: formant structure, zero periodicity. Both trackers
    # must call every frame unvoiced.
    write_wav("whisper_a.wav", whispered_vowel(male_a))


if __name__ == "__main__":
    main()
