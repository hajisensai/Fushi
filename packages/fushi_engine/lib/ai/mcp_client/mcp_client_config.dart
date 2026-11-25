/// AI 助手接入的外部 MCP server 配置（spec
/// `docs/specs/2026-11-05-ai-mcp-client-design.md`）。
///
/// 存在偏好 `ai_mcp_client_servers`（设备本地、凭据键）。请求头与环境变量的值可能是
/// token，与 `ai_providers` 的 `apiKeyB64` 同一存法：base64，不进日志与导出。
library;

import 'dart:convert';

/// 怎么连这个 server。
enum McpTransportKind {
  /// Streamable HTTP（网络地址）。各平台都能用。
  http,

  /// 本地程序，stdin / stdout 走 JSON-RPC。只在桌面能用。
  stdio;

  static McpTransportKind fromName(String? name) {
    for (final McpTransportKind kind in values) {
      if (kind.name == name) return kind;
    }
    return McpTransportKind.http;
  }
}

/// 一个外部 MCP server。
class McpServerConfig {
  const McpServerConfig({
    required this.id,
    required this.name,
    this.enabled = true,
    this.transport = McpTransportKind.http,
    this.url = '',
    this.headers = const <String, String>{},
    this.command = '',
    this.args = const <String>[],
    this.env = const <String, String>{},
    this.disabledTools = const <String>{},
    this.confirmEveryCall = false,
  });

  /// 稳定身份，也是工具 id 的一段（`mcp.<id>.<工具名>`）：只含 `[a-z0-9-]`，创建时由
  /// [mcpServerIdFor] 生成，之后不变。
  final String id;
  final String name;
  final bool enabled;
  final McpTransportKind transport;

  /// HTTP：端点地址。
  final String url;

  /// HTTP：附加请求头（如 `Authorization`）。值按凭据存。
  final Map<String, String> headers;

  /// stdio：程序与参数。
  final String command;
  final List<String> args;

  /// stdio：附加环境变量。值按凭据存。
  final Map<String, String> env;

  /// 用户关掉的工具（server 上的原始工具名）。
  final Set<String> disabledTools;

  /// 每次调用都先弹确认卡（连只读工具也问）。
  final bool confirmEveryCall;

  McpServerConfig copyWith({
    String? name,
    bool? enabled,
    McpTransportKind? transport,
    String? url,
    Map<String, String>? headers,
    String? command,
    List<String>? args,
    Map<String, String>? env,
    Set<String>? disabledTools,
    bool? confirmEveryCall,
  }) => McpServerConfig(
    id: id,
    name: name ?? this.name,
    enabled: enabled ?? this.enabled,
    transport: transport ?? this.transport,
    url: url ?? this.url,
    headers: headers ?? this.headers,
    command: command ?? this.command,
    args: args ?? this.args,
    env: env ?? this.env,
    disabledTools: disabledTools ?? this.disabledTools,
    confirmEveryCall: confirmEveryCall ?? this.confirmEveryCall,
  );

  /// 连接相关字段的指纹：变了就要断开重连。开关、工具开关、确认策略不在里面
  /// （改它们不必重连）。
  String get connectionFingerprint => jsonEncode(<String, Object?>{
    'transport': transport.name,
    'url': url,
    'headers': headers,
    'command': command,
    'args': args,
    'env': env,
  });

  /// 配置是否填全了（能尝试连接）。HTTP 只认带主机名的 `http(s)://` 地址：别的 scheme
  /// （`file:` / `ftp:` …）`package:http` 发不出去，留着只会每轮连接失败。
  bool get isComplete => switch (transport) {
    McpTransportKind.http => isValidMcpHttpUrl(url),
    McpTransportKind.stdio => command.trim().isNotEmpty,
  };

  Map<String, Object?> toJson() => <String, Object?>{
    'id': id,
    'name': name,
    'enabled': enabled,
    'transport': transport.name,
    if (url.isNotEmpty) 'url': url,
    if (headers.isNotEmpty) 'headersB64': _encodeSecretMap(headers),
    if (command.isNotEmpty) 'command': command,
    if (args.isNotEmpty) 'args': args,
    if (env.isNotEmpty) 'envB64': _encodeSecretMap(env),
    if (disabledTools.isNotEmpty)
      'disabledTools': (disabledTools.toList()..sort()),
    if (confirmEveryCall) 'confirmEveryCall': true,
  };

  /// 解一条；缺 id 或 id 不合法返回 null（整条丢弃）。
  static McpServerConfig? fromJson(Map<String, Object?> json) {
    final String id = '${json['id'] ?? ''}';
    if (!isValidMcpServerId(id)) return null;
    final String name = '${json['name'] ?? ''}'.trim();
    return McpServerConfig(
      id: id,
      name: name.isEmpty ? id : name,
      enabled: json['enabled'] != false,
      transport: McpTransportKind.fromName(json['transport'] as String?),
      url: '${json['url'] ?? ''}',
      headers: _decodeSecretMap(json['headersB64']),
      command: '${json['command'] ?? ''}',
      args: <String>[
        if (json['args'] case final List<Object?> list)
          for (final Object? a in list) '$a',
      ],
      env: _decodeSecretMap(json['envB64']),
      disabledTools: <String>{
        if (json['disabledTools'] case final List<Object?> list)
          for (final Object? t in list) '$t',
      },
      confirmEveryCall: json['confirmEveryCall'] == true,
    );
  }
}

