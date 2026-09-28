import 'dart:io';

import 'package:path/path.dart' as p;

import '../rust/api/core.dart' as rust;

/// Prepare the replacement beside the original so a failed write cannot
/// truncate the saved annotation. Rename only after the new data is flushed.
Future<void> writeAnnotationAtomically({
  required String path,
  required rust.TextGridData data,
}) async {
  final staging = await Directory(
    p.dirname(path),
  ).createTemp('.openphon_grid_');
  final replacement = File(p.join(staging.path, 'annotation.TextGrid'));
  try {
    await rust.writeTextGrid(path: replacement.path, data: data);
    final handle = await replacement.open(mode: FileMode.append);
    try {
      await handle.flush();
    } finally {
      await handle.close();
    }
    await replacement.rename(path);
  } finally {
    await staging.delete(recursive: true);
  }
}
