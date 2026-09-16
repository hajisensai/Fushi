// 插图册（ReaderGalleryPage）的真机复测：走原始失败路径——真开书、按 G（与底栏
// 按钮同一个 _openGallery）唤出插图册——验证三件事：
//
// ① 顶栏整条落在状态栏 / 灵动岛之下。用户报的原症状就是「顶部会顶到系统任务栏
//    导致不能操作」：插图册是从阅读器 push 出去的全页路由，裸 Scaffold 的 body
//    不会自己让开系统 inset，过滤 / 定位 / 关闭三个控件整条压在状态栏底下。
//    这条只有在真设备上才有意义：viewPadding.top 是设备给的，widget 测试里得靠
//    FakeViewPadding 造。iOS 上取不到非零状态栏高度即判失败——那是设备选错了，
//    不是「通过」。
// ② 卡片菜单能唤出，「跳转到此插图」真的回到正文。
// ③ 已揭开的图能「恢复遮罩」，撤销后卡片重新盖上模糊层。
//
// 全程焦点 + 合成按键驱动（`CLAUDE.md`「集成测试一律焦点驱动」）：方向键在网格里
// 移焦、菜单键唤出卡片菜单、FocusDriver 在菜单里选项 + Enter 确认。② ③ 两段因此
// 同时也是键盘 / 手柄可达性的证明——指针那侧是长按 / 右键。
//
// 同一份测试三端可跑（安全区那条在 viewPadding 恒 0 的桌面端退化成恒真）：
//   iOS 模拟器   tool\run_mac_itest.ps1 integration_test/reader_gallery_safe_area_itest.dart -Ios
//   Windows 离屏 fushi\tool\run_windows_itest.ps1 integration_test/reader_gallery_safe_area_itest.dart
//   macOS 隐藏   tool\run_mac_itest.ps1 integration_test/reader_gallery_safe_area_itest.dart
library;

import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform;
import 'package:flutter/gestures.dart' show HitTestResult;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:fushi/src/pages/implementations/reader_fushi_page.dart'
    show ReaderFushiPage;
import 'package:fushi/src/reader/reader_gallery_page.dart'
    show ReaderGalleryPage;

import 'helpers/focus_driver.dart';
import 'helpers/observe_capture.dart';
import 'helpers/library_fixture.dart'
    show openBookViaProductionPath, seedReaderBook;
import 'support/itest_startup_guard.dart';
import 'support/test_app_launcher.dart';
import 'test_helpers.dart';

bool _readerShown() => find.byType(ReaderFushiPage).evaluate().isNotEmpty;

bool _galleryShown() => find.byType(ReaderGalleryPage).evaluate().isNotEmpty;

Future<void> _pumpUntil(
  WidgetTester tester,
  bool Function() condition, {
  required String reason,
  int polls = 120,
}) async {
  for (int i = 0; i < polls; i++) {
    await tester.pump(const Duration(milliseconds: 250));
    if (condition()) return;
  }
  fail(reason);
}

Future<void> _sendKey(WidgetTester tester, LogicalKeyboardKey key) async {
  await tester.sendKeyEvent(key);
  await tester.pump(const Duration(milliseconds: 250));
}

Finder get _closeButton =>
    find.byKey(const ValueKey<String>('fushi_gallery_close'));
Finder get _positionButton =>
    find.byKey(const ValueKey<String>('fushi_gallery_position'));
Finder get _filterButton =>
    find.byKey(const ValueKey<String>('fushi_gallery_filter'));
Finder get _menuJump =>
    find.byKey(const ValueKey<String>('fushi_gallery_menu_jump'));
Finder get _menuReveal =>
    find.byKey(const ValueKey<String>('fushi_gallery_menu_reveal'));
Finder get _menuRelock =>
    find.byKey(const ValueKey<String>('fushi_gallery_menu_relock'));

/// 插图册里的卡片（卡片 key 带 src，测试不预设文件名）。
Finder get _cards => find.byWidgetPredicate(
  (Widget w) =>
      w.key is ValueKey<String> &&
      (w.key! as ValueKey<String>).value.startsWith('fushi_gallery_card_'),
);

double _viewPaddingTop(WidgetTester tester) => MediaQuery.viewPaddingOf(
  tester.element(find.byType(ReaderGalleryPage)),
).top;

/// 打开焦点卡的菜单（键盘入口 = 菜单键；指针那侧是长按 / 右键）。
Future<void> _openCardMenu(WidgetTester tester) async {
  await _sendKey(tester, LogicalKeyboardKey.contextMenu);
  await tester.pumpAndSettle(const Duration(milliseconds: 500));
}

