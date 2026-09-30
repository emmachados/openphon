import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../annotation/annotation_editor.dart';
import '../annotation/annotation_model.dart';
import '../audio/playback_service.dart';
import '../audio/recorder_service.dart'
    show findSiblingTextGrid, toAbsolutePath;
import '../data/database.dart';
import '../data/annotation_storage.dart';
import '../rust/api/core.dart' as rust;
import 'analysis_settings.dart';
import 'pitch_edits.dart' as pe;
import 'spectrogram_image.dart';

/// Visible time range of the synchronized viewport, in seconds.
@immutable
class TimeViewport {
  const TimeViewport(this.t0, this.t1) : assert(t1 > t0);

  final double t0;
  final double t1;

  double get span => t1 - t0;

  bool contains(double t) => t >= t0 && t <= t1;

  @override
  bool operator ==(Object other) =>
      other is TimeViewport && other.t0 == t0 && other.t1 == t1;

  @override
  int get hashCode => Object.hash(t0, t1);
}

/// Selected time interval, ordered.
@immutable
class TimeSelection {
  const TimeSelection(double a, double b)
    : t0 = a < b ? a : b,
      t1 = a < b ? b : a;

  final double t0;
  final double t1;

  double get span => t1 - t0;
}

/// A boundary (interval tier, index = interior boundary 1..n-1) or point
/// (point tier, index into points) selected in the tier strip.
@immutable
class AnnotationHit {
  const AnnotationHit({
    required this.tier,
    required this.index,
    required this.isPoint,
  });

  final int tier;
  final int index;
  final bool isPoint;
}

/// Live drag of a boundary/point: identity plus current preview time.
@immutable
class AnnotationDrag {
  const AnnotationDrag({
    required this.tier,
    required this.index,
    required this.isPoint,
    required this.timeS,
  });

  final int tier;
  final int index;
  final bool isPoint;
  final double timeS;

  AnnotationDrag at(double t) =>
      AnnotationDrag(tier: tier, index: index, isPoint: isPoint, timeS: t);
}

/// Waveform envelope tagged with the range it was computed for, so the
/// painter can keep it correctly positioned while the viewport moves.
class EnvelopeSlice {
  EnvelopeSlice(this.t0, this.t1, this.data);

  final double t0;
  final double t1;
  final rust.WaveformEnvelope data;
}

const double kMinViewportSpanS = 0.02;

/// State hub for one open recording: Rust sound handle, playback,
/// viewport, selection, cursor. Widgets listen and repaint.
class AnalysisController extends ChangeNotifier {
  AnalysisController(
    this.recording, {
    this.onSaveSettings,
    this.writeAnnotation = writeAnnotationAtomically,
    this.readPitchEdits = pe.readPitchEdits,
    this.writePitchEdits = pe.writePitchEdits,
    AnalysisSettings? defaultSettings,
  }) : settings = recording.analysisSettingsJson == null
           ? (defaultSettings ?? const AnalysisSettings())
           : AnalysisSettings.fromJson(recording.analysisSettingsJson!);

  final Recording recording;

  /// Persists changed settings; injected so the controller stays
  /// database-agnostic (and trivially testable).
  final Future<void> Function(int recordingId, String json)? onSaveSettings;

  final Future<void> Function({
    required String path,
    required rust.TextGridData data,
  })
  writeAnnotation;

  final Future<rust.PitchEditsData?> Function(String absWavPath) readPitchEdits;
  final Future<void> Function(String absWavPath, rust.PitchEditsData? data)
  writePitchEdits;

  AnalysisSettings settings;

  /// Created on first use so pure viewport logic (and its tests) never
  /// touches the audio plugin.
  PlaybackService get playback => _playback ??= PlaybackService();
  PlaybackService? _playback;

  rust.Sound? _sound;
  String? _absolutePath;
  Object? error;
  bool get isOpen => _sound != null;
  double durationS = 0;

  TimeViewport viewport = const TimeViewport(0, 1);
  TimeSelection? selection;
  double? cursorTimeS;

  EnvelopeSlice? envelope;
  Timer? _settleTimer;
  int _envelopeGeneration = 0;
  int _requestedBuckets = 0;
  bool _disposed = false;

