import 'package:flutter_test/flutter_test.dart';
import 'package:openphon/src/annotation/annotation_editor.dart';
import 'package:openphon/src/annotation/annotation_model.dart';

AnnotationEditor editorWith({
  double xmax = 2,
  List<Interval>? intervals,
  List<AnnotationPoint>? points,
}) => AnnotationEditor(
  AnnotationDoc(
    xmin: 0,
    xmax: xmax,
    tiers: [
      IntervalTierModel(
        name: 'seg',
        intervals: intervals ?? [Interval(0, xmax, '')],
      ),
      PointTierModel(name: 'pts', points: points ?? const []),
    ],
  ),
);

IntervalTierModel seg(AnnotationEditor e) => e.doc.tiers[0] as IntervalTierModel;
PointTierModel pts(AnnotationEditor e) => e.doc.tiers[1] as PointTierModel;

void main() {
  group('boundary operations', () {
    test('insertBoundary splits, label stays left', () {
      final e = editorWith(
        intervals: const [Interval(0, 2, 'word')],
      );
      expect(e.insertBoundary(0, 0.8), isTrue);
      final t = seg(e);
      expect(t.intervals.length, 2);
      expect(t.intervals[0].text, 'word');
      expect(t.intervals[0].xmax, 0.8);
      expect(t.intervals[1].text, '');
      expect(t.intervals[1].xmin, 0.8);
    });

    test('insertBoundary rejects out-of-range, wrong tier, near-edge', () {
      final e = editorWith();
      expect(e.insertBoundary(0, -1), isFalse);
      expect(e.insertBoundary(0, 1e-6), isFalse); // closer than minIntervalS
      expect(e.insertBoundary(1, 0.5), isFalse); // point tier
      expect(e.insertBoundary(5, 0.5), isFalse);
      expect(e.dirty, isFalse);
    });

    test('moveBoundary moves shared edge and clamps at neighbors', () {
      final e = editorWith(
        intervals: const [Interval(0, 1, 'a'), Interval(1, 2, 'b')],
      );
      expect(e.moveBoundary(0, 1, 1.5), isTrue);
      expect(seg(e).intervals[0].xmax, 1.5);
      expect(seg(e).intervals[1].xmin, 1.5);
      // Clamped: cannot cross the right neighbor's end.
      expect(e.moveBoundary(0, 1, 99), isTrue);
      expect(seg(e).intervals[1].xmax, 2);
      expect(
        seg(e).intervals[0].xmax,
        closeTo(2 - AnnotationEditor.minIntervalS, 1e-12),
      );
      // Boundary 0 and n are tier edges, not movable.
      expect(e.moveBoundary(0, 0, 0.5), isFalse);
      expect(e.moveBoundary(0, 2, 0.5), isFalse);
    });

    test('removeBoundary merges and joins non-empty labels', () {
      final e = editorWith(
        intervals: const [
          Interval(0, 0.5, 'a'),
          Interval(0.5, 1, ''),
          Interval(1, 2, 'b'),
        ],
      );
      expect(e.removeBoundary(0, 1), isTrue);
      expect(seg(e).intervals.length, 2);
      expect(seg(e).intervals[0].text, 'a');
      expect(seg(e).intervals[0].xmax, 1);
      expect(e.removeBoundary(0, 1), isTrue);
      expect(seg(e).intervals.single.text, 'a b');
    });

    test('setIntervalText replaces label; no-op returns false', () {
      final e = editorWith();
      expect(e.setIntervalText(0, 0, 'hola'), isTrue);
      expect(seg(e).intervals.single.text, 'hola');
      expect(e.setIntervalText(0, 0, 'hola'), isFalse);
      expect(e.setIntervalText(0, 7, 'x'), isFalse);
    });
  });

  group('point operations', () {
    test('addPoint keeps order and rejects near-coincident times', () {
      final e = editorWith();
      expect(e.addPoint(1, 1.0, 'H'), isTrue);
      expect(e.addPoint(1, 0.5, 'L'), isTrue);
      expect(pts(e).points.map((p) => p.mark).toList(), ['L', 'H']);
      expect(e.addPoint(1, 1.0, 'dup'), isFalse);
      expect(e.addPoint(1, 5.0, 'out'), isFalse);
      expect(e.addPoint(0, 0.2, 'wrong tier'), isFalse);
    });

    test('movePoint clamps between neighbors and range', () {
      final e = editorWith(
        points: const [AnnotationPoint(0.5, 'a'), AnnotationPoint(1.5, 'b')],
      );
      expect(e.movePoint(1, 0, 0.9), isTrue);
      expect(pts(e).points[0].time, 0.9);
      // Clamped short of the right neighbor.
      expect(e.movePoint(1, 0, 99), isTrue);
      expect(
        pts(e).points[0].time,
        closeTo(1.5 - AnnotationEditor.minIntervalS, 1e-12),
      );
      // A clamped move that lands on the current position is a no-op.
      expect(e.movePoint(1, 1, pts(e).points[0].time), isFalse);
      // Left clamp, from a fresh state so the target is not already at it.
      final e2 = editorWith(
        points: const [AnnotationPoint(0.5, 'a'), AnnotationPoint(1.5, 'b')],
      );
      expect(e2.movePoint(1, 1, -5), isTrue);
      expect(
        pts(e2).points[1].time,
        closeTo(0.5 + AnnotationEditor.minIntervalS, 1e-12),
      );
      expect(e2.movePoint(1, 5, 1.0), isFalse); // bad index
    });

    test('removePoint and setPointMark', () {
      final e = editorWith(points: const [AnnotationPoint(0.5, 'a')]);
      expect(e.setPointMark(1, 0, 'b'), isTrue);
      expect(pts(e).points.single.mark, 'b');
      expect(e.removePoint(1, 0), isTrue);
      expect(pts(e).points, isEmpty);
      expect(e.removePoint(1, 0), isFalse);
    });
  });

  group('undo/redo and dirty tracking', () {
    test('undo restores previous state, redo reapplies', () {
      final e = editorWith(intervals: const [Interval(0, 2, 'x')]);
      expect(e.canUndo, isFalse);
      e.insertBoundary(0, 1.0);
      e.setIntervalText(0, 1, 'y');
      expect(seg(e).intervals[1].text, 'y');
      expect(e.undo(), isTrue);
      expect(seg(e).intervals[1].text, '');
      expect(e.undo(), isTrue);
      expect(seg(e).intervals.length, 1);
      expect(e.undo(), isFalse);
      expect(e.redo(), isTrue);
      expect(seg(e).intervals.length, 2);
      expect(e.redo(), isTrue);
      expect(seg(e).intervals[1].text, 'y');
      expect(e.redo(), isFalse);
    });

    test('a new edit clears the redo stack', () {
      final e = editorWith();
      e.insertBoundary(0, 1.0);
      e.undo();
      expect(e.canRedo, isTrue);
      e.insertBoundary(0, 0.5);
      expect(e.canRedo, isFalse);
    });

    test('dirty reflects distance from saved state, undo can clean', () {
      final e = editorWith();
      expect(e.dirty, isFalse);
      e.insertBoundary(0, 1.0);
      expect(e.dirty, isTrue);
      e.undo();
      expect(e.dirty, isFalse); // back at the saved snapshot
      e.redo();
      expect(e.dirty, isTrue);
      e.markSaved();
      expect(e.dirty, isFalse);
      e.undo();
      expect(e.dirty, isTrue); // undone past the save point
    });

    test('replace clears history and dirty', () {
      final e = editorWith();
      e.insertBoundary(0, 1.0);
      e.replace(AnnotationDoc.singleIntervalTier(xmin: 0, xmax: 1));
      expect(e.canUndo, isFalse);
      expect(e.canRedo, isFalse);
      expect(e.dirty, isFalse);
    });

    test('undo depth is capped', () {
      final e = editorWith(xmax: 1000);
      var t = 1.0;
      var edits = 0;
      while (edits < AnnotationEditor.maxUndo + 20) {
        expect(e.insertBoundary(0, t), isTrue);
        t += 1.0;
        edits++;
      }
      var undos = 0;
      while (e.undo()) {
        undos++;
      }
      expect(undos, AnnotationEditor.maxUndo);
    });
  });
}
