"""Formant estimation error against known poles, over a vowel grid and an
F0 sweep.

Design
------
Everything this suite reports about formants on real speech is one method
against another. Two methods agreeing closely says nothing about either
one's error: correlated errors look like agreement. The synthetic grid
built by `synthesize.py --grid` has poles that are known because they are
the synthesis filter's poles, so error is measurable. It crosses a vowel
grid with an F0 sweep, following Shadle, Nam & Whalen (2016) for the
known-target design and Chen, Whalen & Shadle (2019) for the F0 axis: LPC
fits an envelope to a spectrum sampled at harmonics, so as F0 rises the
harmonics thin out and the estimate is pulled toward whichever harmonic
sits nearest the pole.

Each cell is synthesised twice, with four resonances and with five, because
the standard analysis setting asks for five formants below 5500 Hz. In the
four-pole condition the analysis has one pole more than the signal has
resonances, and the spare pole takes a label, shifting every label above
it. Reporting both conditions separates estimation error from label error,
which the single figure a formant tracker prints cannot.

Two scorings per method, as in `compare.py`: `labelled`, which compares the
Fk column with the k-th pole and is what a user reads, and `assigned`,
which compares each pole with whichever reported pole a monotone assignment
gives it and is what the method estimated.

Usage:
    python synthesize.py --grid
    python formant_grid.py [--out formant_grid.json]
"""

import argparse
import json
import math
import subprocess
import tempfile
from pathlib import Path

import numpy as np
import parselmouth
from parselmouth.praat import call

from compare import assign_poles, build_core_binary, read_csv

HERE = Path(__file__).parent
GRID = HERE / "wavs" / "formantgrid"

TIME_STEP = 0.01
MAX_FORMANTS = 5
FORMANT_CEILING = 5500.0
WINDOW_LENGTH = 0.025
PRE_EMPHASIS = 50.0

# Frames within this margin of an edge are excluded: the fade is there and
# no analysis window is full.
MARGIN_S = 0.06


def praat_formants(snd, which):
    if which == "burg":
        fm = snd.to_formant_burg(
            time_step=TIME_STEP, max_number_of_formants=MAX_FORMANTS,
            maximum_formant=FORMANT_CEILING, window_length=WINDOW_LENGTH,
            pre_emphasis_from=PRE_EMPHASIS)
    elif which == "sl":
        fm = call(snd, "To Formant (sl)...", TIME_STEP, MAX_FORMANTS,
                  FORMANT_CEILING, WINDOW_LENGTH, PRE_EMPHASIS)
    else:
        fm = call(snd, "To Formant (robust)...", TIME_STEP, MAX_FORMANTS,
                  FORMANT_CEILING, WINDOW_LENGTH, PRE_EMPHASIS, 1.5, 5, 1e-6)
    t = np.asarray(fm.xs())
    F = np.zeros((len(t), MAX_FORMANTS))
    for k in range(1, MAX_FORMANTS + 1):
        vals = [fm.get_value_at_time(k, x) for x in t]
        F[:, k - 1] = [0.0 if (v is None or math.isnan(v)) else float(v)
                       for v in vals]
    return t, F


def score(t, F, poles):
    """Labelled and assignment-corrected error for one track, one cell."""
    interior = (t >= MARGIN_S) & (t <= t.max() - MARGIN_S)
    t, F = t[interior], F[interior]
    n_true = len(poles)
    lab = {k: [] for k in range(1, n_true + 1)}
    asg = {k: [] for k in range(1, n_true + 1)}
    n_shift = n_unmatched = n_scored = 0
    for row in F:
        present = [v for v in row if v > 0]
        for k in range(1, min(n_true, len(row)) + 1):
            if row[k - 1] > 0:
                lab[k].append(row[k - 1] - poles[k - 1])
        pick = assign_poles(present, poles)
        n_scored += 1
        # A shifted label and a missing pole are different failures and are
        # counted apart.
        if any(j is not None and j != k for k, j in enumerate(pick)):
            n_shift += 1
        if any(j is None for j in pick):
            n_unmatched += 1
        for k, j in enumerate(pick, start=1):
            if j is not None:
                asg[k].append(present[j] - poles[k - 1])

    def summ(errs):
        out = {}
        for k, e in errs.items():
            if not e:
                continue
            e = np.asarray(e)
            out[f"F{k}"] = {
                "n": int(len(e)),
                "median_abs_err_hz": float(np.median(np.abs(e))),
                "rmse_hz": float(np.sqrt(np.mean(e ** 2))),
                "median_signed_err_hz": float(np.median(e)),
            }
        return out

    return {"n_frames": n_scored,
            "pct_label_shift": 100.0 * n_shift / max(n_scored, 1),
            "pct_pole_unmatched": 100.0 * n_unmatched / max(n_scored, 1),
            "labelled": summ(lab), "assigned": summ(asg)}


