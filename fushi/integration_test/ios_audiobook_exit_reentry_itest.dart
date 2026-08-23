import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:fushi/main.dart' as app;
import 'package:fushi/src/media/audiobook/now_listening_mini_bar.dart'
    show NowListeningMiniBar;
import 'package:fushi/src/media/sources/reader_fushi_source.dart'
    show ReaderFushiSource;
import 'package:fushi/src/models/app_model.dart' show AppModel;
import 'package:fushi/src/pages/implementations/home_page.dart' show HomeTab;
import 'package:fushi/src/pages/implementations/reader_fushi_page.dart'
    show ReaderFushiPage;
import 'package:fushi_audio/fushi_audio.dart' show AudiobookPlayerController;

import 'helpers/focus_driver.dart';
import 'helpers/library_fixture.dart' show readyAppModel, seedAudiobook;
import 'support/itest_startup_guard.dart';
import 'test_helpers.dart';

bool _readerShown() => find.byType(ReaderFushiPage).evaluate().isNotEmpty;

bool _readerReady() => find
    .byKey(const ValueKey<String>('fushi_content_ready'))
    .evaluate()
    .isNotEmpty;

Future<void> _pumpUntil(
  WidgetTester tester,
  bool Function() condition, {
  required String reason,
  int polls = 80,
}) async {
  for (int i = 0; i < polls; i++) {
    await tester.pump(const Duration(milliseconds: 250));
    if (condition()) return;
  }
  fail(reason);
}

Finder _bookEntry(String bookKey) {
  final Finder srt = find.byKey(
    ValueKey<String>(
      'srt_entry_${ReaderFushiSource.mediaIdentifierFor(bookKey)}',
    ),
  );
  if (srt.evaluate().isNotEmpty) return srt;
  return find.byKey(
    ValueKey<String>(
      'book_entry_${ReaderFushiSource.mediaIdentifierFor(bookKey)}',
    ),
  );
}

Future<void> _openBook(
  WidgetTester tester,
  FocusDriver driver,
  String bookKey,
) async {
  await _pumpUntil(
    tester,
    () => _bookEntry(bookKey).evaluate().isNotEmpty,
    reason: 'seeded audiobook card must be visible on the Books tab',
  );
  final Finder entry = _bookEntry(bookKey);
  expect(
    await driver.focusWidget(entry),
    isTrue,
    reason: 'audiobook card must expose a focus target',
  );
  await driver.activate();
  await _pumpUntil(
    tester,
    _readerReady,
    reason: 'reader content must become ready after opening the audiobook',
    polls: 160,
  );
}

Future<AudiobookPlayerController> _activeController(
  WidgetTester tester,
  AppModel appModel,
) async {
  AudiobookPlayerController? controller;
  await _pumpUntil(
    tester,
    () {
      controller = appModel.audiobookSession.controller;
      return controller != null && controller!.chapterCueCount > 0;
    },
    reason: 'audiobook session must attach with real cues',
    polls: 160,
  );
  return controller!;
}

