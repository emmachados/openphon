import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:openphon/src/analysis/view_prefs.dart';
import 'package:openphon/src/data/app_prefs.dart';

void main() {
  test('map round-trip preserves every field', () {
    const prefs = ViewPrefs(
      showSpectrogram: false,
      showIntensity: false,
      pitchColor: 0xFF0072B2,
      formantColor: 0xFFD55E00,
      intensityColor: 0xFFE69F00,
      markScale: 1.5,
    );
    expect(ViewPrefs.fromMap(prefs.toMap()), prefs);
  });

  test('defaults match the classic hard-coded colors', () {
    const d = ViewPrefs();
    expect(d.pitchColor, 0xFF1565C0);
    expect(d.formantColor, 0xFFC62828);
    expect(d.intensityColor, 0xFF9E9D24);
    expect(d.markScale, 1.0);
    expect(
      d.showSpectrogram && d.showPitch && d.showFormants && d.showIntensity,
      isTrue,
    );
  });

  test('fromMap tolerates missing and wrongly typed keys', () {
    final parsed = ViewPrefs.fromMap({
      'showPitch': 'yes',
      'pitchColor': 'blue',
      'markScale': '2',
      'unknownFutureKey': 42,
    });
    expect(parsed, const ViewPrefs());
    // Out-of-range scale is clamped, not rejected.
    expect(ViewPrefs.fromMap({'markScale': 99}).markScale, 3.0);
  });

  test('presets change colors/scale but preserve visibility', () {
    const hidden = ViewPrefs(showIntensity: false, showSpectrogram: false);
    final okabe = hidden.withOkabeItoPreset();
    expect(okabe.pitchColor, ViewPrefs.okabeBlue);
    expect(okabe.formantColor, ViewPrefs.okabeVermillion);
    expect(okabe.showIntensity, isFalse);
    expect(okabe.showSpectrogram, isFalse);
    expect(hidden.withHighVisibilityPreset().markScale, 1.5);
    // Classic preset restores the default look exactly.
    expect(
      okabe.withClassicPreset().copyWith(
        showIntensity: true,
        showSpectrogram: true,
      ),
      const ViewPrefs(),
    );
  });

  test('AppPrefs persists and reloads view prefs', () async {
    final dir = await Directory.systemTemp.createTemp('openphon_prefs_');
    addTearDown(() => dir.delete(recursive: true));
    final file = File('${dir.path}/prefs.json');

    final prefs = AppPrefs(fileOverride: file);
    await prefs.setViewPrefs(
      const ViewPrefs(showFormants: false, markScale: 1.25),
    );

    final reloaded = AppPrefs(fileOverride: file);
    await reloaded.load();
    expect(reloaded.viewPrefs.showFormants, isFalse);
    expect(reloaded.viewPrefs.markScale, 1.25);
    expect(reloaded.viewPrefs.showPitch, isTrue);

    // A corrupt viewPrefs key leaves the defaults without breaking load.
    await file.writeAsString(jsonEncode({'viewPrefs': 'garbage'}));
    final corrupt = AppPrefs(fileOverride: file);
    await corrupt.load();
    expect(corrupt.viewPrefs, const ViewPrefs());
  });
}
