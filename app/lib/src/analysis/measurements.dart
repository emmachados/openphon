import '../annotation/annotation_model.dart';
import '../rust/api/core.dart' as rust;

/// Per-interval measurement recipe, the in-app twin of the CLI's
/// `openphon measure`: duration, mean/median F0 over voiced frames, F1–F3
/// at the interval midpoint, mean intensity. Null marks an unavailable
/// measurement; raw tracks retain their zero sentinel. When manual
/// pitch edits apply, a final `f0_edited_frames` column counts the edited
/// frames in each interval, as the CLI does.
class IntervalMeasure {
  const IntervalMeasure({
    required this.label,
    required this.tminS,
    required this.tmaxS,
    required this.meanF0Hz,
    required this.medianF0Hz,
    required this.fMidHz,
    required this.meanIntensityDb,
    this.f0Frames = 0,
    this.voicedF0Frames = 0,
    this.intensityFrames = 0,
    this.f0EditedFrames = 0,
  });

  final String label;
  final double tminS;
  final double tmaxS;
  final double? meanF0Hz;
  final double? medianF0Hz;

  /// F1..F3 at the nearest frame inside the interval (null = missing).
  final List<double?> fMidHz;
  final double? meanIntensityDb;

  /// Finite F0 samples in the interval, including unvoiced zero samples.
  final int f0Frames;
  final int voicedF0Frames;
  final int intensityFrames;

  /// Manually corrected F0 frames inside the interval.
  final int f0EditedFrames;

  double get durationS => tmaxS - tminS;
}

List<IntervalMeasure> measureIntervals(
  IntervalTierModel tier, {
  rust.F0TrackData? f0,
  List<bool>? f0Edited,
  rust.IntensityTrackData? intensity,
  rust.FormantTrackData? formants,
  bool includeEmpty = false,
}) {
  final out = <IntervalMeasure>[];
  for (final iv in tier.intervals) {
    if (iv.text.isEmpty && !includeEmpty) continue;

    final voiced = <double>[];
    var f0Frames = 0;
    var edited = 0;
    if (f0 != null) {
      for (var i = 0; i < f0.timesS.length; i++) {
        final t = f0.timesS[i];
        if (!t.isFinite || t < iv.xmin || t >= iv.xmax) continue;
        final hz = f0.f0Hz[i];
        if (hz.isFinite) {
          f0Frames++;
          if (hz > 0) voiced.add(hz);
        }
        if (f0Edited != null && i < f0Edited.length && f0Edited[i]) edited++;
      }
    }
    double? meanF0;
    double? medianF0;
    if (voiced.isNotEmpty) {
      meanF0 = voiced.reduce((a, b) => a + b) / voiced.length;
      voiced.sort();
      final middle = voiced.length ~/ 2;
      medianF0 = voiced.length.isOdd
          ? voiced[middle]
          : (voiced[middle - 1] + voiced[middle]) / 2;
    }

    double? meanDb;
    var intensityFrames = 0;
    if (intensity != null) {
      var sum = 0.0;
      for (var i = 0; i < intensity.timesS.length; i++) {
        final t = intensity.timesS[i];
        final v = intensity.db[i];
        if (t.isFinite && t >= iv.xmin && t < iv.xmax && v.isFinite) {
          sum += v;
          intensityFrames++;
        }
      }
      if (intensityFrames > 0) meanDb = sum / intensityFrames;
    }

    final fMid = List<double?>.filled(3, null);
    if (formants != null && formants.timesS.isNotEmpty) {
      final mid = 0.5 * (iv.xmin + iv.xmax);
      int? best;
      for (var i = 0; i < formants.timesS.length; i++) {
        final t = formants.timesS[i];
        if (!t.isFinite || t < iv.xmin || t >= iv.xmax) continue;
        if (best == null ||
            (t - mid).abs() < (formants.timesS[best] - mid).abs()) {
          best = i;
        }
      }
      if (best != null) {
        final n = formants.maxFormants;
        for (var k = 0; k < 3 && k < n; k++) {
          final hz = formants.formantsHz[best * n + k];
          if (hz.isFinite && hz > 0) fMid[k] = hz;
        }
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
        f0Frames: f0Frames,
        voicedF0Frames: voiced.length,
        intensityFrames: intensityFrames,
        f0EditedFrames: edited,
      ),
    );
  }
  return out;
}

String _csvEscape(String s) =>
    s.contains(',') || s.contains('"') || s.contains('\n') || s.contains('\r')
    ? '"${s.replaceAll('"', '""')}"'
    : s;

/// One recording's contribution to a library-wide batch export.
class FileMeasures {
  const FileMeasures({
    required this.file,
    required this.tierName,
    required this.rows,
    this.pitchEdited = false,
  });

  final String file;
  final String tierName;
  final List<IntervalMeasure> rows;

  /// Whether manual pitch edits were applied to this recording.
  final bool pitchEdited;
}

/// Library-wide batch CSV: the same columns as [measurementsCsv] with a
/// leading `file` column, matching the CLI's directory-input mode.
String batchMeasurementsCsv(List<FileMeasures> files) {
  final edited = files.any((f) => f.pitchEdited);
  final b = StringBuffer(
    'file,tier,label,tmin_s,tmax_s,duration_s,mean_f0_hz,median_f0_hz,'
    'f1_mid_hz,f2_mid_hz,f3_mid_hz,mean_intensity_db,'
    'f0_frames,voiced_f0_frames,intensity_frames'
    '${edited ? ',f0_edited_frames' : ''}\n',
  );
  for (final f in files) {
    for (final row in f.rows) {
      b.writeln(
        '${_csvEscape(f.file)},${_measurementRow(f.tierName, row, edited)}',
      );
    }
  }
  return b.toString();
}

/// Same header and formatting as the CLI's `measure` output;
/// [editedColumn] adds `f0_edited_frames`, which the CLI writes when a
/// pitch edits file applies.
String measurementsCsv(
  String tierName,
  List<IntervalMeasure> rows, {
  bool editedColumn = false,
}) {
  final b = StringBuffer(
    'tier,label,tmin_s,tmax_s,duration_s,mean_f0_hz,median_f0_hz,'
    'f1_mid_hz,f2_mid_hz,f3_mid_hz,mean_intensity_db,'
    'f0_frames,voiced_f0_frames,intensity_frames'
    '${editedColumn ? ',f0_edited_frames' : ''}\n',
  );
  for (final m in rows) {
    b.writeln(_measurementRow(tierName, m, editedColumn));
  }
  return b.toString();
}

String _measurementRow(String tierName, IntervalMeasure m, bool editedColumn) =>
    [
      _csvEscape(tierName),
      _csvEscape(m.label),
      m.tminS.toStringAsFixed(6),
      m.tmaxS.toStringAsFixed(6),
      m.durationS.toStringAsFixed(6),
      _measurementCell(m.meanF0Hz),
      _measurementCell(m.medianF0Hz),
      _measurementCell(m.fMidHz[0]),
      _measurementCell(m.fMidHz[1]),
      _measurementCell(m.fMidHz[2]),
      _measurementCell(m.meanIntensityDb),
      '${m.f0Frames}',
      '${m.voicedF0Frames}',
      '${m.intensityFrames}',
      if (editedColumn) '${m.f0EditedFrames}',
    ].join(',');

String _measurementCell(double? value) =>
    value != null && value.isFinite ? value.toStringAsFixed(3) : '';
