import 'dart:convert';
import 'dart:async';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:crypto/crypto.dart';
import 'package:drift/drift.dart' show Value;
import 'package:path/path.dart' as p;

import '../analysis/analysis_settings.dart';
import 'database.dart';
import 'library_backup.dart';
import 'wav_import.dart';

const libraryArchiveFormat = 'openphon-library';
const libraryArchiveVersion = 1;
const _maxManifestBytes = 16 * 1024 * 1024;

Future<String> _sha256(File file) async =>
    (await sha256.bind(file.openRead()).first).toString();

AbstractFileHandle _openArchiveFile(String path, FileAccess mode) =>
    FileHandle(path, mode: mode);

Future<T> _usingArchiveFile<T>(
  AbstractFileHandle file,
  FutureOr<T> Function() action,
) async {
  var completed = false;
  try {
    final result = await action();
    completed = true;
    return result;
  } finally {
    try {
      await file.close();
    } catch (_) {
      // A close failure must not hide an earlier read/write/validation error.
      if (completed) rethrow;
    }
  }
}

/// Save to a user-selected destination without truncating an earlier backup
/// if copying fails. The temporary file is on the destination filesystem.
Future<void> publishLibraryArchive({
  required File source,
  required File destination,
}) async {
  final staging = await destination.parent.createTemp('.openphon_publish_');
  var failed = false;
  try {
    final snapshot = await source.copy(p.join(staging.path, 'library.zip'));
    await snapshot.rename(destination.path);
  } catch (_) {
    failed = true;
    rethrow;
  } finally {
    try {
      await staging.delete(recursive: true);
    } catch (_) {
      if (!failed) rethrow;
    }
  }
}

/// One ZIP carries the complete saved analysis state. Each source is copied
/// before validation, hashing and archiving. Publish only a completed archive;
/// a failed snapshot must not replace an earlier backup at [output].
Future<void> writeLibraryArchive({
  required File output,
  required List<BackupItem> items,
  required AnalysisSettings defaultSettings,
  required String softwareVersion,
  required Future<WavProbe> Function(String path) probeWav,
  required Future<void> Function(String path) validateTextGrid,
  required Future<void> Function(String path) validatePitchEdits,
  AbstractFileHandle Function(String path, FileAccess mode) openArchiveFile =
      _openArchiveFile,
}) async {
  final staging = await output.parent.createTemp('.openphon_backup_');
  final stagedArchive = File(p.join(staging.path, 'library.zip'));
  var failed = false;
  try {
    final outputFile = openArchiveFile(stagedArchive.path, FileAccess.write);
    await _usingArchiveFile(outputFile, () async {
      final outputStream = OutputFileStream.withFileHandle(outputFile);
      final encoder = ZipEncoder()..startEncode(outputStream, level: 0);
      final records = <Map<String, Object?>>[];
      for (var i = 0; i < items.length; i++) {
        final item = items[i];
        final r = item.recording;
        Object? settings;
        try {
          settings = r.analysisSettingsJson == null
              ? defaultSettings.toMap()
              : AnalysisSettings.fromJson(
                  r.analysisSettingsJson!,
                  strict: true,
                ).toMap();
        } catch (error) {
          throw FormatException(
            'Invalid analysis settings for ${r.name}: $error',
          );
        }
        final record = <String, dynamic>{
          'name': r.name,
          'created': r.createdAt.toUtc().toIso8601String(),
          'sample_rate_hz': r.sampleRate,
          'channels': r.channels,
          'duration_ms': r.durationMs,
          // Materialise defaults so another installation cannot change them.
          'analysis_settings': settings,
        };
        final metadata = _recordingMetadata(record, i);
        final files = <String, Object?>{};
        final snapshots = <String, File>{};
        for (final source in <String, String?>{
          'wav': item.wavPath,
          'textgrid': item.gridPath,
          'pitch_edits': item.editsPath,
        }.entries) {
          if (source.value == null) continue;
          final extension = switch (source.key) {
            'wav' => '.wav',
            'textgrid' => '.TextGrid',
            _ => '.pitchedits.csv',
          };
          final name = 'recordings/${i + 1}/audio$extension';
          late File snapshot;
          try {
            snapshot = await File(
              source.value!,
            ).copy(p.join(staging.path, 'snapshot$extension'));
          } catch (error) {
            throw FileSystemException(
              'Could not copy ${source.key} for ${r.name}: $error',
              source.value,
            );
          }
          snapshots[source.key] = snapshot;
          files[source.key] = {
            'path': name,
            'size_bytes': await snapshot.length(),
            'sha256': await _sha256(snapshot),
          };
        }
        await _validateRecordingContents(
          metadata: metadata,
          files: snapshots,
          probeWav: probeWav,
          validateTextGrid: validateTextGrid,
          validatePitchEdits: validatePitchEdits,
        );
        for (final snapshot in snapshots.entries) {
          final name =
              (files[snapshot.key] as Map<String, Object?>)['path']! as String;
          final inputFile = openArchiveFile(
            snapshot.value.path,
            FileAccess.read,
          );
          await _usingArchiveFile(inputFile, () {
            final inputStream = InputFileStream.withFileHandle(inputFile);
            final entry = ArchiveFile.stream(name, inputStream)
              ..compression = CompressionType.none;
            encoder.add(entry, autoClose: false);
          });
          await snapshot.value.delete();
        }
        records.add({...record, 'files': files});
      }
      final manifest = const JsonEncoder.withIndent('  ').convert({
        'format': libraryArchiveFormat,
        'version': libraryArchiveVersion,
        'software_version': softwareVersion,
        'created': DateTime.now().toUtc().toIso8601String(),
        'recordings': records,
      });
      if (utf8.encode(manifest).length > _maxManifestBytes) {
        throw const FormatException(
          'The library backup manifest exceeds 16 MiB.',
        );
      }
      encoder.add(ArchiveFile.string('manifest.json', manifest));
      // Finalization flushes buffered bytes. Close the raw output handle even
      // when finalization/flush fails; do not retry a partially written ZIP.
      encoder.endEncode();
    });
    await stagedArchive.rename(output.path);
  } catch (_) {
    failed = true;
    rethrow;
  } finally {
    try {
      await staging.delete(recursive: true);
    } catch (_) {
      if (!failed) rethrow;
    }
  }
}

