import 'package:fushi_platform/fushi_platform.dart';

class IosDirectoryService implements PlatformDirectoryService {
  @override
  Future<List<String>> getExternalStorageDirectories() async => [];

  @override
  Future<List<String>> getDefaultPickerDirectories() async => [];

  @override
  Future<void> excludeFromMediaScanner(String directoryPath) async {}
}
