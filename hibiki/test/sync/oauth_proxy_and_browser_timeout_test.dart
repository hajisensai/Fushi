import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/i18n/strings.g.dart';
import 'package:hibiki/src/sync/sync_backend.dart';
import 'package:hibiki/src/sync/sync_error_messages.dart';
import 'package:hibiki/src/utils/net/app_proxy.dart';

/// BUG-1348：谷歌云盘桌面登录在开着代理的机器上必然失败。
///
/// 用户日志里同一次排查出现两种失败，各修各的根因：
///   * 8×「`errno = 121`（信号灯超时），address = oauth2.googleapis.com」——浏览器那半程
///     走系统代理拿到了授权码，app 这半程用裸 `http.Client()` 直连换 token。Dart 的
///     `HttpClient` 默认 `findProxy` 为空，连 `HTTPS_PROXY` 都不读，所以这是**必然**失败，
///     不是偶发网络抖动，更不是 API 限额。
///   * 2×「`SyncAuthError: Timed out waiting for authorization`」——回调没回到 app，而这条
///     错误因为消息里带 "authorization" 被错误文案层的 `contains('auth')` 抢先判成
///     「登录已过期」，把用户指向重新登录这条死路。
///
/// 前一半的可落地断言层是「代理配置能否到达同步层」（[appUserProxyReader] → [applyAppProxy]），
/// 后一半是错误分类的真实输出（[friendlySyncError]）。两者都是行为测试，不是措辞测试：
/// 断言比的是本地化 getter 本身，与具体语言无关。
void main() {
  group('applyAppProxy: 进程级代理配置必须能到达不传参的调用方（BUG-1348）', () {
    late String Function() savedReader;

    setUp(() => savedReader = appUserProxyReader);
    tearDown(() => appUserProxyReader = savedReader);

    test('省略 userProxy 时取 appUserProxyReader —— 同步层正是这么调的', () async {
      appUserProxyReader = () => '127.0.0.1:7890';
      final _CapturingHttpClient client = _CapturingHttpClient();

      await applyAppProxy(client);

      // 用户真正失败的那个 URL：token 交换。它必须经代理出去。
      expect(
        client.findProxy
            ?.call(Uri.parse('https://oauth2.googleapis.com/token')),
        equals('PROXY 127.0.0.1:7890'),
      );
    });

    test('显式 userProxy 仍然优先 —— 既有更新检查调用点行为逐字不变', () async {
      appUserProxyReader = () => '127.0.0.1:7890';
      final _CapturingHttpClient client = _CapturingHttpClient();

      await applyAppProxy(client, userProxy: '10.0.0.1:1080');

      expect(
        client.findProxy?.call(Uri.parse('https://api.github.com/x')),
        equals('PROXY 10.0.0.1:1080'),
      );
    });

    test('reader 给非法值 → fail-open，绝不把请求切死', () async {
      // 归一失败必须落回 env>GUI>DIRECT，而不是设成一个不存在的代理把网断掉。
      appUserProxyReader = () => 'not a proxy';
      final _CapturingHttpClient client = _CapturingHttpClient();

      await applyAppProxy(client);

      final String? resolved = client.findProxy
          ?.call(Uri.parse('https://oauth2.googleapis.com/token'));
      expect(resolved, isNot(equals('PROXY not a proxy')));
    });
  });

  group('浏览器授权超时不是「登录已过期」（BUG-1348）', () {
    // desktop_oauth.dart 抛的原文，逐字照抄——正是它里面的 "authorization"
    // 触发了错误文案层的 contains('auth') 误判。
    const String loopbackTimeoutMsg = 'Timed out waiting for authorization';

    test('带 browserTimeout 类型 → 专用文案，而不是「登录已过期」', () {
      final SyncAuthError error = SyncAuthError(
        loopbackTimeoutMsg,
        kind: SyncAuthFailureKind.browserTimeout,
      );

      expect(friendlySyncError(error), equals(t.sync_err_browser_timeout));
      expect(friendlySyncError(error), isNot(equals(t.sync_err_auth_expired)));
    });

    test('friendlySyncAuthFailure 对三种 kind 各说各的话', () {
      expect(
        friendlySyncAuthFailure(SyncAuthFailureKind.browserTimeout, null),
        equals(t.sync_err_browser_timeout),
      );
      expect(
        friendlySyncAuthFailure(SyncAuthFailureKind.credentials, null),
        equals(t.sync_err_auth_expired),
      );
      expect(
        friendlySyncAuthFailure(SyncAuthFailureKind.forbidden, null),
        equals(t.sync_err_forbidden),
      );
    });

    test('真正的凭据失效仍然说「登录已过期」—— 没有误伤原有分类', () {
      final SyncAuthError error =
          SyncAuthError('Invalid Credentials (401 Unauthorized)');
      expect(friendlySyncError(error), equals(t.sync_err_auth_expired));
    });
  });

  group('源码守卫：同步层不得再留下绕过代理的直连暗路（BUG-1348）', () {
    String read(String path) {
      final File f = File(path);
      expect(f.existsSync(), isTrue, reason: '$path 不存在（请从 hibiki/ 包根跑测试）');
      return f.readAsStringSync();
    }

    test('google_drive_auth 三处 client 全部经 createSyncHttpClient', () {
      final String source = read('lib/src/sync/google_drive_auth.dart');

      // 裸 http.Client() 就是 BUG-1348 的字面根因：它不带代理也不带连接超时。
      expect(source.contains('http.Client()'), isFalse,
          reason: '裸 http.Client() 不走代理 —— 必须用 createSyncHttpClient()');
      // 登录 / 启动恢复 / 刷新，三条路径都要走代理出口，漏一条就是「登录成功但重启掉线」。
      expect('createSyncHttpClient()'.allMatches(source).length, equals(3),
          reason: 'authenticate / restoreDesktopAuth / refreshAuth 各一处');
    });

    test('sync_http 的两个工厂都装代理 + 连接超时', () {
      final String source = read('lib/src/sync/sync_http.dart');
      expect(source, contains('await applyAppProxy(io)'));
      expect(source, contains('connectionTimeout = kSyncConnectionTimeout'));
      // 共享单例必须能失效，否则用户改完代理仍走旧出口。
      expect(source, contains('void resetSyncHttpClient()'));
    });

    test('loopback 超时抛类型，不靠调用方猜字符串', () {
      final String source = read('lib/src/sync/desktop_oauth.dart');
      expect(source, contains('kind: SyncAuthFailureKind.browserTimeout'),
          reason: '错误分类必须有类型可依 —— 消息里的 "authorization" 会被误判');
    });

    test('错误文案层按 kind 分派，不再让字符串猜测抢先', () {
      // 必须剥注释再比位置：本仓的注释里就写着这两个片段（解释当年为什么错），
      // 直接 indexOf 会命中注释而不是代码，守卫就变成了在给自己的文档排序。
      final String source =
          _stripDartComments(read('lib/src/sync/sync_error_messages.dart'));
      final int typedIdx =
          source.indexOf('error.kind != SyncAuthFailureKind.credentials');
      final int guessIdx = source.indexOf("l.contains('auth')");
      expect(typedIdx, greaterThanOrEqualTo(0), reason: '有类型的鉴权失败必须先一次分派掉');
      expect(guessIdx, greaterThanOrEqualTo(0),
          reason: '字符串兜底分支还在（它服务于无类型的历史抛出点）');
      expect(typedIdx, lessThan(guessIdx),
          reason: '类型分派必须排在字符串猜测之前，否则 browserTimeout 又被说成登录过期');
    });

    test('Google 的 loopback redirect 用回环 IP，不用 localhost', () {
      final String source = read('lib/src/sync/google_drive_auth.dart');
      expect(source, contains("host: '127.0.0.1'"),
          reason: 'localhost 要先过 DNS（Windows 上先解析 ::1）和代理 bypass 列表，'
              '两处任一不配合，授权码就永远回不来');
    });
  });
}

/// 去掉 `//` 行注释与 `/* */` 块注释，只留可执行代码。
///
/// 源码扫描守卫比对的是**代码**里的事实；本仓的注释常常逐字引用被修掉的旧写法（好让后人
/// 知道当年错在哪），不剥注释的守卫会被这些引用命中，从而对着文档下结论。
String _stripDartComments(String source) {
  final String withoutBlocks =
      source.replaceAll(RegExp(r'/\*.*?\*/', dotAll: true), '');
  return withoutBlocks.split('\n').map((String line) {
    final int idx = line.indexOf('//');
    return idx < 0 ? line : line.substring(0, idx);
  }).join('\n');
}

/// 只捕获 `findProxy` 的最小 [HttpClient] 桩。
///
/// 不用真 `HttpClient()`：flutter_test 默认装了 `HttpOverrides`，`HttpClient()` 拿到的是
/// 框架的 mock，`findProxy` 未必存得住——那样测的就是 mock 的行为而不是本仓代码的。
class _CapturingHttpClient implements HttpClient {
  @override
  String Function(Uri url)? findProxy;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
