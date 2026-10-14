# Validation harness

This directory compares the Rust core with Praat. The current release evidence
is [release_report.json](release_report.json), described in
[the validation report](../docs/VALIDATION.md). Historical research JSON
files are not interchangeable with this release report.

## Reproducing the release check

Use Python with `praat-parselmouth==0.4.7` and NumPy installed, and
Rust/Cargo. From this directory:

```sh
python fetch_public.py
python -m unittest discover -p 'test_*.py'
python release_check.py --out release_report.json
cargo build --locked --release --manifest-path ../core/Cargo.toml --example voice_report --example spectral_moments
python voice_quality_check.py
python spectral_check.py
```

`release_check.py` verifies every original public WAV file hash and the committed speaker
partition before scoring. It synthesizes fresh test signals, copies only
manifest-listed public audio to a temporary directory and regenerates
Praat references there. Private participant speech and existing caches
are not read. Missing recordings, changed hashes, partition differences
and incomplete scoring are errors.

The report records source and manifest hashes, environment versions,
per-file results, coverage and every threshold. `all_targets_passed`
reports the existing raw-track outcome independently of CI policy. Every raw synthetic
and public track gate passes and is enforced; public voicing agreement
measures 95.07410% against a target above 90%. No threshold was changed.
The pitch tracker's level term and unvoiced cost changed on 30 September;
`voicing_diagnosis.py` reproduces the diagnosis and the calibration-subset
scores behind that change (`--subset calib`, `--unvoiced-cost`, `--env
OPENPHON_SILENCE_THRESHOLD=...`).

## Scoring and material

`compare.py` uses `gridalign.py` to sample both methods onto a common frame
grid. Default settings are a 10 ms step, F0 range 75–600 Hz, five formants,
a 5500 Hz ceiling, a 25 ms formant window and pre-emphasis from 50 Hz.
The release pitch unvoiced cost is 0.475, with a silence threshold of 0.03
of the recording's absolute peak. Existing gates compare raw formant candidates
without the application's 400 Hz bandwidth filter. A second invocation of
`tracks_csv` uses `FormantParams::default()` including that filter, and
`displayed_formants` reports both configurations on the same frame grid.
Public F0 and formant deviations use frames both pitch trackers call voiced.

The additional formant evidence keeps each labelled Fk slot. It reports the
number of eligible frames, each method's missing slots, paired comparisons,
median and signed median deviation, RMSE, p95, p99 and maximum absolute
deviation. Errors require two finite positive values; missingness is
reported against all eligible frames and is never converted to a 0 Hz error.
These conditional errors must therefore be read with their coverage.

