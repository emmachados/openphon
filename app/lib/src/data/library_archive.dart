import 'dart:convert';
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

Future<String> _sha256(File file) async =>
    (await sha256.bind(file.openRead()).first).toString();

/// One ZIP carries the complete saved analysis state. Each source is copied
/// before hashing and archiving so its checksum describes the archived bytes.
Future<void> writeLibraryArchive({
  required File output,
  required List<BackupItem> items,
  required AnalysisSettings defaultSettings,
  required String softwareVersion,
}) async {
  final staging = await output.parent.createTemp('.openphon_backup_');
  final encoder = ZipFileEncoder();
  var opened = false;
  try {
    encoder.create(output.path, level: 0);
    opened = true;
    final records = <Map<String, Object?>>[];
    for (var i = 0; i < items.length; i++) {
      final item = items[i];
      final r = item.recording;
      final settings = r.analysisSettingsJson == null
          ? defaultSettings
          : AnalysisSettings.fromJson(r.analysisSettingsJson!, strict: true);
      settings.validate();
      final files = <String, Object?>{};
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
        final snapshot = await File(
          source.value!,
        ).copy(p.join(staging.path, 'snapshot$extension'));
        files[source.key] = {
          'path': name,
          'size_bytes': await snapshot.length(),
          'sha256': await _sha256(snapshot),
        };
        await encoder.addFile(snapshot, name, 0);
        await snapshot.delete();
      }
      records.add({
        'name': r.name,
        'created': r.createdAt.toUtc().toIso8601String(),
        'sample_rate_hz': r.sampleRate,
        'channels': r.channels,
        'duration_ms': r.durationMs,
        // Materialise app defaults so restoring into another installation
        // cannot change the settings of previously unconfigured recordings.
        'analysis_settings': settings.toMap(),
        'files': files,
      });
    }
    encoder.addArchiveFile(
      ArchiveFile.string(
        'manifest.json',
        const JsonEncoder.withIndent('  ').convert({
          'format': libraryArchiveFormat,
          'version': libraryArchiveVersion,
          'software_version': softwareVersion,
          'created': DateTime.now().toUtc().toIso8601String(),
          'recordings': records,
        }),
      ),
    );
    await encoder.close();
    opened = false;
  } catch (_) {
    if (opened) {
      await encoder.close();
      opened = false;
    }
    if (await output.exists()) await output.delete();
    rethrow;
  } finally {
    await staging.delete(recursive: true);
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
    if (manifestEntry == null || manifestEntry.size > 16 * 1024 * 1024) {
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
        throw FormatException('Invalid recording metadata at entry ${i + 1}.');
      }
      final settings = _settings(record['analysis_settings']);
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
      final actual = await probeWav(wav.path);
      if (actual.sampleRate != rate ||
          actual.channels != channels ||
          (duration != null &&
              ((actual.durationS * 1000).round() - (duration as int)).abs() >
                  1)) {
        throw FormatException(
          'Audio metadata does not match the backup for $name.',
        );
      }
      final grid = extracted['textgrid'];
      final pitch = extracted['pitch_edits'];
      if (grid != null) await validateTextGrid(grid.path);
      if (pitch != null) await validatePitchEdits(pitch.path);
      restored.add(
        RestorableRecording(
          name: name,
          createdAt: DateTime.parse(created),
          sampleRate: rate,
          channels: channels,
          durationMs: duration as int?,
          settings: settings,
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
