import 'package:flutter/material.dart';

import '../../../l10n/app_localizations.dart';
import '../../analysis/analysis_settings.dart';
import '../breakpoints.dart';

/// Opens the per-recording analysis settings as a bottom sheet (compact)
/// or dialog (expanded). Returns the new settings, or null if dismissed.
Future<AnalysisSettings?> showAnalysisSettings(
  BuildContext context,
  AnalysisSettings current,
) {
  if (isExpanded(context)) {
    return showDialog<AnalysisSettings>(
      context: context,
      builder: (context) => Dialog(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 480, maxHeight: 640),
          child: _SettingsForm(current: current),
        ),
      ),
    );
  }
  return showModalBottomSheet<AnalysisSettings>(
    context: context,
    isScrollControlled: true,
    builder: (context) => Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.8,
        builder: (context, scroll) =>
            _SettingsForm(current: current, scrollController: scroll),
      ),
    ),
  );
}

class _SettingsForm extends StatefulWidget {
  const _SettingsForm({required this.current, this.scrollController});

  final AnalysisSettings current;
  final ScrollController? scrollController;

  @override
  State<_SettingsForm> createState() => _SettingsFormState();
}

class _SettingsFormState extends State<_SettingsForm> {
  late final Map<String, TextEditingController> _fields;
  late int _maxFormants;

  @override
  void initState() {
    super.initState();
    final s = widget.current;
    _fields = {
      'window': _ctl(s.spectrogramWindowS * 1000),
      'maxFreq': _ctl(s.spectrogramMaxFreqHz),
      'dynRange': _ctl(s.dynamicRangeDb),
      'preEmph': _ctl(s.spectrogramPreEmphasisHz),
      'minStep': _ctl(s.spectrogramMinTimeStepS * 1000),
      'pitchFloor': _ctl(s.pitchFloorHz),
      'pitchCeil': _ctl(s.pitchCeilingHz),
      'formantCeil': _ctl(s.formantCeilingHz),
      'intMinPitch': _ctl(s.intensityMinPitchHz),
      'trackStep': _ctl(s.trackTimeStepS * 1000),
    };
    _maxFormants = s.maxFormants;
  }

  static TextEditingController _ctl(double v) => TextEditingController(
    text: v == v.roundToDouble() ? '${v.round()}' : '$v',
  );

  @override
  void dispose() {
    for (final c in _fields.values) {
      c.dispose();
    }
    super.dispose();
  }

  double _value(String key, double fallback) =>
      double.tryParse(_fields[key]!.text.replaceAll(',', '.')) ?? fallback;

  void _applyVoicePreset(double floor, double ceiling, double formantCeil) {
    setState(() {
      _fields['pitchFloor']!.text = '${floor.round()}';
      _fields['pitchCeil']!.text = '${ceiling.round()}';
      _fields['formantCeil']!.text = '${formantCeil.round()}';
    });
  }

  AnalysisSettings _collect() {
    final s = widget.current;
    return s.copyWith(
      spectrogramWindowS: (_value('window', s.spectrogramWindowS * 1000) / 1000)
          .clamp(0.001, 0.1),
      spectrogramMaxFreqHz: _value(
        'maxFreq',
        s.spectrogramMaxFreqHz,
      ).clamp(500, 22050),
      dynamicRangeDb: _value('dynRange', s.dynamicRangeDb).clamp(20, 120),
      spectrogramPreEmphasisHz: _value(
        'preEmph',
        s.spectrogramPreEmphasisHz,
      ).clamp(0, 1000),
      spectrogramMinTimeStepS:
          (_value('minStep', s.spectrogramMinTimeStepS * 1000) / 1000)
              .clamp(0.0005, 0.05),
      pitchFloorHz: _value('pitchFloor', s.pitchFloorHz).clamp(30, 800),
      pitchCeilingHz: _value('pitchCeil', s.pitchCeilingHz).clamp(60, 2000),
      maxFormants: _maxFormants,
      formantCeilingHz: _value(
        'formantCeil',
        s.formantCeilingHz,
      ).clamp(3000, 11000),
      intensityMinPitchHz: _value(
        'intMinPitch',
        s.intensityMinPitchHz,
      ).clamp(30, 600),
      trackTimeStepS: (_value('trackStep', s.trackTimeStepS * 1000) / 1000)
          .clamp(0.001, 0.1),
    );
  }

  Widget _field(String key, String label, String unit) {
    return SizedBox(
      width: 140,
      child: TextField(
        controller: _fields[key],
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        decoration: InputDecoration(
          labelText: label,
          suffixText: unit,
          isDense: true,
        ),
      ),
    );
  }

  Widget _section(String title, List<Widget> children) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 8),
          Wrap(spacing: 12, runSpacing: 12, children: children),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Column(
      children: [
        Expanded(
          child: ListView(
            controller: widget.scrollController,
            padding: const EdgeInsets.all(20),
            children: [
              Text(
                l10n.analysisSettingsTooltip,
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: 12),
              // Praat-convention voice presets: pitch range + formant
              // ceiling. They only prefill the fields; Apply commits.
              Wrap(
                spacing: 8,
                children: [
                  ActionChip(
                    label: Text(l10n.presetAdultMale),
                    onPressed: () => _applyVoicePreset(75, 300, 5000),
                  ),
                  ActionChip(
                    label: Text(l10n.presetAdultFemale),
                    onPressed: () => _applyVoicePreset(100, 500, 5500),
                  ),
                  ActionChip(
                    label: Text(l10n.presetChild),
                    onPressed: () => _applyVoicePreset(150, 800, 8000),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              _section(l10n.sheetSpectrogram, [
                _field('window', l10n.windowLength, 'ms'),
                _field('maxFreq', l10n.maxFrequency, 'Hz'),
                _field('dynRange', l10n.dynamicRange, 'dB'),
                _field('preEmph', l10n.preEmphasisFrom, 'Hz'),
                _field('minStep', l10n.minTimeStep, 'ms'),
              ]),
              _section(l10n.sheetPitch, [
                _field('pitchFloor', l10n.floor, 'Hz'),
                _field('pitchCeil', l10n.ceiling, 'Hz'),
              ]),
              _section(l10n.sheetFormants, [
                SizedBox(
                  width: 140,
                  child: DropdownButtonFormField<int>(
                    initialValue: _maxFormants,
                    decoration: InputDecoration(
                      labelText: l10n.count,
                      isDense: true,
                    ),
                    items: [
                      for (var n = 3; n <= 6; n++)
                        DropdownMenuItem(value: n, child: Text('$n')),
                    ],
                    onChanged: (v) =>
                        setState(() => _maxFormants = v ?? _maxFormants),
                  ),
                ),
                _field('formantCeil', l10n.ceiling, 'Hz'),
              ]),
              _section(l10n.sheetIntensity, [
                _field('intMinPitch', l10n.minimumPitch, 'Hz'),
              ]),
              _section(l10n.sheetTracks, [
                _field('trackStep', l10n.trackTimeStep, 'ms'),
              ]),
            ],
          ),
        ),
        const Divider(height: 1),
        Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              TextButton(
                onPressed: () =>
                    Navigator.pop(context, const AnalysisSettings()),
                child: Text(l10n.resetToDefaults),
              ),
              const Spacer(),
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: Text(l10n.cancel),
              ),
              const SizedBox(width: 8),
              FilledButton(
                onPressed: () => Navigator.pop(context, _collect()),
                child: Text(l10n.apply),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
