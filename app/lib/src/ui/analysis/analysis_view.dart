import 'dart:io';
import 'dart:math' as math;

import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart' show defaultTargetPlatform, kIsWeb;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart'
    show HardwareKeyboard, KeyDownEvent, LogicalKeyboardKey;

import '../../../l10n/app_localizations.dart';
import '../../analysis/analysis_controller.dart';
import '../../analysis/analysis_settings.dart';
import '../../analysis/measurements.dart';
import '../../analysis/view_prefs.dart';
import '../../analysis/viewport_math.dart';
import '../../annotation/annotation_model.dart';
import '../../audio/recorder_service.dart' show sanitizeFileName;
import '../../data/app_prefs.dart';
import '../../data/database.dart';
import '../../data/file_exchange.dart';
import 'overlay_painter.dart';
import 'pitch_edit_bar.dart';
import 'readout_panel.dart';
import 'settings_sheet.dart';
import 'spectrogram_view.dart';
import 'tier_view.dart';
import 'transport_bar.dart';
import 'voice_report_dialog.dart';
import 'waveform_view.dart';

/// Height of the waveform strip; the spectrogram starts below it and its
/// one-pixel divider.
const double kWaveformHeight = 110;
const double kSpectrogramTop = kWaveformHeight + 1;

/// The analysis workbench for one recording, retained across layout changes.
class AnalysisView extends StatefulWidget {
  const AnalysisView({
    super.key,
    required this.recording,
    required this.db,
    required this.prefs,
    this.defaultSettings,
    this.controllerFactory,
    this.onAnnotationSaved,
  });

  final Recording recording;
  final AppDatabase db;

  /// App preferences; listened to here (not only in main.dart) because
  /// pushed routes do not rebuild when prefs change.
  final AppPrefs prefs;

  /// App-level analysis defaults for recordings without stored settings.
  final AnalysisSettings? defaultSettings;

  final AnalysisController Function(Recording recording)? controllerFactory;
  final VoidCallback? onAnnotationSaved;

  @override
  State<AnalysisView> createState() => AnalysisViewState();
}

class AnalysisViewState extends State<AnalysisView> {
  late AnalysisController _controller;

  AnalysisController _newController() =>
      (widget.controllerFactory?.call(widget.recording) ??
            AnalysisController(
              widget.recording,
              onSaveSettings: widget.db.updateAnalysisSettings,
              defaultSettings: widget.defaultSettings,
            ))
        ..open();

