import 'package:flutter_test/flutter_test.dart';
import 'package:openphon/src/analysis/analysis_controller.dart';
import 'package:openphon/src/audio/playback_service.dart';
import 'package:openphon/src/data/database.dart';

void main() {
  test('scaledElapsed maps wall clock to media time at the rate', () {
    const s = Duration(seconds: 1);
    expect(PlaybackService.scaledElapsed(s, 1.0), s);
    expect(
      PlaybackService.scaledElapsed(s, 0.5),
      const Duration(milliseconds: 500),
    );
    expect(
      PlaybackService.scaledElapsed(const Duration(milliseconds: 700), 0.75),
      const Duration(microseconds: 525000),
    );
    expect(PlaybackService.scaledElapsed(Duration.zero, 0.5), Duration.zero);
  });

  test('loop toggle flips and notifies without touching playback', () {
    final c = AnalysisController(
      Recording(
        id: 1,
        name: 'r',
        relativePath: 'r.wav',
        createdAt: DateTime(2026),
        sampleRate: 44100,
        channels: 1,
      ),
    );
    var notified = 0;
    c.addListener(() => notified++);
    expect(c.loopSelection, isFalse);
    c.toggleLoopSelection();
    expect(c.loopSelection, isTrue);
    c.toggleLoopSelection();
    expect(c.loopSelection, isFalse);
    expect(notified, 2);
  });
}
