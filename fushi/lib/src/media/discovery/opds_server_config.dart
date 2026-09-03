/// 用户自配的 OPDS 服务器条目。
///
/// 形状与视频域的 `TorznabIndexerConfig` 同构（用户自配、带 `enabled` 自开关、
/// 整份列表存进一个偏好键的 JSON 数组），刻意不另发明一套：本仓已有的
/// Jellyfin / qBittorrent / Torznab / 互联对端四个「用户自配服务器」全是这个
/// 范式，走 Drift 表只有在需要外键挂子表时才划算（Mihon 扩展仓库是唯一那例）。
library;

import 'dart:convert';

import 'package:fushi/src/media/torrent/torznab_client.dart'
    show isSafeExternalProviderEndpoint;

/// 一台 OPDS 服务器。
class OpdsServerConfig {
  OpdsServerConfig({
    required this.id,
    required this.name,
    required this.catalogUrl,
    this.username = '',
    this.password = '',
    this.enabled = true,
    this.allowInsecureHttp = false,
  }) {
    if (id.trim().isEmpty) {
      throw ArgumentError.value(id, 'id', 'OPDS server id must not be empty');
    }
    if (catalogUrl.scheme != 'http' && catalogUrl.scheme != 'https') {
      throw ArgumentError('OPDS catalog URL must use HTTP or HTTPS');
    }
    if (catalogUrl.host.isEmpty || catalogUrl.userInfo.isNotEmpty) {
      throw ArgumentError(
        'OPDS catalog URL must have a host and carry no user info',
      );
    }
    if (!isSafeExternalProviderEndpoint(
      catalogUrl,
      allowInsecureHttp: allowInsecureHttp,
    )) {
      throw ArgumentError(
        'OPDS catalog URL must use HTTPS unless plain HTTP is explicitly '
        'allowed or the host is loopback',
      );
    }
  }

  /// 稳定身份：源 id 由它派生（`opds-<id>`），而「停用源清单」按源 id 持久化。
  /// 改 id 等于换了一台服务器，旧的开关状态会断档。
  final String id;

  /// 用户起的显示名（列表与源下拉里显示）。空则回退成主机名。
  final String name;

  /// 目录根地址，例如 `https://books.example.com/api/v1/opds`。
  final Uri catalogUrl;

  final String username;
  final String password;

  final bool enabled;

  /// 明文 HTTP 的显式放行。自建 OPDS 常年跑在局域网 `http://192.168.x.x:8080`，
  /// 不给这个开关等于把最主流的自建场景挡在门外；但它必须是用户显式勾选的，
  /// 而不是默认放行——默认放行会让公网地址的降级传输悄悄发生。
  final bool allowInsecureHttp;

  /// 列表与下拉里的展示名。
  String get displayName =>
      name.trim().isNotEmpty ? name.trim() : catalogUrl.host;

  /// HTTP Basic 认证头；没配用户名时返回 null（匿名目录）。
  ///
  /// OPDS 生态事实上只用 Basic（BookOrbit 文档明写「认证类型选 Basic」，
  /// Calibre-Web / Komga / Kavita 同）。
  String? get authorizationHeader {
    if (username.trim().isEmpty) return null;
    final String token = base64Encode(utf8.encode('$username:$password'));
    return 'Basic $token';
  }

  OpdsServerConfig copyWith({
    String? name,
    Uri? catalogUrl,
    String? username,
    String? password,
    bool? enabled,
    bool? allowInsecureHttp,
  }) =>
      OpdsServerConfig(
        id: id,
        name: name ?? this.name,
        catalogUrl: catalogUrl ?? this.catalogUrl,
        username: username ?? this.username,
        password: password ?? this.password,
        enabled: enabled ?? this.enabled,
        allowInsecureHttp: allowInsecureHttp ?? this.allowInsecureHttp,
      );

  /// 密码在 JSON 里 base64 存放。
  ///
  /// 说清楚：这是**遮蔽不是加密**——能解码回来的东西挡不住拿到设备的人。
  /// 本仓没有 secure storage，既有做法就是 `sync_repository.dart` 的
  /// `_encodeSecret`（同样是 base64，用于 WebDAV / 同步服务器密码）。
  /// 真正被执行的纪律不在编码强度，而在**隔离**：本键登记进
  /// `kCredentialPreferenceKeys`（绝不写日志、绝不进明文导出）与
  /// device-local 清单（绝不随备份/同步出设备）。
  Map<String, Object?> toJson() => <String, Object?>{
        'id': id,
        'name': name,
        'url': catalogUrl.toString(),
        'username': username,
        if (password.isNotEmpty)
          'passwordB64': base64Encode(utf8.encode(password)),
        'enabled': enabled,
        'allowInsecureHttp': allowInsecureHttp,
      };

  /// 解析一条配置；任何字段畸形都抛，由列表层逐条丢弃（见
  /// [decodeOpdsServerConfigs]）——一条坏记录不该让整份清单消失。
  factory OpdsServerConfig.fromJson(Map<String, Object?> json) {
    final Uri? url = Uri.tryParse((json['url'] as String? ?? '').trim());
    if (url == null) {
      throw const FormatException('OPDS server entry has no usable url');
    }
    final Object? rawPassword = json['passwordB64'];
    String password = '';
    if (rawPassword is String && rawPassword.isNotEmpty) {
      try {
        password = utf8.decode(base64Decode(rawPassword));
      } on FormatException {
        password = '';
      }
    }
    return OpdsServerConfig(
      id: (json['id'] as String? ?? '').trim(),
      name: (json['name'] as String? ?? '').trim(),
      catalogUrl: url,
      username: (json['username'] as String? ?? '').trim(),
      password: password,
      enabled: json['enabled'] is bool ? json['enabled']! as bool : true,
      allowInsecureHttp: json['allowInsecureHttp'] is bool
          ? json['allowInsecureHttp']! as bool
          : false,
    );
  }
}

/// 整份清单 → JSON 字符串（存进单个偏好键）。
String encodeOpdsServerConfigs(Iterable<OpdsServerConfig> configs) =>
    jsonEncode(<Map<String, Object?>>[
      for (final OpdsServerConfig config in configs) config.toJson(),
    ]);

/// JSON 字符串 → 清单。
///
/// **逐条**容错：一条记录坏掉（用户手改了偏好、旧版本写入了不兼容形状）
/// 只丢那一条，不让整份服务器列表消失。整体不是数组时返回空列表。
List<OpdsServerConfig> decodeOpdsServerConfigs(String? raw) {
  if (raw == null || raw.trim().isEmpty) return const <OpdsServerConfig>[];
  final Object? decoded;
  try {
    decoded = jsonDecode(raw);
  } on FormatException {
    return const <OpdsServerConfig>[];
  }
  if (decoded is! List) return const <OpdsServerConfig>[];
  final List<OpdsServerConfig> configs = <OpdsServerConfig>[];
  final Set<String> seenIds = <String>{};
  for (final Object? item in decoded) {
    if (item is! Map<String, Object?>) continue;
    try {
      final OpdsServerConfig config = OpdsServerConfig.fromJson(item);
      // id 撞车会让两个源共用一个 id，`sourceById` 只认得到第一个，
      // 而「停用」开关会同时作用到两台服务器上。后来者丢弃。
      if (!seenIds.add(config.id)) continue;
      configs.add(config);
    } catch (_) {
      continue;
    }
  }
  return configs;
}
