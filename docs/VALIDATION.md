# Validation report

openphon 0.1.0, openphon_core 0.1.0. Recomputed on 28 September 2026
against Praat 6.1.38 through praat-parselmouth 0.4.7.

The current implementation passes the synthetic track, voice-quality and
spectral checks, and the public-speech F0 and formant checks. Public-speech
voicing agreement is 89.48285%, below the unchanged target of more than
90%. The existing CI exception reports that metric without failing the
workflow. A passing workflow therefore does not establish that every
numerical target has been met.

## Data and procedure

The machine-readable evidence is [release_report.json](../validation/release_report.json).
It contains per-recording results, frame coverage, numerical thresholds,
explicit pass/fail and CI-enforcement flags, tool versions, and SHA-256
hashes of the source files, public manifest and speaker partition.
Undefined diagnostic quantities are stored as JSON null.

[release_check.py](../validation/release_check.py) verified all 360 WAV
file hashes in the public manifest and the committed partition of 120 speakers.
The current hash-bit partition assigns 64 speakers, 192 recordings, to
evaluation and 56 speakers, 168 recordings, to calibration. This rule
assigns each speaker independently; adding another speaker cannot move
existing speakers between subsets. The evaluation subset is the one
specified by the committed partition. This rerun did not change the
partition, analysis parameters or thresholds, and it does not establish
that those speakers were never inspected in earlier research.

The script synthesized 19 test signals and two stress signals in a new
temporary directory, copied only manifest-listed public audio there,
and generated fresh Praat references. No private participant audio or
previously cached reference tracks entered this run. Missing or altered
public audio, partition drift and omitted evaluation recordings cause the
script to fail.

The public WAV archive preserves the original benchmark bytes and is
identified by a committed SHA-256. The downloader verifies the archive and
all 360 original WAV file hashes before release scoring. The audio is
redistributed with [source attribution and licences](../validation/PUBLIC_AUDIO_LICENSES.md).
The source reconstruction audit also records PCM identities independent of
RIFF metadata. All 261 CIEMPIESS PCM identities matched a fresh upstream
reconstruction locally; all 99 Common Voice identities differed with both
FFmpeg 8.0 and 8.1.2 on macOS ARM64. In `cv01_01`, 84 of 72,576 samples
differed by one 16-bit integer step. The cause is unestablished. CI uses the
preserved original WAV bytes, so this decoder difference changes neither
the benchmark nor its scoring rules.

Pitch defaults are a 10 ms step and a 75–600 Hz range. Formants use five
candidates, a 5500 Hz ceiling, a 25 ms window and pre-emphasis from 50 Hz.
The shipped pitch unvoiced cost remains 0.40. Scoring uses the common frame
grid in `validation/gridalign.py`; the report includes coverage diagnostics.
F0 deviations use frames both trackers call voiced. The public-speech
formant comparison also uses mutually voiced frames.

## Current track results

| Synthetic metric, 19 recordings | Result | Target | Result against target |
|---|---:|---:|---|
| Voicing agreement | 99.83810% | > 99% | Pass |
| Median absolute F0 deviation | 0.021 Hz | < 2 Hz | Pass |
| F1 RMSE | 8.138 Hz | < 150 Hz | Pass |
| F2 RMSE | 20.147 Hz | < 250 Hz | Pass |
| F3 RMSE | 68.226 Hz | < 350 Hz | Pass |

| Public evaluation metric, 192 recordings | Result | Target | Result against target |
|---|---:|---:|---|
| Voicing agreement | 89.48285% | > 90% | Fail, report-only in CI |
| Median absolute F0 deviation | 0.455 Hz | < 2 Hz | Pass |
| Median absolute F1 deviation | 6.299 Hz | < 15 Hz | Pass |
| Median absolute F2 deviation | 16.966 Hz | < 45 Hz | Pass |
| Median absolute F3 deviation | 28.045 Hz | < 75 Hz | Pass |

The public score covers 96,490 frames: 54,889 mutually voiced, 31,453
mutually unvoiced, 5,164 voiced only by openphon and 4,984 voiced only by
Praat. Median deviations describe the centre of the error distribution.
Public F1/F2/F3 RMSE values are 113.911/265.671/345.706 Hz, so the median
results should not be read as bounds on individual frames.

These are measurements of agreement with a specified Praat implementation.
They do not establish accuracy against physiological ground truth or
performance across other languages, recording conditions or parameter
settings. This rerun does not establish the cause of the voicing shortfall.
No historical divergence-envelope result is used to excuse it.

## Voice quality and spectral moments

The complete [voice-quality output](../validation/release_voice_quality.txt)
and [spectral output](../validation/release_spectral.txt) are retained with
this report.

`voice_quality_check.py` was rerun on eight synthesized sustained vowels.
Mean absolute deviations were 1.89892 dB for HNR, 0.00083 for local jitter,
0.00301 for local shimmer and 0.02747 Hz for median F0. The corresponding
targets are below 2 dB, 0.002, 0.010 and 2 Hz. HNR is evaluated on six files;
the existing `vq_clean_150` and `vq_clean_220` exclusions remain. These
aggregate passes do not imply that every individual file meets each limit.

`spectral_check.py` passed on six constructed spectra at power exponent 2.
Its mean deviations printed as 0.00000 at five decimal places. The limits
are relative deviation below 0.01 for centre of gravity and 0.02 for
standard deviation, absolute deviation below 0.05 for skewness, and
relative deviation below 0.05 for kurtosis.

## What is tested in the app

The track comparison requests raw LPC candidates. The application applies
a 400 Hz bandwidth filter by default, so these raw-track formant agreement
figures do not directly validate every displayed formant. Changing the
ceiling, pitch range or other settings also changes what is measured.

The application verification includes signed Android production packages,
an iOS development archive, 134 Flutter tests and nine native integration
tests on each of Android and iOS simulators. The native tests cover the Rust
bridge, analyses, TextGrid round trips and atomic replacement, playback,
invalid input and storage preparation. iOS backup-exclusion attributes are
read back by the native test. A synthetic WAV and TextGrid were exported
through the iPad share sheet, saved in local Files and imported back through
both native pickers; the annotation tier was displayed. Physical-device
microphone capture and Android's native picker/share UI remain unverified.
App Store export is blocked by developer-account distribution access.
See [release status](RELEASE.md) for packaging and submission limits.

## Reproduction

From the repository root, using Python with praat-parselmouth 0.4.7,
NumPy and Rust/Cargo installed:

```sh
cargo build --locked --release --manifest-path core/Cargo.toml --example voice_report --example spectral_moments
cd validation
python fetch_public.py
python -m unittest test_release_check test_audio_identity test_sample_public test_fetch_public
python release_check.py --out release_report.json
python voice_quality_check.py
python spectral_check.py
```

The release script preserves the existing public-voicing report-only
exception in its exit status. Inspect `all_targets_passed` and `checks`
in its JSON, not only the process exit code. The saved run used Python
3.13.15, NumPy 2.5.3 and rustc 1.97.1 on macOS arm64; the JSON records the
complete environment and source hashes. CI regenerates its own evidence
on Linux.

Historical research reports are outside the public release source selection.
Their scores, partitions and causal claims are not used as release evidence.
