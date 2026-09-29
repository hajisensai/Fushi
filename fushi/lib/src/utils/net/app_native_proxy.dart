import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';

import 'package:fushi_engine/sync/tls/fushi_pinning_http.dart';
import 'package:fushi_engine/utils/net/app_http.dart';
import 'package:fushi_engine/utils/net/app_proxy.dart';
import 'package:fushi/src/utils/net/hls_relay_normalizer.dart';

Future<AppNativeProxy>? _sharedProxy;
Future<AppNativeProxy>? _challengeProxy;
final Set<String> _nativeProxySecrets = <String>{};

/// 已登记的「钉扎原点」`host:port → 证书 SHA-256 指纹`。
///
/// 互联 host 用自签证书，信任判据是配对时 TOFU 记下的指纹——只有 Dart 侧知道它。
/// native 播放器自己连 https 时，证书怎么判全看那份 libmpv 怎么编：ffmpeg 的 tls
/// 从不校验（Android 随包 libmpv 仍是它），而 2026-08 起 Windows 随包的 libmpv 改用
/// libcurl 取流、默认校验证书，自签 host 一律 `SSL peer certificate ... was not OK`
/// → 互联视频整个打不开（BUG-2455）。同一条流在两端两种结局，说明信任根本不该放在
/// native 侧。
///
/// 收口：交给 native 的 URL 经 [nativePlaybackUri] 降成**明文 http**（带显式端口），
/// native 照常经本中继取流，[AppNativeProxy._forward] 按 `(host, port)` 查到指纹后
/// 用 [createPinnedHttpClient] 升回 https 连真正的 host。native 无论哪个后端都只
/// 看到 loopback 明文；证书信任只在 Dart 这一处裁决，和 API/字幕/封面通道同一判据。
final Map<String, String> _pinnedNativeOrigins = <String, String>{};

String _pinnedOriginKey(String host, int port) => '${host.toLowerCase()}:$port';

/// 登记一个钉扎原点（互联 backend 每次解析出 https host 时调用，重复登记覆盖）。
void registerPinnedNativeOrigin({
  required String host,
  required int port,
  required String fingerprintSha256,
}) {
  _pinnedNativeOrigins[_pinnedOriginKey(host, port)] = fingerprintSha256;
}

/// 撤销登记：同一 `(host, port)` 改回明文 http（host 关了 TLS、对端重新配对）时必须
/// 调用，否则残留的旧指纹会让中继把 native 的真明文请求硬升成 https 去握手一个
/// 明文端口——API/字幕通道都正常、只有视频 502，直到重启 app。
void unregisterPinnedNativeOrigin({required String host, required int port}) {
  _pinnedNativeOrigins.remove(_pinnedOriginKey(host, port));
}

/// `(host, port)` 已登记的钉扎指纹；未登记返回 null。
String? pinnedNativeOriginFingerprint(String host, int port) =>
    _pinnedNativeOrigins[_pinnedOriginKey(host, port)];

@visibleForTesting
void clearPinnedNativeOriginsForTesting() {
  _pinnedNativeOrigins.clear();
  _tlsNativeOrigins.clear();
}

/// 由中继替 native **终结 TLS** 的 https 原点（`host:port`，系统信任根）。
///
/// 钉扎原点（上面）是「自签证书 + 指纹」的特例；这里是所有其它 https 流（Emby /
/// Jellyfin 远程访问、公网直链……）。为什么普通 https 也不交给 native 自己握手：
///  - macOS / iOS 随包 libmpv（FFmpeg 6.1.6 + Mbed TLS）在 `mbedtls_ssl_handshake`
///    里**段错误**（Mac 崩溃报告 `fushi-2026-09-18-210129.ips`：`*/opener` 线程
///    `demux_open_url → … → ssl_parse_server_hello → ssl_get_next_record`，
///    `KERN_INVALID_ADDRESS`）——用户报「iOS / macOS 播 Emby 直接闪退」就是它；
///  - Android 随包 libmpv 走 ffmpeg tls，**从不校验证书**；
///  - Windows 走 libcurl、自己校验，与 Dart 侧 API 通道的信任判据又是两套。
/// 三端三种结局，说明 TLS 根本不该在 native 侧做。降成明文 http 交给 native，中继
/// 用与 API / 字幕 / 封面同一个 [createAppHttpClient]（系统信任根）升回 https：
/// 登录能过的证书流就一定能过，反之亦然，不再有「API 通、视频 502」的第三种状态。
final Set<String> _tlsNativeOrigins = <String>{};