  // Spectrogram display settings, from the per-recording [settings].
  double get sgWindowS => settings.spectrogramWindowS;
  double get sgMaxFreqHz => settings.spectrogramMaxFreqHz;
  double get sgPreEmphasisHz => settings.spectrogramPreEmphasisHz;
  double get sgDynamicRangeDb => settings.dynamicRangeDb;
  double get sgMinTimeStepS => settings.spectrogramMinTimeStepS;

  SpectrogramImage? spectrogramImage;
  final SpectrogramCache _sgCache = SpectrogramCache();
  int _sgWidthPx = 0;

  // Track analysis settings, from the per-recording [settings].
  double get pitchFloorHz => settings.pitchFloorHz;
  double get pitchCeilingHz => settings.pitchCeilingHz;
  int get maxFormants => settings.maxFormants;
  double get formantCeilingHz => settings.formantCeilingHz;
  double get intensityMinPitchHz => settings.intensityMinPitchHz;
  double get trackTimeStepS => settings.trackTimeStepS;

  /// The F0 track every consumer reads: the automatic track with any
  /// manual corrections applied.
  rust.F0TrackData? f0Track;

  /// Automatic track with each frame's candidates.
  rust.F0CandidatesData? f0Candidates;

  /// Frames of [f0Track] set by hand; null when no edits apply.
  List<bool>? f0EditedMask;

  /// Edits at the current pitch settings; null while the track loads or
  /// while stored edits belong to other settings.
  pe.PitchEditor? pitchEditor;

  /// Edits read from, or last written to, the sidecar file.
  rust.PitchEditsData? storedPitchEdits;

  bool pitchEditMode = false;

  /// Last failure writing the sidecar.
  Object? pitchEditsError;

  /// The sidecar exists but could not be parsed; editing stays off so the
  /// file is not overwritten unless the user discards it.
  Object? pitchEditsUnreadable;
  Future<void> _pitchSave = Future.value();

  /// Stored edits exist but were made at other pitch settings, so they are
  /// neither shown nor editable until those settings return or the edits
  /// are discarded.
  bool get pitchEditsMismatch =>
      f0Candidates != null && pitchEditor == null && storedPitchEdits != null;

  rust.IntensityTrackData? intensityTrack;
  rust.FormantTrackData? formantTrack;
  bool get tracksLoading => _tracksPending > 0;
  int _tracksPending = 0;

  /// TextGrid editing engine; null while no TextGrid is loaded.
  AnnotationEditor? annotation;

  /// Tier that tap/keyboard editing targets.
  int activeTier = 0;

  /// Load/save target: the TextGrid alongside the WAV (Praat convention).
  String? annotationPath;

  Object? annotationError;

  Future<void> open() async {
    try {
      final abs = await toAbsolutePath(recording.relativePath);
      _absolutePath = abs;
      final loadClock = Stopwatch()..start();
      final sound = await rust.Sound.load(path: abs);
      if (kDebugMode || kProfileMode) {
        debugPrint('perf: Sound.load ${loadClock.elapsedMilliseconds} ms');
      }
      if (_disposed) {
        sound.dispose();
        return;
      }
      _sound = sound;
      durationS = sound.durationS();
      if (durationS <= 0) durationS = 0.001;
      viewport = TimeViewport(0, durationS);
      await playback.load(
        abs,
        fallbackDuration: Duration(microseconds: (durationS * 1e6).round()),
      );
      await _loadAnnotation(abs);
      try {
        storedPitchEdits = await readPitchEdits(abs);
      } catch (e) {
        pitchEditsUnreadable = e;
      }
    } catch (e) {
      error = e;
    }
    _notify();
    if (_sound != null) loadTracks();
  }

  /// Whole-file F0/intensity/formant tracks, computed in parallel on the
  /// bridge worker pool. Each lands independently.
  Future<void> loadTracks() =>
      Future.wait([_loadF0(), _loadIntensity(), _loadFormants()]).then((_) {});

