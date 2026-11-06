/// MCP 客户端的传输层：把一条 JSON-RPC 请求送到 server、拿回 id 匹配的那条应答。
///
/// - [McpHttpTransport]：Streamable HTTP。应答可能是 `application/json`，也可能是
///   `text/event-stream`（取 id 匹配的那条事件就收工，不等 server 关流）；非 2xx 但
///   body 是 JSON-RPC 应答时照常交回（MangaBaka 的协议错误就是 HTTP 400 + JSON-RPC
///   error，协商要看 `error.data`）。
/// - [McpStdioTransport]：本地程序，每行一条 JSON-RPC。
///
/// 不懂 MCP 语义（协商、`_meta` 信封、方法头）——那些在 `mcp_client_session.dart`。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

/// MCP 客户端的失败（短码 + 给人看的一句）。
class McpClientException implements Exception {
  const McpClientException(this.code, [this.message]);

  /// `connect_failed` / `http_status` / `session_expired` / `timeout` /
  /// `protocol` / `process_exited` / `unsupported_version` / `rpc_error`。
  final String code;
  final String? message;

  @override
  String toString() => message == null
      ? 'McpClientException($code)'
      : 'McpClientException($code: $message)';
}

/// 传输。请求里的 `id` 由调用方分配。
abstract interface class McpClientTransport {
  /// 发一条请求，返回 id 匹配的应答（含 `result` 或 `error` 的整条消息）。
  /// [headers] 只对 HTTP 有意义（MCP 的方法头），stdio 忽略。
  Future<Map<String, Object?>> request(
    Map<String, Object?> message, {
    Map<String, String> headers = const <String, String>{},
    required Duration timeout,
  });

  /// 发一条通知（不等应答）。
  Future<void> notify(
    Map<String, Object?> message, {
    Map<String, String> headers = const <String, String>{},
  });

  Future<void> close();
}

/// 会话 id 头（旧协议的有状态会话）。
const String kMcpClientSessionHeader = 'Mcp-Session-Id';

/// Streamable HTTP 传输。
class McpHttpTransport implements McpClientTransport {
  McpHttpTransport({
    required this.endpoint,
    required http.Client client,
    Map<String, String> headers = const <String, String>{},
  }) : _client = client,
       _headers = headers;

  final Uri endpoint;
  final http.Client _client;
  final Map<String, String> _headers;

  /// server 开的会话（旧协议）；之后每个请求回带。
  String? _sessionId;

  String? get sessionId => _sessionId;

  Map<String, String> _requestHeaders(Map<String, String> extra) =>
      <String, String>{
        ..._headers,
        ...extra,
        'Content-Type': 'application/json',
        'Accept': 'application/json, text/event-stream',
        if (_sessionId case final String id) kMcpClientSessionHeader: id,
      };

  @override
  Future<Map<String, Object?>> request(
    Map<String, Object?> message, {
    Map<String, String> headers = const <String, String>{},
    required Duration timeout,
  }) async {
    final Object? id = message['id'];
    final http.StreamedResponse response = await _post(
      message,
      headers,
      timeout,
    );
    final String? session =
        response.headers[kMcpClientSessionHeader.toLowerCase()];
    if (session != null && session.isNotEmpty) _sessionId = session;
    final String contentType = response.headers['content-type'] ?? '';
    try {
      if (contentType.contains('text/event-stream')) {
        return await _readSse(response.stream, id).timeout(timeout);
      }
      final String body = await utf8
          .decodeStream(response.stream)
          .timeout(timeout);
      final Map<String, Object?>? reply = _matchReply(_tryDecode(body), id);
      if (reply != null) return reply;
    } on TimeoutException {
      throw const McpClientException(
        'timeout',
        'The MCP server took too long to answer.',
      );
    }
    if (response.statusCode == HttpStatus.notFound && _sessionId != null) {
      _sessionId = null;
      throw const McpClientException(
        'session_expired',
        'The MCP session expired.',
      );
    }
    if (response.statusCode == HttpStatus.accepted) {
      throw const McpClientException(
        'protocol',
        'The MCP server sent no reply.',
      );
    }
    throw McpClientException('http_status', 'HTTP ${response.statusCode}');
  }