/// `(host, port)` 是否已登记为「中继终结 TLS」的原点。
bool isTlsNativeOrigin(String host, int port) =>
    _tlsNativeOrigins.contains(_pinnedOriginKey(host, port));

/// 登记一个由中继终结 TLS 的 https 原点（[nativePlaybackUri] 每次降级都会调；
/// 响应里的 `Location` 指向别的 https host 时中继也会替它登记）。
void registerTlsNativeOrigin({required String host, required int port}) {
  _tlsNativeOrigins.add(_pinnedOriginKey(host, port));
}

/// 把要交给 native 播放器 / ffmpeg 的 URL 换成中继能识别的形式。
///
/// 任何 https URL → 同 host、**显式端口**的 http，并把 `(host, port)` 登记给中继：
/// 钉扎原点由中继按指纹升回 https，其余原点按系统信任根升回 https（见
/// [_tlsNativeOrigins]）。非 https（本地文件、明文 http）原样返回；明文 http 同时
/// **撤销**同 `(host, port)` 的 TLS 登记——用户把服务器从 https 改回同端口的 http
/// 时，残留登记会让中继把真明文请求硬升成 https 去握手一个明文端口。
///
/// 端口必须显式：`https://h/x`（隐含 443）降成 `http://h/x` 会变成隐含 80，中继就
/// 查不到登记项。
String nativePlaybackUri(String uri) {
  final Uri? parsed = Uri.tryParse(uri);
  if (parsed == null) return uri;
  if (parsed.isScheme('http')) {
    _tlsNativeOrigins.remove(_pinnedOriginKey(parsed.host, parsed.port));
    return uri;
  }
  if (!parsed.isScheme('https') || parsed.host.isEmpty) return uri;
  if (pinnedNativeOriginFingerprint(parsed.host, parsed.port) == null) {
    registerTlsNativeOrigin(host: parsed.host, port: parsed.port);
  }
  return parsed.replace(scheme: 'http', port: parsed.port).toString();
}

/// 中继连非钉扎上游用的客户端工厂（明文与系统信任根 https 共用）。默认
/// [createAppHttpClient]（代理装配 + 连接超时 + 系统证书信任）；测试用自签原点时
/// 替换成信任测试证书的客户端。
HttpClient Function() appNativeProxyUpstreamClientFactory = () =>
    createAppHttpClient(connectionTimeout: kAppHttpConnectionTimeout);

/// Scrub native diagnostics before forwarding them to application logs/UI.
String redactAppNativeProxySecrets(String value) {
  for (final String secret in _nativeProxySecrets) {
    value = value.replaceAll(secret, '[native-proxy]');
  }
  return value;
}

/// 中继失败原因的落点。默认 [debugPrint]（被 `DebugLogService` 钩住，进得了
/// 「调试日志」页和上传的报错日志）；测试可替换。
///
/// 为什么必须有这个出口：中继对上只能回一个裸 502——native 客户端读不到响应体，
/// reqwest/hyper 把任何非 200 的 CONNECT 结果一律收敛成一个词 `unsuccessful`。
/// 于是「域名解析不了 / TCP 被拒 / 上游代理拒绝 CONNECT / 20 秒连接超时」四种
/// 完全不同的故障，在 Rust 侧长得一模一样。中继这边是唯一知道真实原因的地方，
/// 以前 `_serve` 的 catch-all 把它连同异常一起丢掉，两层各抹一半，最终用户只
/// 看到 `error sending request`（BUG-2381）。
void Function(String message) appNativeProxyLogSink = debugPrint;

/// Native HTTP engines cannot call Dart's per-URL proxy resolver. A loopback
/// forward proxy keeps redirects, HLS segments and later requests on that same
/// policy. The random local credential is unrelated to upstream credentials.
/// Keep this endpoint private: it authorizes access to the local relay.
Future<AppNativeProxy> ensureAppNativeProxy() =>
    _liveProxy(_sharedProxy, (Future<AppNativeProxy> started) {
      _sharedProxy = started;
    }, publicTargetsOnly: false);

