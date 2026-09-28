# Release status and procedure

Version 0.1.0, build 1, release candidate. Checked on 28 September 2026.

## Verified locally

Static analysis reports no issues. All 134 Flutter tests pass. The nine
native integration tests pass on an Android 16 ARM64 emulator with 4 KB
pages, an Android 16 ARM64 emulator with 16 KB pages, and an iPad simulator
running iOS 26.5. These tests exercise Rust
analysis, malformed input, TextGrid reading and replacement, playback and
storage preparation. The core suite passes 74 tests, with one ignored;
the CLI suite passes four tests.

The running iPad application was checked with generated audio: native WAV
and TextGrid import, paired export through the system share sheet, saving
to Files and reimport. Unsaved annotation navigation was checked by
cancelling a recording switch, saving before switching, and reopening the
saved TextGrid. No participant recording was used for these checks.

Android APK and App Bundle production builds succeed with the existing
release certificate. The APK signature verifies. Certificate SHA-256:

```text
B3:04:5A:5A:BA:94:1B:75:46:33:A2:8F:89:60:F3:90:83:59:B7:99:46:34:E9:95:98:67:7A:7D:4F:25:A5:34
```

The APK targets API 36, requires API 24, has no Internet permission and
disables backups. ZIP alignment passes `zipalign -c -P 16 -v 4`; all ARM64
and x86_64 native LOAD segments have alignment of at least 16 KB. The nine native integration tests also pass on the 16 KB emulator.
The production app also starts on that emulator; its process remained
alive and the checked startup logs contained no crash. The release-mode
startup check does not replace the debug-mode native integration suite.

The iOS release application compiles and a development-signed archive
builds. Its privacy manifest is present. App Store export currently fails
because the selected developer team cannot create App Store provisioning
profiles and the account has no associated App Store Connect provider.
A development archive is not a publicly distributable iOS package.

## Outstanding release checks

Physical-device microphone capture, permission denial and recovery, audio
interruption, and Android's native document picker and sharing interface
require device verification. The current tests do not establish microphone
sample integrity on physical Android or iOS devices. Backup/restore and
device-transfer exclusions have not been exercised through a physical
device transfer.

App Store distribution requires an active Apple Developer Program
membership, accepted agreements and appropriate team access. Google Play
and App Store uploads, store declarations, review and publication have not
been performed. Store screenshots must come from the candidate actually
submitted, using synthetic or consented recordings.

The public-speech voicing target is unmet: 89.48285% against a target above
90%. It remains report-only in CI. The release description must retain
this limitation and must not claim universal agreement with Praat. See
[validation](VALIDATION.md) for the other metrics and their interpretation.

## Building and publishing

Use the pinned toolchain and signing instructions in
[the application README](../app/README.md). Run Flutter builds and native
tests sequentially in a checkout because they update shared generated
platform files. Never upload a debug package as a release build.

Before attaching an Android artifact, verify its release certificate with
`apksigner`, validate alignment with `zipalign`, and calculate SHA-256 for
the exact APK and AAB. Preserve these checksums with the release. The APK
is for direct Android installation; the AAB is for Google Play processing.
Keep signing archives, keystores, passwords, certificates and provisioning
profiles outside the public repository.

For iOS, choose the enrolled team in Xcode, archive Runner in Release
configuration and export using the App Store Connect method. Complete a
TestFlight device test before requesting App Store review.

The public source is selected by `scripts/export_release_source.py` into a
new directory. It includes the application, core, CLI and reproducible
public validation procedure. It excludes research manuscripts, participant
transcripts, audio, local inputs and the original Git history. Inspect
`SOURCE_MANIFEST.json` and the actual staged files before publishing.
Existing working files in the research repository are preserved.

CI recompiles unsigned production artifacts and regenerates validation
evidence. The first remote runs are being checked at
https://github.com/emmachados/openphon/actions. Local results alone do not
establish a successful remote run.
