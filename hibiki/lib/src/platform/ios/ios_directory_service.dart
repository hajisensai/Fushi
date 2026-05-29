import 'dart:io';

import 'package:hibiki_platform/hibiki_platform.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

class IosDirectoryService implements PlatformDirectoryService {
  @override
  Future<String> getHibikiExportDirectory() async {
    final docs = await getApplicationDocumentsDirectory();
    final hibikiDir = Directory(p.join(docs.path, 'Hibiki'));
    if (!hibikiDir.existsSync()) {
      hibikiDir.createSync(recursive: true);
    }
    return hibikiDir.path;
  }

  @override
  Future<List<String>> getExternalStorageDirectories() async => [];

  @override
  Future<List<String>> getDefaultPickerDirectories() async => [];

  @override
  Future<void> excludeFromMediaScanner(String directoryPath) async {}
}