Formant preprocessing revision 2 was checked on the 168-recording calibration
subset, then frozen and scored once on the 192-recording evaluation subset.
The calibration summary is [release_formant_calibration.json](release_formant_calibration.json).
The shipped configuration still fails the unchanged synthetic F2/F3 RMSE
targets and the public F3 median target when compared with raw Praat slots. These same-target comparisons are explicit
diagnostics and do not change existing gates or exit status. The
`all_targets_passed` field still means raw gates only;
`displayed_formants.all_same_targets_passed` reports the additional outcome.
See [the numerical report](../docs/VALIDATION.md#shipped-formant-results).
The new `matched_filter_control` filters Praat candidates at the same inclusive
400 Hz bandwidth limit before alignment and compacts their numbered slots.
All six matched-policy comparisons meet the existing targets. Its
`common_support_control` compares the two reference policies on identical
frame triples, so changes in paired coverage cannot explain that comparison.
Raw-reference results and missingness remain in the report. Neither the
bandwidth cutoff nor any threshold was tuned.

Revision 2 removes DC before resampling and before the Gaussian window, scales
the resampling kernel with the rate ratio, normalizes its gain, and computes
exterior-root bandwidth from the reciprocal radius. The
[native preprocessing evidence](release_resampling_check.json) records an
old/new source comparison. Revision 3 adds finite, convergence, residual,
conjugacy and complete-polynomial checks to the root solver. Unresolved sets
produce missing formants. The [native proof](release_root_solver_check.json)
includes an explicitly conservative rejection control; the
[calibration record](release_root_calibration.json) shows unchanged benchmark
scores and coverage after fixed checks and one evaluation run. Correction of
these operations does not imply general resonance-estimation improvement.
Revision 4 preserves exact constants inside the resampling kernel by
accumulating differences from a local sample. Recording-edge zero extension
is unchanged. The [native invariant checks](release_resampling_invariants.json)
cover silent gaps, constant regions and low-amplitude signals; the
[calibration record](release_resampling_calibration.json) retains the fixed
decision and comparison with revision 3. Reproduce the native checks with
`python resampling_check.py --out release_resampling_invariants.json` after
building the release core.
Develop candidates with `python release_check.py --split calib --out calibration.json`.
Only the selected subset is copied for reference generation and scoring;
all manifest hashes and the full speaker partition are still verified.

The synthetic tier contains 19 gated signals, including vowel sources,
transitions, a glide, different sampling rates, noise and a whispered
vowel. Two stress signals are reported separately and excluded from the
aggregate gates. Synthetic ground-truth diagnostics are distinct from
agreement with Praat. Consult the per-file report before generalizing
an aggregate result to a particular signal.

The public tier contains 360 recordings from 120 speakers. `fetch_public.py`
downloads the preserved WAV archive identified by `public_audio_archive.json`,
checks its SHA-256 and verifies all original file hashes against the committed
manifest before installing the files. The archive contains only those 360
public recordings, their manifest, provenance and
[licence notice](PUBLIC_AUDIO_LICENSES.md). CIEMPIESS Light retains CC BY-SA
4.0; Common Voice retains CC0. Audio is distributed as a separate release
asset and is absent from Git history.

The upstream reconstruction script, `sample_public.py --from-manifest`,
uses hash-verified CIEMPIESS Parquet shards at the original pinned revision
and the pinned Common Voice tarball. It requires FFmpeg and PyArrow 25.0.1.
This avoids the dynamic CIEMPIESS filter service, which returned repeated
HTTP 500/504 responses in CI. The reconstruction audit checks a second
`pcm_sha256` identity: little-endian `<IIIQ` sample rate, channel count,
sample width and frame count, followed by PCM bytes, excluding RIFF text
metadata. Those identities were derived after verifying the original
WAV file hashes. All 261 reconstructed CIEMPIESS clips matched their PCM
identities locally. All 99 reconstructed Common Voice clips differed,
with both FFmpeg 8.0 and 8.1.2 on macOS ARM64. In `cv01_01`, 84 of 72,576
samples differed by one 16-bit integer step. The cause has not been
established. The reconstruction audit fails on those differences.

CI and release scoring use the preserved WAV bytes and their original
file hashes. No decoded samples, selected clips, speaker partition,
analysis parameters or numerical thresholds were changed to obtain
reproducible release checks.

`split.py` assigns each speaker from one BLAKE2b hash bit. The current
committed partition has 56 calibration speakers (168 recordings) and
64 evaluation speakers (192 recordings). Adding speakers does not move
existing assignments. The earlier alternating hash-order partition is
retained as a historical option; its reports must not be combined with
results from the current partition. The release rerun uses the committed
evaluation subset and does not certify the history of research decisions
made with these data.

Generic `compare.py` and `generate_references.py` runs may read populated
local tiers. Use `release_check.py` for the isolated public release procedure.
Private research inputs and participant transcripts are outside the public
release source selection.

## Thresholds

| Tier | Metric | Target |
|---|---|---|
| Synthetic | Voicing agreement | > 99% |
| Synthetic | Median absolute F0 deviation | < 2 Hz |
| Synthetic | F1/F2/F3 RMSE | < 150/250/350 Hz |
| Public evaluation | Voicing agreement | > 90% |
| Public evaluation | Median absolute F0 deviation | < 2 Hz |
| Public evaluation | Median absolute F1/F2/F3 deviation | < 15/45/75 Hz |
| Voice quality | Mean absolute HNR deviation | < 2 dB, with two existing clean-signal exclusions |
| Voice quality | Mean absolute local jitter/shimmer deviation | < 0.002/0.010 |
| Voice quality | Mean absolute median-F0 deviation | < 2 Hz |
| Spectral moments | Mean relative centre-of-gravity/SD deviation | < 0.01/0.02 |
| Spectral moments | Mean absolute skewness deviation | < 0.05 |
| Spectral moments | Mean relative kurtosis deviation | < 0.05 |

`voice_quality_check.py` synthesizes eight sustained vowels and invokes
`core/examples/voice_report.rs`. HNR excludes `vq_clean_150` and
`vq_clean_220`; other voice-quality metrics use all eight. The spectral
script constructs six spectra and invokes `spectral_moments.rs` at power
exponent 2. Both scripts exit nonzero if an enforced aggregate check fails.

## Continuous integration

`formant_grid.py` reports raw and shipped formant error against known synthesis
poles across 252 cells. Labelled Fk error is primary; monotone pole assignment
is a separate diagnostic and preserves original column indices when counting
label shifts. Both reports retain fully missing slots, per-slot denominators
and error tails. Aggregate quantiles pool frame errors, not cell medians.
Missing grid recordings are errors. The retained run is
[release_formant_grid.json](release_formant_grid.json). Reproduce it with
`python synthesize.py --grid` and
`python formant_grid.py --out release_formant_grid.json`.
`formant_diagnosis.py` separately generates fresh signals and reports candidate
loss in regions defined by known synthesis poles. The fixed conflicting pair
of cutoff examples and source hashes are retained in
[release_formant_diagnosis.json](release_formant_diagnosis.json). It reads no
public speech. Reproduce it with
`python formant_diagnosis.py --out release_formant_diagnosis.json`.
`root_solver_check.py` compiles the preceding root function, embedded in the
script, and the current solver on fixed polynomials. Run it after building the
release core. `temporal_formant_check.py` evaluates a fixed offline selector
against 32 fresh transition/control fixtures and the 252-cell steady grid.
Its protocol precedes scoring and includes a no-continuity ablation. The
candidate passes the synthetic screen, but the ablation has identical scores
in the scored accuracy regions;
continuity itself has no demonstrated benefit in that screen. The experiment
does not change production selection. See the
[protocol](temporal_formant_protocol.json) and
[report](release_temporal_formant_check.json).
`temporal_formant_challenge.py` then applies the unchanged method to the existing
19 synthetic signals with broader resonance ranges. This additional check was
designed after the first screen and records that chronology. It finds large
labelled-error regressions without missing estimates; the selector remains
experimental. Its [report](release_temporal_formant_challenge.json) retains
frame traces and exact ablation differences. Both experiment commands return
success for a completed negative result; missing data or changed sources fail.
The retained temporal reports use revision 3 at commit `f463995`. Revision 4
corrects the silent-gap residue; use separate output names when running those
experiments on current source, because the historical gap counts differ.
`.github/workflows/validation.yml` runs core and CLI tests, synthetic,
voice-quality and spectral checks, and the isolated public release check.
The application build and integration workflow is separate, at
`.github/workflows/app.yml`.
