import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../helpers/source_guard.dart';

/// BUG-2511 守卫：fork `cookie_manager.cpp` 读侧必须能看见分区（CHIPS）cookie。
///
/// CDP `Network.getCookies({urls})` 按当前 target 的 cookie 访问语义筛，把带
/// `Partitioned` 属性的 cookie 整个筛掉；Cloudflare 现在发的 `cf_clearance` 就是分区
/// cookie（实测 WebView2 1.0.2792：cookie 库里 `top_frame_site_key` 非空，
/// `Network.getCookies` 回空，`Storage.getCookies` 带 `partitionKey` 返回）。读侧走
/// `Network.getCookies` 的后果是站点验证页轮询永远读不到已落库的放行 cookie、永远不关。
/// 判据：
///   · 读侧一律经 `Storage.getCookies` 取全量，再在 C++ 侧按 URL 匹配
///     （`collectCookiesForUrl` / `cookieMatchesUrl`）；
///   · 整个文件不得再出现 `Network.getCookies` 调用（注释里提它不算）；
///   · getCookie / getCookies 两处都必须经 `collectCookiesForUrl`。
void main() {
  final File cpp = File(
    '../packages/flutter_inappwebview_windows/windows/cookie_manager.cpp',
  );

  test('读侧不得再调 CDP Network.getCookies（会丢分区 cookie）', () {
    final String src = maskComments(cpp.readAsStringSync());
    expect(
      src.contains('L"Network.getCookies"'),
      isFalse,
      reason: 'Network.getCookies 看不见 Partitioned cookie，就是 BUG-2511',
    );
    expect(src, contains('L"Storage.getCookies"'));
  });

  test('getCookie + getCookies 都经 collectCookiesForUrl 按 URL 匹配', () {
    final String src = maskComments(cpp.readAsStringSync());
    expect(
      RegExp(
        r'collectCookiesForUrl\(webViewEnvironment, url,',
      ).allMatches(src).length,
      2,
    );
    expect(src, contains('static bool cookieMatchesUrl('));
    expect(src, contains('static bool cookieDomainMatches('));
    expect(src, contains('static bool cookiePathMatches('));
  });

  test('判据自校验：旧写法的合成语料必须被抓到', () {
    const String legacy =
        'CallDevToolsProtocolMethod(L"Network.getCookies", params, cb);';
    expect(maskComments(legacy).contains('L"Network.getCookies"'), isTrue);
  });
}
