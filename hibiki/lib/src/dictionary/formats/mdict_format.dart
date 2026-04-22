import 'dart:convert';
import 'dart:io';

import 'package:dict_reader/dict_reader.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_archive/flutter_archive.dart';
import 'package:isar/isar.dart';
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
          prepareEntries: prepareEntriesMdictFormat,
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

  params.send(t.import_extract);

  final dictReader = DictReader(mdxFile.path);
  await dictReader.initDict();

  final entries = <Map<String, String>>[];
  int count = 0;
  const chunkSize = 5000;
  int chunkIndex = 0;

  try {
    await for (final record in dictReader.readWithMdxData()) {
      final key = record.keyText.trim();
      if (key.isEmpty) continue;

      entries.add({
        'word': key,
        'definition': record.data,
      });
      count++;

      if (count % 1000 == 0) {
        params.send(t.import_found_entry(count: count));
      }

      if (entries.length >= chunkSize) {
        final chunkFile = File(
            path.join(params.resourceDirectory.path, '_entries_$chunkIndex.json'));
        chunkFile.writeAsStringSync(jsonEncode(entries));
        entries.clear();
        chunkIndex++;
      }
    }
  } catch (_) {
    // dict_reader may throw RangeError on some MDict files; save what we have
  }

  if (entries.isNotEmpty) {
    final chunkFile = File(
        path.join(params.resourceDirectory.path, '_entries_$chunkIndex.json'));
    chunkFile.writeAsStringSync(jsonEncode(entries));
  }

  await dictReader.close();
  params.send(t.import_found_entry(count: count));

  // Extract MDD resources (CSS, images, audio) if present
  final mddFile = _findFileByExtension(params.resourceDirectory, '.mdd');
  if (mddFile != null) {
    try {
      final mddReader = DictReader(mddFile.path);
      await mddReader.initDict();

      await for (final record in mddReader.readWithMddData()) {
        final resourcePath = record.keyText
            .replaceAll('\\', '/')
            .replaceFirst(RegExp(r'^/'), '');
        if (resourcePath.isEmpty) continue;

        final outFile =
            File(path.join(params.resourceDirectory.path, resourcePath));
        outFile.parent.createSync(recursive: true);
        outFile.writeAsBytesSync(record.data);
      }

      await mddReader.close();
    } catch (_) {
      // MDD extraction is best-effort
    }
  }
}

Future<String> prepareNameMdictFormat(PrepareDirectoryParams params) async {
  final mdxFile = _findFileByExtension(params.resourceDirectory, '.mdx');
  if (mdxFile != null) {
    try {
      final dictReader = DictReader(mdxFile.path);
      await dictReader.initDict(readKeys: false, readRecordBlockInfo: false);
      final title = dictReader.header['Title'] ?? '';
      await dictReader.close();
      if (title.isNotEmpty) return title.trim();
    } catch (_) {}
    return path.basenameWithoutExtension(mdxFile.path);
  }
  return path.basenameWithoutExtension(params.file.path);
}

void prepareEntriesMdictFormat({
  required PrepareDictionaryParams params,
  required Isar isar,
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
