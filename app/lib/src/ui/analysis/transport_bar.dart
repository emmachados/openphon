import 'package:flutter/material.dart';

import '../../../l10n/app_localizations.dart';

import '../../analysis/analysis_controller.dart';
import '../../data/app_prefs.dart';

class TransportBar extends StatelessWidget {
  const TransportBar({
    super.key,
    required this.controller,
    required this.prefs,
    this.onOpenSettings,
    this.onImportTextGrid,
    this.onSaveTextGrid,
    this.onExportTextGrid,
    this.onNewTextGrid,
    this.onExportMeasurements,
    this.onVoiceReport,
    this.onExportSelection,
  });

  final AnalysisController controller;
  final AppPrefs prefs;
  final VoidCallback? onOpenSettings;
  final VoidCallback? onImportTextGrid;
  final VoidCallback? onSaveTextGrid;
  final VoidCallback? onExportTextGrid;
  final VoidCallback? onNewTextGrid;
  final VoidCallback? onExportMeasurements;
  final VoidCallback? onVoiceReport;
  final VoidCallback? onExportSelection;

  static String _fmtRate(double r) =>
      r == r.roundToDouble() ? '${r.toInt()}×' : '$r×';

  String _fmt(Duration d) {
    final ms = d.inMilliseconds;
    final m = ms ~/ 60000;
    final s = (ms % 60000) / 1000;
    return '$m:${s.toStringAsFixed(2).padLeft(5, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final playback = controller.playback;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: AnimatedBuilder(
        animation: controller,
        builder: (context, _) {
          final hasSelection = controller.selection != null;
          final playCluster = <Widget>[
            ValueListenableBuilder<bool>(
              valueListenable: playback.playing,
              builder: (context, playing, _) => IconButton.filledTonal(
                icon: Icon(playing ? Icons.pause : Icons.play_arrow),
                tooltip: playing ? l10n.pause : l10n.play,
                onPressed: controller.isOpen ? controller.togglePlay : null,
              ),
            ),
            IconButton(
              icon: const Icon(Icons.play_lesson_outlined),
              tooltip: l10n.playSelection,
              onPressed: hasSelection ? controller.playSelection : null,
            ),
            IconButton(
              icon: const Icon(Icons.repeat),
              tooltip: l10n.loopSelectionTooltip,
              isSelected: controller.loopSelection,
              // Stays enabled while active so it can be switched off after
              // the selection is cleared.
              onPressed: hasSelection || controller.loopSelection
                  ? controller.toggleLoopSelection
                  : null,
            ),
            ValueListenableBuilder<double>(
              valueListenable: playback.rate,
              builder: (context, rate, _) => PopupMenuButton<double>(
                tooltip: l10n.playbackRateTooltip,
                initialValue: rate,
                onSelected: playback.setRate,
                itemBuilder: (context) => [
                  for (final r in const [0.5, 0.75, 1.0])
                    PopupMenuItem(value: r, child: Text(_fmtRate(r))),
                ],
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 12,
                  ),
                  child: Text(
                    _fmtRate(rate),
                    style: Theme.of(context).textTheme.labelLarge?.copyWith(
                      color: rate != 1.0
                          ? Theme.of(context).colorScheme.primary
                          : null,
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 8),
            ValueListenableBuilder<Duration>(
              valueListenable: playback.position,
              builder: (context, position, _) => Text(
                '${_fmt(position)} / ${_fmt(playback.duration)}',
                style: Theme.of(context).textTheme.labelLarge,
              ),
            ),
            if (hasSelection)
              Flexible(
                child: Padding(
                  padding: const EdgeInsets.only(left: 16),
                  child: Text(
                    l10n.selectionSpan(
                      controller.selection!.span.toStringAsFixed(3),
                    ),
                    style: Theme.of(context).textTheme.labelMedium,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ),
          ];
          final toolCluster = <Widget>[
            PopupMenuButton<String>(
              icon: const Icon(Icons.layers_outlined),
              tooltip: l10n.layersTooltip,
              onSelected: (v) {
                final vp = prefs.viewPrefs;
                prefs.setViewPrefs(switch (v) {
                  'spectrogram' => vp.copyWith(
                    showSpectrogram: !vp.showSpectrogram,
                  ),
                  'pitch' => vp.copyWith(showPitch: !vp.showPitch),
                  'formants' => vp.copyWith(showFormants: !vp.showFormants),
                  _ => vp.copyWith(showIntensity: !vp.showIntensity),
                });
              },
              itemBuilder: (context) => [
                CheckedPopupMenuItem(
                  value: 'spectrogram',
                  checked: prefs.viewPrefs.showSpectrogram,
                  child: Text(l10n.sheetSpectrogram),
                ),
                CheckedPopupMenuItem(
                  value: 'pitch',
                  checked: prefs.viewPrefs.showPitch,
                  child: Text(l10n.sheetPitch),
                ),
                CheckedPopupMenuItem(
                  value: 'formants',
                  checked: prefs.viewPrefs.showFormants,
                  child: Text(l10n.sheetFormants),
                ),
                CheckedPopupMenuItem(
                  value: 'intensity',
                  checked: prefs.viewPrefs.showIntensity,
                  child: Text(l10n.sheetIntensity),
                ),
              ],
            ),
            IconButton(
              icon: const Icon(Icons.center_focus_strong),
              tooltip: l10n.zoomToSelection,
              onPressed: hasSelection ? controller.zoomToSelection : null,
            ),
            IconButton(
              icon: const Icon(Icons.fit_screen),
              tooltip: l10n.zoomToFit,
              onPressed: controller.isOpen ? controller.zoomToFit : null,
            ),
            IconButton(
              icon: const Icon(Icons.content_cut),
              tooltip: l10n.saveSelectionWavTooltip,
              onPressed: hasSelection ? onExportSelection : null,
            ),
            if (controller.annotation != null) ...[
              // On-screen equivalents of Enter/Delete: touch devices have
              // no hardware keys, so boundary editing must not need them.
              IconButton(
                icon: const Icon(Icons.add),
                tooltip: l10n.insertBoundaryTooltip,
                onPressed: controller.cursorTimeS != null
                    ? () => controller.annotationInsertAtCursor()
                    : null,
              ),
              IconButton(
                icon: const Icon(Icons.backspace_outlined),
                tooltip: l10n.deleteBoundaryTooltip,
                onPressed: controller.annotationHit != null
                    ? () => controller.annotationDeleteHit()
                    : null,
              ),
              IconButton(
                icon: const Icon(Icons.undo),
                tooltip: l10n.undoTooltip,
                onPressed: controller.annotation!.canUndo
                    ? controller.annotationUndo
                    : null,
              ),
              IconButton(
                icon: const Icon(Icons.redo),
                tooltip: l10n.redoTooltip,
                onPressed: controller.annotation!.canRedo
                    ? controller.annotationRedo
                    : null,
              ),
            ],
            PopupMenuButton<String>(
              icon: Badge(
                isLabelVisible: controller.annotation?.dirty ?? false,
                smallSize: 8,
                child: const Icon(Icons.notes),
              ),
              tooltip: l10n.textGridMenu,
              enabled: controller.isOpen,
              onSelected: (v) {
                switch (v) {
                  case 'import':
                    onImportTextGrid?.call();
                  case 'save':
                    onSaveTextGrid?.call();
                  case 'export':
                    onExportTextGrid?.call();
                  case 'new':
                    onNewTextGrid?.call();
                  case 'measure':
                    onExportMeasurements?.call();
                }
              },
              itemBuilder: (context) {
                final hasGrid = controller.annotation != null;
                return [
                  PopupMenuItem(
                    value: 'save',
                    enabled: hasGrid,
                    child: Text(l10n.saveTextGridMenu),
                  ),
                  PopupMenuItem(
                    value: 'export',
                    enabled: hasGrid,
                    child: Text(l10n.exportTextGridMenu),
                  ),
                  PopupMenuItem(
                    value: 'measure',
                    enabled: hasGrid,
                    child: Text(l10n.exportMeasurementsMenu),
                  ),
                  const PopupMenuDivider(),
                  PopupMenuItem(
                    value: 'new',
                    child: Text(l10n.newTextGridMenu),
                  ),
                  PopupMenuItem(
                    value: 'import',
                    child: Text(l10n.importTextGridMenu),
                  ),
                ];
              },
            ),
            IconButton(
              icon: const Icon(Icons.record_voice_over_outlined),
              tooltip: l10n.voiceReportTitle,
              onPressed: controller.isOpen ? onVoiceReport : null,
            ),
            IconButton(
              icon: const Icon(Icons.tune),
              tooltip: l10n.analysisSettingsTooltip,
              onPressed: controller.isOpen ? onOpenSettings : null,
            ),
            if (hasSelection)
              IconButton(
                icon: const Icon(Icons.close),
                tooltip: l10n.clearSelection,
                onPressed: () => controller.setSelection(null),
              ),
          ];
          // One row when everything fits (desktop/tablet); on narrow phone
          // widths stack the play cluster over a right-aligned tool row
          // instead of overflowing.
          return LayoutBuilder(
            builder: (context, constraints) {
              if (constraints.maxWidth >= 700) {
                return Row(
                  children: [...playCluster, const Spacer(), ...toolCluster],
                );
              }
              return Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(children: playCluster),
                  // Wrap, not Row: with a TextGrid loaded the tool cluster
                  // exceeds narrow phone widths and must break lines.
                  Align(
                    alignment: Alignment.centerRight,
                    child: Wrap(
                      alignment: WrapAlignment.end,
                      children: toolCluster,
                    ),
                  ),
                ],
              );
            },
          );
        },
      ),
    );
  }
}
