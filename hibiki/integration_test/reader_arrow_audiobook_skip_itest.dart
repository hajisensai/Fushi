import 'package:flutter/material.dart';
import 'package:flutter/services.dart' hide ModifierKey;
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:hibiki/main.dart' as app;
import 'package:hibiki/src/media/sources/reader_hibiki_source.dart'
    show ReaderHibikiSource;
import 'package:hibiki/src/models/app_model.dart' show AppModel;
import 'package:hibiki/src/shortcuts/input_binding.dart'
    show InputBinding, ModifierKey, ShortcutBindingSet;
import 'package:hibiki/src/shortcuts/shortcut_action.dart'
    show ShortcutAction, ShortcutScope;
import 'package:hibiki_audio/hibiki_audio.dart' show AudiobookPlayerController;

import 'helpers/focus_driver.dart';
import 'helpers/library_fixture.dart' show readyAppModel, seedAudiobook;
import 'support/itest_startup_guard.dart';
import 'test_helpers.dart';

/// TODO-992 设备层验收门（真实 Windows 引擎 + 焦点驱动 + 真键事件）。
///
/// 复现报告：「快捷键左右键改绑有声书上下句后，连续滚动模式仍只翻页不动有声书」。
///
/// 根因修复（develop f22dd38ca，BUG-466）：`resolveReaderArrowPageTurn` 原先无条件
/// 把裸 Left/Right 劫持成翻页（先于注册表解析），导致用户改绑成有声书上/下句后裸方向
/// 键仍翻页。修复给覆写加了 `boundAction` 闸门：仅当该键当前仍绑定到翻页时才做阅读
/// 方向校正；用户改绑成别的动作（或解绑）→ 覆写让出（null），交回注册表解析真实绑定。
/// 分页与连续滚动是同一个 `_handleKeyEvent` 路径，故两模式一并修复。
///
/// 本测试在真实 app 离屏壳里端到端证明该修复：
///   1. 播种一本带 cue 的有声书 EPUB（`seedAudiobook`，纯 Dart cue），焦点驱动打开它，
///      等到 `AudiobookSession.controller` attach 且本章 cue 就绪（== reader 的
///      `_hasActiveAudiobook` 为真的产品条件，audiobook.part.dart:1197）。
///   2. 强制进入「连续滚动」阅读模式（`setViewMode('continuous')`，正是报告里的场景）。
///   3. 经注册表把裸 ArrowRight/ArrowLeft **真实改绑**成
///      `audiobookNextSentence`/`audiobookPrevSentence`（用户改键走的同一 API
///      `updateBindingWithReassignments`，并从翻页 action 上摘掉这两个键）。
///   4. **负向对照**：改绑前先按一次 ArrowRight，断言权威 cue 索引 **不变**——默认绑定
///      下方向键是翻页，不动有声书（证明本测试能区分「翻页」与「动句子」，非假绿）。
///   5. **正向断言**：改绑后发真键事件 ArrowRight → 断言 controller 的权威
///      `currentCueIdx` **前进一句**；ArrowLeft → **回退一句**。断言基于真实状态字段
///      `AudiobookPlayerController.currentCueIdx`（audiobook_controller.dart:102，由
///      `skipToCue` 同步写入 :708-711 并 notifyListeners），不依赖像素截图。
///
/// 焦点机制：reader 页根 `Focus(autofocus:true, onKeyEvent:_handleKeyEvent)`
/// （reader_hibiki_page.dart:1919-1922）。打开书后该节点 autofocus，
/// `tester.sendKeyEvent` 即经它进入被测的 `_handleKeyEvent` 解析链。
///
/// 启动期网络噪声（更新检查 Handshake/证书过期）经 `runHibikiItest` 守卫放行。
///
/// Run (PowerShell, from hibiki/):
///   powershell -ExecutionPolicy Bypass -File tool/run_windows_itest.ps1 \
///       integration_test/reader_arrow_audiobook_skip_itest.dart

/// reader WebView 是否挂载（书已打开的标志）。
bool _webViewShown() =>
    find.byKey(const ValueKey<String>('hoshi_webview')).evaluate().isNotEmpty;

