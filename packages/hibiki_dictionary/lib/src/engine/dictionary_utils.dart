import 'hoshidicts.dart';

Future<HoshiImportResult> importDictionaryViaHoshidicts({
  required String zipPath,
  required String outputDir,
  String breadcrumbDir = '',
}) async {
  return HoshiDicts.importDictionary(zipPath, outputDir,
      breadcrumbDir: breadcrumbDir);
}
