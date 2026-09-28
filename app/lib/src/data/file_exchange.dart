import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

const wavFileType = XTypeGroup(
  label: 'WAV',
  extensions: ['wav'],
  mimeTypes: ['audio/x-wav', 'audio/wav'],
  uniformTypeIdentifiers: ['com.microsoft.waveform-audio'],
);

// TextGrid has no system-wide iOS type identifier. Allow documents in the
// picker and validate their contents with the TextGrid parser before import.
const textGridFileType = XTypeGroup(
  label: 'TextGrid',
  extensions: ['TextGrid', 'textgrid'],
  uniformTypeIdentifiers: ['public.data'],
);

/// Copies a picked document to a path the native parser can read. The picker
/// may supply bytes or a provider URI instead of a directly readable path.
Future<T> withLocalDocument<T>(
  XFile file,
  Future<T> Function(String path) read,
) async {
  final directory = await (await getTemporaryDirectory()).createTemp(
    'openphon_import_',
  );
  try {
    final path = p.join(directory.path, 'document${p.extension(file.name)}');
    await file.saveTo(path);
    return await read(path);
  } finally {
    await directory.delete(recursive: true);
  }
}

/// Each export gets its own directory so an earlier share cannot be
/// overwritten while another application is still reading it.
Future<Directory> exportDirectory() async =>
    (await getTemporaryDirectory()).createTemp('openphon_export_');

/// iPad requires a non-empty popover origin inside the presenting view.
/// Resolve it immediately before sharing, after any file work has finished.
Future<ShareResult?> shareFilesFrom(
  BuildContext context,
  List<XFile> files,
) async {
  if (!context.mounted) return null;
  final box = context.findRenderObject() as RenderBox;
  final origin = box.localToGlobal(Offset.zero) & box.size;
  return SharePlus.instance.share(
    ShareParams(files: files, sharePositionOrigin: origin),
  );
}
