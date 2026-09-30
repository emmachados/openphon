import 'database.dart' show Recording;

/// One recording's files in a backup: source paths plus the deduped
/// export stem derived from the display name (display names live only
/// in the database, so the backup must not use the on-disk filenames).
class BackupItem {
  const BackupItem({
    required this.recording,
    required this.wavPath,
    this.gridPath,
    this.editsPath,
    required this.stem,
  });

  final Recording recording;
  final String wavPath;
  final String? gridPath;

  /// Manual pitch corrections (`<stem>.pitchedits.csv`), if any.
  final String? editsPath;
  final String stem;
}

/// Assigns each recording a unique sanitized stem: "name", "name (2)", …
/// (same convention as WAV import).
List<BackupItem> planBackup(
  Iterable<(Recording, String, String?, String?)> rows,
  String Function(String) sanitize,
) {
  final used = <String>{};
  final items = <BackupItem>[];
  for (final (rec, wav, grid, edits) in rows) {
    var stem = sanitize(rec.name);
    if (stem.isEmpty) stem = 'recording';
    var candidate = stem;
    var n = 2;
    while (!used.add(candidate)) {
      candidate = '$stem (${n++})';
    }
    items.add(
      BackupItem(
        recording: rec,
        wavPath: wav,
        gridPath: grid,
        editsPath: edits,
        stem: candidate,
      ),
    );
  }
  return items;
}

String _csv(String s) => s.contains(',') || s.contains('"') || s.contains('\n')
    ? '"${s.replaceAll('"', '""')}"'
    : s;

/// The backup's index: display name, exported files, format facts.
String backupManifestCsv(
  List<BackupItem> items,
  int Function(String path) sizeOf,
) {
  final b = StringBuffer(
    'name,file,textgrid,sample_rate_hz,channels,duration_s,size_bytes,created,'
    'pitch_edits\n',
  );
  for (final it in items) {
    final r = it.recording;
    final duration = r.durationMs == null
        ? ''
        : (r.durationMs! / 1000).toStringAsFixed(3);
    b.writeln(
      [
        _csv(r.name),
        _csv('${it.stem}.wav'),
        it.gridPath == null ? '' : _csv('${it.stem}.TextGrid'),
        '${r.sampleRate}',
        '${r.channels}',
        duration,
        '${sizeOf(it.wavPath)}',
        r.createdAt.toIso8601String(),
        it.editsPath == null ? '' : _csv('${it.stem}.pitchedits.csv'),
      ].join(','),
    );
  }
  return b.toString();
}
