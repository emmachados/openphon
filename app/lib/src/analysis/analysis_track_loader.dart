import '../rust/api/core.dart' as rust;
import 'analysis_settings.dart';

/// Source of whole-recording tracks. A request receives an immutable settings
/// snapshot so a subsequent settings change cannot alter an in-flight request.
abstract interface class AnalysisTrackLoader {
  Future<rust.F0CandidatesData> pitch(AnalysisSettings settings);
  Future<rust.IntensityTrackData> intensity(AnalysisSettings settings);
  Future<rust.FormantTrackData> formants(AnalysisSettings settings);
}

class SoundAnalysisTrackLoader implements AnalysisTrackLoader {
  const SoundAnalysisTrackLoader(this.sound);

  final rust.Sound sound;

  @override
  Future<rust.F0CandidatesData> pitch(AnalysisSettings settings) =>
      sound.f0Candidates(
        timeStepS: settings.trackTimeStepS,
        f0MinHz: settings.pitchFloorHz,
        f0MaxHz: settings.pitchCeilingHz,
      );

  @override
  Future<rust.IntensityTrackData> intensity(AnalysisSettings settings) =>
      sound.intensity(
        timeStepS: settings.trackTimeStepS,
        minPitchHz: settings.intensityMinPitchHz,
      );

  @override
  Future<rust.FormantTrackData> formants(AnalysisSettings settings) =>
      sound.formants(
        timeStepS: settings.trackTimeStepS,
        maxFormants: settings.maxFormants,
        ceilingHz: settings.formantCeilingHz,
      );
}
