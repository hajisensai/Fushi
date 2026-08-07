import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_archive/flutter_archive.dart';
import 'package:path/path.dart' as path;

import '../models/dictionary_operations_params.dart';
import 'dictionary_format.dart';

/// A dictionary format for archives following the ABBYY Lingvo or DSL format
/// compatible with GoldenDict.
///
/// Details on the format can be found here:
/// http://lingvo.helpmax.net/en/troubleshooting/dsl-compiler/dsl-dictionary-structure/
class MigakuFormat extends DictionaryFormat {
  /// Define a format with the given metadata that has its behaviour for
  /// import, search and display defined with af set of top-level helper methods.
  MigakuFormat._privateConstructor()
      : super(
          uniqueKey: 'migaku',
          name: 'Migaku Dictionary',
          icon: Icons.auto_stories_rounded,
          allowedExtensions: const ['zip'],
          isTextFormat: false,
          fileType: FileType.any,
          prepareDirectory: prepareDirectoryMigakuFormat,
          prepareName: prepareNameMigakuFormat,
          prepareEntries: _prepareEntriesMigakuStub,
        );

  /// Get the singleton instance of this dictionary format.
  static MigakuFormat get instance => _instance;

  static final MigakuFormat _instance = MigakuFormat._privateConstructor();
}

/// Top-level function for use in compute. See [DictionaryFormat] for details.
Future<void> prepareDirectoryMigakuFormat(PrepareDirectoryParams params) async {
  await ZipFile.extractToDirectory(
    zipFile: params.file,
    destinationDir: params.resourceDirectory,
  );
}

/// Top-level function for use in compute. See [DictionaryFormat] for details.
Future<String> prepareNameMigakuFormat(PrepareDirectoryParams params) async {
  File originalFile = params.file;
  return path.basenameWithoutExtension(originalFile.path);
}

/// Stub matching [DictionaryFormat.prepareEntries].
void _prepareEntriesMigakuStub({
  required PrepareDictionaryParams params,
  required dynamic database,
}) {
  // No-op: hoshidicts only supports Yomitan format
}
