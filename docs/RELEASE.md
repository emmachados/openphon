# Release status and procedure

Version 0.1.0, build 2, release candidate 2. Application and device checks
updated on 29 September 2026. Remote numerical validation: 29 September 2026.

## Verified locally

Static analysis reports no issues. All 137 Flutter tests pass. Build 2
passes the nine native integration tests on an Android 16 ARM64 emulator
with 16 KB pages and an iPad simulator running iOS 26.5. Build 1 also passed
the same suite on Android with 4 KB pages. These tests exercise Rust
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
and x86_64 native LOAD segments have alignment of at least 16 KB. The nine
native integration tests also pass on the 16 KB emulator with Android
page-size compatibility fallback disabled. The exact signed production
APK also starts with that fallback disabled; its process remained alive and the checked startup logs contained no crash. The release-mode
startup check does not replace the debug-mode native integration suite.

The iOS release application compiles and a development-signed archive
builds. Its privacy manifest is present. App Store export currently fails
because the selected developer team cannot create App Store provisioning
profiles and the account has no associated App Store Connect provider.
The account owner has confirmed that Developer Program enrollment is pending.
A development archive is not a publicly distributable iOS package.

On 29 September, the development-signed Release archive installed and ran
on an iPhone 17 running iOS 26.6. The owner verified a complete test
recording, playback and reopening with playback after restarting build 1.
Its exported WAV was inspected locally: 44,100 Hz, one channel, 16-bit PCM,
449,320 frames (10.189 seconds), with a complete sample payload. The
recording is not published. Updating in place to build 2 preserved that
WAV byte for byte, and the updated archive launched successfully.

On build 2, the owner verified that an audio interruption displays
"Paused · Stop" and that Stop saves the captured portion. The owner also
verified microphone permission denial without a false recording entry,
then successful recording after restoring permission. These are manual
physical-device results reported by the owner. The automated native suite
has not run on the physical iPhone: the current `flutter test` command
rejects wireless connections before executing tests. Its documented
`--no-uninstall` option must be retained when testing a device containing
recordings.

## Build 2 recording change

Build 2 fixes a confirmed UI defect: the native recorder pauses on an audio
interruption, but build 1 continued to display its recording timer. The
updated UI observes pause events, including events received while startup
is pending, and offers Stop to save the captured portion. Its three
regression tests pass, including retry after a stop error. Signed Android
production packages and the development-signed iOS archive have been
rebuilt with version `0.1.0+2`. Their signatures verify; both Android
packages contain all 84 Rust dependency licence notices.

## Outstanding release checks

Android microphone capture, permission denial and recovery, audio
interruption, and Android's native document picker and sharing interface
require device verification. A separate background/foreground recording
transition has not been verified on either physical platform. The iPhone
checks above do not establish timing accuracy across recording devices or
operating systems. Backup/restore and device-transfer exclusions have not
been exercised through a physical device transfer.

App Store distribution requires an active Apple Developer Program
membership, accepted agreements and appropriate team access. Google Play
and App Store uploads, store declarations, review and publication have not
been performed. Store screenshots must come from the candidate actually
submitted, using synthetic or consented recordings.

The public-speech voicing target is unmet: 89.48285% against a target above
90%. It remains report-only in CI. The release description must retain
this limitation and must not claim universal agreement with Praat. See
[validation](VALIDATION.md) for the other metrics and their interpretation.

## Remaining device verification procedure

Use the signed Android APK and a development or TestFlight iOS candidate
with the same application source. Record the installed version, operating
system, hardware and outcome for each check. Use generated audio or an
explicitly consented test recording.

| Check | Procedure and required observation |
|---|---|
| Capture and persistence | Record a signal with identifiable beginning and end, stop, reopen and play it, then restart the app and reopen it again. Inspect the exported WAV for both markers, complete PCM data and the actual sample rate and channel count. The library metadata must agree with the file. Default capture requests mono at 44,100 Hz with gain, echo cancellation and noise suppression disabled. |
| Permission recovery | Deny microphone permission and attempt recording. Confirm the denial is reported without creating a false recording entry. Grant permission through device settings, return and complete a recording. |
| Interruption recovery | During a consented test recording, exercise an audio-session interruption and a background/foreground transition. Record whether capture stops or resumes, verify that the controls reflect its state, and check that any saved WAV reopens. Preserve the error and sample evidence if the states disagree. |
| Android provider import | Use the native picker to import a known WAV and its matching TextGrid from a document provider. Cancel each picker once. Verify successful imports reopen with the expected duration and tier, and cancellation leaves the library and current editor intact. |
| Android paired sharing | Export the WAV and TextGrid together through the native share sheet into a selected storage provider. Reimport the pair and verify the samples and annotation contents. |
| Physical backup exclusions | Inspect an actual device backup or restore/transfer using test recordings and annotations. Verify the internal library is excluded and deliberately exported copies remain under the selected provider's control. Do not treat the existing attribute readback test as proof of a device transfer. |

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

## Published candidate and remote evidence

The [Android release candidate](https://github.com/emmachados/openphon/releases/tag/v0.1.0-rc.2)
provides a signed APK, App Bundle, checksums and verification metadata.
The [public benchmark archive](https://github.com/emmachados/openphon/releases/tag/validation-public-v1)
preserves the original WAV bytes with source attribution and licences.
The [privacy policy](https://emmamachado.com/openphon/privacy.html) is live.

[Build 2 application CI](https://github.com/emmachados/openphon/actions/runs/36537204654)
at `b36f1d2` has passed analysis, 137 Flutter tests and Android production
packaging. The remote iOS native-test job is still running; its result is
pending. Local build 2 iOS native tests, unsigned production compilation
and the development-signed archive have passed. The core, CLI and
numerical validation code remain unchanged.

[Validation CI](https://github.com/emmachados/openphon/actions/runs/36534135577)
passed at `995bd1f`, including core and CLI tests, synthetic, voice-quality
and spectral checks, public archive and WAV hash verification, 13 integrity
tests and fresh public-speech scoring. All enforced numerical checks pass.
Public voicing remains below target: 89.48492% in the Linux run and
89.48285% in the recorded macOS run. Each report records its environment.
CI packages are unsigned verification outputs; the separately signed
release assets are the installation and store-processing candidates.
