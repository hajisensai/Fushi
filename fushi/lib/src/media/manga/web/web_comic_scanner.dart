import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import 'package:fushi/src/media/manga/cookie/manga_web_view_environment.dart';
import 'package:fushi/src/media/manga/web/web_comic_chapter.dart';
import 'package:fushi/src/media/manga/web/web_comic_scan.dart';
import 'package:fushi/src/media/manga/web/web_comic_site_rule.dart';

/// 扫图脚本（随包资产）。
const String kWebComicScannerAsset = 'assets/web_comic/web_comic_scanner.js';

/// 站点规则表（随包资产）。
const String kWebComicRulesAsset = 'assets/web_comic/site_rules.json';

/// 脚本回传结果用的 JS handler 名。
const String kWebComicScanHandler = 'fushiWebComicScan';

/// 一次扫图的时间上限（含滚动触发懒加载、等 SPA 渲染）。
const Duration kWebComicScanTimeout = Duration(seconds: 45);

/// 扫图失败（脚本报错、超时、页面不是章节）。
class WebComicScanException implements Exception {
  const WebComicScanException(this.message);

  final String message;

  @override
  String toString() => 'WebComicScanException: $message';
}

/// 随包资产的一次性加载（脚本 + 规则表），整个进程共用。
abstract final class WebComicAssets {
  static Future<String>? _script;
  static Future<WebComicRuleSet>? _rules;

  static Future<String> scannerScript() =>
      _script ??= rootBundle.loadString(kWebComicScannerAsset);

  static Future<WebComicRuleSet> rules() => _rules ??= rootBundle
      .loadString(kWebComicRulesAsset)
      .then(WebComicRuleSet.parse);
}

/// 把扫图配置拼成一句 JS 调用。
///
/// `script` 取图方式的函数体**直接写进注入源码**（作为 async 函数字面量），
/// 不在页面里 `new Function`：不少漫画站的 CSP 不允许 `unsafe-eval`，而
/// WebView 层的注入不受页面 CSP 约束。
String webComicScanInvocation({
  required String requestId,
  required WebComicSiteRule? rule,
  WebComicScanThresholds thresholds = const WebComicScanThresholds(),
}) {
  final WebComicImageSource? images = rule?.images;
  final Map<String, Object?> ruleConfig = rule == null
      ? const <String, Object?>{}
      : (Map<String, Object?>.of(rule.toScriptConfig())
          ..['images'] = images is WebComicScriptImageSource
              ? <String, Object?>{'mode': 'script'}
              : images!.toJson());
  final Map<String, Object?> config = <String, Object?>{
    'requestId': requestId,
    'handler': kWebComicScanHandler,
    'rule': rule == null ? null : ruleConfig,
    'minNaturalSide': thresholds.minNaturalSide,
    'minDisplaySide': 100,
  };
  final String scriptFn = images is WebComicScriptImageSource
      ? 'async function (ctx) {\n${images.code}\n}'
      : 'null';
  return 'window.__fushiWebComic && '
      'window.__fushiWebComic.scan(${jsonEncode(config)}, $scriptFn); true;';
}

/// 一个 WebView 上的扫图会话：登记 handler、注入脚本、按请求号等结果。
///
/// handler 必须在 `onWebViewCreated` 里登记（[attach]），之后每次 [scan] 都是
/// 「确保脚本在 → 发起 → 等同号结果」。
class WebComicScanDriver {
  WebComicScanDriver({Future<WebComicRuleSet> Function()? rules})
    : _rules = rules ?? WebComicAssets.rules;

  final Future<WebComicRuleSet> Function() _rules;
  final Map<String, Completer<Object?>> _pending =
      <String, Completer<Object?>>{};
  int _counter = 0;

  /// 在 `onWebViewCreated` 里调用一次。
  void attach(InAppWebViewController controller) {
    controller.addJavaScriptHandler(
      handlerName: kWebComicScanHandler,
      callback: (List<dynamic> args) {
        final Object? payload = args.isEmpty ? null : args.first;
        if (payload is Map) {
          final Completer<Object?>? waiter = _pending.remove(
            payload['requestId']?.toString(),
          );
          if (waiter != null && !waiter.isCompleted) waiter.complete(payload);
        }
        return true;
      },
    );
  }

