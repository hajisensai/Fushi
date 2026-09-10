import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Cloudflare 放行 cookie 的名字；WebView 里出现它即视为挑战已解。
const String kCloudflareClearanceCookie = 'cf_clearance';

/// 一条按域名作用的 cookie。
///
/// 两个漫画扩展运行时共用这一份：Aidoku（wasm host 在 Rust 里发请求，读不到
/// WebView 的 cookie 存储）与 Mihon 桌面 sidecar（JVM 子进程，okhttp 的 jar 是
/// 进程内存、重启即失）。两边都需要「宿主持有真值、每次调用重新注入」，所以
/// 数据结构与匹配规则只应该有一份。
class MangaCookie {
  const MangaCookie({
    required this.name,
    required this.value,
    required this.domain,
    this.path = '/',
    this.secure = false,
    this.hostOnly = false,
    this.expiresAt,
  });

  factory MangaCookie.fromJson(Map<String, Object?> json) => MangaCookie(
        name: json['name']?.toString() ?? '',
        value: json['value']?.toString() ?? '',
        domain: json['domain']?.toString() ?? '',
        path: json['path']?.toString() ?? '/',
        secure: json['secure'] == true,
        hostOnly: json['hostOnly'] == true,
        expiresAt: (json['expiresAt'] as num?)?.toInt(),
      );

  final String name;
  final String value;

  /// 注册域（可带前导点）。匹配规则同 RFC 6265：host 等于它或以 `.<domain>` 结尾。
  final String domain;
  final String path;
  final bool secure;

  /// 只对 [domain] **这一个** host 生效（浏览器里 `Set-Cookie` 未写 `Domain=`
  /// 属性的那种），不覆盖子域。
  ///
  /// 必须随线格式一起传：okhttp 的 jar 把 `secure` 与 `hostOnly` 算进 cookie 的
  /// **身份**（`WrappedCookie.equals`）。宿主注入的条目若把这两位丢成默认值，
  /// 它与站点自己 `Set-Cookie` 写进去的同名条目就是两条不同的 cookie，谁也覆盖
  /// 不了谁——okhttp 于是把 `session=旧值; session=新值` 一起发出去，取首值的
  /// 服务端拿到的是作废的那个。
  final bool hostOnly;

  /// 过期时刻（毫秒时间戳）；null = 会话 cookie，随文件保留直到被替换。
  final int? expiresAt;

  /// 去掉前导点的规范域，用于匹配与去重。
  String get canonicalDomain => canonicalizeDomain(domain);

  bool get isValid => name.isNotEmpty && canonicalDomain.isNotEmpty;

  bool isExpiredAt(int nowMs) => expiresAt != null && expiresAt! <= nowMs;

  /// 这条 cookie 该不该发给 [host]。
  ///
  /// host-only 的条目只认完全相等；其余按 RFC 6265 的域匹配。
  bool matchesHost(String host) => hostOnly
      ? canonicalizeDomain(host) == canonicalDomain
      : hostMatchesDomain(host, canonicalDomain);

