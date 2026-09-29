# openphon

A phonetics application for phones and tablets. Record or import WAV
speech, inspect synchronized waveform and spectrogram views, measure F0,
intensity and formants, annotate tiers, and export WAV, TextGrid and
measurement files. The code is licensed under Apache-2.0.

## Status

Version 0.1.0 is a release candidate. Signed Android APK and App Bundle
builds pass. The native integration suite passes on Android and iOS
simulators, including Rust analysis, playback, TextGrid replacement and
storage preparation. An iOS development archive builds, but App Store
export requires an enrolled developer team with distribution access.
The owner has verified iPhone recording, playback, persistence, interruption
recovery and microphone permission recovery. Physical Android recording
and native import/sharing checks remain outstanding. Neither store
submission has been performed.
Download the [Android prerelease](https://github.com/emmachados/openphon/releases/tag/v0.1.0-rc.2).
See [release status](docs/RELEASE.md) and [build instructions](app/README.md).

The current [validation report](docs/VALIDATION.md) is backed by freshly
generated Praat references and a [machine-readable report](validation/release_report.json).
Synthetic, voice-quality, spectral, and public-speech F0/formant checks
pass. Public-speech voicing agreement is 89.48% on the committed evaluation
subset, below the unchanged target of more than 90%. CI retains an explicit
report-only exception for that metric. These results measure agreement
with Praat at the tested settings; they do not establish accuracy for
every recording or analysis setting.

## Storage and formats

Processing runs locally without a backend, accounts or telemetry. The
mobile library is excluded from system backups through Android backup
rules and iOS directory attributes. Exports use the system share sheet on
mobile and save dialogs on desktop. Exported copies follow the storage
and sharing choices made by the user. See the [privacy statement](docs/PRIVACY.md)
and [user guide](docs/GUIDE.md).

## Repository layout

| Path | Contents |
|---|---|
| `app/` | Flutter application for Android and iOS, with a Windows development target |
| `core/` | Rust DSP algorithms and TextGrid input/output |
| `cli/` | Command-line access to the core; see [CLI instructions](cli/README.md) |
| `validation/` | Benchmark generation, public-audio manifest and comparison scripts |
| `docs/` | User guide, privacy statement and validation report |

## Architecture

Flutter handles capture, storage, rendering and interaction. Rust handles
FFT/spectrogram analysis, RMS intensity, YIN F0 tracking, Burg LPC formants
and TextGrid parsing/serialization through `flutter_rust_bridge`. The
core uses published algorithm descriptions and documented parameters;
Praat is used by the separate validation harness to generate comparisons.
