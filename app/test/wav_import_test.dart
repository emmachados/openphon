import 'dart:io';
import 'dart:typed_data';

import 'package:file_selector/file_selector.dart' show XFile;
import 'package:flutter_test/flutter_test.dart';
import 'package:openphon/src/data/wav_import.dart';
import 'package:path/path.dart' as p;

Uint8List _canonicalWav({int sampleRate = 44100, int samples = 100}) {
  final data = ByteData(44 + samples * 2);
  void ascii(int offset, String s) {
    for (var i = 0; i < s.length; i++) {
      data.setUint8(offset + i, s.codeUnitAt(i));
    }
  }

  ascii(0, 'RIFF');
  data.setUint32(4, 36 + samples * 2, Endian.little);
  ascii(8, 'WAVE');
  ascii(12, 'fmt ');
  data.setUint32(16, 16, Endian.little);
  data.setUint16(20, 1, Endian.little); // PCM
  data.setUint16(22, 1, Endian.little); // mono
  data.setUint32(24, sampleRate, Endian.little);
  data.setUint32(28, sampleRate * 2, Endian.little);
  data.setUint16(32, 2, Endian.little);
  data.setUint16(34, 16, Endian.little);
  ascii(36, 'data');
  data.setUint32(40, samples * 2, Endian.little);
  return data.buffer.asUint8List();
}

void main() {
  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('openphon_import_');
  });
  tearDown(() async {
    await tmp.delete(recursive: true);
  });

  test('unique destination adds (2), (3) suffixes', () {
    expect(pickUniqueDestination(tmp, 'take'), p.join(tmp.path, 'take.wav'));
    File(p.join(tmp.path, 'take.wav')).writeAsBytesSync([]);
    expect(
      pickUniqueDestination(tmp, 'take'),
      p.join(tmp.path, 'take (2).wav'),
    );
    File(p.join(tmp.path, 'take (2).wav')).writeAsBytesSync([]);
    expect(
      pickUniqueDestination(tmp, 'take'),
      p.join(tmp.path, 'take (3).wav'),
    );
  });

  test('unsupported-encoding detection matches the Rust error strings', () {
    expect(
      isUnsupportedEncodingError(
        'unsupported audio format tag 85 (PCM or IEEE float)',
      ),
      isTrue,
    );
    expect(
      isUnsupportedEncodingError('UnsupportedBitDepth: 8'),
      isTrue,
    );
    expect(isUnsupportedEncodingError('unsupported bits per sample'), isTrue);
    expect(isUnsupportedEncodingError('not a RIFF file'), isFalse);
    expect(isUnsupportedEncodingError('io error: permission denied'), isFalse);
  });

  test('successful import copies, probes, and reports metadata', () async {
    final src = File(p.join(tmp.path, 'src.wav'))
      ..writeAsBytesSync(_canonicalWav(sampleRate: 16000, samples: 16000));
    final dest = Directory(p.join(tmp.path, 'recordings'));
    final outcome = await importWav(
      XFile(src.path),
      recordingsDir: dest,
      sanitizedStem: 'vowel sweep',
      probe: (path) async {
        expect(await File(path).length(), await src.length());
        return const WavProbe(sampleRate: 16000, channels: 1, durationS: 1.0);
      },
    );
    expect(outcome.status, WavImportStatus.imported);
    expect(outcome.name, 'vowel sweep');
    expect(outcome.sampleRate, 16000);
    expect(outcome.durationMs, 1000);
    expect(File(outcome.destPath!).existsSync(), isTrue);
  });

  test('probe failure deletes the copy and classifies the error', () async {
    final src = File(p.join(tmp.path, 'bad.wav'))
      ..writeAsBytesSync(_canonicalWav());
    final dest = Directory(p.join(tmp.path, 'recordings'));
    final outcome = await importWav(
      XFile(src.path),
      recordingsDir: dest,
      sanitizedStem: 'bad',
      probe: (_) async =>
          throw Exception('unsupported audio format tag 85 (PCM or IEEE float)'),
    );
    expect(outcome.status, WavImportStatus.unsupportedFormat);
    expect(dest.listSync().whereType<File>(), isEmpty);
    expect(outcome.detail, contains('format tag 85'));
  });

  test('importWav substitutes a stem for nameless files', () async {
    final src = File(p.join(tmp.path, 's.wav'))
      ..writeAsBytesSync(_canonicalWav());
    final outcome = await importWav(
      XFile(src.path),
      recordingsDir: Directory(p.join(tmp.path, 'recordings')),
      sanitizedStem: '',
      probe: (_) async =>
          const WavProbe(sampleRate: 44100, channels: 1, durationS: 0.1),
    );
    expect(outcome.name, 'imported');
  });
}
