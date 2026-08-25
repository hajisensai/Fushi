import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'package:fushi/src/storage/app_paths.dart';

/// 单一浏览器身份：Aidoku wasm host（Rust reqwest）、解 Cloudflare 挑战的 WebView、
/// 阅读器图片下载三方**必须字节一致**——Cloudflare 把 `cf_clearance` 绑定到解题时的
/// User-Agent，任何一方不同就等于没拿到 cookie（BUG-1876）。
const String kAidokuUserAgent =
    'Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) '
    'AppleWebKit/605.1.15 (KHTML, like Gecko) '
    'Version/18.0 Mobile/15E148 Safari/604.1';

/// Cloudflare 放行 cookie 的名字；WebView 里出现它即视为挑战已解。
const String kCloudflareClearanceCookie = 'cf_clearance';

/// 解题回调：把 [challengeUrl] 交给 UI 层在 WebView 里完成验证，返回是否拿到了放行
/// cookie（已写入 jar）。`false` = 用户取消或超时，调用方按原错误上报。
typedef AidokuCloudflareResolver = Future<bool> Function(Uri challengeUrl);

/// 运行时与 UI 层的接线点：UI 启动时装一个 resolver，runtime 遇到
/// `CLOUDFLARE_CHALLENGE` 时调用它。没装（测试 / 无 UI）就退化成直接报错。
abstract final class AidokuCloudflareGate {
  static AidokuCloudflareResolver? resolver;
}

/// 一条按域名作用的 cookie（对齐 Rust 侧 `NetworkCookie`）。
class AidokuCookie {
  const AidokuCookie({
    required this.name,
    required this.value,
    required this.domain,
    this.path = '/',
    this.secure = false,
    this.expiresAt,
  });

  factory AidokuCookie.fromJson(Map<String, Object?> json) => AidokuCookie(
        name: json['name']?.toString() ?? '',
        value: json['value']?.toString() ?? '',
        domain: json['domain']?.toString() ?? '',
        path: json['path']?.toString() ?? '/',
        secure: json['secure'] == true,
        expiresAt: (json['expiresAt'] as num?)?.toInt(),
      );

  final String name;
  final String value;

  /// 注册域（可带前导点）。匹配规则同 RFC 6265：host 等于它或以 `.<domain>` 结尾。
  final String domain;
  final String path;
  final bool secure;

  /// 过期时刻（毫秒时间戳）；null = 会话 cookie，随文件保留直到被替换。
  final int? expiresAt;

  /// 去掉前导点的规范域，用于匹配与去重。
  String get canonicalDomain => canonicalizeDomain(domain);

  bool get isValid => name.isNotEmpty && canonicalDomain.isNotEmpty;

  bool isExpiredAt(int nowMs) => expiresAt != null && expiresAt! <= nowMs;

  bool matchesHost(String host) => hostMatchesDomain(host, canonicalDomain);

  Map<String, Object?> toJson() => <String, Object?>{
        'name': name,
        'value': value,
        'domain': canonicalDomain,
        'path': path,
        'secure': secure,
        if (expiresAt != null) 'expiresAt': expiresAt,
      };

  static String canonicalizeDomain(String domain) {
    String value = domain.trim().toLowerCase();
    while (value.startsWith('.')) {
      value = value.substring(1);
    }
    return value;
  }

  static bool hostMatchesDomain(String host, String domain) {
    final String lowerHost = host.trim().toLowerCase();
    if (lowerHost.isEmpty || domain.isEmpty) return false;
    return lowerHost == domain || lowerHost.endsWith('.$domain');
  }
}

/// 文件持久化的 cookie jar，Aidoku 源专用（与 WebView 自己的 cookie 存储分离：
/// WKHTTPCookieStore 只有 WebView 能读，wasm host 在 Rust 里发请求读不到它，
/// 所以解题后要**复制**一份出来，随每次 invoke 送进 host）。
///
/// 只存 Aidoku 源站的 cookie，设备本地、不进同步/备份。
class AidokuCookieJar {
  AidokuCookieJar(File file, {int Function()? clock})
      : _resolveFile = (() async => file),
        _clock = clock ?? _defaultClock;

  /// 路径延迟解析（共享实例：支持目录要等平台通道就绪）。
  AidokuCookieJar.lazy(
    Future<File> Function() resolveFile, {
    int Function()? clock,
  })  : _resolveFile = resolveFile,
        _clock = clock ?? _defaultClock;

  static int _defaultClock() => DateTime.now().millisecondsSinceEpoch;

