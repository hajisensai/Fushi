import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';

import 'package:hibiki/main.dart' as app;
import 'package:hibiki/models.dart';

import 'helpers/focus_driver.dart';
import 'test_helpers.dart';

/// Integration test for popup dictionary path fix verification.
///
/// Imports a dictionary zip from a known path, then verifies
/// in-app dictionary search returns results — proving the database
/// and dictionary resource paths are correct.
///
/// Prerequisites:
///   - Push dictionary zip to emulator before running:
///     adb push "path/to/dict.zip" /sdcard/Download/test_dict.zip
///
/// Run:
///   flutter drive --driver=test_driver/integration_test.dart \
///       --target=integration_test/popup_dictionary_test.dart
void main() {
  final IntegrationTestWidgetsFlutterBinding binding =
      IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('import dictionary and verify search returns results',
      (WidgetTester tester) async {
    final List<FlutterErrorDetails> errors = [];
    final FlutterExceptionHandler? oldHandler = FlutterError.onError;
    FlutterError.onError = (FlutterErrorDetails details) {
      errors.add(details);
      debugPrint('[popup-test] FlutterError: ${details.exceptionAsString()}');
    };

    try {
      app.main();

      final bool homeReady = await waitForHome(tester);
      expect(homeReady, isTrue, reason: 'Home must render within 90s');
      await tester.pump(const Duration(seconds: 2));

      final FocusDriver driver = FocusDriver(tester);

      await takeScreenshot(binding, 'popup_test_home');

      // ── Phase 1: Access AppModel and import dictionary ──

      final Element anyElement = tester.element(find.byType(Scaffold).first);
      final ProviderContainer container = ProviderScope.containerOf(anyElement);
      final AppModel appModel = container.read(appProvider);

      final cacheDir = await getTemporaryDirectory();
      final File dictFile = File('${cacheDir.path}/test_dict.zip');

      if (!dictFile.existsSync()) {
        // The runner pushes the fixture into the app's own external-files dir
        // (readable with no permission); /sdcard/Download is a legacy fallback
        // but is blocked for the app uid under scoped storage.
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
        if (src != null) {
          src.copySync(dictFile.path);
          debugPrint('[popup-test] Copied dict from ${src.path} to cache');
        } else {
          fail('Dictionary fixture not found. The runner pushes it to '
              "the app's external-files dir; run via ci/integration-test.sh.");
        }
      }

      debugPrint('[popup-test] Importing dictionary from ${dictFile.path}');

      final progressNotifier = ValueNotifier<String>('');
      bool importSuccess = false;
      String? importError;

      try {
        await appModel.importDictionary(
          file: dictFile,
          progressNotifier: progressNotifier,
          onImportSuccess: () {
            importSuccess = true;
            debugPrint('[popup-test] Dictionary import succeeded');
          },
        );
      } catch (e) {
        importError = e.toString();
        debugPrint('[popup-test] Dictionary import error: $e');
      }

      // Pump frames to let the model update listeners.
      for (int i = 0; i < 60; i++) {
        await tester.pump(const Duration(milliseconds: 500));
        if (importSuccess) break;
      }

      if (!importSuccess) {
        fail('Dictionary import did not succeed within 30s. '
            'Progress: ${progressNotifier.value}. '
            'Error: $importError');
      }

      progressNotifier.dispose();

      // ── Phase 2: Navigate to dictionary tab ──

      final List<Finder> navTargets = findPrimaryNavigationTargets();
      expect(navTargets.length, greaterThanOrEqualTo(2),
          reason: 'Navigation must have at least 2 targets (Books, Dicts)');

      final bool focusedDict = await driver.focusWidget(navTargets[1]);
      expect(focusedDict, isTrue,
          reason: 'Dictionary tab must be reachable by focus');
      await driver.activate();
      await tester.pump(const Duration(seconds: 3));

      await takeScreenshot(binding, 'popup_test_dict_tab');

      // ── Phase 3: Search for a word ──

      final Finder searchField = findSearchField();
      await tester.enterText(searchField, '食べる');
      await tester.pump(const Duration(seconds: 5));

      await takeScreenshot(binding, 'popup_test_search_result');

      final Finder resultEvidence = findDictionaryResultEvidence();
      final int resultCount = resultEvidence.evaluate().length;
      debugPrint('[popup-test] Search results: $resultCount evidence widgets');

      expect(resultCount, greaterThan(0),
          reason: 'Dictionary search for 食べる must return at least one result');

      await takeScreenshot(binding, 'popup_test_verified');

      assertStrictErrors(errors);
    } finally {
      FlutterError.onError = oldHandler;
    }
  });
}
