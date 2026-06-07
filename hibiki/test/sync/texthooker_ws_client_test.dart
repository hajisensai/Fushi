import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:web_socket_channel/io.dart';
import 'package:hibiki/src/sync/texthooker_service.dart';
import 'package:hibiki/src/sync/texthooker_ws_client.dart';

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
}
