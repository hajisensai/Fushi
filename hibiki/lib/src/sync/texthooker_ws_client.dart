import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'package:fushi/src/sync/texthooker_message.dart';
import 'package:fushi/src/sync/texthooker_service.dart';

/// WS 连接工厂（注入以便测试）。
typedef WsChannelFactory = WebSocketChannel Function(String url);

/// 连接一个或多个 texthooker WS server（默认 6677/9001/2333），把收到的每条
/// 消息经 [parseTexthookerMessage] 解析后 append 到 [TexthookerService]。
/// 断线固定退避自动重连。
enum TexthookerEndpointPhase { connecting, connected, retrying, stopped }

@immutable
class TexthookerEndpointStatus {
  const TexthookerEndpointStatus({
    required this.url,
    required this.phase,
    this.lastError,
    this.lastMessageAt,
  });

  final String url;
  final TexthookerEndpointPhase phase;
  final String? lastError;
  final DateTime? lastMessageAt;

  TexthookerEndpointStatus copyWith({
    TexthookerEndpointPhase? phase,
    String? lastError,
    DateTime? lastMessageAt,
    bool clearError = false,
  }) {
    return TexthookerEndpointStatus(
      url: url,
      phase: phase ?? this.phase,
      lastError: clearError ? null : lastError ?? this.lastError,
      lastMessageAt: lastMessageAt ?? this.lastMessageAt,
    );
  }
}

class TexthookerWsClient extends ChangeNotifier {
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
  final Set<String> _retryPending = <String>{};
  bool _running = false;
  final Map<String, TexthookerEndpointStatus> _statuses =
      <String, TexthookerEndpointStatus>{};

  bool get isRunning => _running;
  List<TexthookerEndpointStatus> get endpointStatuses =>
      List<TexthookerEndpointStatus>.unmodifiable(_statuses.values);

  void start() {
    if (_running) return;
    _running = true;
    for (final String url in _urls) {
      _setStatus(url, TexthookerEndpointPhase.connecting);
      unawaited(_connect(url));
    }
  }

  Future<void> _connect(String url) async {
    if (!_running) return;
    _setStatus(url, TexthookerEndpointPhase.connecting);
    final WebSocketChannel channel;
    try {
      channel = _channelFactory(url);
    } catch (error) {
      // 连接构造失败（如非法 URL）：退避后重试，绝不上抛。
      _onConnectFailure(url, error);
      return;
    }
    // 关键：[IOWebSocketChannel.connect] 是惰性的，连接建立阶段的失败
    //（用户没开 Textractor/mpv 的 WS 源时「Connection closed before full
    // header was received」）通过 [WebSocketChannel.ready] 这个 Future 抛出。
    // 若不 await/catch 它，rejection 会逃逸到 UncaughtZone 刷屏（真机 bug）。
    // 这里静默吞掉连接失败并退避重试，stream 的 onError 仅兜底「连上后中途
    // 断线」。
    try {
      await channel.ready;
    } catch (error) {
      _onConnectFailure(url, error);
      return;
    }
    // ready 期间可能已被 stop()：不再监听。
    if (!_running) return;
    _setStatus(url, TexthookerEndpointPhase.connected, clearError: true);
    final StreamSubscription<dynamic> sub = channel.stream.listen(
      (dynamic data) {
        _service.appendLine(
          parseTexthookerMessage('$data'),
          source: TexthookerLineSource.websocket,
          sourceLabel: url,
        );
        _setStatus(
          url,
          TexthookerEndpointPhase.connected,
          lastMessageAt: DateTime.now(),
          clearError: true,
        );
      },
      // 连上后中途断线：退避重连，同样不上抛。
      onError: (Object error) => _onConnectFailure(url, error),
      onDone: () => _scheduleRetry(url),
      cancelOnError: true,
    );
    _subs.add(sub);
  }

  /// 连接失败统一处理：可选一行调试日志 + 退避重试，绝不把异常上抛到
  /// UncaughtZone。
  void _onConnectFailure(String url, Object error) {
    if (kDebugMode) {
      debugPrint('[texthooker] WS connect failed ($url): $error; retrying');
    }
    _setStatus(url, TexthookerEndpointPhase.retrying, lastError: '$error');
    _scheduleRetry(url);
  }

  void _scheduleRetry(String url) {
    if (!_running || !_retryPending.add(url)) return;
    _setStatus(url, TexthookerEndpointPhase.retrying);
    final Timer t = Timer(_retryDelay, () {
      _retryPending.remove(url);
      unawaited(_connect(url));
    });
    _retryTimers.add(t);
  }

  Future<void> stop() async {
    _running = false;
    for (final Timer t in _retryTimers) {
      t.cancel();
    }
    _retryTimers.clear();
    _retryPending.clear();
    for (final StreamSubscription<dynamic> sub in _subs) {
      await sub.cancel();
    }
    _subs.clear();
    for (final String url in _urls) {
      _setStatus(url, TexthookerEndpointPhase.stopped);
    }
  }

  void _setStatus(
    String url,
    TexthookerEndpointPhase phase, {
    String? lastError,
    DateTime? lastMessageAt,
    bool clearError = false,
  }) {
    final TexthookerEndpointStatus previous = _statuses[url] ??
        TexthookerEndpointStatus(
          url: url,
          phase: TexthookerEndpointPhase.stopped,
        );
    _statuses[url] = previous.copyWith(
      phase: phase,
      lastError: lastError,
      lastMessageAt: lastMessageAt,
      clearError: clearError,
    );
    notifyListeners();
  }
}
