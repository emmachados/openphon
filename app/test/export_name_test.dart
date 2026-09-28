import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:openphon/src/audio/recorder_service.dart';
import 'package:path/path.dart' as p;

void main() {
  test('sanitizeFileName strips characters invalid on any platform', () {
    expect(
      sanitizeFileName('Recording 2026-07-17 22:43'),
      'Recording 2026-07-17 22-43',
    );
    expect(sanitizeFileName(r'a\b/c:d*e?f"g<h>i|j'), 'a-b-c-d-e-f-g-h-i-j');
    expect(sanitizeFileName('  plain name  '), 'plain name');
  });

  test('sanitizeFileName never returns an empty stem', () {
    expect(sanitizeFileName(''), 'recording');
    expect(sanitizeFileName(':::'), '---');
    expect(sanitizeFileName('   '), 'recording');
  });

  test('exportPairTo copies WAV and sibling TextGrid under one stem', () async {
    final src = await Directory.systemTemp.createTemp('openphon_src');
    final dst = await Directory.systemTemp.createTemp('openphon_dst');
    addTearDown(() async {
      await src.delete(recursive: true);
      await dst.delete(recursive: true);
    });
    final wav = p.join(src.path, 'rec_1.wav');
    await File(wav).writeAsString('WAVDATA');
    await File(p.join(src.path, 'rec_1.TextGrid')).writeAsString('GRID');

    final written = await exportPairTo(dst.path, wav, 'Take 22:43');
    expect(written, 2);
    expect(
      await File(p.join(dst.path, 'Take 22-43.wav')).readAsString(),
      'WAVDATA',
    );
    expect(
      await File(p.join(dst.path, 'Take 22-43.TextGrid')).readAsString(),
      'GRID',
    );
  });

  test('exportPairTo without a sibling TextGrid writes only the WAV', () async {
    final src = await Directory.systemTemp.createTemp('openphon_src');
    final dst = await Directory.systemTemp.createTemp('openphon_dst');
    addTearDown(() async {
      await src.delete(recursive: true);
      await dst.delete(recursive: true);
    });
    final wav = p.join(src.path, 'bare.wav');
    await File(wav).writeAsString('X');

    expect(await exportPairTo(dst.path, wav, 'bare'), 1);
    expect(await File(p.join(dst.path, 'bare.wav')).exists(), isTrue);
    expect(await File(p.join(dst.path, 'bare.TextGrid')).exists(), isFalse);
  });
}