  Future<void> _runTrack(Future<void> Function() task) async {
    _tracksPending++;
    _notify();
    final clock = Stopwatch()..start();
    try {
      await task();
    } catch (_) {
      // Leave the track absent; overlays simply skip it.
    }
    if (kDebugMode || kProfileMode) {
      debugPrint('perf: track ${clock.elapsedMilliseconds} ms');
    }
    _tracksPending--;
    _notify();
  }

  Future<void> _loadF0() {
    final sound = _sound;
    if (sound == null) return Future.value();
    f0Track = null;
    f0Candidates = null;
    f0EditedMask = null;
    pitchEditor = null;
    return _runTrack(() async {
      final c = await sound.f0Candidates(
        timeStepS: trackTimeStepS,
        f0MinHz: pitchFloorHz,
        f0MaxHz: pitchCeilingHz,
      );
      if (_disposed) return;
      f0Candidates = c;
      final stored = storedPitchEdits;
      if (pitchEditsUnreadable != null) {
        // Leave pitchEditor null: see [pitchEditsUnreadable].
      } else if (stored == null) {
        pitchEditor = _emptyPitchEditor(c);
      } else if (pe.pitchEditsMatch(
        stored,
        timeStepS: trackTimeStepS,
        floorHz: pitchFloorHz,
        ceilingHz: pitchCeilingHz,
      )) {
        pitchEditor = pe.PitchEditor.fromData(c, stored);
      }
      _refreshF0();
    });
  }

  pe.PitchEditor _emptyPitchEditor(rust.F0CandidatesData c) => pe.PitchEditor(
    c,
    timeStepS: trackTimeStepS,
    floorHz: pitchFloorHz,
    ceilingHz: pitchCeilingHz,
  );

  void _refreshF0() {
    final c = f0Candidates;
    if (c == null) return;
    final ed = pitchEditor;
    f0Track = rust.F0TrackData(
      timesS: c.timesS,
      f0Hz: ed == null ? c.f0Hz : ed.corrected(),
    );
    f0EditedMask = ed == null || ed.isEmpty ? null : ed.editedMask();
  }

  // ---- manual pitch correction ---------------------------------------------

  void togglePitchEditMode() {
    pitchEditMode = !pitchEditMode;
    _notify();
  }

  bool _pitchOp(bool Function(pe.PitchEditor ed) op) {
    final ed = pitchEditor;
    if (ed == null || !op(ed)) return false;
    _refreshF0();
    _persistPitchEdits(ed);
    _notify();
    return true;
  }

  void _persistPitchEdits(pe.PitchEditor ed) {
    final abs = _absolutePath;
    if (abs == null) return;
    final data = ed.isEmpty ? null : ed.toData();
    storedPitchEdits = data;
    _pitchSave = _pitchSave.then((_) async {
      try {
        await writePitchEdits(abs, data);
        pitchEditsError = null;
      } catch (e) {
        pitchEditsError = e;
      }
      _notify();
    });
  }

  /// Completes when every edit so far has been written.
  Future<void> get pitchEditsSaved => _pitchSave;

  /// Tap in the pitch plot at time [t] and height [frac] (0 = pitch floor,
  /// 1 = ceiling): chooses the candidate of the nearest frame closest to
  /// [frac] within [tolFrac]. Returns false when no candidate is that
  /// close, so the tap can fall through to the cursor.
  bool pitchEditTap(double t, double frac, {double tolFrac = 0.04}) {
    final ed = pitchEditor;
    if (ed == null) return false;
    final i = ed.nearestFrame(t);
    if (i == null) return false;
    final span = pitchCeilingHz - pitchFloorHz;
    double? best;
    var bestD = tolFrac;
    for (final hz in ed.candidatesAt(i)) {
      final d = ((hz - pitchFloorHz) / span - frac).abs();
      if (d <= bestD) {
        bestD = d;
        best = hz;
      }
    }
    if (best == null) return false;
    final hz = best;
    _pitchOp((ed) => ed.chooseCandidate(i, hz));
    return true;
  }

  bool _selectionOp(bool Function(pe.PitchEditor ed, double t0, double t1) op) {
    final sel = selection;
    if (sel == null || sel.span <= 0) return false;
    return _pitchOp((ed) => op(ed, sel.t0, sel.t1));
  }

