import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import '../data/database.dart';
import 'analysis_settings.dart';

// Both native bridge formant entry points inherit these values from
// core/src/formant.rs::FormantParams::default(). They are not spectrogram
// parameters. The metadata contract records them explicitly for reproduction.
const _formantWindowS = 0.025;
const _formantPreEmphasisHz = 50.0;
const _formantMaxBandwidthHz = 400.0;

Map<String, Object?> _effectiveFormantAnalysis(AnalysisSettings settings) => {
  'method': 'burg_lpc',
  'algorithm_revision': 4,
  'parameters': {
    'time_step_s': settings.trackTimeStepS,
    'max_formants': settings.maxFormants,
    'ceiling_hz': settings.formantCeilingHz,
    'window_s': _formantWindowS,
    'pre_emphasis_hz': _formantPreEmphasisHz,
    'max_bandwidth_hz': _formantMaxBandwidthHz,
  },
  'working_sample_rate_hz': 2.0 * settings.formantCeilingHz,
  'physical_window_s': 2.0 * _formantWindowS,
  'lpc_order': 2 * settings.maxFormants,
  'input_preprocessing': {
    'dc_removal': 'subtract_signal_mean_before_resampling',
    'centering_arithmetic': 'subtract_first_sample_then_subtract_residual_mean',
  },
  'resampling': {
    'method': 'hann_windowed_sinc',
    'base_half_width_samples': 32,
    'cutoff_guard': 0.95,
    'rate_ratio': 'working_sample_rate_hz / input_sample_rate_hz',
    'half_width_input_samples': 'ceil(32 / min(1, rate_ratio))',
    'cutoff_relative_to_input_nyquist': '0.95 * min(1, rate_ratio)',
    'kernel_normalization': 'unit_sum_full_kernel_per_output_phase',
    'interior_accumulation': 'local_anchor_plus_weighted_sample_differences',
    'boundary_accumulation': 'weighted_samples_with_zero_extension',
    'boundary_extension': 'zero',
    'equal_sample_rates': 'bypass',
  },
  'frame_preprocessing': {
    'dc_removal': 'subtract_frame_mean_before_gaussian_window',
    'centering_arithmetic': 'subtract_first_sample_then_subtract_residual_mean',
    'window': 'gaussian',
  },
  'root_solver': {
    'method': 'durand_kerner',
    'maximum_iterations': 200,
    'relative_step_tolerance': 1e-12,
    'relative_residual_tolerance': '64 * lpc_order * f64_epsilon',
    'relative_conjugate_tolerance': 8e-12,
    'coefficient_backward_error_tolerance':
        '64 * lpc_order * lpc_order * f64_epsilon',
    'validation':
        'Finite converged complete root set, residuals, unique conjugate pairs, '
        'and polynomial coefficient reconstruction.',
    'failure_policy': 'Reject the complete root set; every formant is missing.',
    'accuracy_limit':
        'Numerical acceptance does not bound individual root error.',
  },
  'candidate_selection': {
    'frequency_lower_bound_hz': 50.0,
    'frequency_upper_margin_hz': 50.0,
    'frequency_bounds': 'exclusive',
    'bandwidth_upper_bound': 'inclusive',
    'outside_unit_circle_roots':
        'reflect_to_reciprocal_magnitude_preserving_angle',
    'bandwidth_definition':
        'working_sample_rate_hz / pi * abs(ln(root_magnitude))',
    'slot_assignment': 'ascending_frequency_after_filtering',
    'removed_candidates':
        'Removed before numbering; higher survivors shift down.',
    'missing_slots': 'Trailing slots after the last surviving candidate.',
  },
};

/// Resolve exactly the settings used by a recording; corrupt stored settings
/// must be reported as an exclusion instead of silently changing the recipe.
AnalysisSettings settingsForRecording(
  Recording recording,
  AnalysisSettings fallback,
) {
  final stored = recording.analysisSettingsJson;
  final settings = stored == null
      ? fallback
      : AnalysisSettings.fromJson(stored, strict: true);
  settings.validate();
  return settings;
}

/// Metadata for both successful measurements and explicitly excluded files.
/// Source errors remain in the report even when a missing WAV caused the
/// exclusion; metadata collection never hides the original outcome.
Future<Map<String, Object?>> recordingMeasurementProvenance({
  required Recording recording,
  required String wavPath,
  required AnalysisSettings settings,
  String? textGridPath,
  String? pitchEditsPath,
  required String status,
  String? detail,
  int? rows,
}) async => {
  'recording_id': recording.id,
  'file': recording.relativePath,
  'display_name': recording.name,
  'status': status,
  'detail': ?detail,
  'rows': ?rows,
  'settings_origin': recording.analysisSettingsJson == null
      ? 'application_defaults'
      : 'recording',
  'analysis_settings': settings.toMap(),
  'formant_analysis': _effectiveFormantAnalysis(settings),
  'sources': {
    'wav': await _sourceIdentity(wavPath),
    if (textGridPath != null) 'textgrid': await _sourceIdentity(textGridPath),
    if (pitchEditsPath != null)
      'pitch_edits': await _sourceIdentity(pitchEditsPath),
  },
};

Future<Map<String, Object?>> _sourceIdentity(String path) async {
  final identity = <String, Object?>{'file': p.basename(path)};
  try {
    final digest = await sha256.bind(File(path).openRead()).single;
    identity['sha256'] = digest.toString();
  } catch (error) {
    identity['error'] = error.toString();
  }
  return identity;
}

/// Versioned recipe metadata accompanies the CSV, whose empty cells cannot
/// by themselves distinguish an unvoiced interval from a track with no frames.
String measurementsMetadataJson({
  required String softwareVersion,
  required String tierName,
  required List<Map<String, Object?>> recordings,
}) => const JsonEncoder.withIndent('  ').convert({
  'schema_version': 2,
  'software': {
    'name': 'openphon',
    'version': softwareVersion,
    'version_source': 'bundled_pubspec',
  },
  'tier': tierName,
  'recipe': {
    'revision': 2,
    'interval_bounds': '[tmin_s, tmax_s)',
    'f0_summary': 'Finite positive F0 samples within the interval.',
    'median': 'Mean of the two middle samples when their count is even.',
    'formants': 'Nearest frame to the midpoint within the interval.',
    'intensity': 'Arithmetic mean of finite intensity samples in dB.',
    'missing_values': 'Empty CSV cells.',
    'coverage_columns': {
      'f0_frames': 'Finite F0 samples, including unvoiced zero samples.',
      'voiced_f0_frames': 'Finite positive F0 samples.',
      'intensity_frames': 'Finite intensity samples.',
    },
  },
  'recordings': recordings,
});

/// Read the source version shipped with this build. This does not claim to
/// identify platform build-name/build-number overrides applied during signing.
Future<String> loadAppVersion({AssetBundle? bundle}) async {
  final manifest = await (bundle ?? rootBundle).loadString('pubspec.yaml');
  final match = RegExp(
    r'^version:\s*([^\s#]+)',
    multiLine: true,
  ).firstMatch(manifest);
  if (match == null) {
    throw const FormatException('Bundled pubspec.yaml has no version.');
  }
  return match.group(1)!.replaceAll(RegExp(r'''^["']|["']$'''), '');
}