class RestorableRecording {
  const RestorableRecording({
    required this.name,
    required this.createdAt,
    required this.sampleRate,
    required this.channels,
    required this.durationMs,
    required this.settings,
    required this.wav,
    this.textGrid,
    this.pitchEdits,
  });
  final String name;
  final DateTime createdAt;
  final int sampleRate;
  final int channels;
  final int? durationMs;
  final AnalysisSettings settings;
  final File wav;
  final File? textGrid;
  final File? pitchEdits;
}

/// Only produced after every file has passed checksum and content validation.
/// Its temporary files belong to the caller until [dispose] is called.
class ValidatedLibraryArchive {
  ValidatedLibraryArchive(this.directory, this.recordings);
  final Directory directory;
  final List<RestorableRecording> recordings;
  Future<void> dispose() => directory.delete(recursive: true);
}

Map<String, dynamic> _map(Object? value, String label) {
  if (value is! Map<String, dynamic>) {
    throw FormatException('Invalid $label in the backup manifest.');
  }
  return value;
}

AnalysisSettings _settings(Object? value) {
  final map = _map(value, 'analysis settings');
  for (final key in const AnalysisSettings().toMap().keys) {
    final n = map[key];
    if (n is! num ||
        !n.isFinite ||
        (key == 'spectrogramPreEmphasisHz' ? n < 0 : n <= 0)) {
      throw FormatException('Invalid analysis setting: $key.');
    }
  }
  if (map['maxFormants'] is! int ||
      (map['pitchCeilingHz'] as num) <= (map['pitchFloorHz'] as num)) {
    throw const FormatException('Invalid formant count or pitch range.');
  }
  return AnalysisSettings.fromJson(jsonEncode(map), strict: true);
}

typedef _RecordingMetadata = ({
  String name,
  DateTime createdAt,
  int sampleRate,
  int channels,
  int? durationMs,
  AnalysisSettings settings,
});

