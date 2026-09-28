"""Voice-quality validation tier: HNR, jitter, shimmer vs Praat Voice Report.

Synthesizes sustained vowels with a Rosenberg source at known jitter and
shimmer, then compares openphon-core's voice_report against Praat's Voice
Report (parselmouth) on the same files. Diagnostic; promoted to a release
gate only if parity holds (see VALIDATION.md).
"""
import csv, os, subprocess, sys, tempfile
from pathlib import Path
import numpy as np
import parselmouth
from parselmouth.praat import call
from synthesize import rosenberg_train, resonator, SR, write_wav

HERE = Path(__file__).parent
CORE = HERE.parent / "core"
EXE = CORE / ("target/release/examples/voice_report"
              + (".exe" if os.name == "nt" else ""))
VQ = HERE / "wavs" / "vq"

# Conditions whose HNR is not a meaningful comparison, named in advance of
# any measurement. A perfectly periodic synthetic vowel has no additive
# noise, so both tools report whatever numerical floor their arithmetic
# reaches (116 dB against 128 dB on one file here) and the difference says
# nothing about harmonicity estimation. Excluding by *measured* value
# instead, as an earlier version did with a 40 dB cap read from both tools'
# outputs, makes the inclusion criterion a function of the outcome and
# drops exactly the disagreements the check exists to find.
HNR_EXEMPT_CONDITIONS = {"vq_clean_150", "vq_clean_220"}

# Sustained vowel /a/ formants; a set of (name, f0, jitter, shimmer).
FORMANTS = [(700, 80), (1220, 90), (2600, 120), (3500, 160)]
CASES = [
    ("vq_clean_150", 150, 0.0, 0.0),
    ("vq_jit005_150", 150, 0.005, 0.0),
    ("vq_jit01_150", 150, 0.01, 0.0),
    ("vq_shim05_150", 150, 0.0, 0.05),
    ("vq_shim10_150", 150, 0.0, 0.10),
    ("vq_jit01_shim05_120", 120, 0.01, 0.05),
    ("vq_clean_220", 220, 0.0, 0.0),
    ("vq_jit01_220", 220, 0.01, 0.0),
]

def synth(f0, jitter, shimmer, dur_s=1.5):
    src = rosenberg_train(f0, dur_s, jitter=jitter, shimmer=shimmer, seed=41)
    x = src
    for f, bw in FORMANTS:
        x = resonator(x, f, bw)
    x /= np.max(np.abs(x)) + 1e-9
    return 0.9 * x

def praat_report(path, f0min=75, f0max=600):
    snd = parselmouth.Sound(str(path))
    pitch = snd.to_pitch_cc(pitch_floor=f0min, pitch_ceiling=f0max)
    pp = call([snd, pitch], "To PointProcess (cc)")
    jitter = call(pp, "Get jitter (local)", 0, 0, 1e-4, 0.02, 1.3)
    shimmer = call([snd, pp], "Get shimmer (local)", 0, 0, 1e-4, 0.02, 1.3, 1.6)
    # Compare against Praat's AUTOCORRELATION harmonicity at the same 6.0
    # periods-per-window as the core: openphon implements the ac method, so
    # this is the apples-to-apples comparison (Praat's cc method uses a
    # different, cross-correlation windowing and its own default window).
    harm = call(snd, "To Harmonicity (ac)", 0.01, f0min, 0.1, 6.0)
    vals = harm.values[harm.values != -200]
    hnr = float(np.mean(vals)) if vals.size else float("nan")
    # Median F0 from the AUTOCORRELATION tracker. The cross-correlation
    # pitch above exists only to build the point process Praat's jitter and
    # shimmer recipe requires; taking the F0 summary from it too would make
    # this the one F0 comparison in the project measured against a
    # different reference from all the others.
    pitch_ac = snd.to_pitch_ac(pitch_floor=f0min, pitch_ceiling=f0max)
    median_f0 = float(call(pitch_ac, "Get quantile", 0, 0, 0.50, "Hertz"))
    return hnr, float(jitter), float(shimmer), median_f0

