# Validation report

openphon 0.1.0, openphon_core 0.1.0. Track and formant-grid evidence recomputed
on 14 October 2026 against Praat 6.1.38 through praat-parselmouth 0.4.7.
The formant algorithm recipe is revision 4, which preserves constant regions
during resampling and retains revision 3 root-set verification. Voice-quality and spectral
checks were also rerun on 14 October and reproduce the 30 September results.

The existing raw-track synthetic and public-speech gates pass, as do the
retained voice-quality and spectral checks. The additional analysis of the
shipped 400 Hz formant filter fails three comparisons against the same
raw-track thresholds: synthetic F2 and F3 RMSE, and public F3 median
deviation. Those comparisons are retained separately. A control applying the same
400 Hz selection to Praat passes the same numerical comparisons, with its
coverage and error tails reported. Neither diagnostic changes existing gates. Public-speech voicing agreement is 95.07410% against a target of more than 90%. The release of
28 September measured 89.48285% and reported that metric without enforcing
it; the pitch tracker change described under [Voicing agreement](#voicing-agreement)
raised it, and CI enforces every existing raw-track target.

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
specified by the committed partition. This rerun did not change the partition, selection cutoff or thresholds.
Preprocessing corrections were checked on synthetic signals and the 168-file
calibration subset before the candidate was frozen and scored once on the
evaluation subset. Root-set verification was subsequently checked at fixed
numerical tolerances on calibration and scored once on evaluation; all retained
scores and coverage reproduce revision 2. The partition does not establish that those speakers were
never inspected in earlier research.
Revision 4 followed the same order: 168 calibration recordings, a recorded
freeze decision, then one evaluation run on 192 recordings. All retained
calibration aggregates and evaluation per-file results, coverage and gates
are identical to revision 3.

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

## Current raw-track results

| Synthetic metric, 19 recordings | Result | Target | Result against target |
|---|---:|---:|---|
| Voicing agreement | 99.83810% | > 99% | Pass |
| Median absolute F0 deviation | 0.021 Hz | < 2 Hz | Pass |
| F1 RMSE | 7.988 Hz | < 150 Hz | Pass |
| F2 RMSE | 20.656 Hz | < 250 Hz | Pass |
| F3 RMSE | 67.567 Hz | < 350 Hz | Pass |

| Public evaluation metric, 192 recordings | Result | Target | Result against target |
|---|---:|---:|---|
| Voicing agreement | 95.07410% | > 90% | Pass |
| Median absolute F0 deviation | 0.469 Hz | < 2 Hz | Pass |
| Median absolute F1 deviation | 6.432 Hz | < 15 Hz | Pass |
| Median absolute F2 deviation | 17.072 Hz | < 45 Hz | Pass |
| Median absolute F3 deviation | 28.198 Hz | < 75 Hz | Pass |

The public score covers 96,490 frames: 56,869 mutually voiced, 34,868
mutually unvoiced, 1,749 voiced only by openphon and 3,004 voiced only by
Praat. Median deviations describe the centre of the error distribution.
Public F1/F2/F3 RMSE values are 119.254/267.934/350.423 Hz, so the median
results should not be read as bounds on individual frames. The formant preprocessing revision leaves the pitch track and mutually
voiced denominator unchanged. Raw formant median deviations before this
revision were 6.397/17.004/28.197 Hz; the corresponding current values are
6.432/17.072/28.198 Hz.

These are measurements of agreement with a specified Praat implementation.
They do not establish accuracy against physiological ground truth or
performance across other languages, recording conditions or parameter
settings.

## Formant preprocessing corrections

The revision changes three numerical operations in `core/src/formant.rs`.
The signal is centered before resampling, and each analysis frame is centered
before multiplication by the Gaussian window. Previously, windowing a constant
level and then removing its mean left a nonconstant signal. Burg analysis
could assign poles to that residual. Centering uses an anchor subtraction
followed by the residual mean, so constant samples become exactly zero.

The resampling sinc and Hann window now both expand with the downsampling
ratio: the half-width is `ceil(32 / min(1, output_rate / input_rate))` input
samples. The cutoff remains `0.95 * min(1, output_rate / input_rate)` relative
to input Nyquist. Each full kernel is normalized to unit sum; samples beyond
the recording are zero. The previous fixed 64-input-sample support lost
anti-aliasing performance as the input rate increased. This scaling follows
[Smith's description of windowed-sinc interpolation](https://www.dsprelated.com/freebooks/pasp/Windowed_Sinc_Interpolation.html).

The [native resampling check](../validation/release_resampling_check.json)
retains source hashes, the comparison driver and its output. Unit-amplitude
one-second tones were resampled to 11 kHz; RMS used the interior 0.1–0.9 s.
The ideal 4500 Hz RMS is 0.707107. The 5700 Hz tone lies above output Nyquist
and should be rejected.

| Input rate | 4500 Hz RMS, before | 4500 Hz RMS, revision 2 | 5700 Hz RMS, before | 5700 Hz RMS, revision 2 |
|---|---:|---:|---:|---:|
| 16 kHz | 0.705871 | 0.707498 | 0.004159 | 0.000950 |
| 44.1 kHz | 0.650641 | 0.707517 | 0.132990 | 0.000906 |
| 48 kHz | 0.635712 | 0.707529 | 0.147789 | 0.000874 |
| 96 kHz | 0.516185 | 0.707529 | 0.243904 | 0.000874 |
| 192 kHz | 0.436966 | 0.707537 | 0.298017 | 0.000854 |

A constant input of 0.1 previously produced formants in all 80 interior
frames at each rate; revision 2 produces none. Regression tests cover these
invariants and the existing synthetic vowel recovery cases.

Roots outside the unit circle now have bandwidth
`working_rate / pi * abs(ln(root_radius))`. This is equivalent to reflecting
their radius into the unit circle while preserving angle, as described in the
[published LPC conversion manual](https://www.fon.hum.uva.nl/praat/manual/LPC__To_Formant.html).
Previously, the code assigned every exterior root a zero bandwidth. Revision 2
left the root solver unchanged. Revision 3 checks its results as described below;
the checks do not establish accurate recovery of ill-conditioned roots.

The [calibration record](../validation/release_formant_calibration.json)
contains the frozen candidate decision, source hashes, calibration aggregates
and grid comparison before and after the change. No bandwidth cutoff, speaker
partition or numerical threshold was tuned. The corrections restore defined
signal-processing invariants. They do not establish a general reduction in
known-resonance error: shipped grid F3 RMSE changed from 247.706 to 251.651 Hz.

## Root-set verification

`checked_poly_roots` retains the Durand–Kerner initialization and 200-iteration
budget. It requires a maximum relative update below `1e-12`, finite arithmetic,
normalized polynomial residuals no greater than `64 * degree * f64::EPSILON`,
unique conjugate pairing within `8e-12`, and reconstructed polynomial
coefficient error no greater than `64 * degree² * f64::EPSILON`. These are
numerical checks, not acoustic error tolerances. An unresolved set produces
no formant candidates for that frame. The existing vector-returning API is
preserved; the checked API also returns a failure reason and diagnostics.

The [native root evidence](../validation/release_root_solver_check.json)
compiles the preserved preceding solver and current solver together. The
reproduction script embeds the preceding root function, so it requires no
uncommitted source snapshot. Separated and close-pair controls retain identical
roots, with maximum complex-plane errors of `2.81e-15` and `1.74e-13` against
the intended construction. The pathological five-pair 50–130 Hz cluster at
11 kHz previously returned six upper-half-plane roots. Its small normalized
individual residual, `2.49e-14`, coexists with coefficient-reconstruction
error `0.0248` and two unmatched nonreal roots. Revision 3 rejects it after
200 iterations.

The rejection is conservative: a wider 100–500 Hz cluster is also unresolved
under the step criterion, although the preceding solver's maximum error
against the intended roots was `2.65e-7`. Coefficient rounding matters for
clustered polynomials, and backward error does not bound individual root
error. These controls establish detection of unverified results, not a general
solution to difficult polynomial roots or high-F0 formant identity.

The [calibration and comparison record](../validation/release_root_calibration.json)
retains the fixed decision, source hashes and coverage. Raw, displayed and
matched-filter calibration aggregates on 168 files are identical to revision 2.
The frozen candidate was then scored once on 192 evaluation files. Every
recorded numerical result and coverage count in the release report is unchanged,
as are the 252-cell known-pole scores. No acoustic parameter, speaker partition
or target was adjusted. Revision 3 export metadata records the numerical
rejection policy, which revision 4 retains.

## Constant-region resampling

Subtracting the whole-recording mean converts an exact zero gap into a
nonzero constant when the recording has a nonzero mean. The preceding
resampler accumulated weighted samples directly. Floating-point summation
produced different residues at different output phases, so subsequent frame
centering left a nonzero signal and Burg analysis could report formants.

Revision 4 uses a local sample as an anchor whenever the complete resampling
kernel lies inside the recording. With normalized weights, it computes
`anchor + sum(weight * (sample - anchor))`; the generic path divides the
weighted difference sum by the kernel gain. Every difference in a constant
region is exactly zero. The filter coefficients, cutoff and support remain
unchanged. At recording boundaries, the preceding weighted accumulation and
zero extension are retained. This correction introduces no amplitude gate
and changes neither LPC order nor candidate selection.

The [native invariants](../validation/release_resampling_invariants.json)
pass all 82 checks. Forty constant inputs at eight rates from 8 to 192 kHz
retain exactly equal interior samples, including the generic 44,101 Hz path.
Eight pulse controls and eight PCM16 dropout fixtures produce no candidates
in 128 guarded frames per configuration, for both raw and default selection.
The active vowel attenuated by `1e-12` retains all 200 candidate slots in
50 frames per configuration; maximum frequency and bandwidth changes are
`9.55e-12` and `1.97e-11` Hz. These are numerical invariance checks, not
formant-accuracy estimates.

The [calibration record](../validation/release_resampling_calibration.json)
retains the decision and revision 3 comparison. All existing raw gates pass;
the 252-cell known-pole results are unchanged. The shipped selection's
previously reported errors remain. Measurement metadata records algorithm
revision 4 and the distinct interior and boundary accumulation rules.

## Shipped formant results

The release run invokes the same native example twice per recording. The raw
invocation disables bandwidth selection; the other uses
`FormantParams::default()`, including the unchanged 400 Hz cutoff. Frequencies
are sorted after rejection and assigned consecutive Fk slots. These slots do
not preserve the identities of rejected candidates.

The `displayed_formants` object in
[release_report.json](../validation/release_report.json) retains the original
comparison of each shipped Fk with the same raw Praat Fk. No pole assignment
is used in that comparison. Public analysis has 56,789 eligible formant
frames, fewer than the 56,869 mutually voiced pitch frames because the
formant windows have a different extent. Missing slots remain in the
coverage denominator; errors require two finite positive values.

| Shipped slot versus raw Praat, public evaluation | Paired frames | Missing shipped slots | Median absolute deviation | RMSE | p95 absolute deviation | p99 absolute deviation |
|---|---:|---:|---:|---:|---:|---:|
| F1 | 56,341 | 448 (0.789%) | 6.468 Hz | 467.055 Hz | 756.428 Hz | 2712.945 Hz |
| F2 | 53,091 | 3,698 (6.512%) | 19.967 Hz | 908.480 Hz | 2418.440 Hz | 3282.780 Hz |
| F3 | 42,853 | 13,936 (24.540%) | 113.199 Hz | 1054.795 Hz | 2211.594 Hz | 2811.853 Hz |

The F3 median exceeds the unchanged 75 Hz raw-track target. Synthetic shipped
F1/F2/F3 RMSE is 8.311/383.636/752.770 Hz, so F2/F3 exceed the 250/350 Hz
targets. These outcomes remain explicit diagnostics with
`enforced_in_ci: false`; `all_targets_passed` continues to mean raw gates.

The new `matched_filter_control` applies the identical inclusive 400 Hz
bandwidth cutoff to Praat candidates before frame alignment, then sorts and
compacts its survivors. This controls the difference in selection rules;
it is not a new Praat algorithm or a test against ground truth. Synthetic
F1/F2/F3 RMSE is 7.403/6.168/19.415 Hz. Public results are:

| Shipped slot versus filtered Praat | Paired frames | Median absolute deviation | RMSE | p95 absolute deviation |
|---|---:|---:|---:|---:|
| F1 | 55,965 | 6.031 Hz | 350.443 Hz | 73.177 Hz |
| F2 | 50,909 | 12.266 Hz | 517.096 Hz | 1279.128 Hz |
| F3 | 37,783 | 15.999 Hz | 465.367 Hz | 1289.959 Hz |

All six matched-filter comparisons meet the unchanged numerical targets.
Their paired sets are smaller because both methods now reject candidates.
The report therefore also compares both reference policies on exactly the
same frame triples. On the 37,783 common F3 frames, median deviation falls
from 58.487 Hz against raw Praat to 15.999 Hz against filtered Praat; the
reference slot is renumbered on 17,772 of those frames. This establishes a
selection-policy contribution without attributing the full 113.199-to-15.999 Hz
difference to that mechanism. Large error tails remain, and the control
does not establish the identities of formants in public speech.

## Known-resonance errors and selection limits

The [known-pole report](../validation/release_formant_grid.json) covers all
252 cells: 18 F1/F2 combinations, seven F0 values from 100 to 400 Hz, and
four- and five-pole conditions. Labelled Fk error is scored before a separate
monotone assignment diagnostic. Pooled quantiles use individual frame errors.

| Labelled error against synthesis poles, all 252 cells | Raw RMSE | Shipped RMSE | Shipped median absolute error | Shipped p95 absolute error |
|---|---:|---:|---:|---:|
| F1 | 58.617 Hz | 54.210 Hz | 27.876 Hz | 108.264 Hz |
| F2 | 686.377 Hz | 171.680 Hz | 23.782 Hz | 125.278 Hz |
| F3 | 655.145 Hz | 251.651 Hz | 25.437 Hz | 887.124 Hz |

Each F1–F3 result contains 9,072 interior frames with no missing displayed
slots. A nonempty slot is not proof that the corresponding resonance was
retained. The [candidate diagnosis](../validation/release_formant_diagnosis.json)
uses regions bounded by midpoints between known synthesis poles. The filter
empties the known-F2 region in 126 frames and the known-F3 region in 450
frames; a higher survivor then receives the lower slot number. These regions
use known synthesis truth and are a diagnostic, not a deployable assignment
rule.

A fixed pair of F0 = 400 Hz signals shows a limitation of changing the cutoff
alone. Retaining any candidate near known F3 = 2600 Hz in
`vg_f1300_f2900_f0400_p5` requires a cutoff of at least 785.314 Hz. The extra
candidate before known F2 in `child_i_400` has bandwidth 713.193 Hz and would
also pass that cutoff. A threshold depending only on bandwidth and F0 cannot
make both desired decisions for these two frames. The report records the
frequencies, bandwidths, synthesis poles and hashes; it does not infer a
replacement rule from evaluation speech.

## Fixed temporal selection experiment

The [declared protocol](../validation/temporal_formant_protocol.json) and
[synthetic screen](../validation/release_temporal_formant_check.json) evaluate
an offline three-track selector. The local cost is
`abs(Fk - reference_k) / 1000 + bandwidth / Fk`; adjacent observed values cost
`abs(log2(Fk_previous / Fk_current))`. The references are 550/1650/2750 Hz,
the adult-female vowel example in the
[published tracking manual](https://www.fon.hum.uva.nl/praat/manual/Formant__Track___.html).
They are an explicit frequency prior. The coefficients are its illustrative
unit costs, not claimed software defaults or fitted speaker parameters.
These retained experiment reports use revision 3 native candidates and
preserve that source hash. Their gap-presence findings below describe that
revision; revision 4 gap checks are reported separately above.

Each slot may be missing, at cost 2 per frame. Each observed/missing boundary
costs half the largest admissible octave jump. A bounded gap therefore cannot
avoid a direct jump more cheaply. Joint states preserve frequency order and
prevent candidate reuse; dynamic programming evaluates them without pruning.
The declared ablation sets all transition and gap-boundary costs to zero while
preserving local costs and missing states.

There are 32 new 1.6 s, 44.1 kHz fixtures at F0 = 100/200/300/400 Hz. Eight
continuous transitions connect resonances 350/2100/2900 Hz and
750/1300/2500 Hz in both directions, with 300 ms endpoint holds. Steady
endpoints, abrupt changes and 200 ms audio gaps are separate controls.
Truth is the instantaneous synthesis pole, not the peak of a finite-window
spectrum. Accuracy excludes recording edges and guarded gap/step boundaries;
gap presence and boundary diagnostics are retained separately.

| Labelled RMSE | Native default F1/F2/F3 | Temporal candidate F1/F2/F3 | No-continuity ablation F1/F2/F3 |
|---|---|---|---|
| Continuous transitions, 1,184 frames | 42.028/190.121/183.147 Hz | 42.028/42.355/37.943 Hz | 42.028/42.355/37.943 Hz |
| Existing steady grid, 9,072 frames | 54.210/171.680/251.651 Hz | 54.210/130.136/57.604 Hz | 54.210/130.136/57.604 Hz |
| Grid at F0 ≥ 300 Hz, 3,888 frames | 73.383/205.751/358.074 Hz | 73.383/195.949/83.606 Hz | 73.383/195.949/83.606 Hz |

All three methods have complete F1–F3 coverage in these groups. The fixed
candidate passes the declared synthetic screen, including paired-support
error and high-F0 controls. The ablation produces identical scores, so this
screen does not demonstrate a benefit from continuity. Its improvements are
reproducible with the local frequency and bandwidth costs alone. The grid's
F3 is fixed at 2600 Hz, close to the reference prior; this is a restriction on
the range tested. A subsequent scoring audit also counts observations lost
from the native baseline, because equal missing counts could conceal
exchanging difficult frames for easy ones. No baseline observations are lost
in the screen. No experimental selector is enabled in the application.

An [additional challenge](../validation/release_temporal_formant_challenge.json)
was designed after the first screen and uses the existing 19 synthetic signals
with broader resonance ranges. It is an explicit diagnostic extension, not an
independent preregistered holdout. The selector, costs and native source are
unchanged. Across these signals, native F1/F2/F3 RMSE is
56.890/21.383/33.269 Hz; the experimental values are
146.024/455.006/315.659 Hz. Both methods have complete coverage in the scored
regions. The temporal and no-continuity methods select exactly the same values
throughout all 1,834 native frames, including unscored edges.

The recorded `child_i_400` frame at 0.495 s illustrates the regression. Known
F1/F2/F3 are 370/3200/3700 Hz. Native default values are
414.205/3188.840/3610.673 Hz; the candidate selects
414.205/1959.665/3188.840 Hz. The reintroduced 1959.665 Hz candidate has
bandwidth 713.193 Hz. Its three-track local cost is 1.354, below 2.664 for the
native assignment, so the specified prior and relative-bandwidth cost prefer
the incorrect labels. `male_u_110` F2 RMSE rises from 22.200 to 1372.078 Hz.
The failure is therefore not confined to high F0.

Missing states also fail to establish appropriate absence in erased audio.
Across 64 guarded gap-core frames in the original screen, the candidate
returns F2 and F3 in all 64; native defaults return neither. These are presence
diagnostics, not frequency errors against a usable signal. Temporal and
no-continuity scores agree in the screen's accuracy regions, but some excluded
boundary and gap results differ. Production retains the existing per-frame
selection rule. The experiment establishes that this fixed candidate does
not support deployment; no cost or cutoff was adjusted to rescue it.
Revision 4 removes the resampling residue behind the gap candidates in these
fixtures. It does not change the selector's frequency prior or establish that
the failed experimental selector is suitable for deployment.

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
this report. Both checks were rerun on 14 October 2026 and reproduced those
files byte for byte.

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

The numerical comparison now exercises both raw LPC candidates and the
application's default 400 Hz bandwidth filter. The shipped-path results and
their limitations are reported above. This validates the native default
configuration, not every custom setting or every displayed frame. Changing
the ceiling, pitch range or other settings changes what is measured.

On 14 October, all 174 Flutter unit and widget tests passed and static
analysis reported no issues. The added tests cover unavailable measurements,
stale analysis results, settings validation and save failures, serialized
pitch-correction removal, export provenance, archive integrity and restore
rollback. These tests exercise application behavior separately from numerical
agreement with Praat.

Two new native integration tests passed on Android 16 ARM64 and an iPhone
17 Pro simulator running iOS 26.5. A backup containing custom settings,
annotations and pitch corrections restored without changing the WAV or
sidecar bytes or the resulting measurements, and preserved an existing
recording. A rendered analysis view kept export disabled until native tracks
completed; its CSV and metadata contained the expected labels, parameters
and checksums. The test intercepts the share method channel to inspect the
prepared files, so it does not verify the operating system's share interface.
The existing touch-based pitch-correction test also passed on both simulators,
including persistence and reapplication when the recording is reopened.
After the root-verification revision, six bridge tests and the export test
passed on each platform. A 44.1 kHz constant WAV produced no formants through
the compiled bridge, and the prepared export identified formant algorithm
revision 3 and its complete-root-set rejection policy. The full 174-test
Flutter suite and static analysis also passed on this revision. Native core
verification passed 96 unit tests and two property tests, with one existing
ignored test; all nine CLI tests and 72 Python tests passed.

Revision 4 passed all 184 Flutter tests and static analysis without issues.
Core verification passed 99 unit tests and two property tests, with one
existing ignored diagnostic; all nine CLI tests and 78 Python tests passed.
Backup regressions check malformed files, metadata discrepancies, source
changes after snapshotting and failed copy, read, write and close operations.
They verify preserved destination bytes, closed handles and the original
error when cleanup also fails.
Ten targeted native tests also passed on each of the Android 16 ARM64
emulator and iPhone 17 Pro simulator running iOS 26.5. Seven bridge tests
include absence of formants in silent gaps. Two backup tests verify a valid
restore and rejection of malformed content or mismatched WAV metadata by
the actual Rust parsers, with earlier archive bytes preserved. The rendered
export test verifies revision 4 metadata and completed native measurements.
Share-channel interception remains in use; these tests do not verify the
operating system's share interface or physical devices.

Earlier native checks cover the Rust bridge, analysis, malformed input,
TextGrid replacement, pitch correction, playback and storage preparation.
The [release record](RELEASE.md) preserves their build-specific results,
signed Android packaging checks, the iOS development archive and manual
iPhone and iPad observations. The current changes have not been packaged or
tested on a physical device. Physical Android capture and its picker/share
interface remain unverified; no App Store distribution build is available.

## Reproduction

From the repository root, using Python with praat-parselmouth 0.4.7,
NumPy and Rust/Cargo installed:

```sh
cargo build --locked --release --manifest-path core/Cargo.toml --example voice_report --example spectral_moments
cd validation
python fetch_public.py
python -m unittest discover -p 'test_*.py'
python release_check.py --out release_report.json
python synthesize.py --grid
python formant_grid.py --out release_formant_grid.json
python formant_diagnosis.py --out release_formant_diagnosis.json
python root_solver_check.py --out release_root_solver_check.json
python resampling_check.py --out release_resampling_invariants.json
python temporal_formant_check.py --out temporal_formant_check.json
python temporal_formant_challenge.py --screen temporal_formant_check.json --out temporal_formant_challenge.json
python voice_quality_check.py
python spectral_check.py
```

The temporal commands above score the current native source into separate
files. Reproducing the retained revision 3 experiment reports requires
commit `f463995`; their source hashes deliberately retain that history.

The release script enforces the existing raw-track targets in its exit
status; `all_targets_passed` and `checks` record those values. Shipped-path
comparisons remain explicit diagnostics. The saved 14 October run used
Python 3.14.7, NumPy 2.5.3 and rustc 1.97.1 on macOS arm64. The JSON records
the complete environment and source hashes. CI regenerates its own evidence
on Linux. Revision 3 passed the complete Linux validation workflow
([run 38539315362](https://github.com/emmachados/openphon/actions/runs/38539315362)).
The retained revision 4 figures above are the macOS results; its CI workflow
also enforces the new constant-preservation and silent-gap checks.

Historical research reports are outside the public release source selection.
Their scores, partitions and causal claims are not used as release evidence.
