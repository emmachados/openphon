import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:file_selector_ios/file_selector_ios.dart';
import 'package:file_selector_ios/src/messages.g.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openphon/src/data/file_exchange.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

class _Directories extends PathProviderPlatform {
  _Directories(this.path);
  final String path;

  @override
  Future<String> getTemporaryPath() async => path;
}

class _IosPicker extends FileSelectorApi {
  FileSelectorConfig? config;

  @override
  Future<List<String>> openFile(FileSelectorConfig config) async {
    this.config = config;
    return [];
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory tmp;
  late PathProviderPlatform originalDirectories;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('openphon_exchange_test_');
    originalDirectories = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _Directories(tmp.path);
  });

  tearDown(() async {
    PathProviderPlatform.instance = originalDirectories;
    await tmp.delete(recursive: true);
  });

  test('the iOS picker accepts both application import filters', () async {
    final api = _IosPicker();
    final picker = FileSelectorIOS(api: api);
    expect(await picker.openFiles(acceptedTypeGroups: [wavFileType]), isEmpty);
    expect(api.config!.utis, ['com.microsoft.waveform-audio']);
    expect(api.config!.allowMultiSelection, isTrue);
    expect(
      await picker.openFile(acceptedTypeGroups: [textGridFileType]),
      isNull,
    );
    expect(api.config!.utis, ['public.data']);
  });

  test(
    'a provider document is readable locally and cleaned after import',
    () async {
      final bytes = Uint8List.fromList('TextGrid content'.codeUnits);
      final file = XFile.fromData(
        bytes,
        path: 'content://documents/phones.TextGrid',
        mimeType: 'text/plain',
      );
      late String localPath;
      final imported = await withLocalDocument(file, (path) async {
        localPath = path;
        expect(path, startsWith(tmp.path));
        return File(path).readAsString();
      });
      expect(imported, 'TextGrid content');
      expect(File(localPath).existsSync(), isFalse);
      expect(tmp.listSync(), isEmpty);
    },
  );

  test('a failed document import also removes its staging copy', () async {
    final file = XFile.fromData(
      Uint8List.fromList([1, 2, 3]),
      name: 'bad.TextGrid',
    );
    await expectLater(
      withLocalDocument(
        file,
        (_) async => throw const FormatException('bad grid'),
      ),
      throwsFormatException,
    );
    expect(tmp.listSync(), isEmpty);
  });

  test('successive exports do not overwrite an outstanding share', () async {
    final first = await exportDirectory();
    await File('${first.path}/take.wav').writeAsString('first');
    final second = await exportDirectory();
    await File('${second.path}/take.wav').writeAsString('second');
    expect(first.path, isNot(second.path));
    expect(await File('${first.path}/take.wav').readAsString(), 'first');
  });

  testWidgets('sharing supplies an origin within the visible view', (
    tester,
  ) async {
    const channel = MethodChannel('dev.fluttercommunity.plus/share');
    Map<Object?, Object?>? arguments;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          arguments = call.arguments as Map<Object?, Object?>;
          return 'dev.fluttercommunity.plus/share/unavailable';
        });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: Builder(
              builder: (context) {
                return TextButton(
                  onPressed: () =>
                      shareFilesFrom(context, [XFile('/tmp/take.wav')]),
                  child: const Text('Share'),
                );
              },
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Share'));
    await tester.pumpAndSettle();
    expect(arguments, isNotNull);
    final rect = Rect.fromLTWH(
      arguments!['originX'] as double,
      arguments!['originY'] as double,
      arguments!['originWidth'] as double,
      arguments!['originHeight'] as double,
    );
    expect(rect.isEmpty, isFalse);
    expect(rect.left, greaterThanOrEqualTo(0));
    expect(rect.top, greaterThanOrEqualTo(0));
    expect(rect.right, lessThanOrEqualTo(800));
    expect(rect.bottom, lessThanOrEqualTo(600));
    expect(arguments!['paths'], ['/tmp/take.wav']);
  });
}
