import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/utils/net/app_native_proxy.dart';
import 'package:fushi_engine/utils/net/app_proxy.dart';

/// BUG-2381：Aidoku 的 wasm host 是 Rust `reqwest`，https 请求经 `hyper-util` 的
/// CONNECT 隧道打进本地中继。两件事在这条链上必须成立，而既有中继测试都用 Dart
/// 客户端验证，结构上验不到：
///
/// 1. hyper-util 对隧道响应的判据比 Dart `HttpClient` 严格（`tunnel.rs`）：状态行
///    必须以 `HTTP/1.1 200` 开头，且**首批读到的字节必须正好以 `\r\n\r\n` 结尾**，
///    否则一律 `TunnelUnsuccessful`。
/// 2. 隧道开不起来时中继只能回一个裸 502，而 hyper 把任何非 200 的 CONNECT 结果
///    收敛成一个词 `unsuccessful`——中继是**唯一**知道真实原因的地方，必须把它
///    交出来，否则「解析不了 / 被拒 / 超时」在 Rust 侧长得一模一样。
void main() {
  late AppNativeProxy relay;
  late String Function() oldMode;
  late String Function() oldProxy;
  late String Function() oldUsername;
  late String Function() oldPassword;
  late void Function(String) oldSink;
  late List<String> logged;

  setUp(() async {
    oldMode = appUserProxyModeReader;
    oldProxy = appUserProxyReader;
    oldUsername = appUserProxyUsernameReader;
    oldPassword = appUserProxyPasswordReader;
    oldSink = appNativeProxyLogSink;
    appUserProxyModeReader = () => kProxyModeDirect;
    appUserProxyUsernameReader = () => '';
    appUserProxyPasswordReader = () => '';
    logged = <String>[];
    appNativeProxyLogSink = logged.add;
    relay = await AppNativeProxy.start();
  });
  tearDown(() async {
    await relay.close();
    appNativeProxyLogSink = oldSink;
    appUserProxyModeReader = oldMode;
    appUserProxyReader = oldProxy;
    appUserProxyUsernameReader = oldUsername;
    appUserProxyPasswordReader = oldPassword;
  });

  String auth() =>
      'Basic ${base64.encode(utf8.encode(relay.endpoint.userInfo))}';

  test('hyper-util 的 CONNECT 隧道在本地中继上真的建得起来', () async {
    final ServerSocket origin = await ServerSocket.bind(
      InternetAddress.loopbackIPv4,
      0,
    );
    addTearDown(origin.close);
    origin.listen((Socket socket) {
      socket.listen((List<int> data) {
        socket.add(utf8.encode('echo:${utf8.decode(data)}'));
      });
    });

    final Socket socket = await Socket.connect(
      relay.endpoint.host,
      relay.endpoint.port,
    );
    addTearDown(socket.destroy);
    final StreamIterator<List<int>> reader = StreamIterator<List<int>>(socket);
    addTearDown(reader.cancel);

    // 用 `localhost` 而不是 `127.0.0.1`：Dart HttpServer 在派发前就拒掉数字
    // authority 的 CONNECT（既有测试 app_native_proxy_test.dart 已记录）。
    final String authority = 'localhost:${origin.port}';
    socket.add(
      utf8.encode(
        'CONNECT $authority HTTP/1.1\r\n'
        'Host: $authority\r\n'
        'Proxy-Authorization: ${auth()}\r\n'
        '\r\n',
      ),
    );
    await socket.flush();

    final List<int> head = <int>[];
    while (await reader.moveNext().timeout(const Duration(seconds: 5))) {
      head.addAll(reader.current);
      final String text = latin1.decode(head);
      expect(
        text,
        startsWith('HTTP/1.1 200'),
        reason: 'hyper-util tunnel.rs 只认 200 开头，其余一律 TunnelUnsuccessful',
      );
      if (text.endsWith('\r\n\r\n')) break;
    }
    expect(
      latin1.decode(head),
      endsWith('\r\n\r\n'),
      reason: r'hyper-util tunnel.rs 的 recvd.ends_with(b"\r\n\r\n") 判据',
    );

    socket.add(utf8.encode('ping'));
    await socket.flush();
    expect(await reader.moveNext().timeout(const Duration(seconds: 5)), isTrue);
    expect(latin1.decode(reader.current), 'echo:ping');
  });

  test('隧道开不起来时，真实原因落到日志出口而不是被 502 吞掉', () async {
    // 端口上没有监听者 → Socket.connect 抛 SocketException。中继对上仍然只能
    // 回 502（不能把原因写进响应），但原因必须留在日志里。
    final ServerSocket closed = await ServerSocket.bind(
      InternetAddress.loopbackIPv4,
      0,
    );
    final int deadPort = closed.port;
    await closed.close();

    final Socket socket = await Socket.connect(
      relay.endpoint.host,
      relay.endpoint.port,
    );
    addTearDown(socket.destroy);
    socket.write(
      'CONNECT localhost:$deadPort HTTP/1.1\r\n'
      'Host: localhost:$deadPort\r\n'
      'Proxy-Authorization: ${auth()}\r\n'
      'Connection: close\r\n'
      '\r\n',
    );
    final String response = await utf8.decoder
        .bind(socket)
        .join()
        .timeout(const Duration(seconds: 30));

    expect(response, startsWith('HTTP/1.1 502'));
    expect(response, isNot(contains('SocketException')));
    expect(logged, hasLength(1));
    expect(logged.single, contains('CONNECT localhost:$deadPort'));
    expect(
      logged.single,
      contains('SocketException'),
      reason: 'BUG-2381：中继是唯一知道原因的一层，不能连它也抹掉',
    );
  });

  test('中继死了以后能自愈：下一次取端点会另起一个活的', () async {
    final AppNativeProxy first = await ensureAppNativeProxy();
    addTearDown(first.close);
    expect(first.isRunning, isTrue);
    // 缓存命中时必须还是同一个，不能每次都重启。
    expect(identical(await ensureAppNativeProxy(), first), isTrue);

    // iOS 把 app 挂起后可能收走监听 socket；`??=` 缓存下这就是「一次坏、
    // 永久坏」。
    await first.close();
    expect(first.isRunning, isFalse);

    final AppNativeProxy second = await ensureAppNativeProxy();
    addTearDown(second.close);
    expect(identical(second, first), isFalse);
    expect(second.isRunning, isTrue);

    // 新中继真的在服务，而不只是换了个端口号。
    final Socket socket = await Socket.connect(
      second.endpoint.host,
      second.endpoint.port,
    );
    addTearDown(socket.destroy);
    socket.write(
      'GET http://origin.invalid/ HTTP/1.1\r\n'
      'Host: origin.invalid\r\n'
      'Connection: close\r\n'
      '\r\n',
    );
    final String response = await utf8.decoder
        .bind(socket)
        .join()
        .timeout(const Duration(seconds: 10));
    expect(response, startsWith('HTTP/1.1 407'));
  });

  test('日志出口先脱敏中继凭据', () async {
    final Socket socket = await Socket.connect(
      relay.endpoint.host,
      relay.endpoint.port,
    );
    addTearDown(socket.destroy);
    // query 里塞上凭据本身：脱敏必须在拼日志之后仍然生效。
    final String secret = relay.endpoint.userInfo.split(':').last;
    socket.write(
      'CONNECT fushi.invalid:443?token=$secret HTTP/1.1\r\n'
      'Host: fushi.invalid\r\n'
      'Proxy-Authorization: ${auth()}\r\n'
      'Connection: close\r\n'
      '\r\n',
    );
    final String response = await utf8.decoder
        .bind(socket)
        .join()
        .timeout(const Duration(seconds: 10));

    expect(response, startsWith('HTTP/1.1 502'));
    expect(logged, hasLength(1));
    expect(logged.single, isNot(contains(secret)));
    expect(logged.single, contains('[native-proxy]'));
  });
}