def pooled(rows, who, scoring, k):
    """Pool one method's error over a set of cells.

    RMSE pools exactly from per-cell RMSE and counts. The median does not,
    so the pooled figure reported here is the RMSE and the frame-weighted
    mean of per-cell medians is named for what it is.
    """
    got = [r[who][scoring].get(k) for r in rows if k in r[who][scoring]]
    got = [g for g in got if g]
    n = sum(g["n"] for g in got)
    if not n:
        return None
    return {
        "n": n,
        "rmse_hz": math.sqrt(sum(g["rmse_hz"] ** 2 * g["n"] for g in got) / n),
        "mean_of_cell_median_abs_err_hz":
            sum(g["median_abs_err_hz"] * g["n"] for g in got) / n,
        "mean_of_cell_median_signed_err_hz":
            sum(g["median_signed_err_hz"] * g["n"] for g in got) / n,
    }


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default="formant_grid.json")
    ap.add_argument("--limit", type=int, default=0)
    args = ap.parse_args()

    truth = json.loads((GRID / "truth.json").read_text())
    cells = truth["cells"]
    if args.limit:
        cells = cells[:args.limit]

    exe = build_core_binary()
    outdir = Path(tempfile.mkdtemp(prefix="openphon_grid_"))
    methods = ["openphon", "praat_burg", "praat_sl", "praat_robust"]

    rows = []
    for i, cell in enumerate(cells, 1):
        wav = GRID / f"{cell['stem']}.wav"
        if not wav.exists():
            continue
        poles = [float(x) for x in cell["poles_hz"]]
        snd = parselmouth.Sound(str(wav))
        subprocess.run([str(exe), str(wav), str(outdir), "raw"],
                       check=True, capture_output=True)
        cols = read_csv(outdir / f"{wav.stem}.formant.csv")
        n_cols = sum(1 for k in range(1, 6) if f"f{k}_hz" in cols)
        F_op = np.column_stack([cols[f"f{k}_hz"] for k in range(1, n_cols + 1)])
        row = {"stem": cell["stem"], "f0_hz": cell["f0_hz"],
               "f1_hz": poles[0], "f2_hz": poles[1], "n_poles": len(poles),
               "openphon": score(cols["time_s"], F_op, poles)}
        for which in ("burg", "sl", "robust"):
            t, F = praat_formants(snd, which)
            row[f"praat_{which}"] = score(t, F, poles)
        rows.append(row)
        if i % 25 == 0:
            print(f"  {i}/{len(cells)}", flush=True)

    report = {"n_cells": len(rows), "margin_s": MARGIN_S,
              "settings": {"time_step_s": TIME_STEP,
                           "max_formants": MAX_FORMANTS,
                           "formant_ceiling_hz": FORMANT_CEILING,
                           "window_length_s": WINDOW_LENGTH,
                           "pre_emphasis_from_hz": PRE_EMPHASIS},
              "praat_version": parselmouth.PRAAT_VERSION,
              "per_cell": rows, "pooled": {}}

    def block(label, subset):
        if not subset:
            return
        report["pooled"][label] = {}
        for who in methods:
            for scoring in ("labelled", "assigned"):
                for k in ("F1", "F2", "F3"):
                    p = pooled(subset, who, scoring, k)
                    if p:
                        report["pooled"][label][f"{who}.{scoring}.{k}"] = p
        for field in ("pct_label_shift", "pct_pole_unmatched"):
            report["pooled"][label][field] = {
                who: float(np.mean([r[who][field] for r in subset]))
                for who in methods}

    block("all", rows)
    for n_poles in (4, 5):
        block(f"n_poles={n_poles}", [r for r in rows if r["n_poles"] == n_poles])
    for f0 in sorted({r["f0_hz"] for r in rows}):
        block(f"f0={int(f0)}", [r for r in rows if r["f0_hz"] == f0])
    for n_poles in (4, 5):
        for f0 in sorted({r["f0_hz"] for r in rows}):
            block(f"n_poles={n_poles},f0={int(f0)}",
                  [r for r in rows
                   if r["n_poles"] == n_poles and r["f0_hz"] == f0])

    # ------------------------------------------------------------- report
    print(f"\n=== formant grid: {len(rows)} cells ===")
    print("\nlabel shift and unmatched poles (% of frames):")
    for field in ("pct_label_shift", "pct_pole_unmatched"):
        print(f"  {field}")
        for label in ("n_poles=4", "n_poles=5"):
            if label in report["pooled"]:
                s = report["pooled"][label][field]
                print(f"    {label:<12}" + "".join(f"{m}={s[m]:.1f}  "
                                                   for m in methods))

    for scoring in ("labelled", "assigned"):
        print(f"\n{scoring} error, RMSE Hz, by pole count:")
        print(f"  {'':<14}" + "".join(f"{m:>16}" for m in methods))
        for label in ("n_poles=4", "n_poles=5"):
            for k in ("F1", "F2", "F3"):
                cells_ = report["pooled"].get(label, {})
                line = "".join(
                    f"{cells_.get(f'{m}.{scoring}.{k}', {}).get('rmse_hz', float('nan')):>16.1f}"
                    for m in methods)
                print(f"  {label + ' ' + k:<14}{line}")

    print("\nassigned error against F0, RMSE Hz (five-pole condition, the "
          "one whose pole count matches the analysis setting):")
    print(f"  {'F0':<6}" + "".join(f"{m + ' ' + k:>20}"
                                   for m in ("praat_burg", "openphon")
                                   for k in ("F1", "F2")))
    for f0 in sorted({r["f0_hz"] for r in rows}):
        lab = f"n_poles=5,f0={int(f0)}"
        c = report["pooled"].get(lab, {})
        line = "".join(
            f"{c.get(f'{m}.assigned.{k}', {}).get('rmse_hz', float('nan')):>20.1f}"
            for m in ("praat_burg", "openphon") for k in ("F1", "F2"))
        print(f"  {int(f0):<6}{line}")

    Path(args.out).write_text(json.dumps(report, indent=2))
    print(f"\nwrote {args.out}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
