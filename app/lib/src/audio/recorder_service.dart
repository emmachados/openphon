import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';

/// Capture parameters are fixed at analysis-friendly defaults: uncompressed
/// PCM WAV, mono. 44.1 kHz keeps the full spectrum available; analysis
/// routines downsample as needed.
const int kSampleRate = 44100;
const int kChannels = 1;

/// Base directory of the recording library.
///
/// Application-support, NOT documents: on Windows the documents folder is
/// commonly redirected into OneDrive, which would sync recordings to the
/// cloud and break the offline/private principle.
Future<Directory> libraryRoot() => getApplicationSupportDirectory();

/// One-time migration for libraries created before the base directory
/// moved: WAVs under `<documents>/recordings` are moved into
/// `<support>/recordings`. Database rows store paths relative to the base,
/// so they stay valid once the files have moved. Safe to call on every
/// launch; it is a no-op when there is nothing to migrate.
Future<void> migrateLibraryFromDocuments() async {
  try {
    final docs = await getApplicationDocumentsDirectory();
    final oldDir = Directory(p.join(docs.path, 'recordings'));
    if (!await oldDir.exists()) return;
    final root = await libraryRoot();
    final newDir = Directory(p.join(root.path, 'recordings'));
    await newDir.create(recursive: true);
    await for (final f in oldDir.list()) {
      if (f is! File || !f.path.toLowerCase().endsWith('.wav')) continue;
      final target = p.join(newDir.path, p.basename(f.path));
      if (await File(target).exists()) continue;
      try {
        await f.rename(target);
      } on FileSystemException {
        // Cross-volume move or a file held open by cloud sync: copy+delete.
        await f.copy(target);
        try {
          await f.delete();
        } catch (_) {
          // Copy succeeded; a leftover original is tolerable.
        }
      }
    }
  } catch (_) {
    // Migration is best-effort; the app must still start.
  }
}

/// User-tunable capture parameters. The three DSP switches default OFF:
/// platform "enhancements" (gain riding, noise suppression, echo
/// cancellation) distort exactly the acoustic detail phonetic measurement
/// needs, so the raw microphone is the baseline.
class RecordingOptions {
  const RecordingOptions({
    this.sampleRate = kSampleRate,
    this.autoGain = false,
    this.echoCancel = false,
    this.noiseSuppress = false,
  });

  final int sampleRate;
  final bool autoGain;
  final bool echoCancel;
  final bool noiseSuppress;

  /// Rates offered in settings; anything else stored in prefs is rejected
  /// back to the default.
  static const List<int> allowedSampleRates = [16000, 22050, 44100, 48000];

  RecordConfig toConfig() => RecordConfig(
    encoder: AudioEncoder.wav,
    sampleRate: sampleRate,
    numChannels: kChannels,
    autoGain: autoGain,
    echoCancel: echoCancel,
    noiseSuppress: noiseSuppress,
  );

  Map<String, Object> toMap() => {
    'sampleRate': sampleRate,
    'autoGain': autoGain,
    'echoCancel': echoCancel,
    'noiseSuppress': noiseSuppress,
  };

  /// Tolerant parse: unknown/invalid values fall back to defaults, and a
  /// stored rate outside [allowedSampleRates] is rejected.
  factory RecordingOptions.fromMap(Map<String, dynamic> map) {
    bool b(String key) => map[key] is bool ? map[key] as bool : false;
    final rate = map['sampleRate'];
    return RecordingOptions(
      sampleRate: rate is int && allowedSampleRates.contains(rate)
          ? rate
          : kSampleRate,
      autoGain: b('autoGain'),
      echoCancel: b('echoCancel'),
      noiseSuppress: b('noiseSuppress'),
    );
  }

  RecordingOptions copyWith({
    int? sampleRate,
    bool? autoGain,
    bool? echoCancel,
    bool? noiseSuppress,
  }) => RecordingOptions(
    sampleRate: sampleRate ?? this.sampleRate,
    autoGain: autoGain ?? this.autoGain,
    echoCancel: echoCancel ?? this.echoCancel,
    noiseSuppress: noiseSuppress ?? this.noiseSuppress,
  );

