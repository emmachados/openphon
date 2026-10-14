import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/material.dart' hide Interval;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:openphon/l10n/app_localizations.dart';
import 'package:openphon/src/analysis/analysis_controller.dart';
import 'package:openphon/src/analysis/analysis_settings.dart';
import 'package:openphon/src/analysis/analysis_track_loader.dart';
import 'package:openphon/src/annotation/annotation_model.dart';
import 'package:openphon/src/audio/recorder_service.dart' show libraryRoot;
import 'package:openphon/src/data/app_prefs.dart';
import 'package:openphon/src/data/database.dart';
import 'package:openphon/src/rust/api/core.dart' as rust;
import 'package:openphon/src/rust/frb_generated.dart';
import 'package:openphon/src/ui/analysis/analysis_view.dart';
import 'package:path/path.dart' as p;

import 'bridge_test.dart' show sineWav;

/// Hold one real native request to inspect export availability while loading.
class _DelayedPitch implements AnalysisTrackLoader {
  _DelayedPitch(this.source);
  final SoundAnalysisTrackLoader source;
  final result = Completer<rust.F0CandidatesData>();
  @override
  Future<rust.F0CandidatesData> pitch(AnalysisSettings settings) =>
      result.future;
  @override
  Future<rust.IntensityTrackData> intensity(AnalysisSettings settings) =>
      source.intensity(settings);
  @override
  Future<rust.FormantTrackData> formants(AnalysisSettings settings) =>
      source.formants(settings);
}

Future<void> _until(WidgetTester tester, bool Function() condition) async {
  for (var i = 0; i < 200 && !condition(); i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 25)),
    );
    await tester.pump();
  }
  expect(condition(), isTrue);
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(RustLib.init);

  testWidgets(
    'export waits for native tracks and shares matching CSV and metadata',
    (tester) async {
      final root = await libraryRoot();
      final directory = await root.createTemp('measurement_ui_');
      addTearDown(() => directory.delete(recursive: true));
      final wav = await File(
        p.join(directory.path, 'source.wav'),
      ).writeAsBytes(sineWav(freqHz: 220, sampleRate: 16000, seconds: 1));
      const settings = AnalysisSettings(
        pitchFloorHz: 100,
        pitchCeilingHz: 500,
        formantCeilingHz: 5000,
      );
      const doc = AnnotationDoc(
        xmin: 0,
        xmax: 1,
        tiers: [
          IntervalTierModel(
            name: 'phones',
            intervals: [Interval(0, 1, 'a\nb')],
          ),
        ],
      );
      await rust.writeTextGrid(
        path: p.setExtension(wav.path, '.TextGrid'),
        data: doc.toTextGrid(),
      );
      final native = await rust.Sound.load(path: wav.path);
      addTearDown(native.dispose);
      final delayed = _DelayedPitch(SoundAnalysisTrackLoader(native));
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      final recording = Recording(
        id: 1,
        name: 'Measurement test',
        relativePath: p.relative(wav.path, from: root.path),
        createdAt: DateTime.utc(2026),
        sampleRate: 16000,
        channels: 1,
        analysisSettingsJson: settings.toJson(),
      );
      final shared = Completer<Map<Object?, Object?>>();
      const channel = MethodChannel('dev.fluttercommunity.plus/share');
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
        call,
      ) async {
        shared.complete(call.arguments as Map<Object?, Object?>);
        return 'dev.fluttercommunity.plus/share/unavailable';
      });
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          channel,
          null,
        ),
      );
      late AnalysisController controller;
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: AnalysisView(
              recording: recording,
              db: db,
              prefs: AppPrefs(
                fileOverride: File(p.join(directory.path, 'prefs.json')),
              ),
              controllerFactory: (r) =>
                  controller = AnalysisController(r, trackLoader: delayed),
            ),
          ),
        ),
      );
      await _until(
        tester,
        () => controller.annotation != null && controller.tracksLoading,
      );
      await tester.tap(find.byTooltip('TextGrid'));
      await tester.pump(const Duration(milliseconds: 400));
      final item = find.ancestor(
        of: find.text('Export measurements…'),
        matching: find.byType(PopupMenuItem<String>),
      );
      expect(tester.widget<PopupMenuItem<String>>(item).enabled, isFalse);
      Navigator.of(tester.element(find.text('Export measurements…'))).pop();
      await tester.pump(const Duration(milliseconds: 400));
      delayed.result.complete(await delayed.source.pitch(settings));
      await _until(tester, () => controller.measurementsReady);
      await tester.tap(find.byTooltip('TextGrid'));
      await tester.pump(const Duration(milliseconds: 400));
      expect(tester.widget<PopupMenuItem<String>>(item).enabled, isTrue);
      await tester.tap(find.text('Export measurements…'));
      await _until(tester, () => shared.isCompleted);
      final arguments = await shared.future;
      final paths = (arguments['paths'] as List).cast<String>();
      expect(paths, hasLength(2));
      final csv = await File(
        paths.singleWhere((v) => v.endsWith('.csv')),
      ).readAsString();
      final report =
          jsonDecode(
                await File(
                  paths.singleWhere((v) => v.endsWith('.json')),
                ).readAsString(),
              )
              as Map;
      expect(csv, contains('"a\nb"'));
      expect(csv, contains('f0_frames,voiced_f0_frames,intensity_frames'));
      final metadata = (report['recordings'] as List).single as Map;
      expect(metadata['analysis_settings'], settings.toMap());
      expect(metadata['formant_analysis']['algorithm_revision'], 4);
      expect(
        metadata['formant_analysis']['resampling']['interior_accumulation'],
        'local_anchor_plus_weighted_sample_differences',
      );
      expect(
        metadata['formant_analysis']['root_solver']['failure_policy'],
        'Reject the complete root set; every formant is missing.',
      );
      expect(metadata['formant_analysis']['parameters']['window_s'], 0.025);
      expect(
        metadata['formant_analysis']['parameters']['max_bandwidth_hz'],
        400,
      );
      expect(report['recipe']['revision'], 2);
      expect(metadata['sources']['wav']['sha256'], hasLength(64));
      expect(metadata['annotation_snapshot']['intervals'][0]['label'], 'a\nb');
      expect(metadata['rows'], 1);
      expect(report['software']['version'], isNotEmpty);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    },
  );
}