def openphon_report(path):
    out = subprocess.run([str(EXE), str(path)], check=True, capture_output=True, text=True).stdout
    d = {r[0]: r[1] for r in csv.reader(out.strip().splitlines()[1:])}
    return (float(d["hnr_db"]), float(d["jitter_local"]), float(d["shimmer_local"]),
            float(d["median_f0_hz"]))

def main():
    VQ.mkdir(parents=True, exist_ok=True)
    rows = []
    for name, f0, jit, shim in CASES:
        s = synth(f0, jit, shim)
        path = VQ / f"{name}.wav"
        # write 16-bit PCM
        import wave, struct
        with wave.open(str(path), "wb") as w:
            w.setnchannels(1); w.setsampwidth(2); w.setframerate(SR)
            w.writeframes(struct.pack(f"<{len(s)}h", *(int(max(-1,min(1,v))*32767) for v in s)))
        op = openphon_report(path)
        pr = praat_report(path)
        rows.append((name, jit, shim, op, pr))

    print(f"{'file':<24}{'jit_in':>7}{'shim_in':>8}"
          f"{'HNR op':>8}{'HNR pr':>8}{'jit op':>9}{'jit pr':>9}{'shim op':>9}{'shim pr':>9}"
          f"{'F0 op':>8}{'F0 pr':>8}")
    hnr_err, jit_err, shim_err, f0_err = [], [], [], []
    for name, jit, shim, op, pr in rows:
        exempt = name in HNR_EXEMPT_CONDITIONS
        print(f"{name:<24}{jit:>7.3f}{shim:>8.3f}"
              f"{op[0]:>8.1f}{pr[0]:>8.1f}{op[1]:>9.5f}{pr[1]:>9.5f}{op[2]:>9.5f}{pr[2]:>9.5f}"
              f"{op[3]:>8.2f}{pr[3]:>8.2f}" + ("  (HNR exempt)" if exempt else ""))
        if not exempt and np.isfinite(op[0]) and np.isfinite(pr[0]):
            hnr_err.append(abs(op[0] - pr[0]))
        if np.isfinite(op[1]) and np.isfinite(pr[1]): jit_err.append(abs(op[1]-pr[1]))
        if np.isfinite(op[2]) and np.isfinite(pr[2]): shim_err.append(abs(op[2]-pr[2]))
        if np.isfinite(op[3]) and np.isfinite(pr[3]): f0_err.append(abs(op[3]-pr[3]))

    hnr_mad = float(np.mean(hnr_err))
    jit_mad = float(np.mean(jit_err))
    shim_mad = float(np.mean(shim_err))
    f0_mad = float(np.mean(f0_err))
    print(f"\nmean |dHNR| = {hnr_mad:.2f} dB "
          f"(over {len(hnr_err)} of {len(rows)} files; "
          f"{sorted(HNR_EXEMPT_CONDITIONS)} exempt by condition)   "
          f"mean |djitter| = {jit_mad*100:.3f}%   "
          f"mean |dshimmer| = {shim_mad*100:.3f}%   "
          f"mean |dmedianF0| = {f0_mad:.3f} Hz")

    # Parity gates vs Praat Voice Report on sustained vowels (see
    # VALIDATION.md for the rationale of each threshold).
    gates = [
        ("HNR mean abs deviation (dB)", hnr_mad, 2.0),
        ("jitter local mean abs deviation", jit_mad, 0.002),
        ("shimmer local mean abs deviation", shim_mad, 0.010),
        # Same bar as the track-level tiers in compare.py.
        ("median F0 mean abs deviation (Hz)", f0_mad, 2.0),
    ]
    print("\nparity gates:")
    ok = True
    for label, val, gate in gates:
        passed = val < gate
        ok &= passed
        print(f"  {label:<36}{val:>10.5f}  (gate < {gate})  {'PASS' if passed else 'FAIL'}")
    print("\nRESULT:", "PASS" if ok else "FAIL")
    return 0 if ok else 1

if __name__ == "__main__":
    sys.exit(main())
