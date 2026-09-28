"""Generate Praat reference tracks for every WAV in wavs/ using parselmouth.

Writes refs/<name>.pitch.csv (time,f0 with 0 = unvoiced) and
refs/<name>.formant.csv (time,f1..f5 with 0 = missing), using the same
analysis parameters the openphon core uses by default.

F4 and F5 are written even though no gate reads them. Scoring a formant
track against known synthesis poles needs every pole the tracker reported,
not the three it labelled F1 to F3: an LPC fit that is asked for five
formants below 5500 Hz will place a pole where the signal has none, and
that pole takes a label from the ones below it. With only three columns the
resulting error is indistinguishable from an estimation error of several
hundred Hz.
"""

import csv
import math
from pathlib import Path

import parselmouth

HERE = Path(__file__).parent
WAVS = HERE / "wavs"
REFS = HERE / "refs"

TIME_STEP = 0.01
PITCH_FLOOR = 75
PITCH_CEILING = 600
MAX_FORMANTS = 5
FORMANT_CEILING = 5500
WINDOW_LENGTH = 0.025
PRE_EMPHASIS = 50

# Columns written per formant frame. MAX_FORMANTS poles are estimated, so
# all of them are reported.
N_FORMANT_COLS = MAX_FORMANTS


SUBDIRS = ("", "stress", "real", "public")


def main():
    REFS.mkdir(exist_ok=True)
    wavs = []
    for sub in SUBDIRS:
        (REFS / sub).mkdir(exist_ok=True)
        wavs += sorted((WAVS / sub).glob("*.wav"))
    for wav in wavs:
        snd = parselmouth.Sound(str(wav))

        pitch = snd.to_pitch(
            time_step=TIME_STEP,
            pitch_floor=PITCH_FLOOR,
            pitch_ceiling=PITCH_CEILING,
        )
        f0 = pitch.selected_array["frequency"]  # 0 where unvoiced
        sub = f"{wav.parent.name}/" if wav.parent != WAVS else ""
        with open(REFS / f"{sub}{wav.stem}.pitch.csv", "w", newline="") as f:
            w = csv.writer(f)
            w.writerow(["time_s", "f0_hz"])
            for t, v in zip(pitch.xs(), f0):
                w.writerow([f"{t:.6f}", f"{v:.3f}"])

        fm = snd.to_formant_burg(
            time_step=TIME_STEP,
            max_number_of_formants=MAX_FORMANTS,
            maximum_formant=FORMANT_CEILING,
            window_length=WINDOW_LENGTH,
            pre_emphasis_from=PRE_EMPHASIS,
        )
        with open(REFS / f"{sub}{wav.stem}.formant.csv", "w", newline="") as f:
            w = csv.writer(f)
            w.writerow(["time_s"] + [f"f{i}_hz" for i in range(1, N_FORMANT_COLS + 1)])
            for t in fm.xs():
                row = [f"{t:.6f}"]
                for i in range(1, N_FORMANT_COLS + 1):
                    v = fm.get_value_at_time(i, t)
                    row.append("0.000" if (v is None or math.isnan(v)) else f"{v:.3f}")
                w.writerow(row)
        print("refs for", wav.stem)


if __name__ == "__main__":
    main()
