# Store listing draft

These fields are prepared for the release candidate. No store submission
has been made.

## Shared description

Name: openphon

Short description: Record, inspect and annotate speech on your phone or tablet.

openphon is a phonetics application for Android and iOS. Record mono WAV
audio or import WAV files, then inspect synchronized waveform and
spectrogram views. Measure fundamental frequency, intensity and formants,
adjust analysis settings, and annotate interval and point tiers.

Import and export Praat TextGrid files, share a recording with its
annotations, and export measurements as CSV. Analysis runs locally.
No account is required. Recordings leave the application when you choose
to export or share them. The library is excluded from automatic system
backups; export a library backup before removing the app or changing device.

The algorithms and validation procedure are open source. Measurements
depend on the recording and analysis settings. The published validation
report describes comparisons with Praat. openphon is not a medical
diagnostic tool.

## Submission information

Application identifier: `app.openphon.openphon` on Android and iOS.
Version: `0.1.0`. Build number: `2`.
Language: English.
Suggested category: Education.

Support: https://github.com/emmachados/openphon/issues
Privacy policy: https://emmamachado.com/openphon/privacy.html
Source and validation: https://github.com/emmachados/openphon

For app review, no login or demonstration account is needed. Import a WAV
file or grant microphone permission and record audio. Select a recording
to view its analysis. The TextGrid menu creates or imports annotations.
The library menu exports recordings and measurement files.

## Prepared declarations for build 2

The application has no advertising, account system, telemetry, backend or
cloud SDK. It requests microphone access for recording. User-initiated
sharing is handled by the chosen system provider. Store privacy and data
safety answers must describe the submitted build and its dependencies.
The iOS privacy manifest declares file-timestamp API use for local and
user-selected files, no tracking and no developer data collection.

The following answers are prepared from application source `b36f1d2` and
the signed candidate 2 packages. They have not been submitted to either
store console.

| Field | Prepared answer | Evidence |
|---|---|---|
| Google Play data collection and sharing | No data collected or shared under the form's definitions | Recording, analysis, annotations and library storage run locally. Exports require a user action and use the selected system provider. |
| App Store data collection | Data not collected | No developer service or third-party collection SDK receives recordings, annotations, identifiers or usage events. |
| Tracking | No | No advertising identifier, advertising integration or tracking service is used. `NSPrivacyTracking` is false. |
| Advertising | No | The dependency list and application UI contain no advertising integration. |
| Account creation or login | None | All application features are available without an account. No review credentials are required. |
| Microphone access | Used for recording | The signed Android APK requests `RECORD_AUDIO`. iOS supplies `NSMicrophoneUsageDescription`. Import and analysis do not require microphone access. |
| Privacy policy | https://emmamachado.com/openphon/privacy.html | Public policy covering local storage, backup exclusions and user-directed exports. |

These privacy answers apply the store definitions to the inspected build.
Google excludes processing confined to the device from collection and
exempts transfers explicitly initiated by the user, with an expected
recipient, from its sharing disclosure. The share sheet in
`app/lib/src/data/file_exchange.dart` follows that pattern. This is the
basis for the proposed Google Play answer; it does not mean an exported
file can never leave the device. See [Google's Data safety guidance](https://support.google.com/googleplay/android-developer/answer/10787469?hl=en).

Apple also excludes processing confined to the device from collection.
Its definition concerns off-device transmission that gives the developer
or integrated partners access beyond servicing the request. The proposed
App Store answer follows that definition for this build. See [Apple's
App Privacy Details](https://developer.apple.com/app-store/app-privacy-details/).

No claim about encryption supplied by an external export destination is
made. The app does not create user accounts or retain a server-side copy
that a deletion-request service could remove. Local deletion and exported
copies are described in the privacy policy. Reassess these answers if a
network service, collection SDK or automatic upload is added.

## Information still required for submission

Submission still requires screenshots, an age-rating questionnaire,
pricing, target age groups, distribution territories and public developer
contact details. Apple enrollment is pending; Google Play account access
has not been confirmed. The Education category and source-code licence do
not determine pricing or target age groups.