/// 网格里把焦点落到第一张卡：方向键右一下即可（没有焦点时落在第 0 张）。
Future<void> _focusFirstCard(WidgetTester tester) async {
  await _sendKey(tester, LogicalKeyboardKey.arrowRight);
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('插图册：顶栏让开系统安全区、键盘可跳转 / 恢复遮罩', (tester) async {
    await runFushiItest(
      label: 'reader-gallery-safe-area',
      body: () async {
        await launchFushiTestApp();
        expect(await waitForHome(tester), isTrue, reason: '首页未就绪');
        await enableFocusNavigation(tester);
        final FocusDriver driver = FocusDriver(tester);

        // 带真实插图的书：默认生成的书只有内联 SVG，EpubBook.images 会是空的，
        // 插图册整页退成空态，本用例就什么都验不到。
        final String bookKey = await seedReaderBook(
          tester,
          fileName: 'gallery_itest.epub',
          withRealImages: true,
        );
        await openBookViaProductionPath(tester, bookKey);
        await _pumpUntil(tester, _readerShown, reason: '阅读器未打开');
        // WebView 首屏排版给足时间（iOS 模拟器上比桌面慢）。
        for (int i = 0; i < 20; i++) {
          await tester.pump(const Duration(milliseconds: 500));
        }

        // 原始入口：G = readerOpenGallery，与底栏按钮同一个 _openGallery。
        await _sendKey(tester, LogicalKeyboardKey.keyG);
        await _pumpUntil(tester, _galleryShown, reason: '按 G 没打开插图册');
        await tester.pump(const Duration(milliseconds: 500));
        expect(_cards, findsWidgets, reason: '这本书没解析出插图，本用例取不到有效证据');
        // 像素证据：用户当初就是拿截图报的「卡片长这样」「顶栏顶到系统条」，
        // 回给同一形式最省事。插图册是纯 Flutter 面，图层树直抓即可。
        await captureFlutterFrame(tester, 'gallery-grid');

        // ① 安全区：设备给的 viewPadding 必须真的把顶栏整条推下去。
        //
        // iOS 上这条是本用例的主证据，必须真拿到一个非零状态栏高度，拿不到就是
        // 证据无效（设备选错了）而不是通过。
        //
        // **只有 iOS 算数，Android 模拟器实测验不了这条**（2026-09-15）：开书后
        // 阅读器进沉浸模式把系统栏藏了，Android 的 viewPadding.top 随之归 0 —— 那里
        // 本来就没有要让的安全区。iOS 的刘海 / 灵动岛是**物理遮挡**，safe area 不随
        // 状态栏隐藏消失，所以同一段代码只在 iOS 上显形。这也正是用户只在 iOS 报出
        // 「顶部顶到系统条点不到」的原因，别把 Android 跑绿当成这条已验证。
        // 桌面端 viewPadding 恒 0，同理退化成恒真，但后面两段照样跑得完。
        final double statusBar = _viewPaddingTop(tester);
        debugPrint('[gallery] viewPadding.top=$statusBar');
        if (defaultTargetPlatform == TargetPlatform.iOS) {
          expect(
            statusBar,
            greaterThan(20),
            reason: '这台 iOS 设备没有刘海 / 灵动岛，本用例取不到有效证据',
          );
        }
        for (final MapEntry<String, Finder> control in <String, Finder>{
          'close': _closeButton,
          'position': _positionButton,
          'filter': _filterButton,
        }.entries) {
          expect(
            control.value,
            findsOneWidget,
            reason: '顶栏控件 ${control.key} 不在页面上',
          );
          final double top = tester.getTopLeft(control.value).dy;
          debugPrint('[gallery] ${control.key}.top=$top');
          expect(
            top,
            greaterThanOrEqualTo(statusBar),
            reason: '顶栏控件 ${control.key} 仍压在状态栏底下（top=$top < $statusBar）',
          );
          // 压在状态栏下的按钮即使画出来了也点不到：在按钮中心做一次真实 hit
          // test，必须有命中路径。
          final Offset centre = tester.getCenter(control.value);
          final HitTestResult hit = HitTestResult();
          WidgetsBinding.instance.hitTestInView(
            hit,
            centre,
            tester.view.viewId,
          );
          expect(
            hit.path.isNotEmpty,
            isTrue,
            reason: '顶栏控件 ${control.key} 在 $centre 处不可命中',
          );
        }

        // ② 同一次画廊会话里验遮罩两个方向：揭开 → 恢复遮罩。
        //
        // 顺序很重要：跳转会离开画廊，放在前面就得再开一次插图册，而那一步依赖
        // 「从画廊 pop 回阅读器后快捷键立刻可用」——与本 PR 无关的另一件事。
        await _focusFirstCard(tester);
        await _openCardMenu(tester);
        expect(_menuJump, findsOneWidget, reason: '菜单键没唤出卡片菜单');
        await captureFlutterFrame(tester, 'gallery-card-menu');
        if (_menuReveal.evaluate().isNotEmpty) {
          expect(await driver.focusWidget(_menuReveal), isTrue);
          await driver.activate();
          await tester.pumpAndSettle(const Duration(milliseconds: 500));
          // 揭开后模糊层必须撤掉。
          expect(
            find.descendant(
              of: _cards.first,
              matching: find.byType(ImageFiltered),
            ),
            findsNothing,
            reason: '揭开后卡片不该还盖着模糊层',
          );
          await _openCardMenu(tester);
        }
        expect(_menuRelock, findsOneWidget, reason: '已揭开且有遮罩理由的卡必须给「恢复遮罩」');
        expect(await driver.focusWidget(_menuRelock), isTrue);
        await driver.activate();
        await tester.pumpAndSettle(const Duration(milliseconds: 500));
        // 撤销后这张卡重新盖上模糊层（墨水屏才换实心遮板，本用例非墨水屏）。
        expect(
          find.descendant(
            of: _cards.first,
            matching: find.byType(ImageFiltered),
          ),
          findsOneWidget,
          reason: '恢复遮罩后卡片必须重新盖上模糊层',
        );
        await captureFlutterFrame(tester, 'gallery-relocked');

        // 菜单关掉后焦点必须回到网格：不回，方向键就再也移不动焦点了。
        await _sendKey(tester, LogicalKeyboardKey.arrowRight);
        expect(
          await driver.focusWidget(_closeButton),
          isTrue,
          reason: '关闭按钮拿不到焦点（它此前正是被状态栏压住那三个之一）',
        );

        // ③ 收尾：菜单里的「跳转到此插图」真的回到正文对应章。
        await _focusFirstCard(tester);
        await _openCardMenu(tester);
        expect(await driver.focusWidget(_menuJump), isTrue);
        await driver.activate();
        await tester.pumpAndSettle(const Duration(seconds: 2));
        expect(_galleryShown(), isFalse, reason: '跳转后应回到正文');
        expect(_readerShown(), isTrue);
      },
    );
  });
}
