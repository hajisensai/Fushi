import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:archive/archive.dart' as archive;
import 'package:archive/archive_io.dart' as archive_io;
import 'package:async_zip/async_zip.dart';
import 'package:beautiful_soup_dart/beautiful_soup.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:html/dom.dart' as dom;
import 'package:list_counter/list_counter.dart';
import 'package:path/path.dart' as path;
import 'package:recase/recase.dart';
import 'package:hibiki/dictionary.dart';
import 'package:hibiki/utils.dart';

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
          name: 'Yomichan Dictionary',
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

  /// If true, uses the [customDefinitionWidget] instead.
  @override
  bool shouldUseCustomDefinitionWidget(String definition) {
    try {
      jsonDecode(definition);
      return true;
    } catch (e) {
      return false;
    }
  }

  @override
  String getCustomDefinitionText(String meaning) {
    final node =
        StructuredContent.processContent(jsonDecode(meaning))?.toNode();
    if (node == null) {
      return '';
    }

    final document = dom.Document.html('');
    document.body?.append(node);
    for (final e in document.querySelectorAll('li')) {
      final css = e.bs4.findParent('ul')?.attributes['style'] ?? '';
      final text = e.text;
      final name = css
              .split(';')
              .firstWhere((e) => e.contains('list-style-type'))
              .split(':')
              .lastOrNull ??
          'square';

      final counterStyle = CounterStyleRegistry.lookup(name);
      final counter = counterStyle.generateMarkerContent(0);
      e.text = '$counter $text';
    }
    document.querySelectorAll('table').map((e) => e.remove());
    final html = document.body?.innerHtml ?? '';

    return BeautifulSoup(html).getText(separator: '\n');
  }

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

/// Top-level function for use in compute. See [DictionaryFormat] for details.
/// Retained for reference; not called at runtime until hoshidicts migration.
void prepareEntriesYomichanFormat({
  required PrepareDictionaryParams params,
  required dynamic isar,
}) {
  final List<FileSystemEntity> entities = params.resourceDirectory.listSync();
  final Iterable<File> files = entities.whereType<File>();

  int n = 0;
  int total = 0;

  for (File file in files) {
    String filename = path.basename(file.path);
    if (filename.startsWith('term_bank') || filename.startsWith('kanji_bank')) {
      String json = file.readAsStringSync();
      List<dynamic> items = jsonDecode(json);
      total += items.length;

      params.send(t.import_found_entry(count: total));
    }
  }

  for (File file in files) {
    String filename = path.basename(file.path);
    if (filename.startsWith('term_bank')) {
      List<dynamic> items = jsonDecode(file.readAsStringSync());

      for (List<dynamic> item in items) {
        final String term = item[0];
        final String reading = item[1];
        final String? spaceSeparatedDefinitionTags = item[2];
        // final String ruleIdentifier = item[3];
        final num rawPopularity = item[4];
        final List<dynamic> rawDefinitions = item[5];
        // final int sequenceNumber = item[6];
        final String spaceSeparatedTermTags = item[7];

        double popularity = rawPopularity.toDouble();
        List<String> entryTagNames =
            spaceSeparatedDefinitionTags?.split(' ') ?? [];
        List<String> headingTagNames = spaceSeparatedTermTags.split(' ');
        final definitions = rawDefinitions
            .map(YomichanFormat.processDefinition)
            .where((d) => d != null)
            .toList();

        final bool hasStructured = definitions.any((d) => d is! String);
        String meaning;
        if (definitions.isEmpty) {
          continue;
        } else if (!hasStructured) {
          meaning = definitions.cast<String>().join('\n');
        } else if (definitions.length == 1) {
          meaning = definitions.first is String
              ? definitions.first as String
              : jsonEncode(definitions.first);
        } else {
          meaning = jsonEncode(definitions);
        }

        // Combine all tag names into extra as JSON
        List<String> allTags = [...entryTagNames, ...headingTagNames]
            .where((t) => t.isNotEmpty)
            .toList();
        String extra = allTags.isNotEmpty ? jsonEncode(allTags) : '';

        final entry = DictionaryEntry(
          dictionaryName: params.dictionary.name,
          word: term,
          reading: reading,
          meaning: meaning,
          extra: extra,
          popularity: popularity,
        );

        isar.dictionaryEntrys.putSync(entry);

        n++;
        params.send(t.import_write_entry(
          count: n,
          total: total,
        ));
      }
    } else if (filename.startsWith('kanji_bank')) {
      List<dynamic> items = jsonDecode(file.readAsStringSync());

      for (List<dynamic> item in items) {
        String term = item[0] as String;
        List<String> onyomis = (item[1] as String).split(' ');
        List<String> kunyomis = (item[2] as String).split(' ');
        List<String> meanings = List<String>.from(item[4]);

        StringBuffer buffer = StringBuffer();
        if (onyomis.join().trim().isNotEmpty) {
          buffer.write('音読み\n');
          for (String onyomi in onyomis) {
            buffer.write('  • $onyomi\n');
          }
          buffer.write('\n');
        }
        if (kunyomis.join().trim().isNotEmpty) {
          buffer.write('訓読み\n');
          for (String kun in kunyomis) {
            buffer.write('  • $kun\n');
          }
          buffer.write('\n');
        }
        if (meanings.isNotEmpty) {
          buffer.write('意味\n');
          for (String meaning in meanings) {
            buffer.write('  • $meaning\n');
          }
          buffer.write('\n');
        }

        String definition = buffer.toString().trim();

        if (definition.isNotEmpty) {
          final entry = DictionaryEntry(
            dictionaryName: params.dictionary.name,
            word: term,
            meaning: definition,
            popularity: 0,
          );

          isar.dictionaryEntrys.putSync(entry);

          n++;
          params.send(t.import_write_entry(
            count: n,
            total: total,
          ));
        }
      }
    }
  }
}
