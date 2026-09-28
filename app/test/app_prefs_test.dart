import 'dart:io';

import 'package:flutter/material.dart' show ThemeMode;
import 'package:flutter_test/flutter_test.dart';
import 'package:openphon/src/analysis/analysis_controller.dart';
import 'package:openphon/src/analysis/analysis_settings.dart';
import 'package:openphon/src/data/app_prefs.dart';
import 'package:openphon/src/data/database.dart';
import 'package:path/path.dart' as p;

Future<File> _tempPrefs() async {
  final dir = await Directory.systemTemp.createTemp('openphon_prefs');
  addTearDown(() => dir.delete(recursive: true));
  return File(p.join(dir.path, 'prefs.json'));
}

void main() {
  test('prefs round-trip theme and analysis defaults through the file', () async {
    final file = await _tempPrefs();
    final prefs = AppPrefs(fileOverride: file);
    await prefs.setThemeMode(ThemeMode.dark);
    await prefs.setDefaultAnalysisSettings(
      const AnalysisSettings().copyWith(pitchCeilingHz: 400),
    );

    final reloaded = AppPrefs(fileOverride: file);
    await reloaded.load();
    expect(reloaded.themeMode, ThemeMode.dark);
    expect(reloaded.defaultAnalysisSettings!.pitchCeilingHz, 400);

    await reloaded.setDefaultAnalysisSettings(null);
    final again = AppPrefs(fileOverride: file);
    await again.load();
    expect(again.defaultAnalysisSettings, isNull);
    expect(again.themeMode, ThemeMode.dark);
  });

  test('missing or corrupt prefs file leaves defaults', () async {
    final file = await _tempPrefs();
    final prefs = AppPrefs(fileOverride: file);
    await prefs.load();
    expect(prefs.themeMode, ThemeMode.system);

    await file.writeAsString('{corrupt');
    await prefs.load();
    expect(prefs.themeMode, ThemeMode.system);
    expect(prefs.defaultAnalysisSettings, isNull);
  });

  test('controller uses app defaults only when the recording has none', () {
    final defaults = const AnalysisSettings().copyWith(pitchFloorHz: 60);
    Recording rec({String? json}) => Recording(
      id: 1,
      name: 'r',
      relativePath: 'r.wav',
      createdAt: DateTime(2026),
      sampleRate: 44100,
      channels: 1,
      analysisSettingsJson: json,
    );
    expect(
      AnalysisController(rec(), defaultSettings: defaults).settings.pitchFloorHz,
      60,
    );
    final own = const AnalysisSettings().copyWith(pitchFloorHz: 90).toJson();
    expect(
      AnalysisController(rec(json: own), defaultSettings: defaults)
          .settings
          .pitchFloorHz,
      90,
    );
    expect(
      AnalysisController(rec()).settings.pitchFloorHz,
      const AnalysisSettings().pitchFloorHz,
    );
  });
}
