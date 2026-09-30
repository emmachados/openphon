# openphon

openphon is an open-source application for phonetic analysis on Android and
iOS. It records or imports WAV audio and displays waveforms, spectrograms,
pitch, intensity and formants. Recordings can be annotated with interval
and point tiers, saved as Praat TextGrids, and exported with measurements
in CSV format. Audio processing runs on the device.

## Installation

Download the APK from the [latest Android prerelease](https://github.com/emmachados/openphon/releases/tag/v0.1.0-rc.2).
Version 0.1.0 is a release candidate intended for testing. The accompanying
AAB is for Google Play distribution, not direct installation. An iOS
package is not yet available; iOS builds require Xcode and local signing.

See the [release notes](CHANGELOG.md) for changes and the
[release status](docs/RELEASE.md) for test coverage and outstanding checks.

## Using openphon

Record audio or import a WAV file, then select it in the library to open
the analysis view. Waveforms, spectrograms and analysis tracks share a
cursor and playback controls. Analysis settings are stored per recording.
The annotation menu provides TextGrid editing and measurement export.
The [user guide](docs/GUIDE.md) covers recording settings, supported WAV
formats, annotation and export.

The library is stored locally and excluded from automatic system backups.
Use **Back up library…** to export recordings and annotations before
removing the app or changing devices. Files exported to another app or
storage provider follow that provider's settings. See the
[privacy statement](docs/PRIVACY.md).

## Development

The mobile interface is written in Flutter; the analysis core is written
in Rust and connected through `flutter_rust_bridge`. Builds use Flutter
3.47.0 and Rust, plus Java 17 and the Android SDK for Android, or Xcode and
CocoaPods for iOS.

From a clone of this repository:

```sh
cd app
flutter pub get --enforce-lockfile
flutter run
```

The [application README](app/README.md) covers platform setup, tests,
bridge generation and release signing. [CONTRIBUTING.md](CONTRIBUTING.md)
covers issue reports, required checks and the rules for changes to the
analysis core.

| Directory | Contents |
|---|---|
| `app/` | Flutter application and native platform integration |
| `core/` | Rust signal analysis and TextGrid input/output |
| `cli/` | [Command-line tools](cli/README.md) for analysis and batch measurements |
| `validation/` | Test signals, public-audio benchmark and comparison scripts |
| `docs/` | User guide, validation results and release documentation |

## Validation

The analysis is compared with Praat 6.1.38 using synthesized signals and a
public speech corpus. The [validation report](docs/VALIDATION.md) describes
the data, parameters and error distributions, with
[machine-readable results](validation/release_report.json) and
[reproduction instructions](validation/README.md).

Public-speech voicing agreement is 95.07% against a target of more than
90%, and CI enforces every numerical target. The comparisons measure
agreement at the tested settings, not accuracy for every recording or
parameter choice. Where the pitch tracker errs, F0 can be corrected by
hand; see the [user guide](docs/GUIDE.md#correcting-pitch).

## Licence

The code is licensed under [Apache-2.0](LICENSE). Third-party dependencies
and the [public benchmark audio](validation/PUBLIC_AUDIO_LICENSES.md) have
their own licence notices.