  /// Keep the view and its edits until the user saves or explicitly discards.
  Future<bool> confirmLeave() async {
    if (_controller.annotation?.dirty != true) return true;
    final l10n = AppLocalizations.of(context)!;
    final choice = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l10n.unsavedAnnotationsTitle),
        content: Text(l10n.unsavedAnnotationsBody),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(l10n.cancel),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, 'discard'),
            child: Text(l10n.discard),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, 'save'),
            child: Text(l10n.save),
          ),
        ],
      ),
    );
    if (!mounted) return false;
    if (choice == 'discard') return true;
    if (choice != 'save') return false;
    final error = await _controller.saveAnnotation();
    if (!mounted) return false;
    if (error != null) {
      _snack(l10n.saveFailed(error));
      return false;
    }
    widget.onAnnotationSaved?.call();
    return _controller.annotation?.dirty != true;
  }

  @override
  void initState() {
    super.initState();
    _controller = _newController();
  }

  @override
  void didUpdateWidget(AnalysisView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.recording.id != widget.recording.id) {
      _controller.dispose();
      _controller = _newController();
    }
  }

  Future<void> _openSettings() async {
    final next = await showAnalysisSettings(context, _controller.settings);
    if (next != null) await _controller.applySettings(next);
  }

  Future<void> _importTextGrid() async {
    try {
      await _importTextGridInner();
    } catch (e) {
      if (mounted) _snack(AppLocalizations.of(context)!.importFailed('$e'));
    }
  }

  Future<void> _importTextGridInner() async {
    final file = await openFile(acceptedTypeGroups: const [textGridFileType]);
    if (file == null || !mounted) return;
    final l10n = AppLocalizations.of(context)!;
    if (_controller.annotation != null) {
      final replace = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(l10n.replaceTextGridTitle),
          content: Text(l10n.replaceOnImportBody),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text(l10n.cancel),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text(l10n.replace),
            ),
          ],
        ),
      );
      if (replace != true) return;
    }
    final error = await withLocalDocument(file, _controller.importTextGrid);
    if (!mounted) return;
    if (error == null) widget.onAnnotationSaved?.call();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          error == null ? l10n.textGridImported : l10n.importFailed(error),
        ),
      ),
    );
  }

  void _snack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _saveTextGrid() async {
    final l10n = AppLocalizations.of(context)!;
    final error = await _controller.saveAnnotation();
    if (!mounted) return;
    if (error == null) widget.onAnnotationSaved?.call();
    _snack(error == null ? l10n.textGridSaved : l10n.saveFailed(error));
  }

  /// Mobile has no save dialog (file_selector's getSaveLocation silently
  /// returns null on Android), so exports go through the system share
  /// sheet from a temp file instead.
  bool get _useShareSheet =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS);

  Future<void> _shareFile(String path, String mimeType) async {
    if (!mounted) return;
    await shareFilesFrom(context, [XFile(path, mimeType: mimeType)]);
  }

  Future<void> _exportTextGrid() async {
    try {
      await _exportTextGridInner();
    } catch (e) {
      if (mounted) _snack(AppLocalizations.of(context)!.exportFailed('$e'));
    }
  }

  Future<void> _exportTextGridInner() async {
    final l10n = AppLocalizations.of(context)!;
    // Sanitized: display names carry colons ("... 23:49"), which neither
    // Android document names nor Windows file names accept.
    final stem = sanitizeFileName(widget.recording.name);
    if (_useShareSheet) {
      final dir = await exportDirectory();
      final path = '${dir.path}/$stem.TextGrid';
      final error = await _controller.exportAnnotation(path);
      if (error != null) {
        _snack(l10n.exportFailed(error));
        return;
      }
      await _shareFile(path, 'text/plain');
      return;
    }
    const grids = XTypeGroup(
      label: 'TextGrid',
      extensions: ['TextGrid', 'textgrid'],
    );
    final location = await getSaveLocation(
      suggestedName: '$stem.TextGrid',
      acceptedTypeGroups: const [grids],
    );
    if (location == null || !mounted) return;
    final error = await _controller.exportAnnotation(location.path);
    _snack(error == null ? l10n.textGridExported : l10n.exportFailed(error));
  }

  /// Exports the per-interval measurement recipe (same columns as the
  /// CLI's `measure`) for the active tier, or the first interval tier when
  /// the active one is a point tier.
  Future<void> _exportMeasurements() async {
    final l10n = AppLocalizations.of(context)!;
    final doc = _controller.annotation?.doc;
    if (doc == null) return;
    IntervalTierModel? tier;
    if (_controller.activeTier < doc.tiers.length &&
        doc.tiers[_controller.activeTier] is IntervalTierModel) {
      tier = doc.tiers[_controller.activeTier] as IntervalTierModel;
    } else {
      tier = doc.tiers.whereType<IntervalTierModel>().firstOrNull;
    }
    if (tier == null) {
      _snack(l10n.noIntervalTier);
      return;
    }
    final edited = _controller.f0EditedMask;
    final rows = measureIntervals(
      tier,
      f0: _controller.f0Track,
      f0Edited: edited,
      intensity: _controller.intensityTrack,
      formants: _controller.formantTrack,
    );
    if (rows.isEmpty) {
      _snack(l10n.noLabelledIntervals);
      return;
    }
    final stem = sanitizeFileName(widget.recording.name);
    if (_useShareSheet) {
      try {
        final dir = await exportDirectory();
        final path = '${dir.path}/${stem}_measures.csv';
        await File(path).writeAsString(
          measurementsCsv(tier.name, rows, editedColumn: edited != null),
        );
        await _shareFile(path, 'text/csv');
      } catch (e) {
        _snack(l10n.exportFailed('$e'));
      }
      return;
    }
    const csvType = XTypeGroup(label: 'CSV', extensions: ['csv']);
    final location = await getSaveLocation(
      suggestedName: '${stem}_measures.csv',
      acceptedTypeGroups: const [csvType],
    );
    if (location == null || !mounted) return;
    try {
      await File(location.path).writeAsString(
        measurementsCsv(tier.name, rows, editedColumn: edited != null),
      );
      _snack(l10n.measurementsExported(rows.length));
    } catch (e) {
      _snack(l10n.exportFailed('$e'));
    }
  }

  /// Praat's "extract selection": the selected stretch as a 16-bit WAV,
  /// through the share sheet on mobile and a save dialog on desktop.
  Future<void> _exportSelection() async {
    final l10n = AppLocalizations.of(context)!;
    final sound = _controller.sound;
    final sel = _controller.selection;
    if (sound == null || sel == null || sel.span <= 0) return;
    final stem = sanitizeFileName(widget.recording.name);
    final name =
        '${stem}_${sel.t0.toStringAsFixed(3)}-${sel.t1.toStringAsFixed(3)}s.wav';
    try {
      if (_useShareSheet) {
        final dir = await exportDirectory();
        final path = '${dir.path}/$name';
        await sound.exportRangeWav(t0S: sel.t0, t1S: sel.t1, path: path);
        await _shareFile(path, 'audio/x-wav');
        return;
      }
      const wavType = XTypeGroup(label: 'WAV', extensions: ['wav']);
      final location = await getSaveLocation(
        suggestedName: name,
        acceptedTypeGroups: const [wavType],
      );
      if (location == null) return;
      await sound.exportRangeWav(t0S: sel.t0, t1S: sel.t1, path: location.path);
      _snack(l10n.selectionSaved);
    } catch (e) {
      _snack(l10n.exportFailed('$e'));
    }
  }

  /// Praat-style voice report over the selection, or the whole recording
  /// when nothing is selected.
  Future<void> _voiceReport() async {
    final sound = _controller.sound;
    if (sound == null) return;
    final sel = _controller.selection;
    final t0 = sel?.t0 ?? 0.0;
    final t1 = sel?.t1 ?? _controller.durationS;
    await showDialog<void>(
      context: context,
      builder: (context) => VoiceReportDialog(
        load: () => sound.voiceReport(
          t0S: t0,
          t1S: t1,
          f0MinHz: _controller.pitchFloorHz,
          f0MaxHz: _controller.pitchCeilingHz,
        ),
        t0: t0,
        t1: t1,
        isSelection: sel != null,
        pitchFloorHz: _controller.pitchFloorHz,
        pitchCeilingHz: _controller.pitchCeilingHz,
      ),
    );
  }

  Future<void> _newTextGrid() async {
    final l10n = AppLocalizations.of(context)!;
    if (_controller.annotation != null) {
      final replace = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(l10n.replaceTextGridTitle),
          content: Text(l10n.replaceOnNewBody),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text(l10n.cancel),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text(l10n.replace),
            ),
          ],
        ),
      );
      if (replace != true) return;
    }
    _controller.newAnnotation();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: Listenable.merge([_controller, widget.prefs]),
      builder: (context, _) {
        if (_controller.error != null) {
          return Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Text(
                AppLocalizations.of(
                  context,
                )!.couldNotOpenRecording('${_controller.error}'),
                textAlign: TextAlign.center,
              ),
            ),
          );
        }
        if (!_controller.isOpen) {
          return const Center(child: CircularProgressIndicator());
        }
        // Keyboard shortcuts live on this ancestor Focus so they keep
        // working wherever focus lands inside the analysis view (transport
        // buttons, tier strip); unhandled keys bubble up here. While the
        // tier label TextField is focused it consumes these keys itself.
        return Focus(
          onKeyEvent: (node, event) {
            if (event is! KeyDownEvent) return KeyEventResult.ignored;
            final ctrl = HardwareKeyboard.instance.isControlPressed;
            final shift = HardwareKeyboard.instance.isShiftPressed;
            final key = event.logicalKey;
            // Praat-like: Enter inserts a boundary/point at the cursor on
            // the active tier, Delete removes the selected boundary/point.
            bool handled;
            // In pitch edit mode, undo and redo act on the pitch edits.
            final pitch = _controller.pitchEditMode;
            if (ctrl && key == LogicalKeyboardKey.keyZ) {
              handled = switch ((pitch, shift)) {
                (true, true) => _controller.pitchRedo(),
                (true, false) => _controller.pitchUndo(),
                (false, true) => _controller.annotationRedo(),
                (false, false) => _controller.annotationUndo(),
              };
            } else if (ctrl && key == LogicalKeyboardKey.keyY) {
              handled = pitch
                  ? _controller.pitchRedo()
                  : _controller.annotationRedo();
            } else if (key == LogicalKeyboardKey.enter ||
                key == LogicalKeyboardKey.numpadEnter) {
              handled = _controller.annotationInsertAtCursor();
            } else if (key == LogicalKeyboardKey.delete ||
                key == LogicalKeyboardKey.backspace) {
              handled = _controller.annotationDeleteHit();
            } else if (ctrl && key == LogicalKeyboardKey.keyS) {
              handled = _controller.annotation != null;
              if (handled) _saveTextGrid();
            } else {
              handled = false;
            }
            return handled ? KeyEventResult.handled : KeyEventResult.ignored;
          },
          child: Column(
            children: [
              Expanded(
                child: _ViewportArea(
                  controller: _controller,
                  viewPrefs: widget.prefs.viewPrefs,
                ),
              ),
              TierView(controller: _controller),
              if (_controller.tracksLoading)
                const LinearProgressIndicator(minHeight: 2),
              const Divider(height: 1),
              ReadoutPanel(controller: _controller),
              const Divider(height: 1),
              if (_controller.pitchEditMode)
                PitchEditBar(controller: _controller),
              TransportBar(
                controller: _controller,
                prefs: widget.prefs,
                onOpenSettings: _openSettings,
                onImportTextGrid: _importTextGrid,
                onSaveTextGrid: _saveTextGrid,
                onExportTextGrid: _exportTextGrid,
                onNewTextGrid: _newTextGrid,
                onExportMeasurements: _exportMeasurements,
                onVoiceReport: _voiceReport,
                onExportSelection: _exportSelection,
              ),
            ],
          ),
        );
      },
    );
  }
}