  /// 进程级共享实例，落在 Aidoku 扩展目录旁的 `cookies.json`。
  static AidokuCookieJar get shared =>
      _shared ??= AidokuCookieJar.lazy(_sharedFile);
  static AidokuCookieJar? _shared;

  /// 测试替换共享实例。
  static set shared(AidokuCookieJar? value) => _shared = value;

  static Future<File> _sharedFile() async {
    final Directory supportRoot = await AppPaths.supportRootDirectory();
    return File(p.join(
      supportRoot.path,
      'manga_extensions',
      'aidoku',
      'cookies.json',
    ));
  }

  final Future<File> Function() _resolveFile;
  final int Function() _clock;
  File? _file;
  List<AidokuCookie> _cookies = const <AidokuCookie>[];
  Future<void>? _loading;

  List<AidokuCookie> get cookies => List<AidokuCookie>.unmodifiable(_cookies);

  Future<void> ensureLoaded() => _loading ??= _load();

  Future<void> _load() async {
    final File target = _file ??= await _resolveFile();
    if (!await target.exists()) return;
    try {
      final Object? decoded = jsonDecode(await target.readAsString());
      if (decoded is! List<Object?>) return;
      _cookies = decoded
          .whereType<Map<Object?, Object?>>()
          .map((Map<Object?, Object?> item) =>
              AidokuCookie.fromJson(item.cast<String, Object?>()))
          .where((AidokuCookie cookie) => cookie.isValid)
          .toList(growable: false);
    } on FormatException {
      // 坏文件 = 没 cookie；下一次写入会覆盖它。
      _cookies = const <AidokuCookie>[];
    }
  }

  /// 当前对 [host] 生效（域匹配且未过期）的 cookie。
  List<AidokuCookie> cookiesFor(Uri url) {
    final int now = _clock();
    return _cookies
        .where((AidokuCookie cookie) =>
            !cookie.isExpiredAt(now) && cookie.matchesHost(url.host))
        .toList(growable: false);
  }

  /// `Cookie:` 请求头值；无匹配返回 null。
  String? cookieHeaderFor(Uri url) {
    final List<AidokuCookie> matched = cookiesFor(url);
    if (matched.isEmpty) return null;
    return matched
        .map((AidokuCookie cookie) => '${cookie.name}=${cookie.value}')
        .join('; ');
  }

  /// 是否已持有对 [url] 生效的 Cloudflare 放行 cookie。
  bool hasClearanceFor(Uri url) => cookiesFor(url)
      .any((AidokuCookie cookie) => cookie.name == kCloudflareClearanceCookie);

  /// 用 WebView 解题后导出的整组 cookie **替换**该站点（[host] 所属的全部注册域）
  /// 的旧条目：旧的 `cf_clearance` 已经失效才会走到解题，留着只会让 host 端多发一个
  /// 被拒的 cookie。其它站点的条目不动。
  Future<void> replaceForHost(String host, List<AidokuCookie> fresh) async {
    await ensureLoaded();
    final int now = _clock();
    final List<AidokuCookie> incoming = fresh
        .where((AidokuCookie cookie) =>
            cookie.isValid &&
            !cookie.isExpiredAt(now) &&
            AidokuCookie.hostMatchesDomain(host, cookie.canonicalDomain))
        .toList(growable: false);
    final Set<String> replacedDomains =
        incoming.map((AidokuCookie cookie) => cookie.canonicalDomain).toSet();
    _cookies = <AidokuCookie>[
      for (final AidokuCookie cookie in _cookies)
        if (!cookie.isExpiredAt(now) &&
            !replacedDomains.contains(cookie.canonicalDomain))
          cookie,
      ...incoming,
    ];
    await _persist();
  }

  Future<void> clear() async {
    await ensureLoaded();
    _cookies = const <AidokuCookie>[];
    await _persist();
  }

  /// 随每次 runtime invoke 送进 Rust host 的 `network` 字段。整个 jar 一起送：
  /// host 端自己按域匹配，而且一次调用里源会跨 api / cdn 子域发多个请求。
  Map<String, Object?> networkPayload() {
    final int now = _clock();
    return <String, Object?>{
      'userAgent': kAidokuUserAgent,
      'cookies': <Object?>[
        for (final AidokuCookie cookie in _cookies)
          if (!cookie.isExpiredAt(now)) cookie.toJson(),
      ],
    };
  }

  Future<void> _persist() async {
    final File target = _file ??= await _resolveFile();
    await target.parent.create(recursive: true);
    final File staged = File('${target.path}.tmp');
    await staged.writeAsString(
      jsonEncode(
        _cookies.map((AidokuCookie cookie) => cookie.toJson()).toList(),
      ),
      flush: true,
    );
    await staged.rename(target.path);
  }
}
