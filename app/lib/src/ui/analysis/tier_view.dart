import 'dart:math' as math;

import 'package:flutter/gestures.dart'
    show DragStartBehavior, PointerDeviceKind;
import 'package:flutter/material.dart';

import '../../../l10n/app_localizations.dart';
import 'package:flutter/services.dart' show KeyDownEvent, LogicalKeyboardKey;

import '../../analysis/analysis_controller.dart';
import '../../analysis/viewport_math.dart';
import '../../annotation/annotation_model.dart';
import 'spectrogram_view.dart' show kFreqAxisWidth;

/// Height of one annotation tier row.
const double kTierHeight = 36;

/// Hit slop for boundaries/points, in screen px, for a precise pointer
/// (mouse/stylus/trackpad).
const double _kHitPx = 8;

/// Hit slop for a finger: half of a 48dp Material touch target, so two
/// boundaries 48px apart remain individually addressable.
const double _kHitPxTouch = 24;

/// Snap distance for boundary drags, in screen px.
const double _kSnapPx = 6;

/// Snap distance for finger drags; wider because the finger occludes the
/// exact position.
const double _kSnapPxTouch = 10;

/// Label shown next to a boundary/point while it is dragged; the finger
/// (or cursor) covers the boundary itself, so the time floats beside it.
String dragTimeLabel(double timeS) => '${timeS.toStringAsFixed(3)} s';

double _hitPxFor(PointerDeviceKind? kind) =>
    kind == PointerDeviceKind.touch ? _kHitPxTouch : _kHitPx;

double _snapPxFor(PointerDeviceKind? kind) =>
    kind == PointerDeviceKind.touch ? _kSnapPxTouch : _kSnapPx;

/// Annotation tier strip under the spectrogram: one row per tier, sharing
/// the controller's time viewport and horizontal mapping (left gutter shows
/// the tier names). Collapses to nothing while no TextGrid is loaded.
///
/// Interactions (pointer): tap activates the tier and selects the tapped
/// interval, or the boundary/point within reach (Delete removes it); drag
/// moves a boundary/point, snapping to other tiers' times; double-tap
/// edits the label inline (Enter commits, Esc cancels).
class TierView extends StatefulWidget {
  const TierView({super.key, required this.controller});

  final AnalysisController controller;

  @override
  State<TierView> createState() => _TierViewState();
}

/// Inline label editing session.
class _LabelEdit {
  _LabelEdit(this.tier, this.index, this.isPoint, String initial)
    : text = TextEditingController(text: initial);
  final int tier;
  final int index;
  final bool isPoint;
  final TextEditingController text;
  final FocusNode focusNode = FocusNode();

  void dispose() {
    text.dispose();
    focusNode.dispose();
  }
}

class _TierViewState extends State<TierView> {
  Offset? _doubleTapPos;
  PointerDeviceKind? _doubleTapKind;
  _LabelEdit? _edit;
  bool _dragging = false;
  PointerDeviceKind? _dragKind;

  AnalysisController get c => widget.controller;

  @override
  void dispose() {
    _edit?.dispose();
    super.dispose();
  }

  double _plotWidth(double maxWidth) =>
      math.max(1.0, maxWidth - kFreqAxisWidth);

  double _xToT(double dx, double plotWidth) => xToTime(
    dx - kFreqAxisWidth,
    c.viewport,
    plotWidth,
  ).clamp(0.0, c.durationS);

  double _pxToS(double px, double plotWidth) =>
      px / plotWidth * c.viewport.span;

  int _tierAt(double dy, AnnotationDoc doc) =>
      (dy ~/ kTierHeight).clamp(0, doc.tiers.length - 1);

  /// Nearest draggable boundary/point on [tier] within the hit slop of [t].
  (int, bool)? _hitAt(AnnotationDoc doc, int tier, double t, double tolS) {
    int? best;
    var bestDist = tolS;
    var isPoint = false;
    switch (doc.tiers[tier]) {
      case IntervalTierModel(:final intervals):
        for (var j = 1; j < intervals.length; j++) {
          final d = (intervals[j].xmin - t).abs();
          if (d <= bestDist) {
            best = j;
            bestDist = d;
          }
        }
      case PointTierModel(:final points):
        isPoint = true;
        for (var j = 0; j < points.length; j++) {
          final d = (points[j].time - t).abs();
          if (d <= bestDist) {
            best = j;
            bestDist = d;
          }
        }
    }
    return best == null ? null : (best, isPoint);
  }

