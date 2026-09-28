import 'package:flutter_test/flutter_test.dart';
import 'package:openphon/src/audio/recorder_service.dart';
import 'package:openphon/src/ui/tile_meta.dart';

void main() {
  group('formatQuality', () {
    test('nothing to show yields null', () {
      expect(formatQuality(null, null), isNull);
      expect(formatQuality(0.0, null), isNull);
      expect(formatQuality(0.01, null), isNull); // below display threshold
    });

    test('snr alone', () {
      expect(formatQuality(0.0, 33.6), 'SNR ~34 dB');
    });

    test('clip alone, one decimal under 10%', () {
      expect(formatQuality(1.23, null), 'clip 1.2%');
    });

    test('clip rounds to integers at 10% and above', () {
      expect(formatQuality(23.4, null), 'clip 23%');
    });

    test('both figures joined', () {
      expect(formatQuality(0.5, 12.2), 'clip 0.5% · SNR ~12 dB');
    });
  });

  group('isPoorQuality', () {
    test('clean recording is not poor', () {
      expect(isPoorQuality(0.0, 40.0), isFalse);
      expect(isPoorQuality(null, null), isFalse);
    });

    test('clipping flags poor', () {
      expect(isPoorQuality(0.1, 40.0), isTrue);
    });

    test('low snr flags poor', () {
      expect(isPoorQuality(0.0, 10.0), isTrue);
    });
  });

  group('clipIndicatorActive', () {
    final t0 = DateTime(2026, 1, 1, 12);

    test('unlit with no clip seen', () {
      expect(clipIndicatorActive(null, t0), isFalse);
    });

    test('lit within the hold window', () {
      expect(
        clipIndicatorActive(t0, t0.add(const Duration(seconds: 1))),
        isTrue,
      );
    });

    test('retires after the hold window', () {
      expect(
        clipIndicatorActive(t0, t0.add(const Duration(seconds: 3))),
        isFalse,
      );
    });
  });
}
