// Chrome DevTools Protocol 的最小客户端：/json/list 选目标 + WebSocket 上的命令 / 事件。
// 只覆盖 Tyrano DOM 数据源用到的部分；纯 dart:io。

import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// /json/list 里的一个调试目标。
class CdpTarget {
  /// 创建目标。
  const CdpTarget({
    required this.id,
    required this.type,
    required this.url,
    required this.webSocketDebuggerUrl,
  });

  /// 目标 id。
  final String id;

  /// 类型（`page` / `service_worker` / ...）。
  final String type;

  /// 当前 URL。
  final String url;

  /// 调试 WebSocket 地址；已有别的客户端独占时 Chromium 不给，为 null。
  final String? webSocketDebuggerUrl;
}

/// 解析 /json/list 响应体；格式不对返回空表。
List<CdpTarget> parseCdpTargetList(String body) {
  final Object? decoded;
  try {
    decoded = jsonDecode(body);
  } on FormatException {
    return const <CdpTarget>[];
  }
  if (decoded is! List<Object?>) return const <CdpTarget>[];
  final List<CdpTarget> targets = <CdpTarget>[];
  for (final Object? item in decoded) {
    if (item is! Map<String, Object?>) continue;
    final Object? id = item['id'];
    final Object? type = item['type'];
    final Object? url = item['url'];
    final Object? ws = item['webSocketDebuggerUrl'];
    if (id is! String || type is! String) continue;
    targets.add(
      CdpTarget(
        id: id,
        type: type,
        url: url is String ? url : '',
        webSocketDebuggerUrl: ws is String && ws.isNotEmpty ? ws : null,
      ),
    );
  }
  return targets;
}

/// 选游戏页面：第一个可连的 `page` 目标，跳过 DevTools 自身的页面。
CdpTarget? selectGamePageTarget(List<CdpTarget> targets) {
  for (final CdpTarget target in targets) {
    if (target.type != 'page') continue;
    if (target.webSocketDebuggerUrl == null) continue;
    if (target.url.startsWith('devtools://')) continue;
    return target;
  }
  return null;
}

/// 一条 CDP 入站消息：命令响应（[id] 非 null）或事件（[method] 非 null）。
class CdpIncoming {
  /// 创建入站消息。
  const CdpIncoming({
    this.id,
    this.method,
    this.params,
    this.result,
    this.error,
  });

  /// 命令响应的 id。
  final int? id;

  /// 事件名。
  final String? method;

  /// 事件参数。
  final Map<String, Object?>? params;

  /// 命令结果。
  final Map<String, Object?>? result;

  /// 命令错误（`{code, message}`）。
  final Map<String, Object?>? error;
}

/// 解析一条 CDP 入站文本帧；不是对象返回 null。
CdpIncoming? parseCdpIncoming(String text) {
  final Object? decoded;
  try {
    decoded = jsonDecode(text);
  } on FormatException {
    return null;
  }
  if (decoded is! Map<String, Object?>) return null;
  final Object? id = decoded['id'];
  final Object? method = decoded['method'];
  final Object? params = decoded['params'];
  final Object? result = decoded['result'];
  final Object? error = decoded['error'];
  return CdpIncoming(
    id: id is int ? id : null,
    method: method is String ? method : null,
    params: params is Map<String, Object?> ? params : null,
    result: result is Map<String, Object?> ? result : null,
    error: error is Map<String, Object?> ? error : null,
  );
}

/// CDP 命令返回错误。
class CdpCommandException implements Exception {
  /// 创建异常。
  const CdpCommandException(this.method, this.message);

  /// 命令名。
  final String method;

  /// 错误信息。
  final String message;

  @override
  String toString() => 'CdpCommandException($method): $message';
}

