import 'package:flutter_test/flutter_test.dart';
import 'package:openphon/src/analysis/analysis_controller.dart';
import 'package:openphon/src/annotation/annotation_editor.dart';
import 'package:openphon/src/annotation/annotation_model.dart';
import 'package:openphon/src/data/database.dart';

AnalysisController _controller() {
  final c = AnalysisController(
    Recording(
      id: 1,
      name: 'r',
      relativePath: 'r.wav',
      createdAt: DateTime(2026),
      sampleRate: 44100,
      channels: 1,
    ),
  );
  c.durationS = 2.0;
  c.annotation = AnnotationEditor(
    AnnotationDoc(
      xmin: 0,
      xmax: 2,
      tiers: const [
        IntervalTierModel(
          name: 'seg',
          intervals: [
            Interval(0, 0.5, 'a'),
            Interval(0.5, 2, 'b'),
          ],
        ),
        PointTierModel(
          name: 'pts',
          points: [AnnotationPoint(1.2, 'H')],
        ),
      ],
    ),
  );
  return c;
}

IntervalTierModel _seg(AnalysisController c) =>
    c.annotation!.doc.tiers[0] as IntervalTierModel;

void main() {
  test('boundary drag previews live and commits one undo step', () {
    final c = _controller();
    c.startAnnotationDrag(0, 1, isPoint: false);
    expect(c.annotationDrag!.timeS, 0.5);
    expect(c.annotationHit!.index, 1);
    c.updateAnnotationDrag(0.8);
    expect(c.annotationDrag!.timeS, 0.8);
    // Document unchanged while previewing.
    expect(_seg(c).intervals[0].xmax, 0.5);
    c.updateAnnotationDrag(0.9);
    c.endAnnotationDrag();
    expect(c.annotationDrag, isNull);
    expect(_seg(c).intervals[0].xmax, 0.9);
    // The whole drag is exactly one undo step.
    expect(c.annotationUndo(), isTrue);
    expect(_seg(c).intervals[0].xmax, 0.5);
    expect(c.annotation!.canUndo, isFalse);
  });

  test('drag snaps to other tiers within tolerance and clamps at neighbors', () {
    final c = _controller();
    c.startAnnotationDrag(0, 1, isPoint: false);
    c.updateAnnotationDrag(1.19, snapTolS: 0.05);
    expect(c.annotationDrag!.timeS, 1.2); // snapped to the point tier
    c.updateAnnotationDrag(1.19, snapTolS: 0.001);
    expect(c.annotationDrag!.timeS, 1.19); // outside snap tolerance
    c.updateAnnotationDrag(5.0);
    expect(c.annotationDrag!.timeS, lessThan(2.0)); // clamped inside neighbor
    c.endAnnotationDrag(commit: false);
    expect(_seg(c).intervals[0].xmax, 0.5); // cancel leaves the doc alone
    expect(c.annotation!.canUndo, isFalse);
  });

  test('cancelled drag with no update commits nothing', () {
    final c = _controller();
    c.startAnnotationDrag(0, 1, isPoint: false);
    c.endAnnotationDrag(commit: false);
    expect(c.annotationDrag, isNull);
    expect(c.annotation!.dirty, isFalse);
  });

  test('insert at cursor and delete hit round-trip on interval tier', () {
    final c = _controller();
    c.activeTier = 0;
    c.cursorTimeS = 1.0;
    expect(c.annotationInsertAtCursor(), isTrue);
    expect(_seg(c).intervals.length, 3);
    // Select the new boundary by tapping near it, then delete it.
    c.annotationTap(0, 1.001, tolS: 0.05);
    expect(c.annotationHit!.index, 2);
    expect(c.annotationDeleteHit(), isTrue);
    expect(_seg(c).intervals.length, 2);
    expect(c.annotationHit, isNull);
    expect(c.annotationDeleteHit(), isFalse); // nothing selected
  });

  test('insert at cursor adds an empty point on a point tier', () {
    final c = _controller();
    c.activeTier = 1;
    c.cursorTimeS = 0.3;
    expect(c.annotationInsertAtCursor(), isTrue);
    final pts = c.annotation!.doc.tiers[1] as PointTierModel;
    expect(pts.points.length, 2);
    expect(pts.points.first.time, 0.3);
    expect(pts.points.first.mark, '');
  });

  test('setLabel edits interval text and point mark', () {
    final c = _controller();
    expect(c.annotationSetLabel(0, 0, false, 'aa'), isTrue);
    expect(_seg(c).intervals[0].text, 'aa');
    expect(c.annotationSetLabel(1, 0, true, 'L%'), isTrue);
    final pts = c.annotation!.doc.tiers[1] as PointTierModel;
    expect(pts.points[0].mark, 'L%');
  });

  test('undo/redo clear the hit selection (indices may be stale)', () {
    final c = _controller();
    c.activeTier = 0;
    c.cursorTimeS = 1.0;
    c.annotationInsertAtCursor();
    c.annotationTap(0, 1.001, tolS: 0.05);
    expect(c.annotationHit, isNotNull);
    expect(c.annotationUndo(), isTrue);
    expect(c.annotationHit, isNull);
    expect(c.annotationRedo(), isTrue);
    expect(c.annotationHit, isNull);
    expect(_seg(c).intervals.length, 3);
  });

  test('newAnnotation creates a dirty single-tier grid over the audio', () {
    final c = _controller();
    c.newAnnotation();
    final ed = c.annotation!;
    expect(ed.dirty, isTrue); // not on disk yet
    final tier = ed.doc.tiers.single as IntervalTierModel;
    expect(tier.name, 'phones');
    expect(tier.intervals.single.xmax, 2.0);
    expect(ed.canUndo, isFalse);
    ed.markSaved();
    expect(ed.dirty, isFalse);
  });

  test('AnnotationEditor.unsaved starts dirty with equal content', () {
    final doc = AnnotationDoc.singleIntervalTier(xmin: 0, xmax: 1);
    final ed = AnnotationEditor.unsaved(doc);
    expect(ed.dirty, isTrue);
    expect(identical(ed.doc, doc), isTrue);
  });

  test('editing without an annotation is a safe no-op', () {
    final c = AnalysisController(
      Recording(
        id: 2,
        name: 'r2',
        relativePath: 'r2.wav',
        createdAt: DateTime(2026),
        sampleRate: 44100,
        channels: 1,
      ),
    );
    expect(c.annotationInsertAtCursor(), isFalse);
    expect(c.annotationDeleteHit(), isFalse);
    expect(c.annotationUndo(), isFalse);
    c.startAnnotationDrag(0, 1, isPoint: false);
    expect(c.annotationDrag, isNull);
  });
}
