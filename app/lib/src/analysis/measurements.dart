import '../annotation/annotation_model.dart';
import '../rust/api/core.dart' as rust;

/// Per-interval measurement recipe, the in-app twin of the CLI's
/// `openphon measure`: duration, mean/median F0 over voiced frames, F1–F3
/// at the interval midpoint, mean intensity. 0 marks "no voiced frames" /
/// "no formant value", matching the track CSVs and the CLI.
class IntervalMeasure {
  const IntervalMeasure({
    required this.label,
    required this.tminS,
    required this.tmaxS,
    required this.meanF0Hz,
    required this.medianF0Hz,
    required this.fMidHz,
    required this.meanIntensityDb,
  });

  final String label;
  final double tminS;
  final double tmaxS;
  final double meanF0Hz;
  final double medianF0Hz;

  /// F1..F3 at the midpoint frame (0 = missing).
  final List<double> fMidHz;
  final double meanIntensityDb;

  double get durationS => tmaxS - tminS;
}

List<IntervalMeasure> measureIntervals(
  IntervalTierModel tier, {
  rust.F0TrackData? f0,
  rust.IntensityTrackData? intensity,
  rust.FormantTrackData? formants,
  bool includeEmpty = false,
}) {
  final out = <IntervalMeasure>[];
  for (final iv in tier.intervals) {
    if (iv.text.isEmpty && !includeEmpty) continue;

    final voiced = <double>[];
    if (f0 != null) {
      for (var i = 0; i < f0.timesS.length; i++) {
        final t = f0.timesS[i];
        if (t >= iv.xmin && t < iv.xmax && f0.f0Hz[i] > 0) {
          voiced.add(f0.f0Hz[i]);
        }
      }
    }
    var meanF0 = 0.0;
    var medianF0 = 0.0;
    if (voiced.isNotEmpty) {
      meanF0 = voiced.reduce((a, b) => a + b) / voiced.length;
      voiced.sort();
      medianF0 = voiced[voiced.length ~/ 2];
    }

    var meanDb = 0.0;
    if (intensity != null) {
      var sum = 0.0;
      var n = 0;
      for (var i = 0; i < intensity.timesS.length; i++) {
        final t = intensity.timesS[i];
        final v = intensity.db[i];
        if (t >= iv.xmin && t < iv.xmax && v.isFinite) {
          sum += v;
          n++;
        }
      }
      if (n > 0) meanDb = sum / n;
    }

    final fMid = List<double>.filled(3, 0);
    if (formants != null && formants.timesS.isNotEmpty) {
      final mid = 0.5 * (iv.xmin + iv.xmax);
      var best = 0;
      for (var i = 1; i < formants.timesS.length; i++) {
        if ((formants.timesS[i] - mid).abs() <
            (formants.timesS[best] - mid).abs()) {
          best = i;
        }
      }
      final n = formants.maxFormants;
      for (var k = 0; k < 3 && k < n; k++) {
        fMid[k] = formants.formantsHz[best * n + k];
      }
    }

    out.add(
      IntervalMeasure(
        label: iv.text,
        tminS: iv.xmin,
        tmaxS: iv.xmax,
        meanF0Hz: meanF0,
        medianF0Hz: medianF0,
        fMidHz: fMid,
        meanIntensityDb: meanDb,
      ),
    );
  }
  return out;
}

String _csvEscape(String s) =>
    s.contains(',') || s.contains('"') || s.contains('\n')
    ? '"${s.replaceAll('"', '""')}"'
    : s;

/// One recording's contribution to a library-wide batch export.
class FileMeasures {
  const FileMeasures({
    required this.file,
    required this.tierName,
    required this.rows,
  });

  final String file;
  final String tierName;
  final List<IntervalMeasure> rows;
}

/// Library-wide batch CSV: the same columns as [measurementsCsv] with a
/// leading `file` column, matching the CLI's directory-input mode.
String batchMeasurementsCsv(List<FileMeasures> files) {
  final b = StringBuffer(
    'file,tier,label,tmin_s,tmax_s,duration_s,mean_f0_hz,median_f0_hz,'
    'f1_mid_hz,f2_mid_hz,f3_mid_hz,mean_intensity_db\n',
  );
  for (final f in files) {
    final single = measurementsCsv(f.tierName, f.rows);
    for (final line in single.split('\n').skip(1)) {
      if (line.isEmpty) continue;
      b.writeln('${_csvEscape(f.file)},$line');
    }
  }
  return b.toString();
}

/// Same header and formatting as the CLI's `measure` output.
String measurementsCsv(String tierName, List<IntervalMeasure> rows) {
  final b = StringBuffer(
    'tier,label,tmin_s,tmax_s,duration_s,mean_f0_hz,median_f0_hz,'
    'f1_mid_hz,f2_mid_hz,f3_mid_hz,mean_intensity_db\n',
  );
  for (final m in rows) {
    b.writeln(
      [
        _csvEscape(tierName),
        _csvEscape(m.label),
        m.tminS.toStringAsFixed(6),
        m.tmaxS.toStringAsFixed(6),
        m.durationS.toStringAsFixed(6),
        m.meanF0Hz.toStringAsFixed(3),
        m.medianF0Hz.toStringAsFixed(3),
        m.fMidHz[0].toStringAsFixed(3),
        m.fMidHz[1].toStringAsFixed(3),
        m.fMidHz[2].toStringAsFixed(3),
        m.meanIntensityDb.toStringAsFixed(3),
      ].join(','),
    );
  }
  return b.toString();
}