Future<Uri> ensureAppNativeProxyEndpoint() async =>
    (await ensureAppNativeProxy()).endpoint;

/// Challenge JavaScript must not reach local origin servers, including through
/// service workers or WebSockets that skip WebView navigation callbacks.
Future<AppNativeProxy> ensureAppChallengeProxy() =>
    _liveProxy(_challengeProxy, (Future<AppNativeProxy> started) {
      _challengeProxy = started;
    }, publicTargetsOnly: true);

Future<Uri> ensureAppChallengeProxyEndpoint() async =>
    (await ensureAppChallengeProxy()).endpoint;

/// 缓存的中继**必须先验活再交出去**。
///
/// 这两个入口以前是 `??=`：一旦 Future 落定就是终身答案。两种情况因此变成
/// 「一次坏、永久坏，只能重启 app」——① 监听 socket 被系统回收（iOS 把 app
/// 挂起后就可能收走监听 socket，恢复后端口还在缓存里，native 客户端每次都撞
/// connection refused）；② 首次 `bind` 失败，那个**已失败**的 Future 被永久
/// 缓存，后面每次调用都重抛同一个旧异常，连重试的机会都没有（BUG-2381）。
///
/// 新 Future 在 await 之前就写回缓存，并发调用因此仍然只启一个中继。
Future<AppNativeProxy> _liveProxy(
  Future<AppNativeProxy>? cached,
  void Function(Future<AppNativeProxy> started) store, {
  required bool publicTargetsOnly,
}) async {
  if (cached != null) {
    try {
      final AppNativeProxy proxy = await cached;
      if (proxy.isRunning) return proxy;
    } on Object catch (error) {
      appNativeProxyLogSink(
        redactAppNativeProxySecrets('native proxy: restarting after $error'),
      );
    }
  }
  final Future<AppNativeProxy> started = AppNativeProxy.start(
    publicTargetsOnly: publicTargetsOnly,
  );
  store(started);
  return started;
}

/// Proxy environment for a native child. Clear inherited bypass rules because
/// the relay applies the application's rules separately to every destination.
Map<String, String> appNativeProxyEnvironment(Uri endpoint) => <String, String>{
  for (final String key in <String>[
    'HTTP_PROXY',
    'HTTPS_PROXY',
    'ALL_PROXY',
    'http_proxy',
    'https_proxy',
    'all_proxy',
  ])
    key: endpoint.toString(),
  'NO_PROXY': '',
  'no_proxy': '',
};

class AppNativeProxy {
  AppNativeProxy._(this._server, this._secret, this._publicTargetsOnly);

  final HttpServer _server;
  final String _secret;
  final bool _publicTargetsOnly;
  final Set<Socket> _sockets = <Socket>{};

  /// 钉扎原点的客户端按 `(host, port, 指纹)` 缓存复用：libmpv 取流是一串 Range /
  /// seek / 缓存回填请求，每个都新建客户端就是每个都重新 TCP + TLS 握手（旧 CONNECT
  /// 隧道时代 curl 只握一次）。复用同一客户端才有 keep-alive 连接池。指纹换了
  /// （重新配对）就换客户端、关旧的。
  final Map<String, HttpClient> _pinnedClients = <String, HttpClient>{};

  /// 非钉扎上游的客户端按 `scheme://host:port` 复用（明文 http 与系统信任根 https
  /// 各一份）。此前非钉扎分支是「一请求一客户端 + `close(force: true)`」：libmpv
  /// 取流是一串 Range / seek / 缓存回填请求，每个都重新 TCP（https 还要 TLS）握手，
  /// 局域网 Emby 直播放的卡顿主因之一。复用同一客户端才有 keep-alive 连接池；
  /// 同一原点在明文与 https 之间切换（登记变化）时换客户端、关旧的。
  final Map<String, HttpClient> _originClients = <String, HttpClient>{};
  bool _closed = false;

  /// 监听 socket 还活着。为 false 时 [ensureAppNativeProxy] 会另起一个。
  bool get isRunning => !_closed;

  Uri get endpoint => Uri(
    scheme: 'http',
    host: InternetAddress.loopbackIPv4.address,
    port: _server.port,
    userInfo: 'fushi:$_secret',
  );

