import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/material.dart' hide Interval;
import 'package:flutter_test/flutter_test.dart';
import 'package:openphon/l10n/app_localizations.dart';
import 'package:openphon/src/analysis/analysis_controller.dart';
import 'package:openphon/src/annotation/annotation_editor.dart';
import 'package:openphon/src/annotation/annotation_model.dart';
import 'package:openphon/src/data/database.dart';
import 'package:openphon/src/ui/analysis/spectrogram_view.dart'
    show kFreqAxisWidth;
import 'package:openphon/src/ui/analysis/tier_view.dart';

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
  c.durationS = 1.0;
  c.annotation = AnnotationEditor(
    AnnotationDoc(
      xmin: 0,
      xmax: 1,
      tiers: const [
        IntervalTierModel(
          name: 'seg',
          intervals: [Interval(0, 0.5, 'a'), Interval(0.5, 1, 'b')],
        ),
      ],
    ),
  );
  return c;
}

Future<void> _pump(WidgetTester tester, AnalysisController c) async {
  await tester.pumpWidget(
    MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(
        body: Center(
          child: SizedBox(
            // Plot width = 400: with the 1 s viewport, 1 px = 2.5 ms.
            width: kFreqAxisWidth + 400,
            child: TierView(controller: c),
          ),
        ),
      ),
    ),
  );
}

void main() {
  test('drag time label formats with ms precision', () {
    expect(dragTimeLabel(0.5), '0.500 s');
    expect(dragTimeLabel(12.3456), '12.346 s');
  });

  testWidgets('dragging a boundary shows the floating time label', (
    tester,
  ) async {
    final c = _controller();
    await _pump(tester, c);
    final strip = tester.getTopLeft(find.byType(TierView));
    final onBoundary = strip + Offset(kFreqAxisWidth + 200, 10);
    final gesture = await tester.startGesture(
      onBoundary,
      kind: PointerDeviceKind.touch,
    );
    await tester.pump(const Duration(milliseconds: 400));
    await gesture.moveBy(const Offset(60, 0));
    await tester.pump();
    expect(c.annotationDrag, isNotNull);
    // The painter draws (not a widget); assert the drag preview time that
    // feeds the label instead of scraping the canvas.
    expect(c.annotationDrag!.timeS, closeTo(0.65, 0.02));
    await gesture.up();
    await tester.pump();
    expect(c.annotationDrag, isNull);
  });

  // The interior boundary at t=0.5 paints at x = kFreqAxisWidth + 200.
  // A tap 18 px away is outside the 8 px mouse slop but inside the 24 px
  // finger slop, so the pointer kind decides whether it hits.
  testWidgets('finger taps get a wider boundary hit slop than mouse', (
    tester,
  ) async {
    final c = _controller();
    await _pump(tester, c);
    final strip = tester.getTopLeft(find.byType(TierView));
    final nearBoundary = strip + Offset(kFreqAxisWidth + 200 + 18, 10);

    await tester.tapAt(nearBoundary, kind: PointerDeviceKind.mouse);
    // Past the double-tap window so the single tap resolves.
    await tester.pump(const Duration(milliseconds: 400));
    expect(c.annotationHit, isNull);
    expect(c.selection, isNotNull); // selected the interval instead

    await tester.tapAt(nearBoundary, kind: PointerDeviceKind.touch);
    await tester.pump(const Duration(milliseconds: 400));
    expect(c.annotationHit, isNotNull);
    expect(c.annotationHit!.index, 1);
  });
}
