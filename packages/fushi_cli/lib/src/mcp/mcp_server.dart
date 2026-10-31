/// 把操作目录对外暴露成 MCP server（Model Context Protocol）的协议层。
///
/// 只做 JSON-RPC 2.0 与 MCP 的 `initialize` / `ping` / `tools/list` /
/// `tools/call`，不懂任何 app 语义：工具清单与执行都交给 [McpToolHost]（app 侧把
/// 操作目录适配成它，见 `fushi/lib/src/ai/mcp/`）。传输由 [McpHttpEndpoint]（挂在
/// 本机控制通道 `/mcp` 上）与 `fushi_cli mcp`（stdio ↔ HTTP 桥）提供。
///
/// 工具清单**不另写**：每个工具都由目录里一条 [FushiOp] 的描述生成（[mcpToolOf]），
/// 参数 schema 就是给模型看的那份（用户表态参数已删掉）。
library;

import 'dart:convert';
import 'dart:math';

import '../ops/fushi_op.dart';

/// 本实现能说的协议版本，新的在前。客户端要的版本不在其中时回最新的。
const List<String> kMcpSupportedProtocolVersions = <String>[
  '2025-06-18',
  '2025-03-26',
  '2024-11-05',
];

/// JSON-RPC 2.0 错误码。
const int kJsonRpcParseError = -32700;
const int kJsonRpcInvalidRequest = -32600;
const int kJsonRpcMethodNotFound = -32601;
const int kJsonRpcInvalidParams = -32602;
const int kJsonRpcInternalError = -32603;

/// MCP 客户端在 `initialize` 里报的身份（不可信，只作展示与记账分组）。
class McpClientInfo {
  const McpClientInfo({required this.name, this.version});

  static const McpClientInfo unknown = McpClientInfo(name: 'MCP client');

  final String name;
  final String? version;

  /// 给人看的一行（确认弹窗里显示）。
  String get label =>
      version == null || version!.isEmpty ? name : '$name $version';
}

/// 一次工具调用的来源。
class McpCallContext {
  const McpCallContext({required this.sessionId, required this.client});

  /// MCP 会话 id（`Mcp-Session-Id`）；客户端没带或会话已过期时是 `anonymous`。
  final String sessionId;
  final McpClientInfo client;
}

/// MCP 的一个工具。
class McpTool {
  const McpTool({
    required this.name,
    required this.description,
    required this.inputSchema,
    this.title,
    this.readOnly = false,
    this.destructive = false,
  });

  final String name;
  final String? title;
  final String description;
  final Map<String, Object?> inputSchema;

  /// `annotations.readOnlyHint`。
  final bool readOnly;

  /// `annotations.destructiveHint`（撤销不了）。
  final bool destructive;

  Map<String, Object?> toJson() => <String, Object?>{
    'name': name,
    if (title != null) 'title': title,
    'description': description,
    'inputSchema': inputSchema,
    'annotations': <String, Object?>{
      if (title != null) 'title': title,
      'readOnlyHint': readOnly,
      if (!readOnly) 'destructiveHint': destructive,
    },
  };
}

/// 一次工具调用的结果。
class McpToolResult {
  /// 成功：[data] 以 JSON 文本放进 `content`，同时作为 `structuredContent`。
  const McpToolResult.ok(this.data) : errorCode = null, errorMessage = null;

  /// 工具执行失败（参数不对、对象不存在、用户拒绝……）：`isError: true`，让模型
  /// 看到原因自己换参数或停下。协议级错误（不认识的工具）不走这里，见
  /// [McpUnknownTool]。
  const McpToolResult.error(String this.errorCode, [this.errorMessage])
    : data = null;

  final Object? data;
  final String? errorCode;
  final String? errorMessage;

  bool get isError => errorCode != null;

  Map<String, Object?> toJson() {
    if (isError) {
      final Map<String, Object?> error = <String, Object?>{
        'error': errorCode,
        if (errorMessage != null) 'message': errorMessage,
      };
      return <String, Object?>{
        'content': <Object?>[
          <String, Object?>{'type': 'text', 'text': jsonEncode(error)},
        ],
        'isError': true,
      };
    }
    final Object? structured = data ?? const <String, Object?>{'ok': true};
    return <String, Object?>{
      'content': <Object?>[
        <String, Object?>{'type': 'text', 'text': jsonEncode(structured)},
      ],
      // structuredContent 规定是对象；列表等包一层。
      'structuredContent': structured is Map
          ? structured
          : <String, Object?>{'result': structured},
      'isError': false,
    };
  }
}

/// [McpToolHost.callTool] 不认识这个工具名：回 JSON-RPC `-32602`。
class McpUnknownTool implements Exception {
  const McpUnknownTool(this.name);

  final String name;

  @override
  String toString() => 'McpUnknownTool($name)';
}

/// 工具清单与执行（app 侧实现）。
abstract interface class McpToolHost {
  /// 当前对外的工具（每次 `tools/list` 现算：可用性随模块开关、初始化状态变）。
  List<McpTool> listTools();

