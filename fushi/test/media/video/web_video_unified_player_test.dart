// 拍板 cbKi3PN0G7-r2：网页视频两档（「制卡优先」/「画质优先」）都在原生播放器页里播、同一套
// 控件；当前档位在播放器顶栏常驻可见、一点就切；内置网页播放器页（WebVideoFushiPage）不再给
// 用户当播放器打开，只当制卡重放的后台宿主。
import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/video/web_video_hosting.dart';
import 'package:fushi/src/media/video/web_video_mode_chip.dart';

import '../../helpers/source_guard.dart';

const String _webSourcePath =
    'lib/src/pages/implementations/video_fushi/web_source.part.dart';
const String _hostPagePath =
    'lib/src/pages/implementations/web_video_fushi_page.dart';
const String _playerPagePath =
    'lib/src/pages/implementations/video_fushi_page.dart';
const String _clipExportPath =
    'lib/src/pages/implementations/video_fushi/clip_export.part.dart';

/// [src] 里从 [start] 起到 [end]（不含）的一段；找不到即失败。
String _slice(String src, String start, String end) {
  final int i = src.indexOf(start);
  expect(i, greaterThanOrEqualTo(0), reason: 'missing $start');
  final int j = src.indexOf(end, i + start.length);
  expect(j, greaterThan(i), reason: 'missing $end after $start');
  return src.substring(i, j);
}

