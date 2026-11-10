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
///
/// #3111 遗留：只删 flush 会让页面刚种的 cookie（如 Cloudflare clearance）在
/// 进程后台被杀时丢失。补法是 `onPageFinished` 只置脏标记，
/// `BackgroundCookieFlusher` 在界面隐藏（`onTrimMemory >= TRIM_MEMORY_UI_HIDDEN`）
/// 时在单线程后台 executor 上 flush 一次、合并重复请求，UI 线程永不等待。
/// 见 `third_party/flutter_inappwebview_android/PATCHES.md`。
const String _clientDir =
    'third_party/flutter_inappwebview_android/android/src/main/java/com/'
    'pichillilorenzo/flutter_inappwebview_android/webview/in_app_webview/';

const String _pluginDir =
    'third_party/flutter_inappwebview_android/android/src/main/java/com/'
    'pichillilorenzo/flutter_inappwebview_android/';

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
      expect(
        body,
        contains('BackgroundCookieFlusher.markDirty();'),
        reason:
            'page-set cookies must still reach disk: mark the store dirty so '
            'the background flusher persists it when the UI is hidden',
      );
    });
  }

  test('BackgroundCookieFlusher flushes only on its background executor', () {
    final String raw = maskComments(
      _read('${_pluginDir}BackgroundCookieFlusher.java'),
    );
    expect(
      raw,
      contains('Executors.newSingleThreadExecutor('),
      reason: 'one dedicated worker thread serialises flushes',
    );
    expect(
      '.flush()'.allMatches(raw).length,
      1,
      reason: 'exactly one flush call site, inside the executor task',
    );

    final String request = methodBody(raw, 'public static void requestFlush()');
    final int execute = request.indexOf('executor.execute(');
    final int flush = request.indexOf('CookieManager.getInstance().flush();');
    expect(execute, greaterThanOrEqualTo(0), reason: 'flush must be queued');
    expect(
      flush,
      greaterThan(execute),
      reason: 'flush() must run inside the executor task, never on the caller',
    );
    expect(
      request.substring(0, execute),
      contains('scheduled.compareAndSet(false, true)'),
      reason: 'duplicate requests are coalesced into one queued task',
    );
    expect(
      request.substring(0, execute),
      contains('if (!dirty.get()) return;'),
      reason: 'no flush when no page finished since the last one',
    );

    for (final String signature in <String>[
      'public static void markDirty()',
      'public void onTrimMemory(int level)',
      'public void onLowMemory()',
    ]) {
      final String body = methodBody(raw, signature);
      expect(
        body,
        isNot(contains('.flush(')),
        reason: '$signature runs on the UI thread: it may only enqueue',
      );
    }
    final String trim = methodBody(raw, 'public void onTrimMemory(int level)');
    expect(trim, contains('level >= TRIM_MEMORY_UI_HIDDEN'));
    expect(trim, contains('requestFlush();'));
  });

  test('plugin registers and releases the background cookie flusher', () {
    final String raw = maskComments(
      _read('${_pluginDir}InAppWebViewFlutterPlugin.java'),
    );
    expect(
      methodBody(
        raw,
        'private void onAttachedToEngine(Context applicationContext,',
      ),
      contains('new BackgroundCookieFlusher(applicationContext)'),
    );
    expect(
      methodBody(
        raw,
        'public void onDetachedFromEngine(@NonNull FlutterPluginBinding binding)',
      ),
      contains('backgroundCookieFlusher.dispose();'),
      reason: 'ComponentCallbacks registration must not outlive the engine',
    );
  });

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
