import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:integration_test/integration_test.dart';

import 'package:hibiki/main.dart' as app;
import 'package:hibiki/src/epub/epub_importer.dart';
import 'package:hibiki/src/focus/hibiki_focus_controller.dart'
    show HibikiFocusController, HibikiFocusId, HibikiFocusRoot;
import 'package:hibiki/src/media/sources/reader_hibiki_source.dart'
    show hibikiBooksProvider;
import 'package:hibiki/src/models/app_model.dart' show appProvider;
import 'package:hibiki/src/pages/implementations/shelf_reorder_page.dart';
import 'package:hibiki/utils.dart';
import 'package:hibiki_audio/hibiki_audio.dart' show AudioCue;

import 'helpers/focus_driver.dart';
import 'helpers/library_fixture.dart' show readyAppModel;
import 'helpers/media_fixtures.dart'
    show buildSampleCues, buildAudiobookEpubBytes, kFixtureChapterHref;
import 'support/itest_startup_guard.dart';
import 'test_helpers.dart';

/// TODO-947 端到端验收门（真实 Windows 引擎 + 焦点驱动）。
///
/// 覆盖书架「编辑排序」入口与退出修复在真 app 离屏环境的端到端证据：
///
///  1. 在真实 app 壳（含 `HibikiFocusRoot`，由 `app.main()` 启动）下播种 **2 本不同
///     bookKey 的书**——`_openShelfSort` 的产品闸门是可重排条目 `< 2` 时只弹 toast
///     不 push（上一轮 itest `Actual 0` 的根因：bookKey = sanitizeTtuFilename(EPUB
///     内 `<dc:title>`)，与 fileName 无关，`EpubGenerator` 标题恒定，两次 seed 撞同
///     一 key 互相覆盖只剩 1 本）。这里用 `buildAudiobookEpubBytes(title:)` 注入两个
///     不同标题的纯 Dart EPUB（仅 cue，无音频/无 ffmpeg），各导入成独立 bookKey 的
///     普通阅读书，保证可重排条目 == 2。
///  2. 焦点驱动（**绝不** `tester.tap` / 坐标点击）把焦点经 `HibikiFocusController`
///     落到书架标签栏的「编辑排序」按钮（`Icons.swap_vert`，tooltip
///     `t.shelf_edit_order`），再发 Enter（焦点确认键，等价手柄 A）→ 断言
///     `find.byType(ShelfReorderPage)` 恰好 1 个（真进了编辑排序态）。
///  3. 再焦点驱动把焦点落到 `ShelfReorderPage` 顶栏「完成 / 退出」按钮（`Icons.check`，
///     tooltip `t.shelf_done`）→ Enter → 断言 `ShelfReorderPage` 已出栈（find 0 个）。
///
/// **必须先开实验开关**：`experimental_focus_navigation_enabled` 默认 false，关时
/// `main.dart` 不安装 `HibikiFocusRoot`，HibikiIconButton 降级为裸 InkWell（仅 tap）。
/// 本测试在 home 就绪后调 `appModel.setExperimentalFocusNavigationEnabled(true)`
/// 让 main.dart 重建装上焦点壳，之后焦点驱动才成立。
///
/// 焦点机制说明（关键，上一轮卡点的根因）：Hibiki 的焦点不走 stock Flutter 的 Tab
/// 遍历，而是自绘 `HibikiFocusController`（方向键 / 手柄）——它在每帧 `ensureFocus`
/// 把焦点「修复」回当前 active 目标，所以裸 `node.requestFocus()` 会被立刻打回
/// （上一轮 `focused=true node=null` 的现象）。正确做法是经控制器自身的
/// `requestById(id)` 把目标设为 active（survive repair），id = 该按钮
/// `HibikiFocusTarget` 的 `FocusNode.debugLabel`（见 hibiki_focus_target.dart：
/// `FocusNode(debugLabel: id.value)`）。落焦后发 Enter，`HibikiIconButton` 在
/// `HibikiFocusRoot` 内注册的 `ActivateIntent` Actions handler 触发 onTap
/// （见 hibiki_icon_button.dart `_focusable`）。这仍是「焦点驱动 + 语义确认键」，
/// 零坐标点击。
///
/// 启动期网络噪声（GitHub 更新检查的 Handshake/证书过期）经 `runHibikiItest`
/// 守卫放行，不冲红测试。
///
/// Run (PowerShell, from hibiki/):
///   powershell -ExecutionPolicy Bypass -File tool/run_windows_itest.ps1 \
///       integration_test/shelf_organize_exit_itest.dart

