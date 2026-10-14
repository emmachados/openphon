import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:openphon/src/analysis/analysis_controller.dart';
import 'package:openphon/src/analysis/analysis_settings.dart';
import 'package:openphon/src/analysis/analysis_track_loader.dart';
import 'package:openphon/src/data/database.dart';
import 'package:openphon/src/rust/api/core.dart' as rust;
import 'package:openphon/src/rust/frb_generated.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

class _Directories extends PathProviderPlatform {
  _Directories(this.path);
  final String path;
  @override
  Future<String> getApplicationSupportPath() async => path;
}

/// Resolve the controller's source path normally without loading a native
/// sound. The injected track loader supplies the analysis used by these tests.
class _UnavailableSound extends RustLibApi {
  @override
  Future<rust.Sound> crateApiCoreSoundLoad({required String path}) async =>
      throw StateError('Native sound loading is not used in this test.');

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Loader implements AnalysisTrackLoader {
  final pitchRequests = <AnalysisSettings>[];

  @override
  Future<rust.F0CandidatesData> pitch(AnalysisSettings settings) async {
    pitchRequests.add(settings);
    final hz = settings.pitchFloorHz * 2;
    return rust.F0CandidatesData(
      timesS: Float64List.fromList([0.05]),
      f0Hz: Float64List.fromList([hz]),
      candidatesHz: Float64List.fromList([hz]),
      maxCandidates: 1,
    );
  }

  @override
  Future<rust.IntensityTrackData> intensity(AnalysisSettings settings) async =>
      rust.IntensityTrackData(
        timesS: Float64List.fromList([0.05]),
        db: Float64List.fromList([60]),
      );

  @override
  Future<rust.FormantTrackData> formants(AnalysisSettings settings) async =>
      rust.FormantTrackData(
        timesS: Float64List.fromList([0.05]),
        maxFormants: 3,
        formantsHz: Float64List.fromList([500, 1500, 2500]),
        bandwidthsHz: Float64List.fromList([80, 80, 80]),
      );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late PathProviderPlatform originalDirectories;

  setUpAll(() => RustLib.initMock(api: _UnavailableSound()));
  tearDownAll(RustLib.dispose);

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('openphon-discard-');
    originalDirectories = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _Directories(directory.path);
  });

  tearDown(() async {
    PathProviderPlatform.instance = originalDirectories;
    await directory.delete(recursive: true);
  });

  Future<AnalysisController> controller(
    _Loader loader,
    Future<void> Function(String, rust.PitchEditsData?) write,
  ) async {
    final c = AnalysisController(
      Recording(
        id: 1,
        name: 'test',
        relativePath: 'test.wav',
        createdAt: DateTime(2026),
        sampleRate: 16000,
        channels: 1,
      ),
      trackLoader: loader,
      writePitchEdits: write,
    );
    addTearDown(c.dispose);
    await c.open();
    expect(c.absolutePath, isNotNull);
    await c.loadTracks();
    c.setSelection(const TimeSelection(0, 0.1));
    return c;
  }

  test('discard waits for writes and reloads the newest settings', () async {
    final writeFinished = Completer<void>();
    final deletionStarted = Completer<void>();
    final deletionFinished = Completer<void>();
    final writes = <rust.PitchEditsData?>[];
    final loader = _Loader();
    final c = await controller(loader, (_, data) async {
      writes.add(data);
      if (data != null) {
        await writeFinished.future;
      } else {
        deletionStarted.complete();
        await deletionFinished.future;
      }
    });
    expect(c.pitchUnvoice(), isTrue);
    final discarding = c.discardStoredPitchEdits();
    expect(c.pitchUnvoice(), isFalse);
    expect(c.pitchReady, isFalse);
    await c.retryPitchEditsSave();
    await c.discardStoredPitchEdits();
    await c.applySettings(c.settings.copyWith(pitchFloorHz: 100));
    writeFinished.complete();
    await deletionStarted.future;
    expect(writes, hasLength(2));
    expect(writes.last, isNull);
    deletionFinished.complete();
    await discarding;
    expect(c.storedPitchEdits, isNull);
    expect(c.f0Track!.f0Hz, [200]);
    expect(c.pitchEditor!.floorHz, 100);
    expect(loader.pitchRequests.last.pitchFloorHz, 100);
    expect(c.pitchReady, isTrue);
    expect(c.pitchEditor!.isEmpty, isTrue);
  });

  test('failed deletion keeps corrections and allows retry', () async {
    var fail = true;
    final c = await controller(_Loader(), (_, data) async {
      if (data == null && fail) throw StateError('Deletion failed.');
    });
    expect(c.pitchUnvoice(), isTrue);
    await c.pitchEditsSaved;
    final stored = c.storedPitchEdits;
    await c.discardStoredPitchEdits();
    expect(c.storedPitchEdits, same(stored));
    expect(c.f0Track!.f0Hz, [0]);
    expect(c.pitchEditsError, isA<StateError>());
    fail = false;
    await c.discardStoredPitchEdits();
    expect(c.storedPitchEdits, isNull);
    expect(c.pitchEditsError, isNull);
    expect(c.f0Track!.f0Hz, [150]);
  });
}
