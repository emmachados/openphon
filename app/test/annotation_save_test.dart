import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:openphon/src/analysis/analysis_controller.dart';
import 'package:openphon/src/annotation/annotation_model.dart';
import 'package:openphon/src/data/database.dart';

void main() {
  final recording = Recording(
    id: 1,
    name: 'Test',
    relativePath: 'test.wav',
    createdAt: DateTime(2026),
    sampleRate: 44100,
    channels: 1,
  );

  test(
    'an edit made during a save stays unsaved and concurrent saves share one write',
    () async {
      final pending = Completer<void>();
      var writes = 0;
      final c = AnalysisController(
        recording,
        writeAnnotation: ({required path, required data}) async {
          writes++;
          expect(data.tiers.single.texts, ['']);
          await pending.future;
        },
      )..durationS = 1;
      addTearDown(c.dispose);
      c.annotationPath = 'test.TextGrid';
      c.newAnnotation();
      final first = c.saveAnnotation();
      final second = c.saveAnnotation();
      expect(writes, 1);
      c.annotation!.setIntervalText(0, 0, 'edited during save');
      pending.complete();
      expect(await first, isNull);
      expect(await second, isNull);
      expect(c.annotation!.dirty, isTrue);
      expect(
        (c.annotation!.doc.tiers.single as IntervalTierModel)
            .intervals
            .single
            .text,
        'edited during save',
      );
      c.annotationUndo();
      expect(c.annotation!.dirty, isFalse);
    },
  );

  test('a failed save retains changes and can be retried', () async {
    var fail = true;
    final c = AnalysisController(
      recording,
      writeAnnotation: ({required path, required data}) async {
        if (fail) throw StateError('storage full');
      },
    )..durationS = 1;
    addTearDown(c.dispose);
    c.annotationPath = 'test.TextGrid';
    c.newAnnotation();
    expect(await c.saveAnnotation(), contains('storage full'));
    expect(c.annotation!.dirty, isTrue);
    fail = false;
    expect(await c.saveAnnotation(), isNull);
    expect(c.annotation!.dirty, isFalse);
  });
}
