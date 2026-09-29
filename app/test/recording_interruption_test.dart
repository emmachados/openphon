import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openphon/main.dart';
import 'package:openphon/src/data/app_prefs.dart';
import 'package:openphon/src/data/database.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:record_platform_interface/record_platform_interface.dart';

class _Directories extends PathProviderPlatform {
  _Directories(this.path);
  final String path;
  @override
  Future<String> getApplicationSupportPath() async => path;
}

Uint8List _wav() {
  final bytes = Uint8List(44 + 8820);
  final data = ByteData.sublistView(bytes);
  void text(int offset, String value) =>
      bytes.setRange(offset, offset + value.length, value.codeUnits);
  text(0, 'RIFF');
  data.setUint32(4, bytes.length - 8, Endian.little);
  text(8, 'WAVEfmt ');
  data.setUint32(16, 16, Endian.little);
  data.setUint16(20, 1, Endian.little);
  data.setUint16(22, 1, Endian.little);
  data.setUint32(24, 44100, Endian.little);
  data.setUint32(28, 88200, Endian.little);
  data.setUint16(32, 2, Endian.little);
  data.setUint16(34, 16, Endian.little);
  text(36, 'data');
  data.setUint32(40, 8820, Endian.little);
  return bytes;
}

class _Recorder extends RecordPlatform {
  final states = StreamController<RecordState>.broadcast();
  String? path;
  Completer<void>? finishStart;
  bool failNextStop = false;
  bool recording = false;
  int starts = 0;
  int stops = 0;

  @override
  Future<void> create(String recorderId) async {}
  @override
  Future<void> dispose(String recorderId) async {}
  @override
  Stream<RecordState> onStateChanged(String recorderId) => states.stream;
  @override
  Future<bool> hasPermission(String recorderId, {bool request = true}) async =>
      true;
  @override
  Future<bool> isRecording(String recorderId) async => recording;
  @override
  Future<Amplitude> getAmplitude(String recorderId) async =>
      Amplitude(current: -40, max: -40);

  @override
  Future<void> start(
    String recorderId,
    RecordConfig config, {
    required String path,
  }) async {
    this.path = path;
    await File(path).writeAsBytes(_wav());
    starts++;
    recording = true;
    states.add(RecordState.record);
    await finishStart?.future;
  }

  @override
  Future<String?> stop(String recorderId) async {
    stops++;
    if (failNextStop) {
      failNextStop = false;
      throw StateError('temporary stop failure');
    }
    recording = false;
    states.add(RecordState.stop);
    return path;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Future<void> _until(WidgetTester tester, bool Function() condition) async {
  for (var i = 0; i < 100 && !condition(); i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump();
  }
  expect(condition(), isTrue);
}

void main() {
  late Directory directory;
  late AppDatabase db;
  late _Recorder recorder;
  late RecordPlatform previousRecorder;
  late PathProviderPlatform previousDirectories;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('openphon_interruption_');
    db = AppDatabase.forTesting(NativeDatabase.memory());
    previousRecorder = RecordPlatform.instance;
    previousDirectories = PathProviderPlatform.instance;
    RecordPlatform.instance = recorder = _Recorder();
    PathProviderPlatform.instance = _Directories(directory.path);
  });

  tearDown(() async {
    await recorder.states.close();
    RecordPlatform.instance = previousRecorder;
    PathProviderPlatform.instance = previousDirectories;
    await db.close();
    await directory.delete(recursive: true);
  });

  for (final duringStart in [false, true]) {
    testWidgets(
      'interruption ${duringStart ? 'during start' : 'during capture'} stays visible and the take can be saved',
      (tester) async {
        addTearDown(() async {
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.pump();
        });
        if (duringStart) recorder.finishStart = Completer<void>();
        await tester.pumpWidget(OpenphonApp(db: db, prefs: AppPrefs()));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Record'));
        await _until(tester, () => recorder.starts == 1);
        recorder.states.add(RecordState.pause);
        await tester.pump();
        recorder.finishStart?.complete();
        await _until(
          tester,
          () => find.text('Paused · Stop').evaluate().isNotEmpty,
        );
        expect(recorder.stops, 0);
        await tester.tap(find.text('Paused · Stop'));
        await _until(tester, () => find.text('Record').evaluate().isNotEmpty);
        await _until(
          tester,
          () => find.byTooltip('Recording actions').evaluate().length == 1,
        );
        expect(recorder.starts, 1);
        expect(recorder.stops, 1);
        expect(File(recorder.path!).readAsBytesSync(), _wav());
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'failed stop after interruption preserves the take and allows retry',
    (tester) async {
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
      });
      await tester.pumpWidget(OpenphonApp(db: db, prefs: AppPrefs()));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Record'));
      await _until(tester, () => recorder.starts == 1);
      recorder.states.add(RecordState.pause);
      await _until(
        tester,
        () => find.text('Paused · Stop').evaluate().isNotEmpty,
      );
      recorder.failNextStop = true;
      await tester.tap(find.text('Paused · Stop'));
      await tester.pumpAndSettle();
      expect(find.textContaining('temporary stop failure'), findsOneWidget);
      expect(find.text('Paused · Stop'), findsOneWidget);
      expect(File(recorder.path!).readAsBytesSync(), _wav());
      await tester.tap(find.text('Paused · Stop'));
      await _until(tester, () => find.text('Record').evaluate().isNotEmpty);
      await _until(
        tester,
        () => find.byTooltip('Recording actions').evaluate().length == 1,
      );
      expect(recorder.starts, 1);
      expect(recorder.stops, 2);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
  );
}
