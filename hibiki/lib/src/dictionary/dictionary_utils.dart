import 'package:flutter/material.dart';
import 'package:isar/isar.dart';
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

Future<void> depositDictionaryDataHelper(PrepareDictionaryParams params) async {
  try {
    final Isar isar = await Isar.open(
      globalSchemas,
      directory: params.directoryPath,
      maxSizeMiB: 8192,
    );

    await isar.writeTxnSync(() async {
      params.dictionaryFormat.prepareEntries(params: params, isar: isar);
    });
  } catch (e, stack) {
    debugPrint('$e');
    debugPrint('$stack');
    params.send('$stack');
    rethrow;
  }
}

Future<void> deleteDictionariesHelper(DeleteDictionaryParams params) async {
  final Isar database = await Isar.open(
    globalSchemas,
    directory: params.directoryPath,
    maxSizeMiB: 8192,
  );

  database.writeTxnSync(() {
    database.dictionaryEntrys.clearSync();
  });
}

Future<void> deleteDictionaryHelper(DeleteDictionaryParams params) async {
  final Isar database = await Isar.open(
    globalSchemas,
    directory: params.directoryPath,
    maxSizeMiB: 8192,
  );

  database.writeTxnSync(() {
    database.dictionaryEntrys
        .where()
        .dictionaryNameEqualTo(params.dictionaryName!)
        .deleteAllSync();
  });
}
