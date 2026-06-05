import 'package:web_socket_channel/io.dart';

import 'package:hibiki/src/sync/texthooker_service.dart';
import 'package:hibiki/src/sync/texthooker_ws_client.dart';

/// 全局持有 texthooker WS client，按设置开关启停。
class TexthookerWsClientHost {
  TexthookerWsClientHost._();
  static final TexthookerWsClientHost instance = TexthookerWsClientHost._();

  TexthookerWsClient? _client;

  bool get isRunning => _client?.isRunning ?? false;

  void start(List<String> urls) {
    if (_client != null) return;
    final TexthookerWsClient client = TexthookerWsClient(
      urls: urls,
      service: TexthookerService.instance,
      channelFactory: (String url) =>
          IOWebSocketChannel.connect(Uri.parse(url)),
    );
    client.start();
    _client = client;
  }

  Future<void> stop() async {
    await _client?.stop();
    _client = null;
  }

  Future<void> restart(List<String> urls) async {
    await stop();
    start(urls);
  }
}