  static Future<AppNativeProxy> start({bool publicTargetsOnly = false}) async {
    final HttpServer server = await HttpServer.bind(
      InternetAddress.loopbackIPv4,
      0,
    );
    final Random random = Random.secure();
    final String secret = base64Url.encode(
      List<int>.generate(32, (int _) => random.nextInt(256)),
    );
    final AppNativeProxy proxy = AppNativeProxy._(
      server,
      secret,
      publicTargetsOnly,
    );
    _nativeProxySecrets.addAll(<String>{
      secret,
      base64.encode(utf8.encode('fushi:$secret')),
    });
    server.listen(
      (HttpRequest request) => unawaited(proxy._serve(request)),
      onDone: () => proxy._closed = true,
      onError: (Object error) {
        proxy._closed = true;
        appNativeProxyLogSink(
          redactAppNativeProxySecrets('native proxy: listener failed: $error'),
        );
      },
    );
    return proxy;
  }

  Future<void> close() async {
    _closed = true;
    for (final Socket socket in _sockets.toList()) {
      socket.destroy();
    }
    for (final HttpClient client in _pinnedClients.values) {
      client.close(force: true);
    }
    _pinnedClients.clear();
    for (final HttpClient client in _originClients.values) {
      client.close(force: true);
    }
    _originClients.clear();
    await _server.close(force: true);
  }

  /// 非钉扎原点的复用客户端（见 [_originClients]）。[secure] 决定这份客户端服务的
  /// 是明文还是系统信任根 https；同一 `(host, port)` 只留一种。
  HttpClient _originClientFor(String host, int port, {required bool secure}) {
    final String origin = _pinnedOriginKey(host, port);
    final String key = '${secure ? 'https' : 'http'}://$origin';
    final HttpClient? cached = _originClients[key];
    if (cached != null) return cached;
    final String stale = '${secure ? 'http' : 'https'}://$origin';
    _originClients.remove(stale)?.close(force: true);
    final HttpClient client = appNativeProxyUpstreamClientFactory()
      ..autoUncompress = false;
    _originClients[key] = client;
    return client;
  }

  /// 钉扎原点的复用客户端（见 [_pinnedClients]）。连接超时与非钉扎分支、
  /// `WebDavOps` 的钉扎客户端同一常量：对端休眠 / WAN 地址黑洞时不能让 libmpv 的
  /// 下一个 Range 请求卡到操作系统默认超时。
  HttpClient _pinnedClientFor(String host, int port, String fingerprint) {
    final String key = '${_pinnedOriginKey(host, port)}|$fingerprint';
    final HttpClient? cached = _pinnedClients[key];
    if (cached != null) return cached;
    // 同一原点换了指纹：旧客户端连同它池里的连接一起作废。
    final String stalePrefix = '${_pinnedOriginKey(host, port)}|';
    for (final String staleKey
        in _pinnedClients.keys
            .where((String k) => k.startsWith(stalePrefix))
            .toList()) {
      _pinnedClients.remove(staleKey)?.close(force: true);
    }
    final HttpClient client = createPinnedHttpClient(
      expectedFingerprint: fingerprint,
      connectionTimeout: kAppHttpConnectionTimeout,
    )..autoUncompress = false;
    _pinnedClients[key] = client;
    return client;
  }

  Future<void> _serve(HttpRequest request) async {
    final String authorization =
        'Basic ${base64.encode(utf8.encode('fushi:$_secret'))}';
    final List<String>? supplied =
        request.headers[HttpHeaders.proxyAuthorizationHeader];
    if (supplied == null ||
        supplied.length != 1 ||
        supplied.single != authorization) {
      request.response.statusCode = HttpStatus.proxyAuthenticationRequired;
      request.response.headers.set(
        HttpHeaders.proxyAuthenticateHeader,
        'Basic realm="Fushi native"',
      );
      await request.response.close();
      return;
    }
    try {
      if (request.method == 'CONNECT') {
        await _connect(request);
      } else {
        await _forward(request);
      }
    } on Object catch (error) {
      // 原因只走应用日志，绝不进响应：响应体会被 native 客户端当成上游内容，
      // 而中继凭据必须先脱敏。
      _report(request, error);
      // Never return proxy URLs, authentication or native request bodies in an
      // error. The caller receives an actionable transport status.
      try {
        request.response.statusCode = HttpStatus.badGateway;
        await request.response.close();
      } on Object {
        /* A detached/closed tunnel has no HTTP response left. */
      }
    }
  }

