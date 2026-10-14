import 'dart:async';
import 'dart:typed_data';

import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';
import 'package:openphon/src/analysis/analysis_controller.dart';
import 'package:openphon/src/analysis/analysis_settings.dart';
import 'package:openphon/src/analysis/analysis_track_loader.dart';
import 'package:openphon/src/data/database.dart';
import 'package:openphon/src/rust/api/core.dart' as rust;

rust.F0CandidatesData pitch(double hz) => rust.F0CandidatesData(
  timesS: Float64List.fromList([0.05]),
  f0Hz: Float64List.fromList([hz]),
  candidatesHz: Float64List.fromList([hz]),
  maxCandidates: 1,
);

class _Loader implements AnalysisTrackLoader {
  final requests =
      <
        ({AnalysisSettings settings, Completer<rust.F0CandidatesData> result})
      >[];
  bool failIntensity = false;

  @override
  Future<rust.F0CandidatesData> pitch(AnalysisSettings settings) {
    final result = Completer<rust.F0CandidatesData>();
    requests.add((settings: settings, result: result));
    return result.future;
  }

  @override
  Future<rust.IntensityTrackData> intensity(AnalysisSettings settings) async {
    if (failIntensity) throw StateError('intensity failed');
    return rust.IntensityTrackData(
      timesS: Float64List.fromList([0.05]),
      db: Float64List.fromList([0]),
    );
  }

  @override
  Future<rust.FormantTrackData> formants(AnalysisSettings settings) async =>
      rust.FormantTrackData(
        timesS: Float64List.fromList([0.05]),
        maxFormants: 3,
        formantsHz: Float64List.fromList([500, 1500, 2500]),
        bandwidthsHz: Float64List.fromList([100, 100, 100]),
      );
}

final recording = Recording(
  id: 1,
  name: 'test',
  relativePath: 'test.wav',
  createdAt: DateTime(2026),
  sampleRate: 44100,
  channels: 1,
);

void main() {
  test(
    'corrupt stored settings block export until explicitly replaced',
    () async {
      final loader = _Loader();
      final bad = recording.copyWith(
        analysisSettingsJson: const Value('bad json'),
      );
      final c = AnalysisController(bad, trackLoader: loader);
      addTearDown(c.dispose);
      final loading = c.loadTracks();
      loader.requests.last.result.complete(pitch(200));
      await loading;
      expect(c.settingsReadError, isA<FormatException>());
      expect(c.measurementsReady, isFalse);
      await c.applySettings(const AnalysisSettings());
      expect(c.settingsReadError, isNull);
      expect(c.measurementsReady, isTrue);
    },
  );
  test(
    'exports require every track; failures survive until a successful retry',
    () async {
      final loader = _Loader()..failIntensity = true;
      final c = AnalysisController(recording, trackLoader: loader);
      addTearDown(c.dispose);
      expect(c.measurementsReady, isFalse);
      final first = c.loadTracks();
      expect(c.tracksLoading, isTrue);
      expect(c.measurementsReady, isFalse);
      loader.requests.single.result.complete(pitch(200));
      await first;
      expect(c.tracksLoading, isFalse);
      expect(
        c.trackErrors[AnalysisTrackKind.intensity].toString(),
        contains('intensity failed'),
      );
      expect(c.measurementsReady, isFalse);
      loader.failIntensity = false;
      final second = c.loadTracks();
      loader.requests.last.result.complete(pitch(200));
      await second;
      expect(c.trackErrors, isEmpty);
      expect(c.measurementsReady, isTrue);
    },
  );

  test(
    'old results cannot replace a newer track or its pitch-edit settings',
    () async {
      final loader = _Loader();
      final c = AnalysisController(recording, trackLoader: loader);
      addTearDown(c.dispose);
      final first = c.loadTracks();
      final next = c.applySettings(c.settings.copyWith(pitchFloorHz: 100));
      expect(loader.requests.map((r) => r.settings.pitchFloorHz), [75, 100]);
      loader.requests.last.result.complete(pitch(220));
      await next;
      expect(c.f0Track!.f0Hz, [220]);
      expect(c.pitchEditor!.floorHz, 100);
      loader.requests.first.result.complete(pitch(110));
      await first;
      expect(c.f0Track!.f0Hz, [220]);
      expect(c.pitchEditor!.floorHz, 100);
      expect(c.measurementsReady, isTrue);
    },
  );

  test(
    'superseded errors cannot mark a successful current analysis failed',
    () async {
      final loader = _Loader();
      final c = AnalysisController(recording, trackLoader: loader);
      addTearDown(c.dispose);
      final first = c.loadTracks();
      final second = c.applySettings(c.settings.copyWith(pitchCeilingHz: 500));
      loader.requests.last.result.complete(pitch(220));
      await second;
      loader.requests.first.result.completeError(
        StateError('obsolete request'),
      );
      await first;
      expect(c.trackErrors, isEmpty);
      expect(c.measurementsReady, isTrue);
    },
  );

  test(
    'saved pitch corrections at other settings block reports and exports',
    () async {
      final loader = _Loader();
      final c = AnalysisController(recording, trackLoader: loader);
      addTearDown(c.dispose);
      c.storedPitchEdits = rust.PitchEditsData(
        timeStepS: 0.01,
        f0MinHz: 100,
        f0MaxHz: 500,
        timesS: Float64List.fromList([0.05]),
        f0Hz: Float64List.fromList([300]),
      );
      final first = c.loadTracks();
      loader.requests.first.result.complete(pitch(200));
      await first;
      expect(c.pitchEditsMismatch, isTrue);
      expect(c.pitchReady, isFalse);
      expect(c.measurementsReady, isFalse);
      final restore = c.restorePitchSettings();
      loader.requests.last.result.complete(pitch(200));
      await restore;
      expect(c.measurementsReady, isTrue);
      expect(c.f0Track!.f0Hz, [300]);
    },
  );

  test(
    'settings writes are ordered and a failed write can be retried',
    () async {
      final pending = Completer<void>();
      final written = <AnalysisSettings>[];
      var fail = false;
      final c = AnalysisController(
        recording,
        onSaveSettings: (id, json) async {
          written.add(AnalysisSettings.fromJson(json));
          if (written.length == 1) await pending.future;
          if (fail) throw StateError('storage full');
        },
      );
      addTearDown(c.dispose);
      final first = c.applySettings(c.settings.copyWith(pitchFloorHz: 100));
      final second = c.applySettings(c.settings.copyWith(pitchFloorHz: 120));
      await Future<void>.delayed(Duration.zero);
      expect(written.map((s) => s.pitchFloorHz), [100]);
      pending.complete();
      await Future.wait([first, second]);
      expect(written.map((s) => s.pitchFloorHz), [100, 120]);
      fail = true;
      await c.applySettings(c.settings.copyWith(pitchFloorHz: 140));
      expect(c.settingsSaveError.toString(), contains('storage full'));
      fail = false;
      await c.retrySettingsSave();
      expect(c.settingsSaveError, isNull);
      expect(written.last.pitchFloorHz, 140);
    },
  );

  test('invalid settings never reach the analysis source', () async {
    final loader = _Loader();
    final c = AnalysisController(recording, trackLoader: loader);
    addTearDown(c.dispose);
    await expectLater(
      c.applySettings(
        c.settings.copyWith(pitchFloorHz: 600, pitchCeilingHz: 300),
      ),
      throwsFormatException,
    );
    expect(loader.requests, isEmpty);
    expect(c.settings.pitchFloorHz, 75);
  });
}
