import 'dart:async';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:hibiki/src/sync/texthooker_service.dart';
import 'package:hibiki/src/sync/texthooker_ws_client.dart';

/// 模拟 IOWebSocketChannel.connect 的连接失败：`ready` 与 `stream` 都抛错。
/// 只实现 _connect 实际用到的 `ready` / `stream`，其余经 noSuchMethod 兜底。
class _FailingChannel implements WebSocketChannel {
  _FailingChannel(this._ready, this._stream);
  final Future<void> _ready;
  final Stream<dynamic> _stream;

  @override
  Future<void> get ready => _ready;

  @override
  Stream<dynamic> get stream => _stream;

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

void main() {
  setUp(() => TexthookerService.instance.clear());

  test('receives raw text and {sentence} json from a ws server', () async {
    final server = await HttpServer.bind('127.0.0.1', 0);
    server.transform(WebSocketTransformer()).listen((WebSocket ws) {
      ws.add('裸テキスト');
      ws.add('{"sentence":"包まれた"}');
    });
    final String url = 'ws://127.0.0.1:${server.port}';

    final client = TexthookerWsClient(
      urls: [url],
      service: TexthookerService.instance,
      channelFactory: (String u) => IOWebSocketChannel.connect(Uri.parse(u)),
    );
    client.start();

    final deadline = DateTime.now().add(const Duration(seconds: 5));
    while (TexthookerService.instance.lines.length < 2 &&
        DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }

    expect(TexthookerService.instance.lines, ['裸テキスト', '包まれた']);

    await client.stop();
    await server.close(force: true);
  });

  test('connection state exposes running flag', () async {
    final client = TexthookerWsClient(
      urls: const <String>[],
      service: TexthookerService.instance,
      channelFactory: (String u) => throw UnimplementedError(),
    );
    expect(client.isRunning, false);
    client.start();
    expect(client.isRunning, true);
    await client.stop();
    expect(client.isRunning, false);
  });

  // BUG-115：texthooker server 未监听时，IOWebSocketChannel.connect 的连接失败
  // 会作为未处理异步错误落在 `ready` future 上逃逸到 zone（被记成 UncaughtZone
  // 噪音，每个重连周期刷一批）。修复后这些错误被吞掉，但仍正常排程重连。
  test('connect failure does not escape the zone but still retries', () async {
    final List<Object> escaped = <Object>[];
    await runZonedGuarded(() async {
      int factoryCalls = 0;
      final client = TexthookerWsClient(
        urls: const <String>['ws://localhost:6677'],
        service: TexthookerService.instance,
        retryDelay: const Duration(milliseconds: 10),
        channelFactory: (String u) {
          factoryCalls++;
          // 连接失败：ready 抛错 + stream 抛错后关闭（IOWebSocketChannel 行为）。
          final Stream<dynamic> stream =
              Stream<dynamic>.error(WebSocketChannelException('refused'));
          final Future<void> ready =
              Future<void>.error(WebSocketChannelException('refused'));
          return _FailingChannel(ready, stream);
        },
      );
      client.start();
      // 等首连失败 + 至少一次退避重连。
      await Future<void>.delayed(const Duration(milliseconds: 60));
      expect(factoryCalls, greaterThanOrEqualTo(2),
          reason: '连接失败后应排程重连，再次调用 channelFactory');
      await client.stop();
    }, (Object error, StackTrace stack) => escaped.add(error));

    expect(escaped, isEmpty, reason: 'BUG-115：连接失败异常不得逃逸到全局 zone');
  });
}
