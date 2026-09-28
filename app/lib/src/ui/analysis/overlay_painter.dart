import 'package:flutter/material.dart';

import '../../analysis/analysis_controller.dart';
import '../../analysis/view_prefs.dart';
import '../../analysis/viewport_math.dart';
import '../../rust/api/core.dart' as rust;
import 'spectrogram_view.dart';

/// Praat-style analysis overlays on the spectrogram: F0 curve (right-hand
/// linear axis, pitch floor..ceiling), intensity curve (0..100 dB), formant
/// dots. Which layers paint, their colors, and the mark scale come from
/// [ViewPrefs]; hidden tracks are still computed for the readout panel.
class TrackOverlay extends StatelessWidget {
  const TrackOverlay({
    super.key,
    required this.controller,
    required this.viewPrefs,
  });

  final AnalysisController controller;
  final ViewPrefs viewPrefs;

  @override
  Widget build(BuildContext context) {
    // Decorative for assistive tech: values are read via the readout panel.
    return ExcludeSemantics(
      child: RepaintBoundary(
        child: AnimatedBuilder(
          animation: controller,
          builder: (context, _) => CustomPaint(
            size: Size.infinite,
            painter: _TrackPainter(controller, viewPrefs),
          ),
        ),
      ),
    );
  }
}

class _TrackPainter extends CustomPainter {
  _TrackPainter(this.c, this.view)
    : viewport = c.viewport,
      f0 = c.f0Track,
      intensity = c.intensityTrack,
      formants = c.formantTrack,
      maxFreqHz = c.sgMaxFreqHz,
      pitchFloorHz = c.pitchFloorHz,
      pitchCeilingHz = c.pitchCeilingHz;

  final AnalysisController c;
  final ViewPrefs view;
  final TimeViewport viewport;
  final rust.F0TrackData? f0;
  final rust.IntensityTrackData? intensity;
  final rust.FormantTrackData? formants;
  final double maxFreqHz;
  final double pitchFloorHz;
  final double pitchCeilingHz;

  Color get _f0Color => view.pitch;
  Color get _intensityColor => view.intensity;
  Color get _formantColor => view.formant;

  @override
  void paint(Canvas canvas, Size size) {
    final plot = Rect.fromLTWH(
      kFreqAxisWidth,
      0,
      size.width - kFreqAxisWidth,
      size.height - kTimeAxisHeight,
    );
    canvas.save();
    canvas.clipRect(plot);
    if (view.showFormants) _paintFormants(canvas, plot);
    if (view.showIntensity) _paintIntensity(canvas, plot);
    if (view.showPitch) _paintF0(canvas, plot);
    canvas.restore();
    if (view.showPitch) _paintF0Axis(canvas, plot);
  }

  void _paintF0(Canvas canvas, Rect plot) {
    final track = f0;
    if (track == null) return;
    final paint = Paint()
      ..color = _f0Color
      ..strokeWidth = 2.5 * view.markScale
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;
    final floor = c.pitchFloorHz;
    final ceil = c.pitchCeilingHz;
    Path? path;
    for (var i = 0; i < track.timesS.length; i++) {
      final t = track.timesS[i];
      if (t < viewport.t0 - 0.05 || t > viewport.t1 + 0.05) continue;
      final hz = track.f0Hz[i];
      if (hz <= 0) {
        if (path != null) canvas.drawPath(path, paint);
        path = null;
        continue;
      }
      final x = plot.left + timeToX(t, viewport, plot.width);
      final y =
          plot.bottom -
          ((hz - floor) / (ceil - floor)).clamp(0.0, 1.0) * plot.height;
      if (path == null) {
        path = Path()..moveTo(x, y);
      } else {
        path.lineTo(x, y);
      }
    }
    if (path != null) canvas.drawPath(path, paint);
  }

  void _paintIntensity(Canvas canvas, Rect plot) {
    final track = intensity;
    if (track == null) return;
    final paint = Paint()
      ..color = _intensityColor
      ..strokeWidth = 1.5 * view.markScale
      ..style = PaintingStyle.stroke;
    Path? path;
    for (var i = 0; i < track.timesS.length; i++) {
      final t = track.timesS[i];
      if (t < viewport.t0 - 0.05 || t > viewport.t1 + 0.05) continue;
      final db = track.db[i];
      if (!db.isFinite || db < -250) {
        if (path != null) canvas.drawPath(path, paint);
        path = null;
        continue;
      }
      final x = plot.left + timeToX(t, viewport, plot.width);
      final y = plot.bottom - (db / 100).clamp(0.0, 1.0) * plot.height;
      if (path == null) {
        path = Path()..moveTo(x, y);
      } else {
        path.lineTo(x, y);
      }
    }
    if (path != null) canvas.drawPath(path, paint);
  }

  void _paintFormants(Canvas canvas, Rect plot) {
    final track = formants;
    if (track == null) return;
    final paint = Paint()..color = _formantColor;
    final n = track.maxFormants;
    final maxFreq = c.sgMaxFreqHz;
    for (var i = 0; i < track.timesS.length; i++) {
      final t = track.timesS[i];
      if (t < viewport.t0 || t > viewport.t1) continue;
      final x = plot.left + timeToX(t, viewport, plot.width);
      for (var k = 0; k < n; k++) {
        final hz = track.formantsHz[i * n + k];
        if (hz <= 0 || hz > maxFreq) continue;
        final y = plot.bottom - hz / maxFreq * plot.height;
        canvas.drawCircle(Offset(x, y), 1.6 * view.markScale, paint);
      }
    }
  }

  void _paintF0Axis(Canvas canvas, Rect plot) {
    final style = TextStyle(color: _f0Color, fontSize: 10);
    for (final hz in [c.pitchFloorHz, c.pitchCeilingHz]) {
      final frac =
          ((hz - c.pitchFloorHz) / (c.pitchCeilingHz - c.pitchFloorHz));
      final y = plot.bottom - frac * plot.height;
      final tp = TextPainter(
        text: TextSpan(text: '${hz.round()}', style: style),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(
        canvas,
        Offset(
          plot.right - tp.width - 2,
          (y - tp.height / 2).clamp(plot.top, plot.bottom - tp.height),
        ),
      );
    }
  }

  @override
  bool shouldRepaint(_TrackPainter old) =>
      old.viewport != viewport ||
      old.f0 != f0 ||
      old.intensity != intensity ||
      old.formants != formants ||
      old.maxFreqHz != maxFreqHz ||
      old.pitchFloorHz != pitchFloorHz ||
      old.pitchCeilingHz != pitchCeilingHz ||
      old.view != view;
}