  Map<String, Object?> toJson() => <String, Object?>{
        'name': name,
        'value': value,
        'domain': canonicalDomain,
        'path': path,
        'secure': secure,
        if (hostOnly) 'hostOnly': true,
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

/// 文件持久化的 cookie jar。
///
/// **宿主是 cookie 的唯一所有者**：扩展运行时（Rust wasm host / JVM sidecar）
/// 自己的 cookie 存储一律当成易失缓存，每次调用由宿主重新注入。运行时重启、
/// 子进程被杀、`clearSourceData` 清库都不该让用户重新登录一次。
///
/// 只存扩展源站的 cookie，设备本地、不进同步/备份。
class MangaCookieJar {
  MangaCookieJar(File file, {int Function()? clock})
      : _resolveFile = (() async => file),
        _clock = clock ?? _defaultClock;

  /// 路径延迟解析（共享实例：支持目录要等平台通道就绪）。
  MangaCookieJar.lazy(Future<File> Function() resolveFile,
      {int Function()? clock})
      : _resolveFile = resolveFile,
        _clock = clock ?? _defaultClock;

  static int _defaultClock() => DateTime.now().millisecondsSinceEpoch;

  final Future<File> Function() _resolveFile;
  final int Function() _clock;
  File? _file;
  List<MangaCookie> _cookies = const <MangaCookie>[];
  Future<void>? _loading;

  List<MangaCookie> get cookies => List<MangaCookie>.unmodifiable(_cookies);

  /// 当前时钟读数（毫秒）。子类拼 payload 时要按同一时钟过滤过期条目。
  int get nowMs => _clock();

  /// 失败不记忆：路径解析（平台通道未就绪）或 IO 失败时清掉备忘，下一次调用
  /// 重试——否则一次启动期抖动会把所有扩展调用毒到重启。
  ///
  /// **会抛**：写路径（[replaceForHost] / [clear]）拿不到文件就没法保证写入，
  /// 必须让调用方知道。只读 cookie 的调用方走 [ensureLoadedBestEffort]。
  Future<void> ensureLoaded() =>
      _loading ??= _load().onError((Object error, StackTrace stack) {
        _loading = null;
        Error.throwWithStackTrace(error, stack);
      });

  /// 读路径的加载契约：**cookie 只是增强，加载失败按无 cookie 继续**。
  ///
  /// [_load] 内部只兜住了 `jsonDecode` / `readAsString`；`_resolveFile()`
  /// （支持目录的平台通道未就绪 / 自定义数据根不可达）与 `target.exists()`
  /// 的失败会整个穿出去，把一次本来无 cookie 也能正常完成的搜索炸成
  /// `FileSystemException`。降级判据属于**调用点契约**，写在这里一次，
  /// 而不是在 [_load] 里再多包一层 catch 把写路径也一起吞掉。
  Future<void> ensureLoadedBestEffort() async {
    try {
      await ensureLoaded();
    } on Object {
      // 忽略：`_cookies` 保持空/上一次的快照，调用方按无 cookie 请求。
      // `ensureLoaded` 已经清掉了失败备忘，下一次调用会重试加载。
    }
  }

  Future<void> _load() async {
    final File target = _file ??= await _resolveFile();
    if (!await target.exists()) return;
    try {
      final Object? decoded = jsonDecode(await target.readAsString());
      if (decoded is! List<Object?>) return;
      _cookies = decoded
          .whereType<Map<Object?, Object?>>()
          .map(
            (Map<Object?, Object?> item) =>
                MangaCookie.fromJson(item.cast<String, Object?>()),
          )
          .where((MangaCookie cookie) => cookie.isValid)
          .toList(growable: false);
    } on FormatException {
      // 坏文件 = 没 cookie；下一次写入会覆盖它。
      _cookies = const <MangaCookie>[];
    } on FileSystemException {
      // 读不动的文件（编码坏 / 权限抖动）同样当作没 cookie，不拦调用：
      // cookie 只是增强，拿不到就按无 cookie 请求。
      _cookies = const <MangaCookie>[];
    }
  }

  /// 当前对 [url] 生效（域匹配且未过期）的 cookie。
  List<MangaCookie> cookiesFor(Uri url) {
    final int now = _clock();
    return _cookies
        .where(
          (MangaCookie cookie) =>
              !cookie.isExpiredAt(now) && cookie.matchesHost(url.host),
        )
        .toList(growable: false);
  }

  /// 属于 [host] 这个**站点**的全部 cookie（不论作用在父域还是子域）。
  ///
  /// 与 [cookiesFor] 的区别是刻意的：[cookiesFor] 回答「这条 cookie 该不该发给
  /// 这个 URL」，由**发请求的一方**判断；而把登录态交给扩展运行时的时候，宿主
  /// 并不知道扩展接下来要打哪些子域（日站的登录域、api 域、viewer 域常常各不
  /// 相同），所以要把整站的条目**连同各自真实的域**一起交出去，由对端的 jar 按
  /// 每个实际请求 URL 去匹配。
  ///
  /// 用 [cookiesFor] 代替会静默丢掉子域条目：作用在 `member.example.jp` 的登录
  /// cookie 对 `https://example.jp` 不生效，于是一条都不会被交出去——表现正是
  /// 「登录了但还是锁着」。
  List<MangaCookie> cookiesForSite(String host) {
    final int now = _clock();
    final String site = MangaCookie.canonicalizeDomain(host);
    return _cookies
        .where(
          (MangaCookie cookie) =>
              !cookie.isExpiredAt(now) &&
              (MangaCookie.hostMatchesDomain(site, cookie.canonicalDomain) ||
                  MangaCookie.hostMatchesDomain(cookie.canonicalDomain, site)),
        )
        .toList(growable: false);
  }

  /// `Cookie:` 请求头值；无匹配返回 null。
  String? cookieHeaderFor(Uri url) {
    final List<MangaCookie> matched = cookiesFor(url);
    if (matched.isEmpty) return null;
    return matched
        .map((MangaCookie cookie) => '${cookie.name}=${cookie.value}')
        .join('; ');
  }

  /// 是否已持有对 [url] 生效的 Cloudflare 放行 cookie。
  bool hasClearanceFor(Uri url) => clearanceValueFor(url) != null;

  /// 对 [url] 生效的 `cf_clearance` 的**值**；没有返回 null。调用方用它判断
  /// 「排队解题期间 jar 是否已被别的调用换上新放行 cookie」——值变了直接重试，
  /// 不必再弹解题页。
  String? clearanceValueFor(Uri url) {
    for (final MangaCookie cookie in cookiesFor(url)) {
      if (cookie.name == kCloudflareClearanceCookie) return cookie.value;
    }
    return null;
  }

  /// 用 WebView 导出的整组 cookie **替换**该站点（[host] 所属的全部注册域）
  /// 的旧条目：旧的 `cf_clearance` 已经失效才会走到解题，留着只会让运行时多发
  /// 一个被拒的 cookie。其它站点的条目不动。
  Future<void> replaceForHost(String host, List<MangaCookie> fresh) async {
    await ensureLoaded();
    final int now = _clock();
    final List<MangaCookie> incoming = fresh
        .where(
          (MangaCookie cookie) =>
              cookie.isValid &&
              !cookie.isExpiredAt(now) &&
              MangaCookie.hostMatchesDomain(host, cookie.canonicalDomain),
        )
        .toList(growable: false);
    final Set<String> replacedDomains =
        incoming.map((MangaCookie cookie) => cookie.canonicalDomain).toSet();
    _cookies = <MangaCookie>[
      for (final MangaCookie cookie in _cookies)
        if (!cookie.isExpiredAt(now) &&
            !replacedDomains.contains(cookie.canonicalDomain))
          cookie,
      ...incoming,
    ];
    await _persist();
  }

  /// 用浏览器导出的整组 cookie **替换**整个站点（[host] 的父域与子域全算）的
  /// 旧条目，各自的真实域原样保留。
  ///
  /// 与 [replaceForHost] 的区别：那个只收「域覆盖 host」的条目（Cloudflare 放行
  /// cookie 就是这种），子域条目会被丢掉。登录导出必须连子域一起收——日站的会话
  /// cookie 常常只作用在登录子域上。
  Future<void> replaceForSite(String host, List<MangaCookie> fresh) async {
    await ensureLoaded();
    final int now = _clock();
    final String site = MangaCookie.canonicalizeDomain(host);
    bool belongsToSite(String domain) =>
        MangaCookie.hostMatchesDomain(site, domain) ||
        MangaCookie.hostMatchesDomain(domain, site);

    final List<MangaCookie> incoming = fresh
        .where(
          (MangaCookie cookie) =>
              cookie.isValid &&
              !cookie.isExpiredAt(now) &&
              belongsToSite(cookie.canonicalDomain),
        )
        .toList(growable: false);
    _cookies = <MangaCookie>[
      for (final MangaCookie cookie in _cookies)
        if (!cookie.isExpiredAt(now) && !belongsToSite(cookie.canonicalDomain))
          cookie,
      ...incoming,
    ];
    await _persist();
  }

  /// 合并运行时回传的 `Set-Cookie` 结果：**按 (name, domain) 逐条覆盖**，不动
  /// 其它条目。
  ///
  /// 与 [replaceForHost] 的区别是刻意的、也是必须的：登录页导出的是浏览器的
  /// **完整**站点快照，整站替换才能把失效条目清干净；而运行时回传的只是**这
  /// 一次请求**碰到的增量（会话续期、轮转 token），拿它整站替换会把同站其它
  /// 域的登录 cookie 一起抹掉——那等于每发一次请求就登出一部分。
  ///
  /// 返回是否真的产生了变化：没变就不落盘，避免每个请求都写一次文件。
  Future<bool> mergeFromRuntime(List<MangaCookie> incoming) async {
    await ensureLoaded();
    final int now = _clock();
    final List<MangaCookie> fresh = incoming
        .where(
          (MangaCookie cookie) => cookie.isValid && !cookie.isExpiredAt(now),
        )
        .toList(growable: false);
    if (fresh.isEmpty) return false;

    String keyOf(MangaCookie cookie) =>
        '${cookie.name} ${cookie.canonicalDomain}';

    final Map<String, MangaCookie> merged = <String, MangaCookie>{
      for (final MangaCookie cookie in _cookies)
        if (!cookie.isExpiredAt(now)) keyOf(cookie): cookie,
    };
    final Map<String, MangaCookie> before = Map<String, MangaCookie>.from(
      merged,
    );
    for (final MangaCookie cookie in fresh) {
      merged[keyOf(cookie)] = cookie;
    }
    final bool changed = merged.length != before.length ||
        merged.entries.any(
          (MapEntry<String, MangaCookie> entry) =>
              before[entry.key]?.value != entry.value.value,
        );
    if (!changed) return false;
    _cookies = merged.values.toList(growable: false);
    await _persist();
    return true;
  }

  /// 清掉 [host] 所属注册域的条目（登出单个源）；返回是否有变化。
  Future<bool> clearForHost(String host) async {
    await ensureLoaded();
    final List<MangaCookie> kept = _cookies
        .where((MangaCookie cookie) => !cookie.matchesHost(host))
        .toList(growable: false);
    if (kept.length == _cookies.length) return false;
    _cookies = kept;
    await _persist();
    return true;
  }

  Future<void> clear() async {
    await ensureLoaded();
    _cookies = const <MangaCookie>[];
    await _persist();
  }

  Future<void> _persist() async {
    final File target = _file ??= await _resolveFile();
    await target.parent.create(recursive: true);
    final File staged = File('${target.path}.tmp');
    await staged.writeAsString(
      jsonEncode(
          _cookies.map((MangaCookie cookie) => cookie.toJson()).toList()),
      flush: true,
    );
    await staged.rename(target.path);
  }
}