  /// 执行。执行失败以 [McpToolResult.error] 返回；不认识的工具抛 [McpUnknownTool]。
  Future<McpToolResult> callTool(
    String name,
    Map<String, Object?> arguments,
    McpCallContext context,
  );
}

/// 一次处理的应答：[body] 为 null 表示没有要回的（全是通知）。
class McpReply {
  const McpReply(this.body, {this.sessionId});

  final Object? body;

  /// `initialize` 新开的会话 id（HTTP 层放进 `Mcp-Session-Id` 应答头）。
  final String? sessionId;
}

class _McpSession {
  _McpSession(this.client, this.protocolVersion);

  final McpClientInfo client;
  final String protocolVersion;
}

/// MCP 协议处理（与传输无关）。
class McpServer {
  McpServer({
    required this.host,
    required this.serverName,
    required this.serverVersion,
    this.instructions,
    Random? random,
  }) : _random = random ?? Random.secure();

  final McpToolHost host;
  final String serverName;
  final String Function() serverVersion;

  /// `initialize` 结果里的 `instructions`（给模型看的使用说明）。
  final String? instructions;

  final Random _random;

  /// 会话只用来记住客户端身份（确认弹窗里显示是谁在要求、操作记录按会话分组）。
  /// 不认识的会话 id（app 重启过）不报 404：按匿名客户端照常处理，客户端不用
  /// 重新握手；鉴权在 HTTP 层每次都做，不依赖会话。
  final Map<String, _McpSession> _sessions = <String, _McpSession>{};

  static const int _maxSessions = 64;

  /// 结束一个会话（HTTP `DELETE /mcp`）。
  void endSession(String sessionId) => _sessions.remove(sessionId);

  /// 处理一条已解码的 JSON-RPC 消息（或 2025-03-26 及更早版本允许的批量数组）。
  Future<McpReply> handle(Object? payload, {String? sessionId}) async {
    if (payload is List) {
      if (payload.isEmpty) {
        return McpReply(_error(null, kJsonRpcInvalidRequest, 'Empty batch'));
      }
      final List<Object?> replies = <Object?>[];
      String? opened;
      for (final Object? message in payload) {
        final _Handled handled = await _handleOne(message, sessionId);
        opened ??= handled.openedSession;
        if (handled.body != null) replies.add(handled.body);
      }
      return McpReply(replies.isEmpty ? null : replies, sessionId: opened);
    }
    final _Handled handled = await _handleOne(payload, sessionId);
    return McpReply(handled.body, sessionId: handled.openedSession);
  }

  Future<_Handled> _handleOne(Object? message, String? sessionId) async {
    if (message is! Map) {
      return _Handled(_error(null, kJsonRpcInvalidRequest, 'Invalid request'));
    }
    final Object? id = message['id'];
    final bool isRequest = message.containsKey('id') && id != null;
    final Object? method = message['method'];
    if (method is! String) {
      // 客户端发来的应答（我们从不发请求）或坏消息：应答忽略，坏请求回错。
      if (message.containsKey('result') || message.containsKey('error')) {
        return const _Handled(null);
      }
      return _Handled(_error(id, kJsonRpcInvalidRequest, 'Missing method'));
    }
    if (!isRequest) {
      // 通知（notifications/initialized、notifications/cancelled…）：不回。
      return const _Handled(null);
    }
    final Object? rawParams = message['params'];
    final Map<String, Object?> params = rawParams is Map
        ? Map<String, Object?>.from(rawParams)
        : const <String, Object?>{};
    try {
      switch (method) {
        case 'initialize':
          return _initialize(id, params);
        case 'ping':
          return _Handled(_result(id, const <String, Object?>{}));
        case 'tools/list':
          return _Handled(
            _result(id, <String, Object?>{
              'tools': <Object?>[
                for (final McpTool tool in host.listTools()) tool.toJson(),
              ],
            }),
          );
        case 'tools/call':
          return _Handled(await _callTool(id, params, sessionId));
        default:
          return _Handled(
            _error(id, kJsonRpcMethodNotFound, 'Method not found: $method'),
          );
      }
    } on Object catch (error) {
      return _Handled(_error(id, kJsonRpcInternalError, '$error'));
    }
  }

  _Handled _initialize(Object? id, Map<String, Object?> params) {
    final Object? requested = params['protocolVersion'];
    final String version =
        requested is String && kMcpSupportedProtocolVersions.contains(requested)
        ? requested
        : kMcpSupportedProtocolVersions.first;
    final Object? info = params['clientInfo'];
    final McpClientInfo client = info is Map && info['name'] is String
        ? McpClientInfo(
            name: _clip(info['name']! as String, 80),
            version: info['version'] is String
                ? _clip(info['version']! as String, 40)
                : null,
          )
        : McpClientInfo.unknown;
    final String sessionId = _newSessionId();
    if (_sessions.length >= _maxSessions) {
      _sessions.remove(_sessions.keys.first);
    }
    _sessions[sessionId] = _McpSession(client, version);
    return _Handled(
      _result(id, <String, Object?>{
        'protocolVersion': version,
        'capabilities': const <String, Object?>{
          'tools': <String, Object?>{'listChanged': false},
        },
        'serverInfo': <String, Object?>{
          'name': serverName,
          'version': serverVersion(),
        },
        if (instructions != null) 'instructions': instructions,
      }),
      openedSession: sessionId,
    );
  }

