import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter/gestures.dart' show kDoubleTapTimeout;
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:openphon/l10n/app_localizations.dart';
import 'package:openphon/src/analysis/analysis_controller.dart';
import 'package:openphon/src/audio/recorder_service.dart' show libraryRoot;
import 'package:openphon/src/data/app_prefs.dart';
import 'package:openphon/src/data/database.dart';
import 'package:openphon/src/rust/api/core.dart' as rust;
import 'package:openphon/src/rust/frb_generated.dart';
import 'package:openphon/src/ui/analysis/analysis_view.dart';
import 'package:openphon/src/ui/analysis/spectrogram_view.dart';
import 'package:path/path.dart' as p;

/// 16-bit mono WAV of a band-limited 150 Hz harmonic complex. Each frame
/// offers the true period and its multiples as candidates. (A pulse train
/// built without band-limiting is not usable here: at 16 kHz its 150 Hz
/// period is not a whole number of samples, and the sampled waveform only
/// repeats exactly every third period.)
Uint8List harmonicWav({required int sampleRate, required double seconds}) {
  final n = (sampleRate * seconds).round();
  final v = Float64List(n);
  for (var k = 1; k * 150 < 0.45 * sampleRate; k++) {
    final gain = math.exp(-math.pow((k * 150 - 700) / 900, 2)) / k;
    for (var i = 0; i < n; i++) {
      v[i] += gain * math.cos(2 * math.pi * k * 150 * i / sampleRate);
    }
  }
  final peak = v.fold<double>(0, (m, x) => math.max(m, x.abs()));
  final samples = ByteData(n * 2);
  for (var i = 0; i < n; i++) {
    samples.setInt16(2 * i, (0.5 * v[i] / peak * 32767).round(), Endian.little);
  }
  final b = BytesBuilder();
  void u32(int v) =>
      b.add(Uint8List(4)..buffer.asByteData().setUint32(0, v, Endian.little));
  void u16(int v) =>
      b.add(Uint8List(2)..buffer.asByteData().setUint16(0, v, Endian.little));
  b.add('RIFF'.codeUnits);
  u32(36 + n * 2);
  b.add('WAVEfmt '.codeUnits);
  u32(16);
  u16(1);
  u16(1);
  u32(sampleRate);
  u32(sampleRate * 2);
  u16(2);
  u16(16);
  b.add('data'.codeUnits);
  u32(n * 2);
  b.add(samples.buffer.asUint8List());
  return b.toBytes();
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(RustLib.init);

  testWidgets('pitch edits are made by touch, saved beside the WAV and '
      'reapplied on reopening', (tester) async {
    final root = await libraryRoot();
    final rel = p.join('recordings', 'pitch_edit_test.wav');
    final wav = File(p.join(root.path, rel));
    await wav.parent.create(recursive: true);
    await wav.writeAsBytes(harmonicWav(sampleRate: 16000, seconds: 1));
    final sidecar = File(rust.pitchEditsPath(wavPath: wav.path));
    if (await sidecar.exists()) await sidecar.delete();
    addTearDown(() async {
      if (await wav.exists()) await wav.delete();
      if (await sidecar.exists()) await sidecar.delete();
    });

    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final prefsDir = await Directory.systemTemp.createTemp('openphon_prefs_');
    addTearDown(() => prefsDir.delete(recursive: true));
    final prefs = AppPrefs(fileOverride: File(p.join(prefsDir.path, 'p.json')));
    final recording = Recording(
      id: 1,
      name: 'pitch edit test',
      relativePath: rel,
      createdAt: DateTime(2026),
      sampleRate: 16000,
      channels: 1,
    );

    late AnalysisController c;
    Future<void> open() async {
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: const [
            AppLocalizations.delegate,
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: AnalysisView(
              key: UniqueKey(),
              recording: recording,
              db: db,
              prefs: prefs,
              controllerFactory: (r) => c = AnalysisController(r),
            ),
          ),
        ),
      );
      for (var i = 0; i < 100 && c.f0Candidates == null; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 50)),
        );
        await tester.pump();
      }
      expect(c.f0Candidates, isNotNull);
    }

    await open();
    expect(c.pitchEditor!.isEmpty, isTrue);
    final auto = c.f0Candidates!;
    final mid = auto.timesS.length ~/ 2;
    expect(auto.f0Hz[mid], closeTo(150, 2));
    final sub = auto.candidatesHz
        .sublist(mid * auto.maxCandidates, (mid + 1) * auto.maxCandidates)
        .firstWhere((f) => f > 0 && (f - auto.f0Hz[mid]).abs() > 10);

    // Edit mode through the toolbar, then zoom so candidates are drawn.
    await tester.tap(find.byTooltip('Edit pitch'));
    await tester.pump();
    expect(c.pitchEditMode, isTrue);
    c.setViewport(auto.timesS[mid] - 0.1, auto.timesS[mid] + 0.1);
    await tester.pump();

    // Tap an alternative candidate of the middle frame where it is drawn.
    final plot = tester.getRect(find.byType(SpectrogramView));
    final plotWidth = plot.width - kFreqAxisWidth;
    final plotHeight = plot.height - kTimeAxisHeight;
    final frac = (sub - c.pitchFloorHz) / (c.pitchCeilingHz - c.pitchFloorHz);
    final x =
        plot.left +
        kFreqAxisWidth +
        (auto.timesS[mid] - c.viewport.t0) / c.viewport.span * plotWidth;
    final y = plot.top + (1 - frac) * plotHeight;
    await tester.tapAt(Offset(x, y));
    // The viewport also recognises double taps, so a single tap resolves
    // only after the double-tap timeout.
    await tester.pump(kDoubleTapTimeout + const Duration(milliseconds: 50));
    expect(c.pitchEditor!.valueAt(mid), sub);
    expect(c.f0Track!.f0Hz[mid], sub);

    // Octave down over a selection, through the edit bar.
    c.setSelection(TimeSelection(auto.timesS[mid + 5], auto.timesS[mid + 10]));
    await tester.pump();
    await tester.tap(find.byTooltip('Octave down (selection)'));
    await tester.pump();
    for (var i = mid + 5; i < mid + 10; i++) {
      expect(c.f0Track!.f0Hz[i], closeTo(75, 3));
    }
    expect(c.pitchEditor!.editedCount, 6);
    await tester.runAsync(() => c.pitchEditsSaved);

    final stored = rust.parsePitchEdits(text: await sidecar.readAsString());
    expect(stored.timesS.length, 6);
    expect(stored.f0MinHz, c.pitchFloorHz);

    // Undo once from the bar: the octave step goes, the tap stays.
    await tester.tap(find.byTooltip('Undo (Ctrl+Z)').last);
    await tester.pump();
    expect(c.pitchEditor!.editedCount, 1);
    await tester.runAsync(() => c.pitchEditsSaved);

    // Reopen: the saved correction is applied to the fresh track.
    await open();
    expect(c.pitchEditor!.editedCount, 1);
    expect(c.f0Track!.f0Hz[mid], closeTo(sub, 1e-3));
    expect(c.f0EditedMask![mid], isTrue);
  });
}
