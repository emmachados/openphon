import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;

import '../../../l10n/app_localizations.dart';
import '../../rust/api/core.dart' as rust;

/// Below this many glottal periods the report shows the sparse-material
/// hint even when values exist: local jitter/shimmer averaged over a few
/// cycles say nothing about the voice.
const int kMinReliablePeriods = 30;

/// Praat-style voice report (mean HNR, local jitter/shimmer, period
/// count) over the selection when there is one, else the whole
/// recording. The loader is injected so the dialog stays testable
/// without the Rust bridge.
class VoiceReportDialog extends StatefulWidget {
  const VoiceReportDialog({
    super.key,
    required this.load,
    required this.t0,
    required this.t1,
    required this.isSelection,
    required this.pitchFloorHz,
    required this.pitchCeilingHz,
  });

  final Future<rust.VoiceReportData> Function() load;

  /// Analyzed range in seconds; [isSelection] only changes the caption.
  final double t0;
  final double t1;
  final bool isSelection;
  final double pitchFloorHz;
  final double pitchCeilingHz;

  @override
  State<VoiceReportDialog> createState() => _VoiceReportDialogState();
}

class _VoiceReportDialogState extends State<VoiceReportDialog> {
  late final Future<rust.VoiceReportData> _future = widget.load();

  String _fmtS(double t) => t.toStringAsFixed(3);

  String _rangeCaption(AppLocalizations l10n) => widget.isSelection
      ? l10n.voiceReportSelectionRange(_fmtS(widget.t0), _fmtS(widget.t1))
      : l10n.voiceReportWholeRange(_fmtS(widget.t1));

  String _pitchCaption(AppLocalizations l10n) => l10n.voiceReportPitchRange(
    widget.pitchFloorHz.toStringAsFixed(0),
    widget.pitchCeilingHz.toStringAsFixed(0),
  );

  static String _hnr(rust.VoiceReportData r) =>
      r.meanHnrDb == null ? '—' : '${r.meanHnrDb!.toStringAsFixed(1)} dB';

  static String _pct(double? v) =>
      v == null ? '—' : '${(v * 100).toStringAsFixed(2)} %';

  static String _hz(double? v) =>
      v == null ? '—' : '${v.toStringAsFixed(1)} Hz';

  List<(String, String)> _rows(AppLocalizations l10n, rust.VoiceReportData r) =>
      [
        (l10n.medianF0Label, _hz(r.medianF0Hz)),
        (l10n.meanF0Label, _hz(r.meanF0Hz)),
        (l10n.sdF0Label, _hz(r.sdF0Hz)),
        (l10n.meanHnrLabel, _hnr(r)),
        (l10n.jitterLocalLabel, _pct(r.jitterLocal)),
        (l10n.shimmerLocalLabel, _pct(r.shimmerLocal)),
        (l10n.pulsePeriodsLabel, '${r.nPeriods}'),
      ];

  String _clipboardText(AppLocalizations l10n, rust.VoiceReportData r) => [
    l10n.voiceReportTitle,
    _rangeCaption(l10n),
    _pitchCaption(l10n),
    for (final (label, value) in _rows(l10n, r)) '$label\t$value',
  ].join('\n');

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    return AlertDialog(
      title: Text(l10n.voiceReportTitle),
      content: FutureBuilder<rust.VoiceReportData>(
        future: _future,
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            return Text(l10n.voiceReportFailed('${snapshot.error}'));
          }
          final report = snapshot.data;
          if (report == null) {
            return const SizedBox(
              height: 96,
              child: Center(child: CircularProgressIndicator()),
            );
          }
          // Jitter/shimmer means over a handful of cycles are noise, not
          // measurements; flag them, don't just flag absent values.
          final sparse = report.meanHnrDb == null ||
              report.jitterLocal == null ||
              report.shimmerLocal == null ||
              report.nPeriods < BigInt.from(kMinReliablePeriods);
          return SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(_rangeCaption(l10n), style: theme.textTheme.bodySmall),
                Text(_pitchCaption(l10n), style: theme.textTheme.bodySmall),
                const SizedBox(height: 12),
                Table(
                  columnWidths: const {1: IntrinsicColumnWidth()},
                  children: [
                    for (final (label, value) in _rows(l10n, report))
                      TableRow(
                        children: [
                          Padding(
                            padding: const EdgeInsets.symmetric(vertical: 2),
                            child: Text(label),
                          ),
                          Padding(
                            padding: const EdgeInsets.only(left: 16),
                            child: Text(
                              value,
                              textAlign: TextAlign.right,
                              style: theme.textTheme.bodyMedium?.copyWith(
                                fontFeatures: const [
                                  FontFeature.tabularFigures(),
                                ],
                              ),
                            ),
                          ),
                        ],
                      ),
                  ],
                ),
                if (sparse) ...[
                  const SizedBox(height: 12),
                  Text(
                    l10n.voiceReportSparseHint,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ],
            ),
          );
        },
      ),
      actions: [
        FutureBuilder<rust.VoiceReportData>(
          future: _future,
          builder: (context, snapshot) {
            final report = snapshot.data;
            return TextButton(
              onPressed: report == null
                  ? null
                  : () async {
                      await Clipboard.setData(
                        ClipboardData(text: _clipboardText(l10n, report)),
                      );
                      if (context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(content: Text(l10n.reportCopied)),
                        );
                      }
                    },
              child: Text(l10n.copy),
            );
          },
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context),
          child: Text(l10n.close),
        ),
      ],
    );
  }
}
