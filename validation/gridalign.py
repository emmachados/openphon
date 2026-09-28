"""One frame grid for every tracker, so comparisons are like-for-like.

The problem this replaces
-------------------------
Each analysis program centres its frames its own way. openphon's formant
frames start at win_n/2 / sr_work = 275/11000 = 0.025000 s exactly,
whatever the file duration. Praat centres its grid inside the signal, so
its first frame depends on duration and on window length. REAPER starts at
0.0. The offset between any two of them is therefore an arbitrary constant
per recording, uniform on the hop across a corpus.

Comparing two tracks by pairing each reference frame with the nearest
frame of the other track and dropping anything further away than a
tolerance fails badly when that offset happens to equal the tolerance:
every reference frame is then equidistant from two candidates, survival is
decided by floating-point rounding, and one candidate can answer for two
reference frames and have its deviation counted twice. Measured on this
repository's own synthetic tier before this module existed: 502 of 1816
formant frames survived, 27.6 %, every survivor at the maximum possible
misalignment of 5.000 ms, and in 18 of 19 files one openphon frame was
scored against two Praat frames.

What this does instead
----------------------
Define a grid from the recording alone, not from any tracker: frames at
step/2, 3*step/2, ... up to the duration. Sample every track onto it by
nearest source frame, never interpolating, so a voicing decision is
carried rather than invented and a formant value is never averaged across
a pole-label switch. Every method then lands on identical frames, so every
pairwise comparison has the same denominator, nothing is silently dropped,
and the residual per-frame offset is bounded by half a hop and reported
rather than hidden.

Sampling by nearest frame is itself a choice with a cost: it quantises
each track's timing to the grid. That cost is symmetric across methods,
bounded, and stated, which is what the previous rule was not.
"""

import numpy as np

STEP_S = 0.01


def canonical_grid(duration_s, step_s=STEP_S, origin_s=None):
    """Frame centres for a recording, independent of any tracker.

    `origin_s` is the phase of the first frame within the hop; it defaults
    to half a hop, which is symmetric about the signal. Pass the value from
    balanced_origin() to make the grid symmetric about the *methods* being
    compared instead.
    """
    if origin_s is None:
        origin_s = step_s / 2.0
    n = int(np.floor((duration_s - origin_s) / step_s)) + 1
    if n <= 0:
        return np.zeros(0)
    return origin_s + step_s * np.arange(n)


def balanced_origin(first_times, step_s=STEP_S):
    """Grid phase minimising the largest displacement any method suffers.

    A grid fixed independently of the methods can sit a full half hop from
    one of them while sitting on top of another, which is the asymmetry
    that makes a tool and the yardstick it is judged against incomparable:
    one is measured with slop and the other without. Placing the grid at
    the centre of the methods' phases equalises the cost instead.

    Phases live on a circle of circumference `step_s`, so the centre is the
    midpoint of the shortest arc containing them all. With a handful of
    methods it is cheapest to test each phase as an arc start and keep the
    tightest span.
    """
    phases = sorted(float(t) % step_s for t in first_times)
    if not phases:
        return step_s / 2.0
    best_span, best_start = None, phases[0]
    for i, start in enumerate(phases):
        # span of the arc that begins at this phase and wraps round
        span = (phases[i - 1] - start) % step_s if len(phases) > 1 else 0.0
        if best_span is None or span < best_span:
            best_span, best_start = span, start
    return (best_start + best_span / 2.0) % step_s


def sample_onto(t_src, values, t_grid, max_offset_s=None):
    """One-to-one sample of a uniform track onto a uniform grid.

    Nearest-frame sampling is not usable here. Both grids advance by the
    same step, so if their offset is close to half a step every grid point
    is equidistant from two source frames; the tie then falls to
    floating-point rounding and one source frame answers for two grid
    points. That is the failure this module exists to remove, and picking a
    different grid does not remove it, because any fixed grid can land
    halfway between some tracker's frames.

    Instead, align the two uniform grids by the single integer lag that
    minimises their offset, and pair frame for frame. The residual offset
    is then one constant per recording, bounded by half a step, identical
    for every frame, and reported. No frame is dropped except where one
    track does not reach, and no frame is ever used twice.

    Returns (sampled, present, offsets) as for a nearest-frame sampler,
    with `offsets` constant wherever present.
    """
    if max_offset_s is None:
        max_offset_s = STEP_S / 2.0
    values = np.asarray(values, dtype=float)
    n = len(t_grid)
    sampled = np.zeros(n, dtype=float)
    present = np.zeros(n, dtype=bool)
    offsets = np.full(n, np.nan)
    if not len(t_src) or not n:
        return sampled, present, offsets

    t_src = np.asarray(t_src, dtype=float)
    grid_step = float(np.median(np.diff(t_grid))) if n > 1 else STEP_S
    src_step = (float(np.median(np.diff(t_src))) if len(t_src) > 1
                else grid_step)
    if not np.isclose(src_step, grid_step, rtol=1e-3):
        raise ValueError(
            f"source step {src_step:.6f}s differs from grid step "
            f"{grid_step:.6f}s; frame-for-frame alignment does not apply")

    # t_src[s] ~= t_grid[g] requires s = g + (t_grid[0] - t_src[0]) / step.
    lag = int(round((t_grid[0] - t_src[0]) / grid_step))
    g = np.arange(n)
    s = g + lag
    inside = (s >= 0) & (s < len(t_src))
    off = np.abs(t_src[s[inside]] - t_grid[g[inside]])
    ok = off <= max_offset_s + 1e-9

    gi, si = g[inside][ok], s[inside][ok]
    sampled[gi] = values[si]
    present[gi] = True
    offsets[gi] = off[ok]
    return sampled, present, offsets


def align_tracks(tracks, duration_s, step_s=STEP_S, max_offset_s=None):
    """Sample a dict of {name: (times, values)} onto one shared grid.

    Returns (t_grid, sampled, present, stats) where sampled and present are
    dicts keyed as `tracks`, and stats carries the per-track offset summary
    that makes the alignment cost visible in the report.
    """
    origin = balanced_origin(
        [t[0] for t, _ in tracks.values() if len(t)], step_s)
    t_grid = canonical_grid(duration_s, step_s, origin)
    sampled, present, stats = {}, {}, {}
    for name, (t_src, values) in tracks.items():
        s, p, off = sample_onto(t_src, values, t_grid, max_offset_s)
        sampled[name] = s
        present[name] = p
        finite = off[np.isfinite(off)]
        stats[name] = {
            "n_src": int(len(t_src)),
            "n_grid": int(len(t_grid)),
            "n_present": int(np.sum(p)),
            "median_offset_ms": round(1000.0 * float(np.median(finite)), 4)
                                if len(finite) else float("nan"),
            "max_offset_ms": round(1000.0 * float(np.max(finite)), 4)
                             if len(finite) else float("nan"),
        }
    return t_grid, sampled, present, stats