  @override
  Future<void> notify(
    Map<String, Object?> message, {
    Map<String, String> headers = const <String, String>{},
  }) async {
    final http.StreamedResponse response = await _post(
      message,
      headers,
      const Duration(seconds: 15),
    );
    // 通知没有应答：读完丢掉，连接才能复用。
    await response.stream.drain<void>();
  }

  Future<http.StreamedResponse> _post(
    Map<String, Object?> message,
    Map<String, String> headers,
    Duration timeout,
  ) async {
    final http.Request request = http.Request('POST', endpoint)
      ..headers.addAll(_requestHeaders(headers))
      ..body = jsonEncode(message);
    try {
      return await _client.send(request).timeout(timeout);
    } on TimeoutException {
      throw const McpClientException(
        'timeout',
        'The MCP server took too long to answer.',
      );
    } on http.ClientException catch (error) {
      throw McpClientException('connect_failed', error.message);
    } on SocketException catch (error) {
      throw McpClientException('connect_failed', error.message);
    } on HandshakeException catch (error) {
      throw McpClientException('connect_failed', error.message);
    }
  }

  /// 逐事件读 SSE，拿到 id 匹配的应答就停（取消订阅即关流）。
  static Future<Map<String, Object?>> _readSse(
    Stream<List<int>> bytes,
    Object? id,
  ) async {
    final StringBuffer data = StringBuffer();
    await for (final String line
        in bytes.transform(utf8.decoder).transform(const LineSplitter())) {
      if (line.isEmpty) {
        final Map<String, Object?>? reply = _matchReply(
          _tryDecode(data.toString()),
          id,
        );
        data.clear();
        if (reply != null) return reply;
        continue;
      }
      if (line.startsWith('data:')) {
        if (data.isNotEmpty) data.writeln();
        data.write(line.substring(5).trimLeft());
      }
    }
    final Map<String, Object?>? tail = _matchReply(
      _tryDecode(data.toString()),
      id,
    );
    if (tail != null) return tail;
    throw const McpClientException(
      'protocol',
      'The MCP server closed the stream without a reply.',
    );
  }

  @override
  Future<void> close() async {
    final String? session = _sessionId;
    _sessionId = null;
    if (session != null) {
      // 旧协议规定客户端结束时 DELETE 会话；失败无所谓（server 会自己过期）。
      try {
        final http.Request request = http.Request('DELETE', endpoint)
          ..headers.addAll(<String, String>{
            ..._headers,
            kMcpClientSessionHeader: session,
          });
        final http.StreamedResponse response = await _client
            .send(request)
            .timeout(const Duration(seconds: 3));
        await response.stream.drain<void>();
      } on Object {
        // 见上。
      }
    }
    _client.close();
  }
}

Object? _tryDecode(String text) {
  if (text.trim().isEmpty) return null;
  try {
    return jsonDecode(text);
  } on FormatException {
    return null;
  }
}

/// 在一条消息或一个批次里找 id 匹配的应答。
Map<String, Object?>? _matchReply(Object? decoded, Object? id) {
  if (decoded is List) {
    for (final Object? item in decoded) {
      final Map<String, Object?>? hit = _matchReply(item, id);
      if (hit != null) return hit;
    }
    return null;
  }
  if (decoded is! Map) return null;
  final bool isReply =
      decoded.containsKey('result') || decoded.containsKey('error');
  if (!isReply) return null;
  // 协议错误（例如无法解析请求）时 server 可能回 `id: null`，也算这次请求的应答。
  final Object? replyId = decoded['id'];
  if (replyId != null && '$replyId' != '$id') return null;
  return Map<String, Object?>.from(decoded);
}

/// stdio 传输需要的进程能力（测试注入假进程）。
abstract interface class McpStdioProcess {
  void writeLine(String line);
  Stream<String> get stdoutLines;
  Stream<String> get stderrLines;
  Future<int> get exitCode;
  void kill();
}

class _RealStdioProcess implements McpStdioProcess {
  _RealStdioProcess(this._process);

  final Process _process;

  @override
  void writeLine(String line) => _process.stdin.writeln(line);

  @override
  Stream<String> get stdoutLines =>
      _process.stdout.transform(utf8.decoder).transform(const LineSplitter());

  @override
  Stream<String> get stderrLines =>
      _process.stderr.transform(utf8.decoder).transform(const LineSplitter());

  @override
  Future<int> get exitCode => _process.exitCode;

  @override
  void kill() => _process.kill();
}

