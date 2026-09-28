"""Compare openphon-core tracks against Praat references. The release gate.

For every wavs/*.wav with references in refs/, runs the core's tracks_csv
example and computes:

  F0:       voicing agreement (%), median |dF0| on frames voiced in both
  Formants: RMSE of F1..F3 on frames where both trackers report a value

Gate thresholds (from the founding plan):
  voicing agreement > 99%          (aggregate over the benchmark set)
  median F0 deviation < 2 Hz       (aggregate, voiced frames)
  F1/F2/F3 RMSE < 150 / 250 / 350 Hz (aggregate), inside the divergence
  envelope between established methods measured by intertracker.py

Exit code 0 iff all gates pass. Per-file rows are diagnostic.
"""

import csv
import json
import math
import os
import subprocess
import sys
import tempfile
from pathlib import Path

import numpy as np

import gridalign

HERE = Path(__file__).parent
WAVS = HERE / "wavs"
REFS = HERE / "refs"
CORE = HERE.parent / "core"

MATCH_TOL_S = 0.005

# Known F0 of the synthetic benchmark files (see synthesize.py): every file
# is voiced end-to-end, so truth-based scoring needs only stem -> f0(t).
# The jittered file's truth is its nominal F0 (per-cycle jitter is zero-mean);
# measured deviation there includes the real jitter, not tracker error alone.
from synthesize import VOWELS  # noqa: E402

TRUTH_F0 = {name: (lambda t, f=f0: f) for name, f0, _ in VOWELS}
TRUTH_F0["male_a_glide_100_200"] = lambda t: 100.0 + (200.0 - 100.0) * t / 1.5
TRUTH_F0["male_a_110_snr20"] = lambda t: 110.0
TRUTH_F0["male_a_110_snr10"] = lambda t: 110.0
TRUTH_F0["male_a_80_jitter2"] = lambda t: 80.0
TRUTH_F0["male_a_110_natural"] = lambda t: 110.0
TRUTH_F0["female_a_210_natural"] = lambda t: 210.0
TRUTH_F0["ba_110"] = lambda t: 110.0
TRUTH_F0["ai_diphthong_120"] = lambda t: 120.0
TRUTH_F0["male_a_110_sr16k"] = lambda t: 110.0
TRUTH_F0["male_a_110_sr48k"] = lambda t: 110.0

# Files that are unvoiced by construction: truth-voiced% must be ~0 and no
# F0 comparison applies.
TRUTH_UNVOICED = {"whisper_a"}

# Known formant poles of the synthetic files. synthesize.py builds every one
# of them by cascading second-order resonators whose pole angle is
# 2*pi*f/sr, so the synthesis frequency IS the pole frequency, which is the
# quantity an LPC tracker estimates. It is not the spectral peak: a pole of
# finite bandwidth puts the peak of |H| slightly below the pole, and
# cascading shifts it further, so a peak-picking method would be scored
# against the wrong target here and an LPC method is not.
#
# This is the one tier on which formant accuracy is measurable at all, and
# until now nothing scored it: compare.py measured openphon against Praat on
# material whose answer was known, and reported the disagreement rather than
# the error. See docs/VALIDATION.md.
_MALE_A = (700.0, 1220.0, 2600.0, 3500.0)
_FEMALE_A = (850.0, 1220.0, 2810.0, 3900.0)


def _static(*fs):
    return lambda t: fs


FORMANT_TRUTH = {name: _static(*[f for f, _bw in fs[:4]])
                 for name, _f0, fs in VOWELS}
for _stem in ("male_a_glide_100_200", "male_a_110_snr20", "male_a_110_snr10",
              "male_a_80_jitter2", "male_a_110_natural", "male_a_110_sr16k",
              "male_a_110_sr48k", "whisper_a"):
    FORMANT_TRUTH[_stem] = _static(*_MALE_A)
FORMANT_TRUTH["female_a_210_natural"] = _static(*_FEMALE_A)
# The CV onset glides F1 and F2 off a stop locus over the first 80 ms.
FORMANT_TRUTH["ba_110"] = lambda t: (
    250.0 + (700.0 - 250.0) * min(t / 0.08, 1.0),
    900.0 + (1220.0 - 900.0) * min(t / 0.08, 1.0),
    2600.0, 3500.0)
# The diphthong glides F1 and F2 across its whole 0.8 s.
FORMANT_TRUTH["ai_diphthong_120"] = lambda t: (
    700.0 + (300.0 - 700.0) * t / 0.8,
    1220.0 + (2300.0 - 1220.0) * t / 0.8,
    2600.0, 3500.0)

# Frames within this margin of the file edges are excluded from truth
# scoring: neither tracker has a full analysis window there.
TRUTH_MARGIN_S = 0.05

GATES = {
    "voicing_agreement_pct": 99.0,
    "f0_median_dev_hz": 2.0,
    "f1_rmse_hz": 150.0,
    "f2_rmse_hz": 250.0,
    "f3_rmse_hz": 350.0,
}