/// 轮询取得 attach 到 session 的有声书控制器（且本章已有 cue），否则返回 null。
Future<AudiobookPlayerController?> _waitForActiveAudiobook(
  WidgetTester tester,
  AppModel appModel, {
  int maxPolls = 80,
}) async {
  for (int i = 0; i < maxPolls; i++) {
    await tester.pump(const Duration(milliseconds: 500));
    final AudiobookPlayerController? c = appModel.audiobookSession.controller;
    if (c != null && c.chapterCueCount > 0) {
      debugPrint('[arrow-skip] audiobook active after ${i * 500}ms '
          'cueCount=${c.chapterCueCount} idx=${c.currentCueIdx}');
      return c;
    }
  }
  return appModel.audiobookSession.controller;
}

/// 把裸 [key] 改绑成 [action]，并从同一 co-active 组（reader+audiobook）其它 action
/// 上摘掉该键（模拟用户改键时的冲突清理，走产品同一 API）。
void _remapBareKey(
  AppModel appModel,
  LogicalKeyboardKey key,
  ShortcutAction action,
) {
  final InputBinding bare = InputBinding(key: key);
  appModel.shortcutRegistry.updateBindingWithReassignments(
    action,
    ShortcutBindingSet(keyboardBindings: <InputBinding>[bare]),
    removeKeyboardConflicts: <InputBinding>[bare],
  );
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'TODO-992 continuous scroll: remapped Left/Right drive audiobook '
    'prev/next sentence instead of only turning the page',
    (WidgetTester tester) async {
      await runHibikiItest(
        label: 'arrow-skip',
        body: () async {
          app.main();
          expect(await waitForHome(tester), isTrue,
              reason: 'home (nav bar) must render');
          await tester.pump(const Duration(seconds: 2));

          // 焦点驱动需要 HibikiFocusRoot（默认 OFF；开关后 main.dart 重建装上壳）。
          final AppModel appModel = await readyAppModel(tester);
          await appModel.setExperimentalFocusNavigationEnabled(true);
          for (int i = 0; i < 8; i++) {
            await tester.pump(const Duration(milliseconds: 250));
          }

          // 播种带 cue 的有声书并焦点驱动打开。
          final String bookKey =
              await seedAudiobook(tester, title: 'TODO-992 Arrow Audiobook');
          final FocusDriver driver = FocusDriver(tester);

          // 先把焦点落到「书架」标签（与 reader_caret_test 同套路）。
          final List<Finder> navTargets = findPrimaryNavigationTargets();
          if (navTargets.isNotEmpty) {
            await driver.focusWidget(navTargets.first);
            await driver.activate();
            await tester.pump(const Duration(seconds: 1));
          }

          final String entryKey =
              'srt_entry_${ReaderHibikiSource.mediaIdentifierFor(bookKey)}';
          final String altEntryKey =
              'book_entry_${ReaderHibikiSource.mediaIdentifierFor(bookKey)}';
          Finder bookEntry = find.byKey(ValueKey<String>(entryKey));
          for (int i = 0; i < 40; i++) {
            await tester.pump(const Duration(milliseconds: 500));
            if (bookEntry.evaluate().isNotEmpty) break;
            final Finder alt = find.byKey(ValueKey<String>(altEntryKey));
            if (alt.evaluate().isNotEmpty) {
              bookEntry = alt;
              break;
            }
          }
          expect(bookEntry, findsOneWidget,
              reason: 'seeded audiobook must appear on the shelf');

          final bool focusedBook = await driver.focusWidget(bookEntry);
          expect(focusedBook, isTrue,
              reason: 'audiobook card must be reachable by focus');
          await driver.activate();
          await tester.pump(const Duration(seconds: 3));

          for (int i = 0; i < 60; i++) {
            await tester.pump(const Duration(milliseconds: 500));
            if (_webViewShown()) break;
          }
          expect(_webViewShown(), isTrue,
              reason: 'reader WebView must mount after opening the book');

          // 有声书 session 必须已 attach 且本章有 cue（_hasActiveAudiobook 真）。
          final AudiobookPlayerController? controller =
              await _waitForActiveAudiobook(tester, appModel);
          expect(controller, isNotNull,
              reason: 'audiobook session controller must attach to the reader');
          final AudiobookPlayerController ctrl = controller!;
          expect(ctrl.chapterCueCount, greaterThanOrEqualTo(3),
              reason: 'fixture must seed enough cues to skip within bounds '
                  '(got ${ctrl.chapterCueCount})');

          // 强制连续滚动模式（报告里的精确场景）。
          await ReaderHibikiSource.instance.setTtuViewMode('continuous');
          for (int i = 0; i < 6; i++) {
            await tester.pump(const Duration(milliseconds: 200));
          }
          expect(ReaderHibikiSource.readerSettings?.isContinuousMode, isTrue,
              reason: 'reader must be in continuous scroll mode for TODO-992');

          // 建立确定性基线 cue（中段，避开首/末句边界），不经键、纯程序定位。
          await ctrl.skipToCueIndex(2);
          for (int i = 0; i < 4; i++) {
            await tester.pump(const Duration(milliseconds: 200));
          }
          final int baseIdx = ctrl.currentCueIdx;
          expect(baseIdx, 2,
              reason: 'baseline cue index must be the seeded mid cue');

          // 负向对照：默认绑定下按 → 是翻页，不动有声书 cue。
          // 证明本测试能区分「翻页」与「动句子」（修复前的红行为正是这个：方向键
          // 只翻页，cue 不动）。改绑前 cue 必须保持 baseIdx。
          await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
          for (int i = 0; i < 6; i++) {
            await tester.pump(const Duration(milliseconds: 150));
          }
          expect(ctrl.currentCueIdx, baseIdx,
              reason: 'with DEFAULT page-turn binding, ArrowRight must NOT move '
                  'the audiobook cue (it turns the page) — this is the pre-fix '
                  'behaviour the report complained about');

          // 真实改绑：裸 → = 下一句，裸 ← = 上一句。
          _remapBareKey(appModel, LogicalKeyboardKey.arrowRight,
              ShortcutAction.audiobookNextSentence);
          _remapBareKey(appModel, LogicalKeyboardKey.arrowLeft,
              ShortcutAction.audiobookPrevSentence);
          await tester.pump(const Duration(milliseconds: 200));

          // 健全性：注册表现在把裸 →/← 解析成有声书上/下句（reader+audiobook 组）。
          expect(
            appModel.shortcutRegistry.resolveKeyboard(
                  LogicalKeyboardKey.arrowRight,
                  modifiers: const <ModifierKey>{},
                  scope: ShortcutScope.reader,
                ) ??
                appModel.shortcutRegistry.resolveKeyboard(
                  LogicalKeyboardKey.arrowRight,
                  modifiers: const <ModifierKey>{},
                  scope: ShortcutScope.audiobook,
                ),
            ShortcutAction.audiobookNextSentence,
            reason: 'after remap, bare ArrowRight must resolve to next-sentence',
          );

          // 正向断言①：改绑后按 → 前进一句（TODO-992 修复点）。
          await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
          for (int i = 0; i < 6; i++) {
            await tester.pump(const Duration(milliseconds: 150));
          }
          final int afterNext = ctrl.currentCueIdx;
          debugPrint('[arrow-skip] base=$baseIdx afterNext=$afterNext');
          expect(afterNext, baseIdx + 1,
              reason: 'remapped ArrowRight must advance the audiobook cue by one '
                  'sentence in continuous scroll mode (TODO-992 fix); pre-fix it '
                  'would have only turned the page and left cue at $baseIdx');

          // 正向断言②：改绑后按 ← 回退一句。
          await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
          for (int i = 0; i < 6; i++) {
            await tester.pump(const Duration(milliseconds: 150));
          }
          final int afterPrev = ctrl.currentCueIdx;
          debugPrint('[arrow-skip] afterNext=$afterNext afterPrev=$afterPrev');
          expect(afterPrev, afterNext - 1,
              reason: 'remapped ArrowLeft must retreat the audiobook cue by one '
                  'sentence (back to $baseIdx)');
          expect(afterPrev, baseIdx,
              reason: 'next then prev returns to the baseline cue');

          debugPrint('[arrow-skip] PASS: in continuous scroll mode, remapped '
              'Left/Right drove audiobook prev/next sentence '
              '(base=$baseIdx next=$afterNext prev=$afterPrev) instead of only '
              'turning the page (TODO-992 / BUG-466).');
        },
      );
    },
  );
}
