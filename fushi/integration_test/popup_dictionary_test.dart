import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';

import 'package:fushi/main.dart' as app;
import 'package:fushi/models.dart';
import 'package:fushi/pages.dart';

import 'helpers/focus_driver.dart';
import 'helpers/library_fixture.dart';
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

      // BUG-1106：Tab 遍历前必须先开实验焦点导航开关——关闭（默认）时裸 Tab 被全局
      // 中和成 DoNothingIntent，而集成测试跑在全新隔离根上、偏好恒为默认值。
      await enableFocusNavigation(tester);
      final FocusDriver driver = FocusDriver(tester);

      await takeScreenshot(binding, 'popup_test_home');

      // ── Phase 1: Access AppModel and import dictionary ──

      final Element anyElement = tester.element(find.byType(Scaffold).first);
      final ProviderContainer container = ProviderScope.containerOf(anyElement);
      final AppModel appModel = container.read(appProvider);

      final cacheDir = await getTemporaryDirectory();
      final File dictFile = File('${cacheDir.path}/test_dict.zip');
      String primarySearchTerm = '食べる';
      bool generatedFallback = false;

      if (!Platform.isAndroid) {
        // Desktop runs have no runner-provisioned external fixture and retain
        // the cache across runs. Rewrite the deterministic fixture every time
        // so an old `test_dict.zip` cannot make this test order-dependent.
        await writeGeneratedDictionary(dictFile);
        primarySearchTerm = 'testword';
        generatedFallback = true;
        debugPrint('[popup-test] Generated local dictionary fixture');
      } else if (!dictFile.existsSync()) {
        // The runner pushes the fixture into the app's own external-files dir
        // (readable with no permission); /sdcard/Download is a legacy fallback
        // but is blocked for the app uid under scoped storage.
        // `getExternalStorageDirectory` is Android-only. Desktop app-level
        // verification uses the generated fixture fallback below.
        final Directory? extDir =
            Platform.isAndroid ? await getExternalStorageDirectory() : null;
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

      // importDictionary intentionally does not call onImportSuccess when the
      // same generated fixture is already installed. Desktop reruns are
      // persistent, so verify the fixture instead of waiting 30 seconds.
      if (!importSuccess && generatedFallback) {
        importSuccess = await seedDictionary(tester);
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

      // Phase 4 below needs the deterministic `testword` entry even when the
      // Android runner supplied a full Japanese dictionary fixture.
      expect(await seedDictionary(tester), isTrue,
          reason: 'generated popup-action fixture must be installed');

      // ── Phase 2: Navigate to dictionary tab ──

      // Home tabs are conditional; locate the dictionary destination by its
      // production identity instead of assuming it is always index 1.
      final Finder dictionaryTab = findNavTargetForTab(HomeTab.dictionaries);
      final bool focusedDict = await driver.focusWidget(dictionaryTab);
      expect(focusedDict, isTrue,
          reason: 'Dictionary tab must be reachable by focus');
      await driver.activate();
      await tester.pump(const Duration(seconds: 3));

      await takeScreenshot(binding, 'popup_test_dict_tab');

      // ── Phase 3: Search for a word ──

      final Finder searchField = findSearchField();
      await tester.enterText(searchField, primarySearchTerm);
      final HomeDictionarySearchDebug popupDebug = tester.state(
        find.byType(HomeDictionaryPage),
      ) as HomeDictionarySearchDebug;
      await popupDebug.debugSearch(primarySearchTerm, writeHistory: true);
      await tester.pump(const Duration(seconds: 5));

      await takeScreenshot(binding, 'popup_test_search_result');

      final Finder resultEvidence = findDictionaryResultEvidence();
      final int resultCount = resultEvidence.evaluate().length;
      debugPrint('[popup-test] Search results: $resultCount evidence widgets');

      expect(resultCount, greaterThan(0),
          reason:
              'Dictionary search for $primarySearchTerm must return results');

      // ── Phase 4: Exercise the real in-app nested popup host ──

      final bool originalBottomDocked = appModel.popupBottomDocked;
      await appModel.setPopupBottomDocked(false);
      addTearDown(
        () => appModel.setPopupBottomDocked(originalBottomDocked),
      );
      final int popupMatches = await popupDebug.debugOpenPopup('testword');
      expect(popupMatches, greaterThan(0));

      Map<Object?, Object?>? snapshot;
      for (int i = 0; i < 80; i++) {
        await tester.pump(const Duration(milliseconds: 250));
        final dynamic raw = await popupDebug.debugEvaluateTopPopup(r'''
(() => ({
  ready: document.readyState,
  mineButtons: document.querySelectorAll('.mine-button').length,
  favoriteButtons: document.querySelectorAll('.favorite-button').length,
  contentHeight: Math.max(document.body.scrollHeight, document.documentElement.scrollHeight),
  viewportHeight: window.innerHeight
}))()
''');
        if (raw is Map && raw['favoriteButtons'] == 1) {
          snapshot = raw.cast<Object?, Object?>();
          break;
        }
      }

      debugPrint('[popup-test] Nested popup snapshot: $snapshot; '
          'autoFit=${popupDebug.debugTopPopupAutoFitHeight}');
      expect(snapshot, isNotNull,
          reason: 'real popup WebView must render mine/favorite controls');
      expect(snapshot!['mineButtons'], 1);
      expect(snapshot['favoriteButtons'], 1);
      expect(popupDebug.debugTopPopupAutoFitHeight, isNotNull,
          reason:
              'popupRendered must feed DOM metrics back to the Flutter host');
      expect(
        popupDebug.debugTopPopupAutoFitHeight!,
        lessThan(appModel.popupMaxHeight * appModel.appUiScale),
        reason: 'single generated entry must shrink below the configured max '
            'instead of leaving the reported blank lower half',
      );

      // DOM click exercises the actual JS -> native WebView -> Dart favorite bridge.
      // Windows native pointer ordering itself is covered by the plugin event test.
      await popupDebug.debugEvaluateTopPopup(
        "document.querySelector('.favorite-button').click(); true",
      );
      bool favorited = false;
      for (int i = 0; i < 40; i++) {
        await tester.pump(const Duration(milliseconds: 250));
        favorited = await appModel.database.isFavoriteWord(
          expression: 'testword',
          reading: 'testword',
          sourceType: 'book',
        );
        if (favorited) break;
      }
      expect(favorited, isTrue,
          reason:
              'favorite button must cross the real JS/Dart bridge and write DB');

      await popupDebug.debugEvaluateTopPopup(
        "document.querySelector('.favorite-button').click(); true",
      );
      for (int i = 0; i < 40; i++) {
        await tester.pump(const Duration(milliseconds: 250));
        favorited = await appModel.database.isFavoriteWord(
          expression: 'testword',
          reading: 'testword',
          sourceType: 'book',
        );
        if (!favorited) break;
      }
      expect(favorited, isFalse,
          reason: 'second favorite activation must remove the same DB row');

      popupDebug.debugClosePopup();
      await tester.pump(const Duration(milliseconds: 300));

      await takeScreenshot(binding, 'popup_test_verified');

      assertStrictErrors(errors);
    } finally {
      FlutterError.onError = oldHandler;
    }
  });
}
