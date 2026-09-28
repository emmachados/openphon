import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

/// Cheap, partial WAV reading for library thumbnails: a RIFF chunk walk to
/// find `fmt ` and `data` (imported files may carry LIST/fact/etc. chunks —
/// never assume the canonical 44-byte header), then a decimated envelope
/// from a handful of seek-reads. ~30 KB of I/O per file, no full decode,
/// no bridge call. Returns null on anything it cannot read; callers fall
/// back to a generic icon.
Future<List<double>?> wavEnvelopePeek(String path, {int buckets = 60}) async {
  RandomAccessFile? raf;
  try {
    raf = await File(path).open();
    final header = await _findChunks(raf);
    if (header == null) return null;
    final (fmt, dataStart, dataLen) = header;
    // Same encodings the Rust reader accepts: 16/24/32-bit PCM, 32 float.
    final supported = switch ((fmt.formatTag, fmt.bitsPerSample)) {
      (1, 16) || (1, 24) || (1, 32) || (3, 32) => true,
      _ => false,
    };
    if (!supported) return null;
    final bytesPerSample = fmt.bitsPerSample ~/ 8;
    final bytesPerFrame = bytesPerSample * fmt.channels;
    final frames = dataLen ~/ bytesPerFrame;
    if (frames <= 0) return null;

    const framesPerProbe = 256;
    final out = List<double>.filled(buckets, 0);
    for (var b = 0; b < buckets; b++) {
      final startFrame = (frames * b / buckets).floor();
      final n = math.min(framesPerProbe, frames - startFrame);
      if (n <= 0) break;
      await raf.setPosition(dataStart + startFrame * bytesPerFrame);
      final bytes = await raf.read(n * bytesPerFrame);
      final bd = ByteData.sublistView(bytes);
      var peak = 0.0;
      // First channel only; a thumbnail does not need the downmix.
      for (var off = 0;
          off + bytesPerSample <= bytes.length;
          off += bytesPerFrame) {
        final v = switch ((fmt.formatTag, fmt.bitsPerSample)) {
          (1, 16) => bd.getInt16(off, Endian.little) / 32768.0,
          // Dart ints are 64-bit: sign-extend 24-bit two's complement
          // explicitly (a shift round-trip does not).
          (1, 24) => _i24(bytes, off) / 8388608.0,
          (1, 32) => bd.getInt32(off, Endian.little) / 2147483648.0,
          _ => bd.getFloat32(off, Endian.little),
        }.abs();
        if (v > peak) peak = v;
      }
      // Float files may exceed full scale; the thumbnail stays in [0, 1].
      out[b] = math.min(1.0, peak);
    }
    return out;
  } catch (_) {
    return null;
  } finally {
    await raf?.close();
  }
}

int _i24(Uint8List b, int off) {
  final v = b[off] | (b[off + 1] << 8) | (b[off + 2] << 16);
  return v >= 0x800000 ? v - 0x1000000 : v;
}

class _Fmt {
  const _Fmt(this.formatTag, this.channels, this.bitsPerSample);
  final int formatTag;
  final int channels;
  final int bitsPerSample;
}

/// Walks the RIFF chunk list; returns the fmt fields plus the data chunk's
/// file offset and byte length (clamped to what the file actually holds —
/// recorders on several platforms leave bogus trailing chunk sizes).
Future<(_Fmt, int, int)?> _findChunks(RandomAccessFile raf) async {
  final fileLen = await raf.length();
  if (fileLen < 12) return null;
  await raf.setPosition(0);
  final riff = await raf.read(12);
  if (String.fromCharCodes(riff, 0, 4) != 'RIFF' ||
      String.fromCharCodes(riff, 8, 12) != 'WAVE') {
    return null;
  }
  _Fmt? fmt;
  var pos = 12;
  while (pos + 8 <= fileLen) {
    await raf.setPosition(pos);
    final head = await raf.read(8);
    if (head.length < 8) return null;
    final id = String.fromCharCodes(head, 0, 4);
    final size = ByteData.sublistView(
      Uint8List.fromList(head),
      4,
      8,
    ).getUint32(0, Endian.little);
    if (id == 'fmt ') {
      if (size < 16 || pos + 8 + 16 > fileLen) return null;
      // Read enough for WAVE_FORMAT_EXTENSIBLE's SubFormat tag at 24.
      final want = math.min(size, 26);
      final body = await raf.read(want);
      final bd = ByteData.sublistView(Uint8List.fromList(body));
      var tag = bd.getUint16(0, Endian.little);
      if (tag == 0xFFFE && body.length >= 26) {
        tag = bd.getUint16(24, Endian.little);
      }
      fmt = _Fmt(
        tag,
        math.max(1, bd.getUint16(2, Endian.little)),
        bd.getUint16(14, Endian.little),
      );
    } else if (id == 'data') {
      if (fmt == null) return null;
      final available = fileLen - (pos + 8);
      return (fmt, pos + 8, math.min(size, available));
    }
    pos += 8 + size + (size & 1);
  }
  return null;
}
