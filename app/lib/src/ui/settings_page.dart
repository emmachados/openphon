import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';

import '../analysis/analysis_settings.dart';
import '../analysis/view_prefs.dart';
import '../audio/recorder_service.dart' show RecordingOptions;
import '../data/app_prefs.dart';
import '../rust/api/core.dart' as rust_core;
import 'analysis/settings_sheet.dart';

/// App-level settings: appearance, analysis defaults, about.
class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key, required this.prefs});

  final AppPrefs prefs;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Scaffold(
      appBar: AppBar(title: Text(l10n.settings)),
      body: ListenableBuilder(
        listenable: prefs,
        builder: (context, _) => ListView(
          children: [
            _SectionHeader(l10n.appearance),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: SegmentedButton<ThemeMode>(
                segments: [
                  ButtonSegment(
                    value: ThemeMode.system,
                    label: Text(l10n.themeSystem),
                    icon: const Icon(Icons.brightness_auto),
                  ),
                  ButtonSegment(
                    value: ThemeMode.light,
                    label: Text(l10n.themeLight),
                    icon: const Icon(Icons.light_mode),
                  ),
                  ButtonSegment(
                    value: ThemeMode.dark,
                    label: Text(l10n.themeDark),
                    icon: const Icon(Icons.dark_mode),
                  ),
                ],
                selected: {prefs.themeMode},
                onSelectionChanged: (s) => prefs.setThemeMode(s.first),
              ),
            ),
            const SizedBox(height: 8),
            _SectionHeader(l10n.analysisSection),
            ListTile(
              leading: const Icon(Icons.tune),
              title: Text(l10n.defaultAnalysisSettings),
              subtitle: Text(
                prefs.defaultAnalysisSettings == null
                    ? l10n.usingBuiltInDefaults
                    : l10n.customizedDefaults,
              ),
              onTap: () async {
                final next = await showAnalysisSettings(
                  context,
                  prefs.defaultAnalysisSettings ?? const AnalysisSettings(),
                );
                if (next != null) await prefs.setDefaultAnalysisSettings(next);
              },
            ),
            if (prefs.defaultAnalysisSettings != null)
              ListTile(
                leading: const Icon(Icons.restart_alt),
                title: Text(l10n.resetAnalysisDefaults),
                onTap: () => prefs.setDefaultAnalysisSettings(null),
              ),
            const SizedBox(height: 8),
            _SectionHeader(l10n.recordingSection),
            ListTile(
              leading: const Icon(Icons.speed),
              title: Text(l10n.recordingSampleRate),
              trailing: DropdownButton<int>(
                value: prefs.recordingOptions.sampleRate,
                items: [
                  for (final rate in RecordingOptions.allowedSampleRates)
                    DropdownMenuItem(value: rate, child: Text('$rate Hz')),
                ],
                onChanged: (v) => prefs.setRecordingOptions(
                  prefs.recordingOptions.copyWith(sampleRate: v),
                ),
              ),
            ),
            SwitchListTile(
              secondary: const Icon(Icons.auto_fix_high),
              title: Text(l10n.autoGain),
              subtitle: Text(l10n.recordingDspHint),
              value: prefs.recordingOptions.autoGain,
              onChanged: (v) => prefs.setRecordingOptions(
                prefs.recordingOptions.copyWith(autoGain: v),
              ),
            ),
            SwitchListTile(
              secondary: const Icon(Icons.hearing_disabled),
              title: Text(l10n.echoCancel),
              subtitle: Text(l10n.recordingDspHint),
              value: prefs.recordingOptions.echoCancel,
              onChanged: (v) => prefs.setRecordingOptions(
                prefs.recordingOptions.copyWith(echoCancel: v),
              ),
            ),
            SwitchListTile(
              secondary: const Icon(Icons.noise_aware),
              title: Text(l10n.noiseSuppress),
              subtitle: Text(l10n.recordingDspHint),
              value: prefs.recordingOptions.noiseSuppress,
              onChanged: (v) => prefs.setRecordingOptions(
                prefs.recordingOptions.copyWith(noiseSuppress: v),
              ),
            ),
            const SizedBox(height: 8),
            _SectionHeader(l10n.sheetTracks),
            _TrackAppearance(prefs: prefs),
            const Divider(),
            ListTile(
              leading: const Icon(Icons.memory),
              title: Text(l10n.coreVersion(rust_core.coreVersion())),
              dense: true,
            ),
            AboutListTile(
              icon: const Icon(Icons.info_outline),
              applicationName: l10n.appTitle,
              applicationVersion: l10n.aboutVersion,
              applicationLegalese: l10n.aboutLegalese,
              child: Text(l10n.aboutOpenphon),
            ),
          ],
        ),
      ),
    );
  }
}

