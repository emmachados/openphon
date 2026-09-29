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
lower rates); trim longer field sessions before importing. A TextGrid with
the same base name as the audio file is picked up automatically on
import; a TextGrid can also be imported later from the annotation menu.

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

The [validation report](VALIDATION.md) describes agreement with Praat at
specified settings. Public-speech voicing agreement remains below its
target; the report gives the numerical results and their limits.

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
  active tier: duration, mean/median F0, F1–F3 at the midpoint, mean
  intensity.

On Android and iOS both exports open the system share sheet; on desktop they
open a save dialog. The library screen's menu also offers **Export
measurements (library)**: one CSV over every recording that has a
TextGrid, with a leading `file` column, the same format as the CLI's
batch mode. Recordings are ordinary WAV files in the app's private
storage; library tiles offer rename and delete.

## Command line

The same analyses are scriptable with `openphon-cli` (see
[the CLI instructions](../cli/README.md)): track extraction to CSV, batch measurement recipes
over WAV + TextGrid pairs, and point-tier event listings.