Map<String, String> _encodeSecretMap(Map<String, String> values) =>
    <String, String>{
      for (final MapEntry<String, String> e in values.entries)
        e.key: base64.encode(utf8.encode(e.value)),
    };

Map<String, String> _decodeSecretMap(Object? raw) {
  if (raw is! Map) return const <String, String>{};
  final Map<String, String> out = <String, String>{};
  for (final MapEntry<Object?, Object?> e in raw.entries) {
    try {
      out['${e.key}'] = utf8.decode(base64.decode('${e.value}'));
    } on FormatException {
      // 坏掉的一个值只丢它自己。
    }
  }
  return out;
}

/// HTTP 型 server 地址是否可用：`http` / `https`，且有主机名。
bool isValidMcpHttpUrl(String url) {
  final Uri? uri = Uri.tryParse(url.trim());
  if (uri == null || uri.host.isEmpty) return false;
  return uri.scheme == 'https' || uri.scheme == 'http';
}

final RegExp _kServerIdPattern = RegExp(
  r'^[a-z0-9](?:[a-z0-9-]{0,22}[a-z0-9])?$',
);

/// server id 是否合法：`[a-z0-9-]`，1–24 字符，不以 `-` 开头结尾。
bool isValidMcpServerId(String id) => _kServerIdPattern.hasMatch(id);

/// 由名字生成一个不与 [taken] 重复的 server id。
String mcpServerIdFor(String name, Iterable<String> taken) {
  final Set<String> used = taken.toSet();
  String base = name
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9]+'), '-')
      .replaceAll(RegExp(r'^-+|-+$'), '');
  if (base.length > 20) {
    base = base.substring(0, 20).replaceAll(RegExp(r'-+$'), '');
  }
  if (base.isEmpty) base = 'server';
  if (!used.contains(base)) return base;
  for (int i = 2; ; i++) {
    final String candidate = '$base-$i';
    if (!used.contains(candidate)) return candidate;
  }
}

/// 整份清单编码。
String encodeMcpServerConfigs(Iterable<McpServerConfig> servers) =>
    jsonEncode(<Object?>[for (final McpServerConfig s in servers) s.toJson()]);

/// 整份清单解码：逐条容错，一条坏掉只丢那一条；id 重复的后者丢弃。整串不是 JSON
/// 列表时抛 [FormatException]（由调用方记日志）。
List<McpServerConfig> decodeMcpServerConfigs(String raw) {
  final Object? decoded = jsonDecode(raw);
  if (decoded is! List) {
    throw const FormatException('ai_mcp_client_servers is not a JSON list');
  }
  final Set<String> seen = <String>{};
  final List<McpServerConfig> out = <McpServerConfig>[];
  for (final Object? item in decoded) {
    if (item is! Map) continue;
    final McpServerConfig? config = McpServerConfig.fromJson(
      Map<String, Object?>.from(item),
    );
    if (config == null || !seen.add(config.id)) continue;
    out.add(config);
  }
  return out;
}

/// 从通用 `mcpServers` 配置片段（Claude Desktop / Cursor / VS Code 等客户端的形状）
/// 导入。认 `{"mcpServers": {...}}`、`{"servers": {...}}` 与直接的 `{名字: {...}}`。
/// 每条：有 `url` → HTTP（`headers` 照收）；有 `command` → stdio（`args` / `env` 照收）。
/// 认不出的条目跳过。新 id 避开 [taken]。
///
/// 导入的条目一律 **关着**（`enabled: false`）：配置片段多半是从网上 / 别的应用复制来的，
/// 本地程序型等于在本机执行片段里的命令，网络地址型会把片段里的请求头（token）发出去；
/// 要用户在设置页看过之后亲手打开。
List<McpServerConfig> importMcpServersFromJson(
  String raw, {
  Iterable<String> taken = const <String>[],
}) {
  final Object? decoded = jsonDecode(raw);
  if (decoded is! Map) {
    throw const FormatException('MCP config must be a JSON object');
  }
  final Object? inner = decoded['mcpServers'] ?? decoded['servers'] ?? decoded;
  if (inner is! Map) return const <McpServerConfig>[];
  final List<String> used = taken.toList();
  final List<McpServerConfig> out = <McpServerConfig>[];
  for (final MapEntry<Object?, Object?> e in inner.entries) {
    final Object? body = e.value;
    if (body is! Map) continue;
    final String name = '${e.key}';
    final String url = '${body['url'] ?? body['serverUrl'] ?? ''}'.trim();
    final String command = '${body['command'] ?? ''}'.trim();
    if (url.isEmpty && command.isEmpty) continue;
    final String id = mcpServerIdFor(name, used);
    used.add(id);
    out.add(
      McpServerConfig(
        id: id,
        name: name,
        enabled: false,
        transport: url.isNotEmpty
            ? McpTransportKind.http
            : McpTransportKind.stdio,
        url: url,
        headers: _stringMap(body['headers']),
        command: url.isNotEmpty ? '' : command,
        args: url.isNotEmpty
            ? const <String>[]
            : <String>[
                if (body['args'] case final List<Object?> list)
                  for (final Object? a in list) '$a',
              ],
        env: url.isNotEmpty
            ? const <String, String>{}
            : _stringMap(body['env']),
      ),
    );
  }
  return out;
}

Map<String, String> _stringMap(Object? raw) => <String, String>{
  if (raw is Map)
    for (final MapEntry<Object?, Object?> e in raw.entries)
      '${e.key}': '${e.value}',
};
