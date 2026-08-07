import 'fushidicts.dart';

Future<FushiImportResult> importDictionaryViaFushidicts({
  required String zipPath,
  required String outputDir,
  String breadcrumbDir = '',
}) async {
  return FushiDicts.importDictionary(zipPath, outputDir,
      breadcrumbDir: breadcrumbDir);
}
