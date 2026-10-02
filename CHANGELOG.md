# Changelog

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