  /// 一行「方法 + 去掉 query 的目标 + 真实异常」，凭据脱敏后交给日志出口。
  static void _report(HttpRequest request, Object error) {
    final String target = request.method == 'CONNECT'
        ? request.uri.toString()
        : request.requestedUri.replace(query: '', fragment: '').toString();
    appNativeProxyLogSink(
      redactAppNativeProxySecrets(
        'native proxy: ${request.method} $target -> $error',
      ),
    );
  }

  Future<void> _forward(HttpRequest request) async {
    final Uri uri = request.requestedUri;
    if (!uri.isScheme('http') || uri.host.isEmpty || uri.userInfo.isNotEmpty) {
      request.response.statusCode = HttpStatus.badRequest;
      await request.response.close();
      return;
    }
    if (await _rejectPrivateTarget(request, uri)) return;
    // 钉扎原点：native 拿到的是 [nativePlaybackUri] 降下来的明文 http，这里按
    // (host, port) 查到指纹就升回 https、用钉扎客户端连——TLS 只在 Dart 这一处裁决。
    final String? pinnedFingerprint = pinnedNativeOriginFingerprint(
      uri.host,
      uri.port,
    );
    // 非钉扎但已登记为「中继终结 TLS」的原点（见 [_tlsNativeOrigins]）：同样升回
    // https，只是用系统信任根而非指纹。
    final bool secure =
        pinnedFingerprint != null || isTlsNativeOrigin(uri.host, uri.port);
    final Uri upstreamUri = secure
        ? uri.replace(scheme: 'https', port: uri.port)
        : uri;
    // 三种客户端都按原点复用，请求结束不关（连接回池）；见 [_originClients]。
    final HttpClient client = pinnedFingerprint == null
        ? _originClientFor(uri.host, uri.port, secure: secure)
        : _pinnedClientFor(uri.host, uri.port, pinnedFingerprint);
    final HttpClientRequest outbound = await client.openUrl(
      request.method,
      upstreamUri,
    );
    // 重定向交给 native 自己跟：mpv 以**最终** URL 作相对 HLS 分片的解析基址，中继
    // 替它跟了基址就错了。只把 Location 改写成中继认识的形式（下面）。
    outbound.followRedirects = false;
    _copyHeaders(request.headers, outbound.headers);
    // 上游一律回未压缩正文：中继要读播放列表改写分片地址、要看分片首字节判「图片
    // 伪装」，压缩过的都做不了（megap 之类 CDN 不问也回 Brotli，Dart 没有 br）。媒体
    // 分片本就不可压缩，播放列表只有几 KB，放弃压缩没有代价。
    outbound.headers.set(HttpHeaders.acceptEncodingHeader, 'identity');
    await outbound.addStream(request);
    final HttpClientResponse response = await outbound.close();
    request.response.statusCode = response.statusCode;
    _copyHeaders(response.headers, request.response.headers);
    _rewriteRedirectLocation(response.headers, request.response.headers);
    await _relayBody(request, response);
    await request.response.close();
  }