/// 书架书卡 finder（`book_entry_` / `srt_entry_` 前缀，见 test_helpers）。
Finder _bookCards() => findBookEntries();

/// 按图标定位 `HibikiIconButton`（按其内部 `Icon` 的图标，最稳；其祖先含
/// `HibikiFocusTarget` 的 `Focus(focusNode)`，debugLabel = 焦点 id 字符串）。
Finder _iconButtonIcon(IconData icon) {
  return find.byWidgetPredicate(
    (Widget w) => w is Icon && w.icon == icon,
    description: 'Icon($icon)',
  );
}

/// ShelfReorderPage 是否在树中。
bool _shelfReorderShown() =>
    find.byType(ShelfReorderPage).evaluate().isNotEmpty;

/// 按钮的焦点定位结果：焦点 id 字符串 + 承载 `Focus` 的 `BuildContext`
/// （用于从树内解析 `HibikiFocusRoot` 控制器）。
class _ButtonFocus {
  const _ButtonFocus(this.focusId, this.focusContext);
  final String focusId;
  final BuildContext focusContext;
}

/// 从 [iconFinder]（按钮内的 Icon）的元素向上找最近的带 `focusNode` 的 `Focus`，
/// 取其 `FocusNode.debugLabel`（= 该 `HibikiFocusTarget` 的焦点 id 字符串）与其
/// `BuildContext`（确保在 `HibikiFocusRoot` 子树内，可解析控制器）。
_ButtonFocus? _focusOfButton(Finder iconFinder) {
  final List<Element> els = iconFinder.evaluate().toList();
  if (els.isEmpty) return null;
  _ButtonFocus? result;
  els.first.visitAncestorElements((Element ancestor) {
    final Widget w = ancestor.widget;
    if (w is Focus && w.focusNode != null) {
      final String? label = w.focusNode!.debugLabel;
      if (label != null) {
        result = _ButtonFocus(label, ancestor);
        return false;
      }
    }
    return true;
  });
  return result;
}

/// 经控制器把焦点设到按钮（survive repair），再发 Enter 激活；轮询直到 [done]。
///
/// 全程焦点驱动 + 语义确认键，零坐标点击。
Future<bool> _focusActivate(
  WidgetTester tester,
  FocusDriver driver,
  Finder iconFinder, {
  required bool Function() done,
  int maxPolls = 24,
}) async {
  expect(iconFinder, findsWidgets,
      reason: 'target button icon must be present');
  final _ButtonFocus? bf = _focusOfButton(iconFinder);
  expect(bf, isNotNull,
      reason: 'button must carry a HibikiFocusTarget Focus node (only inside '
          'HibikiFocusRoot); none found means the page is not under the real '
          'app shell');
  final String focusId = bf!.focusId;
  final HibikiFocusController? controller =
      HibikiFocusRoot.maybeControllerOf(bf.focusContext, listen: false);
  expect(controller, isNotNull,
      reason: 'HibikiFocusRoot controller must be reachable from the button');

  for (int attempt = 0; attempt < 3; attempt++) {
    final bool requested = controller!.requestById(HibikiFocusId(focusId));
    await tester.pump(const Duration(milliseconds: 200));
    debugPrint('[shelf-organize] requestById($focusId) attempt=$attempt '
        'ok=$requested primary=${FocusManager.instance.primaryFocus?.debugLabel}');
    await driver.activate(); // Enter -> ActivateIntent -> onTap
    for (int i = 0; i < maxPolls; i++) {
      if (done()) return true;
      await tester.pump(const Duration(milliseconds: 250));
    }
  }
  return done();
}

/// 轮询直到书架至少出现 [minCount] 张书卡（live UI，禁止 pumpAndSettle）。
Future<int> _waitForBookCards(
  WidgetTester tester, {
  required int minCount,
  int maxPolls = 40,
}) async {
  int count = 0;
  for (int i = 0; i < maxPolls; i++) {
    await tester.pump(const Duration(milliseconds: 500));
    count = _bookCards().evaluate().length;
    if (count >= minCount) {
      debugPrint('[shelf-organize] $count book cards after ${i * 500}ms');
      return count;
    }
  }
  debugPrint('[shelf-organize] WARNING: only $count book cards '
      'after ${maxPolls * 500}ms (need >=$minCount)');
  return count;
}