  Future<Map<String, Object?>> _callTool(
    Object? id,
    Map<String, Object?> params,
    String? sessionId,
  ) async {
    final Object? name = params['name'];
    if (name is! String || name.isEmpty) {
      return _error(id, kJsonRpcInvalidParams, 'Missing tool name');
    }
    final Object? rawArgs = params['arguments'];
    if (rawArgs != null && rawArgs is! Map) {
      return _error(id, kJsonRpcInvalidParams, 'arguments must be an object');
    }
    final _McpSession? session = sessionId == null
        ? null
        : _sessions[sessionId];
    final McpCallContext context = McpCallContext(
      sessionId: session == null ? 'anonymous' : sessionId!,
      client: session?.client ?? McpClientInfo.unknown,
    );
    try {
      final McpToolResult result = await host.callTool(
        name,
        rawArgs == null
            ? const <String, Object?>{}
            : Map<String, Object?>.from(rawArgs as Map),
        context,
      );
      return _result(id, result.toJson());
    } on McpUnknownTool catch (unknown) {
      return _error(id, kJsonRpcInvalidParams, 'Unknown tool: ${unknown.name}');
    }
  }

  String _newSessionId() {
    final StringBuffer buffer = StringBuffer();
    for (int i = 0; i < 16; i++) {
      buffer.write(_random.nextInt(256).toRadixString(16).padLeft(2, '0'));
    }
    return buffer.toString();
  }

  static String _clip(String value, int max) =>
      value.length <= max ? value : value.substring(0, max);

  static Map<String, Object?> _result(Object? id, Object? result) =>
      <String, Object?>{'jsonrpc': '2.0', 'id': id, 'result': result};

  static Map<String, Object?> _error(Object? id, int code, String message) =>
      <String, Object?>{
        'jsonrpc': '2.0',
        'id': id,
        'error': <String, Object?>{'code': code, 'message': message},
      };
}

class _Handled {
  const _Handled(this.body, {this.openedSession});

  final Map<String, Object?>? body;
  final String? openedSession;
}

/// JSON-RPC 解析失败的应答（HTTP 层 / stdio 桥用）。
Map<String, Object?> mcpParseErrorReply([
  String message = 'Parse error',
]) => <String, Object?>{
  'jsonrpc': '2.0',
  'id': null,
  'error': <String, Object?>{'code': kJsonRpcParseError, 'message': message},
};

// ---------------------------------------------------------------------------
// 操作目录 → MCP 工具
// ---------------------------------------------------------------------------

/// 目录 id → MCP 工具名。点换成 `__`：各家模型 API 的工具名只认
/// `^[a-zA-Z0-9_-]{1,64}$`（与 app 内 AI 的线上名同一规则）。目录 id 由棘轮守卫
/// 钉成「点分小写、不含 `__`」，所以这个映射可逆。
String mcpToolNameOf(String opId) => opId.replaceAll('.', '__');

/// MCP 工具名 → 目录 id。
String mcpOpIdOf(String toolName) => toolName.replaceAll('__', '.');

/// 这条操作对外不对外：只在进程内有意义的（导航、候选卡片）与结果含一次性凭据的
/// （配对票据等，只该给用户本人看）不对外。可用性另由调用方现算。
bool mcpExposesOp(FushiOpSpec spec) =>
    !spec.inProcessOnly && !spec.sensitiveResult;

/// 由一条操作的描述生成 MCP 工具：说明 = 目录里的英文说明 + 执行方式；参数 schema
/// = 给模型看的那份（**不含**用户表态参数，外部调用方填不出「已确认」）。
McpTool mcpToolOf(FushiOpSpec spec) => McpTool(
  name: mcpToolNameOf(spec.id),
  title: spec.id,
  description: '${spec.summary.trim()}\n\n${mcpExecutionNote(spec)}',
  inputSchema: spec.modelSchema(),
  readOnly: spec.risk == OpRisk.read,
  destructive: spec.risk == OpRisk.irreversible,
);

/// 工具说明尾部的执行方式（风险级沿用描述，模型据此知道会不会被拦下来等用户）。
String mcpExecutionNote(FushiOpSpec spec) {
  final String base = switch (spec.risk) {
    OpRisk.read => 'Read-only.',
    OpRisk.write when spec.confirm =>
      'Changes data. The user must approve it in the Fushi app before it '
          'runs (the call waits for their answer); afterwards it can be undone '
          'from the AI action log or with undo_action.',
    OpRisk.write =>
      'Changes data. Runs immediately and is recorded in the Fushi AI action '
          'log; it can be undone there or with undo_action.',
    OpRisk.irreversible =>
      'Cannot be undone. The user must approve it in the Fushi app before it '
          'runs (the call waits for their answer).',
  };
  return spec.longRunning
      ? '$base Starts a background job and returns its id; poll the '
            'matching status tool (e.g. task__get) for progress.'
      : base;
}
