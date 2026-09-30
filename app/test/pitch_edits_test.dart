import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:openphon/src/analysis/analysis_controller.dart';
import 'package:openphon/src/analysis/measurements.dart';
import 'package:openphon/src/analysis/pitch_edits.dart';
import 'package:openphon/src/annotation/annotation_model.dart';
import 'package:openphon/src/data/database.dart';
import 'package:openphon/src/rust/api/core.dart' as rust;

/// Ten frames at 10 ms from 5 ms: 200 Hz, with its subharmonic and a second
/// alternative as candidates; frames 7..9 unvoiced, frame 8 without any.
rust.F0CandidatesData _auto() {
  const n = 10;
  final times = Float64List.fromList([
    for (var i = 0; i < n; i++) 0.005 + 0.01 * i,
  ]);
  final f0 = Float64List.fromList([
    for (var i = 0; i < n; i++) i < 7 ? 200.0 : 0.0,
  ]);
  final cands = Float64List(n * 4);
  for (var i = 0; i < n; i++) {
    if (i == 8) continue;
    cands[i * 4] = 200;
    cands[i * 4 + 1] = 101; // within a semitone of 100
    cands[i * 4 + 2] = 300;
  }
  return rust.F0CandidatesData(
    timesS: times,
    f0Hz: f0,
    candidatesHz: cands,
    maxCandidates: 4,
  );
}

PitchEditor _editor() =>
    PitchEditor(_auto(), timeStepS: 0.01, floorHz: 75, ceilingHz: 600);

