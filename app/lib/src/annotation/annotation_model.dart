import 'dart:typed_data';

import '../rust/api/core.dart' show TextGridData, TextGridTierData;

/// Immutable annotation document mirroring a Praat TextGrid.
///
/// Invariants (enforced on construction via [AnnotationDoc.fromTextGrid] and
/// preserved by every editing operation in AnnotationEditor):
///  - interval tiers are contiguous: intervals are sorted, adjacent
///    (`intervals[i].xmax == intervals[i+1].xmin`) and cover exactly
///    [xmin, xmax]; gaps in imported files are filled with empty intervals
///  - point tiers are sorted by time with strictly increasing times
class AnnotationDoc {
  const AnnotationDoc({
    required this.xmin,
    required this.xmax,
    required this.tiers,
  });

  /// A document with a single empty interval tier spanning the recording,
  /// used by the "New TextGrid" action.
  factory AnnotationDoc.singleIntervalTier({
    required double xmin,
    required double xmax,
    String tierName = 'phones',
  }) => AnnotationDoc(
    xmin: xmin,
    xmax: xmax,
    tiers: [
      IntervalTierModel(name: tierName, intervals: [Interval(xmin, xmax, '')]),
    ],
  );

  /// Builds a normalized document from bridge data (see TextGridTierData for
  /// the flattening convention). Out-of-range times are clamped, overlapping
  /// intervals truncated, gaps filled with empty intervals.
  factory AnnotationDoc.fromTextGrid(TextGridData data) {
    final xmin = data.xmin;
    final xmax = data.xmax <= data.xmin ? data.xmin + 1e-6 : data.xmax;
    final tiers = <TierModel>[];
    for (final t in data.tiers) {
      if (t.isPoint) {
        final points = <AnnotationPoint>[];
        for (var i = 0; i < t.xmins.length; i++) {
          final time = t.xmins[i].clamp(xmin, xmax).toDouble();
          points.add(
            AnnotationPoint(time, i < t.texts.length ? t.texts[i] : ''),
          );
        }
        points.sort((a, b) => a.time.compareTo(b.time));
        // Praat forbids coincident points; drop duplicates keeping the first.
        final unique = <AnnotationPoint>[];
        for (final p in points) {
          if (unique.isEmpty || p.time > unique.last.time) unique.add(p);
        }
        tiers.add(PointTierModel(name: t.name, points: unique));
      } else {
        final raw = <Interval>[];
        for (var i = 0; i < t.xmins.length; i++) {
          raw.add(
            Interval(
              t.xmins[i],
              i < t.xmaxs.length ? t.xmaxs[i] : t.xmins[i],
              i < t.texts.length ? t.texts[i] : '',
            ),
          );
        }
        tiers.add(
          IntervalTierModel(
            name: t.name,
            intervals: normalizeIntervals(xmin, xmax, raw),
          ),
        );
      }
    }
    return AnnotationDoc(xmin: xmin, xmax: xmax, tiers: tiers);
  }

  final double xmin;
  final double xmax;
  final List<TierModel> tiers;

  AnnotationDoc copyWithTier(int index, TierModel tier) {
    final next = List<TierModel>.of(tiers);
    next[index] = tier;
    return AnnotationDoc(xmin: xmin, xmax: xmax, tiers: next);
  }

  /// All boundary/point times on tiers other than [excludeTier], for snapping.
  List<double> boundaryTimes({int? excludeTier}) {
    final out = <double>[];
    for (var i = 0; i < tiers.length; i++) {
      if (i == excludeTier) continue;
      switch (tiers[i]) {
        case IntervalTierModel(:final intervals):
          // Interior boundaries only; the tier edges are not draggable targets.
          for (var j = 1; j < intervals.length; j++) {
            out.add(intervals[j].xmin);
          }
        case PointTierModel(:final points):
          for (final p in points) {
            out.add(p.time);
          }
      }
    }
    return out;
  }

  TextGridData toTextGrid() {
    final outTiers = <TextGridTierData>[];
    for (final tier in tiers) {
      switch (tier) {
        case IntervalTierModel(:final name, :final intervals):
          outTiers.add(
            TextGridTierData(
              isPoint: false,
              name: name,
              xmin: xmin,
              xmax: xmax,
              xmins: Float64List.fromList([
                for (final iv in intervals) iv.xmin,
              ]),
              xmaxs: Float64List.fromList([
                for (final iv in intervals) iv.xmax,
              ]),
              texts: [for (final iv in intervals) iv.text],
            ),
          );
        case PointTierModel(:final name, :final points):
          outTiers.add(
            TextGridTierData(
              isPoint: true,
              name: name,
              xmin: xmin,
              xmax: xmax,
              xmins: Float64List.fromList([for (final p in points) p.time]),
              xmaxs: Float64List(0),
              texts: [for (final p in points) p.mark],
            ),
          );
      }
    }
    return TextGridData(xmin: xmin, xmax: xmax, tiers: outTiers);
  }
}

sealed class TierModel {
  const TierModel({required this.name});
  final String name;
}

class IntervalTierModel extends TierModel {
  const IntervalTierModel({required super.name, required this.intervals});
  final List<Interval> intervals;

  /// Index of the interval containing [t] (an interval owns [xmin, xmax)),
  /// with the last interval also owning its xmax. Returns -1 outside range.
  int intervalIndexAt(double t) {
    if (intervals.isEmpty || t < intervals.first.xmin) return -1;
    if (t > intervals.last.xmax) return -1;
    var lo = 0, hi = intervals.length - 1;
    while (lo < hi) {
      final mid = (lo + hi) >> 1;
      if (t >= intervals[mid].xmax) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    return lo;
  }
}

class PointTierModel extends TierModel {
  const PointTierModel({required super.name, required this.points});
  final List<AnnotationPoint> points;
}

class Interval {
  const Interval(this.xmin, this.xmax, this.text);
  final double xmin;
  final double xmax;
  final String text;
}

class AnnotationPoint {
  const AnnotationPoint(this.time, this.mark);
  final double time;
  final String mark;
}

/// Gaps narrower than this are closed by extending the preceding interval;
/// wider gaps get an explicit empty interval.
const double kGapFillEpsS = 1e-6;

/// Sorts, clamps to [xmin, xmax], truncates overlaps, fills gaps with empty
/// intervals, and guarantees exact adjacency and full coverage.
List<Interval> normalizeIntervals(
  double xmin,
  double xmax,
  List<Interval> raw,
) {
  final sorted = [...raw]..sort((a, b) => a.xmin.compareTo(b.xmin));
  final out = <Interval>[];
  var t = xmin;
  for (final iv in sorted) {
    final b = iv.xmax.clamp(xmin, xmax).toDouble();
    if (b <= t) continue; // fully behind the cursor: degenerate or swallowed
    final a = iv.xmin.clamp(xmin, xmax).toDouble();
    if (a > t + kGapFillEpsS) {
      out.add(Interval(t, a, ''));
      t = a;
    }
    out.add(Interval(t, b, iv.text));
    t = b;
  }
  if (t < xmax - kGapFillEpsS) {
    out.add(Interval(t, xmax, ''));
  } else if (out.isNotEmpty && out.last.xmax != xmax) {
    final last = out.removeLast();
    out.add(Interval(last.xmin, xmax, last.text));
  }
  if (out.isEmpty) return [Interval(xmin, xmax, '')];
  return out;
}