/// 导入一本带独立标题（→ 独立 bookKey）的纯 Dart 阅读书（无音频/无 ffmpeg）。
Future<String> _seedTitledReaderBook(
  WidgetTester tester, {
  required String title,
}) async {
  await readyAppModel(tester);
  final ProviderContainer container = ProviderScope.containerOf(
    tester.element(find.byType(MaterialApp).first),
  );
  final dynamic appModel = container.read(appProvider);
  final List<AudioCue> cues =
      buildSampleCues(bookKey: 'pending', chapterHref: kFixtureChapterHref);
  final epubBytes = await buildAudiobookEpubBytes(title: title, cues: cues);
  final String bookKey = await EpubImporter.import(
    db: appModel.database,
    bytes: epubBytes,
    fileName: '$title.epub',
  );
  debugPrint('[shelf-organize] seeded reader book key=$bookKey ($title)');
  container.invalidate(hibikiBooksProvider(appModel.targetLanguage));
  return bookKey;
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'TODO-947 shelf organize: focus-driven enter ShelfReorderPage then exit pops it',
    (WidgetTester tester) async {
      await runHibikiItest(
        label: 'shelf-organize',
        body: () async {
          app.main();
          expect(await waitForHome(tester), isTrue,
              reason: 'home (nav bar) must render');
          await tester.pump(const Duration(seconds: 2));

          // 启用「键盘/手柄焦点导航」实验开关——它默认 OFF，关时 main.dart 不安装
          // HibikiFocusRoot（见 main.dart `_wrapFocusNavigation`），HibikiIconButton
          // 退化成裸 InkWell（仅 tap、无焦点目标），焦点驱动 + Enter 激活根本无从谈起
          // （这正是上一轮 itest 走焦点路径不通的根因）。setter notifyListeners 会让
          // main.dart 重建并包上 HibikiFocusRoot，故落焦/激活才成立。
          final dynamic appModel = await readyAppModel(tester);
          await appModel.setExperimentalFocusNavigationEnabled(true);
          for (int i = 0; i < 8; i++) {
            await tester.pump(const Duration(milliseconds: 250));
          }

          // 播种 2 本不同 bookKey 的阅读书（产品闸门：可重排条目 < 2 只弹 toast）。
          await _seedTitledReaderBook(tester, title: 'Shelf Organize Alpha');
          await _seedTitledReaderBook(tester, title: 'Shelf Organize Beta');

          final int cards = await _waitForBookCards(tester, minCount: 2);
          expect(cards, greaterThanOrEqualTo(2),
              reason: 'need >=2 distinct books so _openShelfSort pushes '
                  'ShelfReorderPage (gate: items.length < 2 only toasts)');

          final FocusDriver driver = FocusDriver(tester);

          // ---- ② 焦点落到「编辑排序」按钮并 Enter 激活 ----
          expect(_iconButtonIcon(Icons.swap_vert), findsOneWidget,
              reason: 'tag bar must render the organize (swap_vert) button; '
                  'tooltip=${t.shelf_edit_order}');
          final bool entered = await _focusActivate(
            tester,
            driver,
            _iconButtonIcon(Icons.swap_vert),
            done: _shelfReorderShown,
          );
          expect(entered, isTrue,
              reason: 'focus+Enter on organize must enter the edit-order state '
                  '(ShelfReorderPage pushed)');
          expect(find.byType(ShelfReorderPage), findsOneWidget,
              reason: 'ShelfReorderPage pushed exactly once');

          // ---- ③ 焦点落到退出 / 完成按钮并 Enter，断言出栈 ----
          expect(_iconButtonIcon(Icons.check), findsWidgets,
              reason: 'ShelfReorderPage app bar must render the done/exit '
                  '(check) button; tooltip=${t.shelf_done}');
          final bool exited = await _focusActivate(
            tester,
            driver,
            _iconButtonIcon(Icons.check),
            done: () => !_shelfReorderShown(),
          );
          expect(exited, isTrue,
              reason: 'focus+Enter on done/exit must pop ShelfReorderPage '
                  '(TODO-947 exit fix: real pop, no recursion hang)');
          expect(find.byType(ShelfReorderPage), findsNothing,
              reason: 'ShelfReorderPage popped off the stack');

          // 回到书架：标签栏的编辑排序入口应再次可见，证明已真退回。
          expect(_iconButtonIcon(Icons.swap_vert), findsOneWidget,
              reason: 'after exit, the shelf (with organize button) is shown '
                  'again');

          debugPrint('[shelf-organize] PASS: entered ShelfReorderPage via '
              'focus+Enter and exited it via focus+Enter (TODO-947).');
        },
      );
    },
  );
}
