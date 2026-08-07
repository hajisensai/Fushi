import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/sync/manual_sync_ui.dart';
import 'package:fushi/src/sync/sync_backend.dart';
import 'package:fushi/src/sync/sync_error_messages.dart';
import 'package:fushi/src/sync/sync_http.dart';
import 'package:fushi/src/utils/net/app_proxy.dart';
import 'package:http/http.dart' as http;

import '../helpers/source_guard.dart';

/// 读一份仓库内源码（守卫用）。测试从 `fushi/` 包根跑，故一律相对包根寻址。
String _read(String path) {
  final File f = File(path);
  expect(f.existsSync(), isTrue, reason: '$path 不存在（请从 fushi/ 包根跑测试）');
  return f.readAsStringSync();
}

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
      expect(f.existsSync(), isTrue, reason: '$path 不存在（请从 fushi/ 包根跑测试）');
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
      // 必须先掩注释再比位置：本仓的注释里就写着这两个片段（解释当年为什么错），
      // 直接 indexOf 会命中注释而不是代码，守卫就变成了在给自己的文档排序。用共享的
      // maskComments（等长掩码）而不是删除式剥离——删行会让后面 indexOf 出来的下标
      // 与原文错位，比出来的先后顺序就不再是源码里的先后顺序。
      final String source =
          maskComments(read('lib/src/sync/sync_error_messages.dart'));
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

  group('新增 kind 不得被「非 A 即 B」判据默默归错边（BUG-1348 收口）', () {
    // browserTimeout 是本轮**新加**的第三个 SyncAuthFailureKind。加值本身安全，
    // 危险的是既有的二元判据：`!error.isForbidden` 读作「不是 403 就是凭据坏了」，
    // 新值一进来就被判成「该登出」，而编译器一声不吭。
    test('每个 SyncAuthFailureKind 都要显式登记登出决定', () {
      const Map<SyncAuthFailureKind, bool> signOutByKind =
          <SyncAuthFailureKind, bool>{
        // 凭据真的不可用了：不登出，账号行就退不回「未登录」（TODO-836）。
        SyncAuthFailureKind.credentials: true,
        // 403：凭据已被接受，只是这一次请求被策略拒了（BUG-1323）。
        SyncAuthFailureKind.forbidden: false,
        // 浏览器回调没回到 app：跟凭据无关，登出只会连坐一个可能仍有效的会话。
        SyncAuthFailureKind.browserTimeout: false,
      };
      expect(
        signOutByKind.keys.toSet(),
        equals(SyncAuthFailureKind.values.toSet()),
        reason: '新增 SyncAuthFailureKind 必须在这里显式写出它该不该登出 —— '
            '默认归到某一边正是本条守卫要拦的事',
      );
      signOutByKind.forEach((SyncAuthFailureKind kind, bool expected) {
        expect(
          shouldSignOutOnAuthError(SyncAuthError('x', kind: kind)),
          equals(expected),
          reason: '$kind 的登出决定与登记表不符',
        );
      });
    });

    test('同步层不得再用 `!....isForbidden` 这种二元投影做判据', () {
      // 掩注释再扫：本仓注释里就写着 `!error.isForbidden`（解释当年为什么错），
      // 裸扫会命中注释，守卫就退化成在检查自己的文档。
      final RegExp negatedProjection = RegExp(r'!\s*[\w.]*\.isForbidden');
      final List<String> offenders = <String>[];
      for (final FileSystemEntity entity
          in Directory('lib/src/sync').listSync(recursive: true)) {
        if (entity is! File || !entity.path.endsWith('.dart')) continue;
        if (negatedProjection
            .hasMatch(maskComments(entity.readAsStringSync()))) {
          offenders.add(entity.path);
        }
      }
      expect(offenders, isEmpty,
          reason: '取反的 bool 投影把枚举压成两态，第三个值只会被默默归边；'
              '按值 switch，让编译器替你抓漏');
    });

    test('登出判据按值分派，三个 kind 一个不落地出现在源码里', () {
      final String source =
          maskComments(_read('lib/src/sync/manual_sync_ui.dart'));
      final int decisionIdx = source.indexOf('bool shouldSignOutOnAuthError(');
      expect(decisionIdx, greaterThanOrEqualTo(0));
      final String decision = source.substring(decisionIdx);
      for (final SyncAuthFailureKind kind in SyncAuthFailureKind.values) {
        expect(decision, contains('SyncAuthFailureKind.${kind.name}'),
            reason: '${kind.name} 没有出现在登出判据里 —— 它被某个默认分支吞了');
      }
    });
  });

  group('共享 sync client：并发首调不得各建一个（BUG-1348 收口）', () {
    late String Function() savedReader;

    setUp(() {
      savedReader = appUserProxyReader;
      // 短路掉 reg query / scutil / gsettings，测的是缓存语义不是平台探测。
      appUserProxyReader = () => '127.0.0.1:7890';
      resetSyncHttpClient();
    });
    tearDown(() {
      resetSyncHttpClient();
      appUserProxyReader = savedReader;
    });

    test('两个后端同时首调，拿到同一个 client', () async {
      // 关键在于**不 await 第一个就发第二个**：这正是 OneDrive 与 Dropbox 同时启动
      // 一轮同步的形状。缓存成品（`_x ??= await create()`）时，第一个 await 交出执行权
      // 的窗口里第二个调用仍看到 null，于是各建一个，先落地的那个从此无人能 close。
      final Future<http.Client> first = obtainSyncHttpClient();
      final Future<http.Client> second = obtainSyncHttpClient();
      expect(identical(await first, await second), isTrue,
          reason: '并发首调必须共享同一次构造，否则被覆盖的那个 client 永久泄漏');
    });

    test('reset 之后重建，且新旧不是同一个', () async {
      final http.Client before = await obtainSyncHttpClient();
      resetSyncHttpClient();
      final http.Client after = await obtainSyncHttpClient();
      expect(identical(before, after), isFalse,
          reason: '改完代理还复用旧出口，等于这个修复对用户不生效');
    });

    test('缓存的是 in-flight future，不是成品 client', () {
      final String source = maskComments(_read('lib/src/sync/sync_http.dart'));
      expect(source, contains('Future<http.Client>? _sharedClient'),
          reason: '缓存成品就一定有「await 期间的第二次首调」这个窗口');
    });
  });
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
