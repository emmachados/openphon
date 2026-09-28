import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:drift/drift.dart' show Value;
import 'package:file_selector/file_selector.dart'
    show XFile, XTypeGroup, getDirectoryPath, getSaveLocation, openFiles;
import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, kDebugMode, kIsWeb, TargetPlatform;
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../../l10n/app_localizations.dart';
import '../analysis/analysis_controller.dart';
import '../analysis/analysis_settings.dart';
import '../analysis/measurements.dart';
import '../annotation/annotation_model.dart';
import '../audio/recorder_service.dart';
import '../audio/wav_math.dart';
import '../data/app_prefs.dart';
import '../data/database.dart';
import '../data/file_exchange.dart';
import '../data/library_backup.dart';
import '../data/wav_import.dart';
import '../rust/api/core.dart' as rust_core;
import 'analysis/analysis_view.dart';
import 'breakpoints.dart';
import 'settings_page.dart';
import 'tile_meta.dart';

class HomePage extends StatefulWidget {
  const HomePage({
    super.key,
    required this.db,
    required this.prefs,
    this.controllerFactory,
  });

  final AppDatabase db;
  final AppPrefs prefs;
  final AnalysisController Function(Recording recording)? controllerFactory;

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final RecorderService _recorder = RecorderService();
  bool _recording = false;
  DateTime? _recordingStart;
  StreamSubscription<double>? _levelSub;
  DateTime? _lastClipAt;

  /// Options captured when the active take started, so a mid-recording
  /// settings change cannot skew the fallback duration math at stop.
  RecordingOptions? _activeRecordingOptions;

  final TileMetaCache _tileMeta = TileMetaCache();

  Future<TileMeta> _metaFor(Recording r) async =>
      _tileMeta.load(await toAbsolutePath(r.relativePath));
  Timer? _ticker;
  int? _selectedId;

  final _analysisKey = GlobalKey<AnalysisViewState>();
  String? _selectedName;
  bool _changingRecording = false;

  void _refreshMetadata() {
    if (mounted) setState(_tileMeta.clear);
  }

  Future<void> _selectRecording(Recording? recording) async {
    if (_changingRecording || recording?.id == _selectedId) return;
    _changingRecording = true;
    try {
      final leave = await _analysisKey.currentState?.confirmLeave() ?? true;
      if (!leave || !mounted) return;
      setState(() {
        _selectedId = recording?.id;
        _selectedName = recording?.name;
        _tileMeta.clear();
      });
    } finally {
      _changingRecording = false;
    }
  }

  /// Picks WAV files and copies them into the library. Validation happens
  /// on the copy via the Rust WAV parser; anything it rejects is removed
  /// again and counted as skipped.
  Future<void> _importAudio() async {
    try {
      await _importAudioInner();
    } catch (e) {
      if (mounted) _snack(AppLocalizations.of(context)!.importFailed('$e'));
    }
  }

  Future<void> _importAudioInner() async {
    final files = await openFiles(acceptedTypeGroups: [wavFileType]);
    if (files.isEmpty) return;
    final root = await libraryRoot();
    final dir = Directory(p.join(root.path, 'recordings'));
    var imported = 0;
    var skipped = 0;
    String? lastDetail;
    for (final f in files) {
      final outcome = await importWav(
        f,
        recordingsDir: dir,
        sanitizedStem: sanitizeFileName(p.basenameWithoutExtension(f.name)),
        probe: (path) async {
          final info = await rust_core.wavInfo(path: path);
          return WavProbe(
            sampleRate: info.sampleRate,
            channels: info.channels,
            durationS: info.durationS,
          );
        },
      );
      if (outcome.status == WavImportStatus.imported) {
        await widget.db.addRecording(
          RecordingsCompanion.insert(
            name: outcome.name!,
            relativePath: await toRelativePath(outcome.destPath!),
            createdAt: DateTime.now(),
            durationMs: Value(outcome.durationMs!),
            sampleRate: outcome.sampleRate!,
            channels: Value(outcome.channels!),
          ),
        );
        imported++;
      } else {
        skipped++;
        lastDetail = outcome.detail;
      }
    }
    if (mounted) {
      final l10n = AppLocalizations.of(context)!;
      // A lone failed file gets the parser's actual message (it says how
      // to fix the problem, e.g. the too-long guard); batches keep counts.
      final text = skipped == 1 && imported == 0 && lastDetail != null
          ? l10n.importFailed(lastDetail)
          : skipped == 0
          ? l10n.importResultOk(imported)
          : l10n.importResultSkipped(imported, skipped);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
    }
  }

