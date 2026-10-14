import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive_io.dart';
import 'package:drift/drift.dart' show Value;
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

class _FailingCopyFile implements File {
  @override
  Future<File> copy(String newPath) async {
    await File(newPath).writeAsString('incomplete replacement');
    throw const FileSystemException('simulated copy failure');
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FaultyFileHandle extends FileHandle {
  _FaultyFileHandle(
    super.path, {
    required super.mode,
    this.failRead = false,
    this.failWrite = false,
    this.failClose = false,
  });

  final bool failRead;
  final bool failWrite;
  final bool failClose;
  int closeCalls = 0;
  int writeCalls = 0;

  @override
  int readInto(Uint8List buffer, [int? length]) {
    if (failRead) throw const FileSystemException('simulated read failure');
    return super.readInto(buffer, length);
  }

  @override
  void writeFromSync(List<int> buffer, [int start = 0, int? end]) {
    writeCalls++;
    if (failWrite) throw const FileSystemException('simulated write failure');
    super.writeFromSync(buffer, start, end);
  }

  @override
  Future<void> close() async {
    closeCalls++;
    await super.close();
    if (failClose) throw const FileSystemException('simulated close failure');
  }
}

void main() {
  late Directory tmp;
  late File backup;
  late List<BackupItem> items;
  const settings = AnalysisSettings(pitchFloorHz: 150, pitchCeilingHz: 450);
  final created = DateTime.utc(2026, 3, 4, 5, 6);

  Future<WavProbe> probeWav(String path) async {
    if (await File(path).readAsString() != 'WAV bytes') {
      throw const FormatException('Unrecognised WAV.');
    }
    return const WavProbe(sampleRate: 48000, channels: 1, durationS: 1);
  }

  Future<void> validateTextGrid(String path) async {
    if (await File(path).readAsString() != 'TextGrid bytes') {
      throw const FormatException('Unrecognised TextGrid.');
    }
  }

  Future<void> validatePitchEdits(String path) async {
    if (await File(path).readAsString() != 'pitch correction bytes') {
      throw const FormatException('Unrecognised pitch corrections.');
    }
  }

  Future<void> create({File? output, List<BackupItem>? sourceItems}) =>
      writeLibraryArchive(
        output: output ?? backup,
        items: sourceItems ?? items,
        defaultSettings: const AnalysisSettings(formantCeilingHz: 5000),
        softwareVersion: '0.1.0+4',
        probeWav: probeWav,
        validateTextGrid: validateTextGrid,
        validatePitchEdits: validatePitchEdits,
      );

  Future<ValidatedLibraryArchive> validate() => validateLibraryArchive(
    input: backup,
    temporaryDirectory: tmp,
    probeWav: probeWav,
    validateTextGrid: validateTextGrid,
    validatePitchEdits: validatePitchEdits,
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
    await create();
  });

  tearDown(() async => tmp.delete(recursive: true));

  test(
    'desktop publication preserves an earlier backup after a partial copy',
    () async {
      final original = await backup.readAsBytes();
      await expectLater(
        publishLibraryArchive(source: _FailingCopyFile(), destination: backup),
        throwsA(
          isA<FileSystemException>().having(
            (error) => error.message,
            'message',
            'simulated copy failure',
          ),
        ),
      );
      expect(await backup.readAsBytes(), original);
      expect(tmp.listSync().whereType<Directory>(), isEmpty);
      final replacement = await File(
        '${tmp.path}/replacement.zip',
      ).writeAsString('complete replacement');
      await publishLibraryArchive(source: replacement, destination: backup);
      expect(await backup.readAsString(), 'complete replacement');
      expect(await replacement.readAsString(), 'complete replacement');
      expect(tmp.listSync().whereType<Directory>(), isEmpty);
    },
  );

  for (final failure in ['read', 'write', 'close']) {
    test(
      'archive $failure failure closes handles and preserves the original error and backup',
      () async {
        final original = await backup.readAsBytes();
        final handles = <_FaultyFileHandle>[];
        await expectLater(
          writeLibraryArchive(
            output: backup,
            items: [items.first],
            defaultSettings: const AnalysisSettings(),
            softwareVersion: 'test',
            probeWav: probeWav,
            validateTextGrid: validateTextGrid,
            validatePitchEdits: validatePitchEdits,
            openArchiveFile: (path, mode) {
              final handle = _FaultyFileHandle(
                path,
                mode: mode,
                failRead: mode == FileAccess.read && failure == 'read',
                failWrite: mode == FileAccess.write && failure == 'write',
                // A second failure during cleanup must not replace read/write.
                failClose: mode == FileAccess.write || failure == 'read',
              );
              handles.add(handle);
              return handle;
            },
          ),
          throwsA(
            isA<FileSystemException>().having(
              (error) => error.message,
              'message',
              'simulated $failure failure',
            ),
          ),
        );
        expect(handles, hasLength(greaterThanOrEqualTo(2)));
        expect(handles.every((handle) => !handle.isOpen), isTrue);
        expect(handles.every((handle) => handle.closeCalls == 1), isTrue);
        if (failure == 'write') expect(handles.first.writeCalls, 1);
        expect(await backup.readAsBytes(), original);
        expect(tmp.listSync().whereType<Directory>(), isEmpty);
      },
    );
  }

  for (final content in ['WAV', 'TextGrid', 'pitch corrections']) {
    test(
      'invalid $content prevents publishing and preserves an earlier backup',
      () async {
        final original = await backup.readAsBytes();
        final source = switch (content) {
          'WAV' => items.first.wavPath,
          'TextGrid' => items.first.gridPath!,
          _ => items.first.editsPath!,
        };
        await File(source).writeAsString('malformed');
        final failure = throwsA(
          isA<FormatException>().having(
            (error) => error.message,
            'recording-specific error',
            contains('Invalid $content for name, with / symbols:'),
          ),
        );
        await expectLater(create(), failure);
        expect(await backup.readAsBytes(), original);
        final fresh = File('${tmp.path}/fresh.zip');
        await expectLater(create(output: fresh), failure);
        expect(await fresh.exists(), isFalse);
        expect(tmp.listSync().whereType<Directory>(), isEmpty);
      },
    );
  }

  test(
    'metadata mismatch in a later recording rejects the complete new backup',
    () async {
      final original = await backup.readAsBytes();
      for (final recording in [
        items.last.recording.copyWith(sampleRate: 16000),
        items.last.recording.copyWith(channels: 2),
        items.last.recording.copyWith(durationMs: const Value(2000)),
      ]) {
        final invalid = BackupItem(
          recording: recording,
          wavPath: items.last.wavPath,
          stem: 'defaults',
        );
        await expectLater(
          create(sourceItems: [items.first, invalid]),
          throwsA(
            isA<FormatException>().having(
              (error) => error.message,
              'message',
              'Audio metadata does not match the backup for defaults.',
            ),
          ),
        );
        expect(await backup.readAsBytes(), original);
        expect(tmp.listSync().whereType<Directory>(), isEmpty);
      }
    },
  );

  test(
    'invalid stored settings identify the recording before publishing',
    () async {
      final original = await backup.readAsBytes();
      final invalid = BackupItem(
        recording: items.first.recording.copyWith(
          analysisSettingsJson: const Value('{"pitchFloorHz":-1}'),
        ),
        wavPath: items.first.wavPath,
        stem: 'invalid',
      );
      await expectLater(
        create(sourceItems: [invalid]),
        throwsA(
          isA<FormatException>().having(
            (error) => error.message,
            'message',
            contains('Invalid analysis settings for name, with / symbols:'),
          ),
        ),
      );
      expect(await backup.readAsBytes(), original);
    },
  );

  test('validation and archived bytes use the staged snapshot', () async {
    final source = items.first.wavPath;
    await writeLibraryArchive(
      output: backup,
      items: [items.first],
      defaultSettings: const AnalysisSettings(),
      softwareVersion: 'test',
      probeWav: (path) async {
        expect(path, isNot(source));
        expect(path, contains('.openphon_backup_'));
        await File(source).writeAsString('changed after snapshot');
        return probeWav(path);
      },
      validateTextGrid: validateTextGrid,
      validatePitchEdits: validatePitchEdits,
    );
    final validated = await validate();
    try {
      expect(await validated.recordings.single.wav.readAsString(), 'WAV bytes');
      expect(await File(source).readAsString(), 'changed after snapshot');
    } finally {
      await validated.dispose();
    }
  });

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
