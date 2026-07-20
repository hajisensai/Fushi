import 'package:flutter/foundation.dart';
import 'package:web_socket_channel/io.dart';

import 'package:hibiki/src/sync/texthooker_service.dart';
import 'package:hibiki/src/sync/texthooker_ws_client.dart';

/// 全局持有 texthooker WS client，按设置开关启停。
class TexthookerWsClientHost extends ChangeNotifier {
  TexthookerWsClientHost._();
  static final TexthookerWsClientHost instance = TexthookerWsClientHost._();

  TexthookerWsClient? _client;

  bool get isRunning => _client?.isRunning ?? false;
  List<TexthookerEndpointStatus> get endpointStatuses =>
      _client?.endpointStatuses ?? const <TexthookerEndpointStatus>[];

  void start(List<String> urls) {
    if (_client != null) return;
    final TexthookerWsClient client = TexthookerWsClient(
      urls: urls,
      service: TexthookerService.instance,
      channelFactory: (String url) =>
          IOWebSocketChannel.connect(Uri.parse(url)),
    );
    client.start();
    client.addListener(notifyListeners);
    _client = client;
    notifyListeners();
  }

  Future<void> stop() async {
    final TexthookerWsClient? client = _client;
    client?.removeListener(notifyListeners);
    await client?.stop();
    _client = null;
    notifyListeners();
  }

  Future<void> restart(List<String> urls) async {
    await stop();
    start(urls);
  }
}
