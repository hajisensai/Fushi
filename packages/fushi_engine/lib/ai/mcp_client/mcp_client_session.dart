/// MCP 客户端会话：协商协议版本、列工具、调工具（spec
/// `docs/specs/2026-11-05-ai-mcp-client-design.md` §7）。
///
/// 要同时会说两代协议：
///
/// - **旧握手**（2024-11-05 / 2025-03-26 / 2025-06-18）：先 `initialize`，再
///   `notifications/initialized`；HTTP 回带 `Mcp-Session-Id`，每个请求带
///   `MCP-Protocol-Version`。
/// - **无状态**（2026-07-28）：没有 `initialize`；每个请求的 `params._meta` 带
///   `io.modelcontextprotocol/protocolVersion`、`.../clientCapabilities`（、`.../clientInfo`），
///   HTTP 另带 `MCP-Protocol-Version`、`Mcp-Method`，`tools/call` 带 `Mcp-Name`。
///   MangaBaka 只认这一代（2026-11-06 实测：`initialize` 一律回 `-32022`，
///   `error.data.supported = ["2026-07-28"]`）。
///
/// 协商：先发旧握手；server 回错且 `error.data.supported` 含无状态版本（或
/// `initialize` 是 method-not-found）就切无状态。
library;

import 'dart:convert';

import 'package:fushi_engine/ai/mcp_client/mcp_client_transport.dart';

/// 旧握手时请求的版本（server 可以回它支持的别的版本，我们接受）。
const String kMcpClientLegacyProtocolVersion = '2025-06-18';

/// 无状态修订版本。
const String kMcpClientStatelessProtocolVersion = '2026-07-28';

/// 普通请求时限。
const Duration kMcpClientRequestTimeout = Duration(seconds: 30);

/// `tools/call` 时限（工具可能真在干活）。
const Duration kMcpClientCallTimeout = Duration(seconds: 60);

/// `tools/list` 翻页上限（防 server 无限翻页）。
const int kMcpClientMaxToolPages = 20;

const String _kMetaProtocolVersion = 'io.modelcontextprotocol/protocolVersion';
const String _kMetaClientCapabilities =
    'io.modelcontextprotocol/clientCapabilities';
const String _kMetaClientInfo = 'io.modelcontextprotocol/clientInfo';

/// server 上的一个工具（只留给模型看的部分：不收 `outputSchema`）。
class McpRemoteTool {
  const McpRemoteTool({
    required this.name,
    required this.description,
    required this.inputSchema,
    this.title,
    this.readOnly = false,
    this.destructive = true,
  });

  final String name;
  final String? title;
  final String description;
  final Map<String, Object?> inputSchema;

  /// `annotations.readOnlyHint`（缺省 false）。
  final bool readOnly;

  /// `annotations.destructiveHint`（MCP 规定缺省 true）。
  final bool destructive;

  static McpRemoteTool? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final Object? name = raw['name'];
    if (name is! String || name.trim().isEmpty) return null;
    final Object? annotations = raw['annotations'];
    final Map<Object?, Object?> hints = annotations is Map
        ? annotations
        : const <Object?, Object?>{};
    final Object? schema = raw['inputSchema'];
    return McpRemoteTool(
      name: name,
      title: raw['title'] as String? ?? hints['title'] as String?,
      description: '${raw['description'] ?? ''}',
      inputSchema: schema is Map
          ? Map<String, Object?>.from(schema)
          : const <String, Object?>{'type': 'object'},
      readOnly: hints['readOnlyHint'] == true,
      destructive: hints['destructiveHint'] != false,
    );
  }
}

/// 一次 `tools/call` 的结果。
class McpCallOutcome {
  const McpCallOutcome({required this.text, this.isError = false});

  /// 交给模型的文本（`content` 里的文本拼起来；没有文本时是 `structuredContent` 的 JSON）。
  final String text;

  /// 工具自己报错（`isError: true`）：模型看到原因可以换参数。
  final bool isError;
}

/// 协商出来的模式。
enum McpProtocolMode { legacy, stateless }

/// 一条到 MCP server 的会话。
class McpClientSession {
  McpClientSession(
    this._transport, {
    required this.clientName,
    required this.clientVersion,
  });

  final McpClientTransport _transport;
  final String clientName;
  final String clientVersion;

  int _nextId = 1;
  McpProtocolMode? _mode;
  String? _protocolVersion;
  String? _serverName;

  McpProtocolMode? get mode => _mode;
  String? get protocolVersion => _protocolVersion;

  /// server 自报的名字（不可信，只作展示）。
  String? get serverName => _serverName;

  bool get isOpen => _mode != null;

  Map<String, Object?> get _clientInfo => <String, Object?>{
    'name': clientName,
    'version': clientVersion,
  };

  /// 协商。失败抛 [McpClientException]。
  Future<void> open() async {
    final Map<String, Object?> reply = await _transport.request(
      _message('initialize', <String, Object?>{
        'protocolVersion': kMcpClientLegacyProtocolVersion,
        'capabilities': <String, Object?>{},
        'clientInfo': _clientInfo,
      }),
      timeout: kMcpClientRequestTimeout,
    );
    final Object? error = reply['error'];
    if (error == null) {
      final Map<Object?, Object?> result = _asMap(reply['result']);
      _mode = McpProtocolMode.legacy;
      _protocolVersion =
          result['protocolVersion'] as String? ??
          kMcpClientLegacyProtocolVersion;
      _serverName = _asMap(result['serverInfo'])['name'] as String?;
      await _transport.notify(<String, Object?>{
        'jsonrpc': '2.0',
        'method': 'notifications/initialized',
      }, headers: _legacyHeaders);
      return;
    }
    final Map<Object?, Object?> err = _asMap(error);
    final Object? supported = _asMap(err['data'])['supported'];
    final bool statelessOffered =
        supported is List &&
        supported.contains(kMcpClientStatelessProtocolVersion);
    if (statelessOffered || err['code'] == -32601) {
      _mode = McpProtocolMode.stateless;
      _protocolVersion = kMcpClientStatelessProtocolVersion;
      return;
    }
    throw McpClientException(
      'unsupported_version',
      supported is List
          ? 'The server only supports MCP ${supported.join(', ')}.'
          : '${err['message'] ?? 'initialize failed'}',
    );
  }

