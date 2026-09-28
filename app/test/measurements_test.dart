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
  final times = Float64List.fromList([
    for (var i = 0; i < 100; i++) i / 100,
  ]);
  final f0 = rust.F0TrackData(
    timesS: times,
    f0Hz: Float64List.fromList([
      for (var i = 0; i < 100; i++)
        (i >= 20 && i < 60) ? 200.0 + (i % 2) : 0.0,
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
    expect(a.medianF0Hz, anyOf(200.0, 201.0));
    expect(a.fMidHz, [700.0, 1200.0, 0.0]);
    expect(a.meanIntensityDb, closeTo(60.0, 1e-9));
    // Interval b has no voiced frames: F0 columns are 0.
    expect(rows[1].meanF0Hz, 0.0);
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
      'f1_mid_hz,f2_mid_hz,f3_mid_hz,mean_intensity_db',
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
      'f1_mid_hz,f2_mid_hz,f3_mid_hz,mean_intensity_db',
    );
    expect(lines, hasLength(1 + 2 * rows.length));
    expect(lines[1], startsWith('take one,phones,a,'));
    expect(lines[1 + rows.length], startsWith('"b,ad",phones,a,'));
  });
}
