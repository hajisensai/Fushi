import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import 'package:fushi/src/media/manga/cookie/manga_web_view_environment.dart';

/// 取当前文档整页 HTML 的脚本：一次 `evaluateJavascript` 拿回 doctype + outerHTML。
///
/// 取的是**渲染后**的 DOM（SPA 站点的正文已经插进来、懒加载图片已有 src），比重新
/// HTTP 取一次原始页更接近用户眼前看到的那一页，也天然带着用户的登录态 / 验证结果。
const String kWebNovelPageHtmlScript =
    '(function(){var d=document.doctype;'
    'var dt=d?"<!DOCTYPE "+d.name+">":"";'
    'return dt+document.documentElement.outerHTML;})()';

/// 一次无界面取页的时间上限（含等待 SPA 渲染）。
const Duration kWebNovelFetchTimeout = Duration(seconds: 45);

/// 取页失败（加载错误、超时、页面没有内容）。
class WebNovelFetchException implements Exception {
  const WebNovelFetchException(this.message);

  final String message;

  @override
  String toString() => 'WebNovelFetchException: $message';
}

/// 取回的一页：整页 HTML 的 UTF-8 字节 + 最终地址（跟随重定向后）。
typedef WebNovelFetchedPage = ({Uint8List html, Uri url});

/// 从一个已加载的 WebView 取当前文档的 HTML（UTF-8 字节，交给 Rust 提取）。
Future<Uint8List> webNovelPageHtml(InAppWebViewController controller) async {
  final Object? raw = await controller.evaluateJavascript(
    source: kWebNovelPageHtmlScript,
  );
  if (raw is! String || raw.isEmpty) {
    throw const WebNovelFetchException('page returned no HTML');
  }
  return utf8.encode(raw);
}

/// 取「还没在浏览器里打开过」的章节页（追更拉下一章）。测试缝：生产用
/// [HeadlessWebNovelPageFetcher]。
abstract interface class WebNovelPageFetcher {
  Future<WebNovelFetchedPage> fetch(Uri url);
}

/// 用无界面 WebView 打开章节页再取 HTML：与浏览器页、网页漫画无界面扫图同一个
/// WebView2 环境（[MangaWebViewEnvironment]）→ 同一份 cookie / 登录态 / 验证结果。
class HeadlessWebNovelPageFetcher implements WebNovelPageFetcher {
  const HeadlessWebNovelPageFetcher();

  @override
  Future<WebNovelFetchedPage> fetch(Uri url) async {
    final WebViewEnvironment? environment =
        await MangaWebViewEnvironment.obtain();
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
              loaded.completeError(WebNovelFetchException(error.description));
            }
          },
      // renderer 死了：接管回调（Android 上不接管 = 系统连 app 进程一起杀），这一次
      // 取页按失败处理；无界面 WebView 用完即弃，不必重建。
      onRenderProcessGone:
          (InAppWebViewController _, RenderProcessGoneDetail detail) {
            if (!loaded.isCompleted) {
              loaded.completeError(
                const WebNovelFetchException('renderer process gone'),
              );
            }
          },
      onWebContentProcessDidTerminate: (InAppWebViewController _) {
        if (!loaded.isCompleted) {
          loaded.completeError(
            const WebNovelFetchException('web content process terminated'),
          );
        }
      },
    );
    try {
      await webView.run();
      final InAppWebViewController controller = await loaded.future.timeout(
        kWebNovelFetchTimeout,
        onTimeout: () =>
            throw const WebNovelFetchException('chapter page did not load'),
      );
      final WebUri? current = await controller.getUrl();
      final Uint8List html = await webNovelPageHtml(controller);
      return (html: html, url: current ?? url);
    } finally {
      try {
        await webView.dispose();
      } on Object {
        // renderer 已死时 dispose 可能抛；结果已经拿到或已失败。
      }
    }
  }
}