  Map<String, String> get _legacyHeaders => <String, String>{
    if (_protocolVersion case final String v) 'MCP-Protocol-Version': v,
  };

  /// 列出全部工具（跟着 `nextCursor` 翻页）。
  Future<List<McpRemoteTool>> listTools() async {
    final List<McpRemoteTool> tools = <McpRemoteTool>[];
    String? cursor;
    for (int page = 0; page < kMcpClientMaxToolPages; page++) {
      final Map<Object?, Object?> result = await _call(
        'tools/list',
        <String, Object?>{if (cursor != null) 'cursor': cursor},
        timeout: kMcpClientRequestTimeout,
      );
      final Object? list = result['tools'];
      if (list is List) {
        for (final Object? raw in list) {
          final McpRemoteTool? tool = McpRemoteTool.fromJson(raw);
          if (tool != null) tools.add(tool);
        }
      }
      final Object? next = result['nextCursor'];
      if (next is! String || next.isEmpty) break;
      cursor = next;
    }
    _serverName ??= _lastServerName;
    return tools;
  }

  /// [_call] 在无状态应答 `_meta` 里见到的 server 名（无状态模式没有 `initialize`
  /// 结果可读）。
  String? _lastServerName;

  /// 调一个工具。协议级失败抛 [McpClientException]；工具自己报错以
  /// [McpCallOutcome.isError] 返回。
  Future<McpCallOutcome> callTool(
    String name,
    Map<String, Object?> arguments,
  ) async {
    final Map<Object?, Object?> result = await _call(
      'tools/call',
      <String, Object?>{'name': name, 'arguments': arguments},
      timeout: kMcpClientCallTimeout,
      extraHeaders: <String, String>{'Mcp-Name': name},
    );
    return McpCallOutcome(
      text: mcpCallResultText(result),
      isError: result['isError'] == true,
    );
  }

  Future<Map<Object?, Object?>> _call(
    String method,
    Map<String, Object?> params, {
    required Duration timeout,
    Map<String, String> extraHeaders = const <String, String>{},
  }) async {
    final McpProtocolMode? mode = _mode;
    if (mode == null) {
      throw const McpClientException('protocol', 'MCP session is not open.');
    }
    final Map<String, String> headers;
    final Map<String, Object?> body;
    switch (mode) {
      case McpProtocolMode.legacy:
        headers = _legacyHeaders;
        body = params;
      case McpProtocolMode.stateless:
        headers = <String, String>{
          'MCP-Protocol-Version': kMcpClientStatelessProtocolVersion,
          'Mcp-Method': method,
          ...extraHeaders,
        };
        body = <String, Object?>{
          ...params,
          '_meta': <String, Object?>{
            _kMetaProtocolVersion: kMcpClientStatelessProtocolVersion,
            _kMetaClientCapabilities: <String, Object?>{},
            _kMetaClientInfo: _clientInfo,
          },
        };
    }
    final Map<String, Object?> reply = await _transport.request(
      _message(method, body),
      headers: headers,
      timeout: timeout,
    );
    final Object? error = reply['error'];
    if (error != null) {
      final Map<Object?, Object?> err = _asMap(error);
      throw McpClientException(
        'rpc_error',
        '${err['message'] ?? 'MCP error ${err['code']}'}',
      );
    }
    final Map<Object?, Object?> result = _asMap(reply['result']);
    final Object? serverInfo = _asMap(
      result['_meta'],
    )['io.modelcontextprotocol/serverInfo'];
    if (serverInfo is Map && serverInfo['name'] is String) {
      _lastServerName = serverInfo['name'] as String;
    }
    return result;
  }

  Map<String, Object?> _message(String method, Map<String, Object?> params) =>
      <String, Object?>{
        'jsonrpc': '2.0',
        'id': _nextId++,
        'method': method,
        'params': params,
      };

  Future<void> close() => _transport.close();
}

Map<Object?, Object?> _asMap(Object? value) =>
    value is Map ? value : const <Object?, Object?>{};

/// `tools/call` 结果 → 给模型的文本：`content` 里的文本按序拼接；图片 / 音频等
/// 非文本块写一个占位；一块文本都没有时用 `structuredContent` 的 JSON。
String mcpCallResultText(Map<Object?, Object?> result) {
  final List<String> parts = <String>[];
  final Object? content = result['content'];
  if (content is List) {
    for (final Object? block in content) {
      if (block is! Map) continue;
      final Object? type = block['type'];
      if (type == 'text' && block['text'] is String) {
        parts.add(block['text'] as String);
      } else if (type == 'resource' && block['resource'] is Map) {
        final Object? text = (block['resource'] as Map)['text'];
        if (text is String) parts.add(text);
      } else if (type is String) {
        parts.add('[$type content omitted]');
      }
    }
  }
  if (parts.isEmpty && result['structuredContent'] != null) {
    return _jsonText(result['structuredContent']);
  }
  return parts.join('\n');
}

String _jsonText(Object? value) {
  try {
    return jsonEncode(value);
  } on JsonUnsupportedObjectError {
    return '$value';
  }
}
