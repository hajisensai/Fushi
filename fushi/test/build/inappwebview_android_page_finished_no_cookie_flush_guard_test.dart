import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../helpers/source_guard.dart';

/// BUG-4261：Android WebView 的 `onPageFinished` 不许在 UI 线程同步刷 cookie。
///
/// 上游在两个 WebViewClient 的 `onPageFinished` 里每次页面加载完都调
/// `CookieManager.getInstance().flush()`（API<21 走 `CookieSyncManager.sync()`）。
/// flush 会阻塞主线程直到 Chromium 的 cookie 存储 IO 线程写完；内存 / IO
/// 压力大或进程在后台 cgroup 时这一等就是 5~10 秒，真机报出 Input dispatching
/// timed out 的 ANR（主线程栈停在 `CookieManagerAdapter.flush` ←
/// `InAppWebViewClientCompat.onPageFinished`）。Chromium 自己会定时落盘，
/// 显式写 cookie 的路径（`MyCookieManager.setCookie` / `delete*`）照旧 flush。
/// 见 `third_party/flutter_inappwebview_android/PATCHES.md`。
const String _clientDir =
    'third_party/flutter_inappwebview_android/android/src/main/java/com/'
    'pichillilorenzo/flutter_inappwebview_android/webview/in_app_webview/';

const String _cookieManager =
    'third_party/flutter_inappwebview_android/android/src/main/java/com/'
    'pichillilorenzo/flutter_inappwebview_android/MyCookieManager.java';

String _read(String relative) {
  final File file = <String>[relative, '../$relative']
      .map(File.new)
      .firstWhere(
        (File f) => f.existsSync(),
        orElse: () => fail('$relative not found'),
      );
  return file.readAsStringSync();
}

void main() {
  for (final String client in <String>[
    'InAppWebViewClient.java',
    'InAppWebViewClientCompat.java',
  ]) {
    test('$client onPageFinished does not flush cookies on the UI thread', () {
      final String raw = _read('$_clientDir$client');
      final String body = maskComments(
        methodBody(raw, 'public void onPageFinished(WebView view, String url)'),
      );
      expect(
        body,
        contains('super.onPageFinished(view, url);'),
        reason: 'anchor sanity: this must be the real onPageFinished body',
      );
      expect(
        body,
        isNot(contains('.flush(')),
        reason:
            'CookieManager.flush() blocks the UI thread on Chromium\'s cookie '
            'IO thread (5-10 s ANR under memory / IO pressure)',
      );
      expect(
        body,
        isNot(contains('CookieSyncManager')),
        reason: 'CookieSyncManager.sync() is the same blocking flush pre-L',
      );
    });
  }

  test('explicit cookie writes in MyCookieManager still flush', () {
    final String raw = _read(_cookieManager);
    for (final String signature in <String>[
      'public void setCookie(String url,',
      'public void deleteCookie(String url, String name,',
      'public void deleteCookies(String url, String domain,',
      'public void deleteAllCookies(final MethodChannel.Result result)',
      'public void removeSessionCookies(final MethodChannel.Result result)',
    ]) {
      expect(
        maskComments(methodBody(raw, signature)),
        contains('cookieManager.flush();'),
        reason: '$signature must persist the write it just made',
      );
    }
  });
}
