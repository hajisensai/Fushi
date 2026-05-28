import 'package:hibiki_platform/hibiki_platform.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;

class IosDirectoryService implements PlatformDirectoryService {
  @override
  Future<String> getHibikiExportDirectory() async {
    final docs = await getApplicationDocumentsDirectory();
    return p.join(docs.path, 'Hibiki');
  }

  @override
  Future<List<String>> getExternalStorageDirectories() async => [];

  @override
  Future<List<String>> getDefaultPickerDirectories(String mediaType) async =>
      [];

  @override
  Future<void> excludeFromMediaScanner(String directoryPath) async {}
}
