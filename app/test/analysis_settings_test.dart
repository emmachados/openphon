import 'package:flutter_test/flutter_test.dart';
import 'package:openphon/src/analysis/analysis_settings.dart';

void main() {
  test('JSON round trip preserves every field', () {
    const s = AnalysisSettings(
      spectrogramWindowS: 0.03,
      spectrogramMinTimeStepS: 0.004,
      spectrogramMaxFreqHz: 8000,
      spectrogramPreEmphasisHz: 50,
      dynamicRangeDb: 60,
      pitchFloorHz: 100,
      pitchCeilingHz: 500,
      maxFormants: 4,
      formantCeilingHz: 5000,
      intensityMinPitchHz: 80,
      trackTimeStepS: 0.005,
    );
    final back = AnalysisSettings.fromJson(s.toJson());
    expect(back, s);
    expect(back.spectrogramDiffers(s), isFalse);
    expect(back.maxFormants, 4);
    expect(back.dynamicRangeDb, 60);
  });

  test('missing and unknown fields fall back to defaults', () {
    final s = AnalysisSettings.fromJson('{"pitchFloorHz": 60, "future": 1}');
    expect(s.pitchFloorHz, 60);
    expect(s.pitchCeilingHz, const AnalysisSettings().pitchCeilingHz);
  });

  test('corrupt JSON yields defaults', () {
    expect(AnalysisSettings.fromJson('not json'), const AnalysisSettings());
  });

  test('strict parsing rejects unsafe numerical settings', () {
    for (final json in [
      '{"maxFormants": 1e400}',
      '{"maxFormants": 4.5}',
      '{"pitchFloorHz": 500, "pitchCeilingHz": 100}',
      '{"trackTimeStepS": 0}',
      '{"pitchFloorHz": "100"}',
    ]) {
      expect(
        () => AnalysisSettings.fromJson(json, strict: true),
        throwsFormatException,
        reason: json,
      );
    }
    expect(
      AnalysisSettings.fromJson('{"maxFormants": 1e400}'),
      const AnalysisSettings(),
    );
  });

  test('differs helpers partition the fields', () {
    const base = AnalysisSettings();
    final sg = base.copyWith(dynamicRangeDb: 50);
    expect(sg.spectrogramDiffers(base), isTrue);
    expect(sg.pitchDiffers(base), isFalse);
    final pitch = base.copyWith(pitchCeilingHz: 400);
    expect(pitch.pitchDiffers(base), isTrue);
    expect(pitch.spectrogramDiffers(base), isFalse);
    final formants = base.copyWith(formantCeilingHz: 5000);
    expect(formants.formantsDiffer(base), isTrue);
    expect(formants.intensityDiffers(base), isFalse);
    // trackTimeStepS affects all three track families.
    final step = base.copyWith(trackTimeStepS: 0.02);
    expect(step.pitchDiffers(base), isTrue);
    expect(step.formantsDiffer(base), isTrue);
    expect(step.intensityDiffers(base), isTrue);
  });
}
