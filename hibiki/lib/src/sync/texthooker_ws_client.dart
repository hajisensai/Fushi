import 'dart:async';

import 'package:web_socket_channel/web_socket_channel.dart';

import 'package:hibiki/src/sync/texthooker_message.dart';
import 'package:hibiki/src/sync/texthooker_service.dart';

/// WS 连接工厂（注入以便测试）。
typedef WsChannelFactory = WebSocketChannel Function(String url);

/// 连接一个或多个 texthooker WS server（默认 6677/9001/2333），把收到的每条
/// 消息经 [parseTexthookerMessage] 解析后 append 到 [TexthookerService]。
/// 断线固定退避自动重连。
class TexthookerWsClient {
  TexthookerWsClient({
    required List<String> urls,
    required TexthookerService service,
    required WsChannelFactory channelFactory,
    Duration retryDelay = const Duration(seconds: 3),
  })  : _urls = urls,
        _service = service,
        _channelFactory = channelFactory,
        _retryDelay = retryDelay;

  /// 事实标准默认端口（Textractor/mpv 6677、agent 9001、LunaTranslator 2333）。
  static const List<String> defaultUrls = <String>[
    'ws://localhost:6677',
    'ws://localhost:9001',
    'ws://localhost:2333',
  ];

  final List<String> _urls;
  final TexthookerService _service;
  final WsChannelFactory _channelFactory;
  final Duration _retryDelay;

  final List<StreamSubscription<dynamic>> _subs =
      <StreamSubscription<dynamic>>[];
  final List<Timer> _retryTimers = <Timer>[];
  bool _running = false;

  bool get isRunning => _running;

  void start() {
    if (_running) return;
    _running = true;
    for (final String url in _urls) {
      _connect(url);
    }
  }

  void _connect(String url) {
    if (!_running) return;
    final WebSocketChannel channel;
    try {
      channel = _channelFactory(url);
    } catch (_) {
      // 连接构造失败（如非法 URL / 端口未监听）：退避后重试。
      _scheduleRetry(url);
      return;
    }
    // BUG-115：`IOWebSocketChannel.connect` 是惰性的——握手/连接失败（典型是
    // texthooker server 未监听时的 ECONNREFUSED）会作为**未处理的异步错误**落在
    // `ready` future 上逃逸到全局 zone（被记成 UncaughtZone 噪音，按重连周期每
    // 几秒刷三条）。这里显式吞掉 `ready` 的错误；真正的重连仍由下面 stream 的
    // onError/onDone 驱动，避免重复 scheduleRetry。
    unawaited(channel.ready.then<void>(
      (_) {},
      onError: (Object _) {},
    ));
    final StreamSubscription<dynamic> sub = channel.stream.listen(
      (dynamic data) => _service.appendLine(parseTexthookerMessage('$data')),
      onError: (Object _) => _scheduleRetry(url),
      onDone: () => _scheduleRetry(url),
      cancelOnError: true,
    );
    _subs.add(sub);
  }

  void _scheduleRetry(String url) {
    if (!_running) return;
    final Timer t = Timer(_retryDelay, () => _connect(url));
    _retryTimers.add(t);
  }

  Future<void> stop() async {
    _running = false;
    for (final Timer t in _retryTimers) {
      t.cancel();
    }
    _retryTimers.clear();
    for (final StreamSubscription<dynamic> sub in _subs) {
      await sub.cancel();
    }
    _subs.clear();
  }
}
