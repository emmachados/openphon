import 'package:flutter/material.dart';

import '../../../l10n/app_localizations.dart';

import '../../analysis/analysis_controller.dart';
import '../breakpoints.dart';

/// Values at the cursor: time, frequency at the tap point, F0, intensity,
/// formants. One decimal, Praat units (s, Hz, dB).
class ReadoutPanel extends StatelessWidget {
  const ReadoutPanel({super.key, required this.controller});

  final AnalysisController controller;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        final t = controller.cursorTimeS;
        // Compact = phone in the hand at arm's length; use body-sized text
        // there and the denser label style on desktop/tablet.
        final base = isExpanded(context)
            ? Theme.of(context).textTheme.labelMedium
            : Theme.of(context).textTheme.titleSmall;
        final style = base?.copyWith(
          fontFeatures: const [FontFeature.tabularFigures()],
        );
        if (t == null) {
          return Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            child: Text(
              AppLocalizations.of(context)!.tapSpectrogramHint,
              style: style,
            ),
          );
        }
        final items = <String>[
          't ${t.toStringAsFixed(3)} s',
          if (controller.cursorFreqHz != null)
            'cursor ${controller.cursorFreqHz!.toStringAsFixed(0)} Hz',
          'F0 ${_fmt(controller.f0At(t), 'Hz', unvoiced: true)}',
          'int ${_fmt(controller.intensityAt(t), 'dB')}',
        ];
        final formants = controller.formantsAt(t);
        for (var k = 0; k < formants.length && k < 3; k++) {
          items.add('F${k + 1} ${_fmt(formants[k], 'Hz')}');
        }
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          child: Wrap(
            spacing: 16,
            runSpacing: 4,
            children: [for (final s in items) Text(s, style: style)],
          ),
        );
      },
    );
  }

  static String _fmt(double? v, String unit, {bool unvoiced = false}) {
    if (v == null) return unvoiced ? 'unvoiced' : '—';
    return '${v.toStringAsFixed(1)} $unit';
  }
}