  bool pitchOctaveDown() => _selectionOp((ed, a, b) => ed.octave(a, b, 0.5));
  bool pitchOctaveUp() => _selectionOp((ed, a, b) => ed.octave(a, b, 2));
  bool pitchUnvoice() => _selectionOp((ed, a, b) => ed.unvoice(a, b));
  bool pitchVoice() => _selectionOp((ed, a, b) => ed.voice(a, b));
  bool pitchRevert() => _selectionOp((ed, a, b) => ed.revert(a, b));
  bool pitchUndo() => _pitchOp((ed) => ed.undo());
  bool pitchRedo() => _pitchOp((ed) => ed.redo());

  /// Deletes edits stored at other settings and starts afresh at the
  /// current ones.
  Future<void> discardStoredPitchEdits() async {
    final abs = _absolutePath;
    final c = f0Candidates;
    if (abs == null || c == null) return;
    storedPitchEdits = null;
    pitchEditsUnreadable = null;
    pitchEditor = _emptyPitchEditor(c);
    _refreshF0();
    _notify();
    await (_pitchSave = _pitchSave.then((_) => writePitchEdits(abs, null)));
  }

  Future<void> _loadIntensity() {
    final sound = _sound;
    if (sound == null) return Future.value();
    intensityTrack = null;
    return _runTrack(() async {
      final t = await sound.intensity(
        timeStepS: trackTimeStepS,
        minPitchHz: intensityMinPitchHz,
      );
      if (!_disposed) intensityTrack = t;
    });
  }

  Future<void> _loadFormants() {
    final sound = _sound;
    if (sound == null) return Future.value();
    formantTrack = null;
    return _runTrack(() async {
      final t = await sound.formants(
        timeStepS: trackTimeStepS,
        maxFormants: maxFormants,
        ceilingHz: formantCeilingHz,
      );
      if (!_disposed) formantTrack = t;
    });
  }

  /// Apply new settings: invalidate only what actually changed (image
  /// cache vs. individual tracks) and persist.
  Future<void> applySettings(AnalysisSettings next) async {
    final prev = settings;
    settings = next;
    final futures = <Future<void>>[];
    if (next.spectrogramDiffers(prev)) {
      spectrogramImage = null;
      _sgCache.clear();
      _refreshSpectrogram();
    }
    if (next.pitchDiffers(prev)) futures.add(_loadF0());
    if (next.intensityDiffers(prev)) futures.add(_loadIntensity());
    if (next.formantsDiffer(prev)) futures.add(_loadFormants());
    _notify();
    final save = onSaveSettings;
    if (save != null) {
      futures.add(save(recording.id, next.toJson()));
    }
    await Future.wait(futures);
  }

  String? get absolutePath => _absolutePath;
  rust.Sound? get sound => _sound;

  // ---- viewport -----------------------------------------------------------

  void setViewport(double t0, double t1) {
    var span = (t1 - t0).clamp(kMinViewportSpanS, durationS);
    var start = t0;
    if (start < 0) start = 0;
    if (start + span > durationS) start = durationS - span;
    if (start < 0) {
      start = 0;
      span = durationS;
    }
    final next = TimeViewport(start, start + span);
    if (next == viewport) return;
    viewport = next;
    _notify();
    _scheduleSettled();
  }

  void zoomAbout(double focalT, double factor) {
    final span = (viewport.span * factor).clamp(
      kMinViewportSpanS,
      durationS <= 0 ? 1 : durationS,
    );
    final ratio = viewport.span == 0
        ? 0.5
        : (focalT - viewport.t0) / viewport.span;
    final t0 = focalT - span * ratio;
    setViewport(t0, t0 + span);
  }

  void panBy(double dt) => setViewport(viewport.t0 + dt, viewport.t1 + dt);

  void zoomToFit() => setViewport(0, durationS);

  /// Zoom to the selection with 5% context either side.
  void zoomToSelection() {
    final sel = selection;
    if (sel == null || sel.span <= 0) return;
    final pad = sel.span * 0.05;
    setViewport(sel.t0 - pad, sel.t1 + pad);
  }

