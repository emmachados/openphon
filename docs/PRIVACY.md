# Privacy statement

openphon records, analyzes and annotates speech on the device. The
application has no backend, account system, telemetry, advertising or
cloud SDK. Export is initiated by the user through a system share sheet
or save dialog. The Android release manifest requests microphone access;
development builds also request network access for Flutter tooling.

## Library storage and backups

Recordings, annotations, preferences and the database are stored in the
application-support directory. Android disables automatic backup and
excludes application data from both cloud backup and device transfer in
its backup rules. On iOS, startup creates the Application Support and
Documents directories, sets their backup-exclusion attributes and checks
that the attributes were applied before opening the library. A failure
shows a retry screen. Documents is included in this preparation because
older libraries may be migrated from that location.

These settings were inspected in a signed Android release package and
verified on an iOS simulator. A physical-device backup/restore or transfer
was not performed in this verification. On desktop, user-configured
backup software can copy application files.

Exported copies are outside the library's backup rules. Selecting a cloud
location or another application in the system picker/share sheet can
transfer those copies according to that provider's settings. Deleting a
recording in openphon does not delete copies previously exported elsewhere.

Removing the app and its data removes the local library. iOS offloading,
which retains app data, is different from deleting the app. Use
*Back up library…* to export recordings, TextGrids and a `manifest.csv`
index before removing the application or moving to another device.
System backup is not a substitute for this export.

## Validation data

The reproducible release check uses synthesized signals and public speech
selected from CIEMPIESS Light and Spanish Common Voice. It verifies the
committed public-audio hashes and does not read the separate private
participant corpus used in earlier research. Private participant audio
and its manifest are excluded from the source repository. See the
[validation report](VALIDATION.md) for the tested material and procedure.