  /// 把上游正文转给 native，途中做两项 HLS 归一化（见 `hls_relay_normalizer.dart`）：
  ///  - 播放列表：绝对 https 分片 / 变体 / `URI="…"` 改写成中继终结 TLS 的明文形式，
  ///    分片请求才会以明文回到中继（否则 CONNECT 隧道里的字节中继看不见）；
  ///  - 分片：图片魔数开头、后面却是 MPEG-TS / fMP4 的「伪装分片」剥掉图片前缀。
  /// 只对整包 GET 做（200，或 `bytes=0-` 换来的完整 206）；真正的部分范围请求的
  /// 字节偏移不能动，原样流过。
  Future<void> _relayBody(
    HttpRequest request,
    HttpClientResponse response,
  ) async {
    final HttpResponse out = request.response;
    // ffmpeg 的 http 首请求默认带 `Range: bytes=0-`，上游多半回 206 + 完整
    // Content-Range——语义上仍是整包，与 200 同等处理；改写 / 剥前缀后以 200 回给
    // native（Content-Range 随之作废）。真正的部分范围请求原样流过。
    final bool wholeBody =
        request.method == 'GET' &&
        isWholeBodyRangeRequest(
          request.headers.value(HttpHeaders.rangeHeader),
        ) &&
        (response.statusCode == HttpStatus.ok ||
            (response.statusCode == HttpStatus.partialContent &&
                isCompleteContentRange(
                  response.headers.value(HttpHeaders.contentRangeHeader),
                )));
    if (!wholeBody) {
      await out.addStream(response);
      return;
    }
    final String? encoding = response.headers.value(
      HttpHeaders.contentEncodingHeader,
    );
    final bool gzipped = encoding != null && encoding.toLowerCase() == 'gzip';
    final bool plain = encoding == null || encoding.toLowerCase() == 'identity';
    final bool playlistHint =
        isHlsPlaylistContentType(
          response.headers.value(HttpHeaders.contentTypeHeader),
        ) ||
        isHlsPlaylistPath(request.requestedUri.path);
    final StreamIterator<List<int>> chunks = StreamIterator<List<int>>(
      response,
    );
    // native 中途断开（libmpv 每次 seek / 换集都会掐掉正在下的分片或首个
    // `bytes=0-` 整包请求）：Dart 的 HttpResponse 对已销毁的连接 `add` / `flush`
    // **不抛**、`done` 也不完成（实测 Windows 上循环会一直跑到上游读完），不看
    // 它这条循环会把上游整包拉完喂给死连接。唯一可靠信号是连接销毁后
    // `connectionInfo` 取不到对端地址回 null。`addStream` 路径由 Dart 自己取消
    // 源订阅，只有这条手动迭代要管；检测到就停读、finally 里 cancel 迭代器让
    // 上游连接回池 / 关闭（读完后 cancel 是 no-op）。
    try {
      await _relayWholeBody(
        request: request,
        response: response,
        out: out,
        chunks: chunks,
        gzipped: gzipped,
        plain: plain,
        playlistHint: playlistHint,
        downstreamAlive: () => out.connectionInfo != null,
      );
    } finally {
      await chunks.cancel();
    }
  }

  static Future<void> _relayWholeBody({
    required HttpRequest request,
    required HttpClientResponse response,
    required HttpResponse out,
    required StreamIterator<List<int>> chunks,
    required bool gzipped,
    required bool plain,
    required bool playlistHint,
    required bool Function() downstreamAlive,
  }) async {
    final BytesBuilder head = BytesBuilder(copy: false);
    // 第一段先攒够 16 字节判魔数（播放列表 / 图片 / 其它）。
    while (head.length < 16 && await chunks.moveNext()) {
      head.add(chunks.current);
    }
    Uint8List bytes = head.toBytes();
    final bool playlist =
        (playlistHint && (gzipped || plain)) ||
        (plain && looksLikeHlsPlaylist(bytes));
    if (playlist) {
      // 播放列表整份读完再改写（一般几 KB；封顶 16 MiB，超了原样透传）。
      const int cap = 16 * 1024 * 1024;
      while (head.length <= cap &&
          downstreamAlive() &&
          await chunks.moveNext()) {
        head.add(chunks.current);
      }
      bytes = head.takeBytes();
      if (bytes.length <= cap) {
        final List<int> decoded = gzipped ? gzip.decode(bytes) : bytes;
        if (looksLikeHlsPlaylist(decoded)) {
          final String rewritten = rewriteHlsPlaylistUris(
            utf8.decode(decoded, allowMalformed: true),
            nativePlaybackUri,
          );
          final List<int> body = utf8.encode(rewritten);
          _asWholeEntity(out);
          out.headers.removeAll(HttpHeaders.contentEncodingHeader);
          out.contentLength = body.length;
          out.add(body);
          return;
        }
      }
      out.add(bytes);
      await _drain(chunks, out, downstreamAlive);
      return;
    }
    if (plain && looksLikeImagePrefix(bytes)) {
      // 伪装分片：继续攒到探到媒体起点或封顶。
      int? offset = disguisedMediaPayloadOffset(bytes);
      while (offset == null &&
          head.length < kDisguisedSegmentProbeLimit &&
          await chunks.moveNext()) {
        head.add(chunks.current);
        offset = disguisedMediaPayloadOffset(head.toBytes());
      }
      bytes = head.takeBytes();
      if (offset != null) {
        _asWholeEntity(out);
        final int declared = response.contentLength;
        if (declared >= offset) out.contentLength = declared - offset;
        out.headers.contentType = bytes[offset] == 0x47
            ? ContentType('video', 'mp2t')
            : ContentType('video', 'mp4');
        out.add(Uint8List.sublistView(bytes, offset));
        await _drain(chunks, out, downstreamAlive);
        return;
      }
    }
    out.add(bytes);
    await _drain(chunks, out, downstreamAlive);
  }

