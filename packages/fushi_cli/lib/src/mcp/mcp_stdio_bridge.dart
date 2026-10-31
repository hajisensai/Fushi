/// `fushi_cli mcp`：MCP 的 stdio 传输 ↔ app 控制通道 `/mcp`（Streamable HTTP）。
///
/// Claude Desktop 一类客户端只会拉起本地进程走 stdio；app 的控制通道端口每次
/// 启动都随机。这个桥每条消息都重新读发现文件找端口（app 重启后自动接上），把
/// stdin 上的每行 JSON-RPC 原样 POST 给 `/mcp`，应答写回 stdout。鉴权用配对令牌
/// （`FUSHI_MCP_TOKEN`），**不**用发现文件里的控制通道 token。
///
/// stdout 只写 JSON-RPC（每条一行）；诊断一律写 [log]（stderr）。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../ctl_endpoint.dart';
import 'mcp_http.dart';
import 'mcp_server.dart';

/// 配对令牌的环境变量（MCP 客户端配置里的 `env`）。
const String kMcpTokenEnv = 'FUSHI_MCP_TOKEN';

/// 桥自己产生的错误码（JSON-RPC 规定 -32000..-32099 留给实现）。
const int kMcpBridgeAppUnavailable = -32001;
const int kMcpBridgeRejected = -32002;

class McpStdioBridge {
  McpStdioBridge({
    required this.token,
    required this.endpoint,
    required this.output,
    required this.log,
    HttpClient? httpClient,
  }) : _http =
           httpClient ??
           (HttpClient()
             ..connectionTimeout = const Duration(seconds: 3)
             // 只连 127.0.0.1：永远直连，别把令牌送进用户的全局代理。
             ..findProxy = (Uri _) => 'DIRECT'),
       _ownsHttp = httpClient == null;

  /// 配对令牌。
  final String token;

  /// 找到正在运行的 app（读发现文件；需要时拉起 app）。没有返回 null。
  final Future<CtlEndpoint?> Function() endpoint;

  final StringSink output;
  final StringSink log;

  final HttpClient _http;
  final bool _ownsHttp;

  String? _sessionId;
  final Set<Future<void>> _inFlight = <Future<void>>{};

  /// 读 [input] 直到 EOF（客户端关掉管道）；等在途请求都应答完再返回 0。
  ///
  /// 每行独立转发、并发处理：等用户在 app 里确认的工具调用不会挡住 `ping` 等其它
  /// 消息。客户端要等 `initialize` 应答后才发后续消息，会话 id 因此总在之前到手。
  Future<int> run(Stream<List<int>> input) async {
    await for (final String line
        in input.transform(utf8.decoder).transform(const LineSplitter())) {
      if (line.trim().isEmpty) continue;
      late final Future<void> task;
      task = _forward(line).whenComplete(() => _inFlight.remove(task));
      _inFlight.add(task);
    }
    await Future.wait(_inFlight.toList());
    if (_ownsHttp) _http.close(force: true);
    return 0;
  }

  Future<void> _forward(String line) async {
    final Object? message;
    try {
      message = jsonDecode(line);
    } on FormatException {
      _write(mcpParseErrorReply());
      return;
    }
    final List<Object?> requestIds = _requestIds(message);
    final CtlEndpoint? target;
    try {
      target = await endpoint();
    } on Object catch (error) {
      _failAll(requestIds, kMcpBridgeAppUnavailable, '$error');
      return;
    }
    if (target == null) {
      _failAll(
        requestIds,
        kMcpBridgeAppUnavailable,
        'Fushi is not running. Start the Fushi desktop app and turn on '
        'Settings › Models › LLM › AI assistant › External AI access (MCP).',
      );
      return;
    }
    final Uri uri = target.baseUri.replace(path: kMcpHttpPath);
    final HttpClientResponse response;
    final String text;
    try {
      final HttpClientRequest request = await _http.postUrl(uri);
      request.headers
        ..set(HttpHeaders.authorizationHeader, 'Bearer $token')
        ..set(HttpHeaders.acceptHeader, 'application/json, text/event-stream')
        ..contentType = ContentType.json;
      final String? session = _sessionId;
      if (session != null) request.headers.set(kMcpSessionHeader, session);
      request.add(utf8.encode(line));
      response = await request.close();
      text = await utf8.decodeStream(response);
    } on IOException catch (error) {
      _failAll(
        requestIds,
        kMcpBridgeAppUnavailable,
        'Lost connection to Fushi: $error',
      );
      return;
    }
    final String? opened = response.headers.value(kMcpSessionHeader);
    if (opened != null && opened.isNotEmpty) _sessionId = opened;
    if (response.statusCode == HttpStatus.accepted) return;
    final Object? decoded;
    try {
      decoded = text.isEmpty ? null : jsonDecode(text);
    } on FormatException {
      _failAll(
        requestIds,
        kMcpBridgeRejected,
        'Unexpected reply from Fushi (HTTP ${response.statusCode}).',
      );
      return;
    }
    if (response.statusCode == HttpStatus.ok && decoded != null) {
      _write(decoded);
      return;
    }
    // 鉴权 / 开关这类 HTTP 层拒绝：每个请求回一条 JSON-RPC 错误，原因照搬给客户端。
    final String reason = decoded is Map && decoded['message'] is String
        ? decoded['message']! as String
        : 'HTTP ${response.statusCode}';
    if (requestIds.isEmpty) {
      log.writeln('[fushi_cli mcp] notification rejected: $reason');
      return;
    }
    _failAll(requestIds, kMcpBridgeRejected, reason);
  }

  static List<Object?> _requestIds(Object? message) {
    Iterable<Object?> all(Object? m) sync* {
      if (m is List) {
        for (final Object? e in m) {
          yield* all(e);
        }
      } else if (m is Map && m['method'] is String && m['id'] != null) {
        yield m['id'];
      }
    }

    return all(message).toList(growable: false);
  }

  void _failAll(List<Object?> ids, int code, String message) {
    if (ids.isEmpty) {
      log.writeln('[fushi_cli mcp] $message');
      return;
    }
    for (final Object? id in ids) {
      _write(<String, Object?>{
        'jsonrpc': '2.0',
        'id': id,
        'error': <String, Object?>{'code': code, 'message': message},
      });
    }
  }

  void _write(Object? message) => output.writeln(jsonEncode(message));
}
