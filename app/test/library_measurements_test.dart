import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openphon/src/analysis/analysis_settings.dart';
import 'package:openphon/src/analysis/library_measurements.dart';
import 'package:openphon/src/data/database.dart';

Recording recording({String? settings}) => Recording(
  id: 7,
  name: 'Take one',
  relativePath: 'recordings/take.wav',
  createdAt: DateTime(2026, 10, 14),
  sampleRate: 16000,
  channels: 1,
  analysisSettingsJson: settings,
);

class ManifestBundle extends CachingAssetBundle {
  ManifestBundle(this.manifest);

  final String manifest;

  @override
  Future<ByteData> load(String key) async {
    expect(key, 'pubspec.yaml');
    return ByteData.sublistView(Uint8List.fromList(utf8.encode(manifest)));
  }
}

void main() {
  test('saved recording settings override current application defaults', () {
    const saved = AnalysisSettings(pitchFloorHz: 100, formantCeilingHz: 5000);
    const fallback = AnalysisSettings(pitchFloorHz: 150);
    expect(
      settingsForRecording(recording(settings: saved.toJson()), fallback),
      saved,
    );
    expect(settingsForRecording(recording(), fallback), fallback);
  });

  test('invalid saved parameters cannot silently select defaults', () {
    for (final stored in ['not json', '[]', '{"pitchFloorHz": -1}']) {
      expect(
        () => settingsForRecording(
          recording(settings: stored),
          const AnalysisSettings(),
        ),
        throwsFormatException,
      );
    }
  });

  test('provenance identifies exact audio and annotation bytes', () async {
    final dir = await Directory.systemTemp.createTemp('openphon-provenance-');
    addTearDown(() => dir.delete(recursive: true));
    final wav = await File('${dir.path}/take.wav').writeAsString('abc');
    final grid = await File('${dir.path}/take.TextGrid').writeAsString('');
    final edits = await File(
      '${dir.path}/take.pitchedits.csv',
    ).writeAsString('abc');
    const settings = AnalysisSettings(pitchFloorHz: 100);
    final result = await recordingMeasurementProvenance(
      recording: recording(settings: settings.toJson()),
      wavPath: wav.path,
      textGridPath: grid.path,
      pitchEditsPath: edits.path,
      settings: settings,
      status: 'measured',
      rows: 2,
    );
    expect(result['settings_origin'], 'recording');
    expect(result['analysis_settings'], settings.toMap());
    expect(result['rows'], 2);
    final sources = result['sources'] as Map<String, Object?>;
    expect(
      (sources['wav'] as Map)['sha256'],
      'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad',
    );
    expect(
      (sources['textgrid'] as Map)['sha256'],
      'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855',
    );
    expect(
      (sources['pitch_edits'] as Map)['sha256'],
      (sources['wav'] as Map)['sha256'],
    );
    await wav.writeAsString('abcd');
    final changed = await recordingMeasurementProvenance(
      recording: recording(),
      wavPath: wav.path,
      settings: settings,
      status: 'measured',
    );
    expect(
      ((changed['sources'] as Map)['wav'] as Map)['sha256'],
      isNot((sources['wav'] as Map)['sha256']),
    );
  });

  test('unreadable sources remain explicit exclusions in metadata', () async {
    final dir = await Directory.systemTemp.createTemp(
      'openphon-missing-source-',
    );
    addTearDown(() => dir.delete(recursive: true));
    final result = await recordingMeasurementProvenance(
      recording: recording(),
      wavPath: '${dir.path}/missing.wav',
      settings: const AnalysisSettings(),
      status: 'error',
      detail: 'Audio could not be loaded.',
    );
    expect(result['status'], 'error');
    expect(result['detail'], 'Audio could not be loaded.');
    final wav = (result['sources'] as Map)['wav'] as Map;
    expect(wav['error'], isNotEmpty);
    expect(wav.containsKey('sha256'), isFalse);
    final metadata =
        jsonDecode(
              measurementsMetadataJson(
                softwareVersion: '0.1.0+4',
                tierName: 'phones',
                recordings: [result],
              ),
            )
            as Map;
    expect(metadata['schema_version'], 2);
    expect(metadata['software']['version'], '0.1.0+4');
    expect(metadata['recordings'][0]['status'], 'error');
    expect(metadata['recipe']['missing_values'], 'Empty CSV cells.');
  });

  test('source version is read from the bundled manifest', () async {
    expect(
      await loadAppVersion(
        bundle: ManifestBundle('name: openphon\nversion: 2.3.4+5\n'),
      ),
      '2.3.4+5',
    );
    await expectLater(
      loadAppVersion(bundle: ManifestBundle('name: openphon\n')),
      throwsFormatException,
    );
  });

  test(
    'formant provenance resolves native defaults independently of spectrogram settings',
    () async {
      final dir = await Directory.systemTemp.createTemp(
        'openphon-formant-recipe-',
      );
      addTearDown(() => dir.delete(recursive: true));
      final wav = await File('${dir.path}/take.wav').writeAsString('audio');
      const settings = AnalysisSettings(
        maxFormants: 4,
        formantCeilingHz: 5000,
        trackTimeStepS: 0.02,
        spectrogramWindowS: 0.007,
        spectrogramPreEmphasisHz: 100,
      );
      final result = await recordingMeasurementProvenance(
        recording: recording(settings: settings.toJson()),
        wavPath: wav.path,
        settings: settings,
        status: 'measured',
      );
      final formants = result['formant_analysis'] as Map;
      final parameters = formants['parameters'] as Map;
      expect(parameters['time_step_s'], 0.02);
      expect(parameters['max_formants'], 4);
      expect(parameters['ceiling_hz'], 5000);
      expect(parameters['window_s'], isNot(settings.spectrogramWindowS));
      expect(
        parameters['pre_emphasis_hz'],
        isNot(settings.spectrogramPreEmphasisHz),
      );
      expect(formants['working_sample_rate_hz'], 10000);
      expect(formants['physical_window_s'], 0.05);
      expect(formants['lpc_order'], 8);

      // This is the exported scientific recipe contract. Spectrogram
      // settings above deliberately differ from the fixed formant settings.
      expect(parameters, {
        'time_step_s': 0.02,
        'max_formants': 4,
        'ceiling_hz': 5000,
        'window_s': 0.025,
        'pre_emphasis_hz': 50.0,
        'max_bandwidth_hz': 400.0,
      });
      expect(formants['algorithm_revision'], 4);
      expect(formants['root_solver']['maximum_iterations'], 200);
      expect(formants['root_solver']['relative_step_tolerance'], 1e-12);
      expect(
        formants['root_solver']['failure_policy'],
        'Reject the complete root set; every formant is missing.',
      );
      expect(formants['input_preprocessing'], {
        'dc_removal': 'subtract_signal_mean_before_resampling',
        'centering_arithmetic':
            'subtract_first_sample_then_subtract_residual_mean',
      });
      final resampling = formants['resampling'] as Map;
      expect(resampling['method'], 'hann_windowed_sinc');
      expect(resampling['base_half_width_samples'], 32);
      expect(resampling['cutoff_guard'], 0.95);
      expect(
        resampling['half_width_input_samples'],
        'ceil(32 / min(1, rate_ratio))',
      );
      expect(
        resampling['cutoff_relative_to_input_nyquist'],
        '0.95 * min(1, rate_ratio)',
      );
      expect(
        resampling['kernel_normalization'],
        'unit_sum_full_kernel_per_output_phase',
      );
      expect(resampling['boundary_extension'], 'zero');
      expect(
        resampling['interior_accumulation'],
        'local_anchor_plus_weighted_sample_differences',
      );
      expect(
        resampling['boundary_accumulation'],
        'weighted_samples_with_zero_extension',
      );
      expect(resampling['equal_sample_rates'], 'bypass');
      expect(
        formants['frame_preprocessing']['dc_removal'],
        'subtract_frame_mean_before_gaussian_window',
      );
      expect(
        formants['frame_preprocessing']['centering_arithmetic'],
        'subtract_first_sample_then_subtract_residual_mean',
      );
      final selection = formants['candidate_selection'] as Map;
      expect(
        selection['slot_assignment'],
        'ascending_frequency_after_filtering',
      );
      expect(selection['frequency_lower_bound_hz'], 50);
      expect(selection['frequency_upper_margin_hz'], 50);
      expect(selection['frequency_bounds'], 'exclusive');
      expect(selection['bandwidth_upper_bound'], 'inclusive');
      expect(
        selection['outside_unit_circle_roots'],
        'reflect_to_reciprocal_magnitude_preserving_angle',
      );
      expect(
        selection['bandwidth_definition'],
        'working_sample_rate_hz / pi * abs(ln(root_magnitude))',
      );
      expect(
        selection['removed_candidates'],
        contains('higher survivors shift down'),
      );

      final exported =
          jsonDecode(
                measurementsMetadataJson(
                  softwareVersion: '0.1.0+4',
                  tierName: 'phones',
                  recordings: [result],
                ),
              )
              as Map;
      expect(exported['recipe']['revision'], 2);
      expect(exported['recordings'][0]['formant_analysis'], formants);
    },
  );
}
