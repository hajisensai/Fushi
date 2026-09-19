/// 用户自配的 AList / OpenList 站点条目。
///
/// 形状与 `OpdsServerConfig` 同构（用户自配、带 `enabled` 自开关、整份列表存进
/// 一个偏好键的 JSON 数组）。多出来的是 [kinds]：AList 是裸文件树，站里放的是书
/// 还是游戏无法从协议推断，只能由用户声明它该出现在哪些发现页的源下拉里。
library;

import 'dart:convert';

import 'package:fushi_engine/media/discovery/discovery_models.dart';
import 'package:fushi_engine/media/torrent/torznab_client.dart'
    show isSafeExternalProviderEndpoint;

/// 一个 AList / OpenList 站点。
class AListSiteConfig {
  AListSiteConfig({
    required this.id,
    required this.name,
    required this.baseUrl,
    Set<DiscoveryMediaKind> kinds = kDefaultAListSiteKinds,
    this.username = '',
    this.password = '',
    this.enabled = true,
    this.allowInsecureHttp = false,
  }) : kinds = Set<DiscoveryMediaKind>.unmodifiable(kinds) {
    if (id.trim().isEmpty) {
      throw ArgumentError.value(id, 'id', 'AList site id must not be empty');
    }
    if (baseUrl.scheme != 'http' && baseUrl.scheme != 'https') {
      throw ArgumentError('AList site URL must use HTTP or HTTPS');
    }
    if (baseUrl.host.isEmpty || baseUrl.userInfo.isNotEmpty) {
      throw ArgumentError(
        'AList site URL must have a host and carry no user info',
      );
    }
    if (!isSafeExternalProviderEndpoint(
      baseUrl,
      allowInsecureHttp: allowInsecureHttp,
    )) {
      throw ArgumentError(
        'AList site URL must use HTTPS unless plain HTTP is explicitly '
        'allowed or the host is loopback',
      );
    }
    if (this.kinds.isEmpty) {
      throw ArgumentError('AList site must declare at least one media kind');
    }
  }

  /// 稳定身份：源 id 由它派生（`alist-<id>`），而「停用源清单」按源 id 持久化。
  final String id;

  /// 用户起的显示名。空则回退成主机名。
  final String name;

  /// 站点根地址（不带 `/api`），例如 `https://od.example.com`。
  /// 用户贴了带路径的地址（`https://od.example.com/GD-1`）时只取 origin。
  final Uri baseUrl;

  /// 站点出现在哪些发现域的源下拉里；条目也按这个域标记。
  final Set<DiscoveryMediaKind> kinds;

  /// 账号；空 = 匿名 / 游客访问（站点开了游客即可列目录、取直链）。
  final String username;
  final String password;

  final bool enabled;

  /// 明文 HTTP 的显式放行（局域网自建站）。
  final bool allowInsecureHttp;

  String get displayName => name.trim().isNotEmpty ? name.trim() : baseUrl.host;

  /// 传给 adapter 的根地址：只留 origin，不带路径/查询。
  String get origin => baseUrl.origin;

  AListSiteConfig copyWith({
    String? name,
    Uri? baseUrl,
    Set<DiscoveryMediaKind>? kinds,
    String? username,
    String? password,
    bool? enabled,
    bool? allowInsecureHttp,
  }) =>
      AListSiteConfig(
        id: id,
        name: name ?? this.name,
        baseUrl: baseUrl ?? this.baseUrl,
        kinds: kinds ?? this.kinds,
        username: username ?? this.username,
        password: password ?? this.password,
        enabled: enabled ?? this.enabled,
        allowInsecureHttp: allowInsecureHttp ?? this.allowInsecureHttp,
      );

  /// 密码 base64 存放：遮蔽不是加密，纪律靠本键登记进
  /// `kCredentialPreferenceKeys` 与 device-local 清单（同 OPDS）。
  Map<String, Object?> toJson() => <String, Object?>{
        'id': id,
        'name': name,
        'url': baseUrl.toString(),
        'kinds': <String>[for (final DiscoveryMediaKind k in kinds) k.name],
        'username': username,
        if (password.isNotEmpty)
          'passwordB64': base64Encode(utf8.encode(password)),
        'enabled': enabled,
        'allowInsecureHttp': allowInsecureHttp,
      };

  /// 解析一条配置；畸形即抛，由列表层逐条丢弃（见 [decodeAListSiteConfigs]）。
  factory AListSiteConfig.fromJson(Map<String, Object?> json) {
    final Uri? url = Uri.tryParse((json['url'] as String? ?? '').trim());
    if (url == null) {
      throw const FormatException('AList site entry has no usable url');
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
    final Object? rawKinds = json['kinds'];
    // 未知的 kind 名（将来新增域再降级回旧版本）只丢那一个，不丢整条。
    final Set<DiscoveryMediaKind> kinds = rawKinds is List
        ? <DiscoveryMediaKind>{
            for (final Object? item in rawKinds)
              for (final DiscoveryMediaKind k in DiscoveryMediaKind.values)
                if (item is String && item == k.name) k,
          }
        : kDefaultAListSiteKinds;
    return AListSiteConfig(
      id: (json['id'] as String? ?? '').trim(),
      name: (json['name'] as String? ?? '').trim(),
      baseUrl: url,
      kinds: kinds,
      username: (json['username'] as String? ?? '').trim(),
      password: password,
      enabled: json['enabled'] is bool ? json['enabled']! as bool : true,
      allowInsecureHttp: json['allowInsecureHttp'] is bool
          ? json['allowInsecureHttp']! as bool
          : false,
    );
  }
}

/// 新站点默认声明的域：文件站最常见的用途是书与游戏；漫画/有声书由用户显式勾。
const Set<DiscoveryMediaKind> kDefaultAListSiteKinds = <DiscoveryMediaKind>{
  DiscoveryMediaKind.novel,
  DiscoveryMediaKind.game,
};

/// 整份清单 → JSON 字符串（存进单个偏好键）。
String encodeAListSiteConfigs(Iterable<AListSiteConfig> configs) =>
    jsonEncode(<Map<String, Object?>>[
      for (final AListSiteConfig config in configs) config.toJson(),
    ]);

/// JSON 字符串 → 清单。逐条容错、id 撞车丢后者（同 `decodeOpdsServerConfigs`）。
List<AListSiteConfig> decodeAListSiteConfigs(String? raw) {
  if (raw == null || raw.trim().isEmpty) return const <AListSiteConfig>[];
  final Object? decoded;
  try {
    decoded = jsonDecode(raw);
  } on FormatException {
    return const <AListSiteConfig>[];
  }
  if (decoded is! List) return const <AListSiteConfig>[];
  final List<AListSiteConfig> configs = <AListSiteConfig>[];
  final Set<String> seenIds = <String>{};
  for (final Object? item in decoded) {
    if (item is! Map<String, Object?>) continue;
    try {
      final AListSiteConfig config = AListSiteConfig.fromJson(item);
      if (!seenIds.add(config.id)) continue;
      configs.add(config);
    } catch (_) {
      continue;
    }
  }
  return configs;
}
