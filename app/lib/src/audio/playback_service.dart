import 'dart:async';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';

/// File playback with a smoothly interpolated position for the cursor.
///
/// The position is NOT taken from `onPositionChanged`: on Windows the
/// plugin delivers those events on a non-platform thread and they can be
/// dropped entirely. Instead the playhead is a wall-clock interpolation
/// from the last known position, re-anchored every few hundred ms by an
/// explicit `getCurrentPosition()` query (an ordinary method-channel
/// round-trip, which is reliable on every platform).
class PlaybackService {
  final AudioPlayer _player = AudioPlayer();

  /// Current playhead, republished at ~60 Hz while playing.
  final ValueNotifier<Duration> position = ValueNotifier(Duration.zero);
  final ValueNotifier<bool> playing = ValueNotifier(false);

  /// Playback rate (1.0 = normal); kept for the whole service lifetime.
  final ValueNotifier<double> rate = ValueNotifier(1.0);

  final Stopwatch _sinceAnchor = Stopwatch();
  Duration _anchor = Duration.zero;
  Duration? _stopAt;
  Duration? _loopFrom;
  Duration _duration = Duration.zero;
  Timer? _frameTimer;
  Timer? _syncTimer;
  bool _disposed = false;

  /// [fallbackDuration] covers backends that report no duration for some
  /// WAVs (seen with Media Foundation on Windows).
  Future<void> load(String absolutePath, {Duration? fallbackDuration}) async {
    // Do not request Android audio focus: on HyperOS (Xiaomi, Android 16)
    // the focus-grant callback never completes, so the plugin silently
    // never calls MediaPlayer.start() and the position pins near zero.
    // A single-user analysis tool does not need focus arbitration.
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
      await _player.setAudioContext(
        AudioContext(
          android: const AudioContextAndroid(
            audioFocus: AndroidAudioFocus.none,
          ),
        ),
      );
    }
    await _player.setSourceDeviceFile(absolutePath);
    if (rate.value != 1.0) {
      await _player.setPlaybackRate(rate.value);
    }
    _duration = await _player.getDuration() ?? Duration.zero;
    if (_duration == Duration.zero && fallbackDuration != null) {
      _duration = fallbackDuration;
    }
    _setAnchor(Duration.zero);
    _publish(Duration.zero);
  }

  Duration get duration => _duration;

  /// Media time covered by [elapsed] of wall clock at [rate]; the
  /// interpolated playhead must advance slower than the wall clock when
  /// playback is slowed.
  static Duration scaledElapsed(Duration elapsed, double rate) =>
      Duration(microseconds: (elapsed.inMicroseconds * rate).round());

  /// Set the playback rate (0.5–1.0 exposed in the UI). Takes effect
  /// immediately, also mid-play; the interpolation is re-anchored first
  /// so the cursor stays continuous.
  Future<void> setRate(double r) async {
    final clamped = r.clamp(0.25, 2.0).toDouble();
    if (playing.value) _setAnchor(position.value);
    rate.value = clamped;
    await _player.setPlaybackRate(clamped);
  }

  /// Play from [from] (or the current position) to [until] (or the end).
  /// With [loop], reaching [until] seeks back to [from] and keeps
  /// playing until [pause].
  Future<void> play({Duration? from, Duration? until, bool loop = false}) async {
    _stopAt = until;
    _loopFrom = loop && until != null ? (from ?? Duration.zero) : null;
    if (from != null) {
      await _player.seek(from);
      _setAnchor(from);
      _publish(from);
    } else {
      _setAnchor(position.value);
    }
    await _player.resume();
    playing.value = true;
    _sinceAnchor.start();
    _frameTimer?.cancel();
    _frameTimer = Timer.periodic(
      const Duration(milliseconds: 16),
      (_) => _onFrame(),
    );
    _syncTimer?.cancel();
    _syncTimer = Timer.periodic(
      const Duration(milliseconds: 400),
      (_) => _resync(),
    );
  }

  Future<void> pause() async {
    await _player.pause();
    await _stopTracking();
  }

  Future<void> seek(Duration to) async {
    await _player.seek(to);
    _setAnchor(to);
    _publish(to);
  }

  void _onFrame() {
    if (!playing.value) return;
    final now = _anchor + scaledElapsed(_sinceAnchor.elapsed, rate.value);
    final stopAt = _stopAt;
    if (stopAt != null && now >= stopAt) {
      final loopFrom = _loopFrom;
      if (loopFrom != null) {
        // Fire-and-forget: the 400 ms resync corrects any seek latency.
        _player.seek(loopFrom);
        _setAnchor(loopFrom);
        _publish(loopFrom);
        return;
      }
      _player.pause();
      _stopTracking();
      _publish(stopAt);
      return;
    }
    if (_duration != Duration.zero && now >= _duration) {
      // Natural end; the plugin has stopped on its own by now.
      _stopTracking();
      _publish(_duration);
      return;
    }
    _publish(now);
  }

  Future<void> _resync() async {
    if (!playing.value) return;
    try {
      final real = await _player.getCurrentPosition();
      if (real != null && playing.value && !_disposed) {
        _setAnchor(real);
      }
    } catch (_) {
      // Transient plugin error; keep interpolating.
    }
  }

  void _setAnchor(Duration at) {
    _anchor = at;
    _sinceAnchor
      ..reset()
      ..start();
  }

  Future<void> _stopTracking() async {
    playing.value = false;
    _frameTimer?.cancel();
    _syncTimer?.cancel();
    _sinceAnchor.stop();
    _stopAt = null;
    _loopFrom = null;
  }

  void _publish(Duration p) {
    if (_disposed) return;
    position.value = p > _duration && _duration != Duration.zero
        ? _duration
        : p;
  }

  Future<void> dispose() async {
    _disposed = true;
    _frameTimer?.cancel();
    _syncTimer?.cancel();
    await _player.dispose();
    position.dispose();
    playing.dispose();
    rate.dispose();
  }
}
