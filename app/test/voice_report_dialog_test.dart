import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openphon/l10n/app_localizations.dart';
import 'package:openphon/src/rust/api/core.dart' as rust;
import 'package:openphon/src/ui/analysis/voice_report_dialog.dart';

Widget _host(VoiceReportDialog dialog) => MaterialApp(
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  home: Scaffold(body: dialog),
);

rust.VoiceReportData _full() => rust.VoiceReportData(
  meanHnrDb: 21.34,
  nPeriods: BigInt.from(412),
  jitterLocal: 0.00342,
  shimmerLocal: 0.0312,
  medianF0Hz: 182.44,
  meanF0Hz: 184.21,
  sdF0Hz: 12.06,
);

void main() {
  testWidgets('shows a spinner while loading, then the values', (
    tester,
  ) async {
    final completer = Completer<rust.VoiceReportData>();
    await tester.pumpWidget(
      _host(
        VoiceReportDialog(
          load: () => completer.future,
          t0: 1.25,
          t1: 2.5,
          isSelection: true,
          pitchFloorHz: 75,
          pitchCeilingHz: 500,
        ),
      ),
    );
    await tester.pump();
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    // Copy is disabled until the report lands.
    expect(
      tester.widget<TextButton>(find.widgetWithText(TextButton, 'Copy'))
          .onPressed,
      isNull,
    );

    completer.complete(_full());
    await tester.pumpAndSettle();

    expect(find.text('Selection 1.250–2.500 s'), findsOneWidget);
    expect(find.text('Pitch range 75–500 Hz'), findsOneWidget);
    expect(find.text('21.3 dB'), findsOneWidget);
    expect(find.text('0.34 %'), findsOneWidget); // jitter
    expect(find.text('3.12 %'), findsOneWidget); // shimmer
    expect(find.text('412'), findsOneWidget);
    expect(find.text('182.4 Hz'), findsOneWidget); // median F0
    expect(find.text('184.2 Hz'), findsOneWidget); // mean F0
    expect(find.text('12.1 Hz'), findsOneWidget); // F0 SD
    // Nothing was sparse, so no hint.
    expect(find.textContaining('sustained voiced'), findsNothing);
  });

  testWidgets('few periods trigger the hint even with values present', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(
        VoiceReportDialog(
          load: () async => rust.VoiceReportData(
            meanHnrDb: 0.1,
            nPeriods: BigInt.from(3),
            jitterLocal: 0.0878,
            shimmerLocal: 0.3609,
          ),
          t0: 0,
          t1: 6.7,
          isSelection: false,
          pitchFloorHz: 75,
          pitchCeilingHz: 600,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('sustained voiced'), findsOneWidget);
  });

  testWidgets('whole-recording caption and sparse hint with dashes', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(
        VoiceReportDialog(
          load: () async => rust.VoiceReportData(nPeriods: BigInt.zero),
          t0: 0,
          t1: 6.123,
          isSelection: false,
          pitchFloorHz: 100,
          pitchCeilingHz: 500,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Whole recording, 0–6.123 s'), findsOneWidget);
    expect(find.text('—'), findsNWidgets(6));
    expect(find.text('0'), findsOneWidget);
    expect(find.textContaining('sustained voiced'), findsOneWidget);
  });

  testWidgets('copy puts a tab-separated report on the clipboard', (
    tester,
  ) async {
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied = (call.arguments as Map)['text'] as String;
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    await tester.pumpWidget(
      _host(
        VoiceReportDialog(
          load: () async => _full(),
          t0: 0,
          t1: 3,
          isSelection: false,
          pitchFloorHz: 75,
          pitchCeilingHz: 500,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Copy'));
    await tester.pumpAndSettle();

    expect(copied, isNotNull);
    expect(copied, contains('Voice report'));
    expect(copied, contains('Median F0\t182.4 Hz'));
    expect(copied, contains('F0 SD\t12.1 Hz'));
    expect(copied, contains('Mean HNR\t21.3 dB'));
    expect(copied, contains('Jitter (local)\t0.34 %'));
    expect(copied, contains('Shimmer (local)\t3.12 %'));
    expect(copied, contains('Glottal periods\t412'));
    expect(find.text('Report copied to clipboard'), findsOneWidget);
  });

  testWidgets('a failed load shows the error, not a stuck spinner', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(
        VoiceReportDialog(
          load: () async => throw Exception('boom'),
          t0: 0,
          t1: 1,
          isSelection: false,
          pitchFloorHz: 75,
          pitchCeilingHz: 500,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('Voice report failed'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });
}
