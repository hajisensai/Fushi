// app 内浏览器（多标签页壳）真 app 取证：Windows 离屏 runner 起真 Fushi、真 WebView2，
// 本地 HttpServer（127.0.0.1）供页，逐项走一遍壳的布局与交互并截图。
//
// 截图三种：
//   - `wb-NN-<名>.png`：根图层 toImage（Windows 上 WebView2 是外部纹理层，网页像素
//     也在里面）。
// 进度另写 `<evidence>/wb-progress.log`（runner 只在进程结束时才把 stdout 落盘，
// 中途卡死时什么都看不到）。
//
// 操作一律焦点驱动（requestFocus + Enter / 快捷键）或 debug 钩子，不点坐标。网页
// 内容里的交互（target=_blank 链接、window.open 按钮）走 JS focus + CDP 键盘 Enter，
// 带真实的用户激活。
//
// 跑：在 fushi/ 下 `.\tool\run_windows_itest.ps1 integration_test/web_browser_shell_itest.dart`
import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:window_manager/window_manager.dart';

import 'package:fushi/models.dart';
import 'package:fushi/pages.dart';
import 'package:fushi/src/pages/implementations/fushi_web_browser_page.dart';
import 'package:fushi/src/web_browser/data/web_browser_store.dart';
import 'package:fushi/src/web_browser/tabs/web_browser_tab.dart';
import 'package:fushi/src/web_browser/web_browser_prefs.dart';

import 'helpers/library_fixture.dart';
import 'helpers/observe_capture.dart';
import 'support/itest_startup_guard.dart';
import 'support/test_app_launcher.dart';
import 'test_helpers.dart';

const String _kDownloadName = 'fushi-itest-download.txt';

/// 自签 HTTPS 站点（SAN=127.0.0.1）：让 WebView2 报证书错误，验证失败页接住它，
/// 而不是停在 WebView2 自带的拦截页。证书在运行时用 openssl 现生成（不把私钥入库）；
/// 本机找不到 openssl 时返回 null，该步记为跳过。
Future<HttpServer?> _startSelfSignedSite() async {
  final List<String> candidates = <String>[
    'openssl',
    r'C:\Program Files\Git\usr\bin\openssl.exe',
  ];
  final Directory dir = await Directory.systemTemp.createTemp('wb-itest-tls');
  final String cert = '${dir.path}${Platform.pathSeparator}c.pem';
  final String key = '${dir.path}${Platform.pathSeparator}k.pem';
  for (final String exe in candidates) {
    try {
      final ProcessResult r = await Process.run(exe, <String>[
        'req',
        '-x509',
        '-newkey',
        'rsa:2048',
        '-nodes',
        '-keyout',
        key,
        '-out',
        cert,
        '-days',
        '2',
        '-subj',
        '/CN=fushi-itest-self-signed',
        '-addext',
        'subjectAltName=IP:127.0.0.1',
      ]);
      if (r.exitCode == 0) break;
    } on ProcessException {
      continue;
    }
  }
  if (!File(cert).existsSync() || !File(key).existsSync()) return null;
  final SecurityContext context = SecurityContext()
    ..useCertificateChain(cert)
    ..usePrivateKey(key);
  final HttpServer server = await HttpServer.bindSecure(
    InternetAddress.loopbackIPv4,
    0,
    context,
  );
  server.listen((HttpRequest req) async {
    req.response.headers.contentType = ContentType.html;
    req.response.write('<!doctype html><title>insecure</title>insecure');
    await req.response.close();
  }, onError: (Object _) {});
  return server;
}

