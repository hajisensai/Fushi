/// 用户自配的 Kavita 服务器条目。
///
/// 形状与 `OpdsServerConfig` / `AudiobookshelfServerConfig` 同构（用户自配、带
/// `enabled` 自开关、整份列表存进一个偏好键的 JSON 数组）。凭据是 Kavita 的长期
/// **API key**（用户设置里生成）：运行时用它换 JWT，JWT 过期就用同一把 key 重换，
/// 所以没有令牌轮换，也不存账号密码。
///
/// key 以 base64 存放：遮蔽不是加密。真正的纪律是本键 `kavita_servers` 登记进
/// `kCredentialPreferenceKeys`（不进日志 / 明文导出）、`PrefRedactionPolicy` 与
/// device-local 清单（不随备份 / 同步出设备），同 OPDS / AList / ABS。
library;

import 'dart:convert';

import 'package:fushi_engine/media/kavita/kavita_api.dart';
import 'package:fushi_engine/media/torrent/torznab_client.dart'
    show isSafeExternalProviderEndpoint;

/// 偏好键：整份 Kavita 服务器清单（JSON 数组）。
const String kKavitaServersPref = 'kavita_servers';

/// 一台 Kavita 服务器。
class KavitaServerConfig {
  KavitaServerConfig({
    required this.id,
    required this.name,
    required this.serverUrl,
    this.apiKey = '',
    this.enabled = true,
    this.allowInsecureHttp = false,
  }) {
    if (id.trim().isEmpty) {
      throw ArgumentError.value(id, 'id', 'Kavita server id must not be empty');
    }
    if (serverUrl.scheme != 'http' && serverUrl.scheme != 'https') {
      throw ArgumentError('Kavita server URL must use HTTP or HTTPS');
    }
    if (serverUrl.host.isEmpty || serverUrl.userInfo.isNotEmpty) {
      throw ArgumentError(
        'Kavita server URL must have a host and carry no user info',
      );
    }
    if (!isSafeExternalProviderEndpoint(
      serverUrl,
      allowInsecureHttp: allowInsecureHttp,
    )) {
      throw ArgumentError(
        'Kavita server URL must use HTTPS unless plain HTTP is explicitly '
        'allowed or the host is loopback',
      );
    }
  }

  /// 稳定身份：本地书的 key、绑定、预取缓存都按它归属。
  final String id;

  /// 用户起的显示名。空则回退成主机名。
  final String name;

  /// 服务器根地址（可带反代子路径），已归一：无尾斜杠。
  final Uri serverUrl;

  /// 长期 API key；空 = 未配置（不进运行时）。
  final String apiKey;

  final bool enabled;

  /// 明文 HTTP 的显式放行（自建 Kavita 多在局域网 `http://…:5000`）。
  final bool allowInsecureHttp;

  bool get hasApiKey => apiKey.trim().isNotEmpty;

  /// 可用于发请求：启用且配了 key。
  bool get isUsable => enabled && hasApiKey;

  String get displayName =>
      name.trim().isNotEmpty ? name.trim() : serverUrl.host;

  /// 归一化后的根地址字符串（协议层用）。
  String get serverUrlString {
    String url = serverUrl.toString();
    while (url.endsWith('/')) {
      url = url.substring(0, url.length - 1);
    }
    return url;
  }

  KavitaServerConfig copyWith({
    String? name,
    Uri? serverUrl,
    String? apiKey,
    bool? enabled,
    bool? allowInsecureHttp,
  }) => KavitaServerConfig(
    id: id,
    name: name ?? this.name,
    serverUrl: serverUrl ?? this.serverUrl,
    apiKey: apiKey ?? this.apiKey,
    enabled: enabled ?? this.enabled,
    allowInsecureHttp: allowInsecureHttp ?? this.allowInsecureHttp,
  );

  /// 构造协议层客户端；调用方负责 `close()`（或交给 `KavitaApiRegistry`）。
  KavitaApi createApi() =>
      KavitaApi(serverUrl: serverUrlString, apiKey: apiKey.trim());

  /// 两份配置会不会让已建好的协议层实例失效（地址 / key 变了）。
  bool sameConnectionAs(KavitaServerConfig other) =>
      serverUrlString == other.serverUrlString &&
      apiKey.trim() == other.apiKey.trim();

  Map<String, Object?> toJson() => <String, Object?>{
    'id': id,
    'name': name,
    'url': serverUrl.toString(),
    if (hasApiKey) 'apiKeyB64': _encode(apiKey.trim()),
    'enabled': enabled,
    'allowInsecureHttp': allowInsecureHttp,
  };

  /// 解析一条配置；畸形即抛，由列表层逐条丢弃（见 [decodeKavitaServerConfigs]）。
  factory KavitaServerConfig.fromJson(Map<String, Object?> json) {
    final Uri? url = Uri.tryParse(
      KavitaApi.normalizeServerUrl(json['url'] as String? ?? ''),
    );
    if (url == null || (json['url'] as String? ?? '').trim().isEmpty) {
      throw const FormatException('Kavita server entry has no usable url');
    }
    return KavitaServerConfig(
      id: (json['id'] as String? ?? '').trim(),
      name: (json['name'] as String? ?? '').trim(),
      serverUrl: url,
      apiKey: _decode(json['apiKeyB64']) ?? '',
      enabled: json['enabled'] is bool ? json['enabled']! as bool : true,
      allowInsecureHttp: json['allowInsecureHttp'] is bool
          ? json['allowInsecureHttp']! as bool
          : false,
    );
  }

  /// 刻意不输出 key。
  @override
  String toString() =>
      'KavitaServerConfig(id: $id, url: $serverUrlString, enabled: $enabled)';

  static String _encode(String value) => base64Encode(utf8.encode(value));

  /// 解不开的 key 按「没有」处理：等价于未配置，用户重新填即可恢复。
  static String? _decode(Object? raw) {
    if (raw is! String || raw.isEmpty) return null;
    try {
      final String value = utf8.decode(base64Decode(raw));
      return value.isEmpty ? null : value;
    } on FormatException {
      return null;
    }
  }
}

/// 整份清单 → JSON 字符串（存进单个偏好键）。
String encodeKavitaServerConfigs(Iterable<KavitaServerConfig> configs) =>
    jsonEncode(<Map<String, Object?>>[
      for (final KavitaServerConfig config in configs) config.toJson(),
    ]);

/// JSON 字符串 → 清单。逐条容错、id 撞车丢后者（同 `decodeOpdsServerConfigs`）。
List<KavitaServerConfig> decodeKavitaServerConfigs(String? raw) {
  if (raw == null || raw.trim().isEmpty) return const <KavitaServerConfig>[];
  final Object? decoded;
  try {
    decoded = jsonDecode(raw);
  } on FormatException {
    return const <KavitaServerConfig>[];
  }
  if (decoded is! List) return const <KavitaServerConfig>[];
  final List<KavitaServerConfig> configs = <KavitaServerConfig>[];
  final Set<String> seenIds = <String>{};
  for (final Object? item in decoded) {
    if (item is! Map<String, Object?>) continue;
    final KavitaServerConfig config;
    try {
      config = KavitaServerConfig.fromJson(item);
    } on FormatException {
      continue;
    } on ArgumentError {
      continue;
    }
    if (!seenIds.add(config.id)) continue;
    configs.add(config);
  }
  return configs;
}
