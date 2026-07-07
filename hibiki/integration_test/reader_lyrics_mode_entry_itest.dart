import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:hibiki/main.dart' as app;
import 'package:hibiki/src/media/sources/reader_hibiki_source.dart'
    show ReaderHibikiSource;
import 'package:hibiki/src/models/app_model.dart' show AppModel;
import 'package:hibiki/src/pages/implementations/reader_hibiki_page.dart'
    show ReaderHibikiPage;
import 'package:hibiki_audio/hibiki_audio.dart' show AudiobookPlayerController;

import 'helpers/focus_driver.dart';
import 'helpers/library_fixture.dart' show readyAppModel, seedAudiobook;
import 'support/itest_startup_guard.dart';
import 'test_helpers.dart';

bool _webViewShown() =>
    find.byKey(const ValueKey<String>('hoshi_webview')).evaluate().isNotEmpty;

bool _readerContentReady() => find
    .byKey(const ValueKey<String>('hoshi_content_ready'))
    .evaluate()
    .isNotEmpty;

bool _lyricsReady() => find
    .byKey(const ValueKey<String>('hoshi_lyrics_ready'))
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

Future<void> _waitForLyricsReadyOrFail(WidgetTester tester) async {
  for (int i = 0; i < 120; i++) {
    await tester.pump(const Duration(milliseconds: 500));
    if (_lyricsReady()) return;
  }
  final Map<String, Object?>? diagnostics =
      await ReaderHibikiPage.debugLyricsModeDiagnostics?.call();
  Object? sentinel;
  try {
    sentinel = await ReaderHibikiPage.debugEvaluateJavascript?.call(
      "Boolean(window.__lyricsSetCue && document.getElementById('lc'))",
    );
  } catch (e) {
    sentinel = 'eval failed: $e';
  }
  fail(
    'lyrics page must report ready after enabling lyrics mode; '
    'diagnostics=$diagnostics; sentinel=$sentinel',
  );
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
      await runHibikiItest(
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

          final String bookKey = await seedAudiobook(
            tester,
            title: 'Lyrics Mode Automation',
          );
          final FocusDriver driver = FocusDriver(tester);

          final List<Finder> navTargets = findPrimaryNavigationTargets();
          if (navTargets.isNotEmpty) {
            await driver.focusWidget(navTargets.first);
            await driver.activate();
            await tester.pump(const Duration(seconds: 1));
          }

          Finder bookEntry = find.byKey(ValueKey<String>(
            'srt_entry_${ReaderHibikiSource.mediaIdentifierFor(bookKey)}',
          ));
          for (int i = 0; i < 40; i++) {
            await tester.pump(const Duration(milliseconds: 500));
            if (bookEntry.evaluate().isNotEmpty) break;
            final Finder fallback = find.byKey(ValueKey<String>(
              'book_entry_${ReaderHibikiSource.mediaIdentifierFor(bookKey)}',
            ));
            if (fallback.evaluate().isNotEmpty) {
              bookEntry = fallback;
              break;
            }
          }
          expect(bookEntry, findsOneWidget,
              reason: 'seeded audiobook card must be visible on the shelf');

          expect(await driver.focusWidget(bookEntry), isTrue,
              reason: 'seeded audiobook card must be focus reachable');
          await driver.activate();
          await _pumpUntil(tester, _webViewShown,
              reason: 'reader WebView must mount after opening audiobook');
          await _pumpUntil(tester, _readerContentReady,
              reason: 'reader content must become ready before lyrics mode');

          final AudiobookPlayerController controller =
              await _waitForActiveAudiobook(tester, appModel);
          expect(controller.chapterCueCount, greaterThan(0),
              reason: 'fixture must provide subtitle cues for lyrics mode');

          expect(ReaderHibikiPage.debugToggleLyricsMode, isNotNull,
              reason: 'profile/debug builds must expose lyrics-mode hook');
          await ReaderHibikiSource.instance.setPreference<bool>(
            key: 'lyrics_mode_hint_shown',
            value: true,
          );
          await ReaderHibikiPage.debugToggleLyricsMode!();

          await _waitForLyricsReadyOrFail(tester);
          expect(ReaderHibikiPage.debugLyricsModeReady?.call(), isTrue);

          final dynamic sentinel =
              await ReaderHibikiPage.debugEvaluateJavascript?.call(
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