void main() {
  final IntegrationTestWidgetsFlutterBinding binding =
      IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'iOS playback exits once, stops completely, and re-enters a non-black reader',
    (WidgetTester tester) async {
      await runFushiItest(
        label: 'ios-audiobook-exit-reentry',
        body: () async {
          app.main();
          expect(
            await waitForHome(tester),
            isTrue,
            reason: 'home must render before seeding the audiobook',
          );
          final AppModel appModel = await readyAppModel(tester);
          await appModel.setExperimentalFocusNavigationEnabled(true);
          final bool originalBackgroundPlay = appModel.audiobookBackgroundPlay;
          final bool originalLyricsMode = ReaderFushiSource.instance.lyricsMode;
          addTearDown(() async {
            await appModel.audiobookSession.stop();
            await appModel.setAudiobookBackgroundPlay(
              value: originalBackgroundPlay,
            );
            await ReaderFushiSource.instance.setLyricsMode(originalLyricsMode);
          });
          await appModel.setAudiobookBackgroundPlay(value: false);
          await ReaderFushiSource.instance.setLyricsMode(false);
          for (int i = 0; i < 8; i++) {
            await tester.pump(const Duration(milliseconds: 250));
          }

          final String bookKey = await seedAudiobook(
            tester,
            title: 'iOS Exit Reentry Audiobook',
            audioDuration: const Duration(seconds: 30),
          );
          final FocusDriver driver = FocusDriver(tester);
          await driver.focusWidget(findNavTargetForTab(HomeTab.books));
          await driver.activate();
          await tester.pump(const Duration(seconds: 1));
          await _openBook(tester, driver, bookKey);

          final AudiobookPlayerController first = await _activeController(
            tester,
            appModel,
          );
          unawaited(first.play());
          await _pumpUntil(
            tester,
            () => first.isPlaying,
            reason: 'Darwin player must enter the playing state',
          );
          expect(appModel.audiobookSession.isActive, isTrue);

          // Framework-level system back is the coordinate-free equivalent of
          // completing iOS' edge-swipe pop. It enters the same PopScope →
          // onWillPop → onSourcePagePop chain as the real gesture.
          final bool handled = await binding.handlePopRoute();
          expect(
            handled,
            isTrue,
            reason: 'the reader route must accept the first back gesture',
          );
          await _pumpUntil(
            tester,
            () => !_readerShown(),
            reason: 'one completed back gesture must leave the reader',
          );
          expect(
            appModel.audiobookSession.controller,
            isNull,
            reason: 'background play is off, so no orphan session may remain',
          );
          await _pumpUntil(
            tester,
            () => !first.isPlaying,
            reason: 'native iOS playback must actually stop after exit',
          );

          // The route must stay gone instead of restoring itself after the
          // asynchronous native stop finishes.
          await tester.pump(const Duration(seconds: 2));
          expect(
            _readerShown(),
            isFalse,
            reason: 'the dismissed reader must not restore itself',
          );

          await _openBook(tester, driver, bookKey);
          final dynamic
          bodyHasText = await ReaderFushiPage.debugEvaluateJavascript?.call(
            'Boolean(document.body && document.body.innerText.trim().length)',
          );
          expect(
            bodyHasText == true || bodyHasText == 'true' || bodyHasText == 1,
            isTrue,
            reason: 're-entered WebView must contain rendered text, not black',
          );
          expect(
            appModel.audiobookSession.controller,
            isNotNull,
            reason: 're-entry must publish a fresh audiobook controller',
          );
          await binding.takeScreenshot('ios_audiobook_reentry_non_black');

          // The opt-in background-play branch must expose an actual stop
          // affordance on iOS. Continuing is allowed only while the user still
          // has a way to end the process-level session.
          final AudiobookPlayerController second = await _activeController(
            tester,
            appModel,
          );
          await appModel.setAudiobookBackgroundPlay(value: true);
          unawaited(second.play());
          await _pumpUntil(
            tester,
            () => second.isPlaying,
            reason: 're-entered audiobook must play before background exit',
          );
          expect(await binding.handlePopRoute(), isTrue);
          await _pumpUntil(
            tester,
            () => !_readerShown(),
            reason: 'the second exit must also complete once',
          );
          expect(
            appModel.audiobookSession.controller,
            same(second),
            reason: 'opt-in background play keeps exactly one owned session',
          );
          await _pumpUntil(
            tester,
            () => find.byType(NowListeningMiniBar).evaluate().isNotEmpty,
            reason: 'background playback must expose the home mini player',
          );
          final Finder stopIcon = find.descendant(
            of: find.byType(NowListeningMiniBar),
            matching: find.byIcon(Icons.stop),
          );
          expect(
            stopIcon,
            findsOneWidget,
            reason: 'iOS mini player must expose a stop action',
          );
          final Finder stopButton = find.ancestor(
            of: stopIcon,
            matching: find.byType(IconButton),
          );
          expect(stopButton, findsOneWidget);
          final SemanticsHandle semantics = tester.ensureSemantics();
          final SemanticsNode stopNode = tester.getSemantics(stopButton);
          expect(
            stopNode.getSemanticsData().hasAction(SemanticsAction.tap),
            isTrue,
            reason:
                'the visible stop button must expose an actionable '
                'touch/accessibility semantic',
          );
          tester.binding.pipelineOwner.semanticsOwner!.performAction(
            stopNode.id,
            SemanticsAction.tap,
          );
          semantics.dispose();
          await tester.pump(const Duration(milliseconds: 250));
          await _pumpUntil(
            tester,
            () => appModel.audiobookSession.controller == null,
            reason: 'activating stop must clear the process-level session',
          );
          await _pumpUntil(
            tester,
            () => !second.isPlaying,
            reason: 'activating stop must silence the native iOS player',
          );
        },
      );
    },
  );
}
