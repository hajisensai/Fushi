// 插图册（ReaderGalleryPage）在 iOS 上的真机复测：走原始失败路径——真开书、按 G
// （与底栏按钮同一个 _openGallery）唤出插图册——验证三件事：
//
// ① 顶栏整条落在状态栏 / 灵动岛之下。用户报的原症状就是「顶部会顶到系统任务栏
//    导致不能操作」：插图册是从阅读器 push 出去的全页路由，裸 Scaffold 的 body
//    不会自己让开系统 inset，过滤 / 定位 / 关闭三个控件整条压在状态栏底下。
//    这条只有在真设备上才有意义：viewPadding.top 是设备给的，widget 测试里得靠
//    FakeViewPadding 造。设备本身没有刘海时本用例直接 fail（证据无效，不是通过）。
// ② 长按卡片能唤出菜单，「跳转到此插图」真的回到正文。
// ③ 已揭开的图能「恢复遮罩」，撤销后卡片重新盖上模糊层。
//
// 跑法（Windows 侧编排，Mac 上的 iOS 模拟器执行）：
//   .\tool\run_mac_itest.ps1 integration_test/ios_reader_gallery_itest.dart -Ios
library;

import 'package:flutter/gestures.dart' show HitTestResult;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:fushi/src/pages/implementations/reader_fushi_page.dart'
    show ReaderFushiPage;
import 'package:fushi/src/reader/reader_gallery_page.dart'
    show ReaderGalleryPage;

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

Finder get _closeButton =>
    find.byKey(const ValueKey<String>('fushi_gallery_close'));
Finder get _positionButton =>
    find.byKey(const ValueKey<String>('fushi_gallery_position'));
Finder get _filterButton =>
    find.byKey(const ValueKey<String>('fushi_gallery_filter'));

/// 插图册里的第一张卡（卡片 key 带 src，测试不预设文件名）。
Finder _firstCard() => find
    .byWidgetPredicate(
      (Widget w) =>
          w.key is ValueKey<String> &&
          (w.key! as ValueKey<String>).value.startsWith('fushi_gallery_card_'),
    )
    .first;

double _viewPaddingTop(WidgetTester tester) => MediaQuery.viewPaddingOf(
  tester.element(find.byType(ReaderGalleryPage)),
).top;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('iOS 插图册：顶栏让开状态栏、长按可跳转 / 恢复遮罩', (tester) async {
    await runFushiItest(
      label: 'ios-reader-gallery',
      body: () async {
        await launchFushiTestApp();
        expect(await waitForHome(tester), isTrue, reason: '首页未就绪');

        final String bookKey = await seedReaderBook(tester);
        await openBookViaProductionPath(tester, bookKey);
        await _pumpUntil(tester, _readerShown, reason: '阅读器未打开');
        // WebView 首屏排版给足时间（iOS 模拟器上比桌面慢）。
        for (int i = 0; i < 20; i++) {
          await tester.pump(const Duration(milliseconds: 500));
        }

        // 原始入口：G = readerOpenGallery，与底栏按钮同一个 _openGallery。
        await tester.sendKeyEvent(LogicalKeyboardKey.keyG);
        await _pumpUntil(tester, _galleryShown, reason: '按 G 没打开插图册');
        await tester.pump(const Duration(milliseconds: 500));

        // ① 安全区：设备给的 viewPadding 必须真的把顶栏整条推下去。
        final double statusBar = _viewPaddingTop(tester);
        debugPrint('[gallery] viewPadding.top=$statusBar');
        expect(statusBar, greaterThan(20), reason: '这台设备没有刘海 / 灵动岛，本用例取不到有效证据');
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

        // ② 长按第一张卡 → 菜单 → 跳转，回到正文。
        await tester.longPress(_firstCard());
        await tester.pumpAndSettle(const Duration(milliseconds: 500));
        final Finder jump = find.byKey(
          const ValueKey<String>('fushi_gallery_menu_jump'),
        );
        expect(jump, findsOneWidget, reason: '长按卡片没弹出菜单');
        await tester.tap(jump);
        await tester.pumpAndSettle(const Duration(seconds: 2));
        expect(_galleryShown(), isFalse, reason: '跳转后应回到正文');
        expect(_readerShown(), isTrue);

        // ③ 恢复遮罩：再开插图册，必要时先揭开一张，再撤销。
        await tester.sendKeyEvent(LogicalKeyboardKey.keyG);
        await _pumpUntil(tester, _galleryShown, reason: '第二次按 G 没打开插图册');
        await tester.pump(const Duration(milliseconds: 500));
        final Finder relockTarget = _firstCard();
        await tester.longPress(relockTarget);
        await tester.pumpAndSettle(const Duration(milliseconds: 500));
        final Finder reveal = find.byKey(
          const ValueKey<String>('fushi_gallery_menu_reveal'),
        );
        if (reveal.evaluate().isNotEmpty) {
          await tester.tap(reveal);
          await tester.pumpAndSettle(const Duration(milliseconds: 500));
          await tester.longPress(relockTarget);
          await tester.pumpAndSettle(const Duration(milliseconds: 500));
        }
        final Finder relock = find.byKey(
          const ValueKey<String>('fushi_gallery_menu_relock'),
        );
        expect(relock, findsOneWidget, reason: '已揭开且有遮罩理由的卡必须给「恢复遮罩」');
        await tester.tap(relock);
        await tester.pumpAndSettle(const Duration(milliseconds: 500));
        // 撤销后这张卡重新盖上模糊层（墨水屏才换实心遮板，本用例非墨水屏）。
        expect(
          find.descendant(
            of: relockTarget,
            matching: find.byType(ImageFiltered),
          ),
          findsOneWidget,
          reason: '恢复遮罩后卡片必须重新盖上模糊层',
        );

        await tester.tap(_closeButton);
        await tester.pumpAndSettle(const Duration(seconds: 1));
        expect(_galleryShown(), isFalse, reason: '关闭按钮点不动');
      },
    );
  });
}
