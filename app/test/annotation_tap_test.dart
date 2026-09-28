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
          points: [AnnotationPoint(1.0, 'H')],
        ),
      ],
    ),
  );
  return c;
}

void main() {
  test('tap on interval tier activates tier and selects the interval', () {
    final c = _controller();
    c.annotationTap(0, 1.3);
    expect(c.activeTier, 0);
    expect(c.selection!.t0, 0.5);
    expect(c.selection!.t1, 2.0);
    expect(c.cursorTimeS, 1.3);
    c.annotationTap(0, 0.1);
    expect(c.selection!.t0, 0);
    expect(c.selection!.t1, 0.5);
  });

  test('tap on point tier snaps the cursor to a nearby point', () {
    final c = _controller();
    c.annotationTap(1, 1.02, tolS: 0.05);
    expect(c.activeTier, 1);
    expect(c.cursorTimeS, 1.0);
    expect(c.annotationHit!.isPoint, isTrue);
    expect(c.annotationHit!.index, 0);
    // Outside tolerance: cursor stays at the tap time, no hit.
    c.annotationTap(1, 1.5, tolS: 0.05);
    expect(c.cursorTimeS, 1.5);
    expect(c.annotationHit, isNull);
    expect(c.selection, isNull);
  });

  test('tap near an interior boundary selects it instead of the interval', () {
    final c = _controller();
    c.annotationTap(0, 0.51, tolS: 0.05);
    expect(c.annotationHit!.isPoint, isFalse);
    expect(c.annotationHit!.index, 1);
    expect(c.cursorTimeS, 0.5);
    expect(c.selection, isNull); // boundary tap does not select the interval
    // A later interval tap clears the boundary selection.
    c.annotationTap(0, 1.3, tolS: 0.05);
    expect(c.annotationHit, isNull);
    expect(c.selection, isNotNull);
  });

  test('tap is ignored without annotation or with a bad tier index', () {
    final c = _controller();
    c.annotationTap(5, 1.0);
    expect(c.selection, isNull);
    final bare = AnalysisController(
      Recording(
        id: 2,
        name: 'r2',
        relativePath: 'r2.wav',
        createdAt: DateTime(2026),
        sampleRate: 44100,
        channels: 1,
      ),
    );
    bare.annotationTap(0, 1.0);
    expect(bare.selection, isNull);
    expect(bare.activeTier, 0);
  });

  test('selection is clamped to the audio duration', () {
    final c = _controller();
    c.durationS = 1.0; // TextGrid extends past the audio
    c.annotationTap(0, 0.8);
    expect(c.selection!.t1, 1.0);
  });
}
