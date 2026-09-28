import 'package:flutter_test/flutter_test.dart';
import 'package:openphon/src/analysis/analysis_controller.dart';
import 'package:openphon/src/analysis/viewport_math.dart';
import 'package:openphon/src/data/database.dart';

Recording _rec() => Recording(
      id: 1,
      name: 'test',
      relativePath: 'recordings/test.wav',
      createdAt: DateTime(2026),
      durationMs: 10000,
      sampleRate: 44100,
      channels: 1,
    );

AnalysisController _controller({double durationS = 10}) {
  final c = AnalysisController(_rec());
  c.durationS = durationS;
  c.viewport = TimeViewport(0, durationS);
  return c;
}

void main() {
  group('px <-> time mapping', () {
    const vp = TimeViewport(2.0, 6.0);

    test('round trips', () {
      for (final x in [0.0, 123.4, 500.0]) {
        expect(timeToX(xToTime(x, vp, 500), vp, 500), closeTo(x, 1e-9));
      }
    });

    test('endpoints map to edges', () {
      expect(timeToX(2.0, vp, 400), 0);
      expect(timeToX(6.0, vp, 400), 400);
      expect(xToTime(200, vp, 400), closeTo(4.0, 1e-12));
    });
  });

  group('viewport operations', () {
    test('zoomAbout keeps the focal time fixed', () {
      final c = _controller();
      c.setViewport(2, 6);
      final before = timeToX(3.0, c.viewport, 100);
      c.zoomAbout(3.0, 0.5);
      expect(c.viewport.span, closeTo(2.0, 1e-9));
      expect(timeToX(3.0, c.viewport, 100), closeTo(before, 1e-6));
      c.dispose();
    });

    test('setViewport clamps to the file', () {
      final c = _controller();
      c.setViewport(-3, 4);
      expect(c.viewport.t0, 0);
      c.setViewport(8, 15);
      expect(c.viewport.t1, closeTo(10, 1e-12));
      expect(c.viewport.span, closeTo(7, 1e-9));
      c.dispose();
    });

    test('zoom never goes below the minimum span', () {
      final c = _controller();
      c.zoomAbout(5.0, 1e-9);
      expect(c.viewport.span, closeTo(kMinViewportSpanS, 1e-12));
      c.dispose();
    });

    test('zoom out is capped at the file duration', () {
      final c = _controller();
      c.setViewport(4, 5);
      c.zoomAbout(4.5, 100);
      expect(c.viewport.t0, 0);
      expect(c.viewport.t1, closeTo(10, 1e-9));
      c.dispose();
    });

    test('pan preserves span', () {
      final c = _controller();
      c.setViewport(1, 3);
      c.panBy(0.5);
      expect(c.viewport.t0, closeTo(1.5, 1e-12));
      expect(c.viewport.span, closeTo(2.0, 1e-12));
      c.dispose();
    });

    test('selection orders its endpoints', () {
      final s = const TimeSelection(4.0, 1.5);
      expect(s.t0, 1.5);
      expect(s.t1, 4.0);
    });
  });
}
