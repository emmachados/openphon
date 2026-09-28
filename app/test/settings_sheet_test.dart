import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openphon/l10n/app_localizations.dart';
import 'package:openphon/src/analysis/analysis_settings.dart';
import 'package:openphon/src/ui/analysis/settings_sheet.dart';

Future<void> _enter(WidgetTester tester, String label, String text) async {
  final field = find.widgetWithText(TextField, label);
  await tester.ensureVisible(field);
  await tester.enterText(field, text);
}

void main() {
  testWidgets('applied values round-trip with clamping', (tester) async {
    AnalysisSettings? result;
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: Builder(
            builder: (context) => Center(
              child: ElevatedButton(
                onPressed: () async {
                  result = await showAnalysisSettings(
                    context,
                    const AnalysisSettings(),
                  );
                },
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    await _enter(tester, 'Min time step', '5');
    // Out of range: must clamp to the 100 ms ceiling.
    await _enter(tester, 'Time step', '900');
    await tester.tap(find.text('Apply'));
    await tester.pumpAndSettle();

    expect(result, isNotNull);
    expect(result!.spectrogramMinTimeStepS, closeTo(0.005, 1e-9));
    expect(result!.trackTimeStepS, closeTo(0.1, 1e-9));
    // Untouched fields keep their defaults.
    expect(result!.pitchFloorHz, 75);
  });

  testWidgets('voice preset prefills pitch range and formant ceiling', (
    tester,
  ) async {
    AnalysisSettings? result;
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: Builder(
            builder: (context) => Center(
              child: ElevatedButton(
                onPressed: () async {
                  result = await showAnalysisSettings(
                    context,
                    const AnalysisSettings(),
                  );
                },
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Child'));
    await tester.pump();
    await tester.tap(find.text('Apply'));
    await tester.pumpAndSettle();

    expect(result!.pitchFloorHz, 150);
    expect(result!.pitchCeilingHz, 800);
    expect(result!.formantCeilingHz, 8000);
    // Presets leave unrelated fields alone.
    expect(result!.spectrogramMaxFreqHz, 5000);
  });
}
