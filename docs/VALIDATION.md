# Validation report

openphon 0.1.0, openphon_core 0.1.0. Recomputed on 30 September 2026
against Praat 6.1.38 through praat-parselmouth 0.4.7.

The current implementation passes every synthetic and public-speech track
check and the voice-quality and spectral checks. Public-speech voicing
agreement is 95.07410% against a target of more than 90%. The release of
28 September measured 89.48285% and reported that metric without enforcing
it; the pitch tracker change described under [Voicing agreement](#voicing-agreement)
raised it, and CI now enforces every target.

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
The pitch tracker's unvoiced cost is 0.475 and its silence threshold 0.03
of the recording's absolute peak (see [Voicing agreement](#voicing-agreement)).
Scoring uses the common frame
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
| Voicing agreement | 95.07410% | > 90% | Pass |
| Median absolute F0 deviation | 0.469 Hz | < 2 Hz | Pass |
| Median absolute F1 deviation | 6.397 Hz | < 15 Hz | Pass |
| Median absolute F2 deviation | 17.004 Hz | < 45 Hz | Pass |
| Median absolute F3 deviation | 28.197 Hz | < 75 Hz | Pass |

The public score covers 96,490 frames: 56,869 mutually voiced, 34,868
mutually unvoiced, 1,749 voiced only by openphon and 3,004 voiced only by
Praat. Median deviations describe the centre of the error distribution.
Public F1/F2/F3 RMSE values are 116.304/266.340/347.542 Hz, so the median
results should not be read as bounds on individual frames. The F0 and
formant medians rose slightly from the previous release (F0 0.455 Hz, F3
28.045 Hz) because the mutually voiced set over which they are computed
grew by 1,980 frames.

These are measurements of agreement with a specified Praat implementation.
They do not establish accuracy against physiological ground truth or
performance across other languages, recording conditions or parameter
settings.

## Voicing agreement

`validation/voicing_diagnosis.py` classifies every public frame by
agreement class and describes the disagreeing frames by level relative to
the recording's loudest frame, distance to the nearest voicing transition
and run context. At the previous operating point (unvoiced cost 0.40, no
level term) the evaluation subset had 5,164 frames voiced only by openphon
and 4,984 voiced only by Praat, from two separate mechanisms.

Of the openphon-only frames, 3,787 (73%) lay more than 30 dB below the
loudest frame; of all 22,486 frames that far down, Praat voiced 77.
Praat's pitch analysis lowers the cost of the unvoiced candidate as a
frame's local peak falls relative to the global peak (Boersma 1993,
silence threshold 0.03), and openphon had no level term. The tracker now
implements that term at the published default of 0.03; the value was
not calibrated.

The unvoiced cost of 0.40 had been calibrated without the level term, so
it was recalibrated on the 168 calibration recordings only. With the level
term, calibration agreement was 94.01, 94.34, 94.43 and 93.97% at 0.45,
0.475, 0.50 and 0.55. False voicing of the whispered synthetic vowel bounds
the value from above: 2.2% up to 0.50, then 3.4, 7.9 and 20.2% at 0.51,
0.53 and 0.55 (Praat: 5.7%). The shipped 0.475 is the point of the
0.475 to 0.50 plateau farthest from that rise, the rule that chose 0.40.
The evaluation subset was scored once, at that value. All synthetic gates
are unchanged, and the voice-quality figures below are identical to the
previous release.

The remaining disagreement lies at segment edges. Of the 4,753
disagreeing evaluation frames, 4,031 (85%) are adjacent to a voicing
transition in one of the tracks, and no openphon-only frame is more than
four frames from one. Praat-only edge frames outnumber openphon-only ones,
which is consistent with Praat's longer analysis window (three periods of
the floor, 40 ms at 75 Hz, against openphon's two periods, 26.7 ms); that
explanation has not been tested, because changing the window would also
change F0 estimates and requires its own evaluation.

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
an iOS development archive, 137 Flutter tests and nine native integration
tests on each of Android and iOS simulators for build 2. The native tests
cover the Rust bridge, analyses, TextGrid round trips and atomic
replacement, playback, invalid input and storage preparation. The pitch
correction change added 10 Flutter tests and one native test; the 147
Flutter tests and 10 native tests passed on an iPhone 17 Pro simulator
running iOS 26.5 on 30 September. The native suite was not rerun on
Android for that change. iOS backup-exclusion attributes are
read back by the native test. A synthetic WAV and TextGrid were exported
through the iPad share sheet, saved in local Files and imported back through
both native pickers; the annotation tier was displayed. Manual test reports
from 29 September cover iPhone recording, playback and persistence on
build 1, and interruption and microphone permission recovery on build 2.
The update preserved the test WAV byte for byte.
Physical Android capture and its native picker/share UI remain unverified.
An App Store distribution build is not yet available.
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

The release script enforces every track target in its exit status;
`all_targets_passed` and `checks` in its JSON record each value. The saved
run used Python 3.14.7, NumPy 2.5.3 and rustc 1.97.1 on macOS arm64; the
JSON records the complete environment and source hashes. CI regenerates its
own evidence on Linux. The last Linux run, at the previous tracker
([run 36534135577](https://github.com/emmachados/openphon/actions/runs/36534135577)),
measured public voicing agreement of 89.48492% against 89.48285% on macOS;
no Linux run exists yet for the current tracker.

Historical research reports are outside the public release source selection.
Their scores, partitions and causal claims are not used as release evidence.
