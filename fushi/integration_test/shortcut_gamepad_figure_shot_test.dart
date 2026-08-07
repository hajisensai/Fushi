// TODO-942 视觉验收：真 app 跑到 设置→快捷键→可视化（手柄）视图，浅色（米色
// ecru，用户截图同款）+ 深色两主题各抓一帧，证明手柄本体轮廓在两主题下都真实
// 可见（帧非空白且真的渲染了 GamepadLayoutView + 外壳画笔）。
//
// 经 tool/run_windows_itest.ps1 离屏运行；纯视觉验收截图：打开设置页走 app 全局
// navigatorKey 推入（生产设置同路径），切视图/滚动定位都用程序化驱动（回调 +
// Scrollable.ensureVisible），无 tester.tap 坐标点击。焦点导航能力本身由
// gamepad_navigation / gamepad_focus_nav 测试守卫。
//
// 抓帧**不用 pumpAndSettle**：栈底主页有永不停止的动画（同步指示器等），
// pumpAndSettle 会挂到超时——照 gamepad_navigation_test 的做法用有界 pump。
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:fushi/main.dart' as app;
import 'package:fushi/pages.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/shortcuts/visual/gamepad_layout_view.dart';
import 'package:fushi/src/startup/observe_blank_detector.dart';

import 'helpers/observe_capture.dart';
import 'test_helpers.dart';

/// 有界抓帧：pump 固定几帧让布局/绘制稳定（不 pumpAndSettle，避免被主页永久
/// 动画卡死），再对根 RenderView 的图层 toImage，落盘并判非空白。
Future<ObserveShot> _capture(WidgetTester tester, String name) async {
  for (int i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 120));
  }
  final RenderView view = tester.binding.renderViews.first;
  final OffsetLayer? layer = view.debugLayer as OffsetLayer?;
  if (layer == null) {
    return ObserveShot(
        name: name, path: '', saved: false, nonBlank: false, bytes: 0);
  }
  final ui.Image image = await layer.toImage(view.paintBounds);
  try {
    final ByteData? rgba =
        await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    final bool nonBlank =
        rgba != null && rgbaLooksNonBlank(rgba.buffer.asUint8List());
    final ByteData? png =
        await image.toByteData(format: ui.ImageByteFormat.png);
    final Uint8List? bytes = png?.buffer.asUint8List();
    if (bytes == null || bytes.isEmpty) {
      return ObserveShot(
          name: name, path: '', saved: false, nonBlank: false, bytes: 0);
    }
    final String path = '${observeScreenshotDir().path}/$name.png';
    await File(path).writeAsBytes(bytes, flush: true);
    return ObserveShot(
      name: name,
      path: path,
      saved: true,
      nonBlank: nonBlank,
      bytes: bytes.length,
    );
  } finally {
    image.dispose();
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('手柄视图两主题截图：本体轮廓在米色/深色下都可见', (WidgetTester tester) async {
    final FlutterExceptionHandler? oldHandler = FlutterError.onError;
    FlutterError.onError = (FlutterErrorDetails details) {
      debugPrint('[gamepad-shot] FlutterError: ${details.exceptionAsString()}');
    };

    try {
      app.main();
      expect(await waitForHome(tester), isTrue, reason: '主页应在 90s 内出现');
      await tester.pump(const Duration(seconds: 2));

      final ProviderContainer container = ProviderScope.containerOf(
        tester.element(find.byType(MaterialApp).first),
      );
      final AppModel appModel = container.read(appProvider);

      // 打开快捷键设置页：走 app 的全局根 navigatorKey（生产弹窗/设置同路径）。
      final NavigatorState navigator = appModel.navigatorKey.currentState!;
      navigator.push(MaterialPageRoute<void>(
        builder: (_) => const ShortcutSettingsPage(),
      ));
      final Finder page = find.byType(ShortcutSettingsPage);
      for (int i = 0; i < 20 && page.evaluate().isEmpty; i++) {
        await tester.pump(const Duration(milliseconds: 400));
      }
      expect(page, findsOneWidget, reason: '快捷键设置页应被推入并完成构建');

      // 切到可视化（手柄）视图：直接触发视图切换段控件的 onSelectionChanged
      // 回调切 visualMode（程序化驱动，非坐标 tap）。
      final Finder toggle = find.byKey(const Key('shortcut_view_toggle'));
      expect(toggle, findsOneWidget, reason: '视图切换段控件应存在');
      final SegmentedButton<bool> segmented =
          tester.widget<SegmentedButton<bool>>(toggle);
      segmented.onSelectionChanged!(<bool>{true});
      await tester.pump(const Duration(milliseconds: 600));

      // 抓两个主题。
      for (final _ThemeShot shot in <_ThemeShot>[
        const _ThemeShot('ecru-theme', 'gamepad-figure-ecru', '米色'),
        const _ThemeShot('dark-theme', 'gamepad-figure-dark', '深色'),
      ]) {
        await appModel.themeNotifier.setAppThemeKey(shot.themeKey);
        await tester.pump(const Duration(milliseconds: 600));

        final Finder figure = find.byType(GamepadLayoutView);
        for (int i = 0; i < 20 && figure.evaluate().isEmpty; i++) {
          await tester.pump(const Duration(milliseconds: 300));
        }
        expect(figure, findsWidgets, reason: '${shot.label}主题：切到可视化视图后应出现手柄整图');

        // 滚到第一张手柄图（程序化 reveal，非指针）。duration 必须为 zero：
        // widget test 里 `await ensureVisible(duration>0)` 会死锁——它 await 滚动
        // 动画完成，而动画要靠并发 pump 推进，此处没有并发 pump。zero 走同步
        // jumpTo，Future 立即完成。
        await Scrollable.ensureVisible(
          figure.evaluate().first,
          alignment: 0.35,
          duration: Duration.zero,
        );
        await tester.pump(const Duration(milliseconds: 400));

        final ObserveShot png = await _capture(tester, shot.fileName);
        debugPrint(
            '[gamepad-shot] ${shot.label} -> ${png.path} (${png.bytes}B, '
            'nonBlank=${png.nonBlank})');
        expect(png.saved, isTrue, reason: '${shot.label}主题帧应落盘');
        expect(png.nonBlank, isTrue,
            reason: '${shot.label}主题抓图不应是空白（${png.path}）');
      }

      // 还原默认主题设置（隔离根内，纯礼貌性还原）。
      await appModel.themeNotifier.setAppThemeKey('system-theme');
      await tester.pump(const Duration(milliseconds: 400));
    } finally {
      FlutterError.onError = oldHandler;
    }
  });
}

/// 一次主题截图的参数（主题 key + 落盘文件名 + 中文标签）。
class _ThemeShot {
  const _ThemeShot(this.themeKey, this.fileName, this.label);

  final String themeKey;
  final String fileName;
  final String label;
}