/// 拉一次 `http://<host>:<port>/json/list`；连不上 / 非 200 返回 null。
Future<List<CdpTarget>?> fetchCdpTargets(
  String host,
  int port, {
  Duration requestTimeout = const Duration(seconds: 2),
}) async {
  final HttpClient client = HttpClient()
    ..connectionTimeout = requestTimeout
    // 回环地址，不走系统 / 环境变量里的代理。
    ..findProxy = ((Uri _) => 'DIRECT');
  try {
    final HttpClientRequest request = await client
        .getUrl(Uri(scheme: 'http', host: host, port: port, path: '/json/list'))
        .timeout(requestTimeout);
    final HttpClientResponse response = await request.close().timeout(
      requestTimeout,
    );
    final String body = await response
        .transform(utf8.decoder)
        .join()
        .timeout(requestTimeout);
    if (response.statusCode != HttpStatus.ok) return null;
    return parseCdpTargetList(body);
  } on Object {
    return null;
  } finally {
    client.close(force: true);
  }
}

/// 一条 CDP WebSocket 连接。
class CdpConnection {
  CdpConnection._(this._socket) {
    _subscription = _socket.listen(
      _onData,
      onDone: _onDone,
      onError: (Object _) => _onDone(),
      cancelOnError: true,
    );
  }

  /// 连上 [webSocketUrl]（不带 Origin 头，Chromium ≥111 对无 Origin 的客户端放行）。
  static Future<CdpConnection> connect(
    String webSocketUrl, {
    Duration timeout = const Duration(seconds: 5),
  }) async {
    final WebSocket socket = await WebSocket.connect(
      webSocketUrl,
    ).timeout(timeout);
    return CdpConnection._(socket);
  }

  final WebSocket _socket;
  late final StreamSubscription<Object?> _subscription;
  final Map<int, Completer<Map<String, Object?>>> _pending =
      <int, Completer<Map<String, Object?>>>{};
  final StreamController<CdpIncoming> _events =
      StreamController<CdpIncoming>.broadcast(sync: true);
  final Completer<void> _closed = Completer<void>();
  int _nextId = 0;

  /// 事件流（命令响应不进这里）。
  Stream<CdpIncoming> get events => _events.stream;

  /// 连接断开（任一方关闭）时完成。
  Future<void> get closed => _closed.future;

  /// 是否已断开。
  bool get isClosed => _closed.isCompleted;

  /// 发一条命令并等结果；连接已断开或命令报错时抛异常。
  Future<Map<String, Object?>> send(
    String method, [
    Map<String, Object?> params = const <String, Object?>{},
  ]) {
    if (isClosed) {
      return Future<Map<String, Object?>>.error(
        CdpCommandException(method, 'connection closed'),
      );
    }
    final int id = ++_nextId;
    final Completer<Map<String, Object?>> completer =
        Completer<Map<String, Object?>>();
    _pending[id] = completer;
    _socket.add(
      jsonEncode(<String, Object?>{
        'id': id,
        'method': method,
        'params': params,
      }),
    );
    return completer.future.then((Map<String, Object?> result) {
      final Object? error = result['__error'];
      if (error != null) throw CdpCommandException(method, '$error');
      return result;
    });
  }

  void _onData(Object? data) {
    if (data is! String) return;
    final CdpIncoming? message = parseCdpIncoming(data);
    if (message == null) return;
    final int? id = message.id;
    if (id != null) {
      final Completer<Map<String, Object?>>? completer = _pending.remove(id);
      if (completer == null) return;
      final Map<String, Object?>? error = message.error;
      completer.complete(
        error != null
            ? <String, Object?>{'__error': error['message'] ?? error}
            : (message.result ?? const <String, Object?>{}),
      );
      return;
    }
    if (message.method != null) _events.add(message);
  }

  void _onDone() {
    if (_closed.isCompleted) return;
    for (final MapEntry<int, Completer<Map<String, Object?>>> entry
        in _pending.entries) {
      entry.value.complete(<String, Object?>{'__error': 'connection closed'});
    }
    _pending.clear();
    _closed.complete();
    unawaited(_events.close());
  }

  /// 主动关闭。
  Future<void> close() async {
    await _socket.close().timeout(
      const Duration(seconds: 2),
      onTimeout: () => null,
    );
    await _subscription.cancel();
    _onDone();
  }
}