void main() {
  test('candidate choice overrides one frame and undoes', () {
    final ed = _editor();
    expect(ed.chooseCandidate(2, 300), isTrue);
    expect(ed.corrected()[2], 300);
    expect(ed.editedMask()[2], isTrue);
    expect(ed.editedCount, 1);
    // Choosing the automatic value again clears the override.
    expect(ed.chooseCandidate(2, 200), isTrue);
    expect(ed.isEmpty, isTrue);
    expect(ed.undo(), isTrue);
    expect(ed.corrected()[2], 300);
    expect(ed.redo(), isTrue);
    expect(ed.isEmpty, isTrue);
  });

  test('octave down snaps to a candidate within a semitone', () {
    final ed = _editor();
    expect(ed.octave(0.0, 0.03, 0.5), isTrue);
    expect(ed.corrected().sublist(0, 4), [101, 101, 101, 200]);
    // Octave up from there: 202 is within a semitone of candidate 200,
    // which is the automatic value, so the frames count as unedited.
    expect(ed.octave(0.0, 0.03, 2), isTrue);
    expect(ed.isEmpty, isTrue);
  });

  test('octave leaves frames whose target leaves the pitch range', () {
    final ed = PitchEditor(
      _auto(),
      timeStepS: 0.01,
      floorHz: 150,
      ceilingHz: 600,
    );
    expect(ed.octave(0.0, 0.1, 0.5), isFalse);
  });

  test('unvoice, voice and revert act on the selected frames only', () {
    final ed = _editor();
    expect(ed.unvoice(0.02, 0.04), isTrue);
    expect(ed.corrected().sublist(1, 5), [200, 0, 0, 200]);
    expect(ed.voice(0.06, 0.1), isTrue);
    // Frame 8 has no voiced candidate and stays unvoiced.
    expect(ed.corrected().sublist(7), [200, 0, 200]);
    expect(ed.revert(0.0, 0.05), isTrue);
    expect(ed.corrected().sublist(0, 5), [200, 200, 200, 200, 200]);
    expect(ed.editedCount, 2);
  });

  test('stored edits round-trip through frame times', () {
    final ed = _editor()
      ..chooseCandidate(3, 300)
      ..unvoice(0.05, 0.06);
    final data = ed.toData();
    expect(data.timesS[0], closeTo(0.035, 1e-12));
    expect(data.timesS[1], closeTo(0.055, 1e-12));
    expect(data.f0Hz, [300, 0]);
    final back = PitchEditor.fromData(_auto(), data);
    expect(back.corrected(), ed.corrected());
    expect(
      pitchEditsMatch(data, timeStepS: 0.01, floorHz: 75, ceilingHz: 600),
      isTrue,
    );
    expect(
      pitchEditsMatch(data, timeStepS: 0.01, floorHz: 75, ceilingHz: 500),
      isFalse,
    );
  });

  test('applyPitchEdits follows the core rule: nearest frame, half a step', () {
    // Same fixture as core/src/pitch_edits.rs.
    final track = rust.F0TrackData(
      timesS: Float64List.fromList([0.1034, 0.1134, 0.1234, 0.1334, 0.1434]),
      f0Hz: Float64List.fromList([100, 100, 100, 100, 100]),
    );
    final edits = rust.PitchEditsData(
      timeStepS: 0.01,
      f0MinHz: 75,
      f0MaxHz: 600,
      timesS: Float64List.fromList([0.1234, 0.1334, 0.5]),
      f0Hz: Float64List.fromList([200, 0, 300]),
    );
    final r = applyPitchEdits(track, edits);
    expect(r.track.f0Hz, [100, 100, 200, 0, 100]);
    expect(r.edited, [false, false, true, true, false]);
  });

  test('measurement export counts edited frames in a final column', () {
    final ed = _editor()..unvoice(0.0, 0.02);
    final track = rust.F0TrackData(
      timesS: _auto().timesS,
      f0Hz: ed.corrected(),
    );
    const tier = IntervalTierModel(
      name: 'v',
      intervals: [Interval(0, 0.05, 'a'), Interval(0.05, 0.1, 'b')],
    );
    final rows = measureIntervals(tier, f0: track, f0Edited: ed.editedMask());
    expect(rows.map((r) => r.f0EditedFrames), [2, 0]);
    expect(rows[0].meanF0Hz, 200);
    final plain = measurementsCsv('v', rows).split('\n').first;
    expect(plain, endsWith(',mean_intensity_db'));
    final csv = measurementsCsv('v', rows, editedColumn: true).split('\n');
    expect(csv[0], endsWith(',mean_intensity_db,f0_edited_frames'));
    expect(csv[1], endsWith(',2'));
    final batch = batchMeasurementsCsv([
      FileMeasures(file: 'x', tierName: 'v', rows: rows, pitchEdited: true),
      FileMeasures(file: 'y', tierName: 'v', rows: rows.sublist(1)),
    ]).split('\n');
    expect(batch[0], endsWith(',f0_edited_frames'));
    expect(batch[3], startsWith('y,'));
    expect(batch[3], endsWith(',0'));
  });

  group('controller', () {
    AnalysisController controller() {
      final c = AnalysisController(
        Recording(
          id: 1,
          name: 'r',
          relativePath: 'r.wav',
          createdAt: DateTime(2026),
          sampleRate: 44100,
          channels: 1,
        ),
      );
      c.durationS = 0.1;
      c.f0Candidates = _auto();
      c.pitchEditor = _editor();
      return c;
    }

    test('a tap near a candidate chooses it; a distant tap falls through', () {
      final c = controller();
      // 300 Hz sits at (300 - 75) / 525 = 0.4286 of the pitch axis.
      expect(c.pitchEditTap(0.026, 0.43, tolFrac: 0.02), isTrue);
      expect(c.pitchEditor!.valueAt(2), 300);
      expect(c.f0Track!.f0Hz[2], 300);
      expect(c.f0EditedMask![2], isTrue);
      expect(c.pitchEditTap(0.026, 0.9, tolFrac: 0.02), isFalse);
    });

    test('selection operations need a selection and undo', () {
      final c = controller();
      expect(c.pitchUnvoice(), isFalse);
      c.setSelection(const TimeSelection(0.0, 0.02));
      expect(c.pitchUnvoice(), isTrue);
      expect(c.f0Track!.f0Hz.sublist(0, 3), [0, 0, 200]);
      expect(c.pitchUndo(), isTrue);
      expect(c.f0EditedMask, isNull);
    });

    test('stored edits at other settings block editing', () {
      final c = controller();
      c.pitchEditor = null;
      c.storedPitchEdits = rust.PitchEditsData(
        timeStepS: 0.01,
        f0MinHz: 100,
        f0MaxHz: 500,
        timesS: Float64List.fromList([0.015]),
        f0Hz: Float64List.fromList([0]),
      );
      expect(c.pitchEditsMismatch, isTrue);
      expect(c.pitchEditTap(0.026, 0.43), isFalse);
    });
  });
}
