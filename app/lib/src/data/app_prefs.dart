import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart' show ThemeMode;
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../analysis/analysis_settings.dart';
import '../analysis/view_prefs.dart';
import '../audio/recorder_service.dart' show RecordingOptions, libraryRoot;

/// App-level preferences, persisted as a small JSON file in the app support
/// directory (`prefs.json`). Deliberately not in the drift database: these
/// are not per-recording rows and a flat file needs no schema migrations.
class AppPrefs extends ChangeNotifier {
  AppPrefs({this.fileOverride});

  /// Test seam: bypasses the platform support directory.
  final File? fileOverride;

  ThemeMode themeMode = ThemeMode.system;

  /// Analysis defaults applied to recordings that have no stored settings
  /// yet; null means the built-in [AnalysisSettings] defaults.
  AnalysisSettings? defaultAnalysisSettings;

  /// Display preferences for the analysis view (layer visibility, track
  /// colors, mark scale).
  ViewPrefs viewPrefs = const ViewPrefs();

  /// Capture parameters for new recordings.
  RecordingOptions recordingOptions = const RecordingOptions();

  Future<File> _file() async =>
      fileOverride ?? File(p.join((await libraryRoot()).path, 'prefs.json'));

  static ThemeMode _parseTheme(Object? v) => switch (v) {
    'light' => ThemeMode.light,
    'dark' => ThemeMode.dark,
    _ => ThemeMode.system,
  };

  static String _themeName(ThemeMode m) => switch (m) {
    ThemeMode.light => 'light',
    ThemeMode.dark => 'dark',
    ThemeMode.system => 'system',
  };

  /// Loads preferences; missing or corrupt files leave the defaults.
  Future<void> load() async {
    try {
      final file = await _file();
      if (!await file.exists()) return;
      final map = jsonDecode(await file.readAsString());
      if (map is! Map<String, dynamic>) return;
      themeMode = _parseTheme(map['themeMode']);
      final defaults = map['defaultAnalysisSettings'];
      defaultAnalysisSettings = defaults is String
          ? AnalysisSettings.fromJson(defaults)
          : null;
      final view = map['viewPrefs'];
      viewPrefs = view is Map<String, dynamic>
          ? ViewPrefs.fromMap(view)
          : const ViewPrefs();
      final rec = map['recordingOptions'];
      recordingOptions = rec is Map<String, dynamic>
          ? RecordingOptions.fromMap(rec)
          : const RecordingOptions();
      notifyListeners();
    } catch (_) {
      // Preferences are best-effort; the app must still start.
    }
  }

  Future<void> _save() async {
    try {
      final file = await _file();
      await file.writeAsString(
        jsonEncode({
          'themeMode': _themeName(themeMode),
          if (defaultAnalysisSettings != null)
            'defaultAnalysisSettings': defaultAnalysisSettings!.toJson(),
          if (viewPrefs != const ViewPrefs()) 'viewPrefs': viewPrefs.toMap(),
          if (recordingOptions != const RecordingOptions())
            'recordingOptions': recordingOptions.toMap(),
        }),
      );
    } catch (_) {
      // Losing a preference write is not worth surfacing.
    }
  }

  Future<void> setThemeMode(ThemeMode mode) async {
    if (mode == themeMode) return;
    themeMode = mode;
    notifyListeners();
    await _save();
  }

  Future<void> setDefaultAnalysisSettings(AnalysisSettings? settings) async {
    defaultAnalysisSettings = settings;
    notifyListeners();
    await _save();
  }

  Future<void> setViewPrefs(ViewPrefs next) async {
    if (next == viewPrefs) return;
    viewPrefs = next;
    notifyListeners();
    await _save();
  }

  Future<void> setRecordingOptions(RecordingOptions next) async {
    if (next == recordingOptions) return;
    recordingOptions = next;
    notifyListeners();
    await _save();
  }
}
