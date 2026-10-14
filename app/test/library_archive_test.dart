import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openphon/src/analysis/analysis_settings.dart';
import 'package:openphon/src/data/database.dart';
import 'package:openphon/src/data/library_archive.dart';
import 'package:openphon/src/data/library_backup.dart';
import 'package:openphon/src/data/wav_import.dart';

class _FailingDatabase extends AppDatabase {
  _FailingDatabase() : super.forTesting(NativeDatabase.memory());
  int inserts = 0;
  @override
  Future<int> addRecording(RecordingsCompanion entry) {
    if (++inserts == 2) {
      throw const FileSystemException('simulated database failure');
    }
    return super.addRecording(entry);
  }
}

void main() {
  late Directory tmp;
  late File backup;
  late List<BackupItem> items;
  const settings = AnalysisSettings(pitchFloorHz: 150, pitchCeilingHz: 450);
  final created = DateTime.utc(2026, 3, 4, 5, 6);

  Future<ValidatedLibraryArchive> validate() => validateLibraryArchive(
    input: backup,
    temporaryDirectory: tmp,
    probeWav: (_) async =>
        const WavProbe(sampleRate: 48000, channels: 1, durationS: 1),
    validateTextGrid: (path) async =>
        expect(await File(path).readAsString(), 'TextGrid bytes'),
    validatePitchEdits: (path) async =>
        expect(await File(path).readAsString(), 'pitch correction bytes'),
  );

  Future<void> rewrite(void Function(Archive archive) edit) async {
    final archive = ZipDecoder().decodeBytes(await backup.readAsBytes());
    edit(archive);
    await backup.writeAsBytes(ZipEncoder().encode(archive));
  }

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('openphon_archive_test_');
    backup = File('${tmp.path}/library.zip');
    final wav = await File('${tmp.path}/audio.wav').writeAsString('WAV bytes');
    final grid = await File(
      '${tmp.path}/audio.TextGrid',
    ).writeAsString('TextGrid bytes');
    final edits = await File(
      '${tmp.path}/audio.pitchedits.csv',
    ).writeAsString('pitch correction bytes');
    items = [
      BackupItem(
        recording: Recording(
          id: 1,
          name: 'name, with / symbols',
          relativePath: 'recordings/audio.wav',
          createdAt: created,
          durationMs: 1000,
          sampleRate: 48000,
          channels: 1,
          analysisSettingsJson: settings.toJson(),
        ),
        wavPath: wav.path,
        gridPath: grid.path,
        editsPath: edits.path,
        stem: 'unused',
      ),
      BackupItem(
        recording: Recording(
          id: 2,
          name: 'defaults',
          relativePath: 'recordings/other.wav',
          createdAt: created,
          durationMs: 1000,
          sampleRate: 48000,
          channels: 1,
        ),
        wavPath: wav.path,
        stem: 'other',
      ),
    ];
    await writeLibraryArchive(
      output: backup,
      items: items,
      defaultSettings: const AnalysisSettings(formantCeilingHz: 5000),
      softwareVersion: '0.1.0+4',
    );
  });

  tearDown(() async => tmp.delete(recursive: true));

  test(
    'backup restores settings, names, dates, and sidecars without overwriting',
    () async {
      final validated = await validate();
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      final library = await Directory('${tmp.path}/library').create();
      final existing = await File(
        '${library.path}/existing.wav',
      ).writeAsString('original');
      await db.addRecording(
        RecordingsCompanion.insert(
          name: 'name, with / symbols',
          relativePath: 'existing.wav',
          createdAt: created,
          sampleRate: 48000,
        ),
      );
      try {
        expect(
          await restoreLibraryArchive(
            archive: validated,
            database: db,
            libraryDirectory: library,
          ),
          2,
        );
        expect(
          await restoreLibraryArchive(
            archive: validated,
            database: db,
            libraryDirectory: library,
          ),
          2,
        );
        final rows = await db.watchLibrary().first;
        expect(rows.length, 5);
        expect(rows.map((r) => r.relativePath).toSet().length, 5);
        expect(await existing.readAsString(), 'original');
        final restored = rows.where((r) => r.relativePath != 'existing.wav');
        for (final r in restored) {
        expect(r.createdAt.isAtSameMomentAs(created), isTrue);
          final s = AnalysisSettings.fromJson(r.analysisSettingsJson!);
          if (r.name == 'defaults') {
            expect(s.formantCeilingHz, 5000);
          } else {
            expect(s.pitchFloorHz, 150);
            expect(s.pitchCeilingHz, 450);
            final stem = '${library.path}/${r.relativePath}'.replaceFirst(
              RegExp(r'\.wav$'),
              '',
            );
            expect(
              await File('$stem.TextGrid').readAsString(),
              'TextGrid bytes',
            );
            expect(
              await File('$stem.pitchedits.csv').readAsString(),
              'pitch correction bytes',
            );
          }
        }
      } finally {
        await validated.dispose();
        await db.close();
      }
    },
  );

  test('damaged content is rejected before restoring', () async {
    await rewrite(
      (archive) => archive.add(
        ArchiveFile.string('recordings/1/audio.wav', 'bad bytes'),
      ),
    );
    await expectLater(validate(), throwsA(isA<FormatException>()));
    expect(
      tmp.listSync().whereType<Directory>().where(
        (d) => d.path.contains('openphon_restore_'),
      ),
      isEmpty,
    );
  });

  test('unsafe paths and unexpected files are rejected', () async {
    await rewrite(
      (archive) => archive.add(ArchiveFile.string('../outside.txt', 'bad')),
    );
    await expectLater(validate(), throwsA(isA<FormatException>()));
    expect(File('${tmp.parent.path}/outside.txt').existsSync(), isFalse);
  });

  test('future schema and invalid pitch range are rejected', () async {
    await rewrite((archive) {
      final manifest =
          jsonDecode(utf8.decode(archive.find('manifest.json')!.content))
              as Map<String, dynamic>;
      manifest['version'] = 2;
      archive.add(ArchiveFile.string('manifest.json', jsonEncode(manifest)));
    });
    await expectLater(validate(), throwsA(isA<FormatException>()));
    await rewrite((archive) {
      final manifest =
          jsonDecode(utf8.decode(archive.find('manifest.json')!.content))
              as Map<String, dynamic>;
      manifest['version'] = 1;
      manifest['recordings'][0]['analysis_settings']['pitchCeilingHz'] = 100;
      archive.add(ArchiveFile.string('manifest.json', jsonEncode(manifest)));
    });
    await expectLater(validate(), throwsA(isA<FormatException>()));
  });

  test(
    'database failure rolls back rows and deletes only new restore files',
    () async {
      final validated = await validate();
      final db = _FailingDatabase();
      final library = await Directory('${tmp.path}/library').create();
      final recordings = await Directory('${library.path}/recordings').create();
      final existing = await File(
        '${recordings.path}/keep.wav',
      ).writeAsString('keep');
      try {
        await expectLater(
          restoreLibraryArchive(
            archive: validated,
            database: db,
            libraryDirectory: library,
          ),
          throwsA(isA<FileSystemException>()),
        );
        expect(await db.watchLibrary().first, isEmpty);
        expect(recordings.listSync().map((f) => f.path), [existing.path]);
        expect(await existing.readAsString(), 'keep');
      } finally {
        await validated.dispose();
        await db.close();
      }
    },
  );
}
