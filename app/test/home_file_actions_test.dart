import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:file_selector_platform_interface/file_selector_platform_interface.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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
  @override
  Future<String> getTemporaryPath() async => path;
}

class _Recorder extends RecordPlatform {
  @override
  Future<void> create(String recorderId) async {}
  @override
  Future<void> dispose(String recorderId) async {}
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _UnavailablePicker extends FileSelectorPlatform {
  @override
  Future<List<XFile>> openFiles({
    List<XTypeGroup>? acceptedTypeGroups,
    String? initialDirectory,
    String? confirmButtonText,
  }) async => throw PlatformException(code: 'provider_unavailable');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory tmp;
  late AppDatabase db;
  late PathProviderPlatform originalDirectories;
  late RecordPlatform originalRecorder;
  late FileSelectorPlatform originalPicker;
  const shareChannel = MethodChannel('dev.fluttercommunity.plus/share');

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('openphon_home_test_');
    db = AppDatabase.forTesting(NativeDatabase.memory());
    originalDirectories = PathProviderPlatform.instance;
    originalRecorder = RecordPlatform.instance;
    originalPicker = FileSelectorPlatform.instance;
    PathProviderPlatform.instance = _Directories(tmp.path);
    RecordPlatform.instance = _Recorder();
    FileSelectorPlatform.instance = _UnavailablePicker();
  });

  tearDown(() async {
    debugDefaultTargetPlatformOverride = null;
    PathProviderPlatform.instance = originalDirectories;
    RecordPlatform.instance = originalRecorder;
    FileSelectorPlatform.instance = originalPicker;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(shareChannel, null);
    await db.close();
    await tmp.delete(recursive: true);
  });

  for (final platform in [TargetPlatform.iOS, TargetPlatform.android]) {
    testWidgets('$platform library export shares a paired WAV and TextGrid', (
      tester,
    ) async {
      debugDefaultTargetPlatformOverride = platform;
      final shared = Completer<Map<Object?, Object?>>();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(shareChannel, (call) async {
            shared.complete(call.arguments as Map<Object?, Object?>);
            return 'dev.fluttercommunity.plus/share/unavailable';
          });
      await tester.runAsync(() async {
        await Directory('${tmp.path}/recordings').create();
        await File('${tmp.path}/recordings/source.wav').writeAsString('audio');
        await File(
          '${tmp.path}/recordings/source.TextGrid',
        ).writeAsString('grid');
        await db.addRecording(
          RecordingsCompanion.insert(
            name: 'Take 10:30',
            relativePath: 'recordings/source.wav',
            createdAt: DateTime(2026),
            sampleRate: 44100,
          ),
        );
      });
      await tester.pumpWidget(OpenphonApp(db: db, prefs: AppPrefs()));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Recording actions'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Export WAV + TextGrid…'));
      await tester.pumpAndSettle();
      for (var i = 0; i < 100 && !shared.isCompleted; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
        await tester.pump();
      }
      expect(
        shared.isCompleted,
        isTrue,
        reason: tester
            .widgetList<Text>(find.byType(Text))
            .map((w) => w.data)
            .join(' | '),
      );
      final arguments = await shared.future;
      await tester.pumpAndSettle();
      final paths = (arguments['paths'] as List).cast<String>();
      expect(paths, hasLength(2));
      expect(paths[0], endsWith('/Take 10-30.wav'));
      expect(paths[1], endsWith('/Take 10-30.TextGrid'));
      expect(File(paths[0]).readAsStringSync(), 'audio');
      expect(File(paths[1]).readAsStringSync(), 'grid');
      expect(arguments['originWidth'], greaterThan(0));
      expect(arguments['originHeight'], greaterThan(0));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      debugDefaultTargetPlatformOverride = null;
    });
  }

  testWidgets('a failed import picker shows a recoverable error', (
    tester,
  ) async {
    await tester.pumpWidget(OpenphonApp(db: db, prefs: AppPrefs()));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Import audio'));
    await tester.pumpAndSettle();
    expect(find.textContaining('provider_unavailable'), findsOneWidget);
    expect(find.byTooltip('Import audio'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });

  testWidgets('restore is available and reports picker failure', (
    tester,
  ) async {
    await tester.pumpWidget(OpenphonApp(db: db, prefs: AppPrefs()));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(PopupMenuButton<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Restore library backup…'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Restore failed: '), findsOneWidget);
    expect(find.textContaining('provider_unavailable'), findsOneWidget);
    expect(await tester.runAsync(() => db.watchLibrary().first), isEmpty);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });

  testWidgets('library export reports exclusions and includes metadata', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    final shared = Completer<Map<Object?, Object?>>();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(shareChannel, (call) async {
          shared.complete(call.arguments as Map<Object?, Object?>);
          return 'dev.fluttercommunity.plus/share/unavailable';
        });
    await tester.runAsync(() async {
      await Directory('${tmp.path}/recordings').create();
      await File('${tmp.path}/recordings/source.wav').writeAsString('audio');
      await db.addRecording(
        RecordingsCompanion.insert(
          name: 'Unannotated take',
          relativePath: 'recordings/source.wav',
          createdAt: DateTime(2026),
          sampleRate: 44100,
        ),
      );
      await File('${tmp.path}/recordings/invalid.wav').writeAsString('audio');
      final invalidId = await db.addRecording(
        RecordingsCompanion.insert(
          name: 'Invalid settings take',
          relativePath: 'recordings/invalid.wav',
          createdAt: DateTime(2026),
          sampleRate: 44100,
        ),
      );
      await db.updateAnalysisSettings(invalidId, '{"pitchFloorHz": -1}');
    });
    await tester.pumpWidget(OpenphonApp(db: db, prefs: AppPrefs()));
    await tester.pumpAndSettle();
    await tester.tap(
      find.descendant(
        of: find.byType(AppBar),
        matching: find.byType(PopupMenuButton<String>),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Export measurements (library)'));
    for (
      var i = 0;
      i < 100 && find.text('Library measurement report').evaluate().isEmpty;
      i++
    ) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(find.text('Library measurement report'), findsOneWidget);
    expect(
      find.textContaining('Unannotated take: No saved TextGrid'),
      findsOneWidget,
    );
    expect(
      find.textContaining('0 rows from 0 recordings; 2 recordings excluded'),
      findsOneWidget,
    );
    await tester.tap(find.text('Export results'));
    for (var i = 0; i < 100 && !shared.isCompleted; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(shared.isCompleted, isTrue);
    final arguments = await shared.future;
    final paths = (arguments['paths'] as List).cast<String>();
    expect(paths, hasLength(2));
    final metadata =
        jsonDecode(
              File(
                paths.singleWhere((path) => path.endsWith('.json')),
              ).readAsStringSync(),
            )
            as Map<String, dynamic>;
    final records = (metadata['recordings'] as List)
        .cast<Map<String, dynamic>>();
    final record = records.singleWhere(
      (r) => r['display_name'] == 'Unannotated take',
    );
    expect(record['status'], 'no_textgrid');
    expect(record['display_name'], 'Unannotated take');
    expect(record['sources']['wav']['sha256'], hasLength(64));
    final invalid = records.singleWhere(
      (r) => r['display_name'] == 'Invalid settings take',
    );
    expect(invalid['status'], 'error');
    expect(invalid['analysis_settings'], isNull);
    expect(invalid['formant_analysis'], isNull);
    expect(invalid['stored_analysis_settings_json'], '{"pitchFloorHz": -1}');
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    debugDefaultTargetPlatformOverride = null;
  });
}
