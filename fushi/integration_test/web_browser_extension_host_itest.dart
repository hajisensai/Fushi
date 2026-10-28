// app 内浏览器跑扩展内容脚本栈（扩展宿主）的真 app 取证：Windows 离屏 runner 起真 Fushi、
// 真 WebView2，本地 HttpServer 供一页带 <video> 的网页（ffmpeg 现生成 60 秒 webm）。
//
// 走一遍：整栈注入（宿主入口 / 页面全局未被污染）→ 打开 Fushi 字幕 + 装一条外挂轨 →
// 覆盖层出字 → 播放器里的 Fushi 按钮与菜单 → 点覆盖层上的字查词（app 查词弹窗、视频被暂停）
// → 关弹窗续播 → app 原生字幕侧栏。截图 `ext-NN-<名>.png`，进度 `ext-progress.log`。
//
// 跑：在 fushi/ 下 `.\tool\run_windows_itest.ps1 integration_test/web_browser_extension_host_itest.dart`
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:window_manager/window_manager.dart';

import 'package:fushi/pages.dart';
import 'package:fushi/src/pages/implementations/fushi_web_browser_page.dart';
import 'package:fushi/src/pages/implementations/srs/srs_card_lookup.dart';
import 'package:fushi/src/web_browser/features/extension_host/web_browser_extension_host_feature.dart';
import 'package:fushi/src/web_browser/features/extension_host/web_browser_subtitle_panel.dart';
import 'package:fushi/src/web_browser/tab_view/web_browser_tab_view.dart';
import 'package:fushi/src/web_browser/tabs/web_browser_tab.dart';

import 'helpers/library_fixture.dart';
import 'helpers/observe_capture.dart';
import 'support/itest_startup_guard.dart';
import 'support/test_app_launcher.dart';
import 'test_helpers.dart';

const String _kCueText = '世界の天気は晴れです';

Future<File?> _makeClip() async {
  final Directory dir = await Directory.systemTemp.createTemp('ext-itest');
  final File out = File('${dir.path}${Platform.pathSeparator}clip.webm');
  try {
    final ProcessResult r = await Process.run('ffmpeg', <String>[
      '-y',
      '-loglevel',
      'error',
      '-f',
      'lavfi',
      '-i',
      'testsrc=size=640x360:rate=15',
      '-f',
      'lavfi',
      '-i',
      'sine=frequency=440',
      '-t',
      '60',
      '-c:v',
      'libvpx',
      '-b:v',
      '200k',
      '-c:a',
      'libopus',
      '-shortest',
      out.path,
    ]);
    if (r.exitCode != 0) return null;
  } on ProcessException {
    return null;
  }
  return out.existsSync() ? out : null;
}