/// stderr 最多留多少字符（出错时给用户看）。
const int kMcpStdioStderrTailChars = 4096;

/// 本地程序传输。
class McpStdioTransport implements McpClientTransport {
  McpStdioTransport(this._process) {
    _stdout = _process.stdoutLines.listen(_onLine);
    _stderr = _process.stderrLines.listen(_onStderr);
    unawaited(_process.exitCode.then(_onExit));
  }

  /// 拉起 [command]。Windows 上走 shell：`npx` / `uvx` 这类入口是 `.cmd`。
  static Future<McpStdioTransport> start({
    required String command,
    List<String> args = const <String>[],
    Map<String, String> env = const <String, String>{},
  }) async {
    try {
      final Process process = await Process.start(
        command,
        args,
        environment: env.isEmpty ? null : env,
        runInShell: Platform.isWindows,
      );
      return McpStdioTransport(_RealStdioProcess(process));
    } on ProcessException catch (error) {
      throw McpClientException('connect_failed', error.message);
    }
  }

  final McpStdioProcess _process;
  late final StreamSubscription<String> _stdout;
  late final StreamSubscription<String> _stderr;
  final Map<String, Completer<Map<String, Object?>>> _pending =
      <String, Completer<Map<String, Object?>>>{};
  final StringBuffer _stderrTail = StringBuffer();
  bool _exited = false;

  /// stderr 的最后一段（诊断用）。
  String get stderrTail => _stderrTail.toString();

  void _onLine(String line) {
    final Object? decoded = _tryDecode(line);
    if (decoded is! Map) return;
    final Object? id = decoded['id'];
    final Object? method = decoded['method'];
    if (method is String) {
      // server 发来的请求：只会答 ping，其余回 method-not-found。通知忽略。
      if (id == null) return;
      _process.writeLine(
        jsonEncode(
          method == 'ping'
              ? <String, Object?>{
                  'jsonrpc': '2.0',
                  'id': id,
                  'result': <String, Object?>{},
                }
              : <String, Object?>{
                  'jsonrpc': '2.0',
                  'id': id,
                  'error': <String, Object?>{
                    'code': -32601,
                    'message': 'Method not supported by Fushi: $method',
                  },
                },
        ),
      );
      return;
    }
    final Completer<Map<String, Object?>>? waiter = _pending.remove('$id');
    if (waiter != null && !waiter.isCompleted) {
      waiter.complete(Map<String, Object?>.from(decoded));
    }
  }

  void _onStderr(String line) {
    _stderrTail.writeln(line);
    if (_stderrTail.length > kMcpStdioStderrTailChars) {
      final String text = _stderrTail.toString();
      _stderrTail
        ..clear()
        ..write(text.substring(text.length - kMcpStdioStderrTailChars));
    }
  }

  void _onExit(int code) {
    _exited = true;
    final String tail = stderrTail.trim();
    final McpClientException error = McpClientException(
      'process_exited',
      tail.isEmpty
          ? 'The MCP program exited (code $code).'
          : 'Exited (code $code): $tail',
    );
    for (final Completer<Map<String, Object?>> waiter in _pending.values) {
      if (!waiter.isCompleted) waiter.completeError(error);
    }
    _pending.clear();
  }

  @override
  Future<Map<String, Object?>> request(
    Map<String, Object?> message, {
    Map<String, String> headers = const <String, String>{},
    required Duration timeout,
  }) async {
    if (_exited) {
      throw const McpClientException(
        'process_exited',
        'The MCP program is not running.',
      );
    }
    final String key = '${message['id']}';
    final Completer<Map<String, Object?>> waiter =
        Completer<Map<String, Object?>>();
    _pending[key] = waiter;
    _process.writeLine(jsonEncode(message));
    try {
      return await waiter.future.timeout(timeout);
    } on TimeoutException {
      _pending.remove(key);
      throw const McpClientException(
        'timeout',
        'The MCP program took too long to answer.',
      );
    }
  }

  @override
  Future<void> notify(
    Map<String, Object?> message, {
    Map<String, String> headers = const <String, String>{},
  }) async {
    if (!_exited) _process.writeLine(jsonEncode(message));
  }

  @override
  Future<void> close() async {
    await _stdout.cancel();
    await _stderr.cancel();
    if (!_exited) _process.kill();
  }
}
