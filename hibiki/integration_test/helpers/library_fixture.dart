import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider/path_provider.dart';

import 'package:hibiki/src/epub/epub_importer.dart';
import 'package:hibiki/src/media/sources/reader_hibiki_source.dart';
import 'package:hibiki/src/models/app_model.dart';

import 'generate_test_epub.dart' show EpubGenerator;

/// Shared self-provisioning helpers so library-dependent integration tests are
/// hermetic on a fresh install.

Future<AppModel> readyAppModel(WidgetTester tester) async {
  final ProviderContainer container = ProviderScope.containerOf(
    tester.element(find.byType(MaterialApp).first),
  );
  final AppModel appModel = container.read(appProvider);
  for (int i = 0; i < 120 && !appModel.isInitialised; i++) {
    await tester.pump(const Duration(milliseconds: 500));
  }
  expect(appModel.isInitialised, isTrue,
      reason: 'AppModel must be initialised before seeding fixtures');
  return appModel;
}

Future<String> seedReaderBook(
  WidgetTester tester, {
  String fileName = 'test_library.epub',
}) async {
  final AppModel appModel = await readyAppModel(tester);
  final ProviderContainer container = ProviderScope.containerOf(
    tester.element(find.byType(MaterialApp).first),
  );

  final Uint8List bytes = EpubGenerator().generate();
  final String bookKey = await EpubImporter.import(
    db: appModel.database,
    bytes: bytes,
    fileName: fileName,
  );
  debugPrint('[fixture] Seeded reader book key=$bookKey ($fileName)');

  container.invalidate(hibikiBooksProvider(appModel.targetLanguage));

  final Finder bookEntries = find.byWidgetPredicate((Widget w) {
    final Key? key = w.key;
    return key is ValueKey<String> &&
        (key.value.startsWith('book_entry_') ||
            key.value.startsWith('srt_entry_'));
  });
  for (int i = 0; i < 40; i++) {
    await tester.pump(const Duration(milliseconds: 500));
    if (bookEntries.evaluate().isNotEmpty) {
      debugPrint('[fixture] Book entry visible after ${i * 500}ms');
      return bookKey;
    }
  }
  debugPrint(
      '[fixture] WARNING: seeded book key=$bookKey not visible after 20s');
  return bookKey;
}

Future<bool> seedDictionary(WidgetTester tester) async {
  final AppModel appModel = await readyAppModel(tester);
  if (_hasGeneratedDictionary(appModel)) {
    debugPrint('[fixture] Generated dictionary already installed');
    return true;
  }

  final Directory cacheDir = await getTemporaryDirectory();
  final File dictFile = File('${cacheDir.path}/test_dict.zip');
  if (!dictFile.existsSync()) {
    final File? source = await _findExternalDictionaryFixture();
    if (source == null) {
      await writeGeneratedDictionary(dictFile);
      debugPrint('[fixture] Generated dictionary fixture at ${dictFile.path}');
    } else {
      source.copySync(dictFile.path);
    }
  }

  final ValueNotifier<String> progress = ValueNotifier<String>('');
  bool ok = false;
  try {
    await appModel.importDictionary(
      file: dictFile,
      progressNotifier: progress,
      onImportSuccess: () => ok = true,
    );
  } catch (e, stack) {
    debugPrint('[fixture] Dictionary import failed: $e\n$stack');
    return _hasGeneratedDictionary(appModel);
  } finally {
    progress.dispose();
  }

  final bool installed = ok || _hasGeneratedDictionary(appModel);
  debugPrint('[fixture] Dictionary seed success=$installed');
  return installed;
}

Future<File> writeGeneratedDictionary(File file) async {
  final Map<String, dynamic> index = <String, dynamic>{
    'title': 'HibikiGeneratedTestDict',
    'format': 3,
    'revision': 'generated-test-1',
    'sequenced': false,
  };
  final List<List<dynamic>> termBank = <List<dynamic>>[
    <dynamic>[
      'testword',
      'testword',
      '',
      '',
      0,
      <String>['Generated dictionary entry used by comprehensive tests.'],
      0,
      '',
    ],
    <dynamic>[
      '\u732b',
      '\u306d\u3053',
      '',
      '',
      0,
      <String>['Generated Japanese lookup entry for comprehensive tests.'],
      1,
      '',
    ],
  ];

  final Archive archive = Archive()
    ..addFile(_jsonFile('index.json', index))
    ..addFile(_jsonFile('term_bank_1.json', termBank));
  final List<int> zipBytes = ZipEncoder().encode(archive)!;
  file.parent.createSync(recursive: true);
  await file.writeAsBytes(zipBytes, flush: true);
  return file;
}

Future<File?> _findExternalDictionaryFixture() async {
  final List<File> candidates = <File>[];
  if (!Platform.isWindows && !Platform.isMacOS && !Platform.isLinux) {
    final Directory? extDir = await getExternalStorageDirectory();
    if (extDir != null) {
      candidates.add(File('${extDir.path}/test_dict.zip'));
    }
  }
  candidates.add(File('/sdcard/Download/test_dict.zip'));

  for (final File file in candidates) {
    if (file.existsSync()) return file;
  }
  return null;
}

bool _hasGeneratedDictionary(AppModel appModel) {
  return appModel.dictionaries.any((dictionary) {
    return dictionary.name == 'HibikiGeneratedTestDict' ||
        dictionary.name == 'HibikiComprehensiveTestDictionary';
  });
}

ArchiveFile _jsonFile(String name, Object json) {
  final List<int> bytes = utf8.encode(jsonEncode(json));
  return ArchiveFile(name, bytes.length, bytes);
}
