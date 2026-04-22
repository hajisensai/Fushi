import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as path;

import 'package:hibiki/dictionary.dart';
import 'package:hibiki/i18n/strings.g.dart';

/// A dictionary format for archives following the ABBYY Lingvo or DSL format
/// compatible with GoldenDict.
///
/// Details on the format can be found here:
/// http://lingvo.helpmax.net/en/troubleshooting/dsl-compiler/dsl-dictionary-structure/
class AbbyyLingvoFormat extends DictionaryFormat {
  /// Define a format with the given metadata that has its behaviour for
  /// import, search and display defined with af set of top-level helper methods.
  AbbyyLingvoFormat._privateConstructor()
      : super(
          uniqueKey: 'abbyy_lingvo',
          name: 'ABBYY Lingvo (DSL)',
          icon: Icons.auto_stories_rounded,
          allowedExtensions: const ['dsl'],
          isTextFormat: true,
          fileType: FileType.any,
          prepareDirectory: prepareDirectoryAbbyyLingvoFormat,
          prepareName: prepareNameAbbyyLingvoFormat,
          prepareEntries: _prepareEntriesAbbyyLingvoStub,
        );

  /// Get the singleton instance of this dictionary format.
  static AbbyyLingvoFormat get instance => _instance;

  static final AbbyyLingvoFormat _instance =
      AbbyyLingvoFormat._privateConstructor();
}

/// Top-level function for use in compute. See [DictionaryFormat] for details.
Future<void> prepareDirectoryAbbyyLingvoFormat(
    PrepareDirectoryParams params) async {
  String dictionaryFilePath =
      path.join(params.resourceDirectory.path, 'dictionary.dsl');
  File originalFile = params.file;
  File newFile = File(dictionaryFilePath);

  if (params.charset.startsWith('UTF-16')) {
    final utf16CodeUnits = originalFile.readAsBytesSync().buffer.asUint16List();
    var converted = String.fromCharCodes(utf16CodeUnits);
    newFile.createSync();
    newFile.writeAsStringSync(converted);
  } else {
    originalFile.copySync(newFile.path);
  }
}

/// Top-level function for use in compute. See [DictionaryFormat] for details.
Future<String> prepareNameAbbyyLingvoFormat(
    PrepareDirectoryParams params) async {
  String dictionaryFilePath =
      path.join(params.resourceDirectory.path, 'dictionary.dsl');
  File dictionaryFile = File(dictionaryFilePath);

  String nameLine =
      dictionaryFile.readAsLinesSync().first.replaceFirst('#NAME', '').trim();

  String name = nameLine.substring(1, nameLine.length - 1);
  return name;
}

/// Stub matching [DictionaryFormat.prepareEntries].
void _prepareEntriesAbbyyLingvoStub({
  required PrepareDictionaryParams params,
  required dynamic database,
}) {
  // No-op: hoshidicts only supports Yomitan format
}

/// Top-level function for use in compute. See [DictionaryFormat] for details.
Future<void> prepareEntriesAbbyyLingvoFormat({
  required PrepareDictionaryParams params,
  required dynamic isar,
}) async {
  int count = 0;

  String dictionaryFilePath =
      path.join(params.resourceDirectory.path, 'dictionary.dsl');
  File dictionaryFile = File(dictionaryFilePath);

  String text = dictionaryFile
      .readAsStringSync()
      .replaceAll('<br>', '\n')
      .replaceAll('[', '<')
      .replaceAll(']', '>')
      .replaceAll('{{', '<')
      .replaceAll('}}', '>')
      .replaceAll('<m0>', '')
      .replaceAll('<m1>', ' ')
      .replaceAll('<m2>', '  ')
      .replaceAll('<m3>', '   ')
      .replaceAll('\\<', '<')
      .replaceAll('\\>', '>')
      .replaceAll('<<', '')
      .replaceAll('>>', '')
      .replaceAll(RegExp('<[^<]+?>'), '');

  List<String> lines = text.split('\n');

  String term = '';

  final buffer = StringBuffer();

  for (String line in lines) {
    if (line.startsWith('#')) {
      continue;
    }

    if (line.characters.isNotEmpty &&
        line.characters.first.codeUnits.first == 9) {
      buffer.writeln(line);
    } else {
      String definition = buffer.toString();
      buffer.clear();

      if (term.isNotEmpty && definition.isNotEmpty) {
        DictionaryEntry entry = DictionaryEntry(
          dictionaryName: params.dictionary.name,
          word: term,
          meaning: definition,
          popularity: 0,
        );

        isar.dictionaryEntrys.putSync(entry);

        params.send(t.import_found_entry(count: count));

        count++;
      }

      term = line.trim();
    }
  }
}
