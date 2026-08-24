import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:fushi/main.dart' as app;
import 'package:fushi/src/media/sources/reader_fushi_source.dart'
    show ReaderFushiSource;
import 'package:fushi/src/models/app_model.dart' show AppModel;
import 'package:fushi/src/pages/implementations/home_page.dart' show HomeTab;
import 'package:fushi/src/pages/implementations/reader_fushi_page.dart'
    show ReaderFushiPage;
import 'package:fushi_audio/fushi_audio.dart' show AudiobookPlayerController;

import 'helpers/focus_driver.dart';
import 'helpers/library_fixture.dart'
    show openBookViaProductionPath, readyAppModel, seedAudiobook;
import 'support/itest_startup_guard.dart';
import 'test_helpers.dart';

bool _webViewShown() =>
    find.byKey(const ValueKey<String>('fushi_webview')).evaluate().isNotEmpty;

bool _readerContentReady() => find
    .byKey(const ValueKey<String>('fushi_content_ready'))
    .evaluate()
    .isNotEmpty;

bool _lyricsReady() => find
    .byKey(const ValueKey<String>('fushi_lyrics_ready'))
    .evaluate()
    .isNotEmpty;

Future<void> _pumpUntil(
  WidgetTester tester,
  bool Function() condition, {
  required String reason,
  int polls = 120,
}) async {
  for (int i = 0; i < polls; i++) {
    await tester.pump(const Duration(milliseconds: 500));
    if (condition()) return;
  }
  fail(reason);
}

Future<AudiobookPlayerController> _waitForActiveAudiobook(
  WidgetTester tester,
  AppModel appModel,
) async {
  for (int i = 0; i < 80; i++) {
    await tester.pump(const Duration(milliseconds: 500));
    final AudiobookPlayerController? controller =
        appModel.audiobookSession.controller;
    if (controller != null && controller.chapterCueCount > 0) {
      return controller;
    }
  }
  fail('audiobook controller must attach with chapter cues before lyrics mode');
}

void main() {
  final IntegrationTestWidgetsFlutterBinding binding =
      IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'reader automation can open an audiobook and enter lyrics mode',
    (WidgetTester tester) async {
      await runFushiItest(
        label: 'lyrics-mode-entry',
        body: () async {
          app.main();
          expect(await waitForHome(tester), isTrue,
              reason: 'home must render before seeding an audiobook');

          final AppModel appModel = await readyAppModel(tester);
          await appModel.setExperimentalFocusNavigationEnabled(true);
          for (int i = 0; i < 8; i++) {
            await tester.pump(const Duration(milliseconds: 250));
          }

          // 物理机 flutter test 会复用 app container；上一次会话若停在歌词模式，
          // 开书会自动发起 pending restore，与本用例的手动 toggle 竞争。
          final bool originalLyricsMode = ReaderFushiSource.instance.lyricsMode;
          addTearDown(() async {
            await ReaderFushiSource.instance.setLyricsMode(originalLyricsMode);
          });
          await ReaderFushiSource.instance.setLyricsMode(false);

          final String bookKey = await seedAudiobook(
            tester,
            title: 'Lyrics Mode Automation',
          );
          final FocusDriver driver = FocusDriver(tester);

          final List<Finder> navTargets = findPrimaryNavigationTargets();
          if (navTargets.isNotEmpty) {
            await driver.focusWidget(findNavTargetForTab(HomeTab.books));
            await driver.activate();
            await tester.pump(const Duration(seconds: 1));
          }

          Finder bookEntry = find.byKey(ValueKey<String>(
            'srt_entry_${ReaderFushiSource.mediaIdentifierFor(bookKey)}',
          ));
          for (int i = 0; i < 40; i++) {
            await tester.pump(const Duration(milliseconds: 500));
            if (bookEntry.evaluate().isNotEmpty) break;
            final Finder fallback = find.byKey(ValueKey<String>(
              'book_entry_${ReaderFushiSource.mediaIdentifierFor(bookKey)}',
            ));
            if (fallback.evaluate().isNotEmpty) {
              bookEntry = fallback;
              break;
            }
          }
          if (bookEntry.evaluate().isEmpty) {
            await openBookViaProductionPath(tester, bookKey);
          } else {
            expect(bookEntry, findsOneWidget,
                reason: 'seeded audiobook card must be visible on the shelf');
            expect(await driver.focusWidget(bookEntry), isTrue,
                reason: 'seeded audiobook card must be focus reachable');
            await driver.activate();
          }
          await _pumpUntil(tester, _webViewShown,
              reason: 'reader WebView must mount after opening audiobook');
          await _pumpUntil(tester, _readerContentReady,
              reason: 'reader content must become ready before lyrics mode');

          final AudiobookPlayerController controller =
              await _waitForActiveAudiobook(tester, appModel);
          expect(controller.chapterCueCount, greaterThan(0),
              reason: 'fixture must provide subtitle cues for lyrics mode');

          expect(ReaderFushiPage.debugOpenQuickSettings, isNotNull,
              reason: 'profile/debug builds must expose quick-settings hook');
          await ReaderFushiPage.debugOpenQuickSettings!();
          await tester.pump(const Duration(seconds: 1));

          final Finder lyricsToggle =
              find.byKey(const ValueKey<String>('fushi_lyrics_mode_toggle'));
          expect(lyricsToggle, findsOneWidget,
              reason: 'quick settings must expose the lyrics-mode action');
          expect(
            await driver.requestFocusInside(
              lyricsToggle,
              debugLabelContains: 'reader-action',
            ),
            isTrue,
            reason:
                'lyrics-mode action must expose a concrete reader-action focus node',
          );
          expect(await driver.activateIntent(), isTrue,
              reason: 'lyrics-mode reader-action must handle ActivateIntent');
          await tester.pump(const Duration(seconds: 1));
          expect(lyricsToggle, findsNothing,
              reason: 'activating lyrics mode must dismiss quick settings');
          expect(find.byType(ReaderFushiPage), findsOneWidget,
              reason:
                  'lyrics action must not activate the neighboring exit action');
          await _pumpUntil(
            tester,
            () => ReaderFushiSource.instance.lyricsMode,
            reason:
                'lyrics action must persist the entering state before loading HTML',
            polls: 10,
          );

          await _pumpUntil(tester, _lyricsReady,
              reason:
                  'lyrics page must report ready after enabling lyrics mode');
          expect(ReaderFushiPage.debugLyricsModeReady?.call(), isTrue);

          final dynamic sentinel =
              await ReaderFushiPage.debugEvaluateJavascript?.call(
            "Boolean(window.__lyricsSetCue && document.getElementById('lc'))",
          );
          expect(
            sentinel == true || sentinel == 'true' || sentinel == 1,
            isTrue,
            reason: 'the live WebView document must be LyricsModeHtml',
          );

          await takeScreenshot(binding, 'reader_lyrics_mode_entry_ready');
        },
      );
    },
  );
}
