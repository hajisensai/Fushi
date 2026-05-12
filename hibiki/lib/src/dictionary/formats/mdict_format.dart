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
    throw Exception(t.dictionary_mdx_not_found);
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

void _prepareEntriesMdictStub({
  required PrepareDictionaryParams params,
  required dynamic database,
}) {
  // Import handled by hoshidicts C++ importer (auto-detects MDX format)
}
