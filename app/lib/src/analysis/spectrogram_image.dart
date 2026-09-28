import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';
import 'dart:ui' as ui;

import '../rust/api/core.dart' as rust;

/// A rendered spectrogram image tagged with the absolute time/frequency
/// range it covers, so the painter can position it under any viewport.
class SpectrogramImage {
  SpectrogramImage({
    required this.image,
    required this.t0,
    required this.t1,
    required this.maxFreqHz,
  });

  /// Image pixels: x = time (t0..t1), y = frequency (maxFreqHz..0 top-down).
  final ui.Image image;
  final double t0;
  final double t1;
  final double maxFreqHz;

  void dispose() => image.dispose();
}

/// Grayscale conversion, Praat-style: white = quiet, black = loud, with a
/// dynamic range below the per-image maximum. Runs in a worker isolate.
Uint8List _dbToRgba(
  Float32List valuesDb,
  int nFrames,
  int nBins,
  double dynamicRangeDb,
) {
  var maxDb = -1e9;
  for (final v in valuesDb) {
    if (v > maxDb) maxDb = v.toDouble();
  }
  final floor = maxDb - dynamicRangeDb;
  final out = Uint8List(nFrames * nBins * 4);
  // Image rows top-down = high frequency first.
  for (var y = 0; y < nBins; y++) {
    final bin = nBins - 1 - y;
    for (var x = 0; x < nFrames; x++) {
      final db = valuesDb[x * nBins + bin];
      var lum = (db - floor) / dynamicRangeDb;
      if (lum < 0) lum = 0;
      if (lum > 1) lum = 1;
      final v = (255 * (1 - lum)).round();
      final o = (y * nFrames + x) * 4;
      out[o] = v;
      out[o + 1] = v;
      out[o + 2] = v;
      out[o + 3] = 255;
    }
  }
  return out;
}

Future<SpectrogramImage?> buildSpectrogramImage(
  rust.SpectrogramData sg, {
  required double dynamicRangeDb,
  required double maxFreqHz,
}) async {
  if (sg.nFrames == 0 || sg.nBins == 0) return null;
  final rgba = await Isolate.run(
    () => _dbToRgba(sg.valuesDb, sg.nFrames, sg.nBins, dynamicRangeDb),
  );
  final completer = Completer<ui.Image>();
  ui.decodeImageFromPixels(
    rgba,
    sg.nFrames,
    sg.nBins,
    ui.PixelFormat.rgba8888,
    completer.complete,
  );
  final image = await completer.future;
  final halfStep = sg.timeStepS / 2;
  return SpectrogramImage(
    image: image,
    t0: sg.firstTimeS - halfStep,
    t1: sg.firstTimeS + (sg.nFrames - 1) * sg.timeStepS + halfStep,
    // Bin i sits at i * freqStepHz; the top pixel row is the highest bin.
    maxFreqHz: (sg.nBins - 1) * sg.freqStepHz,
  );
}

/// Request descriptor quantized to the frame grid so equivalent viewports
/// hit the cache.
class SpectrogramRequest {
  SpectrogramRequest({
    required this.t0,
    required this.t1,
    required this.timeStepS,
    required this.settingsKey,
  });

  final double t0;
  final double t1;
  final double timeStepS;

  /// Hash of every analysis setting that affects pixel values.
  final int settingsKey;

  @override
  bool operator ==(Object other) =>
      other is SpectrogramRequest &&
      other.t0 == t0 &&
      other.t1 == t1 &&
      other.timeStepS == timeStepS &&
      other.settingsKey == settingsKey;

  @override
  int get hashCode => Object.hash(t0, t1, timeStepS, settingsKey);
}

/// Small LRU of rendered images + single-flight, latest-wins scheduling.
class SpectrogramCache {
  SpectrogramCache({this.capacity = 6});

  final int capacity;
  final _entries = <SpectrogramRequest, SpectrogramImage>{};
  int _generation = 0;
  bool _inFlight = false;
  SpectrogramRequest? _pending;
  Future<SpectrogramImage?> Function(SpectrogramRequest)? _compute;

  SpectrogramImage? lookup(SpectrogramRequest req) {
    final hit = _entries.remove(req);
    if (hit != null) _entries[req] = hit; // move to most-recent
    return hit;
  }

  /// Compute (or fetch) the image for [req]; stale in-flight results are
  /// dropped. [onReady] fires only for the newest surviving request.
  void request(
    SpectrogramRequest req,
    Future<SpectrogramImage?> Function(SpectrogramRequest) compute,
    void Function(SpectrogramImage) onReady,
  ) {
    if (_entries.containsKey(req)) {
      onReady(lookup(req)!);
      return;
    }
    _compute = compute;
    _pending = req;
    final gen = ++_generation;
    if (_inFlight) return; // latest-wins: picked up when current lands
    _run(gen, onReady);
  }

  Future<void> _run(int gen, void Function(SpectrogramImage) onReady) async {
    while (true) {
      final req = _pending;
      final compute = _compute;
      if (req == null || compute == null) return;
      _pending = null;
      _inFlight = true;
      SpectrogramImage? image;
      try {
        image = await compute(req);
      } finally {
        _inFlight = false;
      }
      if (image != null) {
        _insert(req, image);
        if (_generation == gen || _pending == null) onReady(image);
      }
      if (_pending == null) return;
      gen = _generation;
    }
  }

  void _insert(SpectrogramRequest req, SpectrogramImage image) {
    _entries[req] = image;
    while (_entries.length > capacity) {
      final oldest = _entries.keys.first;
      _entries.remove(oldest)!.dispose();
    }
  }

  void clear() {
    for (final e in _entries.values) {
      e.dispose();
    }
    _entries.clear();
    _generation++;
    _pending = null;
  }
}
