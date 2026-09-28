import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openphon/main.dart';
import 'package:openphon/src/data/storage_privacy.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('app.openphon/storage');

  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('iOS storage preparation requires confirmed backup exclusion', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          expect(call.method, 'excludeLibraryFromBackup');
          return true;
        });
    await preparePrivateStorage();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (_) async => false);
    await expectLater(preparePrivateStorage(), throwsStateError);
  });

  test(
    'an iOS storage configuration failure reaches the startup caller',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (_) async {
            throw PlatformException(code: 'backup_exclusion_failed');
          });
      await expectLater(
        preparePrivateStorage(),
        throwsA(isA<PlatformException>()),
      );
    },
  );

  testWidgets('startup failure is recoverable without opening the app', (
    tester,
  ) async {
    var attempts = 0;
    await tester.pumpWidget(
      OpenphonBootstrap(
        initialize: () async {
          attempts++;
          if (attempts == 1) throw StateError('storage unavailable');
          return const MaterialApp(home: Text('Library ready'));
        },
      ),
    );
    await tester.pumpAndSettle();
    expect(
      find.text('openphon could not start. Please retry.'),
      findsOneWidget,
    );
    expect(find.text('Library ready'), findsNothing);
    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();
    expect(attempts, 2);
    expect(find.text('Library ready'), findsOneWidget);
  });
}
