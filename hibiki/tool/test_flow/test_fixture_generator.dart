import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';

import '../../integration_test/helpers/generate_test_epub.dart'
    show EpubGenerator;

class FixtureGenerationResult {
  const FixtureGenerationResult({
    required this.markerEpub,
    required this.dictionaryZip,
    required this.fontFile,
  });

  final File markerEpub;
  final File dictionaryZip;
  final File fontFile;
}

Future<FixtureGenerationResult> generateComprehensiveFixtures({
  required String outputDir,
}) async {
  final Directory dir = Directory(outputDir)..createSync(recursive: true);

  final File markerEpub = File('${dir.path}/marker.epub');
  await markerEpub.writeAsBytes(EpubGenerator().generate(), flush: true);

  final File dictionaryZip = File('${dir.path}/test-yomitan.zip');
  await dictionaryZip.writeAsBytes(_buildDictionaryZip(), flush: true);

  final File fontFile = File('${dir.path}/test-font.ttf');
  await fontFile.writeAsBytes(await _loadFontBytes(), flush: true);

  return FixtureGenerationResult(
    markerEpub: markerEpub,
    dictionaryZip: dictionaryZip,
    fontFile: fontFile,
  );
}

List<int> _buildDictionaryZip() {
  final Map<String, Object> index = <String, Object>{
    'title': 'HibikiComprehensiveTestDictionary',
    'format': 3,
    'revision': 'generated-1',
    'sequenced': false,
  };
  final List<List<Object>> terms = <List<Object>>[
    <Object>[
      'testword',
      'testword',
      '',
      '',
      0,
      <String>['Generated dictionary entry used by comprehensive tests.'],
      0,
      '',
    ],
    <Object>[
      'cat',
      'cat',
      '',
      '',
      0,
      <String>['Fallback ASCII lookup entry used by comprehensive tests.'],
      1,
      '',
    ],
  ];

  final Archive archive = Archive()
    ..addFile(_jsonFile('index.json', index))
    ..addFile(_jsonFile('term_bank_1.json', terms));
  return ZipEncoder().encode(archive)!;
}

ArchiveFile _jsonFile(String name, Object json) {
  final List<int> bytes = utf8.encode(jsonEncode(json));
  return ArchiveFile(name, bytes.length, bytes);
}

Future<Uint8List> _loadFontBytes() async {
  final List<File> candidates = <File>[
    File(r'C:\Windows\Fonts\arial.ttf'),
    File(r'C:\Windows\Fonts\segoeui.ttf'),
    File('/System/Library/Fonts/Supplemental/Arial.ttf'),
    File('/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf'),
  ];
  for (final File file in candidates) {
    if (await file.exists()) {
      return file.readAsBytes();
    }
  }

  throw StateError('No system TrueType font fixture was found');
}
