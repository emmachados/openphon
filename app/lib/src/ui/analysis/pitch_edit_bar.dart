import 'package:flutter/material.dart';

import '../../../l10n/app_localizations.dart';
import '../../analysis/analysis_controller.dart';

/// Controls for manual pitch correction, shown while pitch edit mode is on.
/// Selection operations act on the frames inside the current selection.
class PitchEditBar extends StatelessWidget {
  const PitchEditBar({super.key, required this.controller});

  final AnalysisController controller;

  String _num(double v) =>
      v == v.roundToDouble() ? '${v.toInt()}' : v.toString();

  Future<void> _confirmDiscard(BuildContext context) async {
    final l10n = AppLocalizations.of(context)!;
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l10n.discardPitchEditsTitle),
        content: Text(l10n.discardPitchEditsBody),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(l10n.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(l10n.discard),
          ),
        ],
      ),
    );
    if (ok == true) await controller.discardStoredPitchEdits();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        final c = controller;
        final ed = c.pitchEditor;
        final stored = c.storedPitchEdits;
        final String message;
        if (c.pitchEditsUnreadable != null) {
          message = l10n.pitchEditsUnreadable('${c.pitchEditsUnreadable}');
        } else if (c.pitchEditsMismatch && stored != null) {
          message = l10n.pitchEditsOtherSettings(
            _num(stored.timeStepS),
            _num(stored.f0MinHz),
            _num(stored.f0MaxHz),
          );
        } else if (c.pitchEditsError != null) {
          message = l10n.pitchEditsSaveFailed('${c.pitchEditsError}');
        } else if (ed != null && !ed.isEmpty) {
          message = l10n.pitchEditedFrames(ed.editedCount);
        } else {
          message = l10n.pitchEditHint;
        }
        final blocked = ed == null && c.f0Candidates != null;
        final canSel = ed != null && c.selection != null;
        return Material(
          color: theme.colorScheme.surfaceContainerHigh,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
            child: Wrap(
              crossAxisAlignment: WrapCrossAlignment.center,
              alignment: WrapAlignment.end,
              children: [
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  child: Text(message, style: theme.textTheme.labelMedium),
                ),
                if (blocked)
                  TextButton(
                    onPressed: () => _confirmDiscard(context),
                    child: Text(l10n.discardPitchEdits),
                  )
                else ...[
                  IconButton(
                    icon: const Icon(Icons.keyboard_double_arrow_down),
                    tooltip: l10n.octaveDownTooltip,
                    onPressed: canSel ? c.pitchOctaveDown : null,
                  ),
                  IconButton(
                    icon: const Icon(Icons.keyboard_double_arrow_up),
                    tooltip: l10n.octaveUpTooltip,
                    onPressed: canSel ? c.pitchOctaveUp : null,
                  ),
                  IconButton(
                    icon: const Icon(Icons.remove_circle_outline),
                    tooltip: l10n.unvoiceTooltip,
                    onPressed: canSel ? c.pitchUnvoice : null,
                  ),
                  IconButton(
                    icon: const Icon(Icons.add_circle_outline),
                    tooltip: l10n.voiceTooltip,
                    onPressed: canSel ? c.pitchVoice : null,
                  ),
                  IconButton(
                    icon: const Icon(Icons.restore),
                    tooltip: l10n.revertPitchTooltip,
                    onPressed: canSel ? c.pitchRevert : null,
                  ),
                  IconButton(
                    icon: const Icon(Icons.undo),
                    tooltip: l10n.undoTooltip,
                    onPressed: ed?.canUndo ?? false ? c.pitchUndo : null,
                  ),
                  IconButton(
                    icon: const Icon(Icons.redo),
                    tooltip: l10n.redoTooltip,
                    onPressed: ed?.canRedo ?? false ? c.pitchRedo : null,
                  ),
                ],
                IconButton(
                  icon: const Icon(Icons.close),
                  tooltip: l10n.exitPitchEditTooltip,
                  onPressed: c.togglePitchEditMode,
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