  // ---- cursor / selection -------------------------------------------------

  void setCursor(double t, {double? freqHz}) {
    cursorTimeS = t.clamp(0.0, durationS);
    cursorFreqHz = freqHz;
    playback.seek(_toDuration(cursorTimeS!));
    _notify();
  }

  double? cursorFreqHz;

  // ---- readout ------------------------------------------------------------

  int? _nearestIndex(Float64List times, double t) {
    if (times.isEmpty) return null;
    final step = times.length > 1 ? times[1] - times[0] : 1.0;
    final i = ((t - times[0]) / step).round();
    if (i < 0 || i >= times.length) return null;
    return i;
  }

  /// F0 at the frame nearest [t]; null when unvoiced or not computed.
  double? f0At(double t) {
    final track = f0Track;
    if (track == null) return null;
    final i = _nearestIndex(track.timesS, t);
    if (i == null) return null;
    final f = track.f0Hz[i];
    return f > 0 ? f : null;
  }

  double? intensityAt(double t) {
    final track = intensityTrack;
    if (track == null) return null;
    final i = _nearestIndex(track.timesS, t);
    if (i == null) return null;
    final db = track.db[i];
    return db.isFinite && db > -250 ? db : null;
  }

  /// Formants at the frame nearest [t]; zeros (missing) are skipped but
  /// positions are kept, so index 0 is always F1 and so on.
  List<double?> formantsAt(double t) {
    final track = formantTrack;
    if (track == null) return const [];
    final i = _nearestIndex(track.timesS, t);
    if (i == null) return const [];
    final n = track.maxFormants;
    return List.generate(n, (k) {
      final f = track.formantsHz[i * n + k];
      return f > 0 ? f : null;
    });
  }

  void setSelection(TimeSelection? s) {
    selection = s;
    _notify();
  }

  // ---- annotation ---------------------------------------------------------

  /// Loads the sibling TextGrid if one exists. Failures are recorded but
  /// never fail the recording itself.
  Future<void> _loadAnnotation(String absWav) async {
    annotationPath = p.setExtension(absWav, '.TextGrid');
    try {
      final file = await findSiblingTextGrid(absWav);
      if (file == null) return;
      final data = await rust.readTextGrid(path: file.path);
      annotation = AnnotationEditor(AnnotationDoc.fromTextGrid(data));
      activeTier = 0;
      annotationError = null;
    } catch (e) {
      annotationError = e;
    }
  }

  /// Copies [sourcePath] alongside the WAV and loads it, replacing any
  /// current annotation. Returns an error message, or null on success.
  Future<String?> importTextGrid(String sourcePath) async {
    final target = annotationPath;
    if (target == null) return 'Recording is not open';
    try {
      final data = await rust.readTextGrid(path: sourcePath); // validate first
      await writeAnnotation(path: target, data: data);
      annotation = AnnotationEditor(AnnotationDoc.fromTextGrid(data));
      activeTier = 0;
      annotationError = null;
      _notify();
      return null;
    } catch (e) {
      return '$e';
    }
  }

  /// Boundary (interval tier) or point selected by a nearby tap; target of
  /// Delete and shown emphasized. Cleared by edits that invalidate indices.
  AnnotationHit? annotationHit;

  /// Live boundary/point drag preview; committed to the editor as a single
  /// operation (one undo step) on [endAnnotationDrag].
  AnnotationDrag? annotationDrag;

