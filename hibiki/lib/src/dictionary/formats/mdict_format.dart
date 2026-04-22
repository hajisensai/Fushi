import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_archive/flutter_archive.dart';
import 'package:path/path.dart' as path;

import 'package:hibiki/dictionary.dart';
import 'package:hibiki/i18n/strings.g.dart';

class MdictFormat extends DictionaryFormat {
  MdictFormat._privateConstructor()
      : super(
          uniqueKey: 'mdict',
          name: 'MDict Dictionary',
          icon: Icons.menu_book_rounded,
          allowedExtensions: const ['zip', 'mdx'],
          isTextFormat: false,
          fileType: FileType.any,
          prepareDirectory: prepareDirectoryMdictFormat,
          prepareName: prepareNameMdictFormat,
          prepareEntries: _prepareEntriesMdictStub,
        );

  static MdictFormat get instance => _instance;
  static final MdictFormat _instance = MdictFormat._privateConstructor();
}

File? _findFileByExtension(Directory dir, String ext) {
  for (final entity in dir.listSync(recursive: true)) {
    if (entity is File && entity.path.toLowerCase().endsWith(ext)) {
      return entity;
    }
  }
  return null;
}

Future<void> prepareDirectoryMdictFormat(
    PrepareDirectoryParams params) async {
  final ext = path.extension(params.file.path).toLowerCase();

  if (ext == '.zip') {
    await ZipFile.extractToDirectory(
      zipFile: params.file,
      destinationDir: params.resourceDirectory,
    );
  } else if (ext == '.mdx') {
    params.resourceDirectory.createSync(recursive: true);
    params.file
        .copySync(path.join(params.resourceDirectory.path, path.basename(params.file.path)));
  }

  final mdxFile = _findFileByExtension(params.resourceDirectory, '.mdx');
  if (mdxFile == null) {
    throw Exception('找不到 .mdx 文件');
  }

  // MDict reading via dict_reader has been removed; will be replaced by
  // hoshidicts. Throw so callers know this format is not yet functional.
  // MDict format is not supported by hoshidicts; no-op
}

Future<String> prepareNameMdictFormat(PrepareDirectoryParams params) async {
  final mdxFile = _findFileByExtension(params.resourceDirectory, '.mdx');
  if (mdxFile != null) {
    return path.basenameWithoutExtension(mdxFile.path);
  }
  return path.basenameWithoutExtension(params.file.path);
}

/// Stub matching [DictionaryFormat.prepareEntries].
void _prepareEntriesMdictStub({
  required PrepareDictionaryParams params,
  required dynamic database,
}) {
  // No-op: hoshidicts only supports Yomitan format
}

void prepareEntriesMdictFormat({
  required PrepareDictionaryParams params,
  required dynamic isar,
}) {
  final entities = params.resourceDirectory.listSync();
  final chunkFiles = entities
      .whereType<File>()
      .where((f) => path.basename(f.path).startsWith('_entries_') &&
          f.path.endsWith('.json'))
      .toList()
    ..sort((a, b) => a.path.compareTo(b.path));

  int count = 0;
  int total = 0;

  for (final file in chunkFiles) {
    final items = jsonDecode(file.readAsStringSync()) as List;
    total += items.length;
  }

  for (final file in chunkFiles) {
    final items = jsonDecode(file.readAsStringSync()) as List;

    for (final item in items) {
      final map = item as Map<String, dynamic>;
      final word = (map['word'] as String).trim();
      final definition = map['definition'] as String;

      if (word.isEmpty) continue;

      final entry = DictionaryEntry(
        dictionaryName: params.dictionary.name,
        word: word,
        meaning: definition,
        popularity: 0,
      );

      isar.dictionaryEntrys.putSync(entry);

      count++;
      if (count % 1000 == 0) {
        params.send(t.import_write_entry(count: count, total: total));
      }
    }

    // Clean up intermediate file after processing
    file.deleteSync();
  }

  params.send(t.import_write_entry(count: count, total: total));
}
