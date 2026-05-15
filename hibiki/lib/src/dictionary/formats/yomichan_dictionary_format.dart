import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:archive/archive.dart' as archive;
import 'package:archive/archive_io.dart' as archive_io;
import 'package:async_zip/async_zip.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:html/dom.dart' as dom;
import 'package:path/path.dart' as path;
import 'package:recase/recase.dart';
import 'package:hibiki/dictionary.dart';

/// A dictionary format for archives following the latest Yomichan bank schema.
/// Example dictionaries for this format may be downloaded from the Yomichan
/// website.
///
/// Details on the format can be found here:
/// https://github.com/FooSoft/yomichan/blob/master/ext/data/schemas/dictionary-term-bank-v3-schema.json
class YomichanFormat extends DictionaryFormat {
  /// Define a format with the given metadata that has its behaviour for
  /// import, search and display defined with af set of top-level helper methods.
  YomichanFormat._privateConstructor()
      : super(
          uniqueKey: 'yomichan',
          name: 'Yomitan Dictionary',
          icon: Icons.auto_stories_rounded,
          allowedExtensions: const ['zip'],
          isTextFormat: false,
          fileType: FileType.custom,
          prepareDirectory: prepareDirectoryYomichanFormat,
          prepareName: prepareNameYomichanFormat,
          prepareEntries: _prepareEntriesYomichanStub,
        );

  /// Get the singleton instance of this dictionary format.
  static YomichanFormat get instance => _instance;

  static final YomichanFormat _instance = YomichanFormat._privateConstructor();

  /// Recursively get HTML for a structured content definition.
  static String getStructuredContentHtml(dynamic content) {
    if (content is Map) {
      return getNodeHtml(
        tag: content['tag'],
        content: getStructuredContentHtml(content['content']),
        style: getStyle(
          content['style'] ?? {},
        ),
      );
    } else if (content is List) {
      return content.map(getStructuredContentHtml).join();
    }

    return content;
  }

  /// Convert style to appropriate format.
  static Map<String, String> getStyle(Map<String, dynamic> styleMap) {
    return Map<String, String>.fromEntries(
      styleMap.entries.map(
        (e) => MapEntry(
          ReCase(e.key).paramCase,
          e.value.toString(),
        ),
      ),
    );
  }

  /// Get the HTML for a certain node.
  static String getNodeHtml({
    required String content,
    String? tag,
    Map<String, String> style = const {},
  }) {
    if (tag == null) {
      return content;
    }

    dom.Element element = dom.Element.tag(tag);
    element.attributes.addAll(style);

    element.innerHtml = content;

    return element.outerHtml;
  }

  /// For [prepareEntriesYomichanFormat].
  static dynamic processDefinition(dynamic definition) {
    if (definition is String) {
      return definition;
    } else if (definition is Map) {
      final type = definition['type'];
      switch (type) {
        case 'text':
          return definition['text'];
        case 'structured-content':
        case 'image':
          return definition['content'];
      }
    }
    return null;
  }
}

/// Top-level function for use in compute. See [DictionaryFormat] for details.
Future<void> prepareDirectoryYomichanFormat(
    PrepareDirectoryParams params) async {
  final filePath = params.file.path;
  final dirPath = params.resourceDirectory.path;
  final sendPort = params.sendPort;

  // Try fast native FFI extraction first
  await Isolate.run(() {
    extractZipArchiveSync(File(filePath), Directory(dirPath));
  });

  // If native FFI produced nothing, fall back to Dart archive
  final extracted = Directory(dirPath).listSync();
  if (extracted.isEmpty) {
    await Isolate.run(() {
      final port = sendPort;
      final input = archive_io.InputFileStream(filePath);
      final zip = archive.ZipDecoder().decodeBuffer(input);
      final total = zip.files.length;
      int n = 0;
      for (final file in zip.files) {
        final outPath = '$dirPath/${file.name}';
        if (file.isFile) {
          final outFile = File(outPath);
          outFile.parent.createSync(recursive: true);
          outFile.writeAsBytesSync(file.content as List<int>);
        } else {
          Directory(outPath).createSync(recursive: true);
        }
        n++;
        if (n % 100 == 0 || n == total) {
          port.send('$n / $total');
        }
      }
      input.closeSync();
    });
  }
}

/// Top-level function for use in compute. See [DictionaryFormat] for details.
Future<String> prepareNameYomichanFormat(PrepareDirectoryParams params) async {
  /// Get the index, which contains the name of the dictionary contained by
  /// the archive.
  String indexFilePath = path.join(params.resourceDirectory.path, 'index.json');
  File indexFile = File(indexFilePath);
  String indexJson = indexFile.readAsStringSync();
  Map<String, dynamic> index = jsonDecode(indexJson);

  String dictionaryName = (index['title'] as String).trim();
  return dictionaryName;
}

void _prepareEntriesYomichanStub({
  required PrepareDictionaryParams params,
  required dynamic database,
}) {
  // No-op: hoshidicts C++ handles import directly via HoshiDicts.importDictionary
}
