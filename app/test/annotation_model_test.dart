import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:openphon/src/annotation/annotation_model.dart';
import 'package:openphon/src/rust/api/core.dart';

TextGridTierData intervalTier(
  String name,
  List<(double, double, String)> ivs, {
  double xmin = 0,
  double xmax = 1,
}) => TextGridTierData(
  isPoint: false,
  name: name,
  xmin: xmin,
  xmax: xmax,
  xmins: Float64List.fromList([for (final iv in ivs) iv.$1]),
  xmaxs: Float64List.fromList([for (final iv in ivs) iv.$2]),
  texts: [for (final iv in ivs) iv.$3],
);

TextGridTierData pointTier(
  String name,
  List<(double, String)> pts, {
  double xmin = 0,
  double xmax = 1,
}) => TextGridTierData(
  isPoint: true,
  name: name,
  xmin: xmin,
  xmax: xmax,
  xmins: Float64List.fromList([for (final p in pts) p.$1]),
  xmaxs: Float64List(0),
  texts: [for (final p in pts) p.$2],
);

void main() {
  group('normalizeIntervals', () {
    test('sorted contiguous input is preserved', () {
      final out = normalizeIntervals(0, 1, [
        const Interval(0, 0.4, 'a'),
        const Interval(0.4, 1, 'b'),
      ]);
      expect(out.length, 2);
      expect(out[0].text, 'a');
      expect(out[1].xmin, 0.4);
      expect(out[1].xmax, 1);
    });

    test('gaps are filled with empty intervals and edges covered', () {
      final out = normalizeIntervals(0, 2, [
        const Interval(0.5, 1.0, 'x'),
        const Interval(1.5, 1.8, 'y'),
      ]);
      expect(out.map((iv) => iv.text).toList(), ['', 'x', '', 'y', '']);
      for (var i = 1; i < out.length; i++) {
        expect(out[i].xmin, out[i - 1].xmax);
      }
      expect(out.first.xmin, 0);
      expect(out.last.xmax, 2);
    });

    test('unsorted input is sorted', () {
      final out = normalizeIntervals(0, 1, [
        const Interval(0.6, 1, 'b'),
        const Interval(0, 0.6, 'a'),
      ]);
      expect(out.map((iv) => iv.text).toList(), ['a', 'b']);
    });

    test('overlap is truncated, later interval wins the overlap region', () {
      final out = normalizeIntervals(0, 1, [
        const Interval(0, 0.7, 'a'),
        const Interval(0.5, 1, 'b'),
      ]);
      expect(out.length, 2);
      expect(out[0].xmax, 0.7);
      expect(out[1].xmin, 0.7);
    });

    test('empty input yields one empty covering interval', () {
      final out = normalizeIntervals(0, 3, []);
      expect(out.single.xmin, 0);
      expect(out.single.xmax, 3);
      expect(out.single.text, '');
    });

    test('out-of-range intervals are clamped', () {
      final out = normalizeIntervals(0, 1, [const Interval(-1, 2, 'a')]);
      expect(out.single.xmin, 0);
      expect(out.single.xmax, 1);
      expect(out.single.text, 'a');
    });
  });

  group('AnnotationDoc.fromTextGrid', () {
    test('interval and point tiers convert and round-trip', () {
      final data = TextGridData(
        xmin: 0,
        xmax: 2,
        tiers: [
          intervalTier('words', [(0, 1.2, 'hola'), (1.2, 2, '')], xmax: 2),
          pointTier('peaks', [(0.5, 'H*'), (1.6, 'L%')], xmax: 2),
        ],
      );
      final doc = AnnotationDoc.fromTextGrid(data);
      expect(doc.tiers.length, 2);
      final words = doc.tiers[0] as IntervalTierModel;
      expect(words.intervals.first.text, 'hola');
      final peaks = doc.tiers[1] as PointTierModel;
      expect(peaks.points.map((p) => p.mark).toList(), ['H*', 'L%']);

      final back = doc.toTextGrid();
      expect(back.xmax, 2);
      expect(back.tiers[0].isPoint, isFalse);
      expect(back.tiers[0].xmins, data.tiers[0].xmins);
      expect(back.tiers[0].texts, data.tiers[0].texts);
      expect(back.tiers[1].isPoint, isTrue);
      expect(back.tiers[1].xmins, data.tiers[1].xmins);
      expect(back.tiers[1].xmaxs, isEmpty);
    });

    test('unsorted / coincident points are sorted and deduplicated', () {
      final data = TextGridData(
        xmin: 0,
        xmax: 1,
        tiers: [
          pointTier('p', [(0.8, 'b'), (0.2, 'a'), (0.2, 'dup')]),
        ],
      );
      final tier = AnnotationDoc.fromTextGrid(data).tiers.single as PointTierModel;
      expect(tier.points.map((p) => p.mark).toList(), ['a', 'b']);
    });
  });

  group('IntervalTierModel.intervalIndexAt', () {
    final tier = IntervalTierModel(
      name: 't',
      intervals: const [
        Interval(0, 0.5, 'a'),
        Interval(0.5, 1.0, 'b'),
        Interval(1.0, 2.0, 'c'),
      ],
    );

    test('finds containing interval, half-open with closed end', () {
      expect(tier.intervalIndexAt(0), 0);
      expect(tier.intervalIndexAt(0.49), 0);
      expect(tier.intervalIndexAt(0.5), 1);
      expect(tier.intervalIndexAt(1.7), 2);
      expect(tier.intervalIndexAt(2.0), 2);
    });

    test('outside range returns -1', () {
      expect(tier.intervalIndexAt(-0.1), -1);
      expect(tier.intervalIndexAt(2.1), -1);
    });
  });

  test('boundaryTimes lists interior boundaries and points, excluding a tier', () {
    final doc = AnnotationDoc.fromTextGrid(
      TextGridData(
        xmin: 0,
        xmax: 1,
        tiers: [
          intervalTier('a', [(0, 0.3, ''), (0.3, 1, '')]),
          pointTier('p', [(0.7, 'x')]),
        ],
      ),
    );
    expect(doc.boundaryTimes(), [0.3, 0.7]);
    expect(doc.boundaryTimes(excludeTier: 0), [0.7]);
    expect(doc.boundaryTimes(excludeTier: 1), [0.3]);
  });

  test('singleIntervalTier spans the range with one empty interval', () {
    final doc = AnnotationDoc.singleIntervalTier(xmin: 0, xmax: 3.5);
    final tier = doc.tiers.single as IntervalTierModel;
    expect(tier.name, 'phones');
    expect(tier.intervals.single.xmax, 3.5);
  });
}
