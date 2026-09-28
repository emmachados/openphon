# Changelog

## 0.1.0 release candidate

The initial release includes local WAV recording and import, waveform and
spectrogram views, pitch, intensity and formant analysis, TextGrid editing,
and recording, annotation and measurement export.

Release preparation corrected mobile document import and sharing, including
iPad share-sheet positioning and paired WAV/TextGrid exports. Annotation
navigation now offers Save, Discard and Cancel. Saves replace TextGrids
atomically, retain the previous file on failure, and preserve edits made
while a save is running. Resizing between phone and tablet layouts retains
the current editor.

The mobile library is excluded from system backups. Android production
builds require a configured release key; unsigned verification builds need
an explicit opt-in. iOS includes an application privacy manifest.

The numerical validation report is regenerated from synthetic signals and
verified public speech. Public-speech voicing agreement is 89.48%, below
the unchanged target above 90%; this metric remains report-only in CI.
See [the validation report](docs/VALIDATION.md) for all results and scope.
