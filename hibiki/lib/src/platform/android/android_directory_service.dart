import 'dart:io';

import 'package:external_path/external_path.dart';
import 'package:fushi_platform/fushi_platform.dart';
import 'package:path/path.dart' as p;

class AndroidDirectoryService implements PlatformDirectoryService {
  @override
  Future<List<String>> getExternalStorageDirectories() async {
    return await ExternalPath.getExternalStorageDirectories() ?? const [];
  }

  @override
  Future<List<String>> getDefaultPickerDirectories() async {
    return getExternalStorageDirectories();
  }

  @override
  Future<void> excludeFromMediaScanner(String directoryPath) async {
    final noMedia = File(p.join(directoryPath, '.nomedia'));
    if (!noMedia.existsSync()) {
      noMedia.createSync();
    }
  }
}
