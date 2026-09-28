import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:openphon/src/audio/playback_service.dart';

import 'bridge_test.dart' show sineWav;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('PlaybackService plays a file and reports position',
      (tester) async {
    await tester.runAsync(() async {
      final dir = await Directory.systemTemp.createTemp('openphon_play');
      final path = '${dir.path}${Platform.pathSeparator}tone.wav';
      await File(path).writeAsBytes(
        sineWav(freqHz: 440, sampleRate: 44100, seconds: 2.0),
      );

      final service = PlaybackService();
      await service.load(path);
      expect(
        service.duration.inMilliseconds,
        closeTo(2000, 100),
        reason: 'duration should be read from the file',
      );

      await service.play();
      await Future<void>.delayed(const Duration(milliseconds: 700));
      expect(service.playing.value, isTrue);
      expect(
        service.position.value.inMilliseconds,
        greaterThan(200),
        reason: 'position should advance while playing',
      );

      await service.pause();
      final paused = service.position.value;
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(service.position.value, paused,
          reason: 'position must not advance while paused');

      // Play a bounded range: from 0.5 s until 1.0 s.
      await service.play(
        from: const Duration(milliseconds: 500),
        until: const Duration(milliseconds: 1000),
      );
      await Future<void>.delayed(const Duration(milliseconds: 900));
      expect(service.playing.value, isFalse,
          reason: 'playback should stop at the until bound');
      expect(
        service.position.value.inMilliseconds,
        closeTo(1000, 150),
      );

      // Half speed: ~700 ms of wall clock advances the playhead ~350 ms.
      await service.setRate(0.5);
      await service.play(from: Duration.zero);
      await Future<void>.delayed(const Duration(milliseconds: 700));
      expect(service.playing.value, isTrue);
      expect(
        service.position.value.inMilliseconds,
        inInclusiveRange(150, 550),
        reason: 'position should advance at about half the wall clock',
      );
      await service.pause();
      await service.setRate(1.0);

      // Loop: a 0.3 s window is still playing after 1 s of wall clock,
      // with the playhead inside the window.
      await service.play(
        from: const Duration(milliseconds: 500),
        until: const Duration(milliseconds: 800),
        loop: true,
      );
      await Future<void>.delayed(const Duration(milliseconds: 1000));
      expect(service.playing.value, isTrue,
          reason: 'looped playback must not stop at the until bound');
      expect(
        service.position.value.inMilliseconds,
        inInclusiveRange(450, 900),
        reason: 'looped playhead stays around the window',
      );
      await service.pause();
      expect(service.playing.value, isFalse);

      await service.dispose();
      await dir.delete(recursive: true);
    });
  });
}
