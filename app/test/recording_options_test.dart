import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:openphon/src/audio/recorder_service.dart';
import 'package:openphon/src/data/app_prefs.dart';
import 'package:record/record.dart' show AudioEncoder;

void main() {
  test('options map onto RecordConfig; DSP switches default off', () {
    const defaults = RecordingOptions();
    final config = defaults.toConfig();
    expect(config.encoder, AudioEncoder.wav);
    expect(config.sampleRate, kSampleRate);
    expect(config.numChannels, kChannels);
    expect(config.autoGain, isFalse);
    expect(config.echoCancel, isFalse);
    expect(config.noiseSuppress, isFalse);

    final custom = const RecordingOptions(
      sampleRate: 16000,
      noiseSuppress: true,
    ).toConfig();
    expect(custom.sampleRate, 16000);
    expect(custom.noiseSuppress, isTrue);
  });

  test('fromMap rejects a rate outside the allowed list', () {
    expect(
      RecordingOptions.fromMap({'sampleRate': 12345}).sampleRate,
      kSampleRate,
    );
    expect(RecordingOptions.fromMap({'sampleRate': 48000}).sampleRate, 48000);
    expect(RecordingOptions.fromMap({'autoGain': 'yes'}).autoGain, isFalse);
  });

  test('AppPrefs persists recording options', () async {
    final dir = await Directory.systemTemp.createTemp('openphon_rec_');
    addTearDown(() => dir.delete(recursive: true));
    final file = File('${dir.path}/prefs.json');

    final prefs = AppPrefs(fileOverride: file);
    await prefs.setRecordingOptions(
      const RecordingOptions(sampleRate: 22050, autoGain: true),
    );

    final reloaded = AppPrefs(fileOverride: file);
    await reloaded.load();
    expect(reloaded.recordingOptions.sampleRate, 22050);
    expect(reloaded.recordingOptions.autoGain, isTrue);
    expect(reloaded.recordingOptions.noiseSuppress, isFalse);
  });
}