  /// Debug-only: register WAVs that exist in the recordings folder but not
  /// in the library (e.g. test files copied in by hand).
  Future<void> _rescanFolder() async {
    final root = await libraryRoot();
    final dir = Directory(p.join(root.path, 'recordings'));
    if (!await dir.exists()) return;
    final known = (await widget.db.watchLibrary().first)
        .map((r) => r.relativePath)
        .toSet();
    var added = 0;
    await for (final f in dir.list()) {
      if (f is! File || !f.path.toLowerCase().endsWith('.wav')) continue;
      final rel = await toRelativePath(f.path);
      if (known.contains(rel)) continue;
      try {
        final info = await rust_core.wavInfo(path: f.path);
        await widget.db.addRecording(
          RecordingsCompanion.insert(
            name: p.basenameWithoutExtension(f.path),
            relativePath: rel,
            createdAt: (await f.stat()).modified,
            durationMs: Value((info.durationS * 1000).round()),
            sampleRate: info.sampleRate,
            channels: Value(info.channels),
          ),
        );
        added++;
      } catch (_) {
        // Unreadable file: skip.
      }
    }
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(AppLocalizations.of(context)!.rescanResult(added)),
        ),
      );
    }
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _levelSub?.cancel();
    _recorder.dispose();
    super.dispose();
  }

  /// In flight while a toggle (including the permission dialog) is pending;
  /// duplicate taps — easy on touch screens — must not stop-and-restart.
  bool _toggling = false;

  Future<void> _toggleRecording() async {
    if (_toggling) return;
    _toggling = true;
    try {
      await _toggleRecordingInner();
    } catch (e) {
      if (mounted) _snack(AppLocalizations.of(context)!.recordingFailed('$e'));
    } finally {
      _toggling = false;
    }
  }

  Future<void> _toggleRecordingInner() async {
    final l10n = AppLocalizations.of(context)!;
    if (_recording) {
      final path = await _recorder.stop();
      _ticker?.cancel();
      await _levelSub?.cancel();
      _levelSub = null;
      _lastClipAt = null;
      setState(() => _recording = false);
      if (path == null) return;
      final file = File(path);
      if (!await file.exists()) return;
      // Truth from the file header: the device may not have honored the
      // requested sample rate. Byte math against the rate captured at
      // start() is only the fallback for an unparseable header.
      int sampleRate;
      int channels;
      int? durationMs;
      try {
        final info = await rust_core.wavInfo(path: path);
        sampleRate = info.sampleRate;
        channels = info.channels;
        durationMs = (info.durationS * 1000).round();
      } catch (_) {
        final requested = _activeRecordingOptions ?? const RecordingOptions();
        sampleRate = requested.sampleRate;
        channels = kChannels;
        durationMs = wavDurationMs(
          fileBytes: await file.length(),
          sampleRate: sampleRate,
          channels: channels,
        );
      }
      await widget.db.addRecording(
        RecordingsCompanion.insert(
          name: l10n.defaultRecordingName(_stamp()),
          relativePath: await toRelativePath(path),
          createdAt: DateTime.now(),
          durationMs: Value.absentIfNull(durationMs),
          sampleRate: sampleRate,
          channels: Value(channels),
        ),
      );
    } else {
      if (!await _recorder.hasPermission()) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                AppLocalizations.of(context)!.microphonePermissionDenied,
              ),
            ),
          );
        }
        return;
      }
      _activeRecordingOptions = widget.prefs.recordingOptions;
      await _recorder.start(options: _activeRecordingOptions!);
      _levelSub = _recorder.levelDbfs().listen((db) {
        if (db >= clipThresholdDbfs && mounted) {
          setState(() => _lastClipAt = DateTime.now());
        }
      });
      _recordingStart = DateTime.now();
      _ticker = Timer.periodic(
        const Duration(seconds: 1),
        (_) => setState(() {}),
      );
      setState(() => _recording = true);
    }
  }

  String _stamp() {
    final now = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    return '${now.year}-${two(now.month)}-${two(now.day)} '
        '${two(now.hour)}:${two(now.minute)}';
  }

  bool get _useShareSheet =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS);

  void _snack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  /// Library-wide measurement export, the in-app twin of the CLI's
  /// directory mode: every recording with a sibling TextGrid contributes
  /// its first interval tier's labelled intervals, measured at the default
  /// analysis parameters, to one CSV with a leading `file` column (the
  /// recording's display name).
  Future<void> _exportLibraryMeasurements() async {
    final l10n = AppLocalizations.of(context)!;
    final recordings = await widget.db.watchLibrary().first;
    final progress = ValueNotifier<String>('');
    if (!mounted) return;
    // Barrier-only progress dialog; popped in the finally below.
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        content: ValueListenableBuilder<String>(
          valueListenable: progress,
          builder: (context, label, _) => Row(
            children: [
              const CircularProgressIndicator(),
              const SizedBox(width: 16),
              Expanded(child: Text(label)),
            ],
          ),
        ),
      ),
    );
    final files = <FileMeasures>[];
    try {
      const s = AnalysisSettings();
      for (var i = 0; i < recordings.length; i++) {
        final r = recordings[i];
        progress.value = l10n.measuringProgress(i + 1, recordings.length);
        final abs = await toAbsolutePath(r.relativePath);
        final grid = await findSiblingTextGrid(abs);
        if (grid == null) continue;
        try {
          final doc = AnnotationDoc.fromTextGrid(
            await rust_core.readTextGrid(path: grid.path),
          );
          final tier = doc.tiers.whereType<IntervalTierModel>().firstOrNull;
          if (tier == null) continue;
          final rows = measureIntervals(
            tier,
            f0: await rust_core.f0Track(
              path: abs,
              timeStepS: s.trackTimeStepS,
              f0MinHz: s.pitchFloorHz,
              f0MaxHz: s.pitchCeilingHz,
            ),
            intensity: await rust_core.intensityTrack(
              path: abs,
              timeStepS: s.trackTimeStepS,
              minPitchHz: s.intensityMinPitchHz,
            ),
            formants: await rust_core.formantTrack(
              path: abs,
              timeStepS: s.trackTimeStepS,
              maxFormants: s.maxFormants,
              ceilingHz: s.formantCeilingHz,
            ),
          );
          if (rows.isEmpty) continue;
          files.add(
            FileMeasures(
              file: sanitizeFileName(r.name),
              tierName: tier.name,
              rows: rows,
            ),
          );
        } catch (_) {
          // Unreadable audio or TextGrid: skip, keep the batch going.
        }
      }
    } finally {
      if (mounted) Navigator.of(context, rootNavigator: true).pop();
    }
    if (!mounted) return;
    if (files.isEmpty) {
      _snack(l10n.noAnnotatedRecordings);
      return;
    }
    final csv = batchMeasurementsCsv(files);
    final rowCount = files.fold<int>(0, (n, f) => n + f.rows.length);
    if (_useShareSheet) {
      try {
        final dir = await exportDirectory();
        final path = '${dir.path}/library_measures.csv';
        await File(path).writeAsString(csv);
        if (!mounted) return;
        await shareFilesFrom(context, [XFile(path, mimeType: 'text/csv')]);
      } catch (e) {
        _snack(l10n.exportFailed('$e'));
      }
      return;
    }
    const csvType = XTypeGroup(label: 'CSV', extensions: ['csv']);
    final location = await getSaveLocation(
      suggestedName: 'library_measures.csv',
      acceptedTypeGroups: const [csvType],
    );
    if (location == null || !mounted) return;
    try {
      await File(location.path).writeAsString(csv);
      _snack(l10n.libraryMeasurementsExported(rowCount, files.length));
    } catch (e) {
      _snack(l10n.exportFailed('$e'));
    }
  }

  /// Copies every recording (WAV + sibling TextGrid) plus a manifest.csv
  /// out of app-private storage, which uninstalling the app erases.
  /// Desktop: into a picked directory. Mobile: dart:io cannot write into
  /// SAF tree URIs, so all files go through one multi-file share instead
  /// (fine for dozens of recordings; Android intent size limits would
  /// bite at thousands).
  Future<void> _backupLibrary() async {
    final l10n = AppLocalizations.of(context)!;
    final recordings = await widget.db.watchLibrary().first;
    if (recordings.isEmpty) {
      _snack(l10n.libraryEmpty);
      return;
    }
    final rows = <(Recording, String, String?)>[];
    for (final r in recordings) {
      final abs = await toAbsolutePath(r.relativePath);
      final grid = await findSiblingTextGrid(abs);
      rows.add((r, abs, grid?.path));
    }
    final items = planBackup(rows, sanitizeFileName);
    int sizeOf(String path) {
      try {
        return File(path).lengthSync();
      } catch (_) {
        return 0;
      }
    }

    final manifest = backupManifestCsv(items, sizeOf);
    try {
      if (_useShareSheet) {
        final tmp = await exportDirectory();
        final files = <XFile>[];
        for (final it in items) {
          final wavDest = p.join(tmp.path, '${it.stem}.wav');
          await File(it.wavPath).copy(wavDest);
          files.add(XFile(wavDest, mimeType: 'audio/x-wav'));
          final grid = it.gridPath;
          if (grid != null) {
            final gridDest = p.join(tmp.path, '${it.stem}.TextGrid');
            await File(grid).copy(gridDest);
            files.add(XFile(gridDest, mimeType: 'text/plain'));
          }
        }
        final manifestPath = p.join(tmp.path, 'manifest.csv');
        await File(manifestPath).writeAsString(manifest);
        files.add(XFile(manifestPath, mimeType: 'text/csv'));
        if (!mounted) return;
        await shareFilesFrom(context, files);
        return;
      }
      final dirPath = await getDirectoryPath();
      if (dirPath == null || !mounted) return;
      for (final it in items) {
        await File(it.wavPath).copy(p.join(dirPath, '${it.stem}.wav'));
        final grid = it.gridPath;
        if (grid != null) {
          await File(grid).copy(p.join(dirPath, '${it.stem}.TextGrid'));
        }
      }
      await File(p.join(dirPath, 'manifest.csv')).writeAsString(manifest);
      _snack(l10n.backupDone(items.length));
    } catch (e) {
      _snack(l10n.exportFailed('$e'));
    }
  }

  @override
  Widget build(BuildContext context) {
    final expanded = isExpanded(context);
    return PopScope<void>(
      canPop: _selectedId == null,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _selectRecording(null);
      },
      child: Scaffold(
        appBar: AppBar(
          leading: _selectedId == null
              ? null
              : BackButton(onPressed: () => _selectRecording(null)),
          title: Text(
            !expanded && _selectedName != null
                ? _selectedName!
                : AppLocalizations.of(context)!.appTitle,
          ),
          actions: [
            if (expanded || _selectedId == null) ...[
              if (kDebugMode)
                IconButton(
                  icon: const Icon(Icons.refresh),
                  tooltip: AppLocalizations.of(context)!.rescanTooltip,
                  onPressed: _rescanFolder,
                ),
              IconButton(
                icon: const Icon(Icons.library_add_outlined),
                tooltip: AppLocalizations.of(context)!.importAudioTooltip,
                onPressed: _importAudio,
              ),
              IconButton(
                icon: const Icon(Icons.settings_outlined),
                tooltip: AppLocalizations.of(context)!.settings,
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => SettingsPage(prefs: widget.prefs),
                  ),
                ),
              ),
              PopupMenuButton<String>(
                onSelected: (v) {
                  if (v == 'measure_all') _exportLibraryMeasurements();
                  if (v == 'backup') _backupLibrary();
                },
                itemBuilder: (context) => [
                  PopupMenuItem(
                    value: 'measure_all',
                    child: Text(
                      AppLocalizations.of(context)!.exportLibraryMeasurements,
                    ),
                  ),
                  PopupMenuItem(
                    value: 'backup',
                    child: Text(
                      AppLocalizations.of(context)!.backupLibraryMenu,
                    ),
                  ),
                ],
              ),
            ],
          ],
        ),
        // In the expanded layout the FAB docks over the list pane so it
        // never covers the analysis transport controls on the right.
        floatingActionButtonLocation: expanded
            ? FloatingActionButtonLocation.startFloat
            : FloatingActionButtonLocation.endFloat,
        floatingActionButton: !expanded && _selectedId != null
            ? null
            : Builder(
                builder: (context) {
                  final l10n = AppLocalizations.of(context)!;
                  final scheme = Theme.of(context).colorScheme;
                  // Lit for a hold period after any near-full-scale level reading;
                  // the 1 s elapsed-label ticker also retires it.
                  final clipping =
                      _recording &&
                      clipIndicatorActive(_lastClipAt, DateTime.now());
                  return FloatingActionButton.extended(
                    onPressed: _toggleRecording,
                    icon: Icon(_recording ? Icons.stop : Icons.mic),
                    label: Text(
                      !_recording
                          ? l10n.record
                          : clipping
                          ? l10n.clippingWarning(_elapsedLabel(l10n))
                          : _elapsedLabel(l10n),
                    ),
                    backgroundColor: !_recording
                        ? null
                        : clipping
                        ? scheme.error
                        : scheme.errorContainer,
                    foregroundColor: _recording && clipping
                        ? scheme.onError
                        : null,
                  );
                },
              ),
        body: StreamBuilder<List<Recording>>(
          stream: widget.db.watchLibrary(),
          builder: (context, snapshot) {
            final items = snapshot.data ?? const <Recording>[];
            if (items.isEmpty) {
              return const _EmptyLibrary();
            }
            final list = ListView.builder(
              itemCount: items.length,
              itemBuilder: (context, i) => _RecordingTile(
                recording: items[i],
                meta: _metaFor(items[i]),
                selected: expanded && items[i].id == _selectedId,
                onTap: () => _selectRecording(items[i]),
                onDelete: () => _delete(items[i]),
                onExport: () => _exportPair(items[i]),
                onRename: () => _rename(items[i]),
              ),
            );
            Recording? selected;
            for (final r in items) {
              if (r.id == _selectedId) selected = r;
            }
            final analysis = selected == null
                ? null
                : AnalysisView(
                    key: _analysisKey,
                    recording: selected,
                    db: widget.db,
                    prefs: widget.prefs,
                    defaultSettings: widget.prefs.defaultAnalysisSettings,
                    controllerFactory: widget.controllerFactory,
                    onAnnotationSaved: _refreshMetadata,
                  );
            if (!expanded) {
              return analysis == null
                  ? list
                  : SafeArea(top: false, child: analysis);
            }
            return Row(
              children: [
                SizedBox(width: 360, child: list),
                const VerticalDivider(width: 1),
                Expanded(
                  child: selected == null
                      ? Center(
                          child: Text(
                            AppLocalizations.of(context)!.selectRecordingHint,
                          ),
                        )
                      : analysis!,
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  String _elapsedLabel(AppLocalizations l10n) {
    final start = _recordingStart;
    if (start == null) return l10n.stop;
    final s = DateTime.now().difference(start).inSeconds;
    return l10n.stopElapsed(
      '${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}',
    );
  }

  Future<void> _delete(Recording r) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(AppLocalizations.of(context)!.deleteRecordingTitle(r.name)),
        content: Text(AppLocalizations.of(context)!.deleteRecordingBody),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(AppLocalizations.of(context)!.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(AppLocalizations.of(context)!.delete),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    final abs = await toAbsolutePath(r.relativePath);
    final file = File(abs);
    if (await file.exists()) await file.delete();
    final grid = await findSiblingTextGrid(abs);
    if (grid != null) await grid.delete();
    await widget.db.deleteRecording(r.id);
    if (mounted) {
      setState(() {
        if (_selectedId == r.id) {
          _selectedId = null;
          _selectedName = null;
        }
        _tileMeta.clear();
      });
    }
  }

  Future<void> _rename(Recording r) async {
    final controller = TextEditingController(text: r.name);
    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(AppLocalizations.of(context)!.renameRecordingTitle),
        content: TextField(
          controller: controller,
          autofocus: true,
          onSubmitted: (v) => Navigator.pop(context, v),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(AppLocalizations.of(context)!.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text),
            child: Text(AppLocalizations.of(context)!.rename),
          ),
        ],
      ),
    );
    controller.dispose();
    final trimmed = name?.trim();
    if (trimmed == null || trimmed.isEmpty || trimmed == r.name) return;
    await widget.db.renameRecording(r.id, trimmed);
    if (mounted && _selectedId == r.id) setState(() => _selectedName = trimmed);
  }

  /// Copies the WAV and its sibling TextGrid (if any) into a directory the
  /// user picks, under a shared sanitized stem so the pair stays paired in
  /// Praat. Exports the on-disk state; unsaved edits need a save first.
  Future<void> _exportPair(Recording r) async {
    try {
      await _exportPairInner(r);
    } catch (e) {
      if (mounted) _snack(AppLocalizations.of(context)!.exportFailed('$e'));
    }
  }

  Future<void> _exportPairInner(Recording r) async {
    if (_useShareSheet) {
      final abs = await toAbsolutePath(r.relativePath);
      final dir = await exportDirectory();
      final written = await exportPairTo(dir.path, abs, r.name);
      final stem = sanitizeFileName(r.name);
      final files = [
        XFile(p.join(dir.path, '$stem.wav'), mimeType: 'audio/x-wav'),
        if (written == 2)
          XFile(p.join(dir.path, '$stem.TextGrid'), mimeType: 'text/plain'),
      ];
      if (!mounted) return;
      await shareFilesFrom(context, files);
      return;
    }
    final dir = await getDirectoryPath();
    if (dir == null) return;
    final abs = await toAbsolutePath(r.relativePath);
    final stem = sanitizeFileName(r.name);
    final wavTarget = p.join(dir, '$stem.wav');
    final grid = await findSiblingTextGrid(abs);
    final gridTarget = p.join(dir, '$stem.TextGrid');
    final clash =
        await File(wavTarget).exists() ||
        (grid != null && await File(gridTarget).exists());
    if (clash && mounted) {
      final overwrite = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(AppLocalizations.of(context)!.overwriteTitle),
          content: Text(AppLocalizations.of(context)!.overwriteBody(stem)),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text(AppLocalizations.of(context)!.cancel),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text(AppLocalizations.of(context)!.overwrite),
            ),
          ],
        ),
      );
      if (overwrite != true) return;
    }
    if (!mounted) return;
    final l10n = AppLocalizations.of(context)!;
    String message;
    try {
      final written = await exportPairTo(dir, abs, r.name);
      message = written == 2
          ? l10n.exportedPair(stem)
          : l10n.exportedWavOnly(stem);
    } catch (e) {
      message = l10n.exportFailed('$e');
    }
    if (mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(message)));
    }
  }
}

