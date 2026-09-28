"""Spectral-moments validation tier: CoG, SD, skewness, kurtosis vs Praat.

Synthesizes fricative-like noise spectra (band-passed, high-passed,
sloped) plus tonal edge cases, then compares openphon-core's spectral
moments against Praat's Spectrum queries (parselmouth, power p = 2) on
the same files. Promoted to a release gate only if parity holds (see
VALIDATION.md).
"""
import csv, os, struct, subprocess, sys, wave
from pathlib import Path
import numpy as np
import parselmouth
from synthesize import resonator, SR

HERE = Path(__file__).parent
CORE = HERE.parent / "core"
EXE = CORE / ("target/release/examples/spectral_moments"
              + (".exe" if os.name == "nt" else ""))
SP = HERE / "wavs" / "spectral"

RNG = np.random.default_rng(20260719)


def white(dur_s):
    return RNG.standard_normal(int(SR * dur_s))


def highpass(x, alpha=0.95):
    # First-difference-style high-pass: y[n] = x[n] - alpha*x[n-1].
    y = np.copy(x)
    y[1:] -= alpha * x[:-1]
    return y


def cases():
    d = 0.8
    yield "sp_white", white(d)
    # Sibilant-like: high-passed noise shaped by a high resonance.
    yield "sp_s_like", resonator(highpass(white(d)), 7500, 1500)
    yield "sp_sh_like", resonator(highpass(white(d)), 4000, 1200)
    # Low, compact spectrum: band-passed noise at 1.5 kHz.
    yield "sp_band15", resonator(white(d), 1500, 400)
    # Sloped broadband (integrated white ~ -6 dB/oct).
    yield "sp_sloped", np.cumsum(white(d)) * 0.01
    # Tonal edge case: two equal tones.
    t = np.arange(int(SR * d)) / SR
    yield "sp_twotone", np.sin(2 * np.pi * 2000 * t) + np.sin(2 * np.pi * 6000 * t)


def write_wav16(path, s):
    s = s / (np.max(np.abs(s)) + 1e-9) * 0.9
    with wave.open(str(path), "wb") as w:
        w.setnchannels(1); w.setsampwidth(2); w.setframerate(SR)
        w.writeframes(struct.pack(f"<{len(s)}h", *(int(v * 32767) for v in s)))


def praat_moments(path):
    spec = parselmouth.Sound(str(path)).to_spectrum()
    return (spec.get_center_of_gravity(power=2),
            spec.get_standard_deviation(power=2),
            spec.get_skewness(power=2),
            spec.get_kurtosis(power=2))


def openphon_moments(path):
    out = subprocess.run([str(EXE), str(path)], check=True, capture_output=True,
                         text=True).stdout
    d = {r[0]: r[1] for r in csv.reader(out.strip().splitlines()[1:])}
    return tuple(float(d[k]) for k in ("cog_hz", "sd_hz", "skewness", "kurtosis"))


def main():
    SP.mkdir(parents=True, exist_ok=True)
    rows = []
    for name, s in cases():
        path = SP / f"{name}.wav"
        write_wav16(path, s)
        rows.append((name, openphon_moments(path), praat_moments(path)))

    print(f"{'file':<14}{'CoG op':>9}{'CoG pr':>9}{'SD op':>9}{'SD pr':>9}"
          f"{'skew op':>9}{'skew pr':>9}{'kurt op':>9}{'kurt pr':>9}")
    cog_rel, sd_rel, skew_abs, kurt_rel = [], [], [], []
    for name, op, pr in rows:
        print(f"{name:<14}{op[0]:>9.1f}{pr[0]:>9.1f}{op[1]:>9.1f}{pr[1]:>9.1f}"
              f"{op[2]:>9.3f}{pr[2]:>9.3f}{op[3]:>9.3f}{pr[3]:>9.3f}")
        cog_rel.append(abs(op[0] - pr[0]) / pr[0])
        sd_rel.append(abs(op[1] - pr[1]) / pr[1])
        skew_abs.append(abs(op[2] - pr[2]))
        # Kurtosis is unbounded; compare relative to its magnitude + 1.
        kurt_rel.append(abs(op[3] - pr[3]) / (abs(pr[3]) + 1.0))

    gates = [
        ("CoG mean relative deviation", float(np.mean(cog_rel)), 0.01),
        ("SD mean relative deviation", float(np.mean(sd_rel)), 0.02),
        ("skewness mean abs deviation", float(np.mean(skew_abs)), 0.05),
        ("kurtosis mean relative deviation", float(np.mean(kurt_rel)), 0.05),
    ]
    print("\nparity gates:")
    ok = True
    for label, val, gate in gates:
        passed = val < gate
        ok &= passed
        print(f"  {label:<34}{val:>10.5f}  (gate < {gate})  {'PASS' if passed else 'FAIL'}")
    print("\nRESULT:", "PASS" if ok else "FAIL")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
