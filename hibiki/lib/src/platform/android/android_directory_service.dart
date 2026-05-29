import 'dart:io';

import 'package:external_path/external_path.dart';
import 'package:hibiki_platform/hibiki_platform.dart';
import 'package:path/path.dart' as p;

class AndroidDirectoryService implements PlatformDirectoryService {
  @override
  Future<String> getHibikiExportDirectory() async {
    final dcim = await ExternalPath.getExternalStoragePublicDirectory(
      ExternalPath.DIRECTORY_DCIM,
    );
    final hibikiDir = Directory(p.join(dcim, 'hibiki'));
    if (!hibikiDir.existsSync()) {
      hibikiDir.createSync(recursive: true);
    }
    return hibikiDir.path;
  }

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
