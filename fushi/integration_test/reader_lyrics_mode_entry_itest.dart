import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'support/test_app_launcher.dart';
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
          await launchFushiTestApp();
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
          // 首次进入歌词模式会弹一次性提示对话框（`lyrics_mode_hint_shown`）。它是
          // 一层吃掉指针的模态路由：留着它，后面对顶栏那颗模式键的点击会被它吸走
          // （hit test 落在 AbsorbPointer 上）。本用例测的不是这条提示，直接把一次性
          // 旗预置成「已看过」，与真机上第二次进歌词模式的状态一致。
          ReaderFushiSource.instance
              .setPreference<bool>(key: 'lyrics_mode_hint_shown', value: true);

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
          // 不再按 `reader-action` 这个 focus-id 前缀过滤：设置面改成右侧抽屉后，
          // 这颗开关由 AdaptiveSettingsNavigationRow 渲染，焦点目标的 id 前缀是
          // `settings-row`；钉死旧前缀会让这一步在真机上恒 false（本条修复前该
          // 集成测试就卡在这里，与歌词模式本身无关）。断言的意图不变：这颗开关
          // 必须是一个**具体的、能接 ActivateIntent 的焦点停靠点**，而不是裸 InkWell。
          expect(
            await driver.requestFocusInside(lyricsToggle),
            isTrue,
            reason: 'lyrics-mode action must expose a concrete focus node',
          );
          expect(await driver.activateIntent(), isTrue,
              reason:
                  'the focused lyrics-mode action must handle ActivateIntent');
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

          // 歌词模式的顶栏必须与阅读模式一样在场，并挂着回正文的模式键。
          // 默认 chrome 是悬浮态（点空白唤出 / 计时自动收起），所以先走用户在歌词页
          // 唤出 chrome 的**生产路径**：歌词文档空白点击 → `onLyricsTapEmpty` 桥
          // （lyrics_mode_html.dart 里就是这么调的）。顶栏与底栏是同一台状态机，
          // 所以两者一起断言——只出一个才说明顶栏那半边被漏掉了。
          await ReaderFushiPage.debugEvaluateJavascript?.call(
            "window.flutter_inappwebview.callHandler('onLyricsTapEmpty');true",
          );
          final Finder header =
              find.byKey(const ValueKey<String>('fushi_desktop_header'));
          await _pumpUntil(tester, () => header.evaluate().isNotEmpty,
              reason: '歌词模式必须和阅读模式一样有顶栏（它是这里唯一的返回 / 设置面）', polls: 20);
          expect(find.byKey(const ValueKey<String>('fushi_play_bar')),
              findsOneWidget,
              reason: '底栏与顶栏同一台显隐状态机，唤出后两条都该在');
          final Finder modeButton = find.byKey(
            const ValueKey<String>('fushi_reader_lyrics_mode_button'),
          );
          expect(modeButton, findsOneWidget,
              reason: '歌词模式顶栏必须有一颗看得见的「回到阅读模式」键');

          await takeScreenshot(binding, 'reader_lyrics_mode_entry_ready');

          // 那颗键真的能把文档换回正文（回路闭合，不只是画出来）。顶栏整体包在
          // ExcludeFocus 里（TODO-700 不变式：焦点只住在正文），是纯指针面，没有
          // 焦点等价物，故此处按豁免通道①用一次坐标点击。
          await tester.tap(
              modeButton); // itest-tap-allow: 顶栏是 ExcludeFocus 的纯指针面，无焦点等价路径
          await _pumpUntil(
            tester,
            () => !ReaderFushiSource.instance.lyricsMode,
            reason: '顶栏模式键必须真把歌词模式关掉',
            polls: 20,
          );
          await _pumpUntil(tester, _readerContentReady,
              reason: '退出歌词模式后正文必须重新就绪');
        },
      );
    },
  );
}
