import 'package:flutter_test/flutter_test.dart';
import 'package:openphon/src/audio/recorder_service.dart'
    show sanitizeFileName;
import 'package:openphon/src/data/database.dart';
import 'package:openphon/src/data/library_backup.dart';

Recording _rec(int id, String name, {int? durationMs, int sampleRate = 44100}) {
  return Recording(
    id: id,
    name: name,
    relativePath: 'recordings/f$id.wav',
    createdAt: DateTime.utc(2026, 7, 19, 12, 30),
    durationMs: durationMs,
    sampleRate: sampleRate,
    channels: 1,
  );
}

void main() {
  test('stems come from display names, sanitized and deduped', () {
    final items = planBackup([
      (_rec(1, 'Take 23:49'), '/a/f1.wav', null),
      (_rec(2, 'Take 23:49'), '/a/f2.wav', '/a/f2.TextGrid'),
      (_rec(3, ''), '/a/f3.wav', null),
    ], sanitizeFileName);
    expect(items[0].stem, isNot(contains(':')));
    expect(items[1].stem, endsWith(' (2)'));
    expect(items[1].stem, isNot(items[0].stem));
    expect(items[2].stem, 'recording');
  });

  test('manifest lists files, format facts, and escapes commas', () {
    final items = planBackup([
      (_rec(1, 'clean, with comma', durationMs: 6720), '/a/f1.wav',
          '/a/f1.TextGrid'),
      (_rec(2, 'plain', sampleRate: 16000), '/a/f2.wav', null),
    ], sanitizeFileName);
    final csv = backupManifestCsv(items, (path) => path.endsWith('f1.wav')
        ? 1234
        : 99);
    final lines = csv.trim().split('\n');
    expect(
      lines[0],
      'name,file,textgrid,sample_rate_hz,channels,duration_s,size_bytes,created',
    );
    expect(lines[1], contains('"clean, with comma"'));
    expect(lines[1], contains('.TextGrid'));
    expect(lines[1], contains(',6.720,'));
    expect(lines[1], contains(',1234,'));
    expect(lines[1], contains('2026-07-19T12:30:00.000Z'));
    // No TextGrid and no duration: empty fields, not crashes.
    expect(lines[2], contains('plain.wav,,16000,1,,99,'));
  });
}
