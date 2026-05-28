abstract class PlatformDirectoryService {
  Future<String> getHibikiExportDirectory();
  Future<List<String>> getExternalStorageDirectories();
  Future<List<String>> getDefaultPickerDirectories(String mediaType);
  Future<void> excludeFromMediaScanner(String directoryPath);
}