/// 本地测试站点。
Future<HttpServer> _startSite() async {
  final HttpServer server = await HttpServer.bind(
    InternetAddress.loopbackIPv4,
    0,
  );
  server.listen((HttpRequest req) async {
    final HttpResponse res = req.response;
    String html(String title, String body) =>
        '<!doctype html><html lang="ja"><head><meta charset="utf-8">'
        '<meta name="viewport" content="width=device-width">'
        '<title>$title</title><style>body{font:16px/1.7 sans-serif;'
        'margin:24px;max-width:760px}</style></head><body>$body</body></html>';
    switch (req.uri.path) {
      case '/article':
        res.headers.contentType = ContentType.html;
        res.write(
          html(
            'テスト記事 ${req.uri.queryParameters['from'] ?? ''}',
            '<h1>今日の天気と交通情報</h1>'
                '<p>東京は朝から晴れています。電車は平常どおり運行しています。</p>'
                '<p>from=${req.uri.queryParameters['from'] ?? '-'}</p>',
          ),
        );
      case '/popups':
        res.headers.contentType = ContentType.html;
        res.write(
          html(
            '新しいウィンドウ',
            '<h1>新窗口测试</h1>'
                '<p><a id="blank" href="/article?from=blank" target="_blank">'
                'target=_blank のリンク</a></p>'
                '<p><button id="open" onclick="window.open(\'/article?from=open\')">'
                'window.open ボタン</button></p>'
                '<p><a id="dl" href="/download">ダウンロード</a></p>',
          ),
        );
      case '/download':
        res.headers
          ..contentType = ContentType.text
          ..set(
            'content-disposition',
            'attachment; filename="$_kDownloadName"',
          );
        res.write('fushi itest download body\n' * 64);
      case '/long':
        res.headers.contentType = ContentType.html;
        final StringBuffer b = StringBuffer('<h1>長いページ</h1>');
        for (int i = 0; i < 120; i++) {
          b.write(
            '<p>第$i段落。吾輩は猫である。名前はまだ無い。'
            '${i % 10 == 0 ? '<b>needle</b> ' : ''}どこで生れたかとんと見当がつかぬ。</p>',
          );
        }
        res.write(html('長いページ', b.toString()));
      default:
        res.statusCode = HttpStatus.notFound;
    }
    await res.close();
  });
  return server;
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('app 内浏览器壳：宽窗口两种标签样式 / 菜单 / 新窗口 / 查找 / 下载 / 数据页 / 失败页 / 窄窗口', (
    WidgetTester tester,
  ) async {
    final List<FlutterErrorDetails> errors = <FlutterErrorDetails>[];
    final List<String> results = <String>[];
    File? progress;
    void log(String line) {
      final String text = '[wb-itest] $line';
      debugPrint(text);
      try {
        progress ??= File(
          '${observeScreenshotDir().parent.path}/wb-progress.log',
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

    /// 平台调用（WebView 方法通道）一律限时：WebView 卡住时测试报错而不是吊死。
    Future<T?> plat<T>(
      String what,
      Future<T> Function() call, {
      Duration timeout = const Duration(seconds: 15),
    }) async {
      try {
        return await call().timeout(timeout);
      } on Object catch (e) {
        log('platform call "$what" failed: $e');
        return null;
      }
    }

    void result(String item, bool ok, [String note = '']) {
      final String line = '${ok ? 'PASS' : 'FAIL'} $item $note';
      results.add(line);
      log(line);
    }

    int shotIndex = 0;
    Size? originalSize;
    HttpServer? site;
    HttpServer? insecure;
    String? downloadPath;

    await runFushiItest(
      label: 'wb-itest',
      collectedErrors: errors,
      body: () async {
        await launchFushiTestApp();
        expect(await waitForHome(tester), isTrue, reason: '主页应在 90s 内出现');
        await tester.pump(const Duration(seconds: 2));
        final AppModel appModel = await readyAppModel(tester);

        site = await _startSite();
        final String base = 'http://127.0.0.1:${site!.port}';
        log('site=$base');

        // ── 工具 ──────────────────────────────────────────────────────
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

        Future<bool> waitFor(
          bool Function() cond, {
          Duration timeout = const Duration(seconds: 20),
        }) async {
          final DateTime end = DateTime.now().add(timeout);
          while (DateTime.now().isBefore(end)) {
            if (cond()) return true;
            await tester.pump(const Duration(milliseconds: 100));
          }
          return cond();
        }

        Future<bool> waitLoaded(String pathPart) => waitFor(() {
          final WebBrowserTab? t = active();
          return t != null &&
              t.controller != null &&
              (t.url?.toString().contains(pathPart) ?? false) &&
              !t.loading;
        });

        Future<String> shot(String name) async {
          await settle(400);
          shotIndex++;
          final String full =
              'wb-${shotIndex.toString().padLeft(2, '0')}-$name';
          // Windows 上 WebView2 纹理是 Flutter 的外部纹理层，根图层 toImage 已含
          // 网页像素（首轮实测），不必再拼 CDP 截图。
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
          return full;
        }

        /// [finder] 下第一个可聚焦节点。
        FocusNode? focusNodeIn(Finder finder) {
          for (final Element e
              in find
                  .descendant(
                    of: finder,
                    matching: find.byType(Focus),
                    matchRoot: true,
                  )
                  .evaluate()) {
            // Focus 元素的子元素就是它的 _FocusInheritedScope；从那里不建依赖地
            // 取，拿到的正是这个 Focus 自己的节点（建依赖会让 scope 依赖自己，
            // 触发 framework「really is our descendant」断言——首轮踩过）。
            FocusNode? resolved = (e.widget as Focus).focusNode;
            if (resolved == null) {
              e.visitChildElements((Element c) {
                resolved ??= Focus.maybeOf(
                  c,
                  scopeOk: false,
                  createDependency: false,
                );
              });
            }
            if (resolved != null && resolved!.canRequestFocus) return resolved;
          }
          return null;
        }

        /// 焦点驱动「按下」：聚焦 [key] 下的控件，按 Enter。
        Future<bool> activate(Key key) async {
          final Finder f = find.byKey(key);
          if (f.evaluate().isEmpty) {
            log('activate: $key not found');
            return false;
          }
          final FocusNode? node = focusNodeIn(f.first);
          if (node == null) {
            log('activate: $key has no focus node');
            return false;
          }
          node.requestFocus();
          await settle(200);
          await tester.sendKeyEvent(LogicalKeyboardKey.enter);
          await settle(500);
          return true;
        }

        Future<void> chord(LogicalKeyboardKey key, {bool shift = false}) async {
          await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
          if (shift) {
            await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
          }
          await tester.sendKeyEvent(key);
          if (shift) await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
          await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
          await settle(500);
        }

        /// 让浏览页里的某个 Flutter 控件持焦（快捷键 Focus 在页面根上）。
        Future<void> focusChrome() async {
          focusNodeIn(
            find.byKey(const ValueKey<String>('web-browser-more')).first,
          )?.requestFocus();
          await settle(200);
        }

        Future<void> loadInActive(String url) async {
          log('load $url');
          await plat(
            'loadUrl',
            () => active()!.controller!.loadUrl(
              urlRequest: URLRequest(url: WebUri(url)),
            ),
          );
        }

        Future<void> webEnterOn(String id) async {
          final InAppWebViewController c = active()!.controller!;
          log('web enter on #$id');
          await plat(
            'focus #$id',
            () => c.evaluateJavascript(
              source: 'document.getElementById("$id").focus();',
            ),
          );
          for (final String type in <String>['keyDown', 'keyUp']) {
            await plat(
              'cdp $type',
              () => c.callDevToolsProtocolMethod(
                methodName: 'Input.dispatchKeyEvent',
                parameters: <String, dynamic>{
                  'type': type,
                  'key': 'Enter',
                  'code': 'Enter',
                  'windowsVirtualKeyCode': 13,
                  'nativeVirtualKeyCode': 13,
                  if (type == 'keyDown') 'text': '\r',
                },
              ),
              // 激活链接后 WebView2 的 CDP 完成回调一直不回（首轮实测，新标签页
              // 照常开出），这里只等几秒。
              timeout: const Duration(seconds: 3),
            );
          }
        }

        bool menuOpen(String id) => find
            .byKey(ValueKey<String>('web-browser-menu-$id'))
            .evaluate()
            .isNotEmpty;

        Future<void> dismissPopup() async {
          await tester.sendKeyEvent(LogicalKeyboardKey.escape);
          await settle(500);
        }

        // ── 宽窗口 ────────────────────────────────────────────────────
        originalSize = await windowManager.getSize();
        await windowManager.setSize(const Size(1300, 820));
        await settle(800);
        final ui.FlutterView fv = tester.binding.platformDispatcher.views.first;
        log(
          'window outer=${await windowManager.getSize()} '
          'client=${fv.physicalSize / fv.devicePixelRatio}',
        );
        // 起点：侧边栏样式。
        await setWebBrowserTabStyle(
          appModel.prefsRepo,
          WebBrowserTabStyle.sidebar,
        );
        await setWebBrowserSidebarOpen(appModel.prefsRepo, true);

        final BuildContext ctx = tester.element(find.byType(HomePage));
        unawaited(openFushiWebBrowser(ctx, Uri.parse('$base/article')));
        await settle(1500);
        expect(
          find.byType(FushiWebBrowserPage, skipOffstage: false),
          findsOneWidget,
        );
        final bool loaded = await waitLoaded('/article');
        result('首页加载文章', loaded, 'title="${active()?.title}"');
        // Windows fork 的 getTitle 曾误回地址，标签名 / 书签名全成了网址。
        result(
          '标签名取页面标题',
          active()?.title.trim() == 'テスト記事',
          'title="${active()?.title}"',
        );
        // 标签名取证：页面自己的 document.title 与平台 getTitle 对照。
        final Object? docTitle = await plat<dynamic>(
          'document.title',
          () => active()!.controller!.evaluateJavascript(
            source: 'document.title',
          ),
        );
        final String? platTitle = await plat<String?>(
          'getTitle',
          () => active()!.controller!.getTitle(),
        );
        log('title probe: document.title="$docTitle" getTitle="$platTitle"');
        // 页面加载后脚本改标题，平台标题是否跟上。
        await plat<dynamic>(
          'set document.title',
          () => active()!.controller!.evaluateJavascript(
            source: 'document.title = "Probe Title";',
          ),
        );
        await settle(1500);
        final String? platTitle2 = await plat<String?>(
          'getTitle',
          () => active()!.controller!.getTitle(),
        );
        result(
          '脚本改标题同步到标签',
          active()?.title == 'Probe Title' && platTitle2 == 'Probe Title',
          'tab.title="${active()?.title}" getTitle="$platTitle2"',
        );
        await settle(1000);

        // 1. 侧边栏模式
        final bool sidebar = find
            .byKey(const ValueKey<String>('web-browser-sidebar'))
            .evaluate()
            .isNotEmpty;
        result('侧边栏模式渲染', sidebar);
        await shot('sidebar');

        // 2. ⋯ 菜单
        final bool menuActivated = await activate(
          const ValueKey<String>('web-browser-more'),
        );
        final bool menuShown = menuOpen('history') && menuOpen('new-tab');
        result('⋯ 菜单（焦点+Enter）', menuActivated && menuShown);
        await shot('more-menu');
        await dismissPopup();

        // 3. 标签右键菜单 → 改为顶部标签栏
        final WebBrowserTab first = active()!;
        final Finder sidebarTab = find.byKey(
          ValueKey<String>('web-browser-sidebar-tab-${first.id}'),
        );
        final Offset at = sidebarTab.evaluate().isNotEmpty
            ? tester.getCenter(sidebarTab.first)
            : const Offset(120, 120);
        page().debugShowTabContextMenu(first, at);
        await settle(700);
        result('标签右键菜单', menuOpen('use-top') && menuOpen('tab-close'));
        await shot('tab-context-menu');
        final bool switched = await activate(
          const ValueKey<String>('web-browser-menu-use-top'),
        );
        await settle(800);
        final bool strip = find
            .byKey(const ValueKey<String>('web-browser-tab-strip'))
            .evaluate()
            .isNotEmpty;
        result(
          '右键菜单切到顶部标签栏',
          switched &&
              strip &&
              webBrowserTabStyle(appModel.prefsRepo) ==
                  WebBrowserTabStyle.topStrip,
        );
        await shot('top-strip');

        // 4. 新窗口：target=_blank 与 window.open 都开新标签页
        await loadInActive('$base/popups');
        await waitLoaded('/popups');
        await settle(800);
        final int before = page().tabsController.length;
        await webEnterOn('blank');
        final bool blankTab = await waitFor(
          () => page().tabsController.length == before + 1,
          timeout: const Duration(seconds: 10),
        );
        await waitFor(
          () => active()?.url?.toString().contains('from=blank') ?? false,
          timeout: const Duration(seconds: 10),
        );
        result(
          'target=_blank 开新标签页',
          blankTab,
          'tabs=${page().tabsController.length} active=${active()?.url}',
        );
        await waitFor(() => !(active()?.loading ?? true));
        await shot('new-window-blank');
        // 回到 popups 页点 window.open
        final WebBrowserTab popupsTab = page().tabsController.tabs.firstWhere(
          (WebBrowserTab t) => t.url?.path == '/popups',
        );
        page().tabsController.activate(popupsTab);
        await settle(800);
        final int before2 = page().tabsController.length;
        await webEnterOn('open');
        final bool openTab = await waitFor(
          () => page().tabsController.length == before2 + 1,
          timeout: const Duration(seconds: 10),
        );
        await waitFor(
          () => active()?.url?.toString().contains('from=open') ?? false,
          timeout: const Duration(seconds: 10),
        );
        result(
          'window.open 开新标签页',
          openTab,
          'tabs=${page().tabsController.length} active=${active()?.url}',
        );
        await waitFor(() => !(active()?.loading ?? true));
        await shot('new-window-open');

        // 5. 快捷键：Ctrl+T 新标签页 / Ctrl+W 关 / Ctrl+Shift+T 重开 / Ctrl+Tab
        await focusChrome();
        final int n0 = page().tabsController.length;
        await chord(LogicalKeyboardKey.keyT);
        final bool ctrlT = page().tabsController.length == n0 + 1;
        result('Ctrl+T 新标签页', ctrlT, 'tabs=${page().tabsController.length}');
        await shot('new-tab-start');
        await focusChrome();
        await chord(LogicalKeyboardKey.keyW);
        result(
          'Ctrl+W 关标签页',
          page().tabsController.length == n0,
          'tabs=${page().tabsController.length}',
        );
        await focusChrome();
        final WebBrowserTab beforeTab = active()!;
        await chord(LogicalKeyboardKey.tab);
        result('Ctrl+Tab 下一标签页', !identical(active(), beforeTab));
        await focusChrome();
        final int n1 = page().tabsController.length;
        await chord(LogicalKeyboardKey.keyW);
        await focusChrome();
        await chord(LogicalKeyboardKey.keyT, shift: true);
        await settle(800);
        result(
          'Ctrl+Shift+T 重开关闭的标签页',
          page().tabsController.length == n1,
          'tabs=${page().tabsController.length}',
        );

        // 6. 页内查找
        page().tabsController.activate(first);
        await settle(500);
        await loadInActive('$base/long');
        await waitLoaded('/long');
        await settle(800);
        await focusChrome();
        await chord(LogicalKeyboardKey.keyF);
        final bool findOpen = active()?.findOpen ?? false;
        result('Ctrl+F 打开查找条', findOpen);
        if (findOpen) {
          final Finder field = find.descendant(
            of: find.byKey(const ValueKey<String>('web-browser-find-bar')),
            matching: find.byType(EditableText),
          );
          if (field.evaluate().isNotEmpty) {
            await tester.enterText(field.first, 'needle');
            await settle(1500);
          }
          final Finder count = find.byKey(
            const ValueKey<String>('web-browser-find-count'),
          );
          final String countText = count.evaluate().isEmpty
              ? '(none)'
              : (find
                    .descendant(
                      of: count,
                      matching: find.byType(Text),
                      matchRoot: true,
                    )
                    .evaluate()
                    .map((Element e) => (e.widget as Text).data)
                    .join(','));
          result('查找计数', countText.contains('12'), 'count=$countText');
        }
        await shot('find-bar');
        if (active()?.findOpen ?? false) {
          await activate(const ValueKey<String>('web-browser-find-close'));
        }

        // 7. 滚动（宽窗口桌面不收起）
        await plat(
          'scroll',
          () => active()!.controller!.evaluateJavascript(
            source: 'window.scrollBy(0, 1500);',
          ),
        );
        await settle(800);
        result(
          '宽窗口滚动后 chrome 仍在',
          find
              .byKey(const ValueKey<String>('web-browser-toolbar'))
              .evaluate()
              .isNotEmpty,
        );

        // 8. 书签：Ctrl+D
        page().tabsController.activate(first);
        await loadInActive('$base/article');
        await waitLoaded('/article');
        await focusChrome();
        await chord(LogicalKeyboardKey.keyD);
        await settle(800);
        final WebBrowserStore store = page().store;
        final bool bookmarked =
            await store.bookmarkForUrl(Uri.parse('$base/article')) != null;
        result('Ctrl+D 加书签', bookmarked);

        // 9. 下载
        await loadInActive('$base/download');
        List<WebBrowserDownload> downloads = <WebBrowserDownload>[];
        final DateTime dlEnd = DateTime.now().add(const Duration(seconds: 20));
        while (DateTime.now().isBefore(dlEnd)) {
          downloads = await store.downloads();
          if (downloads.isNotEmpty &&
              downloads.first.state != WebBrowserDownloadState.running) {
            break;
          }
          await tester.pump(const Duration(milliseconds: 200));
        }
        downloadPath = downloads.isEmpty ? null : downloads.first.savedPath;
        result(
          '下载进下载记录',
          downloads.isNotEmpty &&
              downloads.first.state == WebBrowserDownloadState.completed,
          downloads.isEmpty
              ? 'none'
              : 'name=${downloads.first.fileName} '
                    'bytes=${downloads.first.receivedBytes}/${downloads.first.totalBytes} '
                    'state=${downloads.first.state} '
                    'path=${downloads.first.savedPath}',
        );
        await settle(1000);

        // 10. 数据页：下载 / 历史 / 书签（经 ⋯ 菜单，焦点+Enter）
        Future<void> openDataPage(String id, String shotName) async {
          await activate(const ValueKey<String>('web-browser-more'));
          final bool ok = await activate(
            ValueKey<String>('web-browser-menu-$id'),
          );
          await settle(1200);
          result('⋯ › $id 页', ok);
          await shot(shotName);
          final NavigatorState nav = Navigator.of(
            tester.element(
              find.byType(FushiWebBrowserPage, skipOffstage: false),
            ),
          );
          nav.pop();
          await settle(1000);
        }

        await openDataPage('downloads', 'downloads-page');
        await openDataPage('history', 'history-page');
        await openDataPage('bookmarks', 'bookmarks-page');

        // 11. 失败页：404 与连接被拒
        await loadInActive('$base/missing');
        final bool http404 = await waitFor(
          () => active()?.error?.statusCode == 404,
          timeout: const Duration(seconds: 10),
        );
        result('404 失败页', http404, 'error=${active()?.error?.description}');
        log(
          '404 tab: loading=${active()?.loading} '
          'href=${await plat<dynamic>('href', () => active()!.controller!.evaluateJavascript(source: 'location.href'))}',
        );
        await shot('error-404');
        await loadInActive('http://127.0.0.1:1/');
        final bool refused = await waitFor(
          () => active()?.error != null && active()?.error?.statusCode == null,
          timeout: const Duration(seconds: 15),
        );
        result('连接失败页', refused, 'error=${active()?.error?.description}');
        await shot('error-network');
        insecure = await _startSelfSignedSite();
        if (insecure == null) {
          log('证书错误失败页: SKIP（本机没有 openssl）');
        } else {
          await loadInActive('https://127.0.0.1:${insecure!.port}/');
          final bool certError = await waitFor(
            () =>
                active()?.error?.kind == WebBrowserLoadErrorKind.certificate &&
                !(active()?.loading ?? true),
            timeout: const Duration(seconds: 15),
          );
          result(
            '证书错误失败页',
            certError,
            'error=${active()?.error?.kind} ${active()?.error?.description}',
          );
          result(
            '证书错误不用拦截页标题',
            active()?.displayTitle == '127.0.0.1',
            'displayTitle=${active()?.displayTitle}',
          );
          await shot('error-certificate');
        }
        page().tabsController.activate(first);
        await loadInActive('$base/article');
        await waitLoaded('/article');

        // 12. 切回侧边栏（经 ⋯ 菜单分段的状态，直接写偏好后由设置刷新不可达：
        //     用右键菜单「改为侧边栏」）
        page().debugShowTabContextMenu(first, const Offset(200, 18));
        await settle(600);
        await activate(const ValueKey<String>('web-browser-menu-use-sidebar'));
        await settle(800);
        result(
          '右键菜单切回侧边栏',
          webBrowserTabStyle(appModel.prefsRepo) == WebBrowserTabStyle.sidebar,
        );

        // ── 窄窗口 ────────────────────────────────────────────────────
        await windowManager.setSize(const Size(430, 900));
        await settle(1500);
        log('narrow client=${fv.physicalSize / fv.devicePixelRatio}');
        final bool countBtn = find
            .byKey(const ValueKey<String>('web-browser-tab-count'))
            .evaluate()
            .isNotEmpty;
        result('竖屏底栏 + 标签数按钮', countBtn);
        await shot('narrow-bottom-bar');
        await activate(const ValueKey<String>('web-browser-tab-count'));
        await settle(1200);
        final bool grid = find
            .byKey(const ValueKey<String>('web-browser-tab-grid'))
            .evaluate()
            .isNotEmpty;
        result('标签数按钮打开标签页网格', grid);
        await shot('narrow-tab-grid');
        if (grid) {
          await activate(const ValueKey<String>('web-browser-grid-done'));
          await settle(800);
        }
        // 滚动收起
        await loadInActive('$base/long');
        await waitLoaded('/long');
        await settle(600);
        for (int i = 0; i < 6; i++) {
          await plat(
            'scroll',
            () => active()!.controller!.evaluateJavascript(
              source: 'window.scrollBy(0, 300);',
            ),
          );
          await settle(200);
        }
        await settle(800);
        final bool mini = find
            .byKey(const ValueKey<String>('web-browser-mini-bar'))
            .evaluate()
            .isNotEmpty;
        result('竖屏往下滚收起成小地址条', mini);
        await shot('narrow-collapsed');

        log('===== SUMMARY =====');
        for (final String r in results) {
          log(r);
        }
        final List<FlutterErrorDetails> nonBenign = errors
            .where((FlutterErrorDetails e) => !isBenignStartupNetworkError(e))
            .toList();
        log('flutter errors=${nonBenign.length}');
        for (final FlutterErrorDetails e in nonBenign) {
          log('ERROR ${e.exceptionAsString()}');
        }
        // 收尾：关浏览页，还原窗口。
        final NavigatorState nav = Navigator.of(
          tester.element(find.byType(FushiWebBrowserPage, skipOffstage: false)),
        );
        nav.pop();
        await settle(1000);
      },
    ).whenComplete(() async {
      if (originalSize != null) {
        await windowManager.setSize(originalSize!);
      }
      await site?.close(force: true);
      await insecure?.close(force: true);
      final String? path = downloadPath;
      if (path != null && path.endsWith(_kDownloadName)) {
        try {
          File(path).deleteSync();
        } on Object {
          // 已不在。
        }
      }
    });
    expect(
      results.where((String r) => r.startsWith('FAIL')).toList(),
      isEmpty,
      reason: results.join('\n'),
    );
  });
}
