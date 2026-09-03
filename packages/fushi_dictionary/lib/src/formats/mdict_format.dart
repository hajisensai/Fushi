import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_archive/flutter_archive.dart';
import 'package:path/path.dart' as path;

import '../models/dictionary_operations_params.dart';
import 'dictionary_format.dart';

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

/// 取目录里扩展名为 [ext] 的文件。
///
/// 包里有多个同扩展名文件时，选中哪个会决定词典的显示名
/// （prepareNameMdictFormat），所以不能交给 listSync 的平台顺序：同一个 zip
/// 在 Windows 与 Linux 上导出的名字必须一样。固定取路径字典序最小的那个。
File? _findFileByExtension(Directory dir, String ext) {
  File? best;
  for (final entity in dir.listSync(recursive: true)) {
    if (entity is File && entity.path.toLowerCase().endsWith(ext)) {
      if (best == null || entity.path.compareTo(best.path) < 0) {
        best = entity;
      }
    }
  }
  return best;
}

Future<void> prepareDirectoryMdictFormat(PrepareDirectoryParams params) async {
  final ext = path.extension(params.file.path).toLowerCase();

  if (ext == '.zip') {
    await ZipFile.extractToDirectory(
      zipFile: params.file,
      destinationDir: params.resourceDirectory,
    );
  } else if (ext == '.mdx') {
    params.resourceDirectory.createSync(recursive: true);
    params.file.copySync(path.join(
        params.resourceDirectory.path, path.basename(params.file.path)));
  }

  final mdxFile = _findFileByExtension(params.resourceDirectory, '.mdx');
  if (mdxFile == null) {
    throw Exception('MDX file not found in archive');
  }

  // MDict reading via dict_reader has been removed; will be replaced by
  // fushidicts. Throw so callers know this format is not yet functional.
  // MDict format is not supported by fushidicts; no-op
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
  // Import handled by fushidicts C++ importer (auto-detects MDX format)
}
