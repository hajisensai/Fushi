import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

import 'package:fushi/src/media/manga/mihon/mihon_bridge_runtime.dart';
import 'package:fushi/src/media/manga/mihon/mihon_child_process_containment.dart';
import 'package:fushi/src/media/manga/mihon/mihon_cloudflare_gate.dart';
import 'package:fushi/src/media/manga/cookie/manga_cookie_jar.dart';
import 'package:fushi/src/media/manga/mihon/mihon_cookie_jar.dart';
import 'package:fushi/src/media/manga/mihon/mihon_models.dart';
import 'package:fushi/src/media/manga/mihon/mihon_runtime.dart';
import 'package:fushi/src/media/manga/mihon/mihon_proxy_policy_server.dart';
import 'package:fushi/src/media/manga/mihon/mihon_sidecar_temp_dir.dart';

const Duration kMihonSourceImageHeaderTimeout = Duration(seconds: 90);
const Duration kMihonSourceImageIdleTimeout = Duration(seconds: 90);
const int kMihonSourceImageMaxBytes = 32 * 1024 * 1024;

/// sidecar 回 `409 {"errorKind":"apkUnknown"}`：这个 JVM 进程还没收到该 APK
/// （刚起 / 刚重启）。宿主把 APK 原样上传一次再重发同一个调用（manga-28）。
const String kMihonApkNotRegisteredCode = 'APK_NOT_REGISTERED';

/// 读取漫画源封面时按“无进度”计时，而不是从请求开始固定倒数。
///
/// [Stream.timeout] 会在每个数据块到达后重置计时器，所以慢速但仍在持续返回数据的
/// 图片不会像旧的整请求 45 秒超时那样被中途切断；真正连续 90 秒没有任何数据时
/// 仍会退出。大小上限避免异常扩展让预览封面无限占用内存；[maxBytes] 传 null
/// 表示不设上限（漫画页图沿用原来不限大小的行为）。
Future<Uint8List> readMihonSourceImageBytes(
  Stream<List<int>> stream, {
  Duration idleTimeout = kMihonSourceImageIdleTimeout,
  int? maxBytes = kMihonSourceImageMaxBytes,
}) async {
  final BytesBuilder builder = BytesBuilder(copy: false);
  int length = 0;
  await for (final List<int> chunk in stream.timeout(idleTimeout)) {
    length += chunk.length;
    if (maxBytes != null && length > maxBytes) {
      throw const MihonRuntimeException(
        'IMAGE_TOO_LARGE',
        'Mihon source image exceeds the 32 MiB limit',
      );
    }
    builder.add(chunk);
  }
  return builder.takeBytes();
}

/// 从 sidecar 的本地图片代理取一张漫画页。
///
/// 超时形状与封面相同（BUG-2450 第 4 点）：[headerTimeout] 内要等到响应头，之后按
/// 「连续 [idleTimeout] 没有任何数据」计时。取消仍靠调用方关掉 [client]——关掉
/// 回环连接后 sidecar 那边的转发流随之关闭，上游请求被取消。
///
/// sidecar 边收边转（manga-18b，`streamingImageResponse`）：源站回了响应头，这边
/// 就拿到响应头，之后每个数据块都重置空闲计时，所以慢速但一直在出数据的大图不会
/// 被砍；上游中途断掉或超过 sidecar 的读超时，sidecar 直接断开连接（chunked 没有
/// 结束块），这边立刻报错，不会干等到空闲超时。
Future<Uint8List> fetchMihonPageImageBytes(
  http.Client client,
  Uri url, {
  required Map<String, String> headers,
  Duration headerTimeout = kMihonSourceImageHeaderTimeout,
  Duration idleTimeout = kMihonSourceImageIdleTimeout,
}) async {
  final http.Request request = http.Request('GET', url)
    ..headers.addAll(headers);
  final http.StreamedResponse response = await client
      .send(request)
      .timeout(headerTimeout);
  if (response.statusCode != HttpStatus.ok) {
    throw MihonRuntimeException(
      'IMAGE_HTTP_${response.statusCode}',
      'Mihon image proxy request failed',
    );
  }
  final Uint8List bytes = await readMihonSourceImageBytes(
    response.stream,
    idleTimeout: idleTimeout,
    maxBytes: null,
  );
  if (bytes.isEmpty) {
    throw const MihonRuntimeException(
      'EMPTY_IMAGE',
      'Mihon source returned an empty image',
    );
  }
  return bytes;
}

