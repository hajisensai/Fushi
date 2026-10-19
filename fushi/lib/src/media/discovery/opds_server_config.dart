/// 用户自配的 OPDS 服务器条目。
///
/// 形状与视频域的 `TorznabIndexerConfig` 同构（用户自配、带 `enabled` 自开关、
/// 整份列表存进一个偏好键的 JSON 数组），刻意不另发明一套：本仓已有的
/// Jellyfin / qBittorrent / Torznab / 互联对端四个「用户自配服务器」全是这个
/// 范式，走 Drift 表只有在需要外键挂子表时才划算（Mihon 扩展仓库是唯一那例）。
library;

import 'dart:convert';

import 'package:fushi_engine/media/torrent/torznab_client.dart'
    show isSafeExternalProviderEndpoint;
import 'package:fushi_engine/utils/net/redirect_headers.dart';

/// 一台 OPDS 服务器。
class OpdsServerConfig {
  OpdsServerConfig({
    required this.id,
    required this.name,
    required this.catalogUrl,
    this.username = '',
    this.password = '',
    this.apiKey = '',
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

  /// HTTP Basic 账号。Komga 的账号是**登录邮箱**（实测 `admin` 401、
  /// `admin@example.org` 200）。
  final String username;
  final String password;

  /// 可选的 API key，经 `X-API-Key` 头发送（BUG-3521）。
  ///
  /// Komga 1.29 的 API key 只认这个头：实测 `?apikey=`、Basic 里塞 key、
  /// 路径带 key 全部 401。与 Basic 并存时两个头都发——服务端各取所需，
  /// 不认识的头会被忽略。存储与 [password] 同一套遮蔽 + 隔离纪律。
  final String apiKey;

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
  /// OPDS 生态主流是 Basic（BookOrbit 文档明写「认证类型选 Basic」，
  /// Calibre-Web 同）；Komga 另有 API key（见 [apiKey]）。
  String? get authorizationHeader {
    if (username.trim().isEmpty) return null;
    final String token = base64Encode(utf8.encode('$username:$password'));
    return 'Basic $token';
  }

  /// 请求 [target] 时该附的凭据头：**只对目录自己的 origin** 给出。
  ///
  /// feed 里的链接可以指向任意主机（封面挂 CDN、下载重定向到对象存储都常见）。
  /// 无差别附上凭据会把用户的密码 / API key 送给第三方主机——与浏览器和 curl
  /// 的既定行为一致：凭据绑定 origin，不跟着链接走。下载、feed 请求与封面
  /// 图片三条链路共用这一个判据。
  Map<String, String> credentialHeadersFor(Uri target) {
    if (!isSameHttpOrigin(catalogUrl, target)) return const <String, String>{};
    final String? basic = authorizationHeader;
    final String key = apiKey.trim();
    if (basic == null && key.isEmpty) return const <String, String>{};
    return <String, String>{
      if (basic != null) 'Authorization': basic,
      if (key.isNotEmpty) 'X-API-Key': key,
    };
  }

  OpdsServerConfig copyWith({
    String? name,
    Uri? catalogUrl,
    String? username,
    String? password,
    String? apiKey,
    bool? enabled,
    bool? allowInsecureHttp,
  }) => OpdsServerConfig(
    id: id,
    name: name ?? this.name,
    catalogUrl: catalogUrl ?? this.catalogUrl,
    username: username ?? this.username,
    password: password ?? this.password,
    apiKey: apiKey ?? this.apiKey,
    enabled: enabled ?? this.enabled,
    allowInsecureHttp: allowInsecureHttp ?? this.allowInsecureHttp,
  );

  /// 密码与 API key 在 JSON 里 base64 存放。
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
    if (password.isNotEmpty) 'passwordB64': base64Encode(utf8.encode(password)),
    if (apiKey.isNotEmpty) 'apiKeyB64': base64Encode(utf8.encode(apiKey)),
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
    final String password = _decodeSecret(json['passwordB64']);
    // 旧版本写入的配置没有这个字段 → 空串（无 API key），形状向后兼容。
    final String apiKey = _decodeSecret(json['apiKeyB64']).trim();
    return OpdsServerConfig(
      id: (json['id'] as String? ?? '').trim(),
      name: (json['name'] as String? ?? '').trim(),
      catalogUrl: url,
      username: (json['username'] as String? ?? '').trim(),
      password: password,
      apiKey: apiKey,
      enabled: json['enabled'] is bool ? json['enabled']! as bool : true,
      allowInsecureHttp: json['allowInsecureHttp'] is bool
          ? json['allowInsecureHttp']! as bool
          : false,
    );
  }
}

/// base64 遮蔽字段 → 明文；缺失或畸形一律空串（一条坏字段不该让整条配置丢失）。
String _decodeSecret(Object? raw) {
  if (raw is! String || raw.isEmpty) return '';
  try {
    return utf8.decode(base64Decode(raw));
  } on FormatException {
    return '';
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

/// 已知 OPDS 服务端的目录端点（相对服务端根 / 反代前缀）。
///
/// 每条都核对过官方出处，不是猜的：
/// - Komga：`/opds/v2/catalog`、`/opds/v1.2/catalog`（komga.org/docs/guides/opds，
///   且在真 Komga 1.29.1 上实测：根地址回 200 HTML，`/opds`、`/opds/v2`、带结尾
///   斜杠的 `/opds/v1.2/catalog/` 一律 404，只有这两条 200）。v2 排前面：同一台
///   Komga 的 v2 目录根直接列出近期书目，搜索也会返回书而不只是系列目录。
/// - Calibre-Web：`/opds`（janeczku/calibre-web `cps/opds.py` 的路由
///   `@opds.route("/opds")`）。
/// - Kavita：`/api/opds/{apiKey}`（Kareadita/Kavita `OpdsController` 的
///   `[HttpGet("{apiKey}")]` + `BaseApiController` 的 `[Route("api/[controller]")]`）。
///   key 是路径的一部分，所以只在配了 API key 时才拼这一条。
const List<String> kKnownOpdsCatalogPaths = <String>[
  '/opds/v2/catalog',
  '/opds/v1.2/catalog',
  '/opds',
];

/// 反代前缀最多往上回溯几层（`/a/b/c` → `/a/b/c`、`/a/b`、`/a`、根）。
const int _kMaxPrefixDepth = 3;

/// 把用户填的地址展开成**按优先级排列**的候选目录地址（BUG-3519）。
///
/// 第一条恒为用户原样填的地址（填对了就零额外请求）；其后是去掉结尾斜杠的
/// 形态（Komga 对 `/opds/v1.2/catalog/` 回 404），再往后是 [kKnownOpdsCatalogPaths]
/// 拼在服务端根与各级路径前缀上（覆盖「只填了 `http://host:25600`」与
/// 「Komga 挂在反代子路径 `/komga` 下」两种形态）。
///
/// **不**在保存时直接改写用户的地址：去结尾斜杠只是候选之一——没有官方依据
/// 说所有 OPDS 服务端都把 `/x/` 与 `/x` 视为同一资源，盲改可能把一台原本
/// 能用的服务器改坏。只有真打通的那条才写回配置。
List<Uri> opdsCatalogUrlCandidates(Uri given, {String apiKey = ''}) {
  final Uri base = given.removeFragment();
  final List<Uri> candidates = <Uri>[base];
  final String path = base.path;
  String trimmed = path;
  while (trimmed.endsWith('/')) {
    trimmed = trimmed.substring(0, trimmed.length - 1);
  }
  if (trimmed != path && trimmed.isNotEmpty) {
    candidates.add(base.replace(path: trimmed));
  }
  final List<String> segments = trimmed
      .split('/')
      .where((String segment) => segment.isNotEmpty)
      .toList(growable: false);
  // 根优先：「只填了服务端根」与「填了半截 /opds」都在第一轮命中；反代前缀
  // 部署（`/komga/...`）再逐级加深。
  final List<String> prefixes = <String>[
    '',
    for (
      int depth = 1;
      depth <= segments.length && depth <= _kMaxPrefixDepth;
      depth++
    )
      '/${segments.take(depth).join('/')}',
  ];
  final String key = apiKey.trim();
  for (final String prefix in prefixes) {
    for (final String endpoint in kKnownOpdsCatalogPaths) {
      candidates.add(_originUri(base, '$prefix$endpoint'));
    }
    if (key.isNotEmpty) {
      candidates.add(
        _originUri(base, '$prefix/api/opds/${Uri.encodeComponent(key)}'),
      );
    }
  }
  final Set<String> seen = <String>{};
  return <Uri>[
    for (final Uri candidate in candidates)
      if (seen.add(candidate.toString())) candidate,
  ];
}

Uri _originUri(Uri base, String path) => Uri(
  scheme: base.scheme,
  host: base.host,
  port: base.hasPort ? base.port : null,
  path: path,
);
