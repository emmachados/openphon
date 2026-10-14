# openphon user guide

openphon is a phonetics workbench for phones and tablets: record or
import speech, inspect waveform and spectrogram, track F0, intensity,
and formants, annotate on multiple tiers, and export Praat-compatible
TextGrids and measurement tables. Everything runs on the device;
nothing requires a network connection.

## Recording

Tap the microphone button on the library screen. The sample rate
(16/22.05/44.1/48 kHz) and the microphone DSP switches (auto gain,
echo cancellation, noise suppression) are set in Settings → Recording.
The DSP switches default to off: for acoustic measurement the signal
should reach the analysis unprocessed, and they should stay off unless
a recording is unusable without them.

An audio interruption can pause capture. The button then reads
**Paused · Stop**, and elapsed capture time stops advancing. Tap it to
save the portion already recorded; begin a new recording when ready.
Capture does not resume automatically after the interruption.

## Importing

The import button on the library screen accepts WAV files from the
system file picker: 16-, 24-, or 32-bit integer PCM and 32-bit float
(the format modern field recorders write), plain or extensible header.
Files at any of the supported sample rates are analyzed as-is; stereo
files are averaged to mono. Recordings load fully into memory, so files
are capped at about 35 minutes at 48 kHz (proportionally longer at
lower rates); trim longer field sessions before importing. Import a matching
TextGrid separately from the annotation menu. To transfer a complete library,
use the backup and restore commands described below.

## Analysis

Opening a recording shows the waveform, spectrogram, and analysis
tracks (F0, intensity, formants), time-aligned with a shared cursor and
playback. Which layers are drawn is chosen from the Layers button in
the transport bar; hidden layers are still computed. Analysis
parameters (F0 search range, formant ceiling, time steps, dynamic
range) are set per recording from the settings sheet; the Adult male /
Adult female / Child chips prefill the standard ranges. Defaults follow
Praat's (10 ms step, F0 75–600 Hz, 5 formants below 5500 Hz, 25 ms
formant window, pre-emphasis from 50 Hz).

The effective analysis defaults are saved when a recording is first opened.
Subsequent changes to the application's defaults do not change that recording.
Analysis failures appear with a Retry action. Measurement export is enabled
only after pitch, intensity and formants have finished successfully. A settings
change invalidates affected tracks; late results from earlier settings cannot
replace the current analysis.

The [validation report](VALIDATION.md) describes agreement with Praat at
specified settings, with the numerical results and their limits.

## Correcting pitch

The pitch tracker chooses one F0 value per 10 ms frame from up to four
candidate periodicities, or calls the frame unvoiced. Where it chooses
wrongly, typically an octave error or voicing in breath or noise, the
**Edit pitch** button (the line-chart icon in the transport bar) turns on
pitch editing. Zoomed in far enough that frames are at least 3 px apart,
each frame's candidates are drawn as rings.

- Tap a ring to use that candidate for its frame.
- Select a stretch, then use the edit bar to move its voiced frames an
  octave down or up, set its frames unvoiced, voice its unvoiced frames
  with their best candidate, or revert it to the automatic track. An
  octave move snaps to a candidate within a semitone of the target when
  one exists.
- Undo and redo (Ctrl+Z, Ctrl+Y on a keyboard) apply to pitch edits while
  editing is on.

Edited frames are marked with a square (or a cross at the floor when set
unvoiced) whenever the pitch layer is shown. Every consumer of the F0
track uses the corrected values: the readout, the measurement exports, the
voice report and the command line. In the voice report the corrected track
places the glottal pulses, as an edited Pitch object does in Praat, so
jitter, shimmer, the period count and the F0 summary follow the edits;
HNR does not depend on the track.

Edits are saved automatically beside the recording as
`<name>.pitchedits.csv`, a comment line holding the pitch settings
followed by `time_s,f0_hz` rows (0 = unvoiced). They belong to the time
step, floor and ceiling they were made at: after changing any of those,
the edits are kept on disk but not applied, and the edit bar offers to
restore the settings or discard the edits. Library backups include the
file; deleting a recording deletes it.

## Annotation

Create a TextGrid from the annotation menu, then add interval or point
tiers. On touch screens, boundaries are inserted, selected, and dragged
with a finger (a time readout follows the dragged boundary); labels are
edited by double-tap. All edits undo/redo.

Use **Save TextGrid** to save edits. Leaving a recording with unsaved
changes offers Save, Discard and Cancel. If saving fails, the editor stays
open. Edits made during an ongoing save remain marked as unsaved.

## Exporting

From the annotation menu:

- **Export TextGrid** writes a Praat text-format TextGrid.
- **Export measurements** writes a CSV with one row per interval of the
  active interval tier, or the first interval tier when a point tier is active:
  duration, mean/median F0, F1–F3 at the midpoint, mean
  intensity. Formants use the nearest frame inside the interval. Missing
  measurements are empty cells, including F0 in an interval without voiced
  frames. `f0_frames`, `voiced_f0_frames` and `intensity_frames` report the
  contributing frame counts. For an even number of voiced frames, the median
  averages the two middle values. When pitch edits apply, a final `f0_edited_frames` column
  counts the corrected frames in each interval.

Each measurement CSV is accompanied by a `.metadata.json` file containing the
analysis settings, source audio SHA-256 and bundled software version. An
individual export records the exact measured annotation tier and pitch
corrections, including edits still present in the editor. The bundled version
identifies the source version; it does not identify build-number overrides
supplied when packaging the application.

The `formant_analysis` object records the effective 25 ms window, 50 Hz
pre-emphasis, 400 Hz bandwidth cutoff and processing revision, alongside the
chosen ceiling, frame step and maximum formant count. The cutoff is a
candidate-selection heuristic: removing a candidate shifts the higher
survivors down one numbered slot. The [validation report](VALIDATION.md)
describes the measured consequences and the remaining high-F0 errors.

On Android and iOS both exports open the system share sheet; on desktop they
open a save dialog. The library screen's menu also offers **Export
measurements (library)**. Choose an interval tier by name; the command uses
each recording's saved settings and applies matching pitch corrections.
It saves pending edits in the open recording before reading the library.
The `file` column identifies the recording by its unique library-relative
path; display names remain in the metadata. A report lists every excluded
recording and its reason, including missing or ambiguous tiers, unreadable
files and incompatible pitch corrections. The JSON also includes the source
TextGrid and pitch-correction file checksums. Recordings without saved settings
use the current application defaults, which are recorded in the metadata.

## Backing up and restoring

**Back up library…** saves the open recording's pending edits and produces
`openphon_library.zip`. Its versioned `manifest.json` contains recording
names, creation times in UTC, format metadata and complete effective analysis
settings. The archive contains each WAV and its available TextGrid and pitch
corrections, with SHA-256 checksums. Recordings without saved settings receive
the current application defaults in the archive.

**Restore library backup…** accepts that ZIP and verifies every checksum,
audio header, annotation and pitch-correction file before adding recordings.
Restoration creates new library entries and retains existing recordings,
including entries with the same display name. A failed database update rolls
back the new entries and removes only the files created by that restore.
Earlier backups consisting of separate files are not ZIP archives; their WAVs
and TextGrids can still be imported separately.

## Command line

The same analyses are scriptable with `openphon-cli` (see
[the CLI instructions](../cli/README.md)): track extraction to CSV, batch measurement recipes
over WAV + TextGrid pairs, and point-tier event listings.
