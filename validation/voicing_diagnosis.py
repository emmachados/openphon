"""Where do openphon and Praat disagree about voicing on the public tier?

Classifies every frame of the public recordings (both partition subsets,
reported separately) as both-voiced, both-unvoiced, openphon-only or
Praat-only, and describes the disagreeing frames by:

- relative level: frame RMS in dB below the recording's loudest frame;
- boundary distance: frames to the nearest voicing transition in either
  track (0 = the frame is itself next to a transition);
- run context: whether an openphon-only frame extends a Praat voiced run
  or forms an island, and the reverse for Praat-only frames;
- Praat's own pitch strength at the frame.

Tracks come from the shipped tracker (core example tracks_csv) and from
parselmouth at the release settings, aligned with gridalign. Nothing here
changes a parameter; `--unvoiced-cost` and `--env` exist only to let the
same diagnosis describe a candidate operating point.

    python voicing_diagnosis.py --out voicing_diagnosis.json
"""

import argparse
import csv
import json
import os
import subprocess
import tempfile
from pathlib import Path

import numpy as np
import parselmouth

import gridalign

HERE = Path(__file__).parent
CORE = HERE.parent / "core"
PUBLIC = HERE / "wavs" / "public"
PARTITION = HERE / "partition_public.json"

STEP = 0.01
FLOOR, CEILING = 75, 600


