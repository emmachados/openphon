import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:openphon/src/analysis/spectrogram_image.dart';

Future<SpectrogramImage> _image(double t0, double t1) async {
  final completer = Completer<ui.Image>();
  ui.decodeImageFromPixels(
    Uint8List.fromList([0, 0, 0, 255]),
    1,
    1,
    ui.PixelFormat.rgba8888,
    completer.complete,
  );
  return SpectrogramImage(
    image: await completer.future,
    t0: t0,
    t1: t1,
    maxFreqHz: 5000,
  );
}

SpectrogramRequest _req(double t0, {double step = 0.002, int settings = 0}) =>
    SpectrogramRequest(t0: t0, t1: t0 + 1, timeStepS: step, settingsKey: settings);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('identical requests hit the cache without recompute', () async {
    final cache = SpectrogramCache();
    var computes = 0;
    Future<SpectrogramImage?> compute(SpectrogramRequest r) async {
      computes++;
      return _image(r.t0, r.t1);
    }

    final got = <SpectrogramImage>[];
    cache.request(_req(0), compute, got.add);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    cache.request(_req(0), compute, got.add);
    await Future<void>.delayed(const Duration(milliseconds: 50));

    expect(computes, 1);
    expect(got, hasLength(2));
    expect(identical(got[0], got[1]), isTrue);
  });

  test('burst of requests: only the newest survives (latest-wins)', () async {
    final cache = SpectrogramCache();
    final computed = <double>[];
    Future<SpectrogramImage?> compute(SpectrogramRequest r) async {
      computed.add(r.t0);
      await Future<void>.delayed(const Duration(milliseconds: 30));
      return _image(r.t0, r.t1);
    }

    final delivered = <double>[];
    for (final t0 in [0.0, 1.0, 2.0, 3.0]) {
      cache.request(_req(t0), compute, (img) => delivered.add(img.t0));
    }
    await Future<void>.delayed(const Duration(milliseconds: 200));

    // First starts immediately; intermediate 1.0 and 2.0 are skipped.
    expect(computed, [0.0, 3.0]);
    expect(delivered, isNotEmpty);
    expect(delivered.last, 3.0);
    expect(delivered, isNot(contains(1.0)));
    expect(delivered, isNot(contains(2.0)));
  });

  test('capacity eviction disposes oldest entries', () async {
    final cache = SpectrogramCache(capacity: 2);
    Future<SpectrogramImage?> compute(SpectrogramRequest r) => _image(r.t0, r.t1);

    for (final t0 in [0.0, 1.0, 2.0]) {
      cache.request(_req(t0), compute, (_) {});
      await Future<void>.delayed(const Duration(milliseconds: 30));
    }
    expect(cache.lookup(_req(0.0)), isNull, reason: 'oldest evicted');
    expect(cache.lookup(_req(1.0)), isNotNull);
    expect(cache.lookup(_req(2.0)), isNotNull);
  });

  test('different settings key misses the cache', () async {
    final cache = SpectrogramCache();
    var computes = 0;
    Future<SpectrogramImage?> compute(SpectrogramRequest r) async {
      computes++;
      return _image(r.t0, r.t1);
    }

    cache.request(_req(0, settings: 1), compute, (_) {});
    await Future<void>.delayed(const Duration(milliseconds: 30));
    cache.request(_req(0, settings: 2), compute, (_) {});
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(computes, 2);
  });
}
