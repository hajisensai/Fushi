/// MCP 的 Streamable HTTP 传输：挂在本机控制通道（[CtlServer]）的 `/mcp` 上。
///
/// 只复用控制通道的监听（127.0.0.1、随机端口、发现文件），**不复用它的 token**：
/// 控制通道 token 等于用户本人（`fushi_cli` 能敲表态 flag），MCP 是外部 AI，
/// 用用户在设置里亲手生成的配对令牌鉴权，身份按模型处理（表态参数一律拒收）。
///
/// 只实现规范里的 JSON 应答模式：`POST` 一条 JSON-RPC 消息 → `application/json`
/// 应答（通知 → 202 无正文）；不开 SSE 流（`GET` 回 405）；`DELETE` 结束会话。
library;

import 'dart:convert';

import 'package:shelf/shelf.dart' as shelf;

import 'mcp_server.dart';

/// 控制通道上的挂载路径。
const String kMcpHttpPath = '/mcp';

/// MCP 会话头（规范规定的名字，HTTP 头大小写不敏感）。
const String kMcpSessionHeader = 'mcp-session-id';

/// 外部 AI 访问的鉴权结论（app 侧按设置与配对令牌现算）。
enum McpAccess {
  /// 放行。
  allowed,

  /// 设置里没打开「外部 AI 访问」（默认关）。
  disabled,

  /// 打开了，但还没生成配对令牌。
  notPaired,

  /// 没带令牌或令牌不对。
  unauthorized,
}

/// `/mcp` 的 HTTP 处理器。
class McpHttpEndpoint {
  McpHttpEndpoint({required this.server, required this.authorize});

  final McpServer server;

  /// 按请求带的 Bearer 令牌（没带为 null）判定能不能进。每个请求都判：
  /// 关掉开关或重新生成令牌后，已连着的客户端下一条请求就被拒。
  final McpAccess Function(String? bearerToken) authorize;

  Future<shelf.Response> handle(shelf.Request request) async {
    // 网页里的 fetch 一定带 Origin（DNS 重绑定 / 恶意网页打本机端口）：一律拒。
    // MCP 客户端（桌面进程）不带这个头。控制通道外层已拒过，这里不依赖外层。
    if (request.headers.containsKey('origin')) {
      return _status(
        403,
        'forbidden',
        'Requests with an Origin header are rejected.',
      );
    }
    switch (authorize(_bearer(request.headers['authorization']))) {
      case McpAccess.allowed:
        break;
      case McpAccess.disabled:
        return _status(
          403,
          'mcp_disabled',
          'External AI access is off. Turn it on in Fushi › Settings › Models › '
              'LLM › AI assistant.',
        );
      case McpAccess.notPaired:
        return _status(
          403,
          'mcp_not_paired',
          'No pairing token yet. Generate one in Fushi › Settings › Models › '
              'LLM › AI assistant.',
        );
      case McpAccess.unauthorized:
        return _status(
          401,
          'unauthorized',
          'Missing or wrong pairing token (Authorization: Bearer <token>).',
        );
    }
    final String? sessionId = request.headers[kMcpSessionHeader];
    switch (request.method.toUpperCase()) {
      case 'POST':
        return _post(request, sessionId);
      case 'DELETE':
        if (sessionId != null) server.endSession(sessionId);
        return shelf.Response(204);
      default:
        // 不提供服务端主动推送的 SSE 流（规范允许，回 405）。
        return shelf.Response(
          405,
          headers: const <String, String>{'Allow': 'POST, DELETE'},
        );
    }
  }

  Future<shelf.Response> _post(shelf.Request request, String? sessionId) async {
    final Object? payload;
    try {
      payload = jsonDecode(await request.readAsString());
    } on FormatException {
      return _json(400, mcpParseErrorReply());
    }
    final McpReply reply = await server.handle(payload, sessionId: sessionId);
    final Object? body = reply.body;
    final Map<String, String> headers = <String, String>{
      if (reply.sessionId != null) 'Mcp-Session-Id': reply.sessionId!,
    };
    if (body == null) return shelf.Response(202, headers: headers);
    return _json(200, body, headers: headers);
  }

  static String? _bearer(String? header) {
    if (header == null) return null;
    const String prefix = 'Bearer ';
    if (!header.startsWith(prefix)) return null;
    final String token = header.substring(prefix.length).trim();
    return token.isEmpty ? null : token;
  }

  static shelf.Response _status(int status, String code, String message) =>
      _json(status, <String, Object?>{'error': code, 'message': message});

  static shelf.Response _json(
    int status,
    Object? body, {
    Map<String, String> headers = const <String, String>{},
  }) => shelf.Response(
    status,
    body: jsonEncode(body),
    headers: <String, String>{
      'Content-Type': 'application/json; charset=utf-8',
      'Cache-Control': 'no-store',
      ...headers,
    },
  );
}
