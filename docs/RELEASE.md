# Release status

Version 0.1.0-rc.4, build 4. Test record dated 2 October 2026.

## Downloads

The [Android release](https://github.com/emmachados/openphon/releases/tag/v0.1.0-rc.4)
contains a signed APK for direct installation, an AAB for Google Play,
`SHA256SUMS` and `verification.json`. Android requires API 24 or later
and targets API 36. Application source: `4d8e2a3`.

An iOS development archive is available locally, but there is no App Store
or TestFlight distribution package. Neither store submission is complete.

## Tests and builds

| Check | Result |
|---|---|
| Flutter static analysis | No issues |
| Flutter tests | 147 passed |
| Rust core tests | Build 3: 82 passed; one ignored. Unchanged in build 4 |
| CLI tests | Build 3: six passed. Unchanged in build 4 |
| Android 16, ARM64, 16 KB pages | Build 4: ten native tests passed; signed APK starts with page-size compatibility fallback disabled |
| Android 16, ARM64, 4 KB pages | Build 1: nine native tests passed |
| iPhone 17 Pro simulator, iOS 26.5 | Build 4: ten native tests passed (one file failed on the first run and passed on three reruns) |
| Android production packages | APK and AAB build and signature checks passed |
| iOS production build | Build 4: unsigned release compilation passed on the second attempt. Build 2: development-signed archive passed. Distribution signing unavailable |

Build 4 adds a citation request to the About screen and changes nothing
in the analysis or the Rust code since build 3. Build 3 added manual pitch
correction, applied the corrections in the voice report and changed the
pitch tracker's voicing decision (see the [changelog](../CHANGELOG.md)).
The tenth native test checks that a corrected track reaches the voice
report.

On the first iOS run of build 4, `annotation_storage_test.dart` failed in
its first test and the unsigned release compilation reported an error.
Their output was not kept, so the cause is unknown; the test passed on
three further runs and the compilation succeeded when repeated.

Native tests cover the Rust bridge, analysis, malformed input, TextGrid
replacement, pitch correction, playback and storage preparation.
Integration tests run in debug mode. The signed Android release received a
separate startup check on the 16 KB emulator with
`bionic.linker.16kb.app_compat.enabled` set to false: the package reported
`pageSizeCompat=0`, the crash log was empty, Settings showed the Rust
core version and About showed the citation request.

The APK has no Internet permission and disables backups. ZIP alignment
passes `zipalign -c -P 16 -v 4`; all ARM64 and x86_64 native LOAD segments
have alignment of at least 16 KB. Both Android packages contain 84 Rust
dependency licence notices. The iOS archive includes its privacy manifest.

Android signing certificate, SHA-256:

```text
B3:04:5A:5A:BA:94:1B:75:46:33:A2:8F:89:60:F3:90:83:59:B7:99:46:34:E9:95:98:67:7A:7D:4F:25:A5:34
```

## Manual testing

The build 1 iPad simulator test covered WAV and TextGrid import, paired
export through the share sheet, saving to Files and reimport. Annotation
checks covered cancelling a recording switch, saving before switching,
and reopening the saved TextGrid. These tests used generated audio.

Manual test reports from an iPhone 17 running iOS 26.6 cover:

| Build | Test result |
|---|---|
| 1 | Complete recording, playback, and playback after restarting the app |
| 2 | Audio interruption displays “Paused · Stop”; Stop saves the captured portion |
| 2 | Denied microphone access produces no false library entry; recording works after permission is restored |

The build 1 WAV was inspected separately: mono, 44,100 Hz, 16-bit PCM,
449,320 frames, with a complete sample payload. Installing build 2 retained
that file byte for byte. The physical iPhone has not run the automated
native suite, which requires USB with the documented Flutter test command.

## Outstanding checks

Builds 3 and 4 have not run on a physical Android or iOS device, on a 4 KB-page
Android emulator or as an iOS development archive. Physical Android recording, microphone permission recovery, interruptions,
document-provider import and paired sharing remain untested. Separate
background/foreground recording transitions and physical backup/restore
or device-transfer exclusions also remain untested. Simulator attribute
checks establish the backup settings, not the outcome of a device transfer.

Store screenshots, account setup, declarations and submission are pending.

F-Droid reads the listing from `fastlane/metadata/android/en-US/` in this
repository: title, short and full description, icon and per-build
changelogs. Inclusion also needs a build recipe submitted to the
`fdroiddata` repository, which must build the Flutter application and the
Rust core from source with pinned Flutter and Rust toolchains. No recipe
has been written or tested, and F-Droid signs its own builds unless
reproducible-build verification against the release APK is set up.
The [store listing draft](STORE_LISTING.md) contains the current metadata
and proposed privacy answers.

Public-speech voicing agreement is 95.07% for build 3, against
a target of more than 90%, and CI enforces it. Build 2 measured 89.48% and
reported the metric without enforcing it. Other numerical results and
their scope are described in the [validation report](VALIDATION.md).

## Device test procedure

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

## Build procedure

Toolchain, test commands and signing configuration are documented in the
[application README](../app/README.md). Run Flutter builds and native tests
sequentially: they share generated platform files. On a device containing
recordings, retain `--no-uninstall` when running the native suite.

For Android, check the release certificate with `apksigner`, alignment with
`zipalign`, and SHA-256 hashes of the APK and AAB before attaching assets.
For iOS, archive Runner in Release configuration with a distribution-enabled
team, export for App Store Connect and test through TestFlight before review.
Signing credentials and provisioning profiles belong outside the repository.

## CI and benchmark files

[Application CI](https://github.com/emmachados/openphon/actions/runs/36982815768)
at `382d053` (build 3) passed static analysis, Flutter tests, Android
production packaging and the iOS simulator suite, after one retry of a
stalled test launch. The build 4 commits had not been pushed when this
record was written, so CI has not run on `4d8e2a3`. CI packages are
unsigned build outputs; the GitHub release contains the separately signed
Android packages.

[Validation CI](https://github.com/emmachados/openphon/actions/runs/36534135577)
at `995bd1f` passed core and CLI tests, synthetic, voice-quality and spectral
checks, 13 data-integrity tests, and public-speech scoring. The core and
validation code are unchanged in build 2. Public voicing agreement for
build 2 was 89.48492% on Linux and 89.48285% in the recorded macOS run;
the build 3 tracker measures 95.07410% on macOS. The voice report change
in build 3 leaves the voice-quality parity figures unchanged.

The [public benchmark archive](https://github.com/emmachados/openphon/releases/tag/validation-public-v1)
contains the 360 WAV files used in validation, with hashes, source attribution
and licences. The [privacy policy](https://emmamachado.com/openphon/privacy.html)
is published separately.