/// Waveform strip + spectrogram sharing one time axis, one gesture
/// surface, and one cursor/selection overlay.
///
/// Gestures: tap = cursor; one-pointer drag = selection; two-pointer
/// scale = zoom about the focal point (with pan); double tap = zoom to
/// fit; mouse wheel = zoom about the pointer, Shift+wheel = pan.
class _ViewportArea extends StatefulWidget {
  const _ViewportArea({required this.controller, required this.viewPrefs});

  final ViewPrefs viewPrefs;

  final AnalysisController controller;

  @override
  State<_ViewportArea> createState() => _ViewportAreaState();
}

enum _DragMode { newSelection, adjustStart, adjustEnd }

class _ViewportAreaState extends State<_ViewportArea> {
  double? _dragAnchorT;
  _DragMode _dragMode = _DragMode.newSelection;
  double _scaleStartSpan = 0;
  double _scaleFocalT = 0;
  bool _shiftDown = false;
  PointerDeviceKind? _lastPointerKind;
  Size _lastSize = Size.zero;

  AnalysisController get c => widget.controller;

  double _plotWidth(BoxConstraints constraints) =>
      math.max(1, constraints.maxWidth - kFreqAxisWidth);

  double _xToT(double dx, double plotWidth) => xToTime(
    dx - kFreqAxisWidth,
    c.viewport,
    plotWidth,
  ).clamp(0.0, c.durationS);

