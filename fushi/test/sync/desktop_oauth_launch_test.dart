import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/sync/desktop_oauth.dart';
import 'package:fushi/src/sync/sync_backend.dart';

/// BUG-2120：桌面 loopback 授权必须把链接句柄交给观察者，且句柄的动作与信号各自真的
/// 落到流程上：观察者拿到的 URL 与浏览器实际被拉起的逐字节一致、句柄在浏览器拉起**之前**
/// 就交出（拉起失败恰恰最需要链接）、cancel 立刻以 cancelled 收场并释放端口、reopen 再拉
/// 同一 URL、finished 在每种收场（授权码 / 取消 / 超时）都会完成、observe 作用域交错也不
/// 抹掉后来者。
///
/// 这里跑的是**真回环服务器**（`HttpServer.bind` 到临时端口）+ 桩掉的 url_launcher 通道。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const MethodChannel channel = MethodChannel(
    'plugins.flutter.io/url_launcher',
  );
  final List<String> launchedUrls = <String>[];
  // 桩的行为：true 正常拉起；false 回 false；throw 模拟本仓钉的 url_launcher_windows /
  // _linux 在 ShellExecuteW ≤ 32 / xdg-open 失败时抛 PlatformException。
  String launchBehaviour = 'true';

  setUp(() {
    launchedUrls.clear();
    launchBehaviour = 'true';
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall call) async {
      if (call.method == 'launch') {
        final Map<Object?, Object?> args = Map<Object?, Object?>.from(
          call.arguments as Map,
        );
        launchedUrls.add(args['url'] as String);
        switch (launchBehaviour) {
          case 'false':
            return false;
          case 'throw':
            throw PlatformException(code: 'SE_ERR_NOASSOC');
        }
      }
      return true;
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  Uri buildAuthUrl(String redirectUri) => Uri.https(
        'accounts.example.test',
        'o/oauth2/auth',
        <String, String>{'redirect_uri': redirectUri, 'scope': 'a b'},
      );

  /// 模拟浏览器回调。**不能用 `HttpClient`**：flutter_test 把 `dart:io` 的 HttpClient
  /// 整个换成了假实现（永远回 400、从不真连），会让这里静静挂到超时；裸 Socket 不在
  /// 那层覆盖范围内，手写一条最小 HTTP/1.1 请求即可。
  Future<void> hitCallback(String redirectUri, String query) async {
    final Uri u = Uri.parse(redirectUri);
    final Socket socket = await Socket.connect(u.host, u.port);
    try {
      socket.write('GET /?$query HTTP/1.1\r\n'
          'Host: ${u.host}:${u.port}\r\n'
          'Connection: close\r\n\r\n');
      await socket.flush();
      final String response =
          await socket.cast<List<int>>().transform(utf8.decoder).join();
      expect(response, startsWith('HTTP/1.1 200'));
    } finally {
      socket.destroy();
    }
  }

  Future<bool> portOpen(String redirectUri) async {
    final Uri u = Uri.parse(redirectUri);
    try {
      final Socket s = await Socket.connect(u.host, u.port,
          timeout: const Duration(seconds: 1));
      s.destroy();
      return true;
    } on SocketException {
      return false;
    }
  }

  /// 起一条流程并等到观察者拿到句柄。
  Future<(Future<DesktopOAuthResult>, DesktopOAuthLaunch, String)> start({
    Duration timeout = const Duration(minutes: 5),
  }) async {
    late String redirectUri;
    final Completer<DesktopOAuthLaunch> launched =
        Completer<DesktopOAuthLaunch>();
    final Future<DesktopOAuthResult> flow = runDesktopOAuthLoopback(
      host: '127.0.0.1',
      timeout: timeout,
      buildAuthUrl: (String r) {
        redirectUri = r;
        return buildAuthUrl(r);
      },
      onLaunched: launched.complete,
    );
    // 流程抛错时别让测试卡在 launched 上。
    unawaited(flow.catchError((Object e) {
      if (!launched.isCompleted) launched.completeError(e);
      return const DesktopOAuthResult(code: '', redirectUri: '');
    }));
    final DesktopOAuthLaunch launch = await launched.future;
    return (flow, launch, redirectUri);
  }

  test('观察者收到的 authUrl 与浏览器实际被拉起的 URL 逐字节一致', () async {
    final (
      Future<DesktopOAuthResult> flow,
      DesktopOAuthLaunch launch,
      String redirectUri
    ) = await start();
    expect(await launch.browserOpened, isTrue);
    expect(launchedUrls, hasLength(1));
    expect(launch.authUrl.toString(), launchedUrls.single);
    expect(launch.authUrl, buildAuthUrl(redirectUri));
    expect(redirectUri, startsWith('http://127.0.0.1:'));

    await hitCallback(redirectUri, 'code=abc123');
    final DesktopOAuthResult result = await flow;
    expect(result.code, 'abc123');
    expect(result.redirectUri, redirectUri);
    await launch.finished; // 授权码到达 → finished 完成
  });

  test('浏览器没拉起来（插件抛 PlatformException）：句柄照常交出、流程不终止、browserOpened=false',
      () async {
    launchBehaviour = 'throw';
    final (
      Future<DesktopOAuthResult> flow,
      DesktopOAuthLaunch launch,
      String redirectUri
    ) = await start();
    expect(await launch.browserOpened, isFalse);
    expect(launchedUrls, hasLength(1));
    expect(await portOpen(redirectUri), isTrue, reason: '流程必须还在等，用户手里有链接');

    // 用户把链接贴到别的浏览器完成授权 → 照常拿到授权码。
    await hitCallback(redirectUri, 'code=viaOtherBrowser');
    expect((await flow).code, 'viaOtherBrowser');
  });

  test('浏览器回 false 且**没有**观察者：仍像以前一样抛错（没人拿得到链接）', () async {
    launchBehaviour = 'false';
    await expectLater(
      runDesktopOAuthLoopback(host: '127.0.0.1', buildAuthUrl: buildAuthUrl),
      throwsA(isA<SyncAuthError>().having(
        (SyncAuthError e) => e.message,
        'message',
        contains('Failed to launch browser'),
      )),
    );
  });

  test('cancel() 立刻以 cancelled 收场、finished 完成并释放回环端口', () async {
    final (
      Future<DesktopOAuthResult> flow,
      DesktopOAuthLaunch launch,
      String redirectUri
    ) = await start();
    expect(await portOpen(redirectUri), isTrue, reason: '等待期间端口应在监听');

    launch.cancel();
    launch.cancel(); // 重复取消无副作用

    await expectLater(
      flow,
      throwsA(isA<SyncAuthError>().having(
        (SyncAuthError e) => e.kind,
        'kind',
        SyncAuthFailureKind.cancelled,
      )),
    );
    await launch.finished;
    expect(await portOpen(redirectUri), isFalse, reason: '取消后端口必须释放');
  });

  test('超时也经由同一个 completer：抛 browserTimeout 且 finished 完成', () async {
    final (Future<DesktopOAuthResult> flow, DesktopOAuthLaunch launch, _) =
        await start(timeout: const Duration(milliseconds: 200));
    await expectLater(
      flow,
      throwsA(isA<SyncAuthError>().having(
        (SyncAuthError e) => e.kind,
        'kind',
        SyncAuthFailureKind.browserTimeout,
      )),
    );
    await launch.finished.timeout(const Duration(seconds: 1));
  });

  test('reopenBrowser() 用同一条 URL 再拉一次浏览器；拉不起来时回 false 而不是抛', () async {
    final (
      Future<DesktopOAuthResult> flow,
      DesktopOAuthLaunch launch,
      String redirectUri
    ) = await start();
    expect(launchedUrls, hasLength(1));

    expect(await launch.reopenBrowser(), isTrue);
    expect(launchedUrls, hasLength(2));
    expect(launchedUrls[1], launchedUrls[0]);

    launchBehaviour = 'throw';
    expect(await launch.reopenBrowser(), isFalse);

    await hitCallback(redirectUri, 'code=z');
    expect((await flow).code, 'z');
  });

  test('DesktopOAuthLaunchObserver.observe 作用域：body 内生效，离开即还原', () async {
    expect(DesktopOAuthLaunchObserver.debugCurrent, isNull);
    DesktopOAuthLaunch? seen;
    late String redirectUri;

    final String out = await DesktopOAuthLaunchObserver.observe(
      (DesktopOAuthLaunch launch) => seen = launch,
      () async {
        expect(DesktopOAuthLaunchObserver.debugCurrent, isNotNull);
        final Future<DesktopOAuthResult> flow = runDesktopOAuthLoopback(
          host: '127.0.0.1',
          buildAuthUrl: (String r) {
            redirectUri = r;
            return buildAuthUrl(r);
          },
        );
        for (int i = 0; i < 50 && seen == null; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
        expect(seen, isNotNull, reason: '未显式传 onLaunched 时应落到观察者');
        await hitCallback(redirectUri, 'code=ok');
        return (await flow).code;
      },
    );
    expect(out, 'ok');
    expect(DesktopOAuthLaunchObserver.debugCurrent, isNull,
        reason: '离开 observe 后监听器必须还原');
  });

  test('observe 的 body 抛出时监听器同样还原', () async {
    await expectLater(
      DesktopOAuthLaunchObserver.observe(
        (DesktopOAuthLaunch _) {},
        () async => throw StateError('boom'),
      ),
      throwsStateError,
    );
    expect(DesktopOAuthLaunchObserver.debugCurrent, isNull);
  });

  test('两次 observe 交错结束：先结束的 A 不抹掉后来者 B，B 结束后槽位为空', () async {
    void la(DesktopOAuthLaunch _) {}
    void lb(DesktopOAuthLaunch _) {}
    final Completer<void> ca = Completer<void>();
    final Completer<void> cb = Completer<void>();

    final Future<void> a =
        DesktopOAuthLaunchObserver.observe(la, () => ca.future);
    final Future<void> b =
        DesktopOAuthLaunchObserver.observe(lb, () => cb.future);
    expect(DesktopOAuthLaunchObserver.debugCurrent, same(lb));

    ca.complete();
    await a;
    expect(DesktopOAuthLaunchObserver.debugCurrent, same(lb),
        reason: 'A 先结束不能把 B 的监听器抹成 null（正是本 PR 要修的「无对话框转圈」）');

    cb.complete();
    await b;
    expect(DesktopOAuthLaunchObserver.debugCurrent, isNull,
        reason: 'B 结束后不能残留已经结束的 A');
  });
}
