import 'package:flutter/material.dart';
import 'package:hibiki/dictionary.dart';
import 'package:hibiki/models.dart';

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

/// Deposit dictionary data into the database.
///
/// Previously used Isar; will be replaced by hoshidicts (C++ FFI).
Future<void> depositDictionaryDataHelper(PrepareDictionaryParams params) async {
  throw UnimplementedError('Will be replaced by hoshidicts');
}

/// Delete all dictionaries from the database.
///
/// Previously used Isar; will be replaced by hoshidicts (C++ FFI).
Future<void> deleteDictionariesHelper(DeleteDictionaryParams params) async {
  throw UnimplementedError('Will be replaced by hoshidicts');
}

/// Delete a single dictionary from the database.
///
/// Previously used Isar; will be replaced by hoshidicts (C++ FFI).
Future<void> deleteDictionaryHelper(DeleteDictionaryParams params) async {
  throw UnimplementedError('Will be replaced by hoshidicts');
}
