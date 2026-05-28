import 'dart:io';

import 'package:hibiki_platform/hibiki_platform.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

class DesktopDirectoryService implements PlatformDirectoryService {
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
  Future<List<String>> getDefaultPickerDirectories(String mediaType) async {
    final result = <String>[];
    if (Platform.isWindows) {
      final userProfile = Platform.environment['USERPROFILE'];
      if (userProfile != null) {
        result.add(p.join(userProfile, 'Documents'));
        result.add(p.join(userProfile, 'Downloads'));
      }
    } else if (Platform.isMacOS || Platform.isLinux) {
      final home = Platform.environment['HOME'];
      if (home != null) {
        result.add(p.join(home, 'Documents'));
        result.add(p.join(home, 'Downloads'));
      }
    }
    return result.where((d) => Directory(d).existsSync()).toList();
  }

  @override
  Future<void> excludeFromMediaScanner(String directoryPath) async {}
}
