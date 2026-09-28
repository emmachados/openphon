import 'package:flutter_test/flutter_test.dart';
import 'package:openphon/src/audio/wav_math.dart';

void main() {
  test('one second of 16-bit mono 44.1 kHz audio', () {
    expect(
      wavDurationMs(fileBytes: kWavHeaderBytes + 88200, sampleRate: 44100),
      1000,
    );
  });

  test('stereo halves the duration for the same payload', () {
    expect(
      wavDurationMs(
        fileBytes: kWavHeaderBytes + 88200,
        sampleRate: 44100,
        channels: 2,
      ),
      500,
    );
  });

  test('header-only file has no duration', () {
    expect(wavDurationMs(fileBytes: kWavHeaderBytes, sampleRate: 44100), null);
    expect(wavDurationMs(fileBytes: 10, sampleRate: 44100), null);
  });
}
