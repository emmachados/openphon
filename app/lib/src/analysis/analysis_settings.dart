import 'dart:convert';

/// Per-recording analysis parameters. Defaults match the Rust core's
/// defaults (which the validation harness pins against Praat); only
/// [dynamicRangeDb] is display-only.
class AnalysisSettings {
  const AnalysisSettings({
    this.spectrogramWindowS = 0.005,
    this.spectrogramMinTimeStepS = 0.002,
    this.spectrogramMaxFreqHz = 5000,
    this.spectrogramPreEmphasisHz = 0,
    this.dynamicRangeDb = 70,
    this.pitchFloorHz = 75,
    this.pitchCeilingHz = 600,
    this.maxFormants = 5,
    this.formantCeilingHz = 5500,
    this.intensityMinPitchHz = 100,
    this.trackTimeStepS = 0.01,
  });

  final double spectrogramWindowS;
  final double spectrogramMinTimeStepS;
  final double spectrogramMaxFreqHz;
  final double spectrogramPreEmphasisHz;
  final double dynamicRangeDb;
  final double pitchFloorHz;
  final double pitchCeilingHz;
  final int maxFormants;
  final double formantCeilingHz;
  final double intensityMinPitchHz;
  final double trackTimeStepS;

  AnalysisSettings copyWith({
    double? spectrogramWindowS,
    double? spectrogramMinTimeStepS,
    double? spectrogramMaxFreqHz,
    double? spectrogramPreEmphasisHz,
    double? dynamicRangeDb,
    double? pitchFloorHz,
    double? pitchCeilingHz,
    int? maxFormants,
    double? formantCeilingHz,
    double? intensityMinPitchHz,
    double? trackTimeStepS,
  }) {
    return AnalysisSettings(
      spectrogramWindowS: spectrogramWindowS ?? this.spectrogramWindowS,
      spectrogramMinTimeStepS:
          spectrogramMinTimeStepS ?? this.spectrogramMinTimeStepS,
      spectrogramMaxFreqHz: spectrogramMaxFreqHz ?? this.spectrogramMaxFreqHz,
      spectrogramPreEmphasisHz:
          spectrogramPreEmphasisHz ?? this.spectrogramPreEmphasisHz,
      dynamicRangeDb: dynamicRangeDb ?? this.dynamicRangeDb,
      pitchFloorHz: pitchFloorHz ?? this.pitchFloorHz,
      pitchCeilingHz: pitchCeilingHz ?? this.pitchCeilingHz,
      maxFormants: maxFormants ?? this.maxFormants,
      formantCeilingHz: formantCeilingHz ?? this.formantCeilingHz,
      intensityMinPitchHz: intensityMinPitchHz ?? this.intensityMinPitchHz,
      trackTimeStepS: trackTimeStepS ?? this.trackTimeStepS,
    );
  }

  /// True when a change between the two requires re-rendering the
  /// spectrogram image (vs. only recomputing tracks).
  bool spectrogramDiffers(AnalysisSettings other) =>
      spectrogramWindowS != other.spectrogramWindowS ||
      spectrogramMinTimeStepS != other.spectrogramMinTimeStepS ||
      spectrogramMaxFreqHz != other.spectrogramMaxFreqHz ||
      spectrogramPreEmphasisHz != other.spectrogramPreEmphasisHz ||
      dynamicRangeDb != other.dynamicRangeDb;

  bool pitchDiffers(AnalysisSettings other) =>
      pitchFloorHz != other.pitchFloorHz ||
      pitchCeilingHz != other.pitchCeilingHz ||
      trackTimeStepS != other.trackTimeStepS;

  bool formantsDiffer(AnalysisSettings other) =>
      maxFormants != other.maxFormants ||
      formantCeilingHz != other.formantCeilingHz ||
      trackTimeStepS != other.trackTimeStepS;

  bool intensityDiffers(AnalysisSettings other) =>
      intensityMinPitchHz != other.intensityMinPitchHz ||
      trackTimeStepS != other.trackTimeStepS;

  Map<String, Object?> toMap() => {
    'spectrogramWindowS': spectrogramWindowS,
    'spectrogramMinTimeStepS': spectrogramMinTimeStepS,
    'spectrogramMaxFreqHz': spectrogramMaxFreqHz,
    'spectrogramPreEmphasisHz': spectrogramPreEmphasisHz,
    'dynamicRangeDb': dynamicRangeDb,
    'pitchFloorHz': pitchFloorHz,
    'pitchCeilingHz': pitchCeilingHz,
    'maxFormants': maxFormants,
    'formantCeilingHz': formantCeilingHz,
    'intensityMinPitchHz': intensityMinPitchHz,
    'trackTimeStepS': trackTimeStepS,
  };

  String toJson() => jsonEncode(toMap());

  /// Unknown fields are ignored and missing fields fall back to defaults,
  /// so stored settings survive schema evolution in both directions.
  factory AnalysisSettings.fromJson(String json) {
    Map<String, Object?> map;
    try {
      map = (jsonDecode(json) as Map).cast<String, Object?>();
    } catch (_) {
      return const AnalysisSettings();
    }
    const d = AnalysisSettings();
    double dbl(String key, double fallback) {
      final v = map[key];
      return v is num ? v.toDouble() : fallback;
    }

    final formants = map['maxFormants'];
    return AnalysisSettings(
      spectrogramWindowS: dbl('spectrogramWindowS', d.spectrogramWindowS),
      spectrogramMinTimeStepS: dbl(
        'spectrogramMinTimeStepS',
        d.spectrogramMinTimeStepS,
      ),
      spectrogramMaxFreqHz: dbl('spectrogramMaxFreqHz', d.spectrogramMaxFreqHz),
      spectrogramPreEmphasisHz: dbl(
        'spectrogramPreEmphasisHz',
        d.spectrogramPreEmphasisHz,
      ),
      dynamicRangeDb: dbl('dynamicRangeDb', d.dynamicRangeDb),
      pitchFloorHz: dbl('pitchFloorHz', d.pitchFloorHz),
      pitchCeilingHz: dbl('pitchCeilingHz', d.pitchCeilingHz),
      maxFormants: formants is num ? formants.toInt() : d.maxFormants,
      formantCeilingHz: dbl('formantCeilingHz', d.formantCeilingHz),
      intensityMinPitchHz: dbl('intensityMinPitchHz', d.intensityMinPitchHz),
      trackTimeStepS: dbl('trackTimeStepS', d.trackTimeStepS),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is AnalysisSettings &&
      !spectrogramDiffers(other) &&
      !pitchDiffers(other) &&
      !formantsDiffer(other) &&
      !intensityDiffers(other);

  @override
  int get hashCode => Object.hashAll(toMap().values);
}
