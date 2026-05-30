import 'dart:io';
import 'dart:typed_data';

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
/// hermetic on a fresh install (no manual `adb push` + import step). Mirrors the
/// pattern proven in reader_pagination_test/_seedTestBook: import the synthetic
/// marker EPUB straight into the app database, then refresh the shelf provider.
///
/// These let the EMULATOR-ONLY runner (ci/integration-test.sh) drive every
/// target unattended: the runner pushes the dictionary zip to /sdcard, and the
/// tests seed their own book/dictionary at runtime.

/// Resolve the [AppModel] from the running app and wait until it has finished
/// initialising (DB open + first frame). Fails the test if it never does.
Future<AppModel> _readyAppModel(WidgetTester tester) async {
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

/// Import the synthetic marker EPUB onto the shelf and refresh the shelf
/// provider so it becomes visible. Returns the new book id. Idempotent enough
/// for the per-target fresh installs flutter drive produces.
Future<int> seedReaderBook(
  WidgetTester tester, {
  String fileName = 'test_library.epub',
}) async {
  final AppModel appModel = await _readyAppModel(tester);
  final ProviderContainer container = ProviderScope.containerOf(
    tester.element(find.byType(MaterialApp).first),
  );

  final Uint8List bytes = EpubGenerator().generate();
  final int bookId = await EpubImporter.import(
    db: appModel.database,
    bytes: bytes,
    fileName: fileName,
  );
  debugPrint('[fixture] Seeded reader book id=$bookId ($fileName)');

  container.invalidate(hibikiBooksProvider(appModel.targetLanguage));
  await tester.pumpAndSettle();
  return bookId;
}

/// Import the dictionary the runner pushed into the app's external-files dir
/// (copied into the app cache first, as the importer reads from app storage).
/// The app reads its own external-files dir with no permission;
/// /sdcard/Download is a legacy fallback but is blocked for the app uid under
/// scoped storage. Returns true if the import succeeded; false (with a debug
/// log) if the fixture is absent or the import threw.
Future<bool> seedDictionary(WidgetTester tester) async {
  final AppModel appModel = await _readyAppModel(tester);

  final Directory cacheDir = await getTemporaryDirectory();
  final File dictFile = File('${cacheDir.path}/test_dict.zip');
  if (!dictFile.existsSync()) {
    final Directory? extDir = await getExternalStorageDirectory();
    final List<File> candidates = <File>[
      if (extDir != null) File('${extDir.path}/test_dict.zip'),
      File('/sdcard/Download/test_dict.zip'),
    ];
    File? src;
    for (final File f in candidates) {
      if (f.existsSync()) {
        src = f;
        break;
      }
    }
    if (src == null) {
      debugPrint('[fixture] No dictionary fixture in the app external-files '
          'dir or /sdcard/Download — skipping dictionary seed');
      return false;
    }
    src.copySync(dictFile.path);
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
    return false;
  } finally {
    progress.dispose();
  }
  debugPrint('[fixture] Dictionary seed success=$ok');
  return ok;
}