  @override
  bool operator ==(Object other) =>
      other is RecordingOptions &&
      other.sampleRate == sampleRate &&
      other.autoGain == autoGain &&
      other.echoCancel == echoCancel &&
      other.noiseSuppress == noiseSuppress;

  @override
  int get hashCode =>
      Object.hash(sampleRate, autoGain, echoCancel, noiseSuppress);
}

class RecorderService {
  final AudioRecorder _recorder = AudioRecorder();

  Future<bool> hasPermission() => _recorder.hasPermission();

  /// Starts recording and returns the absolute path of the target WAV file.
  ///
  /// The device may not honor the requested sample rate; callers must read
  /// the truth from the finished file's header, not from [options].
  Future<String> start({
    RecordingOptions options = const RecordingOptions(),
  }) async {
    final root = await libraryRoot();
    final dir = Directory(p.join(root.path, 'recordings'));
    await dir.create(recursive: true);
    final stamp = DateTime.now().toIso8601String().replaceAll(':', '-');
    final path = p.join(dir.path, 'rec_$stamp.wav');
    await _recorder.start(options.toConfig(), path: path);
    return path;
  }

  /// Stops recording and returns the file path, or null if nothing was
  /// recorded.
  Future<String?> stop() => _recorder.stop();

  Stream<Amplitude> amplitude() =>
      _recorder.onAmplitudeChanged(const Duration(milliseconds: 100));

  /// Momentary input level in dBFS (0 = full scale), ~10 Hz while
  /// recording. Wrapped so UI code needs no `record`-package types.
  Stream<double> levelDbfs() => amplitude().map((a) => a.current);

  Future<void> dispose() => _recorder.dispose();
}

/// Input level at/above which the live indicator flags clipping. -0.5 dBFS
/// rather than 0: device meters rarely report the exact rail even when
/// samples are flattened against it.
const double clipThresholdDbfs = -0.5;

/// How long the clipping warning stays lit after the last hot reading, so
/// a single clipped burst is noticeable rather than a one-frame flicker.
const Duration clipIndicatorHold = Duration(seconds: 2);

/// Whether the warning should be lit at [now] given the last hot reading.
bool clipIndicatorActive(DateTime? lastClipAt, DateTime now) =>
    lastClipAt != null && now.difference(lastClipAt) <= clipIndicatorHold;

/// The WAV's sibling TextGrid (Praat convention: same stem), if present.
/// Checks `.TextGrid` first, then `.textgrid` for case-sensitive
/// filesystems.
Future<File?> findSiblingTextGrid(String absWavPath) async {
  final upper = File(p.setExtension(absWavPath, '.TextGrid'));
  if (await upper.exists()) return upper;
  final lower = File(p.setExtension(absWavPath, '.textgrid'));
  if (await lower.exists()) return lower;
  return null;
}

/// Replaces characters that are invalid in file names on any supported
/// platform, so recording names ("Recording 2026-07-17 22:43") can become
/// export stems.
String sanitizeFileName(String name) {
  final cleaned = name.replaceAll(RegExp(r'[\\/:*?"<>|]'), '-').trim();
  return cleaned.isEmpty ? 'recording' : cleaned;
}

/// Copies the WAV and its sibling TextGrid (if any) into [dir] under a
/// shared stem derived from [name], so the pair stays paired in Praat.
/// Returns the number of files written (1 or 2).
Future<int> exportPairTo(String dir, String absWavPath, String name) async {
  final stem = sanitizeFileName(name);
  await File(absWavPath).copy(p.join(dir, '$stem.wav'));
  final grid = await findSiblingTextGrid(absWavPath);
  if (grid == null) return 1;
  await grid.copy(p.join(dir, '$stem.TextGrid'));
  return 2;
}

/// Converts an absolute path under the library root to the
/// library-relative form stored in the database.
Future<String> toRelativePath(String absolute) async {
  final root = await libraryRoot();
  return p.relative(absolute, from: root.path);
}

Future<String> toAbsolutePath(String relative) async {
  final root = await libraryRoot();
  return p.join(root.path, relative);
}
