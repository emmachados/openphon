import 'annotation_model.dart';

/// UI-agnostic editing engine over an immutable [AnnotationDoc].
///
/// Every operation validates its inputs and returns `true` only if the
/// document changed; failed operations leave document and history untouched.
/// Undo/redo is snapshot-based (cheap because the model is immutable and
/// unchanged tiers are shared between snapshots). Pure Dart on purpose:
/// mouse, touch, and tests all drive the same engine.
class AnnotationEditor {
  AnnotationEditor(AnnotationDoc doc) : _doc = doc, _savedDoc = doc;

  /// An editor whose document does not exist on disk yet ("New TextGrid"):
  /// starts dirty so the UI prompts a save. Implemented by giving the saved
  /// snapshot a distinct identity (dirty is identity-based).
  AnnotationEditor.unsaved(AnnotationDoc doc)
    : _doc = doc,
      _savedDoc = AnnotationDoc(
        xmin: doc.xmin,
        xmax: doc.xmax,
        tiers: doc.tiers,
      );

  /// Shortest interval an edit may produce.
  static const double minIntervalS = 1e-4;

  /// Undo depth cap.
  static const int maxUndo = 200;

  AnnotationDoc _doc;
  AnnotationDoc _savedDoc;
  final List<AnnotationDoc> _undo = [];
  final List<AnnotationDoc> _redo = [];

  AnnotationDoc get doc => _doc;
  bool get canUndo => _undo.isNotEmpty;
  bool get canRedo => _redo.isNotEmpty;

  /// True when the current document differs from the last saved/loaded one.
  /// Identity comparison is sound because the model is immutable.
  bool get dirty => !identical(_doc, _savedDoc);

  void markSaved([AnnotationDoc? saved]) => _savedDoc = saved ?? _doc;

  /// Replaces the document and clears history (load / import / new).
  void replace(AnnotationDoc doc) {
    _doc = doc;
    _savedDoc = doc;
    _undo.clear();
    _redo.clear();
  }

  bool _commit(AnnotationDoc next) {
    _undo.add(_doc);
    if (_undo.length > maxUndo) _undo.removeAt(0);
    _redo.clear();
    _doc = next;
    return true;
  }

  bool undo() {
    if (_undo.isEmpty) return false;
    _redo.add(_doc);
    _doc = _undo.removeLast();
    return true;
  }

  bool redo() {
    if (_redo.isEmpty) return false;
    _undo.add(_doc);
    _doc = _redo.removeLast();
    return true;
  }

  IntervalTierModel? _intervalTier(int tier) {
    if (tier < 0 || tier >= _doc.tiers.length) return null;
    final t = _doc.tiers[tier];
    return t is IntervalTierModel ? t : null;
  }

  PointTierModel? _pointTier(int tier) {
    if (tier < 0 || tier >= _doc.tiers.length) return null;
    final t = _doc.tiers[tier];
    return t is PointTierModel ? t : null;
  }

  /// Moves interior boundary [boundary] (1..n-1, the shared edge between
  /// intervals boundary-1 and boundary) to [t], clamped so both neighbors
  /// keep at least [minIntervalS].
  bool moveBoundary(int tier, int boundary, double t) {
    final it = _intervalTier(tier);
    if (it == null) return false;
    if (boundary < 1 || boundary >= it.intervals.length) return false;
    final left = it.intervals[boundary - 1];
    final right = it.intervals[boundary];
    final lo = left.xmin + minIntervalS;
    final hi = right.xmax - minIntervalS;
    if (lo > hi) return false;
    final nt = t.clamp(lo, hi).toDouble();
    if (nt == left.xmax) return false;
    final intervals = List<Interval>.of(it.intervals);
    intervals[boundary - 1] = Interval(left.xmin, nt, left.text);
    intervals[boundary] = Interval(nt, right.xmax, right.text);
    return _commit(
      _doc.copyWithTier(
        tier,
        IntervalTierModel(name: it.name, intervals: intervals),
      ),
    );
  }