  void _commitEdit() {
    final e = _edit;
    if (e == null) return;
    c.annotationSetLabel(e.tier, e.index, e.isPoint, e.text.text);
    setState(() {
      _edit = null;
      e.dispose();
    });
  }

  void _cancelEdit() {
    final e = _edit;
    if (e == null) return;
    setState(() {
      _edit = null;
      e.dispose();
    });
  }

  void _openEdit(AnnotationDoc doc, Offset pos, double plotWidth) {
    final tier = _tierAt(pos.dy, doc);
    final t = _xToT(pos.dx, plotWidth);
    _LabelEdit? edit;
    switch (doc.tiers[tier]) {
      case IntervalTierModel it:
        final i = it.intervalIndexAt(t);
        if (i < 0) return;
        edit = _LabelEdit(tier, i, false, it.intervals[i].text);
      case PointTierModel pt:
        final hit = _hitAt(
          doc,
          tier,
          t,
          _pxToS(_hitPxFor(_doubleTapKind) * 2, plotWidth),
        );
        if (hit == null) return;
        edit = _LabelEdit(tier, hit.$1, true, pt.points[hit.$1].mark);
    }
    // Commit when focus leaves the field (covers taps anywhere else).
    final e = edit;
    e.focusNode.addListener(() {
      if (identical(_edit, e) && !e.focusNode.hasFocus) _commitEdit();
    });
    setState(() => _edit = e);
    // autofocus alone is unreliable here (the field appears mid-gesture);
    // request focus explicitly once it is in the tree.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (identical(_edit, e) && mounted) e.focusNode.requestFocus();
    });
  }

  /// Pixel rect of the label editor for the current viewport, or null when
  /// the edited item no longer exists (undo while editing).
  Rect? _editRect(AnnotationDoc doc, _LabelEdit e, double plotWidth) {
    if (e.tier >= doc.tiers.length) return null;
    final top = e.tier * kTierHeight;
    switch (doc.tiers[e.tier]) {
      case IntervalTierModel it:
        if (e.isPoint || e.index >= it.intervals.length) return null;
        final iv = it.intervals[e.index];
        final x0 = kFreqAxisWidth + timeToX(iv.xmin, c.viewport, plotWidth);
        final x1 = kFreqAxisWidth + timeToX(iv.xmax, c.viewport, plotWidth);
        return Rect.fromLTRB(
          math.max(x0, kFreqAxisWidth),
          top,
          math.min(x1, kFreqAxisWidth + plotWidth),
          top + kTierHeight,
        );
      case PointTierModel pt:
        if (!e.isPoint || e.index >= pt.points.length) return null;
        final x =
            kFreqAxisWidth +
            timeToX(pt.points[e.index].time, c.viewport, plotWidth);
        return Rect.fromLTRB(x - 60, top, x + 60, top + kTierHeight);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: c,
      builder: (context, _) {
        final doc = c.annotation?.doc;
        if (doc == null || doc.tiers.isEmpty) return const SizedBox.shrink();
        final theme = Theme.of(context);
        final tierNames = doc.tiers.map((t) => t.name).join(', ');
        final activeName = c.activeTier < doc.tiers.length
            ? doc.tiers[c.activeTier].name
            : '';
        return Semantics(
          label: AppLocalizations.of(
            context,
          )!.tierStripSemantics(tierNames, activeName),
          child: _buildStrip(doc, theme),
        );
      },
    );
  }

  Widget _buildStrip(AnnotationDoc doc, ThemeData theme) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final plotWidth = _plotWidth(constraints.maxWidth);
        final height = doc.tiers.length * kTierHeight;
        final editRect = _edit == null
            ? null
            : _editRect(doc, _edit!, plotWidth);
        return SizedBox(
          height: height,
          width: constraints.maxWidth,
          child: Stack(
            children: [
              Positioned.fill(
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  // Anchor drag-start details at the pointer-down
                  // position: the boundary hit-test must see where the
                  // press landed, not where the drag cleared the slop.
                  dragStartBehavior: DragStartBehavior.down,
                  onTapUp: (d) {
                    _commitEdit();
                    final tier = _tierAt(d.localPosition.dy, doc);
                    c.annotationTap(
                      tier,
                      _xToT(d.localPosition.dx, plotWidth),
                      tolS: _pxToS(_hitPxFor(d.kind), plotWidth),
                    );
                  },
                  onDoubleTapDown: (d) {
                    _doubleTapPos = d.localPosition;
                    _doubleTapKind = d.kind;
                  },
                  onDoubleTap: () {
                    _commitEdit();
                    final pos = _doubleTapPos;
                    if (pos != null) _openEdit(doc, pos, plotWidth);
                  },
                  onHorizontalDragStart: (d) {
                    _commitEdit();
                    final tier = _tierAt(d.localPosition.dy, doc);
                    final t = _xToT(d.localPosition.dx, plotWidth);
                    final hit = _hitAt(
                      doc,
                      tier,
                      t,
                      _pxToS(_hitPxFor(d.kind), plotWidth),
                    );
                    if (hit == null) return;
                    _dragging = true;
                    _dragKind = d.kind;
                    c.startAnnotationDrag(tier, hit.$1, isPoint: hit.$2);
                  },
                  onHorizontalDragUpdate: (d) {
                    if (!_dragging) return;
                    c.updateAnnotationDrag(
                      _xToT(d.localPosition.dx, plotWidth),
                      snapTolS: _pxToS(_snapPxFor(_dragKind), plotWidth),
                    );
                  },
                  onHorizontalDragEnd: (d) {
                    if (!_dragging) return;
                    _dragging = false;
                    c.endAnnotationDrag();
                  },
                  onHorizontalDragCancel: () {
                    if (!_dragging) return;
                    _dragging = false;
                    c.endAnnotationDrag(commit: false);
                  },
                  child: CustomPaint(
                    size: Size(constraints.maxWidth, height),
                    painter: _TierPainter(
                      doc: doc,
                      viewport: c.viewport,
                      selection: c.selection,
                      cursorTimeS: c.cursorTimeS,
                      activeTier: c.activeTier,
                      hit: c.annotationHit,
                      drag: c.annotationDrag,
                      colors: theme.colorScheme,
                      labelStyle:
                          theme.textTheme.bodySmall ?? const TextStyle(),
                    ),
                  ),
                ),
              ),
              if (editRect != null)
                Positioned.fromRect(
                  rect: editRect,
                  child: Focus(
                    onKeyEvent: (node, event) {
                      if (event is KeyDownEvent &&
                          event.logicalKey == LogicalKeyboardKey.escape) {
                        _cancelEdit();
                        return KeyEventResult.handled;
                      }
                      return KeyEventResult.ignored;
                    },
                    child: Material(
                      elevation: 2,
                      child: TextField(
                        controller: _edit!.text,
                        focusNode: _edit!.focusNode,
                        autofocus: true,
                        style: theme.textTheme.bodySmall,
                        textAlign: TextAlign.center,
                        decoration: const InputDecoration(
                          isDense: true,
                          contentPadding: EdgeInsets.symmetric(
                            horizontal: 4,
                            vertical: 8,
                          ),
                          border: OutlineInputBorder(),
                        ),
                        onSubmitted: (_) => _commitEdit(),
                        onTapOutside: (_) => _commitEdit(),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}

class _TierPainter extends CustomPainter {
  _TierPainter({
    required this.doc,
    required this.viewport,
    required this.selection,
    required this.cursorTimeS,
    required this.activeTier,
    required this.hit,
    required this.drag,
    required this.colors,
    required this.labelStyle,
  });

  final AnnotationDoc doc;
  final TimeViewport viewport;
  final TimeSelection? selection;
  final double? cursorTimeS;
  final int activeTier;
  final AnnotationHit? hit;
  final AnnotationDrag? drag;
  final ColorScheme colors;
  final TextStyle labelStyle;

  double _x(double t, double plotWidth) =>
      kFreqAxisWidth + timeToX(t, viewport, plotWidth);

  void _paintLabel(
    Canvas canvas,
    String text,
    double xLeft,
    double xRight,
    double rowTop, {
    required Color color,
  }) {
    if (text.isEmpty || xRight - xLeft < 8) return;
    final tp = TextPainter(
      text: TextSpan(
        text: text,
        style: labelStyle.copyWith(color: color),
      ),
      textDirection: TextDirection.ltr,
      maxLines: 1,
      ellipsis: '…',
    )..layout(maxWidth: xRight - xLeft - 4);
    final x = xLeft + ((xRight - xLeft) - tp.width) / 2;
    tp.paint(canvas, Offset(x, rowTop + (kTierHeight - tp.height) / 2));
  }

  bool _isHit(int tier, int index, bool isPoint) =>
      hit != null &&
      hit!.tier == tier &&
      hit!.index == index &&
      hit!.isPoint == isPoint;

  bool _isDragged(int tier, int index, bool isPoint) =>
      drag != null &&
      drag!.tier == tier &&
      drag!.index == index &&
      drag!.isPoint == isPoint;

  @override
  void paint(Canvas canvas, Size size) {
    final plotWidth = size.width - kFreqAxisWidth;
    final line = Paint()
      ..color = colors.outlineVariant
      ..strokeWidth = 1;
    final boundary = Paint()
      ..color = colors.outline
      ..strokeWidth = 1;
    final emphasized = Paint()
      ..color = colors.primary
      ..strokeWidth = 2.5;

    for (var i = 0; i < doc.tiers.length; i++) {
      final rowTop = i * kTierHeight;
      final rowBottom = rowTop + kTierHeight;
      final rowRect = Rect.fromLTRB(
        kFreqAxisWidth,
        rowTop,
        size.width,
        rowBottom,
      );
      if (i == activeTier) {
        canvas.drawRect(
          rowRect,
          Paint()..color = colors.primaryContainer.withValues(alpha: 0.25),
        );
      }

      switch (doc.tiers[i]) {
        case IntervalTierModel(:final intervals):
          for (final iv in intervals) {
            if (iv.xmax < viewport.t0 || iv.xmin > viewport.t1) continue;
            final x0 = _x(iv.xmin, plotWidth).clamp(kFreqAxisWidth, size.width);
            final x1 = _x(iv.xmax, plotWidth).clamp(kFreqAxisWidth, size.width);
            // Highlight the interval matching the current selection on the
            // active tier (i.e. the tapped interval).
            final sel = selection;
            if (i == activeTier &&
                sel != null &&
                (sel.t0 - iv.xmin).abs() < 1e-9 &&
                (sel.t1 - iv.xmax).abs() < 1e-9) {
              canvas.drawRect(
                Rect.fromLTRB(x0, rowTop, x1, rowBottom),
                Paint()..color = colors.primary.withValues(alpha: 0.18),
              );
            }
            _paintLabel(
              canvas,
              iv.text,
              x0,
              x1,
              rowTop.toDouble(),
              color: colors.onSurface,
            );
          }
          // Interior boundaries; a dragged boundary paints at its preview
          // position instead.
          for (var j = 1; j < intervals.length; j++) {
            final dragged = _isDragged(i, j, false);
            final t = dragged ? drag!.timeS : intervals[j].xmin;
            if (!viewport.contains(t)) continue;
            final x = _x(t, plotWidth);
            canvas.drawLine(
              Offset(x, rowTop.toDouble()),
              Offset(x, rowBottom),
              dragged || _isHit(i, j, false) ? emphasized : boundary,
            );
          }
        case PointTierModel(:final points):
          for (var j = 0; j < points.length; j++) {
            final dragged = _isDragged(i, j, true);
            final t = dragged ? drag!.timeS : points[j].time;
            if (!viewport.contains(t)) continue;
            final x = _x(t, plotWidth);
            canvas.drawLine(
              Offset(x, rowTop + kTierHeight * 0.35),
              Offset(x, rowBottom),
              dragged || _isHit(i, j, true) ? emphasized : boundary,
            );
            _paintLabel(
              canvas,
              points[j].mark,
              x - 40,
              x + 40,
              rowTop.toDouble() - kTierHeight * 0.18,
              color: colors.onSurface,
            );
          }
      }

      // Tier name in the left gutter.
      final name = TextPainter(
        text: TextSpan(
          text: doc.tiers[i].name,
          style: labelStyle.copyWith(
            color: i == activeTier ? colors.primary : colors.onSurfaceVariant,
            fontSize: 10,
          ),
        ),
        textDirection: TextDirection.ltr,
        maxLines: 1,
        ellipsis: '…',
      )..layout(maxWidth: kFreqAxisWidth - 6);
      name.paint(canvas, Offset(2, rowTop + (kTierHeight - name.height) / 2));

      // Row borders.
      canvas.drawLine(
        Offset(0, rowTop.toDouble()),
        Offset(size.width, rowTop.toDouble()),
        line,
      );
      canvas.drawLine(
        Offset(kFreqAxisWidth, rowTop.toDouble()),
        Offset(kFreqAxisWidth, rowBottom),
        line,
      );
    }
    canvas.drawLine(
      Offset(0, size.height),
      Offset(size.width, size.height),
      line,
    );

    // Selection wash and cursor, for continuity with the panels above.
    final sel = selection;
    if (sel != null && sel.t1 > viewport.t0 && sel.t0 < viewport.t1) {
      final x0 = _x(sel.t0, plotWidth).clamp(kFreqAxisWidth, size.width);
      final x1 = _x(sel.t1, plotWidth).clamp(kFreqAxisWidth, size.width);
      canvas.drawRect(
        Rect.fromLTRB(x0, 0, x1, size.height),
        Paint()..color = colors.primary.withValues(alpha: 0.08),
      );
    }
    final cursor = cursorTimeS;
    if (cursor != null && viewport.contains(cursor)) {
      final x = _x(cursor, plotWidth);
      canvas.drawLine(
        Offset(x, 0),
        Offset(x, size.height),
        Paint()
          ..color = colors.error.withValues(alpha: 0.7)
          ..strokeWidth = 1,
      );
    }

    _paintDragLabel(canvas, size, plotWidth);
  }

  /// Floating time readout beside the dragged boundary/point: the pointer
  /// occludes the mark, so precision needs a visible number. Flips to the
  /// left side near the right edge.
  void _paintDragLabel(Canvas canvas, Size size, double plotWidth) {
    final d = drag;
    if (d == null || !viewport.contains(d.timeS)) return;
    final x = _x(d.timeS, plotWidth);
    final rowTop = (d.tier * kTierHeight).toDouble();
    final tp = TextPainter(
      text: TextSpan(
        text: dragTimeLabel(d.timeS),
        style: labelStyle.copyWith(
          color: colors.onPrimary,
          fontFeatures: const [FontFeature.tabularFigures()],
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    const pad = 4.0;
    const gap = 14.0;
    var left = x + gap;
    if (left + tp.width + 2 * pad > size.width) {
      left = x - gap - tp.width - 2 * pad;
    }
    final rect = RRect.fromRectAndRadius(
      Rect.fromLTWH(
        left,
        rowTop + (kTierHeight - tp.height) / 2 - pad,
        tp.width + 2 * pad,
        tp.height + 2 * pad,
      ),
      const Radius.circular(4),
    );
    canvas.drawRRect(rect, Paint()..color = colors.primary);
    tp.paint(canvas, Offset(left + pad, rect.top + pad));
  }

  @override
  bool shouldRepaint(_TierPainter old) =>
      !identical(old.doc, doc) ||
      old.viewport != viewport ||
      old.selection != selection ||
      old.cursorTimeS != cursorTimeS ||
      old.activeTier != activeTier ||
      old.hit != hit ||
      old.drag != drag;
}