class _RecordingTile extends StatelessWidget {
  const _RecordingTile({
    required this.recording,
    required this.meta,
    required this.selected,
    required this.onTap,
    required this.onDelete,
    required this.onExport,
    required this.onRename,
  });

  final Recording recording;
  final Future<TileMeta> meta;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback onDelete;
  final VoidCallback onExport;
  final VoidCallback onRename;

  @override
  Widget build(BuildContext context) {
    final d = recording.durationMs;
    final duration = d == null
        ? ''
        : '${d ~/ 60000}:${((d % 60000) ~/ 1000).toString().padLeft(2, '0')}';
    return FutureBuilder<TileMeta>(
      future: meta,
      builder: (context, snapshot) {
        final m = snapshot.data;
        final envelope = m?.envelope;
        final quality = formatQuality(m?.clippedPct, m?.estSnrDb);
        final poor = isPoorQuality(m?.clippedPct, m?.estSnrDb);
        final subtitle = [
          duration,
          '${recording.sampleRate} Hz',
          '${recording.channels} ch',
          if (m?.sizeBytes != null) formatBytes(m!.sizeBytes!),
          ?quality,
        ].where((s) => s.isNotEmpty).join(' · ');
        return ListTile(
          selected: selected,
          onTap: onTap,
          leading: envelope == null
              ? const Icon(Icons.graphic_eq)
              : ExcludeSemantics(
                  child: SizedBox(
                    width: 72,
                    height: 40,
                    child: CustomPaint(
                      painter: _EnvelopeThumb(
                        envelope,
                        Theme.of(context).colorScheme.primary,
                      ),
                    ),
                  ),
                ),
          title: Row(
            children: [
              Flexible(
                child: Text(recording.name, overflow: TextOverflow.ellipsis),
              ),
              if (m?.hasTextGrid ?? false) ...[
                const SizedBox(width: 6),
                Icon(
                  Icons.notes,
                  size: 14,
                  semanticLabel: AppLocalizations.of(context)!.textGridBadge,
                  color: Theme.of(context).colorScheme.primary,
                ),
              ],
            ],
          ),
          subtitle: Text(
            subtitle,
            style: poor
                ? TextStyle(color: Theme.of(context).colorScheme.error)
                : null,
          ),
          trailing: PopupMenuButton<String>(
            tooltip: AppLocalizations.of(context)!.recordingActions,
            onSelected: (v) {
              switch (v) {
                case 'rename':
                  onRename();
                case 'export':
                  onExport();
                case 'delete':
                  onDelete();
              }
            },
            itemBuilder: (context) => [
              PopupMenuItem(
                value: 'rename',
                child: Text(AppLocalizations.of(context)!.rename),
              ),
              PopupMenuItem(
                value: 'export',
                child: Text(AppLocalizations.of(context)!.exportPairMenu),
              ),
              PopupMenuItem(
                value: 'delete',
                child: Text(AppLocalizations.of(context)!.delete),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// Tiny min/max waveform bars for the library tile.
class _EnvelopeThumb extends CustomPainter {
  const _EnvelopeThumb(this.envelope, this.color);

  final List<double> envelope;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    if (envelope.isEmpty) return;
    final paint = Paint()
      ..color = color
      ..strokeWidth = math.max(1.0, size.width / envelope.length - 0.5)
      ..strokeCap = StrokeCap.round;
    final mid = size.height / 2;
    for (var i = 0; i < envelope.length; i++) {
      final x = (i + 0.5) * size.width / envelope.length;
      // Minimum stub so silence still reads as a waveform strip.
      final h = math.max(1.0, envelope[i] * mid);
      canvas.drawLine(Offset(x, mid - h), Offset(x, mid + h), paint);
    }
  }

  @override
  bool shouldRepaint(_EnvelopeThumb old) =>
      old.color != color || !identical(old.envelope, envelope);
}

class _EmptyLibrary extends StatelessWidget {
  const _EmptyLibrary();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.mic_none,
            size: 56,
            color: Theme.of(context).colorScheme.outline,
          ),
          const SizedBox(height: 12),
          Text(
            AppLocalizations.of(context)!.noRecordingsYet,
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 4),
          Text(AppLocalizations.of(context)!.tapRecordHint),
        ],
      ),
    );
  }
}