// Both creation and restore use these checks, so a valid checksum cannot hide
// content or metadata which the same application would refuse to restore.
_RecordingMetadata _recordingMetadata(Map<String, dynamic> record, int index) {
  final name = record['name'];
  final created = record['created'];
  final rate = record['sample_rate_hz'];
  final channels = record['channels'];
  final duration = record['duration_ms'];
  if (name is! String ||
      created is! String ||
      DateTime.tryParse(created) == null ||
      !DateTime.parse(created).isUtc ||
      rate is! int ||
      rate <= 0 ||
      channels is! int ||
      channels <= 0 ||
      (duration != null && (duration is! int || duration < 0))) {
    throw FormatException(
      'Invalid recording metadata for ${name is String ? name : 'entry ${index + 1}'}.',
    );
  }
  late AnalysisSettings settings;
  try {
    settings = _settings(record['analysis_settings']);
  } catch (error) {
    throw FormatException('Invalid analysis settings for $name: $error');
  }
  return (
    name: name,
    createdAt: DateTime.parse(created),
    sampleRate: rate,
    channels: channels,
    durationMs: duration as int?,
    settings: settings,
  );
}

Future<void> _validateRecordingContents({
  required _RecordingMetadata metadata,
  required Map<String, File> files,
  required Future<WavProbe> Function(String path) probeWav,
  required Future<void> Function(String path) validateTextGrid,
  required Future<void> Function(String path) validatePitchEdits,
}) async {
  final name = metadata.name;
  late WavProbe actual;
  try {
    actual = await probeWav(files['wav']!.path);
  } catch (error) {
    throw FormatException('Invalid WAV for $name: $error');
  }
  if (!actual.durationS.isFinite ||
      actual.durationS < 0 ||
      actual.sampleRate != metadata.sampleRate ||
      actual.channels != metadata.channels ||
      (metadata.durationMs != null &&
          ((actual.durationS * 1000).round() - metadata.durationMs!).abs() >
              1)) {
    throw FormatException(
      'Audio metadata does not match the backup for $name.',
    );
  }
  final grid = files['textgrid'];
  final pitch = files['pitch_edits'];
  if (grid != null) {
    try {
      await validateTextGrid(grid.path);
    } catch (error) {
      throw FormatException('Invalid TextGrid for $name: $error');
    }
  }
  if (pitch != null) {
    try {
      await validatePitchEdits(pitch.path);
    } catch (error) {
      throw FormatException('Invalid pitch corrections for $name: $error');
    }
  }
}

