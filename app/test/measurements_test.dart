import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:openphon/src/analysis/measurements.dart';
import 'package:openphon/src/annotation/annotation_model.dart';
import 'package:openphon/src/rust/api/core.dart' as rust;

void main() {
  const tier = IntervalTierModel(
    name: 'phones',
    intervals: [
      Interval(0, 0.2, ''),
      Interval(0.2, 0.6, 'a'),
      Interval(0.6, 1.0, 'b, "x"'),
    ],
  );

  // 10 ms grid; F0 200 Hz inside [0.2, 0.6), unvoiced elsewhere;
  // intensity 60 dB everywhere; F1/F2 constant.
  final times = Float64List.fromList([for (var i = 0; i < 100; i++) i / 100]);
  final f0 = rust.F0TrackData(
    timesS: times,
    f0Hz: Float64List.fromList([
      for (var i = 0; i < 100; i++) (i >= 20 && i < 60) ? 200.0 + (i % 2) : 0.0,
    ]),
  );
  final intensity = rust.IntensityTrackData(
    timesS: times,
    db: Float64List.fromList(List.filled(100, 60.0)),
  );
  final formants = rust.FormantTrackData(
    timesS: times,
    maxFormants: 2,
    formantsHz: Float64List.fromList([
      for (var i = 0; i < 100; i++) ...[700.0, 1200.0],
    ]),
    bandwidthsHz: Float64List.fromList(List.filled(200, 80.0)),
  );

  test('labelled intervals are measured; empty ones skipped by default', () {
    final rows = measureIntervals(
      tier,
      f0: f0,
      intensity: intensity,
      formants: formants,
    );
    expect(rows, hasLength(2));
    final a = rows.first;
    expect(a.label, 'a');
    expect(a.durationS, closeTo(0.4, 1e-9));
    expect(a.meanF0Hz, closeTo(200.5, 1e-9));
    expect(a.medianF0Hz, 200.5);
    expect(a.fMidHz, [700.0, 1200.0, null]);
    expect(a.meanIntensityDb, closeTo(60.0, 1e-9));
    expect(a.f0Frames, 40);
    expect(a.voicedF0Frames, 40);
    expect(a.intensityFrames, 40);
    // Interval b has F0 samples but no voiced frames.
    expect(rows[1].meanF0Hz, isNull);
    expect(rows[1].medianF0Hz, isNull);
    expect(rows[1].f0Frames, 40);
    expect(rows[1].voicedF0Frames, 0);
    expect(rows[1].meanIntensityDb, closeTo(60.0, 1e-9));
  });

  test('includeEmpty adds the unlabelled interval', () {
    final rows = measureIntervals(tier, f0: f0, includeEmpty: true);
    expect(rows, hasLength(3));
    expect(rows.first.label, '');
  });

  test('CSV matches the CLI header and escapes labels', () {
    final csv = measurementsCsv(
      'phones',
      measureIntervals(tier, f0: f0, intensity: intensity, formants: formants),
    );
    final lines = csv.trim().split('\n');
    expect(
      lines.first,
      'tier,label,tmin_s,tmax_s,duration_s,mean_f0_hz,median_f0_hz,'
      'f1_mid_hz,f2_mid_hz,f3_mid_hz,mean_intensity_db,'
      'f0_frames,voiced_f0_frames,intensity_frames',
    );
    expect(lines[2], startsWith('phones,"b, ""x""",0.600000'));
  });

  test('batch CSV prefixes each row with the escaped file column', () {
    final rows = measureIntervals(tier, f0: f0);
    final csv = batchMeasurementsCsv([
      FileMeasures(file: 'take one', tierName: 'phones', rows: rows),
      FileMeasures(file: 'b,ad', tierName: 'phones', rows: rows),
    ]);
    final lines = csv.trim().split('\n');
    expect(
      lines.first,
      'file,tier,label,tmin_s,tmax_s,duration_s,mean_f0_hz,median_f0_hz,'
      'f1_mid_hz,f2_mid_hz,f3_mid_hz,mean_intensity_db,'
      'f0_frames,voiced_f0_frames,intensity_frames',
    );
    expect(lines, hasLength(1 + 2 * rows.length));
    expect(lines[1], startsWith('take one,phones,a,'));
    expect(lines[1 + rows.length], startsWith('"b,ad",phones,a,'));
  });

  test('finite coverage excludes invalid values and preserves true zero dB', () {
    const shortTier = IntervalTierModel(
      name: 'phones',
      intervals: [Interval(0, 0.5, 'a')],
    );
    final times = Float64List.fromList([0, 0.1, 0.2, 0.3, 0.4, 0.5]);
    final rows = measureIntervals(
      shortTier,
      f0: rust.F0TrackData(
        timesS: times,
        f0Hz: Float64List.fromList([
          100,
          double.nan,
          0,
          200,
          double.infinity,
          400,
        ]),
      ),
      intensity: rust.IntensityTrackData(
        timesS: times,
        db: Float64List.fromList([
          0,
          double.nan,
          double.infinity,
          double.negativeInfinity,
          0,
          50,
        ]),
      ),
      formants: rust.FormantTrackData(
        timesS: Float64List.fromList([0.25]),
        maxFormants: 3,
        formantsHz: Float64List.fromList([500, 0, double.nan]),
        bandwidthsHz: Float64List(3),
      ),
    );
    final row = rows.single;
    expect(row.f0Frames, 3);
    expect(row.voicedF0Frames, 2);
    expect(row.intensityFrames, 2);
    expect(row.meanF0Hz, 150);
    expect(row.medianF0Hz, 150);
    expect(row.meanIntensityDb, 0);
    expect(row.fMidHz, [500, null, null]);
    expect(
      measurementsCsv('phones', rows).split('\n')[1],
      'phones,a,0.000000,0.500000,0.500000,150.000,150.000,500.000,,,0.000,3,2,2',
    );
  });

  test(
    'unavailable tracks and intervals without frames export blank cells',
    () {
      const shortTier = IntervalTierModel(
        name: 'phones',
        intervals: [Interval(0, 0.005, 'a')],
      );
      final rows = measureIntervals(
        shortTier,
        f0: f0,
        formants: rust.FormantTrackData(
          timesS: Float64List.fromList([0.01]),
          maxFormants: 1,
          formantsHz: Float64List.fromList([700]),
          bandwidthsHz: Float64List.fromList([80]),
        ),
      );
      expect(rows.single.fMidHz, [null, null, null]);
      expect(rows.single.meanIntensityDb, isNull);
      expect(
        measurementsCsv('phones', rows).split('\n')[1],
        'phones,a,0.000000,0.005000,0.005000,,,,,,,1,0,0',
      );
      final absent = measureIntervals(shortTier).single;
      expect(absent.meanF0Hz, isNull);
      expect(absent.f0Frames, 0);
    },
  );

  test('odd-sized median is the central observed value', () {
    final rows = measureIntervals(
      const IntervalTierModel(name: 'v', intervals: [Interval(0, 1, 'a')]),
      f0: rust.F0TrackData(
        timesS: Float64List.fromList([0.1, 0.2, 0.3]),
        f0Hz: Float64List.fromList([300, 100, 200]),
      ),
    );
    expect(rows.single.medianF0Hz, 200);
  });

  test('batch preserves quoted multiline labels and carriage returns', () {
    const tier = IntervalTierModel(
      name: 'tier\rname',
      intervals: [Interval(0, 1, 'first\n\nsecond, "quoted"\rline')],
    );
    final rows = measureIntervals(tier);
    final single = measurementsCsv(tier.name, rows);
    final headerEnd = single.indexOf('\n');
    final batch = batchMeasurementsCsv([
      FileMeasures(file: 'take\rname', tierName: tier.name, rows: rows),
    ]);
    expect(
      batch,
      'file,${single.substring(0, headerEnd + 1)}'
      '"take\rname",${single.substring(headerEnd + 1)}',
    );
    expect(
      single,
      contains('"tier\rname","first\n\nsecond, ""quoted""\rline"'),
    );
  });
}
