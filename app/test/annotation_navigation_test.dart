import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openphon/l10n/app_localizations.dart';
import 'package:openphon/src/analysis/analysis_controller.dart';
import 'package:openphon/src/data/app_prefs.dart';
import 'package:openphon/src/data/database.dart';
import 'package:openphon/src/ui/analysis/analysis_view.dart';
import 'package:openphon/src/ui/home_page.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:record_platform_interface/record_platform_interface.dart';

class _Directories extends PathProviderPlatform {
  _Directories(this.path);
  final String path;
  @override
  Future<String> getApplicationSupportPath() async => path;
}

class _Recorder extends RecordPlatform {
  @override
  Future<void> create(String recorderId) async {}
  @override
  Future<void> dispose(String recorderId) async {}
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Analysis extends AnalysisController {
  _Analysis(super.recording, {required super.writeAnnotation}) {
    durationS = 1;
    annotationPath = 'test.TextGrid';
    newAnnotation();
    // Navigation must protect edits even when an analysis error is displayed.
    error = StateError('analysis unavailable');
  }
  bool disposed = false;
  @override
  Future<void> open() async {}
  @override
  void dispose() {
    disposed = true;
    super.dispose();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory tmp;
  late AppDatabase db;
  late PathProviderPlatform directories;
  late RecordPlatform recorder;
  late List<_Analysis> opened;
  late int saves;
  late bool failSave;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('openphon_navigation_');
    db = AppDatabase.forTesting(NativeDatabase.memory());
    directories = PathProviderPlatform.instance;
    recorder = RecordPlatform.instance;
    PathProviderPlatform.instance = _Directories(tmp.path);
    RecordPlatform.instance = _Recorder();
    opened = [];
    saves = 0;
    failSave = false;
    for (final name in ['First recording', 'Second recording']) {
      await db.addRecording(
        RecordingsCompanion.insert(
          name: name,
          relativePath: '$name.wav',
          createdAt: DateTime(2026),
          sampleRate: 44100,
        ),
      );
    }
  });

  tearDown(() async {
    PathProviderPlatform.instance = directories;
    RecordPlatform.instance = recorder;
    await db.close();
    await tmp.delete(recursive: true);
  });

  Future<void> start(WidgetTester tester, Size size) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = size;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: HomePage(
          db: db,
          prefs: AppPrefs(),
          controllerFactory: (recording) {
            final c = _Analysis(
              recording,
              writeAnnotation: ({required path, required data}) async {
                saves++;
                if (failSave) throw StateError('disk full');
              },
            );
            opened.add(c);
            return c;
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('First recording'));
    await tester.pumpAndSettle();
    expect(find.byType(AnalysisView), findsOneWidget);
  }

  Future<void> finish(WidgetTester tester) async {
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  }

  testWidgets('back can cancel, and discard closes without saving', (
    tester,
  ) async {
    await start(tester, const Size(600, 900));
    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    expect(find.text('Save annotation changes?'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(opened.single.disposed, isFalse);
    expect(opened.single.annotation!.dirty, isTrue);
    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Discard'));
    await tester.pumpAndSettle();
    expect(find.byType(AnalysisView), findsNothing);
    expect(opened.single.disposed, isTrue);
    expect(saves, 0);
    await finish(tester);
  });

  testWidgets('failed save blocks leaving and a successful retry closes', (
    tester,
  ) async {
    await start(tester, const Size(600, 900));
    failSave = true;
    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(find.textContaining('disk full'), findsOneWidget);
    expect(opened.single.disposed, isFalse);
    expect(opened.single.annotation!.dirty, isTrue);
    failSave = false;
    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(saves, 2);
    expect(opened.single.annotation!.dirty, isFalse);
    expect(find.byType(AnalysisView), findsNothing);
    await finish(tester);
  });

  testWidgets('switching tablet recordings requires a decision', (
    tester,
  ) async {
    await start(tester, const Size(1100, 900));
    await tester.tap(find.text('Second recording'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(opened, hasLength(1));
    await tester.tap(find.text('Second recording'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(opened, hasLength(2));
    expect(opened.first.disposed, isTrue);
    expect(opened.last.recording.name, 'Second recording');
    expect(saves, 1);
    await finish(tester);
  });

  testWidgets('resizing retains the same editor and system back is guarded', (
    tester,
  ) async {
    await start(tester, const Size(1100, 900));
    expect(find.text('Second recording'), findsOneWidget);
    final state = tester.state(find.byType(AnalysisView));
    tester.view.physicalSize = const Size(600, 900);
    await tester.pumpAndSettle();
    expect(tester.state(find.byType(AnalysisView)), same(state));
    expect(opened, hasLength(1));
    expect(find.text('Second recording'), findsNothing);
    expect(opened.single.disposed, isFalse);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('Save annotation changes?'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    tester.view.physicalSize = const Size(1100, 900);
    await tester.pumpAndSettle();
    expect(tester.state(find.byType(AnalysisView)), same(state));
    await finish(tester);
  });
}
