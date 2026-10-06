/// 用户自配的 Audiobookshelf（ABS）服务器条目。
///
/// 形状与 `OpdsServerConfig` / `AListSiteConfig` 同构（用户自配、带 `enabled` 自开关、
/// 整份列表存进一个偏好键的 JSON 数组）。不同的是**不存密码**：ABS 有正经的令牌
/// 生命周期（1 小时 access token + 30 天会轮换的 refresh token，或用户粘贴的 API
/// key），密码只在设置页「登录」那一下用来换令牌，之后持久化的只有令牌。refresh
/// token 也失效了就提示用户重新登录，而不是拿存着的密码悄悄重登。
///
/// **不进**媒体服务器注册表（`media_server_registry.dart`）：那边每条配置都会被
/// 首页无条件当成视频服务器渲染，而 ABS 是发现页的有声书源。
library;

import 'dart:convert';

import 'package:fushi_engine/media/audiobook/audiobookshelf/audiobookshelf_models.dart';
import 'package:fushi_engine/media/torrent/torznab_client.dart'
    show isSafeExternalProviderEndpoint;

/// 一台 ABS 服务器。
class AudiobookshelfServerConfig {
  AudiobookshelfServerConfig({
    required this.id,
    required this.name,
    required this.serverUrl,
    this.username = '',
    this.tokens,
    this.enabled = true,
    this.allowInsecureHttp = false,
  }) {
    if (id.trim().isEmpty) {
      throw ArgumentError.value(id, 'id', 'ABS server id must not be empty');
    }
    if (serverUrl.scheme != 'http' && serverUrl.scheme != 'https') {
      throw ArgumentError('ABS server URL must use HTTP or HTTPS');
    }
    if (serverUrl.host.isEmpty || serverUrl.userInfo.isNotEmpty) {
      throw ArgumentError(
        'ABS server URL must have a host and carry no user info',
      );
    }
    if (!isSafeExternalProviderEndpoint(
      serverUrl,
      allowInsecureHttp: allowInsecureHttp,
    )) {
      throw ArgumentError(
        'ABS server URL must use HTTPS unless plain HTTP is explicitly '
        'allowed or the host is loopback',
      );
    }
  }

  /// 稳定身份：源 id 由它派生（`abs-<id>`）。
  final String id;

  /// 用户起的显示名。空则回退成主机名。
  final String name;

  /// 服务器根地址（可带 `RouterBasePath` 子路径），已归一：无尾斜杠。
  final Uri serverUrl;

  /// 登录的用户名（只作展示「已登录：xxx」；用 API key 时为空）。
  final String username;

  /// 当前令牌；null = 未登录（不进发现源注册表）。
  final AudiobookshelfTokens? tokens;

  final bool enabled;

  /// 明文 HTTP 的显式放行（自建 ABS 多在局域网 `http://…:13378`）。
  final bool allowInsecureHttp;

  bool get isSignedIn => tokens != null;

  String get displayName =>
      name.trim().isNotEmpty ? name.trim() : serverUrl.host;

  /// 换令牌。[tokens] 传 null 即退出登录——不能靠 `copyWith(tokens: null)`，
  /// 那会被当成「不改」。
  AudiobookshelfServerConfig withTokens(
    AudiobookshelfTokens? tokens, {
    String? username,
  }) => AudiobookshelfServerConfig(
    id: id,
    name: name,
    serverUrl: serverUrl,
    username: username ?? this.username,
    tokens: tokens,
    enabled: enabled,
    allowInsecureHttp: allowInsecureHttp,
  );

  /// 令牌 base64 存放：遮蔽不是加密。真正的纪律是本键登记进
  /// `kCredentialPreferenceKeys`（不进日志 / 明文导出）与 device-local 清单
  /// （不随备份 / 同步出设备），同 OPDS / AList。
  Map<String, Object?> toJson() {
    final AudiobookshelfTokens? current = tokens;
    return <String, Object?>{
      'id': id,
      'name': name,
      'url': serverUrl.toString(),
      'username': username,
      if (current != null) 'accessTokenB64': _encode(current.accessToken),
      if (current?.refreshToken case final String refresh)
        'refreshTokenB64': _encode(refresh),
      'enabled': enabled,
      'allowInsecureHttp': allowInsecureHttp,
    };
  }

  /// 解析一条配置；畸形即抛，由列表层逐条丢弃（见
  /// [decodeAudiobookshelfServerConfigs]）。
  factory AudiobookshelfServerConfig.fromJson(Map<String, Object?> json) {
    final Uri? url = Uri.tryParse((json['url'] as String? ?? '').trim());
    if (url == null) {
      throw const FormatException('ABS server entry has no usable url');
    }
    final String? access = _decode(json['accessTokenB64']);
    return AudiobookshelfServerConfig(
      id: (json['id'] as String? ?? '').trim(),
      name: (json['name'] as String? ?? '').trim(),
      serverUrl: url,
      username: (json['username'] as String? ?? '').trim(),
      tokens: access == null
          ? null
          : AudiobookshelfTokens(
              accessToken: access,
              refreshToken: _decode(json['refreshTokenB64']),
            ),
      enabled: json['enabled'] is bool ? json['enabled']! as bool : true,
      allowInsecureHttp: json['allowInsecureHttp'] is bool
          ? json['allowInsecureHttp']! as bool
          : false,
    );
  }

  static String _encode(String value) => base64Encode(utf8.encode(value));

  /// 解不开的令牌按「没有」处理：等价于未登录，用户重新登录即可恢复。
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
String encodeAudiobookshelfServerConfigs(
  Iterable<AudiobookshelfServerConfig> configs,
) => jsonEncode(<Map<String, Object?>>[
  for (final AudiobookshelfServerConfig config in configs) config.toJson(),
]);

/// JSON 字符串 → 清单。逐条容错、id 撞车丢后者（同 `decodeOpdsServerConfigs`）。
List<AudiobookshelfServerConfig> decodeAudiobookshelfServerConfigs(
  String? raw,
) {
  if (raw == null || raw.trim().isEmpty) {
    return const <AudiobookshelfServerConfig>[];
  }
  final Object? decoded;
  try {
    decoded = jsonDecode(raw);
  } on FormatException {
    return const <AudiobookshelfServerConfig>[];
  }
  if (decoded is! List) return const <AudiobookshelfServerConfig>[];
  final List<AudiobookshelfServerConfig> configs =
      <AudiobookshelfServerConfig>[];
  final Set<String> seenIds = <String>{};
  for (final Object? item in decoded) {
    if (item is! Map<String, Object?>) continue;
    final AudiobookshelfServerConfig config;
    try {
      config = AudiobookshelfServerConfig.fromJson(item);
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

/// 把某台服务器的新令牌写回清单（刷新轮换后的持久化用）。找不到 id（用户刚删了
/// 这台服务器）时原样返回——不能把删掉的服务器写回来。
List<AudiobookshelfServerConfig> replaceAudiobookshelfTokens(
  List<AudiobookshelfServerConfig> configs,
  String configId,
  AudiobookshelfTokens tokens,
) => <AudiobookshelfServerConfig>[
  for (final AudiobookshelfServerConfig config in configs)
    config.id == configId ? config.withTokens(tokens) : config,
];