Future<HttpServer> _startSite(File clip) async {
  final HttpServer server = await HttpServer.bind(
    InternetAddress.loopbackIPv4,
    0,
  );
  server.listen((HttpRequest req) async {
    final HttpResponse res = req.response;
    switch (req.uri.path) {
      case '/video':
        res.headers.contentType = ContentType.html;
        res.write(
          '<!doctype html><html lang="ja"><head><meta charset="utf-8">'
          '<title>動画テスト</title><style>body{margin:24px;font:16px sans-serif}'
          '</style></head><body><h1>動画テスト</h1>'
          '<div id="player" style="position:relative;width:640px;height:360px">'
          '<video id="v" src="/clip.webm" muted autoplay loop playsinline '
          'width="640" height="360"></video></div>'
          '<p>東京は朝から晴れています。</p></body></html>',
        );
      case '/clip.webm':
        res.headers.contentType = ContentType('video', 'webm');
        await res.addStream(clip.openRead());
      default:
        res.statusCode = HttpStatus.notFound;
    }
    await res.close();
  });
  return server;
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('扩展宿主：注入 / 字幕覆盖层 / 播放器菜单 / 查词暂停与续播 / 原生侧栏', (
    WidgetTester tester,
  ) async {
    final List<FlutterErrorDetails> errors = <FlutterErrorDetails>[];
    final List<String> results = <String>[];
    File? progress;
    void log(String line) {
      final String text = '[ext-itest] $line';
      debugPrint(text);
      try {
        progress ??= File(
          '${observeScreenshotDir().parent.path}/ext-progress.log',
        );
        progress!.writeAsStringSync(
          '${DateTime.now().toIso8601String()} $text\n',
          mode: FileMode.append,
          flush: true,
        );
      } on Object {
        // 取证日志写不进去不影响测试本身。
      }
    }

    void result(String item, bool ok, [String note = '']) {
      final String line = '${ok ? 'PASS' : 'FAIL'} $item $note';
      results.add(line);
      log(line);
    }

    int shotIndex = 0;
    HttpServer? site;
    Size? originalSize;

    await runFushiItest(
      label: 'ext-itest',
      collectedErrors: errors,
      body: () async {
        final File? clip = await _makeClip();
        expect(clip, isNotNull, reason: '需要 ffmpeg 生成测试视频');
        await launchFushiTestApp();
        expect(await waitForHome(tester), isTrue, reason: '主页应在 90s 内出现');
        await tester.pump(const Duration(seconds: 2));
        await readyAppModel(tester);
        site = await _startSite(clip!);
        final String base = 'http://127.0.0.1:${site!.port}';
        log('site=$base');

        Future<void> settle([int ms = 600]) async {
          for (int i = 0; i < ms ~/ 50; i++) {
            await tester.pump(const Duration(milliseconds: 50));
          }
        }

        FushiWebBrowserPageState page() =>
            tester.state<FushiWebBrowserPageState>(
              find.byType(FushiWebBrowserPage, skipOffstage: false),
            );
        WebBrowserTab? active() => page().tabsController.activeTab;
        WebBrowserExtensionHostFeature host() =>
            page().features.whereType<WebBrowserExtensionHostFeature>().single;
        SrsCardLookupController lookup() => SrsCardLookupScope.of(
          tester.element(find.byType(WebBrowserTabView).first),
        )!;

        Future<bool> waitFor(
          FutureOr<bool> Function() cond, {
          Duration timeout = const Duration(seconds: 20),
        }) async {
          final DateTime end = DateTime.now().add(timeout);
          while (DateTime.now().isBefore(end)) {
            if (await cond()) return true;
            await tester.pump(const Duration(milliseconds: 200));
          }
          return await cond();
        }

        Future<Object?> js(String source) async {
          final InAppWebViewController? c = active()?.controller;
          if (c == null) return null;
          try {
            return await c
                .evaluateJavascript(source: source)
                .timeout(const Duration(seconds: 10));
          } on Object catch (e) {
            log('js failed: $e');
            return null;
          }
        }

        Future<void> shot(String name) async {
          await settle(500);
          shotIndex++;
          final String full =
              'ext-${shotIndex.toString().padLeft(2, '0')}-$name';
          final RenderView view = tester.binding.renderViews.first;
          final OffsetLayer layer = view.debugLayer! as OffsetLayer;
          final ui.Image frame = await layer.toImage(view.paintBounds);
          try {
            final ByteData? png = await frame.toByteData(
              format: ui.ImageByteFormat.png,
            );
            await File(
              '${observeScreenshotDir().path}/$full.png',
            ).writeAsBytes(png!.buffer.asUint8List(), flush: true);
          } finally {
            frame.dispose();
          }
          log('shot $full');
        }

        originalSize = await windowManager.getSize();
        await windowManager.setSize(const Size(1300, 860));
        await settle(800);

        final BuildContext ctx = tester.element(find.byType(HomePage));
        unawaited(openFushiWebBrowser(ctx, Uri.parse('$base/video')));
        await settle(1500);
        final bool loaded = await waitFor(() {
          final WebBrowserTab? t = active();
          return t != null &&
              t.controller != null &&
              (t.url?.path == '/video') &&
              !t.loading;
        }, timeout: const Duration(seconds: 40));
        result('页面加载', loaded);

        // ① 整栈注入 + 页面全局未被污染
        final bool injected = await waitFor(
          () async => await js('typeof window.__fushiExtHost') == 'object',
        );
        result('整栈注入（__fushiExtHost）', injected);
        final Object? globals = await js(
          'JSON.stringify({sel: typeof window.fushiSelection, '
          'bridge: typeof (window.flutter_inappwebview && window.flutter_inappwebview.callHandler), '
          'chrome: typeof window.chrome === "object" && !!window.chrome.runtime && !!window.chrome.runtime.sendMessage, '
          'panel: typeof window.fushiSubtitleTrackList})',
        );
        log('globals=$globals');
        final Map<String, dynamic> g = globals is String
            ? jsonDecode(globals) as Map<String, dynamic>
            : <String, dynamic>{};
        result('app 的 JS 桥完好', g['bridge'] == 'function', '$globals');
        result('页面拿不到扩展 chrome 垫片', g['chrome'] != true, '$globals');
        result('字幕契约在（subtitle-panel.js 跑完）', g['panel'] == 'function');
        final bool playing = await waitFor(
          () async =>
              await js(
                '(function(){var v=document.getElementById("v");'
                'return !!v && !v.paused && v.currentTime > 0;})()',
              ) ==
              true,
        );
        result('视频在播', playing);

        // ② 打开 Fushi 字幕 + 装外挂轨 → 覆盖层出字
        await host().setStorage(<String, Object?>{
          'subtitleOverlayEnabled': true,
          'netflixSubtitlePanel': true,
        });
        await settle(800);
        final Object? installed = await host().request(
          active()!,
          <String, Object?>{
            'type': 'fushiSubtitleSidePanelInstallTrack',
            'filename': 'itest.srt',
            'cues': <Object?>[
              <String, Object?>{
                'startMs': 0,
                'endMs': 60000,
                'text': _kCueText,
              },
            ],
          },
        );
        log('install=${jsonEncode(installed)}');
        result('外挂轨装上', installed is Map && installed['ok'] == true);
        final bool overlay = await waitFor(
          () async =>
              await js(
                '(function(){var o=document.getElementById("fushi-subtitle-overlay");'
                'return !!o && (o.textContent||"").indexOf("$_kCueText") >= 0;})()',
              ) ==
              true,
        );
        result('字幕覆盖层出字', overlay);
        await shot('overlay');

        // ③ 播放器里的 Fushi 按钮与菜单
        await js(
          '(function(){var v=document.getElementById("v");'
          'v.dispatchEvent(new MouseEvent("mouseover",{bubbles:true}));'
          'v.dispatchEvent(new MouseEvent("mousemove",{bubbles:true}));})()',
        );
        final bool button = await waitFor(
          () async =>
              await js('!!document.getElementById("fushi-player-btn")') == true,
        );
        result('播放器 Fushi 按钮', button);
        await js(
          '(function(){var b=document.getElementById("fushi-player-btn");'
          'if (b) b.click();})()',
        );
        final bool menu = await waitFor(
          () async =>
              await js(
                '(function(){var m=document.getElementById("fushi-player-controls");'
                'return !!m && m.getBoundingClientRect().width > 0 && getComputedStyle(m).display !== "none" && (m.textContent||"").length > 0;})()',
              ) ==
              true,
          timeout: const Duration(seconds: 8),
        );
        final Object? menuText = await js(
          '(document.getElementById("fushi-player-controls")||{}).innerText || ""',
        );
        log('menu=${menuText.toString().replaceAll('\n', ' | ')}');
        result('播放器菜单打开', menu);
        await shot('player-menu');
        await js(
          '(function(){var b=document.getElementById("fushi-player-btn");'
          'if (b) b.click();})()',
        );
        await settle(400);

        // ④ 点覆盖层上的字查词 → app 查词弹窗、视频被暂停
        final Object? rectRaw = await js(
          '(function(){var o=document.querySelector("#fushi-subtitle-overlay .fushi-subtitle-overlay-text");'
          'if(!o) return null; var n=o.firstChild; while(n && n.nodeType!==3) n=n.firstChild;'
          'var r=document.createRange(); if(!n) return null; r.setStart(n,0); r.setEnd(n,1);'
          'var b=r.getBoundingClientRect(); return JSON.stringify({x:b.left+b.width/2,y:b.top+b.height/2});})()',
        );
        log('cueRect=$rectRaw');
        bool opened = false;
        if (rectRaw is String) {
          final Map<String, dynamic> r =
              jsonDecode(rectRaw) as Map<String, dynamic>;
          await js(
            'window.fushiLookupAtPoint(${r['x']}, ${r['y']}, '
            '{startMs:0,endMs:60000,text:"$_kCueText"})',
          );
          opened = await waitFor(() => lookup().isOpen);
        }
        result('查词交给 app 弹窗', opened, 'queries=${lookup().debugQueries}');
        final bool paused = await waitFor(
          () async => await js('document.getElementById("v").paused') == true,
          timeout: const Duration(seconds: 5),
        );
        result('查词时暂停', paused);
        await shot('lookup-popup');

        // ⑤ 关弹窗 → 续播
        lookup().closeAll();
        final bool resumed = await waitFor(
          () async => await js('document.getElementById("v").paused') == false,
          timeout: const Duration(seconds: 8),
        );
        result('关弹窗续播', resumed);

        // ⑥ 「打开字幕列表」→ app 原生侧栏
        await js(
          'window.fushiSubtitleShortcut && window.fushiSubtitleShortcut("toggle-panel")',
        );
        final bool panel = await waitFor(
          () => find.byType(WebBrowserSubtitlePanel).evaluate().isNotEmpty,
          timeout: const Duration(seconds: 8),
        );
        result('原生字幕侧栏打开', panel);
        final bool rows = await waitFor(
          () => find.textContaining('世界の天気').evaluate().isNotEmpty,
          timeout: const Duration(seconds: 8),
        );
        result('侧栏列出字幕', rows);
        await shot('side-panel');
        host().closeSidePanel();
        await settle(800);
      },
    );

    try {
      if (originalSize != null) await windowManager.setSize(originalSize!);
    } on Object {
      // 窗口已关。
    }
    await site?.close(force: true);
    log(
      'SUMMARY ${results.where((String r) => r.startsWith('PASS')).length}'
      '/${results.length}',
    );
    for (final String r in results) {
      log(r);
    }
    expect(
      results.where((String r) => r.startsWith('FAIL')),
      isEmpty,
      reason: results.join('\n'),
    );
  });
}