/// Track appearance: preset picker, one swatch row per track, mark scale.
class _TrackAppearance extends StatelessWidget {
  const _TrackAppearance({required this.prefs});

  final AppPrefs prefs;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final vp = prefs.viewPrefs;
    final String? preset;
    if (vp == vp.withClassicPreset()) {
      preset = 'classic';
    } else if (vp == vp.withOkabeItoPreset()) {
      preset = 'okabe';
    } else if (vp == vp.withHighVisibilityPreset()) {
      preset = 'highvis';
    } else {
      preset = null;
    }
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SegmentedButton<String>(
            emptySelectionAllowed: true,
            segments: [
              ButtonSegment(value: 'classic', label: Text(l10n.presetClassic)),
              ButtonSegment(value: 'okabe', label: Text(l10n.presetOkabeIto)),
              ButtonSegment(
                value: 'highvis',
                label: Text(l10n.presetHighVisibility),
              ),
            ],
            selected: {?preset},
            onSelectionChanged: (s) {
              if (s.isEmpty) return;
              prefs.setViewPrefs(switch (s.first) {
                'classic' => vp.withClassicPreset(),
                'okabe' => vp.withOkabeItoPreset(),
                _ => vp.withHighVisibilityPreset(),
              });
            },
          ),
          const SizedBox(height: 12),
          _swatchRow(
            context,
            l10n.sheetPitch,
            vp.pitchColor,
            (c) => prefs.setViewPrefs(vp.copyWith(pitchColor: c)),
          ),
          _swatchRow(
            context,
            l10n.sheetFormants,
            vp.formantColor,
            (c) => prefs.setViewPrefs(vp.copyWith(formantColor: c)),
          ),
          _swatchRow(
            context,
            l10n.sheetIntensity,
            vp.intensityColor,
            (c) => prefs.setViewPrefs(vp.copyWith(intensityColor: c)),
          ),
          const SizedBox(height: 4),
          Row(
            children: [
              Text(l10n.markSize),
              Expanded(
                child: Slider(
                  value: vp.markScale.clamp(0.75, 2.0),
                  min: 0.75,
                  max: 2.0,
                  divisions: 5,
                  label: '${vp.markScale}×',
                  onChanged: (v) =>
                      prefs.setViewPrefs(vp.copyWith(markScale: v)),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _swatchRow(
    BuildContext context,
    String label,
    int current,
    void Function(int) onPick,
  ) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: [
          SizedBox(width: 80, child: Text(label)),
          Wrap(
            spacing: 8,
            children: [
              for (final argb in ViewPrefs.swatches)
                Semantics(
                  label: AppLocalizations.of(context)!.colorOptionSemantics(
                    label,
                  ),
                  button: true,
                  child: InkWell(
                    customBorder: const CircleBorder(),
                    onTap: () => onPick(argb),
                    child: Container(
                      width: 24,
                      height: 24,
                      decoration: BoxDecoration(
                        color: Color(argb),
                        shape: BoxShape.circle,
                        border: argb == current
                            ? Border.all(
                                width: 3,
                                color: Theme.of(context).colorScheme.onSurface,
                              )
                            : Border.all(
                                color: Theme.of(
                                  context,
                                ).colorScheme.outlineVariant,
                              ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader(this.title);

  final String title;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
      child: Text(
        title,
        style: Theme.of(context).textTheme.titleSmall?.copyWith(
          color: Theme.of(context).colorScheme.primary,
        ),
      ),
    );
  }
}
