import 'package:flutter/material.dart';

import '../../../l10n/app_localizations.dart';
import 'package:flutter/scheduler.dart';

import '../../analysis/analysis_controller.dart';
import '../../analysis/viewport_math.dart';

/// Waveform strip: min/max envelope of the visible range, with the
/// playback cursor on top. The envelope is fetched at one bucket per
/// pixel for the settled viewport; while panning/zooming the last slice
/// is stretched into place.
class WaveformView extends StatelessWidget {
  const WaveformView({super.key, required this.controller});

  final AnalysisController controller;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: AppLocalizations.of(context)!.waveformSemantics,
      child: _buildPlot(context),
    );
  }

  Widget _buildPlot(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        SchedulerBinding.instance.addPostFrameCallback((_) {
          controller.requestEnvelope(width.floor());
        });
        final scheme = Theme.of(context).colorScheme;
        return ClipRect(
          child: RepaintBoundary(
            child: AnimatedBuilder(
              animation: controller,
              builder: (context, _) => CustomPaint(
                size: Size.infinite,
                painter: _WaveformPainter(
                  envelope: controller.envelope,
                  viewport: controller.viewport,
                  color: scheme.primary,
                  midlineColor: scheme.outlineVariant,
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _WaveformPainter extends CustomPainter {
  _WaveformPainter({
    required this.envelope,
    required this.viewport,
    required this.color,
    required this.midlineColor,
  });

  final EnvelopeSlice? envelope;
  final TimeViewport viewport;
  final Color color;
  final Color midlineColor;

  @override
  void paint(Canvas canvas, Size size) {
    final midY = size.height / 2;
    canvas.drawLine(
      Offset(0, midY),
      Offset(size.width, midY),
      Paint()
        ..color = midlineColor
        ..strokeWidth = 1,
    );
    final env = envelope;
    if (env == null) return;
    final n = env.data.min.length;
    if (n == 0) return;
    final paint = Paint()
      ..color = color
      ..strokeWidth = 1;
    final bucketDur = (env.t1 - env.t0) / n;
    // Half the strip height for full scale, tiny floor so silence shows.
    final yScale = midY * 0.95;
    for (var i = 0; i < n; i++) {
      final t = env.t0 + (i + 0.5) * bucketDur;
      final x = timeToX(t, viewport, size.width);
      if (x < -1 || x > size.width + 1) continue;
      final lo = env.data.min[i] * yScale;
      final hi = env.data.max[i] * yScale;
      canvas.drawLine(
        Offset(x, midY - hi.clamp(-yScale, yScale) - 0.5),
        Offset(x, midY - lo.clamp(-yScale, yScale) + 0.5),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(_WaveformPainter old) =>
      old.envelope != envelope ||
      old.viewport != viewport ||
      old.color != color;
}
