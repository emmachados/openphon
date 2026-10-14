# Changelog

## Unreleased

Measurement exports wait for completed analyses and retain computation errors
with a retry action. Outdated analysis requests cannot replace tracks computed
with newer settings. Missing measurements are empty CSV cells; interval exports
report frame counts, average the middle pair for even-sized medians, and retain
multiline annotation labels. The default interval recipe uses the same columns
in the app and CLI. A midpoint formant requires a frame inside the measured
interval.

Analysis settings reject nonfinite or invalid values. Corrupt stored settings
and failed settings or pitch-correction saves are reported with recovery
actions. Pending saves finish before library exports, and removing pitch
corrections waits for earlier writes before deleting the sidecar.

Library measurements use saved per-recording settings and an explicitly chosen
tier name, and report all exclusions. Application measurement exports include
JSON metadata with analysis parameters, source checksums and the bundled
software version.
Backups are versioned ZIP archives containing complete analysis settings and
associated files. Restore verifies checksums and native file contents before
adding new entries, and preserves the existing library.

Validation now reports the default bandwidth-filtered formant output alongside
raw LPC candidates, including missingness and error tails. A 252-cell synthetic
grid compares both configurations with known resonance frequencies. A matched
reference control applies the same bandwidth selection to Praat and retains
the original raw-reference comparison and coverage separately.

Formant preprocessing now removes constant offsets before resampling and
windowing, scales the anti-aliasing filter with the sampling-rate ratio and
normalizes its gain. Exterior roots receive the bandwidth of their reflected
radius instead of zero. The 400 Hz selection cutoff and existing numerical
targets are unchanged. Calibration and evaluation retain the remaining
known-resonance errors; increasing the cutoff cannot resolve the documented
pair of conflicting selection cases. Measurement metadata identifies this
formant algorithm as revision 3 and records its effective parameters and
root rejection policy. Root sets must converge and pass finite, residual,
conjugacy and coefficient-reconstruction checks before producing formants.
Unresolved sets are missing estimates. Fixed numerical controls and unchanged
calibration/evaluation scores accompany the change.

An offline temporal-selection experiment adds 32 known-resonance transition
and control fixtures, explicit missing states, paired-support scoring and a
no-continuity ablation. It remains separate from application selection.

## 0.1.0-rc.4

The About screen asks researchers who use openphon to cite it and gives
the reference. Citation metadata are in `CITATION.cff`, and each release is
archived on Zenodo with a DOI. Analysis is unchanged from 0.1.0-rc.3.

## 0.1.0-rc.3

Pitch can be corrected by hand. In pitch edit mode each frame's candidates
are drawn and can be chosen by tapping; a selection can be moved an octave
down or up, set unvoiced or voiced, or reverted. Corrections are saved
beside the recording as `<name>.pitchedits.csv` and apply to the readout,
measurement exports, the voice report, library backups and the CLI
`measure` and `voice` commands, which add an `f0_edited_frames` column or
row when they apply. In the voice report the corrected track places the
glottal pulses, so jitter, shimmer and the period count follow the edits;
HNR does not. The app's voice report now uses the displayed F0 track, so
a selection's report follows the whole recording's track at the analysis
time step instead of tracking the selected stretch on its own.

The pitch tracker now lowers the cost of the unvoiced candidate for faint
frames, following Boersma (1993) with his default silence threshold of
0.03, and its unvoiced cost was recalibrated from 0.40 to 0.475 on the
calibration subset. Public-speech voicing agreement with Praat rose from
89.48% to 95.07%; the voicing target is now enforced in CI. F0 values on
recordings analysed with earlier versions can differ at voicing edges and
in faint stretches.

## 0.1.0-rc.2

Recording controls now reflect native audio interruptions. The button
shows **Paused · Stop** and the elapsed timer stops while capture is
paused. Stop saves the recorded portion, including after an interruption
during startup or a failed stop attempt that is retried.

## 0.1.0-rc.1

Initial Android release candidate, with WAV recording and import,
waveform and spectrogram views, pitch, intensity and formant analysis,
TextGrid editing, and CSV measurement export. iOS source is included.

Mobile file handling supports document-provider imports and paired
WAV/TextGrid sharing, including the iPad share sheet. Leaving an editor
with unsaved changes offers Save, Discard and Cancel. TextGrid saves are
atomic, and edits made during a save remain marked as unsaved. The editor
is retained when the layout changes between phone and tablet sizes.

The internal library is excluded from system backups. Android release
builds require signing credentials; iOS includes a privacy manifest.

See the [validation report](docs/VALIDATION.md) for numerical comparisons
with Praat. Public-speech voicing agreement is 89.48%, below its target of
more than 90%.