class DesktopMihonRuntime extends MihonBridgeRuntime
    implements
        CancellableMihonRuntime,
        HostCookieMihonRuntime,
        ChallengeMihonRuntime {
  DesktopMihonRuntime({
    required this.dataDirectory,
    Directory? resourceDirectory,
    http.Client? httpClient,
    MihonCookieJar? cookieJar,
  }) : resourceDirectory = resourceDirectory ?? _defaultResourceDirectory(),
       _processContainment = MihonChildProcessContainment.platform(),
       _http = httpClient ?? http.Client(),
       _cookies = cookieJar ?? MihonCookieJar.shared;

  final Directory dataDirectory;
  final Directory resourceDirectory;
  final http.Client _http;
  final MihonChildProcessContainment _processContainment;

  /// 登录态真值。sidecar 自己的 cookie jar 是进程内存、`_restart()` 即清空，
  /// 所以宿主每次调用都要重新注入（BUG-2425）。
  final MihonCookieJar _cookies;

  @override
  MihonCookieJar get cookieJar => _cookies;

  Process? _process;
  int? _port;
  String? _token;
  _SidecarLogSink? _log;
  Future<void>? _starting;
  bool _disposed = false;
  MihonProxyPolicyServer? _proxyPolicy;

  /// 当前进程退出后删它的 JVM 临时目录（BUG-4914）。[dispose] 要等它：否则
  /// 「dispose 返回」时目录还在删，调用方紧接着删数据目录会和它撞上。
  Future<void>? _tempDirRelease;

  /// APK 路径 → 摘要。只是「这个文件的 sha256 是多少」的缓存，不记「哪个 sidecar
  /// 进程收到过哪些 APK」——那个真值只在 sidecar 手里，未命中由它回 409 说。
  final Map<String, _CachedApk> _apkCache = <String, _CachedApk>{};
  final Map<String, http.Client> _imageClients = <String, http.Client>{};
  int _imageRequestSequence = 0;

  /// 每个页引用是哪个 sidecar 进程发的。页图 URL 是那个进程的
  /// `http://127.0.0.1:<端口>/image/...`，只在它活着时有效；装 / 更新 / 卸任何
  /// 扩展都会 [_restart]，之后旧页表整份作废（BUG-4917）。按进程对象身份比，
  /// 不按端口比：新进程可能恰好拿到同一个临时端口。
  final Expando<Process> _pageIssuer = Expando<Process>('mihonPageIssuer');

  @visibleForTesting
  int? get processId => _process?.pid;

  Uri _uri(String path) {
    final int? port = _port;
    if (port == null) {
      throw const MihonRuntimeException(
        'NOT_STARTED',
        'M-Extension-Server is not running',
      );
    }
    return Uri.parse('http://127.0.0.1:$port$path');
  }

  Map<String, String> get _headers => <String, String>{
    'Authorization': 'Bearer $_token',
    // NanoHTTPD 2.3.1 falls back to US-ASCII when a request content type
    // omits its charset. Mihon manga URLs commonly contain CJK text, so
    // omitting this parameter corrupts those URLs into U+FFFD on the
    // bridge round trip and makes otherwise valid detail pages return 404.
    'Content-Type': 'application/json; charset=utf-8',
  };

  /// [_headers] 再加上 [source] 站点的登录 cookie。
  ///
  /// sidecar 的 `DalvikHandler` 把收到的 `Cookie:` 头解析后灌进该源的 okhttp
  /// jar，域取自 `source.getBaseUrl()`——所以这里必须用**同一个 baseUrl** 挑
  /// cookie，否则注进去的条目域对不上，等于没注。
  ///
  /// 交出的是**整站**的 cookie 连同各自真实的域，而不是「对 baseUrl 生效的那些」：
  /// 宿主并不知道扩展接下来要打哪些子域（日站的登录域 / api 域 / viewer 域常常
  /// 各不相同），按 baseUrl 筛会把只作用在登录子域上的会话 cookie 整个丢掉。域
  /// 匹配由 sidecar 那边的 okhttp jar 按每个实际请求 URL 去做。
  ///
  /// 刻意**不设源的 UA**：本轮桌面端不做 Cloudflare 解题（sidecar 的
  /// `CloudflareInterceptor` 是空壳），没有「clearance 绑定 UA」的约束，改写只会
  /// 平白破坏自设 UA 的源。注意这条**只有在 sidecar 改成读专用头之后才成立**——
  /// 在那之前，`dart:io` 无条件带上的 `User-Agent: Dart/x.y (dart:io)` 会被当成
  /// 源的 UA 全局写下去。将来补解题时，UA 必须与 cookie 一起作为「登录身份」整体
  /// 存取，而不是在这里单独塞一个默认值。
  Future<Map<String, String>> _headersFor(MihonSource? source) async {
    final Map<String, String> headers = _headers;
    final Uri? base = _sourceBaseUri(source);
    if (base == null) return headers;
    await _cookies.ensureLoadedBestEffort();
    final List<MangaCookie> cookies = _cookies.cookiesForSite(base.host);
    if (cookies.isNotEmpty) {
      headers[kMihonCookieHeader] = encodeMihonCookieWire(cookies);
    }
    return headers;
  }

  /// 测试缝：直接跑生产的请求头构造，不必先把 JVM sidecar 拉起来。
  ///
  /// 暴露的是**同一个函数**而不是一份复制品——注入规则一旦在测试里另写一遍，
  /// 两边就能各自正确、合起来还是不发 cookie。
  @visibleForTesting
  Future<Map<String, String>> debugRequestHeaders(MihonSource? source) =>
      _headersFor(source);

  /// 测试缝：同上，跑生产的响应 cookie 吸收。
  @visibleForTesting
  Future<void> debugAbsorbResponseCookies(
    MihonSource? source,
    Map<String, String> responseHeaders,
  ) => _absorbResponseCookies(source, responseHeaders);

  /// 源站 baseUrl；解析不出 host 的源（空串 / 相对地址）当作没有站点。
  static Uri? _sourceBaseUri(MihonSource? source) {
    final String raw = source?.baseUrl.trim() ?? '';
    if (raw.isEmpty) return null;
    final Uri? parsed = Uri.tryParse(raw);
    if (parsed == null || parsed.host.isEmpty) return null;
    return parsed;
  }

  /// 把 sidecar 回传的 `Set-Cookie` 增量并回宿主 jar。
  ///
  /// 少了这一步，登录态只能撑到服务端轮转会话为止：源在响应里换发的新
  /// session cookie 只活在 sidecar 的内存 jar 里，下次 `_restart()` 一清，
  /// 宿主手上还是登录时那份**已经作废**的旧 cookie。
  Future<void> _absorbResponseCookies(
    MihonSource? source,
    Map<String, String> responseHeaders,
  ) async {
    if (_sourceBaseUri(source) == null) return;
    final String? raw = responseHeaders[kMihonSetCookieHeader];
    if (raw == null || raw.isEmpty) return;
    final List<MangaCookie> incoming = decodeMihonCookieWire(raw);
    if (incoming.isEmpty) return;
    try {
      await _cookies.mergeFromRuntime(incoming);
    } on Object {
      // cookie 落盘失败不该把一次成功的源调用变成失败：内存里的新值这一轮仍然
      // 有效，下一次响应会再带一遍。
    }
  }

  @override
  Future<MihonCapabilities> getCapabilities() async {
    await _ensureStarted();
    return _readCapabilities();
  }

  @override
  Future<MihonExtensionInspection> inspectExtension(String apkPath) async {
    final Map<String, Object?> response = await _withApk(
      apkPath,
      (String apkSha256) =>
          _postObject('/inspect', <String, Object?>{'apkSha256': apkSha256}),
    );
    return MihonExtensionInspection.fromJson(response);
  }

  /// 在宿主的浏览器里解 Cloudflare 挑战，把拿到的整站 cookie 写进 [_cookies]。
  ///
  /// 解题页要用 sidecar **实际发出**的 UA 打开被拦的地址（都由 sidecar 随错误报
  /// 回来）：`cf_clearance` 绑定 UA，浏览器换个 UA 拿到的 cookie 交给 sidecar 会
  /// 被 Cloudflare 原地拒掉，表现为「验证完了还是 403」。写进的是同一个 jar 实例，
  /// 下一次调用 [_headersFor] 就会把新 cookie 注入 sidecar，不需要重启子进程。
  @override
  Future<void> solveCloudflare(Uri uri, {String? userAgent}) async {
    final MihonCloudflareResolver? resolver = MihonCloudflareGate.resolver;
    if (resolver == null) {
      throw const MihonRuntimeException(
        'CHALLENGE_UNAVAILABLE',
        'No browser is available to solve the verification',
      );
    }
    final bool solved = await resolver(uri, userAgent ?? '', _cookies);
    if (!solved) {
      throw const MihonRuntimeException(
        'CHALLENGE_CANCELLED',
        'Website verification was cancelled',
      );
    }
  }

  @override
  Future<String> installPrivateExtension(String apkPath) async => apkPath;

  @override
  Future<void> uninstallPrivateExtension(String packageName) async {
    await invalidateExtension(packageName);
  }

  @override
  Future<Object?> invokeBridge(
    MihonExtensionRef extension,
    String method,
    Map<String, Object?> arguments, {
    MihonSource? source,
  }) async {
    return _withApk(
      extension.apkPath,
      (String apkSha256) => _postJson('/dalvik', <String, Object?>{
        'apkSha256': apkSha256,
        'method': method,
        ...arguments,
      }, source: source),
    );
  }

  @override
  Future<List<MihonPage>> getPages(
    MihonExtensionRef extension,
    MihonSource source,
    MihonChapter chapter, {
    List<MihonPreference> preferences = const <MihonPreference>[],
  }) async {
    final List<MihonPage> pages = await super.getPages(
      extension,
      source,
      chapter,
      preferences: preferences,
    );
    // 应答来自此刻的进程：调用途中若发生重启，旧进程已被杀，请求只会失败。
    final Process? issuer = _process;
    if (issuer != null) {
      for (final MihonPage page in pages) {
        _pageIssuer[page] = issuer;
      }
    }
    return pages;
  }

  @override
  Future<Uint8List> fetchImage(
    MihonExtensionRef extension,
    MihonSource source,
    MihonPage page, {
    List<MihonPreference> preferences = const <MihonPreference>[],
  }) => fetchImageRequest(
    extension,
    source,
    page,
    requestId: 'direct-${_imageRequestSequence++}',
    preferences: preferences,
  );

  @override
  Future<Uint8List> fetchImageRequest(
    MihonExtensionRef extension,
    MihonSource source,
    MihonPage page, {
    required String requestId,
    List<MihonPreference> preferences = const <MihonPreference>[],
  }) async {
    await _ensureStarted();
    final Process? issuer = _pageIssuer[page];
    if (issuer != null && !identical(issuer, _process)) {
      throw const MihonRuntimeException(
        kMihonStalePageReferenceCode,
        'The page list was issued by an M-Extension-Server process that has '
        'since restarted',
      );
    }
    final Uri requested = Uri.parse(page.resolvedUrl);
    final int? port = _port;
    if (requested.scheme != 'http' ||
        requested.host != '127.0.0.1' ||
        requested.port != port ||
        !requested.path.startsWith('/image/')) {
      throw const MihonRuntimeException(
        'INVALID_IMAGE_URL',
        'Mihon bridge returned an image URL outside its authenticated proxy',
      );
    }
    final http.Client imageClient = http.Client();
    final http.Client? replaced = _imageClients[requestId];
    replaced?.close();
    _imageClients[requestId] = imageClient;
    try {
      return await fetchMihonPageImageBytes(
        imageClient,
        requested,
        headers: _headers,
      );
    } finally {
      if (identical(_imageClients[requestId], imageClient)) {
        _imageClients.remove(requestId);
      }
      imageClient.close();
    }
  }

  @override
  Future<void> cancelImageRequests(Iterable<String> requestIds) async {
    for (final String requestId in requestIds) {
      _imageClients.remove(requestId)?.close();
    }
  }

  @override
  Future<Uint8List> fetchSourceImage(
    MihonExtensionRef extension,
    MihonSource source,
    String url, {
    List<MihonPreference> preferences = const <MihonPreference>[],
  }) async {
    return _withApk(
      extension.apkPath,
      (String apkSha256) =>
          _fetchSourceImage(apkSha256, source, url, preferences),
    );
  }

  Future<Uint8List> _fetchSourceImage(
    String apkSha256,
    MihonSource source,
    String url,
    List<MihonPreference> preferences,
  ) async {
    await _ensureStarted();
    final http.Request request = http.Request('POST', _uri('/source-image'))
      ..headers.addAll(await _headersFor(source))
      ..body = jsonEncode(<String, Object?>{
        'apkSha256': apkSha256,
        'sourceId': source.id,
        'url': url,
        'preferences': mihonBridgePreferences(source, preferences),
      });
    final http.StreamedResponse response = await _http
        .send(request)
        .timeout(kMihonSourceImageHeaderTimeout);
    // 封面/图片请求往往比 `/dalvik` 更频繁，先撞上会话续期的通常正是它们；
    // 只注入不回收，等于把这条链路上换发的新 cookie 全丢掉。
    await _absorbResponseCookies(source, response.headers);
    if (response.statusCode != HttpStatus.ok) {
      // 错误体是 sidecar 自己写的一小段 JSON；要读出来才分得清「APK 没上传」。
      final String body = await response.stream.bytesToString().timeout(
        kMihonSourceImageIdleTimeout,
      );
      if (_isApkUnknown(body)) {
        throw const MihonRuntimeException(
          kMihonApkNotRegisteredCode,
          'M-Extension-Server has not received this extension APK yet',
        );
      }
      throw MihonRuntimeException(
        'IMAGE_HTTP_${response.statusCode}',
        'Mihon source image request failed',
      );
    }
    final Uint8List bytes = await readMihonSourceImageBytes(response.stream);
    if (bytes.isEmpty) {
      throw const MihonRuntimeException(
        'EMPTY_IMAGE',
        'Mihon source returned an empty image',
      );
    }
    return bytes;
  }

  static bool _isApkUnknown(String body) {
    try {
      final Object? decoded = jsonDecode(body);
      return decoded is Map<Object?, Object?> &&
          decoded['errorKind'] == _kApkUnknownKind;
    } on FormatException {
      return false;
    }
  }

  @override
  Future<void> clearSourceData(
    MihonExtensionRef extension,
    MihonSource source,
  ) async {
    await _withApk(
      extension.apkPath,
      (String apkSha256) => _postObject('/source-data/clear', <String, Object?>{
        'apkSha256': apkSha256,
        'sourceId': source.id,
      }, source: source),
    );
    // sidecar 侧 `SourceDataHandler` 清的是它自己那份内存 jar。宿主手上还留着
    // 真值，不一起清的话「清除源数据」清完立刻又被下一次请求原样注回去——用户
    // 看到的就是「登出按了没反应」。
    final Uri? base = _sourceBaseUri(source);
    if (base != null) {
      try {
        await _cookies.clearForHost(base.host);
      } on Object {
        // 清不动文件不该让「清除源数据」整体失败：服务端那份已经清了。
      }
    }
    await _restart();
  }

  @override
  Future<void> invalidateExtension(String packageName) =>
      invalidateExtensions(<String>[packageName]);

  @override
  Future<void> invalidateExtensions(Iterable<String> packageNames) async {
    final Set<String> names = packageNames.toSet();
    if (names.isEmpty) return;
    _apkCache.removeWhere(
      (String path, _CachedApk value) =>
          names.contains(p.basenameWithoutExtension(path)),
    );
    // 一次重启覆盖整批：sidecar 重启后所有扩展都会被重新加载，逐个重启没有额外
    // 效果，只有额外代价。
    await _restart();
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    final _SidecarLogSink? log = _log;
    try {
      if (_process != null && _port != null) {
        await _http
            .post(_uri('/stop'), headers: _headers)
            .timeout(const Duration(milliseconds: 600));
      }
    } catch (_) {
      // Process identity is retained below; a failed graceful stop never causes
      // a port/PID scan or termination of unrelated processes.
    }
    try {
      final Process? process = _process;
      if (process != null) {
        try {
          await process.exitCode.timeout(const Duration(milliseconds: 700));
        } on TimeoutException {
          process.kill();
          try {
            await process.exitCode.timeout(const Duration(milliseconds: 500));
          } on TimeoutException {
            // Closing the Windows Job Object below is the final exact-process
            // backstop. The app-level exit barrier must remain bounded.
          }
        }
      }
    } finally {
      _processContainment.close();
    }
    final Future<void>? tempDirRelease = _tempDirRelease;
    _tempDirRelease = null;
    if (tempDirRelease != null) {
      try {
        // 进程已退出（或刚被 Job Object 收掉）时只剩几次删文件；仍设上限，
        // 退出屏障不能被删不动的文件拖住（那种目录留给下次启动清扫）。
        await tempDirRelease.timeout(const Duration(seconds: 2));
      } on TimeoutException {
        // 见上。
      }
    }
    _process = null;
    _port = null;
    _token = null;
    _apkCache.clear();
    for (final http.Client client in _imageClients.values) {
      client.close();
    }
    _imageClients.clear();
    _http.close();
    await log?.close();
    await _proxyPolicy?.close();
    _proxyPolicy = null;
  }

  Future<void> _ensureStarted() async {
    if (_disposed) {
      throw const MihonRuntimeException(
        'DISPOSED',
        'Mihon runtime has been disposed',
      );
    }
    if (_process != null && _port != null) return;
    final Future<void>? current = _starting;
    if (current != null) return current;
    final Future<void> start = _start();
    _starting = start;
    try {
      await start;
    } finally {
      if (identical(_starting, start)) _starting = null;
    }
  }

  Future<void> _start() async {
    final File java = File(_javaExecutablePath());
    final File server = File(
      p.join(resourceDirectory.path, 'm-extension-server.jar'),
    );
    if (!java.existsSync() || !server.existsSync()) {
      throw MihonRuntimeException(
        'RUNTIME_MISSING',
        'Bundled Java/M-Extension-Server is missing from '
            '${resourceDirectory.path}',
      );
    }
    await dataDirectory.create(recursive: true);
    final Directory preferences = Directory(
      p.join(dataDirectory.path, 'preferences'),
    );
    await preferences.create(recursive: true);
    final Random random = Random.secure();
    final String token = base64UrlEncode(
      List<int>.generate(32, (_) => random.nextInt(256)),
    ).replaceAll('=', '');
    await _proxyPolicy?.close();
    final MihonProxyPolicyServer proxyPolicy =
        await MihonProxyPolicyServer.start(token);
    _proxyPolicy = proxyPolicy;
    // JVM 的临时目录归宿主管、随这个进程退出删掉（BUG-4914）：上传的扩展 APK、解出的
    // 扩展 jar（强杀后会残留）都在这里，以前落在系统临时目录里永不回收。
    final MihonSidecarTempDir tempDir = await MihonSidecarTempDir.create(
      dataDirectory,
    );
    final Process process;
    try {
      process = await Process.start(
        java.path,
        <String>[
          '-Xmx512m',
          '-Djava.awt.headless=true',
          '-Djava.util.prefs.userRoot=${preferences.path}',
          '-Djava.io.tmpdir=${tempDir.directory.path}',
          '-jar',
          server.path,
          // 0 = "bind an ephemeral port yourself and tell us which one".
          // Picking the port here (bind → read → close → hand the number over)
          // is a TOCTOU: between our close and the child's bind any other local
          // process can take that port, and we would then hand our per-process
          // Bearer token to a stranger. It also made a benign port collision
          // fail the whole start with START_TIMEOUT.
          '0',
          dataDirectory.path,
        ],
        environment: <String, String>{
          'FUSHI_MIHON_TOKEN': token,
          'FUSHI_MIHON_PROXY_POLICY_PORT': '${proxyPolicy.port}',
        },
        mode: ProcessStartMode.normal,
      );
    } catch (_) {
      await tempDir.release();
      rethrow;
    }
    // 进程真退出了（含下面各条启动失败路径里的 kill）才删：Windows 上 JVM 还开着的
    // 文件删不掉。宿主自己被强杀时这里不会跑，留给下一次启动的清扫。
    _tempDirRelease = process.exitCode.then((int _) => tempDir.release());
    if (_disposed) {
      process.kill();
      try {
        await process.exitCode.timeout(const Duration(seconds: 1));
      } on TimeoutException {
        // Process identity is exact; the runtime is already shutting down.
      }
      throw const MihonRuntimeException(
        'DISPOSED',
        'Mihon runtime was disposed while the sidecar was starting',
      );
    }
    try {
      _processContainment.attach(process.pid);
    } catch (error) {
      process.kill();
      try {
        await process.exitCode.timeout(const Duration(seconds: 1));
      } on TimeoutException {
        // This is still the exact retained child. Startup fails rather than
        // allowing an uncontained JVM to outlive Fushi.
      }
      throw MihonRuntimeException(
        'PROCESS_CONTAINMENT_FAILED',
        'Failed to contain the Mihon sidecar process',
        cause: error,
      );
    }
    _process = process;
    _token = token;

    // The child prints its real listening port once NanoHTTPD has bound it.
    // `null` means "it will never arrive" (the process is gone).
    final Completer<int?> announced = Completer<int?>();
    // 扩展加载失败的**唯一**完整证据（哪个扩展的哪个方法、什么异常）是 sidecar 经
    // logback 打到 stdout 的 Java 栈。此前这两条流一个在 ready 行之后被丢弃、一个
    // 被整段扔空，栈随进程退出永久消失，桌面端只剩 UI 上一行没有出处的错误文本。
    // 落盘到数据目录，跟随用户自定义数据根。
    final _SidecarLogSink log = await _SidecarLogSink.open(dataDirectory);
    _log = log;
    // Never cancelled: stdout has to keep being drained or the pipe fills up
    // and blocks the JVM.
    process.stdout
        .transform(const Utf8Decoder(allowMalformed: true))
        .transform(const LineSplitter())
        .listen((String line) {
          log.write(line);
          if (announced.isCompleted) return;
          final int? port = _parseReadyPort(line);
          if (port != null) announced.complete(port);
        });
    process.stderr
        .transform(const Utf8Decoder(allowMalformed: true))
        .transform(const LineSplitter())
        .listen(log.write);
    unawaited(
      process.exitCode.then((int _) {
        unawaited(proxyPolicy.close());
        if (identical(_proxyPolicy, proxyPolicy)) _proxyPolicy = null;
        if (!announced.isCompleted) announced.complete(null);
        if (identical(_process, process)) {
          _process = null;
          _port = null;
          _token = null;
        }
        if (identical(_log, log)) _log = null;
        unawaited(log.close());
      }),
    );

    final DateTime deadline = DateTime.now().add(const Duration(seconds: 20));
    final int? readyPort = await announced.future.timeout(
      const Duration(seconds: 20),
      onTimeout: () => null,
    );
    if (readyPort == null || readyPort <= 0) {
      process.kill();
      _process = null;
      _port = null;
      _token = null;
      throw const MihonRuntimeException(
        'START_TIMEOUT',
        'M-Extension-Server did not report a listening port',
      );
    }
    // Only now is a port known to be held by *this* child, so only now may the
    // per-process Bearer token leave the app.
    _port = readyPort;

    Object? lastError;
    while (DateTime.now().isBefore(deadline)) {
      // Liveness is checked before the request, not after it fails: a dead
      // child must not be sent another authenticated request first.
      if (await _hasExited(process)) break;
      try {
        final MihonCapabilities capabilities = await _readCapabilities();
        if (!capabilities.isUsable) {
          throw const MihonRuntimeException(
            'INCOMPATIBLE_BRIDGE',
            'Bundled M-Extension-Server lacks required Mihon capabilities',
          );
        }
        return;
      } catch (error) {
        lastError = error;
        await Future<void>.delayed(const Duration(milliseconds: 200));
      }
    }
    process.kill();
    _process = null;
    _port = null;
    _token = null;
    throw MihonRuntimeException(
      'START_TIMEOUT',
      'M-Extension-Server did not become ready',
      cause: lastError,
    );
  }

  /// Readiness contract with the sidecar; mirrors
  /// `MExtensionServerController.READY_LINE_PREFIX`.
  static const String _readyLinePrefix = 'FUSHI_MIHON_READY port=';

  /// Extracts the announced port from one stdout line, or `null` if the line
  /// is ordinary log output.
  ///
  /// The child shares stdout with logback, so the marker is located rather
  /// than assumed to start the line.
  static int? _parseReadyPort(String line) {
    final int marker = line.indexOf(_readyLinePrefix);
    if (marker < 0) return null;
    final String tail = line.substring(marker + _readyLinePrefix.length);
    final Match? digits = RegExp(r'^\d+').matchAsPrefix(tail);
    if (digits == null) return null;
    final int? port = int.tryParse(digits.group(0)!);
    if (port == null || port <= 0 || port > 65535) return null;
    return port;
  }

  /// 把 sidecar 错误响应里的异常类型与 Java 栈拼成 `details`。
  ///
  /// 旧 sidecar 只回 `{error, code}`；两个字段都缺就返回 null，让详情对话框保持
  /// 原来的降级行为，而不是显示一段空标题。
  static String? _errorDetails(Map<Object?, Object?>? error) {
    if (error == null) return null;
    final String type = error['errorType']?.toString().trim() ?? '';
    final String stack = error['stackTrace']?.toString().trimRight() ?? '';
    if (type.isEmpty && stack.isEmpty) return null;
    if (stack.isEmpty) return type;
    // 栈首行通常已含异常类型；重复时不再前缀一遍。
    if (type.isEmpty || stack.startsWith(type)) return stack;
    return '$type\n$stack';
  }

  /// Decode the bridge envelope without confusing source HTTP failures with
  /// transport failures. Older sidecars expose the source code via HttpException.
  static MihonRuntimeException decodeErrorResponse(http.Response response) {
    Object? decoded;
    try {
      decoded = jsonDecode(response.body);
    } on FormatException {
      // Non-JSON gateway responses still have a meaningful transport status.
    }
    final Map<Object?, Object?> error = decoded is Map<Object?, Object?>
        ? decoded
        : const <Object?, Object?>{};
    final Object? kind = error['errorKind'];
    if (kind == _kApkUnknownKind) {
      return MihonRuntimeException(
        kMihonApkNotRegisteredCode,
        error['error']?.toString() ??
            'M-Extension-Server has not received this extension APK yet',
      );
    }
    // sidecar 的 CloudflareInterceptor 认出了拦截页：把被拦 URL 与实际发出的 UA
    // 原样带上，解题页要用同一个 UA 打开同一个地址，cf_clearance 才对得上。
    if (kind == 'cloudflare') {
      final Uri? challengeUrl = Uri.tryParse(
        error['challengeUrl']?.toString() ?? '',
      );
      if (challengeUrl != null &&
          challengeUrl.host.isNotEmpty &&
          (challengeUrl.scheme == 'http' || challengeUrl.scheme == 'https')) {
        final String? userAgent = error['userAgent']?.toString();
        return MihonCloudflareChallengeException(
          challengeUrl,
          userAgent: userAgent == null || userAgent.isEmpty ? null : userAgent,
          details: _errorDetails(error),
        );
      }
    }
    final Object? sourceCode = kind == 'sourceHttp'
        ? error['sourceStatusCode']
        : kind == null &&
              error['errorType'] == 'eu.kanade.tachiyomi.network.HttpException'
        ? error['code']
        : null;
    final int? sourceStatus =
        sourceCode is int && sourceCode >= 400 && sourceCode <= 599
        ? sourceCode
        : null;
    return MihonRuntimeException(
      sourceStatus == null
          ? 'BRIDGE_HTTP_${response.statusCode}'
          : 'SOURCE_HTTP_$sourceStatus',
      sourceStatus == null
          ? error['error']?.toString() ?? 'Mihon bridge request failed'
          : 'Manga source returned HTTP $sourceStatus',
      details: _errorDetails(error),
    );
  }

  Future<MihonCapabilities> _readCapabilities() async {
    final http.Response response = await _http
        .get(_uri('/capabilities'), headers: _headers)
        .timeout(const Duration(seconds: 2));
    if (response.statusCode != HttpStatus.ok) {
      throw MihonRuntimeException(
        'CAPABILITIES_HTTP_${response.statusCode}',
        'M-Extension-Server capabilities request failed',
      );
    }
    final Map<String, Object?> payload =
        (jsonDecode(response.body) as Map<Object?, Object?>)
            .cast<String, Object?>();
    if (payload['hostProxyPolicy'] != true) {
      throw const MihonRuntimeException(
        'INCOMPATIBLE_BRIDGE',
        'Bundled M-Extension-Server lacks host proxy policy support',
      );
    }
    // 调用只带 APK 摘要（manga-28）；不认 `PUT /apk/<摘要>` 的旧 sidecar 会把每个
    // 调用都当成缺参数，宁可在启动时就说清楚。
    if (payload['apkByDigest'] != true) {
      throw const MihonRuntimeException(
        'INCOMPATIBLE_BRIDGE',
        'Bundled M-Extension-Server lacks APK-by-digest support',
      );
    }
    return MihonCapabilities.fromJson(payload);
  }

  Future<Map<String, Object?>> _postObject(
    String path,
    Map<String, Object?> body, {
    MihonSource? source,
  }) async {
    final Object? response = await _postJson(path, body, source: source);
    if (response is! Map<Object?, Object?>) {
      throw MihonRuntimeException(
        'INVALID_RESPONSE',
        '$path returned ${response.runtimeType}, expected an object',
      );
    }
    return response.cast<String, Object?>();
  }

  Future<Object?> _postJson(
    String path,
    Map<String, Object?> body, {
    MihonSource? source,
  }) async {
    await _ensureStarted();
    try {
      final http.Response response = await _http
          .post(
            _uri(path),
            headers: await _headersFor(source),
            body: jsonEncode(body),
          )
          .timeout(kMihonBridgeRequestTimeout);
      // 先吸收 cookie 再判状态码：源返回 403 往往正是「会话过期并换发了新
      // cookie」那一刻，此时丢掉回传的增量会让下一次重试继续用作废的旧值。
      await _absorbResponseCookies(source, response.headers);
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw decodeErrorResponse(response);
      }
      return response.body.isEmpty ? null : jsonDecode(response.body);
    } on MihonRuntimeException {
      rethrow;
    } on TimeoutException catch (error) {
      // A slow source is not evidence that the shared JVM has died. Killing it
      // here aborts every concurrent source search and silently replays actions.
      throw MihonRuntimeException(
        'BRIDGE_TIMEOUT',
        'Mihon source request timed out',
        cause: error,
      );
    } on Object catch (error) {
      throw MihonRuntimeException(
        'BRIDGE_IO',
        'M-Extension-Server request failed',
        cause: error,
      );
    }
  }

  Future<void> _restart() async {
    final Process? process = _process;
    _process = null;
    _port = null;
    _token = null;
    if (process != null) {
      process.kill();
      try {
        await process.exitCode.timeout(const Duration(seconds: 2));
      } on TimeoutException {
        // The retained Process object is the only identity we ever terminate.
      }
    }
  }

  /// 以 APK 摘要发一次调用（manga-28）。
  ///
  /// 以前每个调用都把整个 APK 的 base64 塞进请求体；现在调用只带 sha256，APK 本体
  /// 每个 sidecar 进程只经 `PUT /apk/<摘要>` 传一次。sidecar 回「没见过这个摘要」
  /// （新起的进程、装 / 卸扩展后的重启）时上传一次再重发：那一次调用在加载扩展
  /// 之前就失败了，扩展代码一行没跑，重发不会重放任何动作。上传后仍说没见过就是
  /// 真错，原样抛出，不再循环。
  Future<T> _withApk<T>(
    String apkPath,
    Future<T> Function(String apkSha256) call,
  ) async {
    final String apkSha256 = await _apkDigest(apkPath);
    try {
      return await call(apkSha256);
    } on MihonRuntimeException catch (error) {
      if (error.code != kMihonApkNotRegisteredCode) rethrow;
    }
    return call(await _uploadApk(apkPath));
  }

  Future<FileStat> _apkStat(String apkPath) async {
    final FileStat stat = await File(apkPath).stat();
    if (stat.type != FileSystemEntityType.file) {
      throw MihonRuntimeException(
        'APK_MISSING',
        'Extension APK does not exist: $apkPath',
      );
    }
    return stat;
  }

  Future<String> _apkDigest(String apkPath) async {
    final FileStat stat = await _apkStat(apkPath);
    final _CachedApk? cached = _apkCache[apkPath];
    if (cached != null &&
        cached.modifiedAt == stat.modified &&
        cached.size == stat.size) {
      return cached.sha256;
    }
    final Digest digest = await sha256.bind(File(apkPath).openRead()).first;
    final String hex = digest.toString();
    _apkCache[apkPath] = _CachedApk(
      modifiedAt: stat.modified,
      size: stat.size,
      sha256: hex,
    );
    return hex;
  }

  /// 把 APK 原样（不是 base64）传给当前 sidecar 进程，返回实际上传内容的摘要。
  ///
  /// 摘要按这次读到的字节重算：文件若在上次算摘要之后被换掉，重发用的是新摘要，
  /// 不会拿旧摘要配新内容（sidecar 也会校验，对不上直接拒收）。
  Future<String> _uploadApk(String apkPath) async {
    final FileStat stat = await _apkStat(apkPath);
    final Uint8List bytes = await File(apkPath).readAsBytes();
    final String apkSha256 = sha256.convert(bytes).toString();
    _apkCache[apkPath] = _CachedApk(
      modifiedAt: stat.modified,
      size: stat.size,
      sha256: apkSha256,
    );
    await _ensureStarted();
    try {
      final http.Response response = await _http
          .put(
            _uri('/apk/$apkSha256'),
            headers: <String, String>{
              'Authorization': 'Bearer $_token',
              'Content-Type': 'application/vnd.android.package-archive',
            },
            body: bytes,
          )
          .timeout(kMihonBridgeRequestTimeout);
      if (response.statusCode != HttpStatus.ok) {
        throw decodeErrorResponse(response);
      }
    } on MihonRuntimeException {
      rethrow;
    } on TimeoutException catch (error) {
      throw MihonRuntimeException(
        'BRIDGE_TIMEOUT',
        'Uploading the extension APK timed out',
        cause: error,
      );
    } on Object catch (error) {
      throw MihonRuntimeException(
        'BRIDGE_IO',
        'Uploading the extension APK failed',
        cause: error,
      );
    }
    return apkSha256;
  }

  String _javaExecutablePath() {
    // macOS 版只出 Apple Silicon（arm64），bundle 里只有这一份 JVM 镜像
    // （tool/mihon/build_desktop_runtime.sh）；Intel Mac 不再支持。
    final String runtimeName = Platform.isMacOS
        ? 'runtime-macos-arm64'
        : 'runtime';
    return p.join(
      resourceDirectory.path,
      runtimeName,
      'bin',
      Platform.isWindows ? 'java.exe' : 'java',
    );
  }

  static Future<bool> _hasExited(Process process) async {
    try {
      await process.exitCode.timeout(const Duration(milliseconds: 1));
      return true;
    } on TimeoutException {
      return false;
    }
  }

  static Directory _defaultResourceDirectory() {
    final Directory executable = File(Platform.resolvedExecutable).parent;
    if (Platform.isMacOS) {
      return Directory(
        p.normalize(p.join(executable.path, '..', 'Resources', 'mihon_bridge')),
      );
    }
    return Directory(p.join(executable.path, 'mihon_bridge'));
  }
}