# Real-speech gates. The GATED real-speech tier is wavs/public/, built from
# redistributable corpora so a reader can rebuild and re-score it; the
# secondary tier wavs/real/ holds local-only participant recordings from 8
# speakers, too few to partition, and is reported rather than gated.
# Real speech has no ground truth, so gates measure agreement with Praat:
#   - voicing: >90% guards the calibrated operating point. See
#     docs/VALIDATION.md for what the public tier reaches against it and
#     for the divergence envelope the threshold is read against.
#   - formants: gated on the MEDIAN |dF| over frames both trackers call
#     voiced, at ~3% of nominal formant frequency (the classical formant
#     JND): 15/45/75 Hz for F1/F2/F3, observed 7/22/32. RMSE is reported
#     but not gated: its tail is pole-labeling swaps (F1/F2 merges) on
#     ~1% of frames, which median agreement rightly ignores -- the same
#     tail appears between Praat's own Burg and Split-Levinson formant
#     algorithms (intertracker.py), so it is a property of LPC formant
#     analysis, not of this implementation.
# Both sets of gates sit inside the divergence envelope that
# intertracker.py measures between established methods on this material.
REAL_GATES = {
    "voicing_agreement_pct": 90.0,
    "f0_median_dev_hz": 2.0,
    "f1_median_dev_hz": 15.0,
    "f2_median_dev_hz": 45.0,
    "f3_median_dev_hz": 75.0,
}


def read_csv(path):
    with open(path, newline="") as f:
        rows = list(csv.reader(f))
    header, data = rows[0], rows[1:]
    cols = {name: np.array([float(r[i]) for r in data]) for i, name in enumerate(header)}
    return cols


def match_frames(t_ref, t_got):
    """Indices (i_ref, i_got) of frames within MATCH_TOL_S of each other."""
    pairs = []
    j = 0
    for i, t in enumerate(t_ref):
        while j + 1 < len(t_got) and abs(t_got[j + 1] - t) < abs(t_got[j] - t):
            j += 1
        if len(t_got) and abs(t_got[j] - t) <= MATCH_TOL_S:
            pairs.append((i, j))
    return pairs


def match_coverage(t_ref, t_got, pairs):
    """How much of a comparison the frame matching actually kept.

    match_frames() drops any reference frame with no partner inside
    MATCH_TOL_S and reports nothing when it does, so a comparison can lose
    most of its frames and still print a plausible number. It also permits
    one `got` frame to answer for several `ref` frames, which double-counts
    that frame's deviation. Both go unnoticed without these counts.

    The failure mode this exists to catch: the two grids are offset by
    almost exactly MATCH_TOL_S, every ref frame is then equidistant from
    two got frames, and which ones survive is decided by floating-point
    rounding rather than by anything acoustic.
    """
    offsets = [abs(t_got[j] - t_ref[i]) for i, j in pairs]
    return {
        "n_ref": int(len(t_ref)),
        "n_got": int(len(t_got)),
        "n_matched": int(len(pairs)),
        "n_got_distinct": int(len({j for _, j in pairs})),
        "matched_pct": round(100.0 * len(pairs) / max(len(t_ref), 1), 3),
        "median_offset_ms": round(1000.0 * float(np.median(offsets)), 4)
                            if offsets else float("nan"),
        "max_offset_ms": round(1000.0 * float(np.max(offsets)), 4)
                         if offsets else float("nan"),
    }


def truth_scores(stem, times, f0):
    """Score one tracker's pitch track against the known synthesis F0.

    Returns (voiced_recall_pct, median_dev_hz, gross_err_pct) over frames
    away from the file edges, or None for files without a truth entry.
    Ground truth: every benchmark file is voiced throughout, so voiced
    recall is simply the voiced fraction; gross errors are voiced frames
    more than 20% off the true F0 (octave-class mistakes).
    """
    fn = TRUTH_F0.get(stem)
    if fn is None and stem not in TRUTH_UNVOICED:
        return None
    interior = (times >= TRUTH_MARGIN_S) & (times <= times.max() - TRUTH_MARGIN_S)
    t, f = times[interior], f0[interior]
    if not len(t):
        return None
    voiced = f > 0
    if stem in TRUTH_UNVOICED:
        # Column reads as "voiced %": for these files 0 is perfect.
        return 100.0 * np.mean(voiced), float("nan"), float("nan")
    recall = 100.0 * np.mean(voiced)
    truth = np.array([fn(x) for x in t[voiced]])
    devs = np.abs(f[voiced] - truth)
    med = float(np.median(devs)) if len(devs) else float("nan")
    gross = 100.0 * np.mean(devs / truth > 0.2) if len(devs) else float("nan")
    return recall, med, gross


# Cost of leaving a true pole with no reported pole assigned to it. Set far
# above any plausible frequency error so that the assignment only ever
# leaves a pole unmatched for want of a candidate.
MISSING_COST_HZ = 1e6