def build_tracks_csv():
    subprocess.run(["cargo", "build", "--locked", "--release", "--example",
                    "tracks_csv"], cwd=CORE, check=True,
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    return CORE / "target" / "release" / "examples" / "tracks_csv"


def openphon_pitch(exe, wav, tmp, env):
    subprocess.run([str(exe), str(wav), tmp, "raw"], check=True, env=env)
    rows = list(csv.DictReader(open(Path(tmp) / f"{wav.stem}.pitch.csv")))
    return (np.array([float(r["time_s"]) for r in rows]),
            np.array([float(r["f0_hz"]) for r in rows]))


def praat_pitch(snd):
    p = snd.to_pitch(time_step=STEP, pitch_floor=FLOOR, pitch_ceiling=CEILING)
    sel = p.selected_array
    return p.xs(), sel["frequency"], sel["strength"]


def frame_level_db(snd, times):
    """RMS over a 3/floor window (Praat's pitch window) at each time."""
    x = snd.values[0]
    sr = snd.sampling_frequency
    half = int(round(1.5 / FLOOR * sr))
    out = np.full(len(times), -np.inf)
    for i, t in enumerate(times):
        c = int(round(t * sr))
        seg = x[max(0, c - half):c + half]
        if len(seg):
            rms = float(np.sqrt(np.mean(seg * seg)))
            out[i] = 20 * np.log10(rms) if rms > 0 else -np.inf
    return out - np.max(out[np.isfinite(out)])


def transitions(v):
    """Indices i where v[i] != v[i-1]."""
    return np.flatnonzero(v[1:] != v[:-1]) + 1


def boundary_distance(op_v, pr_v):
    edges = np.union1d(transitions(op_v), transitions(pr_v))
    n = len(op_v)
    if not len(edges):
        return np.full(n, n)
    idx = np.arange(n)
    # A transition at i sits between frames i-1 and i: both are distance 0.
    d_left = np.min(np.abs(idx[:, None] - edges[None, :]), axis=1)
    d_right = np.min(np.abs(idx[:, None] - (edges[None, :] - 1)), axis=1)
    return np.minimum(d_left, d_right)


def run_context(only, other_voiced):
    """For each maximal run of `only` frames: does it touch a voiced frame
    of the other tracker (extension) or not (island)? Returns per-frame
    labels and the run lengths."""
    labels = np.array([""] * len(only), dtype=object)
    lengths = []
    i, n = 0, len(only)
    while i < n:
        if not only[i]:
            i += 1
            continue
        j = i
        while j < n and only[j]:
            j += 1
        touches = (i > 0 and other_voiced[i - 1]) or (j < n and other_voiced[j])
        labels[i:j] = "extension" if touches else "island"
        lengths.append(j - i)
        i = j
    return labels, lengths


LEVEL_BINS = [(-np.inf, -40), (-40, -30), (-30, -20), (-20, -10), (-10, 0.1)]


def summarise(frames):
    cls = np.array([f["class"] for f in frames])
    out = {"frames": len(frames)}
    for c in ("both_voiced", "both_unvoiced", "openphon_only", "praat_only"):
        out[c] = int(np.sum(cls == c))
    out["agreement_pct"] = 100 * (out["both_voiced"] + out["both_unvoiced"]) / len(frames)
    level = np.array([f["level_db"] for f in frames])
    bdist = np.array([f["boundary_distance"] for f in frames])
    strength = np.array([f["praat_strength"] for f in frames])
    ctx = np.array([f["context"] for f in frames])
    for c in ("openphon_only", "praat_only"):
        m = cls == c
        d = {}
        d["by_boundary_distance"] = {
            "0": int(np.sum(m & (bdist == 0))),
            "1": int(np.sum(m & (bdist == 1))),
            "2-4": int(np.sum(m & (bdist >= 2) & (bdist <= 4))),
            ">=5": int(np.sum(m & (bdist >= 5))),
        }
        d["by_level_db"] = {
            f"{lo}..{hi}": int(np.sum(m & (level >= lo) & (level < hi)))
            for lo, hi in LEVEL_BINS}
        d["by_context"] = {k: int(np.sum(m & (ctx == k)))
                           for k in ("extension", "island")}
        if c == "openphon_only":
            d["praat_strength_quartiles"] = [
                round(float(q), 3) for q in np.quantile(strength[m], [.25, .5, .75])
            ] if m.any() else []
        out[c + "_detail"] = d
    # Level distribution of agreed frames, as the denominator the bins need.
    for c in ("both_voiced", "both_unvoiced"):
        m = cls == c
        out[c + "_by_level_db"] = {
            f"{lo}..{hi}": int(np.sum(m & (level >= lo) & (level < hi)))
            for lo, hi in LEVEL_BINS}
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default="voicing_diagnosis.json")
    ap.add_argument("--unvoiced-cost", type=float)
    ap.add_argument("--env", action="append", default=[],
                    help="extra NAME=VALUE for the tracker binary")
    ap.add_argument("--frames-out", help="optional per-frame CSV")
    ap.add_argument("--subset", choices=("calib", "eval"),
                    help="score one partition subset only; candidate "
                         "operating points are chosen with --subset calib")
    args = ap.parse_args()

    env = dict(os.environ)
    if args.unvoiced_cost is not None:
        env["OPENPHON_UNVOICED_COST"] = repr(args.unvoiced_cost)
    for kv in args.env:
        k, v = kv.split("=", 1)
        env[k] = v

    partition = json.loads(PARTITION.read_text())
    manifest = list(csv.DictReader(open(PUBLIC / "manifest.csv")))
    exe = build_tracks_csv()

    frames_by = {"calib": [], "eval": []}
    per_file = {}
    with tempfile.TemporaryDirectory() as tmp:
        for row in manifest:
            stem = row["stem"]
            subset = partition[stem.split("_")[0]]
            if args.subset and subset != args.subset:
                continue
            wav = PUBLIC / f"{stem}.wav"
            snd = parselmouth.Sound(str(wav))
            ot, of0 = openphon_pitch(exe, wav, tmp, env)
            pt, pf0, pstr = praat_pitch(snd)
            grid, s, present, _ = gridalign.align_tracks(
                {"op": (ot, of0), "pr": (pt, pf0), "st": (pt, pstr)},
                snd.duration, STEP)
            both = present["op"] & present["pr"]
            g = grid[both]
            op_v = s["op"][both] > 0
            pr_v = s["pr"][both] > 0
            level = frame_level_db(snd, g)
            bdist = boundary_distance(op_v, pr_v)
            op_only, pr_only = op_v & ~pr_v, pr_v & ~op_v
            ctx_op, _ = run_context(op_only, pr_v)
            ctx_pr, _ = run_context(pr_only, op_v)
            ctx = np.where(op_only, ctx_op, np.where(pr_only, ctx_pr, ""))
            cls = np.where(op_v & pr_v, "both_voiced",
                  np.where(~op_v & ~pr_v, "both_unvoiced",
                  np.where(op_only, "openphon_only", "praat_only")))
            fr = [{"stem": stem, "t": float(g[i]), "class": str(cls[i]),
                   "level_db": float(level[i]),
                   "boundary_distance": int(bdist[i]),
                   "praat_strength": float(s["st"][both][i]),
                   "context": str(ctx[i])} for i in range(len(g))]
            frames_by[subset] += fr
            per_file[stem] = {
                "subset": subset,
                "agreement_pct": 100 * float(np.mean(op_v == pr_v)),
                "openphon_only": int(op_only.sum()),
                "praat_only": int(pr_only.sum()),
            }

    report = {
        "settings": {"unvoiced_cost": args.unvoiced_cost, "env": args.env,
                     "step_s": STEP, "floor_hz": FLOOR, "ceiling_hz": CEILING},
        **{sub: summarise(fr) for sub, fr in frames_by.items() if fr},
        "per_file": per_file,
    }
    Path(args.out).write_text(json.dumps(report, indent=1))
    if args.frames_out:
        with open(args.frames_out, "w", newline="") as f:
            first = next(fr[0] for fr in frames_by.values() if fr)
            w = csv.DictWriter(f, fieldnames=list(first) + ["subset"])
            w.writeheader()
            for sub, fr in frames_by.items():
                for r in fr:
                    w.writerow({**r, "subset": sub})
    for sub in ("calib", "eval"):
        if sub not in report:
            continue
        r = report[sub]
        print(f"{sub}: {r['frames']} frames, agreement {r['agreement_pct']:.3f}%, "
              f"openphon-only {r['openphon_only']}, praat-only {r['praat_only']}")


if __name__ == "__main__":
    main()
