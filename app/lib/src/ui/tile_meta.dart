import 'dart:io';

import '../audio/recorder_service.dart' show findSiblingTextGrid;
import '../audio/wav_peek.dart';
import '../rust/api/core.dart' as rust_core;

/// Lazily computed per-tile decoration: waveform envelope, TextGrid badge,
/// file size, recording-quality figures. Null envelope means "fall back to
/// the generic icon"; null quality figures mean "not computed / not
/// estimable" and the tile simply omits them.
class TileMeta {
  const TileMeta({
    this.envelope,
    this.hasTextGrid = false,
    this.sizeBytes,
    this.clippedPct,
    this.estSnrDb,
  });

  final List<double>? envelope;
  final bool hasTextGrid;
  final int? sizeBytes;
  final double? clippedPct;
  final double? estSnrDb;
}

/// Memoizes one [TileMeta] future per WAV, keyed by path + mtime so
/// re-recording or re-importing under the same name invalidates naturally.
/// Owned by the library page; [clear] after deletes keeps it bounded.
class TileMetaCache {
  final Map<String, Future<TileMeta>> _cache = {};

  Future<TileMeta> load(String absWavPath) async {
    DateTime? mtime;
    try {
      mtime = await File(absWavPath).lastModified();
    } catch (_) {
      return const TileMeta();
    }
    final key = '$absWavPath:${mtime.microsecondsSinceEpoch}';
    return _cache.putIfAbsent(key, () => _load(absWavPath));
  }

  Future<TileMeta> _load(String absWavPath) async {
    int? size;
    try {
      size = await File(absWavPath).length();
    } catch (_) {}
    double? clippedPct;
    double? estSnrDb;
    try {
      final q = await rust_core.wavQuality(path: absWavPath);
      clippedPct = q.clippedPct;
      estSnrDb = q.estSnrDb;
    } catch (_) {
      // Bridge unavailable (tests) or unreadable file: omit the figures.
    }
    return TileMeta(
      envelope: await wavEnvelopePeek(absWavPath),
      hasTextGrid: await findSiblingTextGrid(absWavPath) != null,
      sizeBytes: size,
      clippedPct: clippedPct,
      estSnrDb: estSnrDb,
    );
  }

  void clear() => _cache.clear();
}

/// "912 kB", "12.4 MB" — thumbnail subtitle sizes.
String formatBytes(int bytes) {
  if (bytes < 1000) return '$bytes B';
  if (bytes < 1000 * 1000) return '${(bytes / 1000).round()} kB';
  return '${(bytes / 1e6).toStringAsFixed(1)} MB';
}

/// Clipping is flagged from the first affected samples: even 0.05% of a
/// recording on the rails is audible and biases measurements. The SNR
/// warning threshold is where formant analysis on field recordings gets
/// visibly unreliable.
const double clipWarnPct = 0.05;
const double snrWarnDb = 15.0;

/// Quality summary for the tile subtitle: "clip 1.2% · SNR ~34 dB".
/// Clipping is shown only when present; the SNR estimate whenever it
/// exists. Null when there is nothing to show.
String? formatQuality(double? clippedPct, double? estSnrDb) {
  final parts = <String>[
    if (clippedPct != null && clippedPct >= clipWarnPct)
      'clip ${clippedPct.toStringAsFixed(clippedPct < 10 ? 1 : 0)}%',
    if (estSnrDb != null) 'SNR ~${estSnrDb.round()} dB',
  ];
  return parts.isEmpty ? null : parts.join(' · ');
}

/// Whether the figures warrant warning emphasis in the UI.
bool isPoorQuality(double? clippedPct, double? estSnrDb) =>
    (clippedPct != null && clippedPct >= clipWarnPct) ||
    (estSnrDb != null && estSnrDb < snrWarnDb);
