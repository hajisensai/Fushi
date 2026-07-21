import 'package:flutter/foundation.dart';
import 'package:web_socket_channel/io.dart';

import 'package:hibiki/src/sync/texthooker_service.dart';
import 'package:hibiki/src/sync/texthooker_ws_client.dart';

/// app 级单例，持有并托管 texthooker WS **客户端**（[TexthookerWsClient]，连出去连
/// Textractor/LunaTranslator/mpv 等外部 WS 服务端），按设置开关启停/重启。
///
/// 命名说明：这是「持有 client 的宿主/管理器」，**不是** WS 服务端；旧名 `...Host` 易被
/// 误读成 server，故更名为 `...Manager`（无行为变化，纯消歧）。
class TexthookerWsClientManager extends ChangeNotifier {
  TexthookerWsClientManager._();
  static final TexthookerWsClientManager instance =
      TexthookerWsClientManager._();

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