  /// Tap on tier [tier] at time [t]: activates the tier. Within [tolS] of an
  /// interior boundary or point, selects it (cursor snaps to it); otherwise
  /// on an interval tier selects the tapped interval, on a point tier moves
  /// the cursor. Annotation taps do not seek playback, keeping this logic
  /// plugin-free.
  void annotationTap(int tier, double t, {double tolS = 0}) {
    final doc = annotation?.doc;
    if (doc == null || tier < 0 || tier >= doc.tiers.length) return;
    activeTier = tier;
    annotationHit = null;
    switch (doc.tiers[tier]) {
      case IntervalTierModel it:
        for (var j = 1; j < it.intervals.length; j++) {
          final b = it.intervals[j].xmin;
          if ((b - t).abs() <= tolS) {
            annotationHit = AnnotationHit(tier: tier, index: j, isPoint: false);
            cursorTimeS = b.clamp(0.0, durationS);
            _notify();
            return;
          }
        }
        final i = it.intervalIndexAt(t);
        if (i >= 0) {
          final iv = it.intervals[i];
          selection = TimeSelection(
            iv.xmin.clamp(0.0, durationS),
            iv.xmax.clamp(0.0, durationS),
          );
        }
        cursorTimeS = t.clamp(0.0, durationS);
      case PointTierModel pt:
        for (var j = 0; j < pt.points.length; j++) {
          if ((pt.points[j].time - t).abs() <= tolS) {
            final nearer =
                annotationHit == null ||
                (pt.points[j].time - t).abs() <
                    (pt.points[annotationHit!.index].time - t).abs();
            if (nearer) {
              annotationHit = AnnotationHit(
                tier: tier,
                index: j,
                isPoint: true,
              );
            }
          }
        }
        final hit = annotationHit;
        cursorTimeS = (hit != null ? pt.points[hit.index].time : t).clamp(
          0.0,
          durationS,
        );
    }
    _notify();
  }

  /// Removes the selected boundary (merging its intervals) or point.
  bool annotationDeleteHit() {
    final ed = annotation;
    final hit = annotationHit;
    if (ed == null || hit == null) return false;
    final ok = hit.isPoint
        ? ed.removePoint(hit.tier, hit.index)
        : ed.removeBoundary(hit.tier, hit.index);
    if (ok) {
      annotationHit = null;
      _notify();
    }
    return ok;
  }

  /// Inserts a boundary (interval tier) or an empty point (point tier) at
  /// the cursor on the active tier.
  bool annotationInsertAtCursor() {
    final ed = annotation;
    final t = cursorTimeS;
    if (ed == null || t == null) return false;
    if (activeTier < 0 || activeTier >= ed.doc.tiers.length) return false;
    final ok = switch (ed.doc.tiers[activeTier]) {
      IntervalTierModel() => ed.insertBoundary(activeTier, t),
      PointTierModel() => ed.addPoint(activeTier, t, ''),
    };
    if (ok) {
      annotationHit = null;
      _notify();
    }
    return ok;
  }

  bool annotationSetLabel(int tier, int index, bool isPoint, String text) {
    final ed = annotation;
    if (ed == null) return false;
    final ok = isPoint
        ? ed.setPointMark(tier, index, text)
        : ed.setIntervalText(tier, index, text);
    if (ok) _notify();
    return ok;
  }

  bool annotationUndo() {
    final ok = annotation?.undo() ?? false;
    if (ok) {
      annotationHit = null;
      _notify();
    }
    return ok;
  }

  bool annotationRedo() {
    final ok = annotation?.redo() ?? false;
    if (ok) {
      annotationHit = null;
      _notify();
    }
    return ok;
  }

  /// Starts dragging interior boundary/point [index] on [tier]; selects it.
  void startAnnotationDrag(int tier, int index, {required bool isPoint}) {
    final doc = annotation?.doc;
    if (doc == null || tier < 0 || tier >= doc.tiers.length) return;
    final double t;
    switch (doc.tiers[tier]) {
      case IntervalTierModel it:
        if (isPoint || index < 1 || index >= it.intervals.length) return;
        t = it.intervals[index].xmin;
      case PointTierModel pt:
        if (!isPoint || index < 0 || index >= pt.points.length) return;
        t = pt.points[index].time;
    }
    annotationDrag = AnnotationDrag(
      tier: tier,
      index: index,
      isPoint: isPoint,
      timeS: t,
    );
    annotationHit = AnnotationHit(tier: tier, index: index, isPoint: isPoint);
    activeTier = tier;
    _notify();
  }

