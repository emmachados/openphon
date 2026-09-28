import 'package:flutter/material.dart' hide Interval;
import 'package:flutter_test/flutter_test.dart';
import 'package:openphon/l10n/app_localizations.dart';
import 'package:openphon/src/analysis/analysis_controller.dart';
import 'package:openphon/src/annotation/annotation_editor.dart';
import 'package:openphon/src/annotation/annotation_model.dart';
import 'package:openphon/src/data/database.dart';
import 'package:openphon/src/ui/analysis/tier_view.dart';

void main() {
  testWidgets('tier strip exposes tiers and interactions to assistive tech', (
    tester,
  ) async {
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
          IntervalTierModel(name: 'phones', intervals: [Interval(0, 1, '')]),
          PointTierModel(name: 'peaks', points: []),
        ],
      ),
    );
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(body: TierView(controller: c)),
      ),
    );
    expect(
      find.bySemanticsLabel(RegExp('Annotation tiers: phones, peaks.*')),
      findsOneWidget,
    );
  });
}
