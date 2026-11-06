/// 用户自配的 OpenSubsonic（Navidrome / Gonic / Airsonic …）服务器条目。
///
/// 形状与 `AudiobookshelfServerConfig` 同构（用户自配、带 `enabled` 自开关、整份列表存进
/// 一个偏好键的 JSON 数组）。区别：Subsonic 的 token 认证（`t = md5(password + salt)`）
/// 每次请求都要用明文密码现算，所以密码必须持久化；也可以只填 OpenSubsonic
/// `apiKeyAuthentication` 扩展的 API key（此时不需要密码）。
library;

import 'dart:convert';

import 'package:fushi_engine/media/torrent/torznab_client.dart'
    show isSafeExternalProviderEndpoint;

/// 一台 Subsonic 服务器。
class SubsonicServerConfig {
  SubsonicServerConfig({
    required this.id,
    required this.name,
    required Uri serverUrl,
    this.username = '',
    this.password,
    this.apiKey,
    this.enabled = true,
    this.allowInsecureHttp = false,
  }) : serverUrl = _stripTrailingSlash(serverUrl) {
    if (id.trim().isEmpty) {
      throw ArgumentError.value(
        id,
        'id',
        'Subsonic server id must not be empty',
      );
    }
    if (this.serverUrl.scheme != 'http' && this.serverUrl.scheme != 'https') {
      throw ArgumentError('Subsonic server URL must use HTTP or HTTPS');
    }
    if (this.serverUrl.host.isEmpty || this.serverUrl.userInfo.isNotEmpty) {
      throw ArgumentError(
        'Subsonic server URL must have a host and carry no user info',
      );
    }
    if (!isSafeExternalProviderEndpoint(
      this.serverUrl,
      allowInsecureHttp: allowInsecureHttp,
    )) {
      throw ArgumentError(
        'Subsonic server URL must use HTTPS unless plain HTTP is explicitly '
        'allowed or the host is loopback',
      );
    }
    final bool hasKey = (apiKey ?? '').isNotEmpty;
    final bool hasPassword = username.isNotEmpty && (password ?? '').isNotEmpty;
    if (!hasKey && !hasPassword) {
      throw ArgumentError(
        'Subsonic server needs an API key or a username with a password',
      );
    }
  }

  /// 稳定身份。
  final String id;

  /// 用户起的显示名。空则回退成主机名。
  final String name;

  /// 服务器根地址（可带子路径），已归一：无尾斜杠。
  final Uri serverUrl;

  final String username;
  final String? password;

  /// OpenSubsonic `apiKeyAuthentication` 的 API key；有它时请求只带 `apiKey`。
  final String? apiKey;

  final bool enabled;

  /// 明文 HTTP 的显式放行（自建服务多在局域网 `http://…:4533`）。
  final bool allowInsecureHttp;

  /// 音乐引擎里的服务器身份（`MusicServerBrowser.serverId`）。
  String get serverId => 'subsonic-$id';

  String get displayName =>
      name.trim().isNotEmpty ? name.trim() : serverUrl.host;

  /// 凭据 base64 存放：遮蔽不是加密。真正的纪律是本键登记进 `kCredentialPreferenceKeys`
  /// （不进日志 / 明文导出）与设备本地清单（不随备份 / 同步出设备），同 OPDS / ABS。
  Map<String, Object?> toJson() => <String, Object?>{
    'id': id,
    'name': name,
    'url': serverUrl.toString(),
    'username': username,
    if ((password ?? '').isNotEmpty) 'passwordB64': _encode(password!),
    if ((apiKey ?? '').isNotEmpty) 'apiKeyB64': _encode(apiKey!),
    'enabled': enabled,
    'allowInsecureHttp': allowInsecureHttp,
  };

  /// 解析一条配置；畸形即抛 [FormatException] / [ArgumentError]，由列表层逐条丢弃。
  factory SubsonicServerConfig.fromJson(Map<String, Object?> json) {
    final Uri? url = Uri.tryParse((json['url'] as String? ?? '').trim());
    if (url == null) {
      throw const FormatException('Subsonic server entry has no usable url');
    }
    return SubsonicServerConfig(
      id: (json['id'] as String? ?? '').trim(),
      name: (json['name'] as String? ?? '').trim(),
      serverUrl: url,
      username: (json['username'] as String? ?? '').trim(),
      password: _decode(json['passwordB64']),
      apiKey: _decode(json['apiKeyB64']),
      enabled: json['enabled'] is bool ? json['enabled']! as bool : true,
      allowInsecureHttp: json['allowInsecureHttp'] is bool
          ? json['allowInsecureHttp']! as bool
          : false,
    );
  }

  static Uri _stripTrailingSlash(Uri url) {
    String path = url.path;
    while (path.endsWith('/')) {
      path = path.substring(0, path.length - 1);
    }
    return path == url.path ? url : url.replace(path: path);
  }

  static String _encode(String value) => base64Encode(utf8.encode(value));

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
String encodeSubsonicServerConfigs(Iterable<SubsonicServerConfig> configs) =>
    jsonEncode(<Map<String, Object?>>[
      for (final SubsonicServerConfig config in configs) config.toJson(),
    ]);

/// JSON 字符串 → 清单。逐条容错（坏条目丢弃）、id 撞车丢后者。
List<SubsonicServerConfig> decodeSubsonicServerConfigs(String? raw) {
  if (raw == null || raw.trim().isEmpty) return const <SubsonicServerConfig>[];
  final Object? decoded;
  try {
    decoded = jsonDecode(raw);
  } on FormatException {
    return const <SubsonicServerConfig>[];
  }
  if (decoded is! List) return const <SubsonicServerConfig>[];
  final List<SubsonicServerConfig> configs = <SubsonicServerConfig>[];
  final Set<String> seenIds = <String>{};
  for (final Object? item in decoded) {
    if (item is! Map<String, Object?>) continue;
    final SubsonicServerConfig config;
    try {
      config = SubsonicServerConfig.fromJson(item);
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