  /// Moves the drag preview to [t], clamped between neighbors and snapped
  /// to boundaries/points on other tiers within [snapTolS].
  void updateAnnotationDrag(double t, {double snapTolS = 0}) {
    final doc = annotation?.doc;
    final drag = annotationDrag;
    if (doc == null || drag == null) return;
    if (snapTolS > 0) {
      double? best;
      for (final b in doc.boundaryTimes(excludeTier: drag.tier)) {
        if ((b - t).abs() <= snapTolS &&
            (best == null || (b - t).abs() < (best - t).abs())) {
          best = b;
        }
      }
      if (best != null) t = best;
    }
    const eps = AnnotationEditor.minIntervalS;
    switch (doc.tiers[drag.tier]) {
      case IntervalTierModel it:
        final left = it.intervals[drag.index - 1];
        final right = it.intervals[drag.index];
        t = t.clamp(left.xmin + eps, right.xmax - eps).toDouble();
      case PointTierModel pt:
        var lo = doc.xmin;
        var hi = doc.xmax;
        if (drag.index > 0) lo = pt.points[drag.index - 1].time + eps;
        if (drag.index < pt.points.length - 1) {
          hi = pt.points[drag.index + 1].time - eps;
        }
        if (lo > hi) return;
        t = t.clamp(lo, hi).toDouble();
    }
    annotationDrag = drag.at(t);
    _notify();
  }

  /// Writes the annotation to its sibling-of-the-WAV path and clears the
  /// dirty flag. Returns an error message, or null on success.
  Future<String?>? _annotationSave;

  Future<String?> saveAnnotation() => _annotationSave ??= _saveAnnotation()
      .whenComplete(() => _annotationSave = null);

  Future<String?> _saveAnnotation() async {
    final ed = annotation;
    final path = annotationPath;
    if (ed == null || path == null) return 'No TextGrid to save';
    final saved = ed.doc;
    try {
      await writeAnnotation(path: path, data: saved.toTextGrid());
      ed.markSaved(saved);
      _notify();
      return null;
    } catch (e) {
      return '$e';
    }
  }

  /// Writes the annotation to an arbitrary [path] (export); the dirty flag
  /// is untouched because the sibling file still differs.
  Future<String?> exportAnnotation(String path) async {
    final ed = annotation;
    if (ed == null) return 'No TextGrid to export';
    try {
      await rust.writeTextGrid(path: path, data: ed.doc.toTextGrid());
      return null;
    } catch (e) {
      return '$e';
    }
  }

  /// Replaces the annotation with a fresh single-interval-tier document
  /// spanning the recording. Starts dirty: nothing is on disk until saved.
  void newAnnotation({String tierName = 'phones'}) {
    if (durationS <= 0) return;
    annotation = AnnotationEditor.unsaved(
      AnnotationDoc.singleIntervalTier(
        xmin: 0,
        xmax: durationS,
        tierName: tierName,
      ),
    );
    activeTier = 0;
    annotationHit = null;
    annotationDrag = null;
    _notify();
  }

  /// Ends the drag; when [commit] is set, applies it as one editor
  /// operation (one undo step).
  void endAnnotationDrag({bool commit = true}) {
    final ed = annotation;
    final drag = annotationDrag;
    annotationDrag = null;
    if (ed == null || drag == null) return;
    if (commit) {
      if (drag.isPoint) {
        ed.movePoint(drag.tier, drag.index, drag.timeS);
      } else {
        ed.moveBoundary(drag.tier, drag.index, drag.timeS);
      }
    }
    _notify();
  }

  // ---- waveform envelope --------------------------------------------------

  /// Called by the waveform view with its current pixel width; refreshes
  /// the envelope for the settled viewport.
  void requestEnvelope(int buckets) {
    if (buckets <= 0 || _sound == null) return;
    _requestedBuckets = buckets;
    if (envelope == null) {
      _refreshEnvelope(); // first paint: no debounce
    } else {
      _scheduleSettled();
    }
  }

  void _scheduleSettled() {
    _settleTimer?.cancel();
    _settleTimer = Timer(const Duration(milliseconds: 100), _onSettled);
  }

  void _onSettled() {
    if (_disposed) return;
    _refreshEnvelope();
    _refreshSpectrogram();
  }

  // ---- spectrogram --------------------------------------------------------