def assign_poles(reported, truth):
    """Order-preserving one-to-one assignment of true poles to reported ones.

    An LPC analysis asked for five formants below 5500 Hz places five poles
    whether or not the signal has five resonances, and a spurious pole takes
    the label of the resonance above it, pushing every higher label up by
    one. The labelled error that follows is not an estimation error: the
    pole is there, under another name. Both quantities are worth having, so
    this recovers the assignment and the labelled comparison is kept beside
    it.

    Formants are ordered, so the assignment must be monotone; that makes it
    a small dynamic program rather than a general matching problem. Cost is
    absolute frequency error. A true pole may also be left unmatched, at
    cost MISSING_COST_HZ, which is set far above any plausible error so
    that leaving a pole unmatched happens only when there are not enough
    reported poles to go round, never as a way of dropping a bad match. A
    match is therefore never discarded for being large, which would bias
    the corrected error downward.

    Returns a list of length len(truth) holding the index into `reported`
    assigned to each true pole, or None where none was.
    """
    n_t, n_r = len(truth), len(reported)
    INF = float("inf")
    # best[i][j]: cost of placing truth[i:] within reported[j:]
    best = [[INF] * (n_r + 1) for _ in range(n_t + 1)]
    move = [[None] * (n_r + 1) for _ in range(n_t + 1)]
    for j in range(n_r + 1):
        best[n_t][j] = 0.0
    for i in range(n_t - 1, -1, -1):
        for j in range(n_r, -1, -1):
            options = [(MISSING_COST_HZ + best[i + 1][j], "miss")]
            if j < n_r:
                options.append((abs(reported[j] - truth[i]) + best[i + 1][j + 1],
                                "take"))
                options.append((best[i][j + 1], "skip"))
            best[i][j], move[i][j] = min(options, key=lambda o: o[0])
    out, i, j = [], 0, 0
    while i < n_t:
        m = move[i][j]
        if m == "take":
            out.append(j)
            i += 1
            j += 1
        elif m == "skip":
            j += 1
        else:
            out.append(None)
            i += 1
    return out


def formant_truth_scores(stem, times, F, n_cols=3):
    """Score one tracker's formant track against the known synthesis poles.

    `F` is a dict k -> array of Hz on `times`, zero where the tracker
    reported nothing; `n_cols` is how many pole columns the tracker emitted.
    Frames within TRUTH_MARGIN_S of an edge are excluded, as for F0: neither
    tracker has a full analysis window there, and the amplitude ramp means
    the LPC fit is to a signal that is barely present.

    Two scorings are returned. `labelled` compares the tracker's Fk column
    with the k-th synthesis pole, which is what a user of the tracker reads.
    `assigned` compares each synthesis pole with whichever reported pole the
    monotone assignment gives it, which is what the tracker estimated. The
    gap between them is the cost of the label, not of the estimate, and
    `pct_label_shift` says how often the two disagree.

    Reported per formant: the count, the median absolute error, the RMSE and
    the signed median, because a systematic offset and a symmetric spread
    are different failures and the absolute error hides which one this is.
    """
    fn = FORMANT_TRUTH.get(stem)
    if fn is None or not len(times):
        return None
    interior = ((times >= TRUTH_MARGIN_S)
                & (times <= times.max() - TRUTH_MARGIN_S))
    t = times[interior]
    if not len(t):
        return None
    n_true = len(fn(t[0]))

    def summarise(err):
        return {
            "n": int(len(err)),
            "median_abs_err_hz": float(np.median(np.abs(err))),
            "rmse_hz": float(np.sqrt(np.mean(err ** 2))),
            "median_signed_err_hz": float(np.median(err)),
        }

    labelled_err = {k: [] for k in range(1, n_true + 1)}
    assigned_err = {k: [] for k in range(1, n_true + 1)}
    missing = {k: 0 for k in range(1, n_true + 1)}
    n_shift = n_unmatched = n_frames = 0
    for idx, x in enumerate(t):
        truth = fn(x)
        row = [F[k][interior][idx] for k in range(1, n_cols + 1)]
        for k in range(1, min(n_true, n_cols) + 1):
            if row[k - 1] > 0:
                labelled_err[k].append(row[k - 1] - truth[k - 1])
            else:
                missing[k] += 1
        present = [v for v in row if v > 0]
        pick = assign_poles(present, truth)
        n_frames += 1
        # A shifted label and a missing pole are different failures: the
        # first says the estimate is there under another name, the second
        # that the method did not report it at all.
        if any(j is not None and j != k for k, j in enumerate(pick)):
            n_shift += 1
        if any(j is None for j in pick):
            n_unmatched += 1
        for k, j in enumerate(pick, start=1):
            if j is not None:
                assigned_err[k].append(present[j] - truth[k - 1])

    out = {"pct_label_shift": (100.0 * n_shift / n_frames) if n_frames else
           float("nan"),
           "pct_pole_unmatched": (100.0 * n_unmatched / n_frames) if n_frames
           else float("nan"),
           "n_frames": n_frames, "labelled": {}, "assigned": {}}
    for k in range(1, n_true + 1):
        if labelled_err[k]:
            out["labelled"][f"F{k}"] = summarise(np.array(labelled_err[k]))
            out["labelled"][f"F{k}"]["n_missing"] = missing[k]
        if assigned_err[k]:
            out["assigned"][f"F{k}"] = summarise(np.array(assigned_err[k]))
    return out if out["labelled"] else None


def frame_voiced_mask(times, rp, gp):
    """For each formant-frame time, True iff the nearest pitch frame of
    BOTH trackers (within 6 ms) is voiced."""

    def voiced_at(track_t, track_v, t):
        i = int(np.searchsorted(track_t, t))
        i = min(max(i, 0), len(track_t) - 1)
        if i > 0 and abs(track_t[i - 1] - t) < abs(track_t[i] - t):
            i -= 1
        return bool(track_v[i]) if abs(track_t[i] - t) <= 0.006 else False

    rv, gv = rp["f0_hz"] > 0, gp["f0_hz"] > 0
    return np.array([
        voiced_at(rp["time_s"], rv, t) and voiced_at(gp["time_s"], gv, t)
        for t in times
    ])


