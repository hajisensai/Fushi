import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../helpers/source_guard.dart';

/// BUG-1951 守卫：fork `cookie_manager.cpp` 的 cookie 过期时刻单位契约。
///
/// CDP `Network.getCookies` 的 `expires` 是**秒**，platform-interface `Cookie.expiresDate`
/// 是**毫秒**（同文件 `setCookie` 按毫秒收、`/ 1000` 后喂 CDP）。旧代码把秒直出成毫秒，
/// getCookies → setCookie 往返后 cookie 落到 1970 年被丢弃（4K 档登录态复制静默失效）、
/// 漫画过盾页 `cf_clearance` 落库即判过期。判据：
///   · 读侧不得再出现 `jsonCookie["expires"].get<int64_t>()` 直出；
///   · 读侧 `expiresDate` 必须经 `cookieExpiresDateMs`（秒→毫秒、会话 -1 → null）；
///   · 写侧 `parameters["expires"] = expiresDate.value() / 1000` 必须仍在（两侧成对）。
void main() {
  final File cpp = File(
    '../packages/flutter_inappwebview_windows/windows/cookie_manager.cpp',
  );

  test('fork cookie_manager.cpp 存在且能剥注释扫描', () {
    expect(cpp.existsSync(), isTrue, reason: cpp.path);
    expect(maskComments(cpp.readAsStringSync()).length, greaterThan(2000));
  });

  test('getCookies/getCookie 的 expiresDate 走秒→毫秒换算，不得直出 CDP 秒值', () {
    final String src = maskComments(cpp.readAsStringSync());
    expect(
      src.contains('jsonCookie["expires"].get<int64_t>()'),
      isFalse,
      reason: 'CDP expires 是秒，直出成 expiresDate（毫秒）就是 BUG-1951',
    );
    final RegExp use = RegExp(
      r'\{"expiresDate",\s*cookieExpiresDateMs\(jsonCookie\)\}',
    );
    expect(
      use.allMatches(src).length,
      2,
      reason: 'getCookie + getCookies 两处都必须经 cookieExpiresDateMs',
    );
    expect(src, contains('expiresSec * 1000.0'), reason: '秒 → 毫秒');
    expect(src, contains('if (expiresSec < 0)'), reason: '会话 cookie（-1）回 null');
  });

  test('setCookie 写侧仍按毫秒收、/1000 喂 CDP（与读侧成对）', () {
    final String src = maskComments(cpp.readAsStringSync());
    expect(
      src,
      contains('parameters["expires"] = expiresDate.value() / 1000;'),
    );
  });

  test('判据自校验：旧写法的合成语料必须被抓到', () {
    const String legacy =
        '{"expiresDate", jsonCookie["expires"].get<int64_t>()},';
    expect(
      maskComments(legacy).contains('jsonCookie["expires"].get<int64_t>()'),
      isTrue,
    );
  });
}
