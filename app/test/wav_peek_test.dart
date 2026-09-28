import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:openphon/src/audio/wav_peek.dart';
import 'package:openphon/src/ui/tile_meta.dart';

Uint8List _wav({
  int sampleRate = 44100,
  int channels = 1,
  int bits = 16,
  int formatTag = 1,
  required List<int> samples,
  List<int> preDataChunks = const [],
}) {
  final dataLen = samples.length * 2;
  final extra = preDataChunks.length;
  final b = BytesBuilder();
  void u32(int v) =>
      b.add(Uint8List(4)..buffer.asByteData().setUint32(0, v, Endian.little));
  void u16(int v) =>
      b.add(Uint8List(2)..buffer.asByteData().setUint16(0, v, Endian.little));
  b.add('RIFF'.codeUnits);
  u32(4 + 24 + extra + 8 + dataLen);
  b.add('WAVE'.codeUnits);
  b.add('fmt '.codeUnits);
  u32(16);
  u16(formatTag);
  u16(channels);
  u32(sampleRate);
  u32(sampleRate * channels * bits ~/ 8);
  u16(channels * bits ~/ 8);
  u16(bits);
  b.add(preDataChunks);
  b.add('data'.codeUnits);
  u32(dataLen);
  for (final s in samples) {
    u16(s & 0xFFFF);
  }
  return b.toBytes();
}

/// Like [_wav] but with a caller-encoded data payload (24-bit, float…).
Uint8List _wavPayload({
  int sampleRate = 44100,
  int channels = 1,
  required int bits,
  required int formatTag,
  required List<int> dataBytes,
}) {
  final b = BytesBuilder();
  void u32(int v) =>
      b.add(Uint8List(4)..buffer.asByteData().setUint32(0, v, Endian.little));
  void u16(int v) =>
      b.add(Uint8List(2)..buffer.asByteData().setUint16(0, v, Endian.little));
  b.add('RIFF'.codeUnits);
  u32(4 + 24 + 8 + dataBytes.length);
  b.add('WAVE'.codeUnits);
  b.add('fmt '.codeUnits);
  u32(16);
  u16(formatTag);
  u16(channels);
  u32(sampleRate);
  u32(sampleRate * channels * bits ~/ 8);
  u16(channels * bits ~/ 8);
  u16(bits);
  b.add('data'.codeUnits);
  u32(dataBytes.length);
  b.add(dataBytes);
  return b.toBytes();
}

List<int> _listChunk() {
  final b = BytesBuilder();
  b.add('LIST'.codeUnits);
  b.add(
    Uint8List(4)..buffer.asByteData().setUint32(0, 10, Endian.little),
  );
  b.add('INFOhello!'.codeUnits);
  return b.toBytes();
}

Future<String> _write(Directory dir, String name, Uint8List bytes) async {
  final f = File('${dir.path}/$name');
  await f.writeAsBytes(bytes);
  return f.path;
}

void main() {
  late Directory tmp;
  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('openphon_peek_');
  });
  tearDown(() => tmp.delete(recursive: true));

  test('envelope of a known sine follows its amplitude', () async {
    final samples = List<int>.generate(
      44100,
      (i) => (0.5 * 32767 * math.sin(2 * math.pi * 220 * i / 44100)).round(),
    );
    final path = await _write(tmp, 'sine.wav', _wav(samples: samples));
    final env = await wavEnvelopePeek(path, buckets: 20);
    expect(env, isNotNull);
    expect(env, hasLength(20));
    for (final v in env!) {
      expect(v, closeTo(0.5, 0.06));
    }
  });

  test('24-bit and float32 envelopes follow amplitude', () async {
    // Constant 0.5-amplitude square-ish signal: every bucket peaks ~0.5.
    final b24 = BytesBuilder();
    for (var i = 0; i < 4096; i++) {
      final v = (i % 2 == 0 ? 1 : -1) * 4194304; // ±0.5 in 24-bit
      final le = Uint8List(4)..buffer.asByteData().setInt32(0, v, Endian.little);
      b24.add(le.sublist(0, 3));
    }
    final p24 = await _write(
      tmp,
      'p24.wav',
      _wavPayload(bits: 24, formatTag: 1, dataBytes: b24.toBytes()),
    );
    final e24 = (await wavEnvelopePeek(p24, buckets: 8))!;
    for (final v in e24) {
      expect(v, closeTo(0.5, 0.01));
    }

    final bf = BytesBuilder();
    for (var i = 0; i < 4096; i++) {
      bf.add(
        Uint8List(4)
          ..buffer.asByteData().setFloat32(
            0,
            i % 2 == 0 ? 1.5 : -1.5, // beyond full scale: must clamp to 1
            Endian.little,
          ),
      );
    }
    final pf = await _write(
      tmp,
      'pf.wav',
      _wavPayload(bits: 32, formatTag: 3, dataBytes: bf.toBytes()),
    );
    final ef = (await wavEnvelopePeek(pf, buckets: 8))!;
    for (final v in ef) {
      expect(v, 1.0);
    }
  });

  test('walks past a LIST chunk before data', () async {
    final path = await _write(
      tmp,
      'list.wav',
      _wav(samples: List.filled(1000, 1000), preDataChunks: _listChunk()),
    );
    final env = await wavEnvelopePeek(path, buckets: 8);
    expect(env, isNotNull);
    expect(env!.first, closeTo(1000 / 32768, 0.001));
  });

  test('rejects non-PCM, truncated, and non-WAV files', () async {
    final float = await _write(
      tmp,
      'float.wav',
      _wav(samples: List.filled(100, 0), formatTag: 3),
    );
    expect(await wavEnvelopePeek(float), isNull);

    final truncated = await _write(
      tmp,
      'trunc.wav',
      Uint8List.sublistView(_wav(samples: List.filled(100, 0)), 0, 20),
    );
    expect(await wavEnvelopePeek(truncated), isNull);

    final junk = await _write(
      tmp,
      'junk.wav',
      Uint8List.fromList(List.filled(400, 7)),
    );
    expect(await wavEnvelopePeek(junk), isNull);

    expect(await wavEnvelopePeek('${tmp.path}/missing.wav'), isNull);
  });

  test('stereo peeks only the first channel without crashing', () async {
    final frames = <int>[];
    for (var i = 0; i < 500; i++) {
      frames
        ..add(8000) // left
        ..add(0); // right
    }
    final path = await _write(
      tmp,
      'stereo.wav',
      _wav(samples: frames, channels: 2),
    );
    final env = await wavEnvelopePeek(path, buckets: 4);
    expect(env, isNotNull);
    expect(env!.first, closeTo(8000 / 32768, 0.001));
  });

  test('formatBytes covers the unit boundaries', () {
    expect(formatBytes(999), '999 B');
    expect(formatBytes(912000), '912 kB');
    expect(formatBytes(12400000), '12.4 MB');
  });
}
