import 'dart:io';

import 'package:flutter/material.dart';
import 'package:hibiki/dictionary.dart';
import 'package:hibiki/src/dictionary/hoshidicts.dart';

int fastHash(String string) {
  var hash = 0xcbf29ce484222325;

  var i = 0;
  while (i < string.length) {
    final codeUnit = string.codeUnitAt(i++);
    hash ^= codeUnit >> 8;
    hash *= 0x100000001b3;
    hash ^= codeUnit & 0xFF;
    hash *= 0x100000001b3;
  }

  return hash;
}

Future<HoshiImportResult> importDictionaryViaHoshidicts({
  required String zipPath,
  required String outputDir,
}) async {
  return HoshiDicts.importDictionary(zipPath, outputDir);
}

Future<void> deleteDictionaryDirectory(String directoryPath) async {
  final dir = Directory(directoryPath);
  if (dir.existsSync()) {
    dir.deleteSync(recursive: true);
  }
}

Future<void> depositDictionaryDataHelper(PrepareDictionaryParams params) async {
  debugPrint('[hoshidicts] depositDictionaryDataHelper is now a no-op; '
      'import is handled by HoshiDicts.importDictionary directly');
}

Future<void> deleteDictionariesHelper(DeleteDictionaryParams params) async {
  debugPrint('[hoshidicts] deleteDictionariesHelper is now a no-op; '
      'deletion is handled by removing resource directories');
}

Future<void> deleteDictionaryHelper(DeleteDictionaryParams params) async {
  debugPrint('[hoshidicts] deleteDictionaryHelper is now a no-op; '
      'deletion is handled by removing resource directories');
}
