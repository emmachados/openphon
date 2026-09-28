import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

const _storageChannel = MethodChannel('app.openphon/storage');

/// Android exclusions are in the release manifest and backup rules. iOS
/// directory attributes must be set before the database or library is opened.
Future<void> preparePrivateStorage() async {
  if (kIsWeb || defaultTargetPlatform != TargetPlatform.iOS) return;
  final excluded = await _storageChannel.invokeMethod<bool>(
    'excludeLibraryFromBackup',
  );
  if (excluded != true) {
    throw StateError('The library could not be excluded from system backups.');
  }
}
