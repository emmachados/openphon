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
import hashlib
import platform
import json
import math
import subprocess
import tempfile
from pathlib import Path

import numpy as np
import parselmouth
from parselmouth.praat import call

from compare import build_core_binary, read_csv
from formant_evidence import truth_errors, summarize_errors

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
    """Score original Fk slots and a separate assignment diagnostic."""
    interior = (t >= MARGIN_S) & (t <= t.max() - MARGIN_S)
    F = F[interior]
    truth = np.tile(poles, (len(F), 1))
    labelled, assigned, shifted, unmatched = truth_errors(F, truth)
    n = len(F)
    samples = {"labelled": {f"F{k + 1}": e for k, e in labelled.items()},
               "assigned": {f"F{k + 1}": e for k, e in assigned.items()}}
    return {"n_frames": n,
            "pct_label_shift": 100.0 * shifted / n if n else None,
            "pct_pole_unmatched": 100.0 * unmatched / n if n else None,
            **{name: {k: summarize_errors(e, n) for k, e in values.items()}
               for name, values in samples.items()},
            "_errors": samples}


def pooled(rows, who, scoring, k):
    """Pool frame errors exactly, including quantiles and missing slots."""
    cells = [r[who] for r in rows if k in r[who][scoring]]
    if not cells:
        return None
    errors = [e for cell in cells for e in cell["_errors"][scoring][k]]
    out = summarize_errors(errors, sum(cell["n_frames"] for cell in cells))
    present = [cell[scoring][k] for cell in cells if cell[scoring][k]["n"]]
    for metric in ("abs", "signed"):
        out[f"mean_of_cell_median_{metric}_err_hz"] = (
            sum(c[f"median_{metric}_err_hz"] * c["n"] for c in present) / out["n"]
            if out["n"] else None)
    return out


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
    methods = ["openphon", "openphon_shipped", "praat_burg", "praat_sl", "praat_robust"]
    params = json.loads(subprocess.check_output([str(exe), "--params"], text=True))
    if params["formant_max_bandwidth_hz"] != 400.0:
        raise ValueError("Shipped grid evidence requires the 400 Hz default")

    rows = []
    for i, cell in enumerate(cells, 1):
        wav = GRID / f"{cell['stem']}.wav"
        if not wav.exists():
            raise FileNotFoundError(f"Missing synthesis cell: {wav}")
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
        subprocess.run([str(exe), str(wav), str(outdir)],
                       check=True, capture_output=True)
        shipped = read_csv(outdir / f"{wav.stem}.formant.csv")
        F_shipped = np.column_stack([shipped[f"f{k}_hz"] for k in range(1, 6)])
        row["openphon_shipped"] = score(shipped["time_s"], F_shipped, poles)
        for which in ("burg", "sl", "robust"):
            t, F = praat_formants(snd, which)
            row[f"praat_{which}"] = score(t, F, poles)
        rows.append(row)
        if i % 25 == 0:
            print(f"  {i}/{len(cells)}", flush=True)

    sources = [HERE / name for name in ("formant_grid.py", "formant_evidence.py",
                                        "compare.py", "synthesize.py")]
    sources += [HERE.parent / "core/examples/tracks_csv.rs"]
    sources += sorted((HERE.parent / "core/src").glob("*.rs"))
    report = {"n_cells": len(rows), "n_expected_cells": len(cells), "margin_s": MARGIN_S,
              "scoring": "Labelled Fk slots against known poles; assignment is a separate diagnostic. "
                         "Missing slots retain their denominators. Errors and tails use present slots.",
              "configurations": {"openphon": {"max_bandwidth_hz": None},
                                 "openphon_shipped": {"max_bandwidth_hz": params["formant_max_bandwidth_hz"]}},
              "source_sha256": {str(p.relative_to(HERE.parent)): hashlib.sha256(p.read_bytes()).hexdigest()
                                for p in sources},
              "truth_sha256": hashlib.sha256((GRID / "truth.json").read_bytes()).hexdigest(),
              "environment": {"python": platform.python_version(), "numpy": np.__version__,
                              "parselmouth": parselmouth.__version__, "platform": platform.platform()},
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
                for k in ("F1", "F2", "F3", "F4", "F5"):
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

    for row in rows:
        for who in methods:
            row[who].pop("_errors")
    Path(args.out).write_text(json.dumps(report, indent=2, allow_nan=False) + "\n")
    print(f"\nwrote {args.out}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
