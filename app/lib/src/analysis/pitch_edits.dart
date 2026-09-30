import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import '../rust/api/core.dart' as rust;

/// Manual corrections of the automatic F0 track, as per-frame overrides
/// (0 = unvoiced). Every operation is one undo step. Frames are those of
/// [auto]; the sidecar file stores their times so the CLI can apply the
/// same corrections without the candidate list.
class PitchEditor {
  PitchEditor(
    this.auto, {
    required this.timeStepS,
    required this.floorHz,
    required this.ceilingHz,
    Map<int, double>? overrides,
  }) : _overrides = Map.of(overrides ?? const {});

  /// Maps stored edits onto [auto]'s frames with the rule of the Rust
  /// `PitchEdits::apply`: nearest frame, within half a frame step.
  factory PitchEditor.fromData(
    rust.F0CandidatesData auto,
    rust.PitchEditsData data,
  ) {
    final overrides = <int, double>{};
    for (var k = 0; k < data.timesS.length; k++) {
      final i = frameNear(auto.timesS, data.timesS[k], data.timeStepS);
      if (i != null) overrides[i] = data.f0Hz[k];
    }
    return PitchEditor(
      auto,
      timeStepS: data.timeStepS,
      floorHz: data.f0MinHz,
      ceilingHz: data.f0MaxHz,
      overrides: overrides,
    );
  }

  final rust.F0CandidatesData auto;
  final double timeStepS;
  final double floorHz;
  final double ceilingHz;

  Map<int, double> _overrides;
  final _undo = <Map<int, double>>[];
  final _redo = <Map<int, double>>[];

  int get frameCount => auto.timesS.length;
  int get editedCount => _overrides.length;
  bool get isEmpty => _overrides.isEmpty;
  bool get canUndo => _undo.isNotEmpty;
  bool get canRedo => _redo.isNotEmpty;
  bool isEdited(int frame) => _overrides.containsKey(frame);

  double valueAt(int frame) => _overrides[frame] ?? auto.f0Hz[frame];

  /// The corrected track.
  Float64List corrected() {
    final out = Float64List.fromList(auto.f0Hz);
    _overrides.forEach((i, f) => out[i] = f);
    return out;
  }

  /// Per-frame mask of edited frames.
  List<bool> editedMask() =>
      List.generate(frameCount, (i) => _overrides.containsKey(i));

  /// Voiced candidates of [frame], cheapest first.
  List<double> candidatesAt(int frame) {
    final k = auto.maxCandidates;
    final out = <double>[];
    for (var j = 0; j < k; j++) {
      final f = auto.candidatesHz[frame * k + j];
      if (f > 0) out.add(f);
    }
    return out;
  }

  /// Frame nearest [t] within half a step, or null.
  int? nearestFrame(double t) => frameNear(auto.timesS, t, timeStepS);

  static int? frameNear(Float64List times, double t, double fallbackStep) {
    if (times.isEmpty) return null;
    final step = times.length > 1 ? times[1] - times[0] : fallbackStep;
    final i = ((t - times[0]) / step).round();
    if (i < 0 || i >= times.length) return null;
    return (times[i] - t).abs() <= 0.5 * step + 1e-9 ? i : null;
  }

  Iterable<int> _framesIn(double t0, double t1) sync* {
    for (var i = 0; i < frameCount; i++) {
      final t = auto.timesS[i];
      if (t >= t0 && t < t1) yield i;
    }
  }

  bool _commit(Map<int, double> next) {
    if (_sameMap(next, _overrides)) return false;
    _undo.add(_overrides);
    _redo.clear();
    _overrides = next;
    return true;
  }

  /// Sets [frame] to [hz]; an override equal to the automatic value is
  /// dropped, so the frame counts as unedited again.
  void _set(Map<int, double> m, int frame, double hz) {
    if (hz == auto.f0Hz[frame]) {
      m.remove(frame);
    } else {
      m[frame] = hz;
    }
  }

  bool chooseCandidate(int frame, double hz) {
    if (frame < 0 || frame >= frameCount) return false;
    final next = Map.of(_overrides);
    _set(next, frame, hz);
    return _commit(next);
  }

  /// Multiplies voiced frames in [t0, t1) by [factor] (2 or 0.5). The
  /// result snaps to a candidate within a semitone of the target when one
  /// exists, so a corrected octave error lands on a periodicity the tracker
  /// found; frames whose target falls outside the pitch range are left.
  bool octave(double t0, double t1, double factor) {
    final next = Map.of(_overrides);
    for (final i in _framesIn(t0, t1)) {
      final cur = valueAt(i);
      if (cur <= 0) continue;
      final target = cur * factor;
      if (target < floorHz || target > ceilingHz) continue;
      var value = target;
      var best = 1.0 / 12;
      for (final c in candidatesAt(i)) {
        final d = (math.log(c / target) / math.ln2).abs();
        if (d <= best) {
          best = d;
          value = c;
        }
      }
      _set(next, i, value);
    }
    return _commit(next);
  }

