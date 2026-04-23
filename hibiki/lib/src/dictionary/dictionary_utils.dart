import 'package:hibiki/src/dictionary/hoshidicts.dart';

Future<HoshiImportResult> importDictionaryViaHoshidicts({
  required String zipPath,
  required String outputDir,
}) async {
  return HoshiDicts.importDictionary(zipPath, outputDir);
}