  /// 扫当前页。[pageUrl] 是当前地址（脚本没报时兜底解析相对 URL）。
  Future<WebComicScanResult> scan(
    InAppWebViewController controller, {
    required Uri pageUrl,
    Duration timeout = kWebComicScanTimeout,
  }) async {
    final WebComicRuleSet rules = await _rules();
    final WebComicSiteRule? rule = rules.matchChapter(pageUrl);
    final String script = await WebComicAssets.scannerScript();
    await controller.evaluateJavascript(source: script);
    final String requestId = 'scan-${++_counter}';
    final Completer<Object?> waiter = Completer<Object?>();
    _pending[requestId] = waiter;
    try {
      await controller.evaluateJavascript(
        source: webComicScanInvocation(requestId: requestId, rule: rule),
      );
      final Object? raw = await waiter.future.timeout(
        timeout,
        onTimeout: () => throw const WebComicScanException('scan timed out'),
      );
      final Object? error = raw is Map ? raw['error'] : null;
      final WebComicScanResult? result = normalizeWebComicScan(
        raw,
        fallbackPageUrl: pageUrl,
      );
      if (result == null) {
        throw const WebComicScanException('malformed scan result');
      }
      if (result.isEmpty && error != null) {
        throw WebComicScanException(error.toString());
      }
      return result;
    } finally {
      _pending.remove(requestId);
    }
  }
}

/// 换章时扫一个**还没打开过**的章节页（阅读器读到头要跳下一章）。
abstract interface class WebComicChapterScanner {
  Future<WebComicScanResult> scanChapter(Uri url);
}

/// 用无界面 WebView 打开章节页再扫（与浏览器页同一套脚本、同一个 WebView2
/// 环境 → 同一份 cookie）。
class HeadlessWebComicChapterScanner implements WebComicChapterScanner {
  const HeadlessWebComicChapterScanner();

  @override
  Future<WebComicScanResult> scanChapter(Uri url) async {
    final WebViewEnvironment? environment =
        await MangaWebViewEnvironment.obtain();
    final WebComicScanDriver driver = WebComicScanDriver();
    final Completer<InAppWebViewController> loaded =
        Completer<InAppWebViewController>();
    final HeadlessInAppWebView webView = HeadlessInAppWebView(
      webViewEnvironment: environment,
      initialSize: const Size(1280, 1800),
      initialUrlRequest: URLRequest(url: WebUri.uri(url)),
      initialSettings: InAppWebViewSettings(
        javaScriptEnabled: true,
        sharedCookiesEnabled: true,
      ),
      onWebViewCreated: driver.attach,
      onLoadStop: (InAppWebViewController controller, WebUri? _) {
        if (!loaded.isCompleted) loaded.complete(controller);
      },
      onReceivedError:
          (
            InAppWebViewController _,
            WebResourceRequest request,
            WebResourceError error,
          ) {
            if (request.isForMainFrame == true && !loaded.isCompleted) {
              loaded.completeError(WebComicScanException(error.description));
            }
          },
      // 渲染进程死了页面不会再 loadStop：立刻判失败，不白等到超时。
      onRenderProcessGone:
          (InAppWebViewController _, RenderProcessGoneDetail detail) {
            if (!loaded.isCompleted) {
              loaded.completeError(
                const WebComicScanException('renderer process gone'),
              );
            }
          },
      onWebContentProcessDidTerminate: (InAppWebViewController _) {
        if (!loaded.isCompleted) {
          loaded.completeError(
            const WebComicScanException('web content process terminated'),
          );
        }
      },
    );
    try {
      await webView.run();
      final InAppWebViewController controller = await loaded.future.timeout(
        kWebComicScanTimeout,
        onTimeout: () =>
            throw const WebComicScanException('chapter page did not load'),
      );
      final WebUri? current = await controller.getUrl();
      return await driver.scan(controller, pageUrl: current ?? url);
    } finally {
      try {
        await webView.dispose();
      } on Object {
        // renderer 已死时 dispose 可能抛；结果已经拿到或已失败。
      }
    }
  }
}

/// 从浏览器（与浏览器页同一个环境）读 [pageUrl] 站点的 cookie。
Future<List<WebComicCookie>> readWebComicCookies(Uri pageUrl) async {
  final WebViewEnvironment? environment =
      await MangaWebViewEnvironment.obtain();
  final List<Cookie> cookies = await CookieManager.instance(
    webViewEnvironment: environment,
  ).getCookies(url: WebUri.uri(pageUrl));
  return <WebComicCookie>[
    for (final Cookie cookie in cookies)
      (
        name: cookie.name,
        value: cookie.value?.toString() ?? '',
        domain: cookie.domain?.toString(),
      ),
  ];
}
