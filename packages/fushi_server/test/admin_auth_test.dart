import 'dart:convert';
import 'dart:math';

import 'package:fushi_server/src/admin/admin_server.dart';
import 'package:test/test.dart';

/// 管理端凭据匹配的往返守卫。
///
/// 这条链路曾经整条都在私有方法里、没有任何可断言面，于是「写 cookie 时
/// `Uri.encodeComponent`、读 cookie 时忘了解码」漏到了合并前：token 是
/// `base64Url.encode(32 字节)`，32 % 3 == 2 ⇒ **必然以 `=` 结尾**，编码后是
/// `%3D`，与原串连长度都不等 —— 浏览器登录成功、Set-Cookie 也发了，下一跳却
/// 一定认证失败，回到登录页。Bearer 那条通道不受影响，所以 CLI 侧一切正常，
/// 只有 WebUI 死循环。
///
/// 这里钉的不变式就是那件事：**写侧发出去的 cookie，读侧必须认得回来**。
void main() {
  String realToken() {
    final Random random = Random.secure();
    return base64Url.encode(List<int>.generate(32, (_) => random.nextInt(256)));
  }

  test('真实形状的 token 必然带 = 结尾（下面几条的前提）', () {
    for (int i = 0; i < 20; i++) {
      expect(realToken(), endsWith('='),
          reason: '32 字节 base64Url 必有一个填充字符；前提不成立的话往返用例测的是空气');
    }
  });

  test('登录下发的 cookie，认证侧必须认得回来（往返）', () {
    for (int i = 0; i < 20; i++) {
      final String token = realToken();
      // 取 Set-Cookie 的第一段（`fushi_admin=...`），模拟浏览器回传。
      final String setCookie = adminSetCookieValue(token, secure: false);
      final String sent = setCookie.split(';').first.trim();
      expect(
        adminRequestAuthorized(
          authorization: null,
          cookie: sent,
          token: token,
        ),
        isTrue,
        reason: '写侧编码、读侧不解码 = WebUI 登录死循环（token=$token）',
      );
    }
  });

  test('Bearer 通道照常', () {
    final String token = realToken();
    expect(
      adminRequestAuthorized(
        authorization: 'Bearer $token',
        cookie: null,
        token: token,
      ),
      isTrue,
    );
    expect(
      adminRequestAuthorized(
        authorization: 'Bearer ${token}x',
        cookie: null,
        token: token,
      ),
      isFalse,
    );
  });

  test('别的 cookie 混在一起不影响', () {
    final String token = realToken();
    final String sent =
        adminSetCookieValue(token, secure: false).split(';').first.trim();
    expect(
      adminRequestAuthorized(
        authorization: null,
        cookie: 'theme=dark; $sent; other=1',
        token: token,
      ),
      isTrue,
    );
  });

  test('错 token / 畸形百分号一律不放行，且不回退去比原串', () {
    final String token = realToken();
    expect(
      adminRequestAuthorized(
        authorization: null,
        cookie: 'fushi_admin=${Uri.encodeComponent('wrong')}',
        token: token,
      ),
      isFalse,
    );
    // 畸形 % 序列：解码会抛，必须当作不匹配。这里故意让**原串**等于 token，
    // 万一实现 catch 之后回退比原串就会放行 —— 那正是要挡住的写法。
    expect(
      adminRequestAuthorized(
        authorization: null,
        cookie: 'fushi_admin=%zz',
        token: '%zz',
      ),
      isFalse,
      reason: '解码失败时绝不回退去比原串',
    );
  });

  test('常数时间比较：长度不同即 false，内容不同也 false', () {
    expect(adminConstantTimeEquals('abc', 'abcd'), isFalse);
    expect(adminConstantTimeEquals('abc', 'abd'), isFalse);
    expect(adminConstantTimeEquals('abc', 'abc'), isTrue);
  });
}
