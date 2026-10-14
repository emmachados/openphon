import 'dart:io';
import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:openphon/src/analysis/analysis_settings.dart';
import 'package:openphon/src/analysis/measurements.dart';
import 'package:openphon/src/analysis/pitch_edits.dart';
import 'package:openphon/src/annotation/annotation_model.dart';
import 'package:openphon/src/data/database.dart';
import 'package:openphon/src/data/library_archive.dart';
import 'package:openphon/src/data/library_backup.dart';
import 'package:openphon/src/data/wav_import.dart';
import 'package:openphon/src/rust/api/core.dart' as rust;
import 'package:openphon/src/rust/frb_generated.dart';
import 'package:path/path.dart' as p;

import 'bridge_test.dart' show sineWav;

Future<WavProbe> _probeArchiveWav(String path) async {
  final info = await rust.wavInfo(path: path);
  return WavProbe(
    sampleRate: info.sampleRate,
    channels: info.channels,
    durationS: info.durationS,
  );
}

Future<void> _validateArchiveTextGrid(String path) async {
  await rust.readTextGrid(path: path);
}

Future<void> _validateArchivePitchEdits(String path) async {
  rust.parsePitchEdits(text: await File(path).readAsString());
}

Future<String> _measure(String wav, AnalysisSettings settings) async {
  final automatic = await rust.f0Track(
    path: wav,
    timeStepS: settings.trackTimeStepS,
    f0MinHz: settings.pitchFloorHz,
    f0MaxHz: settings.pitchCeilingHz,
  );
  final edits = await readPitchEdits(wav);
  expect(edits, isNotNull);
  expect(
    pitchEditsMatch(
      edits!,
      timeStepS: settings.trackTimeStepS,
      floorHz: settings.pitchFloorHz,
      ceilingHz: settings.pitchCeilingHz,
    ),
    isTrue,
  );
  final corrected = applyPitchEdits(automatic, edits);
  final doc = AnnotationDoc.fromTextGrid(
    await rust.readTextGrid(path: p.setExtension(wav, '.TextGrid')),
  );
  final tier = doc.tiers.single as IntervalTierModel;
  final rows = measureIntervals(
    tier,
    f0: corrected.track,
    f0Edited: corrected.edited,
    intensity: await rust.intensityTrack(
      path: wav,
      timeStepS: settings.trackTimeStepS,
      minPitchHz: settings.intensityMinPitchHz,
    ),
    formants: await rust.formantTrack(
      path: wav,
      timeStepS: settings.trackTimeStepS,
      maxFormants: settings.maxFormants,
      ceilingHz: settings.formantCeilingHz,
    ),
  );
  expect(rows.fold<int>(0, (count, row) => count + row.f0EditedFrames), 2);
  expect(rows.first.meanF0Hz, isNotNull);
  expect(rows.first.meanIntensityDb, isNotNull);
  return measurementsCsv(tier.name, rows, editedColumn: true);
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(RustLib.init);

  testWidgets(
    'native backup restore preserves edited measurements and all analysis settings',
    (tester) async {
      final directory = await Directory.systemTemp.createTemp(
        'openphon_native_restore_',
      );
      addTearDown(() => directory.delete(recursive: true));
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      const settings = AnalysisSettings(
        pitchFloorHz: 150,
        pitchCeilingHz: 500,
        trackTimeStepS: 0.02,
        formantCeilingHz: 5000,
        intensityMinPitchHz: 120,
        spectrogramWindowS: 0.01,
        dynamicRangeDb: 60,
      );
      final wav = await File(
        p.join(directory.path, 'source.wav'),
      ).writeAsBytes(sineWav(freqHz: 220, sampleRate: 16000, seconds: 1));
      final grid = p.setExtension(wav.path, '.TextGrid');
      final doc = AnnotationDoc(
        xmin: 0,
        xmax: 1,
        tiers: [
          IntervalTierModel(
            name: 'phones',
            intervals: [
              const Interval(0, 0.5, 'first\nline'),
              const Interval(0.5, 1, 'second'),
            ],
          ),
        ],
      );
      await rust.writeTextGrid(path: grid, data: doc.toTextGrid());
      final automatic = await rust.f0Track(
        path: wav.path,
        timeStepS: settings.trackTimeStepS,
        f0MinHz: settings.pitchFloorHz,
        f0MaxHz: settings.pitchCeilingHz,
      );
      final edits = rust.PitchEditsData(
        timeStepS: settings.trackTimeStepS,
        f0MinHz: settings.pitchFloorHz,
        f0MaxHz: settings.pitchCeilingHz,
        timesS: Float64List.fromList([
          automatic.timesS[3],
          automatic.timesS[4],
        ]),
        f0Hz: Float64List.fromList([0, 440]),
      );
      await writePitchEdits(wav.path, edits);
      final savedEdits = (await readPitchEdits(wav.path))!;
      final before = await _measure(wav.path, settings);
      final created = DateTime.parse('2026-10-14T15:23:45+02:00');
      final original = Recording(
        id: 10,
        name: 'Restored, labelled take',
        relativePath: 'source.wav',
        createdAt: created,
        sampleRate: 16000,
        channels: 1,
        durationMs: 1000,
        analysisSettingsJson: settings.toJson(),
      );
      final backup = File(p.join(directory.path, 'backup.zip'));
      await writeLibraryArchive(
        output: backup,
        items: [
          BackupItem(
            recording: original,
            wavPath: wav.path,
            gridPath: grid,
            editsPath: rust.pitchEditsPath(wavPath: wav.path),
            stem: 'take',
          ),
        ],
        defaultSettings: const AnalysisSettings(),
        softwareVersion: 'integration-test',
        probeWav: _probeArchiveWav,
        validateTextGrid: _validateArchiveTextGrid,
        validatePitchEdits: _validateArchivePitchEdits,
      );
      final validated = await validateLibraryArchive(
        input: backup,
        temporaryDirectory: directory,
        probeWav: _probeArchiveWav,
        validateTextGrid: _validateArchiveTextGrid,
        validatePitchEdits: _validateArchivePitchEdits,
      );
      addTearDown(validated.dispose);
      final library = await Directory(
        p.join(directory.path, 'isolated_library'),
      ).create();
      final sentinel = await File(
        p.join(library.path, 'keep.wav'),
      ).writeAsString('existing library file');
      expect(
        await restoreLibraryArchive(
          archive: validated,
          database: db,
          libraryDirectory: library,
        ),
        1,
      );
      final restored = (await db.watchLibrary().first).single;
      expect(restored.name, original.name);
      expect(restored.createdAt.isAtSameMomentAs(created), isTrue);
      expect(restored.analysisSettingsJson, settings.toJson());
      final restoredWav = p.join(library.path, restored.relativePath);
      expect(await File(restoredWav).readAsBytes(), await wav.readAsBytes());
      expect(await sentinel.readAsString(), 'existing library file');
      final restoredSettings = AnalysisSettings.fromJson(
        restored.analysisSettingsJson!,
        strict: true,
      );
      final after = await _measure(restoredWav, restoredSettings);
      expect(after, before);
      final restoredEdits = (await readPitchEdits(restoredWav))!;
      expect(restoredEdits.timesS, savedEdits.timesS);
      expect(restoredEdits.f0Hz, savedEdits.f0Hz);
      expect(
        await File(rust.pitchEditsPath(wavPath: restoredWav)).readAsBytes(),
        await File(rust.pitchEditsPath(wavPath: wav.path)).readAsBytes(),
      );
    },
  );

  testWidgets(
    'native backup validation rejects malformed sources before publishing',
    (tester) async {
      final directory = await Directory.systemTemp.createTemp(
        'openphon_native_backup_validation_',
      );
      addTearDown(() => directory.delete(recursive: true));
      final wav = File(p.join(directory.path, 'source.wav'));
      final grid = File(p.join(directory.path, 'source.TextGrid'));
      final pitch = File(p.join(directory.path, 'source.pitchedits.csv'));
      final backup = File(p.join(directory.path, 'existing.zip'));
      for (final problem in [
        'WAV',
        'TextGrid',
        'pitch corrections',
        'metadata',
      ]) {
        await wav.writeAsBytes(
          sineWav(freqHz: 220, sampleRate: 16000, seconds: 1),
        );
        if (problem == 'WAV') await wav.writeAsString('not a WAV');
        if (problem == 'TextGrid') await grid.writeAsString('not a TextGrid');
        if (problem == 'pitch corrections') {
          await pitch.writeAsString('not pitch corrections');
        }
        await backup.writeAsString('preserve earlier backup');
        final recording = Recording(
          id: 1,
          name: 'Rejected $problem',
          relativePath: 'source.wav',
          createdAt: DateTime.utc(2026),
          sampleRate: problem == 'metadata' ? 48000 : 16000,
          channels: 1,
          durationMs: 1000,
        );
        await expectLater(
          writeLibraryArchive(
            output: backup,
            items: [
              BackupItem(
                recording: recording,
                wavPath: wav.path,
                gridPath: problem == 'TextGrid' ? grid.path : null,
                editsPath: problem == 'pitch corrections' ? pitch.path : null,
                stem: 'source',
              ),
            ],
            defaultSettings: const AnalysisSettings(),
            softwareVersion: 'integration-test',
            probeWav: _probeArchiveWav,
            validateTextGrid: _validateArchiveTextGrid,
            validatePitchEdits: _validateArchivePitchEdits,
          ),
          throwsA(
            isA<FormatException>().having(
              (error) => error.message,
              'recording-specific validation error',
              contains(recording.name),
            ),
          ),
        );
        expect(await backup.readAsString(), 'preserve earlier backup');
        expect(directory.listSync().whereType<Directory>(), isEmpty);
      }
    },
  );
}
