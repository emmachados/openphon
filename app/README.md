# Application build and development

The Flutter application calls the Rust core in `../core` through
`flutter_rust_bridge` and the glue crate in `rust/`. Cargokit builds the
native library during Flutter builds.

## Toolchain

The checked configuration uses Flutter 3.47.0, Dart 3.13.0, Rust stable
(local rustc 1.97.1), Java 17 for Android, and Xcode with CocoaPods for iOS.
The current generated Android minimum is API 24; the iOS deployment
minimum is 15.0. Dependency versions are recorded in `pubspec.lock`,
`ios/Podfile.lock` and the Xcode Swift package lockfiles.

The Rust plugin currently uses CocoaPods while other iOS plugins use
Swift Package Manager. Flutter warns that this fallback will be removed
in a future version. The pinned toolchain builds successfully with it.

## Commands

Run these from `app/`, with Flutter and Cargo on PATH and the appropriate
platform SDK installed:

```sh
flutter pub get --enforce-lockfile
flutter analyze --no-pub
flutter test --no-pub
flutter build apk --debug --target-platform android-arm64 --no-pub
flutter build ios --simulator --debug --no-pub
flutter devices
flutter test integration_test --no-pub --no-uninstall -d <device-id>
```

For Android, set `JAVA_HOME` to a Java 17 installation. Select a device
identifier from `flutter devices`; do not assume a particular simulator
or connected phone. Native integration tests require a supported target.
The iOS simulator suite covers bridge calls, DSP, TextGrid I/O, playback
and backup-exclusion readback.

`--no-uninstall` retains the app data after native tests. Flutter 3.47's
`flutter test` otherwise uninstalls the app by default; use the flag on a
device that contains recordings. This command requires a USB connection
for a physical iPhone because its test configuration disables publication
of the debugging port. Installing or launching the signed release archive
over the local network is a separate operation.

After editing `rust/src/api/*.rs`, regenerate the bridge with
`flutter_rust_bridge_codegen generate` using version 2.12.x. After changing
the Drift schema, run `dart run build_runner build --delete-conflicting-outputs`.
Core and CLI tests run with `cargo test --locked --manifest-path
../core/Cargo.toml` and the corresponding `../cli/Cargo.toml` path. See
[validation instructions](../validation/README.md) for numerical checks.

## Distribution and verification scope

`.github/workflows/app.yml` checks analysis, Flutter tests, unsigned Android
production packaging, iOS simulator integration tests and unsigned iOS
production compilation. The unsigned CI artifacts are verification outputs.
They cannot be distributed as signed installation packages.

Local verification has passed 137 Flutter tests and nine native integration
tests on each mobile platform. Native iPad WAV and TextGrid pickers, paired
sharing, saving to Files, reimport and annotation display have been checked.
Physical microphone capture and Android's native picker/share interface
still require device checks. See [release status](../docs/RELEASE.md).

### Android signing

Copy `android/key.properties.example` to a private location outside this
repository and supply the existing keystore and its credentials. Relative
keystore paths resolve beside that properties file. Build with:

```sh
export OPENPHON_ANDROID_KEY_PROPERTIES=/absolute/private/path/key.properties
flutter build appbundle --release
flutter build apk --release
```

The fallback properties location is the ignored `android/key.properties`.
With Flutter 3.47, omit `--no-pub` from Android release builds. That flag
skips regenerating the plugin registrant and can retain a test-only plugin
reference after `flutter pub get` or a debug build. CI first enforces the
lockfile and checks that the release build leaves it unchanged.

Release tasks fail when signing material is absent or incomplete. There is
no debug-key fallback. `OPENPHON_UNSIGNED_RELEASE=1` explicitly permits an
unsigned build for CI packaging checks. Verify a signed APK with Android
Build Tools `apksigner verify --verbose --print-certs` before distributing it.
Never commit signing files, passwords or a signing-key archive.

### iOS distribution

An active Apple Developer Program membership and access to App Store
Connect distribution are required. Select the enrolled team in Xcode,
then archive the Runner scheme with automatic signing. A development-signed
archive is insufficient for TestFlight or App Store distribution. Keep
certificates and provisioning profiles outside the source repository.

## Storage and platform notes

`libraryRoot()` in `lib/src/audio/recorder_service.dart` locates the
application-support directory. Mobile backup exclusions are described in
[the privacy statement](../docs/PRIVACY.md). File-provider imports are
copied into local storage before native parsing. Each export uses a
separate temporary directory, and iPad sharing supplies a popover origin.

Annotation edits are saved with *Save TextGrid*. Leaving an editor with
unsaved changes offers Save, Discard and Cancel. A failed save keeps the
editor open. Saves write a temporary sibling file and replace the existing
TextGrid only after writing and flushing it. Edits made during a save stay
marked as unsaved.

The Windows recorder backend has previously been observed to omit the
beginning of a take and write a duplicate `fmt` header, which the WAV
parser tolerates. Windows capture was not retested in this revision.
`PlaybackService` interpolates the Windows playhead and periodically
re-anchors it with the native position query. A debug-only library rescan
action can register WAVs copied into the recordings folder manually.

## Third-party notices

The existing in-app Licences page includes full Rust dependency licence
texts from `assets/licenses/rust_licenses.json`. Regenerate this asset with
`python3 ../scripts/generate_rust_licenses.py` after changing the Rust lockfile.
Conditional normal dependencies across targets are included; Dart and
Flutter plugin notices are collected separately by Flutter.