  /// Frequency at a tap position, when it falls inside the spectrogram plot.
  double? _yToFreq(double dy) {
    final plotHeight = _lastSize.height - kSpectrogramTop - kTimeAxisHeight;
    if (dy < kSpectrogramTop || plotHeight <= 0) return null;
    final frac = 1 - (dy - kSpectrogramTop) / plotHeight;
    if (frac < 0) return null;
    return frac * c.sgMaxFreqHz;
  }

  /// In pitch edit mode, a tap near a candidate chooses it; returns
  /// whether the tap was consumed.
  bool _pitchTap(double dx, double dy, double plotWidth) {
    if (!c.pitchEditMode) return false;
    final plotHeight = _lastSize.height - kSpectrogramTop - kTimeAxisHeight;
    if (dy < kSpectrogramTop || plotHeight <= 0) return false;
    final frac = 1 - (dy - kSpectrogramTop) / plotHeight;
    if (frac < 0) return false;
    final slop = selectionEdgeSlopFor(_lastPointerKind);
    return c.pitchEditTap(
      _xToT(dx, plotWidth),
      frac,
      tolFrac: slop / plotHeight,
    );
  }

  /// Selection-edge hit test with ±12 px slop; decides the drag mode.
  _DragMode _modeFor(double dx, double plotWidth) {
    final sel = c.selection;
    if (sel == null) return _DragMode.newSelection;
    final slop = selectionEdgeSlopFor(_lastPointerKind);
    final x0 = kFreqAxisWidth + timeToX(sel.t0, c.viewport, plotWidth);
    final x1 = kFreqAxisWidth + timeToX(sel.t1, c.viewport, plotWidth);
    if ((dx - x0).abs() <= slop) return _DragMode.adjustStart;
    if ((dx - x1).abs() <= slop) return _DragMode.adjustEnd;
    return _DragMode.newSelection;
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final plotWidth = _plotWidth(constraints);
        _lastSize = Size(constraints.maxWidth, constraints.maxHeight);
        return Listener(
          // ScaleStartDetails carries no pointer kind; remember it here so
          // the selection-edge slop can widen for fingers.
          onPointerDown: (event) => _lastPointerKind = event.kind,
          onPointerSignal: (event) {
            if (event is! PointerScrollEvent) return;
            final t = _xToT(event.localPosition.dx, plotWidth);
            if (_shiftDown) {
              c.panBy(event.scrollDelta.dy / plotWidth * c.viewport.span);
            } else {
              c.zoomAbout(t, math.exp(event.scrollDelta.dy * 0.0015));
            }
          },
          child: Focus(
            autofocus: true,
            onKeyEvent: (node, event) {
              _shiftDown = HardwareKeyboard.instance.isShiftPressed;
              return KeyEventResult.ignored;
            },
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTapUp: (d) {
                final pos = d.localPosition;
                if (_pitchTap(pos.dx, pos.dy, plotWidth)) return;
                c.setCursor(_xToT(pos.dx, plotWidth), freqHz: _yToFreq(pos.dy));
              },
              onDoubleTap: c.zoomToFit,
              onScaleStart: (d) {
                _scaleStartSpan = c.viewport.span;
                _scaleFocalT = _xToT(d.localFocalPoint.dx, plotWidth);
                if (d.pointerCount == 1) {
                  _dragMode = _modeFor(d.localFocalPoint.dx, plotWidth);
                  final sel = c.selection;
                  _dragAnchorT = switch (_dragMode) {
                    _DragMode.newSelection => _xToT(
                      d.localFocalPoint.dx,
                      plotWidth,
                    ),
                    _DragMode.adjustStart => sel!.t1,
                    _DragMode.adjustEnd => sel!.t0,
                  };
                } else {
                  _dragAnchorT = null;
                }
              },
              onScaleUpdate: (d) {
                if (d.pointerCount >= 2) {
                  _dragAnchorT = null;
                  final span = (_scaleStartSpan / d.scale).clamp(
                    kMinViewportSpanS,
                    math.max(c.durationS, 0.001),
                  );
                  final focalFrac =
                      (d.localFocalPoint.dx - kFreqAxisWidth) / plotWidth;
                  final t0 = _scaleFocalT - focalFrac * span;
                  c.setViewport(t0, t0 + span);
                } else {
                  final anchor = _dragAnchorT;
                  if (anchor == null) return;
                  final t = _xToT(d.localFocalPoint.dx, plotWidth);
                  if ((t - anchor).abs() > 1e-6) {
                    c.setSelection(TimeSelection(anchor, t));
                  }
                }
              },
              child: Stack(
                fit: StackFit.expand,
                children: [
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      SizedBox(
                        height: kWaveformHeight,
                        child: Padding(
                          padding: const EdgeInsets.only(left: kFreqAxisWidth),
                          child: WaveformView(controller: c),
                        ),
                      ),
                      const Divider(height: 1),
                      Expanded(
                        child: Stack(
                          fit: StackFit.expand,
                          children: [
                            SpectrogramView(
                              controller: c,
                              showImage: widget.viewPrefs.showSpectrogram,
                            ),
                            TrackOverlay(
                              controller: c,
                              viewPrefs: widget.viewPrefs,
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  // Selection and cursor span both panels.
                  RepaintBoundary(
                    child: AnimatedBuilder(
                      animation: c,
                      builder: (context, _) => CustomPaint(
                        painter: _SelectionPainter(
                          selection: c.selection,
                          viewport: c.viewport,
                          color: Theme.of(
                            context,
                          ).colorScheme.primary.withValues(alpha: 0.2),
                        ),
                      ),
                    ),
                  ),
                  RepaintBoundary(
                    child: ValueListenableBuilder<Duration>(
                      valueListenable: c.playback.position,
                      builder: (context, position, _) => AnimatedBuilder(
                        animation: c,
                        builder: (context, _) => CustomPaint(
                          painter: _CursorPainter(
                            timeS: position.inMicroseconds / 1e6,
                            viewport: c.viewport,
                            color: Theme.of(context).colorScheme.error,
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

/// Half-width in px within which a press grabs a selection edge instead of
/// starting a new selection: half a 48 dp target for fingers, tighter for
/// precise pointers.
double selectionEdgeSlopFor(PointerDeviceKind? kind) =>
    kind == PointerDeviceKind.touch ? 24.0 : 12.0;

class _SelectionPainter extends CustomPainter {
  _SelectionPainter({
    required this.selection,
    required this.viewport,
    required this.color,
  });

  final TimeSelection? selection;
  final TimeViewport viewport;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final sel = selection;
    if (sel == null) return;
    final plotWidth = size.width - kFreqAxisWidth;
    final x0 = kFreqAxisWidth + timeToX(sel.t0, viewport, plotWidth);
    final x1 = kFreqAxisWidth + timeToX(sel.t1, viewport, plotWidth);
    final left = x0.clamp(kFreqAxisWidth, size.width);
    final right = x1.clamp(kFreqAxisWidth, size.width);
    if (right <= left) return;
    final bottom = size.height - kTimeAxisHeight;
    canvas.drawRect(
      Rect.fromLTRB(left, 0, right, bottom),
      Paint()..color = color,
    );
    // Edge handles (draggable with slop) with a centered grab pill each,
    // so the touch affordance is visible.
    final edge = Paint()
      ..color = color.withValues(alpha: 0.9)
      ..strokeWidth = 3;
    final pill = Paint()..color = color.withValues(alpha: 1.0);
    for (final x in [left, right]) {
      canvas.drawLine(Offset(x, 0), Offset(x, bottom), edge);
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromCenter(center: Offset(x, bottom / 2), width: 6, height: 28),
          const Radius.circular(3),
        ),
        pill,
      );
    }
  }

  @override
  bool shouldRepaint(_SelectionPainter old) =>
      old.selection != selection || old.viewport != viewport;
}

class _CursorPainter extends CustomPainter {
  _CursorPainter({
    required this.timeS,
    required this.viewport,
    required this.color,
  });

  final double timeS;
  final TimeViewport viewport;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    if (!viewport.contains(timeS)) return;
    final plotWidth = size.width - kFreqAxisWidth;
    final x = kFreqAxisWidth + timeToX(timeS, viewport, plotWidth);
    canvas.drawLine(
      Offset(x, 0),
      Offset(x, size.height - kTimeAxisHeight),
      Paint()
        ..color = color
        ..strokeWidth = 1,
    );
  }

  @override
  bool shouldRepaint(_CursorPainter old) =>
      old.timeS != timeS || old.viewport != viewport;
}
