# openphon-cli

Command-line interface to the Rust analysis core used by openphon. It
reads WAV and TextGrid files and writes analysis tracks and annotation-based
measurements as CSV. Praat is not required to run the CLI.

```
cargo build --release          # binary at target/release/openphon
```

## Usage

```
openphon info        file.wav                       # format + analysis summary
openphon pitch       file.wav  > pitch.csv          # time_s,f0_hz (0 = unvoiced)
openphon intensity   file.wav  --out int.csv        # time_s,intensity_db
openphon formants    file.wav  --max 3 --raw        # time_s,f1_hz..fN_hz
openphon spectrogram file.wav  --max-freq 5000      # matrix, header row in Hz
openphon textgrid    file.TextGrid                  # tier summary
openphon textgrid    file.TextGrid --write out.TextGrid   # re-emit long form UTF-8
openphon measure     file.wav                       # per-interval measures over the
                                                    # sibling TextGrid's first interval
                                                    # tier: duration, mean/median F0,
                                                    # F1-F3 at midpoint, mean intensity
openphon measure     file.wav --tier phones --mid50 # aggregate over the middle 50%
openphon measure     file.wav --contour             # + F0/intensity at 20/50/80%
openphon measure     file.wav --tier phones --join words   # + containing word label
openphon measure     file.wav --tier bursts --rel-tier phones   # point tier: values at
                                                    # each mark + distances to the
                                                    # containing interval's boundaries
                                                    # (VOT-style)
openphon measure     corpus_dir/ --tier phones      # batch: every WAV with a sibling
                                                    # TextGrid; adds a `file` column
openphon measure     file.wav --ignore-pitch-edits  # measure the automatic F0 track
```

Run `openphon help` for all options. The analysis parameters and comparisons
with Praat are described in the [validation report](../docs/VALIDATION.md).
Pitch CSV uses the same column layout as the validation harness.

Notes:

- `measure` applies the app's manual pitch corrections from a sibling
  `<stem>.pitchedits.csv` and appends `f0_edited_frames` (intervals) or
  `f0_edited` (points). Without that file the columns are unchanged.
  Edits made at a different `--step`, `--floor` or `--ceiling` are an
  error; `--ignore-pitch-edits` measures the automatic track instead.

- `formants --max N` sets the model order (like Praat's "number of
  formants"), which changes the analysis, not just the number of columns.
- `--raw` disables the bandwidth-based candidate filter so output is
  label-compatible with Praat's `To Formant (burg)`.
