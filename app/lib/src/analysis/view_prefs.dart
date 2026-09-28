import 'dart:ui' show Color;

/// Display preferences for the analysis view: which layers are painted and
/// how the track marks look. App-wide (persisted via AppPrefs), deliberately
/// separate from [AnalysisSettings] — these change what is *drawn*, never
/// what is computed, so hidden tracks keep feeding the readout panel and
/// toggling back is instant.
class ViewPrefs {
  const ViewPrefs({
    this.showSpectrogram = true,
    this.showPitch = true,
    this.showFormants = true,
    this.showIntensity = true,
    this.pitchColor = defaultPitchColor,
    this.formantColor = defaultFormantColor,
    this.intensityColor = defaultIntensityColor,
    this.markScale = 1.0,
  });

  /// The classic colors the app shipped with.
  static const int defaultPitchColor = 0xFF1565C0;
  static const int defaultFormantColor = 0xFFC62828;
  static const int defaultIntensityColor = 0xFF9E9D24;

  /// Okabe-Ito colorblind-safe palette values used by the presets.
  static const int okabeBlue = 0xFF0072B2;
  static const int okabeVermillion = 0xFFD55E00;
  static const int okabeOrange = 0xFFE69F00;

  /// Swatches offered per track in settings: the classic trio plus
  /// Okabe-Ito's most distinguishable values on a grayscale spectrogram.
  static const List<int> swatches = [
    defaultPitchColor,
    defaultFormantColor,
    defaultIntensityColor,
    okabeBlue,
    okabeVermillion,
    okabeOrange,
    0xFF009E73, // Okabe-Ito bluish green
    0xFFCC79A7, // Okabe-Ito reddish purple
  ];

  /// Appearance presets; visibility flags are left untouched.
  ViewPrefs withClassicPreset() => copyWith(
    pitchColor: defaultPitchColor,
    formantColor: defaultFormantColor,
    intensityColor: defaultIntensityColor,
    markScale: 1.0,
  );

  ViewPrefs withOkabeItoPreset() => copyWith(
    pitchColor: okabeBlue,
    formantColor: okabeVermillion,
    intensityColor: okabeOrange,
    markScale: 1.0,
  );

  ViewPrefs withHighVisibilityPreset() =>
      withOkabeItoPreset().copyWith(markScale: 1.5);

  final bool showSpectrogram;
  final bool showPitch;
  final bool showFormants;
  final bool showIntensity;

  /// ARGB values (ints so the JSON round-trip stays trivial).
  final int pitchColor;
  final int formantColor;
  final int intensityColor;

  /// Multiplies stroke widths and dot radii; 1.0 = classic look.
  final double markScale;

  Color get pitch => Color(pitchColor);
  Color get formant => Color(formantColor);
  Color get intensity => Color(intensityColor);

  ViewPrefs copyWith({
    bool? showSpectrogram,
    bool? showPitch,
    bool? showFormants,
    bool? showIntensity,
    int? pitchColor,
    int? formantColor,
    int? intensityColor,
    double? markScale,
  }) {
    return ViewPrefs(
      showSpectrogram: showSpectrogram ?? this.showSpectrogram,
      showPitch: showPitch ?? this.showPitch,
      showFormants: showFormants ?? this.showFormants,
      showIntensity: showIntensity ?? this.showIntensity,
      pitchColor: pitchColor ?? this.pitchColor,
      formantColor: formantColor ?? this.formantColor,
      intensityColor: intensityColor ?? this.intensityColor,
      markScale: markScale ?? this.markScale,
    );
  }

  Map<String, Object> toMap() => {
    'showSpectrogram': showSpectrogram,
    'showPitch': showPitch,
    'showFormants': showFormants,
    'showIntensity': showIntensity,
    'pitchColor': pitchColor,
    'formantColor': formantColor,
    'intensityColor': intensityColor,
    'markScale': markScale,
  };

  /// Tolerant of missing or wrongly typed keys: anything unreadable falls
  /// back to its default, so prefs from other versions never break loading.
  factory ViewPrefs.fromMap(Map<String, dynamic> map) {
    bool b(String key, bool fallback) =>
        map[key] is bool ? map[key] as bool : fallback;
    int i(String key, int fallback) =>
        map[key] is int ? map[key] as int : fallback;
    const d = ViewPrefs();
    final scale = map['markScale'];
    return ViewPrefs(
      showSpectrogram: b('showSpectrogram', d.showSpectrogram),
      showPitch: b('showPitch', d.showPitch),
      showFormants: b('showFormants', d.showFormants),
      showIntensity: b('showIntensity', d.showIntensity),
      pitchColor: i('pitchColor', d.pitchColor),
      formantColor: i('formantColor', d.formantColor),
      intensityColor: i('intensityColor', d.intensityColor),
      markScale: scale is num
          ? scale.toDouble().clamp(0.5, 3.0)
          : d.markScale,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is ViewPrefs &&
      other.showSpectrogram == showSpectrogram &&
      other.showPitch == showPitch &&
      other.showFormants == showFormants &&
      other.showIntensity == showIntensity &&
      other.pitchColor == pitchColor &&
      other.formantColor == formantColor &&
      other.intensityColor == intensityColor &&
      other.markScale == markScale;

  @override
  int get hashCode => Object.hash(
    showSpectrogram,
    showPitch,
    showFormants,
    showIntensity,
    pitchColor,
    formantColor,
    intensityColor,
    markScale,
  );
}
