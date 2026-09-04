import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/sync/desktop_oauth.dart';
import 'package:fushi/src/sync/sync_backend.dart';

/// BUG-2120：桌面 loopback 授权拉起浏览器后必须把链接句柄交给观察者，
/// 且句柄的三个动作（复制用的 URL / 重开浏览器 / 取消）各自真的落到流程上。
///
/// 这里跑的是**真回环服务器**（`HttpServer.bind` 到临时端口）+ 桩掉的 url_launcher
/// 通道，断言的是行为：观察者拿到的 URL 与浏览器实际被拉起的 URL 逐字节一致、取消能让
/// 等待立刻以 [SyncAuthFailureKind.cancelled] 结束并释放端口、重开会再拉一次同一 URL。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const MethodChannel channel = MethodChannel(
    'plugins.flutter.io/url_launcher',
  );
  final List<String> launchedUrls = <String>[];

  setUp(() {
    launchedUrls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall call) async {
      if (call.method == 'launch') {
        final Map<Object?, Object?> args = Map<Object?, Object?>.from(
          call.arguments as Map,
        );
        launchedUrls.add(args['url'] as String);
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
      final Socket s = await Socket.connect(
        u.host,
        u.port,
        timeout: const Duration(seconds: 1),
      );
      s.destroy();
      return true;
    } on SocketException {
      return false;
    }
  }

  test('观察者收到的 authUrl 与浏览器实际被拉起的 URL 逐字节一致', () async {
    late String redirectUri;
    DesktopOAuthLaunch? seen;

    final Future<DesktopOAuthResult> flow = runDesktopOAuthLoopback(
      host: '127.0.0.1',
      buildAuthUrl: (String r) {
        redirectUri = r;
        return buildAuthUrl(r);
      },
      onLaunched: (DesktopOAuthLaunch launch) => seen = launch,
    );
    // 让 bind + launch 跑完，观察者被回调。
    await Future<void>.delayed(Duration.zero);
    for (int i = 0; i < 50 && seen == null; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }

    expect(seen, isNotNull, reason: '拉起浏览器后必须回调观察者');
    expect(launchedUrls, hasLength(1));
    expect(seen!.authUrl.toString(), launchedUrls.single);
    expect(seen!.authUrl, buildAuthUrl(redirectUri));
    expect(redirectUri, startsWith('http://127.0.0.1:'));

    await hitCallback(redirectUri, 'code=abc123');
    final DesktopOAuthResult result = await flow;
    expect(result.code, 'abc123');
    expect(result.redirectUri, redirectUri);
  });

  test('cancel() 立刻以 cancelled 收场并释放回环端口', () async {
    late String redirectUri;
    final Completer<DesktopOAuthLaunch> launched =
        Completer<DesktopOAuthLaunch>();

    final Future<DesktopOAuthResult> flow = runDesktopOAuthLoopback(
      host: '127.0.0.1',
      buildAuthUrl: (String r) {
        redirectUri = r;
        return buildAuthUrl(r);
      },
      onLaunched: launched.complete,
    );
    final DesktopOAuthLaunch launch = await launched.future;
    expect(await portOpen(redirectUri), isTrue, reason: '等待期间端口应在监听');

    launch.cancel();
    launch.cancel(); // 重复取消无副作用

    await expectLater(
      flow,
      throwsA(
        isA<SyncAuthError>().having(
          (SyncAuthError e) => e.kind,
          'kind',
          SyncAuthFailureKind.cancelled,
        ),
      ),
    );
    expect(await portOpen(redirectUri), isFalse, reason: '取消后端口必须释放');
  });

  test('reopenBrowser() 用同一条 URL 再拉一次浏览器', () async {
    late String redirectUri;
    final Completer<DesktopOAuthLaunch> launched =
        Completer<DesktopOAuthLaunch>();

    final Future<DesktopOAuthResult> flow = runDesktopOAuthLoopback(
      host: '127.0.0.1',
      buildAuthUrl: (String r) {
        redirectUri = r;
        return buildAuthUrl(r);
      },
      onLaunched: launched.complete,
    );
    final DesktopOAuthLaunch launch = await launched.future;
    expect(launchedUrls, hasLength(1));

    expect(await launch.reopenBrowser(), isTrue);
    expect(launchedUrls, hasLength(2));
    expect(launchedUrls[1], launchedUrls[0]);

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
    expect(
      DesktopOAuthLaunchObserver.debugCurrent,
      isNull,
      reason: '离开 observe 后监听器必须还原',
    );
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
}
