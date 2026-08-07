// UI/UX 巡检截图取证：启动真 app，播种书/有声书/视频 fixture，深浅色两套主题下
// 逐个顶层模块 tab（首页/书架/视频/下载/游戏[仅 Windows]/设置）抓取真实渲染帧。
//
// 双路落盘：
// - Android（flutter drive + test_driver/integration_test_screenshots.dart）：
//   binding.takeScreenshot → 宿主机 fushi/screenshots/<name>.png。
// - Windows 离屏（tool/run_windows_itest.ps1）：根 RenderView.toImage →
//   <evidenceDir>/screenshots/<name>.png（同 observe_offscreen_test 约定）。
//
// 只抓 Flutter 图层树，不打开阅读器/播放器（无 openMedia，纯离屏可跑）。
// 抓帧不走 pumpAndSettle——下载页/视频页可能有常驻动画（转圈/进度轮询），
// pumpAndSettle 会挂到超时；固定 pump 数帧后直接抓。
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' show Navigator, NavigatorState;
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/main.dart' as app;
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/pages/implementations/home_page.dart'
    show HomePage, HomeTab;
import 'package:fushi/src/startup/observe_blank_detector.dart';
import 'package:integration_test/integration_test.dart';

import 'helpers/library_fixture.dart';
import 'helpers/observe_capture.dart' show observeScreenshotDir;
import 'test_helpers.dart';

/// 关掉启动期弹出的模态框（如联网成功时的「发现新版本」更新弹窗），避免挡住
/// 截图。走 Navigator.pop（不点坐标）；根路由 canPop=false 时自然停。
Future<void> _dismissTopDialogs(WidgetTester tester) async {
  final NavigatorState nav =
      tester.state<NavigatorState>(find.byType(Navigator).first);
  for (int i = 0; i < 3 && nav.canPop(); i++) {
    nav.pop();
    await tester.pump(const Duration(milliseconds: 400));
    debugPrint('[survey] popped a startup dialog/route (#${i + 1})');
  }
}

/// 固定 pump 若干帧（不 settle），让页面异步内容尽量渲染出来。
Future<void> _pumpFrames(WidgetTester tester,
    {int frames = 8,
    Duration interval = const Duration(milliseconds: 250)}) async {
  for (int i = 0; i < frames; i++) {
    await tester.pump(interval);
  }
}

/// 抓根 RenderView 为 PNG 落 observeScreenshotDir（Windows 离屏证据路径）。
/// Android 上该目录不可写或抓图失败时静默返回 false（Android 走 takeScreenshot）。
Future<bool> _captureRenderView(WidgetTester tester, String name) async {
  try {
    final RenderView view = tester.binding.renderViews.first;
    final OffsetLayer? layer = view.debugLayer as OffsetLayer?;
    if (layer == null) return false;
    final ui.Image image = await layer.toImage(view.paintBounds);
    try {
      final ByteData? rgba =
          await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      final bool nonBlank =
          rgba != null && rgbaLooksNonBlank(rgba.buffer.asUint8List());
      final ByteData? png =
          await image.toByteData(format: ui.ImageByteFormat.png);
      if (png == null) return false;
      final String path = '${observeScreenshotDir().path}/$name.png';
      await File(path).writeAsBytes(png.buffer.asUint8List(), flush: true);
      debugPrint('[survey] saved $path (${png.lengthInBytes}B, '
          'nonBlank=$nonBlank)');
      return nonBlank;
    } finally {
      image.dispose();
    }
  } catch (e) {
    debugPrint('[survey] renderview capture failed ($name): $e');
    return false;
  }
}

void main() {
  final IntegrationTestWidgetsFlutterBinding binding =
      IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('UI 巡检截图：五模块 × 深浅色', (WidgetTester tester) async {
    final List<FlutterErrorDetails> errors = <FlutterErrorDetails>[];
    final FlutterExceptionHandler? oldHandler = FlutterError.onError;
    FlutterError.onError = (FlutterErrorDetails details) {
      errors.add(details);
      debugPrint('[survey] FlutterError: ${details.exceptionAsString()}');
    };

    try {
      app.main();
      expect(await waitForHome(tester), isTrue, reason: '主页应在 90s 内出现');
      await tester.pump(const Duration(seconds: 2));
      final AppModel appModel = await readyAppModel(tester);

      // 播种内容让书架/视频架非空（失败不阻断——空态本身也是巡检对象）。
      try {
        await seedReaderBook(tester);
      } catch (e) {
        debugPrint('[survey] seedReaderBook failed: $e');
      }
      try {
        await seedAudiobook(tester);
      } catch (e) {
        debugPrint('[survey] seedAudiobook failed（无 ffmpeg 可忽略）: $e');
      }
      try {
        await seedVideo(tester);
      } catch (e) {
        debugPrint('[survey] seedVideo failed（无 ffmpeg 可忽略）: $e');
      }

      await _dismissTopDialogs(tester);

      // Android 的 takeScreenshot 要求先把 Flutter surface 转成图像渲染，
      // 否则抛 "Call convertFlutterSurfaceToImage() before taking a screenshot"。
      if (!kIsWeb && Platform.isAndroid) {
        try {
          await binding.convertFlutterSurfaceToImage();
          await tester.pump(const Duration(seconds: 1));
        } catch (e) {
          debugPrint('[survey] convertFlutterSurfaceToImage failed: $e');
        }
      }

      final List<HomeTab> tabs = <HomeTab>[
        HomeTab.home,
        HomeTab.books,
        HomeTab.video,
        HomeTab.downloads,
        if (Platform.isWindows) HomeTab.games,
        HomeTab.settings,
      ];
      expect(HomePage.debugSelectTab, isNotNull,
          reason: 'HomePage.debugSelectTab 测试钩子应已注册（debug build）');

      final String originalBrightness = appModel.themeNotifier.brightnessMode;
      int nonBlankCount = 0;
      for (final String mode in <String>['dark', 'light']) {
        await appModel.themeNotifier.setBrightnessMode(mode);
        await _pumpFrames(tester, frames: 4);
        await _dismissTopDialogs(tester);
        for (final HomeTab tab in tabs) {
          HomePage.debugSelectTab!(tab);
          await _pumpFrames(tester);
          final String name = 'survey-$mode-${tab.name}';
          // Android cwd 只读，RenderView 本地落盘只在桌面跑；Android 走 driver
          // 的 takeScreenshot 回传宿主机。
          if (!Platform.isAndroid) {
            final bool nonBlank = await _captureRenderView(tester, name);
            if (nonBlank) nonBlankCount++;
          }
          await takeScreenshot(binding, name);
        }
      }
      // 还原用户主题设置（模拟器默认保留 app 数据，别把巡检痕迹留下）。
      await appModel.themeNotifier.setBrightnessMode(originalBrightness);
      await tester.pump(const Duration(seconds: 1));

      // 至少各主题多数面非空白（takeScreenshot 路径由 driver 落盘，宿主侧校验）。
      debugPrint('[survey] nonBlank RenderView captures: '
          '$nonBlankCount/${tabs.length * 2}');

      assertStrictErrors(errors);
    } finally {
      FlutterError.onError = oldHandler;
    }
  });
}
