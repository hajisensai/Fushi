import 'dart:io';

/// Abstract storage directory provider.
/// Each platform resolves these to appropriate OS-specific locations.
abstract class StoragePaths {
  Future<Directory> get documentsDir;
  Future<Directory> get supportDir;
  Future<Directory> get cacheDir;
}
