import 'dart:io';

import 'package:file_selector/file_selector.dart' show XFile;
import 'package:path/path.dart' as p;

/// What [importWav] found out about one picked file.
enum WavImportStatus { imported, unsupportedFormat, unreadable }

class WavImportOutcome {
  const WavImportOutcome(
    this.status, {
    this.name,
    this.destPath,
    this.sampleRate,
    this.channels,
    this.durationMs,
    this.detail,
  });

  final WavImportStatus status;
  final String? name;
  final String? destPath;
  final int? sampleRate;
  final int? channels;
  final int? durationMs;

  /// Raw parser error for failed imports; the reader's messages are
  /// user-appropriate (e.g. the too-long guard says how to fix it).
  final String? detail;
}

/// Probe result the caller's WAV reader must supply (mirrors the Rust
/// bridge's WavInfo without importing bridge types here, so this file is
/// unit-testable without the native library).
class WavProbe {
  const WavProbe({
    required this.sampleRate,
    required this.channels,
    required this.durationS,
  });

  final int sampleRate;
  final int channels;
  final double durationS;
}

/// `name.wav`, `name (2).wav`, `name (3).wav`, ... first one that does not
/// exist in [dir].
String pickUniqueDestination(Directory dir, String stem) {
  var candidate = p.join(dir.path, '$stem.wav');
  var n = 2;
  while (File(candidate).existsSync()) {
    candidate = p.join(dir.path, '$stem (${n++}).wav');
  }
  return candidate;
}

/// True when [rawError] from the WAV parser means "real file, unsupported
/// encoding" (8-bit/compressed) rather than "not a WAV at all".
bool isUnsupportedEncodingError(String rawError) {
  final s = rawError.toLowerCase();
  return s.contains('format tag') ||
      s.contains('bit') && s.contains('depth') ||
      s.contains('bits per sample') ||
      s.contains('unsupportedbitdepth');
}

/// Copies [file] into [recordingsDir] under a unique name derived from
/// [sanitizedStem], validates it with [probe], and reports the outcome.
/// On validation failure the copy is deleted; nothing is registered here —
/// the caller owns the database insert (it has the DB and the l10n).
///
/// The copy goes through XFile.saveTo, which streams the picked file's
/// bytes: on Android the picker returns SAF content URIs whose `path` is
/// not a filesystem path, so File(file.path) must never be touched.
Future<WavImportOutcome> importWav(
  XFile file, {
  required Directory recordingsDir,
  required String sanitizedStem,
  required Future<WavProbe> Function(String path) probe,
}) async {
  await recordingsDir.create(recursive: true);
  final dest = pickUniqueDestination(
    recordingsDir,
    sanitizedStem.isEmpty ? 'imported' : sanitizedStem,
  );
  try {
    await file.saveTo(dest);
  } catch (_) {
    try {
      await File(dest).delete();
    } catch (_) {}
    return const WavImportOutcome(WavImportStatus.unreadable);
  }
  try {
    final info = await probe(dest);
    return WavImportOutcome(
      WavImportStatus.imported,
      name: p.basenameWithoutExtension(dest),
      destPath: dest,
      sampleRate: info.sampleRate,
      channels: info.channels,
      durationMs: (info.durationS * 1000).round(),
    );
  } catch (e) {
    try {
      await File(dest).delete();
    } catch (_) {}
    return WavImportOutcome(
      isUnsupportedEncodingError('$e')
          ? WavImportStatus.unsupportedFormat
          : WavImportStatus.unreadable,
      detail: '$e',
    );
  }
}
