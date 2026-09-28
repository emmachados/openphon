# openphon-cli

Command-line companion to the openphon app: the same Praat-validated Rust
DSP core (`openphon_core`), scriptable from a shell. Useful for batch
pipelines (R, Python, shell loops) and Praat-free servers.

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
```

Run `openphon help` for all options. Defaults are identical to the app and
to the parameters validated against Praat in `validation/`; `pitch` output
is byte-identical to the validation harness's reference CSV layout.

Notes:

- `formants --max N` sets the model order (like Praat's "number of
  formants"), which changes the analysis, not just the number of columns.
- `--raw` disables the bandwidth-based candidate filter so output is
  label-compatible with Praat's `To Formant (burg)`.