  /// 改写过的响应不再是上游那个实体的字节切片：206 → 200、去掉 Content-Range。
  static void _asWholeEntity(HttpResponse out) {
    out.statusCode = HttpStatus.ok;
    out.headers.removeAll(HttpHeaders.contentRangeHeader);
  }

  static Future<void> _drain(
    StreamIterator<List<int>> chunks,
    HttpResponse out,
    bool Function() downstreamAlive,
  ) async {
    while (downstreamAlive() && await chunks.moveNext()) {
      out.add(chunks.current);
      // 逐段 flush 给 native 侧回压：不然大分片会整段堆在 Dart 端内存里。
      await out.flush();
    }
  }

  /// 上游 3xx 的 `Location` 若是 https，改写成 [nativePlaybackUri] 同款的明文
  /// 显式端口形式并登记原点：native 跟过去仍经中继升 https，而不是自己去握手
  /// （Apple 端那一握手就是段错误）。相对 Location / 明文 http 原样。
  static void _rewriteRedirectLocation(
    HttpHeaders upstream,
    HttpHeaders downstream,
  ) {
    final String? location = upstream.value(HttpHeaders.locationHeader);
    if (location == null) return;
    final Uri? target = Uri.tryParse(location);
    if (target == null || !target.isScheme('https') || target.host.isEmpty) {
      return;
    }
    downstream.set(HttpHeaders.locationHeader, nativePlaybackUri(location));
  }

  Future<void> _connect(HttpRequest request) async {
    final Uri target = Uri.parse('https://${request.uri}');
    if (target.host.isEmpty ||
        target.userInfo.isNotEmpty ||
        target.port < 1 ||
        target.port > 65535 ||
        target.hasQuery ||
        target.hasFragment ||
        (target.path.isNotEmpty && target.path != '/')) {
      throw const FormatException('Invalid CONNECT target');
    }
    if (await _rejectPrivateTarget(request, target)) return;
    final tunnel = await _openTunnel(target);
    final Socket upstream = tunnel.socket;
    final StreamIterator<List<int>> reader = tunnel.reader;
    Socket? downstream;
    try {
      request.response.statusCode = HttpStatus.ok;
      downstream = await request.response.detachSocket();
      _sockets.add(downstream);
      final Socket client = downstream;
      await Future.wait(<Future<void>>[
        upstream.addStream(client).then((_) async {
          await upstream.close();
        }),
        client.addStream(_remaining(reader, tunnel.remaining)).then((_) async {
          await client.close();
        }),
      ], eagerError: true);
    } finally {
      await reader.cancel();
      upstream.destroy();
      downstream?.destroy();
      _sockets.remove(upstream);
      _sockets.remove(downstream);
    }
  }

  Future<bool> _rejectPrivateTarget(HttpRequest request, Uri target) async {
    if (!_publicTargetsOnly || !isDirectProxyTarget(target.host)) return false;
    request.response.statusCode = HttpStatus.forbidden;
    await request.response.close();
    return true;
  }

