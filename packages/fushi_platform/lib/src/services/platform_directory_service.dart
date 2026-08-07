abstract class PlatformDirectoryService {
  Future<String> getHibikiExportDirectory();
  Future<List<String>> getExternalStorageDirectories();
  // HBK-AUDIT-137: mediaType was ignored by every impl; dropped so the
  // signature reflects reality.
  Future<List<String>> getDefaultPickerDirectories();
  Future<void> excludeFromMediaScanner(String directoryPath);
}