  bool unvoice(double t0, double t1) {
    final next = Map.of(_overrides);
    for (final i in _framesIn(t0, t1)) {
      _set(next, i, 0);
    }
    return _commit(next);
  }

  /// Voices unvoiced frames in [t0, t1) with their cheapest candidate;
  /// frames without a voiced candidate stay unvoiced.
  bool voice(double t0, double t1) {
    final next = Map.of(_overrides);
    for (final i in _framesIn(t0, t1)) {
      if (valueAt(i) > 0) continue;
      final cands = candidatesAt(i);
      if (cands.isNotEmpty) _set(next, i, cands.first);
    }
    return _commit(next);
  }

  /// Returns frames in [t0, t1) to the automatic track.
  bool revert(double t0, double t1) {
    final next = Map.of(_overrides);
    for (final i in _framesIn(t0, t1)) {
      next.remove(i);
    }
    return _commit(next);
  }

  bool undo() {
    if (_undo.isEmpty) return false;
    _redo.add(_overrides);
    _overrides = _undo.removeLast();
    return true;
  }

  bool redo() {
    if (_redo.isEmpty) return false;
    _undo.add(_overrides);
    _overrides = _redo.removeLast();
    return true;
  }

  rust.PitchEditsData toData() {
    final frames = _overrides.keys.toList()..sort();
    return rust.PitchEditsData(
      timeStepS: timeStepS,
      f0MinHz: floorHz,
      f0MaxHz: ceilingHz,
      timesS: Float64List.fromList([for (final i in frames) auto.timesS[i]]),
      f0Hz: Float64List.fromList([for (final i in frames) _overrides[i]!]),
    );
  }

  static bool _sameMap(Map<int, double> a, Map<int, double> b) =>
      a.length == b.length && a.entries.every((e) => b[e.key] == e.value);
}

/// Whether stored edits were made at these pitch settings.
bool pitchEditsMatch(
  rust.PitchEditsData data, {
  required double timeStepS,
  required double floorHz,
  required double ceilingHz,
}) {
  bool close(double a, double b) =>
      (a - b).abs() <= 1e-9 * math.max(1, math.max(a.abs(), b.abs()));
  return close(data.timeStepS, timeStepS) &&
      close(data.f0MinHz, floorHz) &&
      close(data.f0MaxHz, ceilingHz);
}

/// Overwrites edited frames of [track] (same rule as the Rust `apply`) and
/// returns the corrected track with its edited-frame mask.
({rust.F0TrackData track, List<bool> edited}) applyPitchEdits(
  rust.F0TrackData track,
  rust.PitchEditsData data,
) {
  final f0 = Float64List.fromList(track.f0Hz);
  final edited = List<bool>.filled(f0.length, false);
  for (var k = 0; k < data.timesS.length; k++) {
    final i = PitchEditor.frameNear(
      track.timesS,
      data.timesS[k],
      data.timeStepS,
    );
    if (i == null) continue;
    f0[i] = data.f0Hz[k];
    edited[i] = true;
  }
  return (
    track: rust.F0TrackData(timesS: track.timesS, f0Hz: f0),
    edited: edited,
  );
}

/// Reads the sidecar beside [absWavPath]; null when there is none.
Future<rust.PitchEditsData?> readPitchEdits(String absWavPath) async {
  final file = File(rust.pitchEditsPath(wavPath: absWavPath));
  if (!await file.exists()) return null;
  return rust.parsePitchEdits(text: await file.readAsString());
}

/// Writes [data] beside [absWavPath] through a staging file and a rename,
/// so a failed write cannot truncate saved edits; null or empty edits
/// remove the sidecar.
Future<void> writePitchEdits(
  String absWavPath,
  rust.PitchEditsData? data,
) async {
  final path = rust.pitchEditsPath(wavPath: absWavPath);
  if (data == null || data.timesS.isEmpty) {
    final f = File(path);
    if (await f.exists()) await f.delete();
    return;
  }
  final staging = await Directory(
    p.dirname(path),
  ).createTemp('.openphon_pitch_');
  try {
    final tmp = File(p.join(staging.path, 'edits.csv'));
    await tmp.writeAsString(rust.formatPitchEdits(data: data), flush: true);
    await tmp.rename(path);
  } finally {
    await staging.delete(recursive: true);
  }
}
