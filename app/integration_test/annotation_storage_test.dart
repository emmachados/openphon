import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:openphon/src/analysis/analysis_controller.dart';
import 'package:openphon/src/annotation/annotation_model.dart';
import 'package:openphon/src/data/annotation_storage.dart';
import 'package:openphon/src/data/database.dart';
import 'package:openphon/src/rust/api/core.dart' as rust;
import 'package:openphon/src/rust/frb_generated.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(RustLib.init);

  testWidgets(
    'native saves replace an existing TextGrid and reopen with the latest edits',
    (tester) async {
      final directory = await Directory.systemTemp.createTemp(
        'openphon_atomic_grid_',
      );
      addTearDown(() => directory.delete(recursive: true));
      final path = '${directory.path}/annotation.TextGrid';
      final c = AnalysisController(
        Recording(
          id: 1,
          name: 'Test',
          relativePath: 'test.wav',
          createdAt: DateTime(2026),
          sampleRate: 44100,
          channels: 1,
        ),
      )..durationS = 1;
      addTearDown(c.dispose);
      c.annotationPath = path;
      c.newAnnotation();
      c.annotation!.setIntervalText(0, 0, 'first label');
      expect(await c.saveAnnotation(), isNull);
      c.annotation!.setIntervalText(0, 0, 'replacement label');
      expect(await c.saveAnnotation(), isNull);
      expect(c.annotation!.dirty, isFalse);
      final reopened = AnnotationDoc.fromTextGrid(
        await rust.readTextGrid(path: path),
      );
      expect(
        (reopened.tiers.single as IntervalTierModel).intervals.single.text,
        'replacement label',
      );
      expect(
        await directory.list().length,
        1,
        reason: 'No staging files remain after a save',
      );
    },
  );

  testWidgets(
    'failed native replacement retains the existing destination and removes staging files',
    (tester) async {
      final directory = await Directory.systemTemp.createTemp(
        'openphon_atomic_failure_',
      );
      addTearDown(() => directory.delete(recursive: true));
      final destination = await Directory(
        '${directory.path}/existing',
      ).create();
      final original = File('${destination.path}/keep.txt');
      await original.writeAsString('original data');
      final data = AnnotationDoc.singleIntervalTier(
        xmin: 0,
        xmax: 1,
        tierName: 'phones',
      ).toTextGrid();
      await expectLater(
        writeAnnotationAtomically(path: destination.path, data: data),
        throwsA(isA<FileSystemException>()),
      );
      expect(await original.readAsString(), 'original data');
      expect(await directory.list().length, 1);
    },
  );
}