def build_core_binary():
    subprocess.run(
        ["cargo", "build", "--release", "--example", "tracks_csv"],
        cwd=CORE,
        check=True,
        capture_output=True,
    )
    exe = "tracks_csv.exe" if os.name == "nt" else "tracks_csv"
    return CORE / "target" / "release" / "examples" / exe


def main(argv=None):
    import argparse

    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument(
        "--split", choices=["all", "calib", "eval"], default="all",
        help="restrict the GATED public tier to one half of a speaker-disjoint "
             "partition (see split.py). Parameters tuned against that tier "
             "must be swept on 'calib' and gated on 'eval'; 'all' reports the "
             "pooled figure and is not a held-out result. The secondary "
             "spontaneous tier is never partitioned: 8 speakers do not divide "
             "into halves that mean anything, which is why nothing is tuned "
             "against it and nothing is gated on it.")
    ap.add_argument(
        "--unvoiced-cost", type=float, default=None,
        help="override the pitch tracker's unvoiced candidate cost (CMNDF "
             "units) for this run, via OPENPHON_UNVOICED_COST. The sweep in "
             "sweep.py uses it; unset, the shipped default applies.")
    ap.add_argument(
        "--json", dest="json_out", default=None,
        help="write the aggregates, per-file rows and ground-truth rows to "
             "this path as JSON, so callers parse structure rather than text.")
    ap.add_argument(
        "--report-only", nargs="+", default=["real"], metavar="TIER[:METRIC]",
        help="score and print these gates but keep them out of the exit "
             "status. A bare tier name exempts that whole tier; "
             "'TIER:METRIC' exempts one gate of it, e.g. "
             "'public:voicing_agreement_pct', which is what CI uses so that "
             "a documented voicing shortfall does not hide a formant "
             "regression behind a permanently red build. Defaults to the "
             "secondary spontaneous tier, which carries 8 speakers and so "
             "cannot support a held-out gate. It is a reporting switch, "
             "never a threshold change.")
    ap.add_argument(
        "--dump-devs", dest="dump_devs", default=None,
        help="write per-recording absolute formant deviations (both-voiced "
             "frames) to DIR/<stem>.json, in the shape intertracker.py caches. "
             "Derived from participant audio: keep it out of the repository.")
    args = ap.parse_args(argv)

    exe = build_core_binary()
    outdir = Path(tempfile.mkdtemp(prefix="openphon_val_"))

    env = dict(os.environ)
    if args.unvoiced_cost is not None:
        env["OPENPHON_UNVOICED_COST"] = repr(float(args.unvoiced_cost))
        print(f"unvoiced candidate cost overridden to "
              f"{args.unvoiced_cost} CMNDF\n")

    # The operating point as the binary will actually apply it, asked of the
    # binary rather than assumed. Recording only the command-line override
    # left every artefact produced at the shipped default saying nothing
    # about which default that was.
    params = json.loads(subprocess.run(
        [str(exe), "--params"], check=True, capture_output=True,
        env=env, text=True).stdout)
    print(f"openphon operating point: {params}\n")

    if args.dump_devs:
        Path(args.dump_devs).mkdir(parents=True, exist_ok=True)

    def new_acc():
        return {
            "agree_num": 0,
            "agree_den": 0,
            # Directional disagreement: which tool voiced a frame the other
            # did not. Section 4.4 of the paper claims this is symmetric,
            # which is a claim about these two counts.
            "openphon_only": 0,
            "praat_only": 0,
            "both_voiced_n": 0,
            "f0_devs": [],
            "formant_dev": {1: [], 2: [], 3: []},
            "rows": [],
        }

    # Per-tier accumulators: "synth" (gated), "real" (gated when present),
    # "stress" (diagnostic only). Sub-accumulators keyed "real:<corpus>"
    # appear on demand and are diagnostic: the real tier draws on two
    # corpora recorded under different conditions, and pooling them hides
    # which one carries a result.
    acc = {tier: new_acc() for tier in ("synth", "real", "public", "stress")}

    # Per-file frame-matching coverage, recorded for every comparison so that
    # a figure computed on a fraction of the frames cannot pass unremarked.
    coverage = []

    # wavs/ is the gated synthetic benchmark; wavs/real/ holds local-only
    # real recordings (never committed) gated separately; wavs/stress/
    # holds deliberately hard material (heavy noise, jittered/creaky
    # phonation) that is reported for regression visibility but kept out
    # of the aggregate gates, whose thresholds are calibrated for
    # realistic recording conditions.
    gated = sorted(WAVS.glob("*.wav"))
    real = sorted((WAVS / "real").glob("*.wav"))
    public = sorted((WAVS / "public").glob("*.wav"))
    stress = sorted((WAVS / "stress").glob("*.wav"))
    if not gated:
        print("no benchmark WAVs; run synthesize.py first")
        return 1

    if args.split != "all":
        # Only the gated tier is partitioned. A parameter swept against it
        # has to be gated on speakers the sweep never saw; the secondary
        # spontaneous tier is neither swept against nor gated, so splitting
        # its 8 speakers would halve a reported figure for no purpose.
        from split import half_for, partition, speaker_of

        def restrict(wavs, label):
            if not wavs:
                return wavs
            assignment = partition([w.stem for w in wavs])
            kept = [w for w in wavs if half_for(w.stem, assignment) == args.split]
            speakers = sorted({speaker_of(w.stem) for w in kept})
            print(f"{label} restricted to '{args.split}' half: "
                  f"{len(kept)} recordings, {len(speakers)} speakers")
            return kept

        public = restrict(public, "public tier (gated)")
        print()

    # The public tier's manifest names each clip's corpus; without it the
    # tier's aggregate cannot be attributed.
    public_corpus = {}
    manifest = WAVS / "public" / "manifest.csv"
    if public and manifest.exists():
        with open(manifest, encoding="utf-8", newline="") as f:
            public_corpus = {r["stem"]: r["corpus"] for r in csv.DictReader(f)}

    truth_rows = []
    formant_truth_rows = []

    for wav in gated + real + public + stress:
        tier = "synth" if wav.parent == WAVS else wav.parent.name
        sub = "" if tier == "synth" else f"{tier}/"
        ref_pitch = REFS / f"{sub}{wav.stem}.pitch.csv"
        ref_formant = REFS / f"{sub}{wav.stem}.formant.csv"
        if not ref_pitch.exists() or not ref_formant.exists():
            print(f"skipping {wav.stem}: no references (run generate_references.py)")
            continue
        # "raw" = no bandwidth filter, label-compatible with Praat's raw poles.
        subprocess.run(
            [str(exe), str(wav), str(outdir), "raw"],
            check=True, capture_output=True, env=env,
        )

        # Both real tiers also accumulate per corpus, so a pooled figure can
        # be read back apart. For the private tier corpus_of() is the same
        # function the speaker-disjoint split uses; for the public tier the
        # manifest is authoritative, since that tier is assembled from two
        # corpora with different licences, varieties and recording chains.
        targets = [acc[tier]]
        corpus = None
        if tier == "real":
            from split import corpus_of
            corpus = corpus_of(wav.stem)
        elif tier == "public":
            corpus = public_corpus.get(wav.stem)
        if corpus:
            targets.append(acc.setdefault(f"{tier}:{corpus}", new_acc()))

        a = acc[tier]
        rp, gp = read_csv(ref_pitch), read_csv(outdir / f"{wav.stem}.pitch.csv")
        # Both tracks are sampled frame for frame onto one grid placed at
        # the centre of their phases, so neither is privileged and no frame
        # is dropped or reused. See gridalign.py for why nearest-frame
        # pairing cannot do this.
        dur = max(rp["time_s"][-1], gp["time_s"][-1]) + gridalign.STEP_S / 2
        tg, samp, pres, gstats = gridalign.align_tracks(
            {"praat": (rp["time_s"], rp["f0_hz"]),
             "openphon": (gp["time_s"], gp["f0_hz"])}, dur)
        keep = pres["praat"] & pres["openphon"]
        cov_pitch = {"n_ref": int(len(rp["time_s"])),
                     "n_got": int(len(gp["time_s"])),
                     "n_grid": int(len(tg)),
                     "n_matched": int(np.sum(keep)),
                     "matched_pct": round(
                         100.0 * np.sum(keep) / max(len(rp["time_s"]), 1), 3),
                     "offsets_ms": {k: v["median_offset_ms"]
                                    for k, v in gstats.items()}}
        ref_v = samp["praat"][keep]
        got_v = samp["openphon"][keep]
        both_voiced = (ref_v > 0) & (got_v > 0)
        agree = (ref_v > 0) == (got_v > 0)
        file_agree = 100.0 * np.mean(agree) if len(agree) else 0.0
        devs = np.abs(ref_v[both_voiced] - got_v[both_voiced])
        for t in targets:
            t["agree_num"] += int(np.sum(agree))
            t["agree_den"] += len(agree)
            t["openphon_only"] += int(np.sum((got_v > 0) & (ref_v <= 0)))
            t["praat_only"] += int(np.sum((ref_v > 0) & (got_v <= 0)))
            t["both_voiced_n"] += int(np.sum(both_voiced))
            t["f0_devs"].extend(devs)

        rf, gf = read_csv(ref_formant), read_csv(outdir / f"{wav.stem}.formant.csv")
        fdur = max(rf["time_s"][-1], gf["time_s"][-1]) + gridalign.STEP_S / 2
        forigin = gridalign.balanced_origin([rf["time_s"][0], gf["time_s"][0]])
        ftg = gridalign.canonical_grid(fdur, gridalign.STEP_S, forigin)
        fsamp, fpres, foff = {}, {}, {}
        for who, cols in (("praat", rf), ("openphon", gf)):
            fsamp[who], fpres[who] = {}, None
            for k in (1, 2, 3):
                s, p, off = gridalign.sample_onto(
                    cols["time_s"], cols[f"f{k}_hz"], ftg)
                fsamp[who][k] = s
                fpres[who] = p if fpres[who] is None else (fpres[who] & p)
            foff[who] = round(1000.0 * float(np.nanmedian(off)), 4)
        fkeep = fpres["praat"] & fpres["openphon"]
        cov_formant = {"n_ref": int(len(rf["time_s"])),
                       "n_got": int(len(gf["time_s"])),
                       "n_grid": int(len(ftg)),
                       "n_matched": int(np.sum(fkeep)),
                       "matched_pct": round(
                           100.0 * np.sum(fkeep) / max(len(rf["time_s"]), 1), 3),
                       "offsets_ms": foff}
        coverage.append({"stem": wav.stem, "tier": tier,
                         "pitch": cov_pitch, "formant": cov_formant})
        for what, cov in (("pitch", cov_pitch), ("formant", cov_formant)):
            if cov["matched_pct"] < 99.0:
                print(f"    {wav.stem} {what}: matched "
                      f"{cov['n_matched']}/{cov['n_ref']} "
                      f"({cov['matched_pct']:.1f}%), offsets "
                      f"{cov['offsets_ms']}")
        # On real continuous speech, formants are only compared on frames
        # BOTH trackers call voiced: outside speech the LPC poles both
        # tools report are arbitrary noise fits, and scoring them measures
        # nothing about formant analysis. Synthetic files are speech
        # throughout by construction, so no mask is applied there (and the
        # whispered file keeps its formant row, which is the point of it).
        if tier in ("real", "public"):
            voiced_mask = frame_voiced_mask(ftg[fkeep], rp, gp)
        else:
            voiced_mask = np.ones(int(np.sum(fkeep)), dtype=bool)
        rmse = {}
        per_file_dev = {}
        for k in (1, 2, 3):
            ref_f = fsamp["praat"][k][fkeep]
            got_f = fsamp["openphon"][k][fkeep]
            both = (ref_f > 0) & (got_f > 0) & voiced_mask
            dev = np.abs(ref_f[both] - got_f[both])
            for t in targets:
                t["formant_dev"][k].extend(dev)
            per_file_dev[f"F{k}"] = [round(float(x), 3) for x in dev]
            rmse[k] = np.sqrt(np.mean(dev**2)) if len(dev) else float("nan")
        for t in targets:
            t["rows"].append(
                (wav.stem, file_agree,
                 np.median(devs) if len(devs) else float("nan"),
                 rmse[1], rmse[2], rmse[3]))

        if args.dump_devs:
            # Same shape as intertracker_cache/<stem>.json, so the figure
            # script reads openphon and the established pairs identically.
            (Path(args.dump_devs) / f"{wav.stem}.json").write_text(json.dumps({
                "stem": wav.stem,
                "tier": tier,
                "unvoiced_cost": params["unvoiced_cost"],
                "operating_point": params,
                "pitch": {"openphon__vs__praat_ac": {
                    "n_frames": len(agree),
                    "n_agree": int(np.sum(agree)),
                    "devs": [round(float(x), 4) for x in devs],
                }},
                "formants": {"openphon__vs__praat_burg": per_file_dev},
            }))

        got_truth = truth_scores(wav.stem, gp["time_s"], gp["f0_hz"])
        ref_truth = truth_scores(wav.stem, rp["time_s"], rp["f0_hz"])
        if got_truth and ref_truth:
            truth_rows.append((wav.stem, *got_truth, *ref_truth))

        # Formant error against the synthesis poles, scored on each
        # tracker's OWN frames: the truth is a function of time, so no
        # alignment between the two trackers is needed and none is imposed.
        # This keeps the accuracy figures independent of the grid decisions
        # that the agreement figures turn on.
        n_got_cols = sum(1 for k in range(1, 6) if f"f{k}_hz" in gf)
        n_ref_cols = sum(1 for k in range(1, 6) if f"f{k}_hz" in rf)
        ft_got = formant_truth_scores(
            wav.stem, gf["time_s"],
            {k: gf[f"f{k}_hz"] for k in range(1, n_got_cols + 1)}, n_got_cols)
        ft_ref = formant_truth_scores(
            wav.stem, rf["time_s"],
            {k: rf[f"f{k}_hz"] for k in range(1, n_ref_cols + 1)}, n_ref_cols)
        if ft_got and ft_ref:
            formant_truth_rows.append(
                {"stem": wav.stem, "tier": tier,
                 "openphon": ft_got, "praat_burg": ft_ref})

    def print_rows(rows):
        print(f"{'file':<28}{'voice%':>8}{'medF0':>8}{'F1rmse':>9}{'F2rmse':>9}{'F3rmse':>9}")
        for name, va, md, r1, r2, r3 in rows:
            print(f"{name:<28}{va:>8.1f}{md:>8.2f}{r1:>9.1f}{r2:>9.1f}{r3:>9.1f}")

    print_rows(acc["synth"]["rows"])
    if acc["public"]["rows"]:
        print("\npublic real-speech tier (redistributable corpora, gated):")
        print_rows(acc["public"]["rows"])
    if acc["real"]["rows"]:
        print("\nsecondary spontaneous tier (local-only, reported not gated):")
        print_rows(acc["real"]["rows"])
    if acc["stress"]["rows"]:
        print("\nstress set (diagnostic, not gated):")
        print_rows(acc["stress"]["rows"])

    if truth_rows:
        print("\nvs ground truth (diagnostic, not gated; voiced recall % / "
              "median |dF0| Hz / gross-error %):")
        print(f"{'file':<28}{'openphon':>24}{'praat':>24}")
        for name, gr, gm, gg, rr, rm, rg in truth_rows:
            print(f"{name:<28}{gr:>10.1f}{gm:>8.2f}{gg:>6.1f}"
                  f"{rr:>10.1f}{rm:>8.2f}{rg:>6.1f}")

    formant_truth_pooled = {}
    if formant_truth_rows:
        print("\nformants vs the known synthesis poles, median |err| Hz "
              "(labelled column / after monotone pole assignment):")
        print(f"{'file':<26}{'':>3}{'openphon':>22}{'praat burg':>22}"
              f"{'shift%':>16}")
        for row in formant_truth_rows:
            for k in ("F1", "F2", "F3", "F4"):
                g = row["openphon"]["labelled"].get(k)
                r = row["praat_burg"]["labelled"].get(k)
                if not g or not r:
                    continue
                ga = row["openphon"]["assigned"].get(k, {})
                ra = row["praat_burg"]["assigned"].get(k, {})
                shift = (f"{row['openphon']['pct_label_shift']:.0f}/"
                         f"{row['praat_burg']['pct_label_shift']:.0f}"
                         if k == "F1" else "")
                print(f"{row['stem']:<26}{k:>3}"
                      f"{g['median_abs_err_hz']:>13.1f} /"
                      f"{ga.get('median_abs_err_hz', float('nan')):>7.1f}"
                      f"{r['median_abs_err_hz']:>13.1f} /"
                      f"{ra.get('median_abs_err_hz', float('nan')):>7.1f}"
                      f"{shift:>16}")

        def _pool(who, scoring, k):
            rows = [r[who][scoring][k] for r in formant_truth_rows
                    if k in r[who][scoring]]
            n = sum(r["n"] for r in rows)
            if not n:
                return None
            # RMSE pools exactly from per-file RMSE and counts; the median
            # does not, so what is pooled here is the frame-weighted mean of
            # per-file medians and it is named as such in the JSON.
            rmse = math.sqrt(sum(r["rmse_hz"] ** 2 * r["n"] for r in rows) / n)
            return {"n": n, "rmse_hz": rmse,
                    "mean_of_file_median_abs_err_hz":
                        sum(r["median_abs_err_hz"] * r["n"] for r in rows) / n,
                    "mean_of_file_median_signed_err_hz":
                        sum(r["median_signed_err_hz"] * r["n"] for r in rows) / n}

        print(f"\n{'pooled over the synthetic tier':<34}"
              f"{'n':>8}{'RMSE':>9}{'mean med':>10}{'bias':>9}")
        for who in ("openphon", "praat_burg"):
            for scoring in ("labelled", "assigned"):
                for k in ("F1", "F2", "F3", "F4"):
                    p = _pool(who, scoring, k)
                    if not p:
                        continue
                    formant_truth_pooled[f"{who}.{scoring}.{k}"] = p
                    print(f"{who + ' ' + scoring + ' ' + k:<34}{p['n']:>8}"
                          f"{p['rmse_hz']:>9.1f}"
                          f"{p['mean_of_file_median_abs_err_hz']:>10.1f}"
                          f"{p['mean_of_file_median_signed_err_hz']:>+9.1f}")
        shifts = [r["openphon"]["pct_label_shift"] for r in formant_truth_rows]
        shifts_p = [r["praat_burg"]["pct_label_shift"]
                    for r in formant_truth_rows]
        print(f"\nframes whose labels are not the identity assignment: "
              f"openphon {np.mean(shifts):.1f} %, "
              f"Praat burg {np.mean(shifts_p):.1f} % "
              f"(unweighted over {len(shifts)} files)")

    def aggregate(a):
        den = max(a["agree_den"], 1)
        # Raw agreement counts both-unvoiced frames, and on continuous
        # speech roughly two frames in five are inter-word silence, where
        # agreement is close to free: a tool that voiced nothing at all
        # would already score the both-unvoiced share. So report the 2x2
        # the raw figure hides, the two class-conditional rates, and a
        # chance-corrected coefficient, and keep raw agreement descriptive.
        tp = a["both_voiced_n"]                       # both call it voiced
        fp = a["openphon_only"]                       # openphon voiced only
        fn = a["praat_only"]                          # Praat voiced only
        tn = a["agree_num"] - tp                      # both call it unvoiced
        po = a["agree_num"] / den
        pe = ((tp + fn) * (tp + fp) + (tn + fp) * (tn + fn)) / (den * den)
        agg = {
            "voicing_agreement_pct": 100.0 * a["agree_num"] / den,
            "openphon_only_pct": 100.0 * a["openphon_only"] / den,
            "praat_only_pct": 100.0 * a["praat_only"] / den,
            "voicing_confusion": {"both_voiced": tp, "both_unvoiced": tn,
                                  "openphon_only": fp, "praat_only": fn},
            "praat_unvoiced_pct": 100.0 * (tn + fp) / den,
            "voiced_recall_pct": 100.0 * tp / max(tp + fn, 1),
            "voiced_precision_pct": 100.0 * tp / max(tp + fp, 1),
            "voicing_kappa": (po - pe) / (1 - pe) if pe < 1 else float("nan"),
            "n_frames": a["agree_den"],
            "n_recordings": len(a["rows"]),
            "f0_median_dev_hz": float(np.median(a["f0_devs"])) if a["f0_devs"] else float("nan"),
        }
        for k in (1, 2, 3):
            d = np.array(a["formant_dev"][k])
            agg[f"f{k}_rmse_hz"] = float(np.sqrt(np.mean(d**2))) if len(d) else float("nan")
            agg[f"f{k}_median_dev_hz"] = float(np.median(d)) if len(d) else float("nan")
            agg[f"f{k}_p75_dev_hz"] = float(np.percentile(d, 75)) if len(d) else float("nan")
            agg[f"f{k}_n"] = int(len(d))
        return agg

    # {tier: set of exempt metric names}; an empty set means the whole tier.
    exempt = {}
    for spec in args.report_only:
        tier_name, _, metric = spec.partition(":")
        if metric:
            exempt.setdefault(tier_name, set()).add(metric)
        else:
            exempt[tier_name] = set()

    def check(label, agg, gates, tier=None):
        print(f"\n{label}:")
        ok = True
        metrics = exempt.get(tier)
        for key, gate in gates.items():
            val = agg[key]
            if key == "voicing_agreement_pct":
                passed, rel = val > gate, ">"
            else:
                passed, rel = val < gate, "<"
            # A whole-tier exemption is an empty set; a per-metric one names
            # the metrics it covers.
            counted = not (metrics == set() or (metrics and key in metrics))
            ok &= bool(passed) or not counted
            note = "" if counted else "  (reported, not gated)"
            print(f"  {key:<26}{val:>9.2f}  (gate {rel} {gate})  "
                  f"{'PASS' if passed else 'FAIL'}{note}")
        return ok

    aggs = {"synth": aggregate(acc["synth"])}
    ok = check("aggregate (synthetic)", aggs["synth"], GATES)
    for tier, label in (("public", "public tier, gated"),
                        ("real", "secondary spontaneous tier")):
        if not acc[tier]["rows"]:
            continue
        agg = aggs[tier] = aggregate(acc[tier])
        whole_tier_exempt = exempt.get(tier) == set()
        ok &= check(f"aggregate ({label})"
                    + (", REPORTED NOT GATED" if whole_tier_exempt else ""),
                    agg, REAL_GATES, tier=tier)
        print("  (RMSE diagnostic, tail = pole-labeling swaps: "
              + "  ".join(f"F{k} {agg[f'f{k}_rmse_hz']:.0f} Hz" for k in (1, 2, 3))
              + ")")
        print(f"  (disagreement direction: openphon-only "
              f"{agg['openphon_only_pct']:.2f}% of frames, Praat-only "
              f"{agg['praat_only_pct']:.2f}%)")
        c = agg["voicing_confusion"]
        print(f"  (voicing 2x2: both-voiced {c['both_voiced']}, "
              f"both-unvoiced {c['both_unvoiced']}, openphon-only "
              f"{c['openphon_only']}, Praat-only {c['praat_only']}; "
              f"Praat calls {agg['praat_unvoiced_pct']:.1f}% of frames "
              f"unvoiced)")
        print(f"  (voiced recall {agg['voiced_recall_pct']:.2f}%, "
              f"precision {agg['voiced_precision_pct']:.2f}%, "
              f"kappa {agg['voicing_kappa']:.4f})")

    # Per-corpus rows: diagnostic, never gated. The corpora within a tier
    # differ in sample rate, task and recording condition, and a pooled
    # figure cannot say which of them a result comes from.
    per_corpus = {k: aggregate(v) for k, v in acc.items() if ":" in k}
    for tier, label in (("public", "public tier"),
                        ("real", "secondary spontaneous tier")):
        rows_c = {k: v for k, v in per_corpus.items() if k.startswith(f"{tier}:")}
        if len(rows_c) < 2:
            continue
        print(f"\n{label} by corpus (diagnostic, not gated):")
        print(f"  {'corpus':<18}{'recs':>6}{'voice%':>9}{'op-only%':>10}"
              f"{'pr-only%':>10}{'medF0':>8}{'medF1':>8}{'medF2':>8}{'medF3':>8}")
        for name, agg in sorted(rows_c.items()):
            print(f"  {name.split(':', 1)[1]:<18}{agg['n_recordings']:>6}"
                  f"{agg['voicing_agreement_pct']:>9.2f}"
                  f"{agg['openphon_only_pct']:>10.2f}{agg['praat_only_pct']:>10.2f}"
                  f"{agg['f0_median_dev_hz']:>8.2f}"
                  + "".join(f"{agg[f'f{k}_median_dev_hz']:>8.1f}" for k in (1, 2, 3)))
    aggs.update(per_corpus)

    print("\nRESULT:", "PASS" if ok else "FAIL")

    if args.json_out:
        Path(args.json_out).write_text(json.dumps({
            "split": args.split,
            "unvoiced_cost": params["unvoiced_cost"],
            "operating_point": params,
            "gates": {"synthetic": GATES, "real": REAL_GATES},
            "match_tol_s": MATCH_TOL_S,
            "coverage": coverage,
            "aggregates": aggs,
            "per_file": {
                tier: [dict(zip(
                    ("stem", "voicing_agreement_pct", "f0_median_dev_hz",
                     "f1_rmse_hz", "f2_rmse_hz", "f3_rmse_hz"), r))
                    for r in acc[tier]["rows"]]
                for tier in ("synth", "real", "public", "stress")
                if acc[tier]["rows"]
            },
            "ground_truth": [dict(zip(
                ("stem", "openphon_voiced_recall_pct", "openphon_median_dev_hz",
                 "openphon_gross_err_pct", "praat_voiced_recall_pct",
                 "praat_median_dev_hz", "praat_gross_err_pct"), r))
                for r in truth_rows],
            "formant_ground_truth": {
                "per_file": formant_truth_rows,
                "pooled": formant_truth_pooled,
                "margin_s": TRUTH_MARGIN_S,
            },
            "passed": bool(ok),
        }, indent=2, default=float))
        print("wrote", args.json_out)
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