const String _kApkUnknownKind = 'apkUnknown';

class _CachedApk {
  const _CachedApk({
    required this.modifiedAt,
    required this.size,
    required this.sha256,
  });

  final DateTime modifiedAt;
  final int size;
  final String sha256;
}

/// sidecar 的 stdout/stderr 落盘。
///
/// 扩展加载类错误（NoSuchMethodError / InstantiationError / ClassCastException）
/// 的完整 Java 栈只存在于 sidecar 进程的 stdout（logback 的 ConsoleAppender；上游
/// 那个会写 RollingFile 的 `initLoggerConfig` 从来没有调用点）。这两条流以前一条
/// 在 ready 行之后被丢弃、一条被整段扔空，栈随进程退出即消失，桌面端因此完全无法
/// 自证根因。
///
/// 有意保持极简：单文件 + 满了轮转一份 `.1`。它是诊断证据而不是可靠日志系统，
/// 任何写入异常都必须被吞掉——日志坏了绝不能连累漫画源可用。
class _SidecarLogSink {
  _SidecarLogSink._(this._file, this._backup, this._sink, this._written);

  /// 单文件上限；超过就轮转。两份合计最多 ~4 MiB。
  static const int _maxBytes = 2 * 1024 * 1024;

  final File _file;
  final File _backup;
  IOSink? _sink;
  int _written;
  bool _closed = false;
  Future<void>? _closing;

