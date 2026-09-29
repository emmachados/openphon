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
python -m unittest test_release_check test_audio_identity test_sample_public test_fetch_public
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
reports the numerical outcome independently of CI policy. Public voicing
agreement currently measures 89.48285% against a target above 90%; this
metric retains the existing report-only exception. The other synthetic
and public track gates pass. No threshold or pitch parameter was changed
in the release rerun.

## Scoring and material

`compare.py` uses `gridalign.py` to sample both methods onto a common frame
grid. Default settings are a 10 ms step, F0 range 75–600 Hz, five formants,
a 5500 Hz ceiling, a 25 ms formant window and pre-emphasis from 50 Hz.
The release pitch unvoiced cost is 0.40. Formants are compared without the
application's 400 Hz bandwidth filter; the results describe this raw
candidate configuration. Public F0 and formant deviations use frames
both pitch trackers call voiced.

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
| Public evaluation | Voicing agreement | > 90%, report-only in CI |
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

`formant_grid.py` reports formant error against known synthesis poles.
`.github/workflows/validation.yml` runs core and CLI tests, synthetic,
voice-quality and spectral checks, and the isolated public release check.
The application build and integration workflow is separate, at
`.github/workflows/app.yml`.