  /// Called by the spectrogram view with its pixel width.
  void requestSpectrogram(int px) {
    if (px <= 0 || _sound == null) return;
    _sgWidthPx = px;
    if (spectrogramImage == null) {
      _refreshSpectrogram();
    } else {
      _scheduleSettled();
    }
  }

  /// Time step snapped to doubling levels of the configured minimum, so
  /// pans and small zooms reuse cached images.
  double _quantizedStep(double raw) {
    var s = sgMinTimeStepS;
    while (s < raw) {
      s *= 2;
    }
    return s;
  }

  void _refreshSpectrogram() {
    final sound = _sound;
    if (sound == null || _sgWidthPx <= 0) return;
    final vp = viewport;
    final margin = vp.span / 2;
    final step = _quantizedStep(vp.span / _sgWidthPx);
    double snap(double v) => (v / step).round() * step;
    final req = SpectrogramRequest(
      t0: snap((vp.t0 - margin).clamp(0.0, durationS)),
      t1: snap((vp.t1 + margin).clamp(0.0, durationS)),
      timeStepS: step,
      settingsKey: Object.hash(
        sgWindowS,
        sgMaxFreqHz,
        sgPreEmphasisHz,
        sgDynamicRangeDb,
      ),
    );
    final cached = _sgCache.lookup(req);
    if (cached != null) {
      if (!identical(cached, spectrogramImage)) {
        spectrogramImage = cached;
        _notify();
      }
      return;
    }
    _sgCache.request(
      req,
      (r) async {
        final clock = Stopwatch()..start();
        final sg = await sound.spectrogramRange(
          t0S: r.t0,
          t1S: r.t1,
          windowS: sgWindowS,
          timeStepS: r.timeStepS,
          maxFreqHz: sgMaxFreqHz,
          preEmphasisHz: sgPreEmphasisHz,
        );
        final image = await buildSpectrogramImage(
          sg,
          dynamicRangeDb: sgDynamicRangeDb,
          maxFreqHz: sgMaxFreqHz,
        );
        if (kDebugMode || kProfileMode) {
          debugPrint(
            'perf: spectrogram ${(r.t1 - r.t0).toStringAsFixed(2)} s '
            '@${(r.timeStepS * 1000).toStringAsFixed(1)} ms step -> '
            '${clock.elapsedMilliseconds} ms',
          );
        }
        return image;
      },
      (image) {
        if (_disposed) return;
        spectrogramImage = image;
        _notify();
      },
    );
  }

  Future<void> _refreshEnvelope() async {
    final sound = _sound;
    if (sound == null || _requestedBuckets <= 0) return;
    final gen = ++_envelopeGeneration;
    final vp = viewport;
    try {
      final data = await sound.envelope(
        t0S: vp.t0,
        t1S: vp.t1,
        nBuckets: _requestedBuckets,
      );
      if (_disposed || gen != _envelopeGeneration) return;
      envelope = EnvelopeSlice(vp.t0, vp.t1, data);
      _notify();
    } catch (_) {
      // Sound disposed mid-flight or transient failure; next settle retries.
    }
  }

  // ---- playback -----------------------------------------------------------

  Future<void> togglePlay() async {
    if (playback.playing.value) {
      await playback.pause();
    } else {
      final from = cursorTimeS;
      await playback.play(from: from == null ? null : _toDuration(from));
    }
  }

  /// When set, [playSelection] repeats the selection until paused.
  bool loopSelection = false;

  void toggleLoopSelection() {
    loopSelection = !loopSelection;
    _notify();
  }

  /// Play exactly the selected interval (looped when [loopSelection]).
  Future<void> playSelection() async {
    final sel = selection;
    if (sel == null || sel.span <= 0) return;
    await playback.play(
      from: _toDuration(sel.t0),
      until: _toDuration(sel.t1),
      loop: loopSelection,
    );
  }

  Duration _toDuration(double seconds) =>
      Duration(microseconds: (seconds * 1e6).round());

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _settleTimer?.cancel();
    spectrogramImage = null;
    _sgCache.clear();
    _playback?.dispose();
    _sound?.dispose();
    _sound = null;
    super.dispose();
  }
}
