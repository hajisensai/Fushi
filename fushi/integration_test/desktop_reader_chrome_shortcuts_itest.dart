import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'helpers/library_fixture.dart';
import 'support/test_app_launcher.dart';
import 'test_helpers.dart';

/// 桌面端 ッツ 形态阅读器 chrome 的键盘驱动集成测试（焦点驱动纪律：不用坐标点击）。
///
/// 真 app、隐藏 runner、种一本生成的 EPUB → 生产路径开书 → 用阅读器快捷键依次打开
/// 插图画廊（G）/ 阅读统计（I）/ 导航抽屉（Ctrl+F，贴左）/ 设置抽屉（T，贴右），每步
/// 断言对应 key 的组件真在树上、Esc 能关掉；顶部工具栏本身是 ExcludeFocus 的纯指针面，
/// 所以走快捷键而不是 Tab 到按钮。
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  Future<void> pumpFor(WidgetTester tester, int ticks,
      {int ms = 250}) async {
    for (int i = 0; i < ticks; i++) {
      await tester.pump(Duration(milliseconds: ms));
    }
  }

  Future<bool> waitFor(WidgetTester tester, Finder f,
      {int maxTicks = 40}) async {
    for (int i = 0; i < maxTicks; i++) {
      await tester.pump(const Duration(milliseconds: 250));
      if (f.evaluate().isNotEmpty) return true;
    }
    return false;
  }

  Future<void> key(WidgetTester tester, LogicalKeyboardKey k,
      {bool ctrl = false}) async {
    if (ctrl) await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(k);
    if (ctrl) await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await pumpFor(tester, 4);
  }

  testWidgets(
      'desktop reader chrome: G gallery / I statistics / Ctrl+F left drawer / '
      'T right drawer open and close via keyboard', (WidgetTester tester) async {
    final List<FlutterErrorDetails> errors = <FlutterErrorDetails>[];
    final FlutterExceptionHandler? oldHandler = FlutterError.onError;
    FlutterError.onError = (FlutterErrorDetails details) {
      errors.add(details);
      debugPrint('[desktop-chrome] FlutterError: ${details.exceptionAsString()}');
    };
    try {
      await launchFushiTestApp();
      expect(await waitForHome(tester), isTrue,
          reason: 'Home must render within 90s');

      final String bookKey = await seedReaderBook(tester);
      await openBookViaProductionPath(tester, bookKey);

      // 首屏恢复完成后底部状态行才出现（桌面端 ッツ 形态的可见证据）。
      final Finder footer = find.byKey(const ValueKey<String>('fushi_status_footer'));
      expect(await waitFor(tester, footer, maxTicks: 120), isTrue,
          reason: 'reader status footer must appear after first restore');

      // G → 画廊页（生成书没有插图也会进空态页），Esc 关。
      await key(tester, LogicalKeyboardKey.keyG);
      final Finder galleryClose =
          find.byKey(const ValueKey<String>('fushi_gallery_close'));
      expect(await waitFor(tester, galleryClose), isTrue,
          reason: 'G must open the gallery page');
      await key(tester, LogicalKeyboardKey.escape);
      expect(await waitFor(tester, footer), isTrue);
      expect(galleryClose, findsNothing);

      // I → 统计浮层，Esc 关。
      await key(tester, LogicalKeyboardKey.keyI);
      final Finder statsClose =
          find.byKey(const ValueKey<String>('fushi_reader_stats_close'));
      expect(await waitFor(tester, statsClose), isTrue,
          reason: 'I must open the statistics dialog');
      expect(
        find.byKey(const ValueKey<String>('fushi_reader_stats_tracking_toggle')),
        findsOneWidget,
      );
      await key(tester, LogicalKeyboardKey.escape);
      await pumpFor(tester, 4);
      expect(statsClose, findsNothing);

      // Ctrl+F → 导航抽屉贴左。
      await key(tester, LogicalKeyboardKey.keyF, ctrl: true);
      final Finder sheet =
          find.byKey(const ValueKey<String>('fushi_reader_side_sheet'));
      expect(await waitFor(tester, sheet), isTrue,
          reason: 'Ctrl+F must open the navigation drawer');
      final Size screen = tester.getSize(find.byType(MaterialApp).first);
      final Rect navRect = tester.getRect(sheet);
      expect(navRect.left, 0, reason: 'navigation drawer is left-anchored');
      expect(navRect.right, lessThan(screen.width));
      await key(tester, LogicalKeyboardKey.escape);
      await pumpFor(tester, 4);
      expect(sheet, findsNothing);

      // T → 设置抽屉贴右，分段条在。
      await key(tester, LogicalKeyboardKey.keyT);
      expect(await waitFor(tester, sheet), isTrue,
          reason: 'T must open the settings drawer');
      final Rect settingsRect = tester.getRect(sheet);
      expect(settingsRect.right, screen.width,
          reason: 'settings drawer is right-anchored');
      expect(find.byType(SegmentedButton<String>), findsWidgets);
      await key(tester, LogicalKeyboardKey.escape);
      await pumpFor(tester, 4);
      expect(sheet, findsNothing);

      assertStrictErrors(errors);
      debugPrint('[desktop-chrome] PASS — gallery / statistics / left nav / '
          'right settings all reachable by keyboard');
    } finally {
      FlutterError.onError = oldHandler;
    }
  });
}
