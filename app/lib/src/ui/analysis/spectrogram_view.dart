import 'package:flutter/material.dart';

import '../../../l10n/app_localizations.dart';
import 'package:flutter/scheduler.dart';

import '../../analysis/analysis_controller.dart';
import '../../analysis/spectrogram_image.dart';
import '../../analysis/viewport_math.dart';

const double kFreqAxisWidth = 44.0;
const double kTimeAxisHeight = 20.0;

/// Spectrogram viewport: the current rendered image mapped from its
/// absolute time range into the live viewport (so a stale image stays
/// correctly positioned during pan/zoom), with frequency and time axes.
class SpectrogramView extends StatelessWidget {
  const SpectrogramView({
    super.key,
    required this.controller,
    this.showImage = true,
  });

  final AnalysisController controller;

  /// When false only the white plot background and the axes are drawn —
  /// the layer toggle hides the image but the overlays keep their frame.
  final bool showImage;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: AppLocalizations.of(context)!.spectrogramSemantics,
      child: _buildPlot(context),
    );
  }

  Widget _buildPlot(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textStyle = Theme.of(
      context,
    ).textTheme.labelSmall?.copyWith(color: scheme.onSurfaceVariant);
    return LayoutBuilder(
      builder: (context, constraints) {
        final plotWidth = constraints.maxWidth - kFreqAxisWidth;
        SchedulerBinding.instance.addPostFrameCallback((_) {
          controller.requestSpectrogram(plotWidth.floor());
        });
        return AnimatedBuilder(
          animation: controller,
          builder: (context, _) => CustomPaint(
            size: Size.infinite,
            painter: _SpectrogramPainter(
              image: showImage ? controller.spectrogramImage : null,
              viewport: controller.viewport,
              displayMaxFreqHz: controller.sgMaxFreqHz,
              axisTextStyle: textStyle,
              axisColor: scheme.outlineVariant,
              background: Colors.white,
            ),
          ),
        );
      },
    );
  }
}

class _SpectrogramPainter extends CustomPainter {
  _SpectrogramPainter({
    required this.image,
    required this.viewport,
    required this.displayMaxFreqHz,
    required this.axisTextStyle,
    required this.axisColor,
    required this.background,
  });

  final SpectrogramImage? image;
  final TimeViewport viewport;
  final double displayMaxFreqHz;
  final TextStyle? axisTextStyle;
  final Color axisColor;
  final Color background;

  @override
  void paint(Canvas canvas, Size size) {
    final plot = Rect.fromLTWH(
      kFreqAxisWidth,
      0,
      size.width - kFreqAxisWidth,
      size.height - kTimeAxisHeight,
    );
    // Praat-style: quiet is white, so the plot background is white in
    // both app themes.
    canvas.drawRect(plot, Paint()..color = background);

    final img = image;
    if (img != null && img.t1 > img.t0) {
      canvas.save();
      canvas.clipRect(plot);
      // Horizontal: map the image's absolute [t0, t1] into the viewport.
      final x0 = plot.left + timeToX(img.t0, viewport, plot.width);
      final x1 = plot.left + timeToX(img.t1, viewport, plot.width);
      // Vertical: image top is its own max frequency; scale into display.
      final topFrac = 1 - img.maxFreqHz / displayMaxFreqHz;
      final destTop = plot.top + topFrac * plot.height;
      canvas.drawImageRect(
        img.image,
        Rect.fromLTWH(
          0,
          0,
          img.image.width.toDouble(),
          img.image.height.toDouble(),
        ),
        Rect.fromLTRB(x0, destTop, x1, plot.bottom),
        Paint()..filterQuality = FilterQuality.low,
      );
      canvas.restore();
    }

    _paintFreqAxis(canvas, plot);
    _paintTimeAxis(canvas, plot, size);
  }

  void _paintFreqAxis(Canvas canvas, Rect plot) {
    final tickPaint = Paint()
      ..color = axisColor
      ..strokeWidth = 1;
    final stepHz = displayMaxFreqHz > 8000 ? 2000 : 1000;
    for (var f = 0; f <= displayMaxFreqHz; f += stepHz) {
      final y = plot.bottom - f / displayMaxFreqHz * plot.height;
      canvas.drawLine(
        Offset(plot.left - 4, y),
        Offset(plot.left, y),
        tickPaint,
      );
      final tp = TextPainter(
        text: TextSpan(text: '${f ~/ 1000}k', style: axisTextStyle),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, Offset(plot.left - 8 - tp.width, y - tp.height / 2));
    }
  }

  void _paintTimeAxis(Canvas canvas, Rect plot, Size size) {
    final tickPaint = Paint()
      ..color = axisColor
      ..strokeWidth = 1;
    final step = _niceTimeStep(viewport.span);
    var t = (viewport.t0 / step).ceil() * step;
    while (t <= viewport.t1) {
      final x = plot.left + timeToX(t, viewport, plot.width);
      canvas.drawLine(
        Offset(x, plot.bottom),
        Offset(x, plot.bottom + 4),
        tickPaint,
      );
      final tp = TextPainter(
        text: TextSpan(text: _fmtTime(t, step), style: axisTextStyle),
        textDirection: TextDirection.ltr,
      )..layout();
      final tx = (x - tp.width / 2).clamp(plot.left, size.width - tp.width);
      tp.paint(canvas, Offset(tx, plot.bottom + 5));
      t += step;
    }
  }

  static double _niceTimeStep(double span) {
    const candidates = [
      0.001,
      0.002,
      0.005,
      0.01,
      0.02,
      0.05,
      0.1,
      0.2,
      0.5,
      1.0,
      2.0,
      5.0,
      10.0,
      30.0,
      60.0,
    ];
    final target = span / 6;
    for (final c in candidates) {
      if (c >= target) return c;
    }
    return candidates.last;
  }

  static String _fmtTime(double t, double step) =>
      step >= 1 ? '${t.round()} s' : t.toStringAsFixed(step >= 0.01 ? 2 : 3);

  @override
  bool shouldRepaint(_SpectrogramPainter old) =>
      old.image != image ||
      old.viewport != viewport ||
      old.displayMaxFreqHz != displayMaxFreqHz;
}