void main() {
  group('档位名与一键切换', () {
    test('两档显示名 / 能力说明 / 另一档', () {
      expect(
        webVideoModeTitle(WebVideoHosting.builtin),
        t.web_video_mode_capture_title,
      );
      expect(
        webVideoModeTitle(WebVideoHosting.windowed),
        t.web_video_mode_quality_title,
      );
      expect(
        webVideoModeSubtitle(WebVideoHosting.builtin),
        t.web_video_mode_capture_subtitle,
      );
      expect(
        webVideoModeSubtitle(WebVideoHosting.windowed),
        t.web_video_mode_quality_subtitle,
      );
      expect(
        otherWebVideoMode(WebVideoHosting.builtin),
        WebVideoHosting.windowed,
      );
      expect(
        otherWebVideoMode(WebVideoHosting.windowed),
        WebVideoHosting.builtin,
      );
    });

    testWidgets('顶栏档位标识：常驻显示档位名（文字，不是只有图标），点一下回调', (WidgetTester tester) async {
      int taps = 0;
      Widget chip(WebVideoHosting hosting) => MaterialApp(
        theme: ThemeData(useMaterial3: true),
        home: Scaffold(
          body: Center(
            child: WebVideoModeChip(
              hosting: hosting,
              tooltip: 'tip',
              onPressed: () => taps++,
            ),
          ),
        ),
      );
      await tester.pumpWidget(chip(WebVideoHosting.builtin));
      expect(find.text(t.web_video_mode_capture_title), findsOneWidget);
      expect(find.byIcon(Icons.style_outlined), findsOneWidget);
      await tester.tap(find.byType(WebVideoModeChip));
      await tester.pump();
      expect(taps, 1);

      await tester.pumpWidget(chip(WebVideoHosting.windowed));
      await tester.pumpAndSettle();
      expect(find.text(t.web_video_mode_quality_title), findsOneWidget);
      expect(find.text(t.web_video_mode_capture_title), findsNothing);
      // 命中区不小于 36dp 高（顶栏胶囊里的文字按钮）。
      expect(
        tester.getSize(find.byType(WebVideoModeChip)).height,
        greaterThanOrEqualTo(36),
      );
      expect(tester.takeException(), isNull);
    });
  });

  group('两档同一个播放器页', () {
    late String webSource;
    late String hostPage;

    setUpAll(() {
      webSource = maskComments(File(_webSourcePath).readAsStringSync());
      hostPage = maskComments(File(_hostPagePath).readAsStringSync());
    });

    test('网页站入口只在本页播：拿不到底层合成落到制卡优先，不再换成内置网页播放器页 / 浏览器', () {
      final String open = _slice(
        webSource,
        'Future<void> _openWebSource(',
        'void _onWebCaptureSurfaceCreated(',
      );
      expect(open, isNot(contains('WebVideoFushiPage')));
      expect(open, isNot(contains('fushiWebBrowserRoute')));
      expect(
        open,
        contains('WebVideoHosting hosting = WebVideoHosting.builtin;'),
      );
      expect(open, contains('await acquireUnderlayComposition()'));
      expect(open, contains('await _initWebSource(row);'));
    });

    test('制卡优先 = 可捕获档会话（软件 DRM、非底层合成），截画面走 WebView 表面', () {
      final String init = _slice(
        webSource,
        'Future<void> _initWebSource(',
        'Future<void> _persistWebPosition(',
      );
      expect(
        init,
        contains(
          'final bool captureFirst = _webHosting == WebVideoHosting.builtin;',
        ),
      );
      expect(init, contains('hosting: _webHosting,'));
      expect(init, contains('softwareDrm: captureFirst,'));
      expect(init, contains('underlay: !captureFirst,'));
      expect(init, contains('surfaceCapture: captureFirst'));
    });

    test('制卡优先档的 WebView 是 Flutter 树里的纹理：播放器档里不接命中测试，控件收点击', () {
      final String wrap = _slice(
        webSource,
        'Widget _wrapWebVideoSurface(',
        'Widget _buildWebReturnBar(',
      );
      expect(
        wrap,
        contains('IgnorePointer(ignoring: hasVideo, child: surface)'),
      );
      expect(wrap, contains('session.underlay'));
    });

    test('顶栏档位标识对两档都画，换档按站点记手动选择并原地重开本页', () {
      final String chip = _slice(
        webSource,
        'Widget? _webHostingTopBarButton(',
        'bool _webHostingAvailable(',
      );
      expect(chip, isNot(contains('widget.webSite != null')));
      expect(chip, contains('WebVideoModeChip('));
      final String sw = _slice(
        webSource,
        'Future<void> _switchWebHosting(',
        'Future<void> _runWebMineQueue(',
      );
      expect(sw, contains('kWebVideoHostingManualBySitePrefKey'));
      expect(sw, contains('VideoFushiPage.neutralized('));
      expect(sw, contains('webHosting: target,'));
      expect(sw, isNot(contains('WebVideoFushiPage')));
    });

    test('内置网页播放器页只当制卡重放宿主：打开它的地方都是制卡交接', () {
      final Directory lib = Directory('lib');
      final RegExp open = RegExp(r'WebVideoFushiPage\.neutralized\(');
      int sites = 0;
      for (final FileSystemEntity f in lib.listSync(recursive: true)) {
        if (f is! File || !f.path.endsWith('.dart')) continue;
        final String code = maskComments(f.readAsStringSync());
        for (final RegExpMatch m in open.allMatches(code)) {
          // 静态工厂自身的定义不算调用点。
          if (code.substring(m.start - 20, m.start).contains('static Widget')) {
            continue;
          }
          sites++;
          final String call = code.substring(m.start, m.start + 400);
          expect(
            call,
            contains('autoRunMineQueue: true'),
            reason: '${f.path}：内置网页播放器页只能作为制卡重放宿主打开',
          );
        }
      }
      expect(sites, greaterThan(0));
      // 本页没有用户可选的宿主档，也不再自己切档。
      expect(hostPage, isNot(contains('this.hosting')));
      expect(hostPage, isNot(contains('_switchHosting(')));
      expect(hostPage, isNot(contains('WebVideoHosting.windowed')));
    });
  });

  group('制卡优先档的能力真的接上（审查补丁）', () {
    late String webSource;
    late String playerPage;
    late String clipExport;

    setUpAll(() {
      webSource = maskComments(File(_webSourcePath).readAsStringSync());
      playerPage = maskComments(File(_playerPagePath).readAsStringSync());
      clipExport = maskComments(File(_clipExportPath).readAsStringSync());
    });

    test('截图快捷键与控制条截图钮同一条门：网页档不再一律 no-op', () {
      final String actions = _slice(
        playerPage,
        'VideoPlayerShortcutActions _buildVideoShortcutActions(',
        'ocrFrame:',
      );
      expect(actions, isNot(contains('screenshot: web')));
      expect(actions, isNot(contains('screenshotSubtitled: web')));
      expect(actions, contains('_saveScreenshot(withSubtitles: false)'));
      expect(actions, contains('_saveScreenshot(withSubtitles: true)'));
      final String save = _slice(
        clipExport,
        'Future<void> _saveScreenshot(',
        'await controller?.screenshot()',
      );
      expect(save, contains('!controller.canCaptureFrame'));
      expect(save, contains('_webFrameCaptureUnavailableMessage('));
    });

    test('画质优先档截不到帧时指明要切到制卡优先', () {
      final String msg = _slice(
        webSource,
        'String _webFrameCaptureUnavailableMessage(',
        'Future<bool> _applyWebShaderTier(',
      );
      expect(msg, contains('WebVideoHosting.windowed'));
      expect(msg, contains('t.web_video_mode_capture_needed'));
      final String ocr = _slice(
        playerPage,
        'void _ocrCurrentFrame()',
        '_manualFrameOcrRequests.value++',
      );
      expect(ocr, contains('_webFrameCaptureUnavailableMessage('));
    });

    test('选了超分但没挂上要报出来，不让面板选中态冒充已生效', () {
      final String select = _slice(
        webSource,
        'Future<void> _selectWebShaderTier(',
        'Future<void> _initWebSource(',
      );
      expect(select, contains('await _applyWebShaderTier()'));
      expect(select, contains('t.web_video_mode_shaders_failed'));
      expect(playerPage, isNot(contains('_webShaderActive')));
    });

    test('画质优先申请底层合成被拒时不再被当成可切的一档', () {
      final String open = _slice(
        webSource,
        'Future<void> _openWebSource(',
        'void _onWebCaptureSurfaceCreated(',
      );
      expect(
        open,
        contains('qualityFirstAvailable = await acquireUnderlayComposition();'),
      );
      expect(
        open,
        contains('_webQualityFirstAvailable = qualityFirstAvailable;'),
      );
    });
  });
}