  /// Splits the interval containing [t]. The existing label stays with the
  /// left part (Praat behavior); the right part starts empty.
  bool insertBoundary(int tier, double t) {
    final it = _intervalTier(tier);
    if (it == null) return false;
    final i = it.intervalIndexAt(t);
    if (i < 0) return false;
    final iv = it.intervals[i];
    if (t < iv.xmin + minIntervalS || t > iv.xmax - minIntervalS) return false;
    final intervals = List<Interval>.of(it.intervals);
    intervals[i] = Interval(iv.xmin, t, iv.text);
    intervals.insert(i + 1, Interval(t, iv.xmax, ''));
    return _commit(
      _doc.copyWithTier(
        tier,
        IntervalTierModel(name: it.name, intervals: intervals),
      ),
    );
  }

  /// Removes interior boundary [boundary], merging its two intervals.
  /// Non-empty labels are joined with a space.
  bool removeBoundary(int tier, int boundary) {
    final it = _intervalTier(tier);
    if (it == null) return false;
    if (boundary < 1 || boundary >= it.intervals.length) return false;
    final left = it.intervals[boundary - 1];
    final right = it.intervals[boundary];
    final text = [left.text, right.text].where((s) => s.isNotEmpty).join(' ');
    final intervals = List<Interval>.of(it.intervals);
    intervals[boundary - 1] = Interval(left.xmin, right.xmax, text);
    intervals.removeAt(boundary);
    return _commit(
      _doc.copyWithTier(
        tier,
        IntervalTierModel(name: it.name, intervals: intervals),
      ),
    );
  }

  bool setIntervalText(int tier, int index, String text) {
    final it = _intervalTier(tier);
    if (it == null || index < 0 || index >= it.intervals.length) return false;
    final iv = it.intervals[index];
    if (iv.text == text) return false;
    final intervals = List<Interval>.of(it.intervals);
    intervals[index] = Interval(iv.xmin, iv.xmax, text);
    return _commit(
      _doc.copyWithTier(
        tier,
        IntervalTierModel(name: it.name, intervals: intervals),
      ),
    );
  }

  /// Adds a point at [t]. Fails if [t] is out of range or within
  /// [minIntervalS] of an existing point (coincident points are invalid).
  bool addPoint(int tier, double t, String mark) {
    final pt = _pointTier(tier);
    if (pt == null || t < _doc.xmin || t > _doc.xmax) return false;
    final points = List<AnnotationPoint>.of(pt.points);
    var i = 0;
    while (i < points.length && points[i].time < t) {
      i++;
    }
    final prevOk = i == 0 || t - points[i - 1].time >= minIntervalS;
    final nextOk = i == points.length || points[i].time - t >= minIntervalS;
    if (!prevOk || !nextOk) return false;
    points.insert(i, AnnotationPoint(t, mark));
    return _commit(
      _doc.copyWithTier(tier, PointTierModel(name: pt.name, points: points)),
    );
  }

  bool removePoint(int tier, int index) {
    final pt = _pointTier(tier);
    if (pt == null || index < 0 || index >= pt.points.length) return false;
    final points = List<AnnotationPoint>.of(pt.points)..removeAt(index);
    return _commit(
      _doc.copyWithTier(tier, PointTierModel(name: pt.name, points: points)),
    );
  }

  /// Moves point [index] to [t], clamped inside the document range and
  /// stopped [minIntervalS] short of its neighbors.
  bool movePoint(int tier, int index, double t) {
    final pt = _pointTier(tier);
    if (pt == null || index < 0 || index >= pt.points.length) return false;
    final points = pt.points;
    var lo = _doc.xmin;
    var hi = _doc.xmax;
    if (index > 0) lo = points[index - 1].time + minIntervalS;
    if (index < points.length - 1) hi = points[index + 1].time - minIntervalS;
    if (lo > hi) return false;
    final nt = t.clamp(lo, hi).toDouble();
    if (nt == points[index].time) return false;
    final next = List<AnnotationPoint>.of(points);
    next[index] = AnnotationPoint(nt, points[index].mark);
    return _commit(
      _doc.copyWithTier(tier, PointTierModel(name: pt.name, points: next)),
    );
  }

  bool setPointMark(int tier, int index, String mark) {
    final pt = _pointTier(tier);
    if (pt == null || index < 0 || index >= pt.points.length) return false;
    if (pt.points[index].mark == mark) return false;
    final points = List<AnnotationPoint>.of(pt.points);
    points[index] = AnnotationPoint(points[index].time, mark);
    return _commit(
      _doc.copyWithTier(tier, PointTierModel(name: pt.name, points: points)),
    );
  }
}