/// Extract into temporary storage, reject unexpected paths and links, verify
/// all checksums, and probe every audio/annotation file before library writes.
Future<ValidatedLibraryArchive> validateLibraryArchive({
  required File input,
  required Directory temporaryDirectory,
  required Future<WavProbe> Function(String path) probeWav,
  required Future<void> Function(String path) validateTextGrid,
  required Future<void> Function(String path) validatePitchEdits,
}) async {
  final staging = await temporaryDirectory.createTemp('openphon_restore_');
  InputFileStream? stream;
  try {
    stream = InputFileStream(input.path);
    final decoder = ZipDecoder();
    final archive = decoder.decodeStream(stream);
    final entries = <String, ArchiveFile>{};
    for (final header in decoder.directory.fileHeaders) {
      final name = header.filename;
      if (name.contains('\\') ||
          name.startsWith('/') ||
          name
              .split('/')
              .any((part) => part == '..' || part == '.' || part.isEmpty) ||
          name.contains(':') ||
          entries.containsKey(name)) {
        throw FormatException('Invalid or duplicate archive path: $name.');
      }
      final entry = archive.find(name)!;
      if (!entry.isFile || entry.isSymbolicLink) {
        throw FormatException('The backup contains a non-file entry: $name.');
      }
      entries[name] = entry;
    }
    final manifestEntry = entries.remove('manifest.json');
    if (manifestEntry == null || manifestEntry.size > _maxManifestBytes) {
      throw const FormatException('This is not an openphon library backup.');
    }
    final manifest = _map(
      jsonDecode(utf8.decode(manifestEntry.content)),
      'manifest',
    );
    if (manifest['format'] != libraryArchiveFormat ||
        manifest['version'] != libraryArchiveVersion) {
      throw const FormatException(
        'Unsupported openphon backup format or version.',
      );
    }
    final records = manifest['recordings'];
    if (records is! List) {
      throw const FormatException('Missing backup recordings.');
    }
    final restored = <RestorableRecording>[];
    for (var i = 0; i < records.length; i++) {
      final record = _map(records[i], 'recording');
      final metadata = _recordingMetadata(record, i);
      final name = metadata.name;
      final files = _map(record['files'], 'recording files');
      if (!files.containsKey('wav') ||
          files.keys.any(
            (k) => !{'wav', 'textgrid', 'pitch_edits'}.contains(k),
          )) {
        throw FormatException('Invalid file list for $name.');
      }
      final extracted = <String, File>{};
      final recordDirectory = await Directory(
        p.join(staging.path, '$i'),
      ).create();
      for (final file in files.entries) {
        final description = _map(file.value, 'file');
        final path = description['path'];
        final size = description['size_bytes'];
        final checksum = description['sha256'];
        final entry = entries.remove(path);
        if (path is! String ||
            size is! int ||
            size < 0 ||
            checksum is! String ||
            !RegExp(r'^[a-f0-9]{64}$').hasMatch(checksum) ||
            entry == null ||
            entry.size != size) {
          throw FormatException(
            'Missing file or invalid size/checksum for $name (${file.key}).',
          );
        }
        final extension = switch (file.key) {
          'wav' => '.wav',
          'textgrid' => '.TextGrid',
          _ => '.pitchedits.csv',
        };
        final target = File(p.join(recordDirectory.path, 'audio$extension'));
        final output = OutputFileStream(target.path);
        try {
          entry.writeContent(output);
        } finally {
          await output.close();
        }
        if (await target.length() != size ||
            await _sha256(target) != checksum) {
          throw FormatException(
            'Checksum verification failed for $name (${file.key}).',
          );
        }
        extracted[file.key] = target;
      }
      final wav = extracted['wav']!;
      final grid = extracted['textgrid'];
      final pitch = extracted['pitch_edits'];
      await _validateRecordingContents(
        metadata: metadata,
        files: extracted,
        probeWav: probeWav,
        validateTextGrid: validateTextGrid,
        validatePitchEdits: validatePitchEdits,
      );
      restored.add(
        RestorableRecording(
          name: name,
          createdAt: metadata.createdAt,
          sampleRate: metadata.sampleRate,
          channels: metadata.channels,
          durationMs: metadata.durationMs,
          settings: metadata.settings,
          wav: wav,
          textGrid: grid,
          pitchEdits: pitch,
        ),
      );
    }
    if (entries.isNotEmpty) {
      throw const FormatException(
        'The backup contains files absent from its manifest.',
      );
    }
    return ValidatedLibraryArchive(staging, restored);
  } catch (_) {
    await staging.delete(recursive: true);
    rethrow;
  } finally {
    await stream?.close();
  }
}

/// Each restore gets a new directory, even when filenames or display names
/// already exist. A database failure rolls back every row and removes only
/// this restore's files; the existing library is never overwritten.
Future<int> restoreLibraryArchive({
  required ValidatedLibraryArchive archive,
  required AppDatabase database,
  required Directory libraryDirectory,
}) async {
  final recordings = await Directory(
    p.join(libraryDirectory.path, 'recordings'),
  ).create(recursive: true);
  final destination = await recordings.createTemp('restored_');
  try {
    final rows = <RecordingsCompanion>[];
    for (var i = 0; i < archive.recordings.length; i++) {
      final r = archive.recordings[i];
      final path = p.join(destination.path, '$i.wav');
      await r.wav.copy(path);
      if (r.textGrid != null) {
        await r.textGrid!.copy(p.setExtension(path, '.TextGrid'));
      }
      if (r.pitchEdits != null) {
        await r.pitchEdits!.copy(p.setExtension(path, '.pitchedits.csv'));
      }
      rows.add(
        RecordingsCompanion.insert(
          name: r.name,
          relativePath: p.relative(path, from: libraryDirectory.path),
          createdAt: r.createdAt,
          sampleRate: r.sampleRate,
          channels: Value(r.channels),
          durationMs: Value(r.durationMs),
          analysisSettingsJson: Value(r.settings.toJson()),
        ),
      );
    }
    await database.transaction(() async {
      for (final row in rows) {
        await database.addRecording(row);
      }
    });
    return rows.length;
  } catch (_) {
    await destination.delete(recursive: true);
    rethrow;
  }
}
