import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:openphon/src/rust/api/core.dart' as rust_core;
import 'package:openphon/src/rust/frb_generated.dart';

/// Minimal 16-bit PCM mono WAV writer for test fixtures.
Uint8List sineWav({
  required double freqHz,
  required int sampleRate,
  required double seconds,
}) {
  final n = (sampleRate * seconds).round();
  final dataLen = n * 2;
  final b = BytesBuilder();
  void u32(int v) => b.add(Uint8List(4)..buffer.asByteData().setUint32(0, v, Endian.little));
  void u16(int v) => b.add(Uint8List(2)..buffer.asByteData().setUint16(0, v, Endian.little));
  b.add('RIFF'.codeUnits);
  u32(36 + dataLen);
  b.add('WAVE'.codeUnits);
  b.add('fmt '.codeUnits);
  u32(16);
  u16(1); // PCM
  u16(1); // mono
  u32(sampleRate);
  u32(sampleRate * 2);
  u16(2);
  u16(16);
  b.add('data'.codeUnits);
  u32(dataLen);
  final samples = ByteData(dataLen);
  for (var i = 0; i < n; i++) {
    final v = 0.5 * math.sin(2 * math.pi * freqHz * i / sampleRate);
    samples.setInt16(2 * i, (v * 32767).round(), Endian.little);
  }
  b.add(samples.buffer.asUint8List());
  return b.toBytes();
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async => await RustLib.init());

  testWidgets('Rust core is reachable over the bridge', (tester) async {
    expect(rust_core.coreVersion(), matches(RegExp(r'^\d+\.\d+\.\d+$')));
    expect(rust_core.echo(input: 'openphon'), 'openphon');
  });

  testWidgets('DSP analyses run over the bridge on a real file',
      (tester) async {
    final dir = await Directory.systemTemp.createTemp('openphon_test');
    final path = '${dir.path}${Platform.pathSeparator}sine220.wav';
    await File(path).writeAsBytes(
      sineWav(freqHz: 220, sampleRate: 44100, seconds: 1.0),
    );

    final info = await rust_core.wavInfo(path: path);
    expect(info.sampleRate, 44100);
    expect(info.channels, 1);
    expect(info.durationS, closeTo(1.0, 0.001));

    final f0 = await rust_core.f0Track(
      path: path,
      timeStepS: 0.01,
      f0MinHz: 75,
      f0MaxHz: 600,
    );
    final voiced = f0.f0Hz.where((f) => f > 0).toList();
    expect(voiced.length / f0.f0Hz.length, greaterThan(0.9));
    expect(voiced[voiced.length ~/ 2], closeTo(220, 0.5));

    final intensity = await rust_core.intensityTrack(
      path: path,
      timeStepS: 0.01,
      minPitchHz: 100,
    );
    // 0.5-amplitude sine -> ~84.95 dB re 2e-5.
    expect(intensity.db[intensity.db.length ~/ 2], closeTo(84.95, 0.3));

    final formants = await rust_core.formantTrack(
      path: path,
      timeStepS: 0.01,
      maxFormants: 5,
      ceilingHz: 5500,
    );
    expect(formants.timesS, isNotEmpty);
    expect(formants.formantsHz.length, formants.timesS.length * 5);
    expect(formants.bandwidthsHz.length, formants.formantsHz.length);

    final sg = await rust_core.computeSpectrogram(
      path: path,
      windowS: 0.005,
      timeStepS: 0.002,
      maxFreqHz: 5000,
      preEmphasisHz: 0,
    );
    expect(sg.valuesDb.length, sg.nFrames * sg.nBins);
    expect(sg.nFrames, greaterThan(100));

    // Quality report: a clean 0.5-amplitude sine never clips and has no
    // quiet frames, so the percentile SNR estimate stays low.
    final q = await rust_core.wavQuality(path: path);
    expect(q.clippedPct, 0.0);
    expect(q.peakDbfs, closeTo(-6.02, 0.1));
    expect(q.estSnrDb, isNotNull);
    expect(q.estSnrDb!, lessThan(3.0));

    // Voice report: a pure tone is perfectly periodic — high HNR, and
    // negligible jitter/shimmer.
    final vr = await rust_core.voiceReport(
      path: path,
      f0MinHz: 75,
      f0MaxHz: 600,
    );
    expect(vr.nPeriods.toInt(), greaterThan(100));
    expect(vr.meanHnrDb, isNotNull);
    expect(vr.meanHnrDb!, greaterThan(30.0));
    expect(vr.jitterLocal!, lessThan(0.01));
    expect(vr.shimmerLocal!, lessThan(0.02));

    await dir.delete(recursive: true);
  });

  testWidgets('Sound handle: load once, analyze many', (tester) async {
    final dir = await Directory.systemTemp.createTemp('openphon_snd');
    final path = '${dir.path}${Platform.pathSeparator}sine220.wav';
    await File(path).writeAsBytes(
      sineWav(freqHz: 220, sampleRate: 44100, seconds: 1.0),
    );

    final sound = await rust_core.Sound.load(path: path);
    expect(sound.sampleRate(), 44100);
    expect(sound.durationS(), closeTo(1.0, 0.001));

    final env = await sound.envelope(t0S: 0, t1S: 1.0, nBuckets: 200);
    expect(env.min.length, 200);
    expect(env.max.length, 200);
    for (var i = 0; i < 200; i++) {
      expect(env.max[i], greaterThanOrEqualTo(env.min[i]));
    }
    // 0.5-amplitude sine: every ~5 ms bucket spans about ±0.5.
    expect(env.max[100], closeTo(0.5, 0.02));
    expect(env.min[100], closeTo(-0.5, 0.02));

    final sg = await sound.spectrogramRange(
      t0S: 0.2,
      t1S: 0.4,
      windowS: 0.005,
      timeStepS: 0.002,
      maxFreqHz: 5000,
      preEmphasisHz: 0,
    );
    expect(sg.nFrames, closeTo(100, 2));
    expect(sg.firstTimeS, greaterThanOrEqualTo(0.2));

    final f0 = await sound.f0(timeStepS: 0.01, f0MinHz: 75, f0MaxHz: 600);
    final voiced = f0.f0Hz.where((f) => f > 0).toList();
    expect(voiced[voiced.length ~/ 2], closeTo(220, 0.5));

    final intensity = await sound.intensity(timeStepS: 0.01, minPitchHz: 100);
    expect(intensity.db, isNotEmpty);
    final formants = await sound.formants(
      timeStepS: 0.01,
      maxFormants: 5,
      ceilingHz: 5500,
    );
    expect(formants.formantsHz.length, formants.timesS.length * 5);

    // Range-scoped voice report: the middle half of a pure tone is as
    // periodic as the whole; an empty range degrades to an empty report.
    final vr = await sound.voiceReport(
      t0S: 0.25,
      t1S: 0.75,
      f0MinHz: 75,
      f0MaxHz: 600,
    );
    expect(vr.nPeriods.toInt(), greaterThan(80));
    expect(vr.meanHnrDb!, greaterThan(30.0));
    expect(vr.jitterLocal!, lessThan(0.01));
    final empty = await sound.voiceReport(
      t0S: 0.5,
      t1S: 0.5,
      f0MinHz: 75,
      f0MaxHz: 600,
    );
    expect(empty.nPeriods.toInt(), 0);
    expect(empty.meanHnrDb, isNull);

    // Extract selection: a 0.2 s cut re-opens with the right length and
    // the same tone; an empty range is an error, not a file.
    final cutPath = '${dir.path}${Platform.pathSeparator}cut.wav';
    await sound.exportRangeWav(t0S: 0.3, t1S: 0.5, path: cutPath);
    final cut = await rust_core.Sound.load(path: cutPath);
    expect(cut.durationS(), closeTo(0.2, 0.001));
    final cutF0 = await cut.f0(timeStepS: 0.01, f0MinHz: 75, f0MaxHz: 600);
    final cutVoiced = cutF0.f0Hz.where((f) => f > 0).toList();
    expect(cutVoiced[cutVoiced.length ~/ 2], closeTo(220, 0.5));
    cut.dispose();
    await expectLater(
      sound.exportRangeWav(t0S: 0.5, t1S: 0.5, path: cutPath),
      throwsA(anything),
    );

    sound.dispose();
    await dir.delete(recursive: true);
  });

  testWidgets('TextGrid round trip over the bridge', (tester) async {
    final dir = await Directory.systemTemp.createTemp('openphon_tg');
    final path = '${dir.path}${Platform.pathSeparator}test.TextGrid';

    final grid = rust_core.TextGridData(
      xmin: 0,
      xmax: 2.5,
      tiers: [
        rust_core.TextGridTierData(
          isPoint: false,
          name: 'words',
          xmin: 0,
          xmax: 2.5,
          xmins: Float64List.fromList([0, 0.8]),
          xmaxs: Float64List.fromList([0.8, 2.5]),
          texts: ['señal', 'quoted "label"'],
        ),
        rust_core.TextGridTierData(
          isPoint: true,
          name: 'peaks',
          xmin: 0,
          xmax: 2.5,
          xmins: Float64List.fromList([1.25]),
          xmaxs: Float64List(0),
          texts: ['H*'],
        ),
      ],
    );
    await rust_core.writeTextGrid(path: path, data: grid);
    final back = await rust_core.readTextGrid(path: path);

    expect(back.xmax, 2.5);
    expect(back.tiers.length, 2);
    expect(back.tiers[0].isPoint, isFalse);
    expect(back.tiers[0].texts, ['señal', 'quoted "label"']);
    expect(back.tiers[0].xmaxs, [0.8, 2.5]);
    expect(back.tiers[1].isPoint, isTrue);
    expect(back.tiers[1].xmins, [1.25]);
    expect(back.tiers[1].texts, ['H*']);

    await dir.delete(recursive: true);
  });

  testWidgets('Bad file surfaces a Dart exception, not a crash',
      (tester) async {
    await expectLater(
      rust_core.wavInfo(path: 'Z:/does/not/exist.wav'),
      throwsA(anything),
    );
    await expectLater(
      rust_core.Sound.load(path: 'Z:/does/not/exist.wav'),
      throwsA(anything),
    );
  });
}