  static Future<_SidecarLogSink> open(Directory dataDirectory) async {
    final Directory logs = Directory(p.join(dataDirectory.path, 'logs'));
    final File file = File(p.join(logs.path, 'sidecar.log'));
    final File backup = File(p.join(logs.path, 'sidecar.log.1'));
    try {
      await logs.create(recursive: true);
      final int existing = await file.exists() ? await file.length() : 0;
      return _SidecarLogSink._(
        file,
        backup,
        file.openWrite(mode: FileMode.append),
        existing,
      );
    } on Object {
      // 只读数据目录、磁盘满、路径被占用——一律降级成「不记日志」。
      return _SidecarLogSink._(file, backup, null, 0);
    }
  }

  void write(String line) {
    final IOSink? sink = _sink;
    if (_closed || sink == null) return;
    try {
      sink.writeln(line);
      _written += line.length + 1;
      if (_written >= _maxBytes) unawaited(_rotate());
    } on Object {
      _sink = null;
    }
  }

  Future<void> _rotate() async {
    final IOSink? sink = _sink;
    if (sink == null) return;
    _sink = null;
    try {
      await sink.flush();
      await sink.close();
      if (await _backup.exists()) await _backup.delete();
      await _file.rename(_backup.path);
      _sink = _file.openWrite(mode: FileMode.write);
      _written = 0;
    } on Object {
      _sink = null;
    }
  }

  Future<void> close() => _closing ??= _close();

  Future<void> _close() async {
    if (_closed) return;
    _closed = true;
    final IOSink? sink = _sink;
    _sink = null;
    if (sink == null) return;
    try {
      await sink.flush();
      await sink.close();
    } on Object {
      // 关闭失败无所谓：进程已经退出，文件由 OS 收尾。
    }
  }
}