  Future<
    ({Socket socket, StreamIterator<List<int>> reader, List<int> remaining})
  >
  _openTunnel(Uri target) async {
    final String directive = resolveAppProxyDirective(target);
    final String? proxy = proxyHostPortFromDirective(directive);
    final Uri peer = proxy == null ? target : Uri.parse('http://$proxy');
    final ({String username, String password})? credentials =
        resolveAppProxyCredentials(target);
    for (int attempt = 0; attempt < 2; attempt++) {
      // A settings change while waiting for a challenge must never send old
      // credentials to a newly selected proxy, or vice versa.
      if (attempt > 0 &&
          (resolveAppProxyDirective(target) != directive ||
              resolveAppProxyCredentials(target) != credentials)) {
        throw const HttpException('Proxy settings changed');
      }
      final Socket socket = await Socket.connect(
        peer.host,
        peer.port,
        timeout: kAppHttpConnectionTimeout,
      );
      _sockets.add(socket);
      final StreamIterator<List<int>> reader = StreamIterator<List<int>>(
        socket,
      );
      bool keep = false;
      try {
        if (proxy == null) {
          keep = true;
          return (socket: socket, reader: reader, remaining: const <int>[]);
        }
        final String auth = attempt == 0 || credentials == null
            ? ''
            : 'Proxy-Authorization: Basic ${base64.encode(utf8.encode('${credentials.username}:${credentials.password}'))}\r\n';
        final String host = target.host.contains(':')
            ? '[${target.host}]'
            : target.host;
        final String authority = '$host:${target.port}';
        socket.write(
          'CONNECT $authority HTTP/1.1\r\nHost: $authority\r\n$auth\r\n',
        );
        await socket.flush();
        final response = await _readConnectResponse(
          reader,
        ).timeout(kAppHttpConnectionTimeout);
        if (response.status == 200) {
          keep = true;
          return (
            socket: socket,
            reader: reader,
            remaining: response.remaining,
          );
        }
        if (attempt != 0 ||
            response.status != 407 ||
            !response.basic ||
            credentials == null) {
          throw const HttpException('Upstream proxy refused CONNECT');
        }
      } finally {
        if (!keep) {
          socket.destroy();
          await reader.cancel();
          _sockets.remove(socket);
        }
      }
    }
    throw const HttpException('Upstream proxy refused CONNECT');
  }

  static Future<({int status, bool basic, List<int> remaining})>
  _readConnectResponse(StreamIterator<List<int>> reader) async {
    final List<int> bytes = <int>[];
    while (await reader.moveNext()) {
      bytes.addAll(reader.current);
      for (int i = 3; i < bytes.length && i < 65536; i++) {
        if (bytes[i - 3] == 13 &&
            bytes[i - 2] == 10 &&
            bytes[i - 1] == 13 &&
            bytes[i] == 10) {
          final String headers = latin1.decode(bytes.sublist(0, i + 1));
          final RegExpMatch? match = RegExp(
            r'^HTTP/1\.[01] (\d{3})(?: |\r)',
          ).firstMatch(headers);
          if (match == null) {
            throw const HttpException('Invalid proxy response');
          }
          return (
            status: int.parse(match.group(1)!),
            basic: RegExp(
              r'^proxy-authenticate:\s*basic(?:\s|$)',
              multiLine: true,
              caseSensitive: false,
            ).hasMatch(headers),
            remaining: bytes.sublist(i + 1),
          );
        }
      }
      if (bytes.length >= 65536) {
        throw const HttpException('Proxy header too large');
      }
    }
    throw const HttpException('Upstream proxy closed CONNECT');
  }

  static Stream<List<int>> _remaining(
    StreamIterator<List<int>> reader,
    List<int> initial,
  ) async* {
    if (initial.isNotEmpty) {
      yield initial;
    }
    while (await reader.moveNext()) {
      yield reader.current;
    }
  }

  static void _copyHeaders(HttpHeaders source, HttpHeaders destination) {
    final Set<String> excluded = <String>{
      // Host 由 Dart 按上游 URL 自己填：中继升 https 时上游端口可能与 native 看到
      // 的显式端口写法不同（`h:443` vs `h`），照抄会撞严格的虚拟主机匹配。
      'host',
      'connection',
      'proxy-connection',
      'proxy-authorization',
      'proxy-authenticate',
      'keep-alive',
      'transfer-encoding',
      'te',
      'trailer',
      'upgrade',
      ...?source
          .value('connection')
          ?.split(',')
          .map((String value) => value.trim().toLowerCase()),
    };
    source.forEach((String name, List<String> values) {
      if (!excluded.contains(name.toLowerCase())) {
        destination.set(name, values);
      }
    });
  }
}
