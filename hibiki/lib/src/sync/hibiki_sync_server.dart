import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:hibiki/src/dictionary/dictionary_media_types.dart';
import 'package:hibiki/src/media/video/video_subtitle_source.dart'
    show
        EmbeddedSubtitleTrack,
        extractEmbeddedSubtitleTrackFile,
        listEmbeddedSubtitleTracks,
        subtitleExtensionForCodec,
        subtitleFormatForCodec;
import 'package:hibiki/src/sync/aggregate_snapshot.dart';
import 'package:hibiki/src/sync/collection_manifest.dart';
import 'package:hibiki/src/sync/hibiki_library_host_service.dart';
import 'package:hibiki/src/sync/interconnect_device_name.dart';
import 'package:hibiki/src/sync/hibiki_remote_api_handlers.dart';
import 'package:hibiki/src/sync/pairing/hibiki_pairing_protocol.dart';
import 'package:hibiki/src/sync/hibiki_remote_lookup_service.dart';
import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;
import 'package:shelf/shelf.dart' as shelf;
import 'package:shelf/shelf_io.dart' as shelf_io;

/// Embedded WebDAV-style server used for device-to-device LAN sync.
///
/// SECURITY (HBK-AUDIT-011): transport is plain HTTP and auth is HTTP Basic,
/// so the bearer token travels in reversible base64 over the wire. This is
/// acceptable only on a trusted LAN, and is gated behind [_allowLan] — when
/// false (the default) the server binds to loopback only and is never exposed
/// to the network. Enabling LAN sync therefore requires an explicit opt-in.
///
/// The proper hardening (TLS with a token-pinned self-signed certificate, or
/// an HMAC challenge-response so the raw token is never transmitted) is a
/// coordinated server+client+discovery protocol change that must be designed
/// and verified on real devices; it is intentionally NOT bolted on here. Until
/// then, treat LAN sync as unencrypted and only use it on a network you trust.

/// A pairing attempt from a peer that POSTed /api/pair. Carries what the host
/// UI needs to identify the requester in its confirmation prompt.
class HibikiPairRequest {
  const HibikiPairRequest({
    required this.deviceName,
    required this.remoteAddress,
    this.pinVerified,
    this.pinRequired = false,
  });

  /// Self-reported name from the client (may be null/empty if not sent).
  final String? deviceName;

  /// Source IP of the TCP connection, or null when it can't be resolved.
  final String? remoteAddress;

  /// TODO-961 M1: PIN 校验结果，仅在 /api/pair/v2/confirm 路径携带。
  /// - null：来自旧 /api/pair（无 PIN 概念），由 host 自行决定是否放行。
  /// - true：本会话 pinProof 校验通过（或本会话 pinRequired=false 免 PIN）。
  /// - false：理论上不出现——pinProof 校验失败时 server 直接 401，不会再问 host。
  /// 双重确认（设计稿 §3.1）：v2 路径要求 pinVerified==true **且** host 人工允许。
  final bool? pinVerified;

  /// TODO-1273: 本会话是否真的要求 PIN（= host 的 pinRequired）。host 审批弹窗据此
  /// 决定是否显示 PIN：LAN 免 PIN 会话（pinRequired=false）不显示 PIN，避免 host 屏上
  /// 出现一个 client 从未被要求输入的「幽灵 PIN」。旧 /api/pair（v1，无 PIN）默认 false。
  final bool pinRequired;
}

/// TODO-961 M1b: confirm 成功后要落库的一条 per-peer 授权凭据。server 生成 token、
/// 通过注入的 [HibikiSyncServer.onPeerPaired] 回调把本记录交给 controller 写进
/// `hibiki_paired_peers` 表（server 不直连 DB，保持可单测 / 存储层无依赖）。
class HibikiPairedPeerRegistration {
  const HibikiPairedPeerRegistration({
    required this.peerId,
    required this.token,
    required this.deviceName,
    required this.remoteAddress,
  });

  /// 对端稳定身份（client 配对时上报的 deviceId）。表 UNIQUE 键，upsert 幂等基准。
  final String peerId;

  /// 本设备专属的长期访问凭据（confirm 派发，写库并回给该 client）。
  final String token;

  /// 对端自报展示名（可空）。
  final String? deviceName;

  /// 配对时对端来源 IP（诊断/展示，可空）。
  final String? remoteAddress;
}

/// Thrown by [HibikiSyncServer.start] when the requested port is already bound
/// by another process. Carries the [port] so the UI can name it.
class SyncServerPortInUseException implements Exception {
  SyncServerPortInUseException(this.port);
  final int port;
  @override
  String toString() => 'SyncServerPortInUseException: port $port is in use';
}

/// True when [e] reports "address already in use": errno 98 (Linux),
/// 10048 (Windows WSAEADDRINUSE) or 48 (macOS), with a message fallback for
/// platforms that omit a numeric code.
bool isAddressInUseError(SocketException e) {
  final int? code = e.osError?.errorCode;
  if (code == 98 || code == 10048 || code == 48) return true;
  // Fall back to the message: cross-process conflicts carry an errno above,
  // but a same-process re-bind raises Dart's "shared flag" guard with no code,
  // and some platforms phrase EADDRINUSE without a numeric code.
  final String message =
      '${e.osError?.message ?? ''} ${e.message}'.toLowerCase();
  return message.contains('address already in use') ||
      message.contains('address in use') ||
      message.contains('only one usage of each socket address') ||
      message.contains('shared flag to bind');
}

/// TODO-1215: dictionary media endpoint accepts these query token param
/// names (aligned with yomitan-api server). A browser <img> GET carries no
/// Authorization header, so it authenticates via ?token= instead.
const List<String> _kDictionaryMediaTokenParams = <String>[
  'token',
  'apiKey',
  'api_key',
  'key',
  'yomitanApiKey',
  'yomitan_api_key',
];

class HibikiSyncServer {
  HibikiSyncServer({
    required String syncDataDir,
    required int port,
    required String token,
    bool allowLan = false,
    HibikiRemoteLookupService? remoteLookupService,
    HibikiRemoteMiningService? miningService,
    HibikiRemoteHistoryService? historyService,
    HibikiLibraryHostService? libraryService,
    SecurityContext? securityContext,
    String? hostFingerprint,
    String? deviceName,
    DateTime Function()? now,
    Uint8List? Function(String dictionary, String path)?
        dictionaryMediaProvider,
  })  : syncDataDir = p.join(syncDataDir, 'sync-data'),
        _requestedPort = port,
        _token = token,
        _allowLan = allowLan,
        _securityContext = securityContext,
        _hostFingerprint = hostFingerprint,
        _deviceName = deviceName,
        _remoteLookupService = remoteLookupService,
        _miningService = miningService,
        _historyService = historyService,
        _libraryService = libraryService,
        _dictionaryMediaProvider = dictionaryMediaProvider,
        _now = now ?? DateTime.now;

  final String syncDataDir;
  final int _requestedPort;
  final String _token;
  final bool _allowLan;

  /// 非 null 时 server 起 HTTPS（shelf 透传给 HttpServer.bindSecure）；null 时
  /// 走明文 HTTP 老路径，行为零变化（TLS 默认关，Never break userspace）。
  final SecurityContext? _securityContext;

  /// TODO-963 M2: host 自报展示名，/api/ping 回传给手动配对的 client 展示「你正在连
  /// 到 <name>」。可空（旧调用方不传，client 回退用 IP）。
  final String? _deviceName;

  /// TODO-961 M1: 本 host 自签证书的 SHA-256 指纹（aa:bb:.. 形式），仅在 TLS 开启
  /// 时非 null。配对成功响应回传给 client 做 TOFU 钉扎核对（首连记录）。
  final String? _hostFingerprint;
  final HibikiRemoteLookupService? _remoteLookupService;
  final HibikiRemoteMiningService? _miningService;
  final HibikiRemoteHistoryService? _historyService;
  final HibikiLibraryHostService? _libraryService;

  /// TODO-1215: dictionary media (gaiji/accent SVG, etc.) byte provider.
  /// Injected rather than depending on the HoshiDicts singleton directly, so
  /// the server has no compile-time coupling to the dictionary engine and
  /// stays unit-testable. Returns null -> the media endpoint answers 404.
  final Uint8List? Function(String dictionary, String path)?
      _dictionaryMediaProvider;
  final DateTime Function() _now;
  final Map<String, _RemoteAudioToken> _remoteAudioTokens =
      <String, _RemoteAudioToken>{};

  /// BUG-908(a)：音频查词 token 的数量上限。POST 侧签发前先按 TTL prune、再淘汰最旧
  /// 者收束到上限内（对照 [_maxPairSessions]）。只 POST /api/lookup/audio 却从不 GET
  /// 取文件的调用者会让 [_remoteAudioTokens] 无界堆积（内存膨胀 DoS）——GET 侧的
  /// [_pruneAudioTokens] 永远等不到，故上限必须在 POST 侧强制。
  static const int _maxAudioTokens = 128;

  final Map<String, _VideoStreamToken> _videoStreamTokens =
      <String, _VideoStreamToken>{};

  /// BUG-908(d)：WebDAV 写操作（PUT / MKCOL / DELETE）的按路径串行闸门。key 是目标
  /// 文件系统绝对路径，value 是该路径上最近一次写的完成 future。新的写先 await 同一
  /// 路径上前一次写的 future 再执行——同一路径的写串行、不同路径可并行。读操作
  /// （PROPFIND / GET / HEAD）不入闸。仅单路径链式 await、绝不嵌套持锁，故无死锁。
  final Map<String, Future<void>> _davWriteChain = <String, Future<void>>{};

  /// TODO-961 M1：进行中的 v2 配对会话（pair/v2 创建、pair/v2/confirm 消费）。
  /// 内存态、不落盘；server 重启即清空（半截配对作废，安全侧）。
  final Map<String, HibikiPairSession> _pairSessions =
      <String, HibikiPairSession>{};

  /// TODO-961 M1（会话 TTL/上限，对照 audio/video token 的 prune 模式）：只发
  /// pair/v2 却不 confirm 的攻击者会留下永久驻留会话（慢速 DoS）。每个会话
  /// [_pairSessionTtl] 后过期，超过 [_maxPairSessions] 时先 prune 再淘汰最旧者。
  /// TTL 与现有 host 60s 自动 deny（[HibikiSyncServerController]）对齐：会话生命周期
  /// 不应长于一次审批窗口（留 90s 余量覆盖审批弹窗 + 用户输 PIN）。
  static const Duration _pairSessionTtl = Duration(seconds: 90);
  static const int _maxPairSessions = 64;

  /// TODO-961 M3：PIN 爆破限速器。按来源（client 自报 deviceId，回退来源 IP）聚合
  /// PIN 校验失败；同一来源在滑动窗口内累计到阈值即锁定退避一段时间，期间 confirm
  /// 直接被拒（不再触碰 PIN 比对）。粒度选「来源」而非「会话」的理由见
  /// [HibikiPinRateLimiter] 文档：[HibikiPairSession.consumed] 已让单会话只能撞一次，
  /// 真正的爆破面是不断开新会话逐个撞——只有按来源聚合才挡得住。纯内存态，随
  /// [_prunePairSessions] 一并 prune 防泄漏；server 重启即清空。
  final HibikiPinRateLimiter _pinRateLimiter = HibikiPinRateLimiter();

  HttpServer? _server;

  /// Interactive pairing approval. When a client POSTs /api/pair, the server
  /// asks the host UI via this callback (Bluetooth-style "device X wants to
  /// pair — allow?") and only hands out [_token] when it resolves true. While
  /// null (no UI wired), every pairing request is refused, so the raw token is
  /// never handed out without a deliberate human approval on the host device.
  Future<bool> Function(HibikiPairRequest request)? onPairRequest;

  /// TODO-961 M1: host 生成 6 位 PIN 并喂给审批弹窗显示的供给器。pair/v2 创建会话时
  /// 调用一次拿到本会话 PIN（同一 PIN 显示给用户、又用于 confirm 时重算比对）。
  /// null（无 UI 接线）时 server 自行用 [HibikiPairingProtocol.generatePin] 兜底，
  /// 但因 PIN 不显示给任何人，pinRequired=true 的会话将无法被 confirm（安全侧默认拒）。
  String Function(HibikiPairSession session)? onPairPinGenerated;

  /// TODO-961 M1: host 偏好「LAN 自动发现也要 PIN」的供给器（默认 false=自家免）。
  /// 注入而非直读 DB，保持 server 对存储层无依赖、可单测。
  Future<bool> Function()? lanRequiresPinProvider;

  /// TODO-1330 / BUG：pinRequired 会话的 client 提交了 confirm（PIN 已被对方读到并
  /// 用于算 proof）时回调一次，让 host UI 关掉那个「一直显示 PIN、等对方输入」的审批
  /// 弹窗。修的是「host 点允许即关窗抹掉 PIN → client 还没输就看不到 PIN」的时序死锁：
  /// host 点允许后弹窗改为常驻显示 PIN，直到本回调（或用户手动关 / TTL 超时）才收起。
  /// 免 PIN 会话不涉及（本就没有常驻 PIN 弹窗），故仅 pinRequired 分支触发。
  void Function()? onPairSessionResolved;

  /// TODO-961 M1b: confirm 成功后把新派发的 per-peer 凭据交给 host 落库（写
  /// `hibiki_paired_peers` 表）。注入而非直连 DB，保持 server 存储层无依赖、可单测。
  /// null（未接线，如纯协议单测）时 confirm 回退派发共享 [_token]，不落 per-peer 行
  /// ——既有 pair_v2 行为零变化（Never break userspace）。
  Future<void> Function(HibikiPairedPeerRegistration registration)?
      onPeerPaired;

  /// TODO-961 M1b: 供给当前全部未吊销的 per-peer token（auth 校验入站请求时，除共享
  /// [_token] 外接受任一 peer token）。注入而非直连 DB。首次 auth 时惰性加载并缓存；
  /// [invalidatePeerTokenCache] 在配对/吊销后清缓存促其下次重载。null 时只认共享 token。
  Future<Set<String>> Function()? pairedPeerTokensProvider;

  /// [pairedPeerTokensProvider] 结果的缓存（避免每个请求打一次 DB）。null=未加载。
  /// 配对新增 / 吊销后经 [invalidatePeerTokenCache] 置 null，下次 auth 重新拉取。
  Set<String>? _cachedPeerTokens;

  bool get isRunning => _server != null;
  int get port => _server?.port ?? _requestedPort;

  static String generateToken() {
    final random = Random.secure();
    final bytes = List<int>.generate(32, (_) => random.nextInt(256));
    return base64Url.encode(bytes);
  }

  Future<void> start() async {
    if (_server != null) return;
    // The WebDAV root maps to [syncDataDir]; materialise it up front so a
    // freshly enabled server answers PROPFIND on '/' with a 207 (an empty
    // collection) instead of a 404. The client's reachability probe PROPFINDs
    // the root and gates every other op — including the MKCOL that would
    // otherwise lazily create this dir — so without this a reachable,
    // correctly-authenticating host is reported as "No reachable Hibiki server
    // address", a chicken-and-egg deadlock that never bootstraps (BUG-035).
    // Deliberately outside the bind try/catch below: a read-only/permission
    // failure here should fail-fast and bubble to the caller's error handling
    // (sync_settings_schema._startServer catch-all) rather than masquerade as a
    // port-in-use error — and since it runs before serve(), a failure leaves no
    // half-bound socket to roll back.
    await Directory(syncDataDir).create(recursive: true);
    final handler = const shelf.Pipeline()
        .addMiddleware(_gzipTextMiddleware())
        .addMiddleware(_authMiddleware())
        .addHandler(_handleRequest);
    try {
      _server = await shelf_io.serve(
        handler,
        _allowLan ? InternetAddress.anyIPv4 : InternetAddress.loopbackIPv4,
        _requestedPort,
        securityContext: _securityContext,
      );
    } on SocketException catch (e) {
      if (isAddressInUseError(e)) {
        throw SyncServerPortInUseException(_requestedPort);
      }
      rethrow;
    }
  }

  /// 导出包缓存（epub/词典/有声书/本地音频 GET 的 Range 续传字节稳定性基础）。
  final ExportPackageCache _exportCache = ExportPackageCache();

  Future<void> stop() async {
    await _server?.close(force: true);
    _server = null;
    _exportCache.dispose();
  }

  /// gzip 压缩 JSON/XML 文本响应（`Accept-Encoding: gzip` 内容协商）。
  ///
  /// 只压 `application/json` 与 XML（WebDAV PROPFIND 207）——文件流（epub/视频/
  /// 封面/音频包，含 Range/206 与断点续传）一律不碰：`Content-Encoding` 与
  /// `Content-Range`/`Content-Length` 字节账在下载器（ResumableDownloader）与
  /// libmpv 侧语义交叉，且媒体本身已压缩、gzip 无收益。清单 JSON（books/videos/
  /// aggregate/collections，大库数百 KB CJK 文本）压到约 1/5~1/6。不带该头的旧
  /// client 收到原样明文——纯内容协商，零协议破坏（dart:io HttpClient 默认发
  /// gzip accept 并透明解压，新旧 client 均无需改动）。
  shelf.Middleware _gzipTextMiddleware() {
    return (shelf.Handler innerHandler) {
      return (shelf.Request request) async {
        final shelf.Response response = await innerHandler(request);
        final String accept =
            (request.headers['accept-encoding'] ?? '').toLowerCase();
        if (!accept.contains('gzip')) return response;
        final String type =
            (response.headers['content-type'] ?? '').toLowerCase();
        final bool compressible =
            type.contains('application/json') || type.contains('xml');
        if (!compressible) return response;
        if (response.headers['content-encoding'] != null) return response;
        final List<int> body = <int>[
          for (final List<int> chunk in await response.read().toList())
            ...chunk,
        ];
        final List<int> gzipped = gzip.encode(body);
        return response.change(
          headers: <String, String>{
            'Content-Encoding': 'gzip',
            'Content-Length': '${gzipped.length}',
          },
          body: gzipped,
        );
      };
    };
  }

  shelf.Middleware _authMiddleware() {
    return (shelf.Handler innerHandler) {
      return (shelf.Request request) async {
        if (request.method == 'OPTIONS') return innerHandler(request);
        // Pairing is the one unauthenticated route: the client has no token
        // yet — that is exactly what it is fetching. Gating is done by the
        // pairing window inside _handlePair, not by Basic auth.
        if (request.url.path == 'api/pair') return innerHandler(request);
        // TODO-961 M1: v2 配对（含 confirm）同样无 token——这正是 client 在获取的
        // 东西。门控由 PIN proof + host 人工确认完成，不靠 Basic auth。
        if (request.url.path == 'api/pair/v2' ||
            request.url.path == 'api/pair/v2/confirm') {
          return innerHandler(request);
        }
        // TODO-963 M2: /api/ping 是无鉴权的轻量探测端点——手动输入 IP 的 client 在
        // 配对前（还没有 token）用它确认地址可达 + 取 host 能力/指纹做 TOFU。只读、
        // 不泄漏数据，与 /api/pair 同属配对前公开面。
        if (request.url.path == 'api/ping') return innerHandler(request);
        // Video stream paths are exempted from Basic auth to allow media_kit
        // to play via a plain URL. Token validation happens inside the handler.
        // Only the /stream sub-path is exempted; /streamurl, /subtitle, and the
        // video list still require Basic auth.
        if (_isVideoStreamPath(request.url.path)) return innerHandler(request);
        // Remote lookup audio file URLs are handed to platform audio players,
        // which issue a bare GET without Authorization. The lookup endpoint
        // stays authenticated; the file endpoint is guarded by an opaque,
        // short-lived in-memory id in _handleAudioFile.
        if (_isLookupAudioFilePath(request.url.path)) {
          return innerHandler(request);
        }
        // TODO-1215: the dictionary media endpoint is fetched by a web page
        // <img src> GET, which carries no Authorization header (same as
        // /api/lookup/audio/file). It authenticates via a ?token= query
        // param instead; a valid token passes here, an invalid/absent one
        // falls through to the Basic check below (in-app / Basic clients
        // still work) and ultimately 401s.
        if (_isDictionaryMediaPath(request.url.path) &&
            _dictionaryMediaTokenValid(request)) {
          return innerHandler(request);
        }
        final auth = request.headers['authorization'];
        if (auth == null || !await _validateAuth(auth)) {
          return shelf.Response(401,
              headers: {'WWW-Authenticate': 'Basic realm="Hibiki Sync"'});
        }
        return innerHandler(request);
      };
    };
  }

  /// 判断 [urlPath]（即 request.url.path，不含前导 `/`）是否为视频流路径
  /// （`api/library/videos/<id>/stream`，id 非空，id 可含 `/`）。
  static bool _isVideoStreamPath(String urlPath) {
    const String prefix = 'api/library/videos/';
    const String suffix = '/stream';
    if (!urlPath.startsWith(prefix)) return false;
    if (!urlPath.endsWith(suffix)) return false;
    final String idPart =
        urlPath.substring(prefix.length, urlPath.length - suffix.length);
    return idPart.isNotEmpty;
  }

  static bool _isLookupAudioFilePath(String urlPath) =>
      urlPath == 'api/lookup/audio/file';

  Future<bool> _validateAuth(String header) async {
    if (!header.startsWith('Basic ')) return false;
    try {
      final decoded = utf8.decode(base64Decode(header.substring(6)));
      final colonIdx = decoded.indexOf(':');
      if (colonIdx < 0) return false;
      final password = decoded.substring(colonIdx + 1);
      // 兼容路径：共享 [_token] 仍受理（未重新配对的老设备继续可用，Never break
      // userspace）。常量时间比较防计时侧信道泄漏 token 前缀。
      if (_constantTimeEquals(
        Uint8List.fromList(utf8.encode(password)),
        Uint8List.fromList(utf8.encode(_token)),
      )) {
        return true;
      }
      // TODO-961 M1b：再比对任一未吊销的 per-peer token。惰性加载 + 缓存，避免每请求
      // 打库；配对/吊销经 [invalidatePeerTokenCache] 清缓存促重载。
      final Set<String> peerTokens = await _peerTokens();
      final Uint8List pw = Uint8List.fromList(utf8.encode(password));
      for (final String peerToken in peerTokens) {
        if (_constantTimeEquals(
            pw, Uint8List.fromList(utf8.encode(peerToken)))) {
          return true;
        }
      }
      return false;
    } catch (_) {
      return false;
    }
  }

  /// 当前有效 per-peer token 集合（惰性加载 + 缓存）。无 provider 时为空集——只认
  /// 共享 [_token]。
  Future<Set<String>> _peerTokens() async {
    final Set<String>? cached = _cachedPeerTokens;
    if (cached != null) return cached;
    final Future<Set<String>> Function()? provider = pairedPeerTokensProvider;
    final Set<String> loaded = provider == null ? <String>{} : await provider();
    _cachedPeerTokens = loaded;
    return loaded;
  }

  /// TODO-961 M1b：配对新增一台设备 / 吊销一台设备后调用，清 per-peer token 缓存，
  /// 使下一次 [_validateAuth] 从 [pairedPeerTokensProvider] 重新拉取最新集合。
  /// controller 在 upsert / revoke 后调它，保证吊销即时生效、新 token 立即受理。
  void invalidatePeerTokenCache() {
    _cachedPeerTokens = null;
  }

  static bool _constantTimeEquals(Uint8List a, Uint8List b) {
    final len = a.length > b.length ? a.length : b.length;
    var result = a.length ^ b.length;
    for (var i = 0; i < len; i++) {
      result |= (i < a.length ? a[i] : 0) ^ (i < b.length ? b[i] : 0);
    }
    return result == 0;
  }

  Future<shelf.Response> _handleRequest(shelf.Request request) async {
    final method = request.method.toUpperCase();
    final reqPath = Uri.decodeFull('/${request.url.path}');
    if (reqPath == '/api/pair') {
      return _handlePair(request);
    }
    if (reqPath == '/api/pair/v2') {
      return _handlePairV2(request);
    }
    if (reqPath == '/api/pair/v2/confirm') {
      return _handlePairConfirm(request);
    }
    if (reqPath.startsWith('/api/lookup/')) {
      return _handleLookupApi(request, method, reqPath);
    }
    if (reqPath == '/api/mine') {
      if (method != 'POST') return shelf.Response(405);
      return _handleMine(request);
    }
    if (reqPath == '/api/media/dictionary') {
      if (method != 'GET' && method != 'HEAD') return shelf.Response(405);
      return _handleDictionaryMedia(request, method == 'HEAD');
    }
    if (reqPath == '/api/duplicate') {
      if (method != 'POST') return shelf.Response(405);
      return _handleDuplicate(request);
    }
    if (reqPath == '/api/extension/status') {
      if (method != 'POST') return shelf.Response(405);
      return _jsonResponse(<String, dynamic>{
        'app': 'hibiki',
        'ready': true,
        'port': port,
      });
    }
    if (reqPath == '/api/ping') {
      if (method != 'GET') return shelf.Response(405);
      return _handlePing();
    }
    if (reqPath == '/api/capabilities') {
      if (method != 'GET') return shelf.Response(405);
      return _handleCapabilities();
    }
    if (reqPath == '/api/library/dictionaries' ||
        reqPath.startsWith('/api/library/dictionaries/')) {
      return _handleLibraryDictionaries(request, method, reqPath);
    }
    if (reqPath == '/api/library/books' ||
        reqPath.startsWith('/api/library/books/')) {
      return _handleLibraryBooks(request, method, reqPath);
    }
    if (reqPath == '/api/library/localaudio' ||
        reqPath.startsWith('/api/library/localaudio/')) {
      return _handleLibraryLocalAudio(request, method, reqPath);
    }
    if (reqPath == '/api/library/audiobooks' ||
        reqPath.startsWith('/api/library/audiobooks/')) {
      return _handleLibraryAudiobooks(request, method, reqPath);
    }
    if (reqPath == '/api/library/videos' ||
        reqPath.startsWith('/api/library/videos/')) {
      return _handleLibraryVideos(request, method, reqPath);
    }
    if (reqPath == '/api/library/aggregate') {
      return _handleLibraryAggregate(request, method, reqPath);
    }
    if (reqPath == '/api/library/collections') {
      return _handleLibraryCollections(request, method, reqPath);
    }

    // 真实读写路径：只做词法规整、**保留原始大小写**。p.canonicalize 在
    // 大小写不敏感平台（Windows）会把整条路径小写化，这会让书文件夹名按宿主平台
    // 大小写折叠——同一本书在 Windows host 落成小写、在 Linux/Android host 保留原
    // 大小写，跨平台同步身份就此错位。故真实文件操作绝不能用 canonicalize 的结果。
    final fsPath = p.normalize(p.join(syncDataDir, reqPath.substring(1)));
    // 路径穿越围栏：canonicalize 的大小写折叠/符号链接解析只用于"是否逃出根目录"
    // 的判定，不参与真实读写，故对身份大小写无影响。
    final canonicalFsPath = p.canonicalize(fsPath);
    final canonicalRoot = p.canonicalize(syncDataDir);
    if (canonicalFsPath != canonicalRoot &&
        !canonicalFsPath.startsWith('$canonicalRoot${p.separator}')) {
      return shelf.Response.forbidden('Path traversal denied');
    }

    switch (method) {
      case 'PROPFIND':
        return _handlePropfind(request, reqPath, fsPath);
      case 'GET':
        return _handleGet(fsPath);
      // BUG-908(d)：改动文件系统的写操作按目标路径串行化，避免并发 PUT/DELETE/MKCOL
      // 同一路径互相踩（截断/半写/删了又建的竞态）。读操作（PROPFIND/GET/HEAD）不入闸。
      case 'PUT':
        return _serializeDavWrite(fsPath, () => _handlePut(request, fsPath));
      case 'MKCOL':
        return _serializeDavWrite(fsPath, () => _handleMkcol(fsPath));
      case 'DELETE':
        return _serializeDavWrite(fsPath, () => _handleDelete(fsPath));
      case 'HEAD':
        return _handleHead(fsPath);
      case 'OPTIONS':
        return shelf.Response.ok('', headers: {
          'Allow': 'OPTIONS, GET, POST, PUT, DELETE, MKCOL, PROPFIND, HEAD',
          'DAV': '1',
        });
      default:
        return shelf.Response(405);
    }
  }

  /// BUG-908(d)：把 [action] 串到 [fsPath] 的写链尾部——同一路径上的写严格 FIFO 串行，
  /// 不同路径互不阻塞。实现是「每路径一条链式 future」：新写先取当前链尾 [prev]，把自己
  /// 的完成 future 挂成新链尾，await [prev] 后再执行 [action]，最后 complete 自己让后继
  /// 继续。永远只 await 单一路径上的前驱、绝不在持有一把锁时去取另一把，故不会死锁；
  /// 收尾时若自己仍是链尾就从 map 摘除，避免闲置路径无界堆积。
  Future<T> _serializeDavWrite<T>(
      String fsPath, Future<T> Function() action) async {
    final Future<void> prev = _davWriteChain[fsPath] ?? Future<void>.value();
    final Completer<void> done = Completer<void>();
    _davWriteChain[fsPath] = done.future;
    try {
      // 等前一次同路径写完成后再动手。前驱失败也不应连累后继，故吞掉其异常。
      await prev.catchError((Object _) {});
      return await action();
    } finally {
      done.complete();
      // 若期间没有后继把链尾替换掉，说明该路径已空闲，摘除以防 map 无界增长。
      if (identical(_davWriteChain[fsPath], done.future)) {
        _davWriteChain.remove(fsPath);
      }
    }
  }

  Future<shelf.Response> _handlePair(shelf.Request request) async {
    if (request.method.toUpperCase() != 'POST') return shelf.Response(405);
    final Future<bool> Function(HibikiPairRequest)? approve = onPairRequest;
    // No UI wired to approve → never hand out the token unattended. A distinct
    // reason lets the client say "peer not ready" instead of "peer declined".
    if (approve == null) return _pairDenied('unavailable');
    String? name;
    final Map<String, dynamic>? body = await _readJsonObject(request);
    final String? reported = body?['name']?.toString().trim();
    // Reject a "localhost"/loopback advertisement so it is never stored as this
    // peer's device name — the paired-devices list would otherwise show
    // "localhost" instead of a real name (TODO-1356).
    if (reported != null &&
        reported.isNotEmpty &&
        !isMeaninglessDeviceName(reported)) {
      name = reported;
    }
    final bool approved = await approve(HibikiPairRequest(
      deviceName: name,
      remoteAddress: _remoteAddress(request),
    ));
    if (!approved) return _pairDenied('declined');
    return _jsonResponse(<String, dynamic>{'token': _token});
  }

  /// A 403 carrying a machine-readable [reason] ('declined' | 'unavailable') so
  /// the client can distinguish a real refusal from a peer that has no approval
  /// handler wired. Older peers reply with a plain-text body instead, which the
  /// client treats as 'unavailable'.
  shelf.Response _pairDenied(String reason) => shelf.Response(
        403,
        body: jsonEncode(<String, String>{'reason': reason}),
        headers: <String, String>{'Content-Type': 'application/json'},
      );

  /// TODO-961 M1: POST /api/pair/v2 {name, clientNonce} → 200 {sessionId,
  /// pinRequired, hostNonce}。仅创建会话、决定是否需要 PIN，并把 host 生成的 PIN
  /// 喂给审批弹窗显示——此阶段 **不** 派 token、**不** 弹「允许/拒绝」（那在
  /// confirm 阶段，双重确认）。PIN 绝不进响应 body。
  Future<shelf.Response> _handlePairV2(shelf.Request request) async {
    if (request.method.toUpperCase() != 'POST') return shelf.Response(405);
    // No approval UI wired → never start a pairing handshake unattended.
    if (onPairRequest == null) return _pairDenied('unavailable');
    final Map<String, dynamic>? body = await _readJsonObject(request);
    final String? clientNonce = body?['clientNonce']?.toString();
    if (clientNonce == null || clientNonce.trim().isEmpty) {
      return shelf.Response(400, body: 'Missing clientNonce');
    }
    final String? reportedName = body?['name']?.toString().trim();
    // Drop a "localhost"/loopback advertisement (never a real device name) so it
    // is not persisted as the peer's name in the paired-devices list (TODO-1356).
    final String? deviceName = (reportedName != null &&
            reportedName.isNotEmpty &&
            !isMeaninglessDeviceName(reportedName))
        ? reportedName
        : null;
    // TODO-961 M1b: client 自报稳定 deviceId（per-peer token 落库的 UNIQUE 身份）。
    // 旧 client 不带此字段 → null → confirm 回退共享 token（兼容）。
    final String? reportedDeviceId = body?['clientDeviceId']?.toString().trim();
    final String? clientDeviceId =
        (reportedDeviceId != null && reportedDeviceId.isNotEmpty)
            ? reportedDeviceId
            : null;
    final String? remote = _remoteAddress(request);

    final bool isLanPeer = HibikiPairingProtocol.isPrivateLanAddress(remote);
    final bool lanRequiresPin =
        await (lanRequiresPinProvider?.call() ?? Future<bool>.value(false));
    final bool pinRequired = HibikiPairingProtocol.computePinRequired(
      isLanPeer: isLanPeer,
      lanRequiresPin: lanRequiresPin,
    );

    final String sessionId = HibikiPairingProtocol.generateNonce();
    final String hostNonce = HibikiPairingProtocol.generateNonce();
    final HibikiPairSession session = HibikiPairSession(
      sessionId: sessionId,
      clientNonce: clientNonce,
      hostNonce: hostNonce,
      // PIN 先用安全随机兜底，下面交给 host UI 供给器（若接线）覆盖为屏显值。
      pin: HibikiPairingProtocol.generatePin(),
      pinRequired: pinRequired,
      deviceName: deviceName,
      remoteAddress: remote,
      createdAt: _now(),
      clientDeviceId: clientDeviceId,
    );
    // 先 prune 过期会话 + 守上限：杜绝「只发 pair/v2 不 confirm」的慢速 DoS 把
    // _pairSessions 撑爆（对照 audio/video token 的 prune 模式）。
    _prunePairSessions();
    _enforcePairSessionCap();
    // 同步回收已冷却的 PIN 失败记录，防限速器内存随开会话数无界增长。
    _pinRateLimiter.prune(_now());

    // host UI 供给器返回真正显示给用户的 PIN（同值用于 confirm 重算比对）。未接线
    // 时保留随机兜底 PIN——它不显示给任何人，故 pinRequired 会话无法被 confirm（拒）。
    final String shownPin = onPairPinGenerated?.call(session) ?? session.pin;
    final HibikiPairSession stored = HibikiPairSession(
      sessionId: sessionId,
      clientNonce: clientNonce,
      hostNonce: hostNonce,
      pin: shownPin,
      pinRequired: pinRequired,
      deviceName: deviceName,
      remoteAddress: remote,
      createdAt: session.createdAt,
      clientDeviceId: clientDeviceId,
    );

    // TODO-1296 / BUG-592: pinRequired（公网 / 跨网段 / host 要求 PIN）会话在 CREATE
    // 阶段就弹 host 审批——审批弹窗会显示本会话 PIN，让 client 被要求输入前 host 屏上
    // 已经有 PIN 可读。修复「公网配对根本看不到 PIN」的时序死锁：旧实现只在 confirm 且
    // pinProof 校验通过后才弹审批显示 PIN，而 client 必须先输对 PIN 才能过校验 → PIN 永
    // 远不显示、配对永远走不通。免 PIN 会话（LAN 自动发现且 host 允许免 PIN）审批仍留在
    // confirm（本就无 PIN 可显示，行为零变化，Never break userspace）。
    if (pinRequired) {
      final bool approved = await onPairRequest!(HibikiPairRequest(
        deviceName: deviceName,
        remoteAddress: remote,
        // pinVerified 尚未校验（那在 confirm）；pinRequired=true 让审批弹窗显示 PIN。
        pinVerified: null,
        pinRequired: true,
      ));
      if (!approved) return _pairDenied('declined');
    }

    _pairSessions[sessionId] = stored;

    // 响应只含 sessionId / pinRequired / hostNonce —— 绝不含 PIN 明文。
    return _jsonResponse(<String, dynamic>{
      'sessionId': sessionId,
      'pinRequired': pinRequired,
      'hostNonce': hostNonce,
    });
  }

  /// TODO-961 M1: POST /api/pair/v2/confirm {sessionId, pinProof} → 200 {token,
  /// hostFingerprint}。校验 pinProof（双 nonce HMAC），通过后 **仍** 需 host 人工
  /// 点允许（双重确认）才派 token。同一 sessionId 二次 confirm（重放）一律拒。
  Future<shelf.Response> _handlePairConfirm(shelf.Request request) async {
    if (request.method.toUpperCase() != 'POST') return shelf.Response(405);
    final Future<bool> Function(HibikiPairRequest)? approve = onPairRequest;
    if (approve == null) return _pairDenied('unavailable');
    final Map<String, dynamic>? body = await _readJsonObject(request);
    final String? sessionId = body?['sessionId']?.toString();
    if (sessionId == null || sessionId.trim().isEmpty) {
      return shelf.Response(400, body: 'Missing sessionId');
    }
    // 先清掉过期会话，使「pair/v2 后超 TTL 才 confirm」被当作未知会话拒绝。
    _prunePairSessions();
    // 同步回收已冷却的 PIN 失败记录（锁定中的保留到期满），防限速器内存泄漏。
    _pinRateLimiter.prune(_now());
    final HibikiPairSession? session = _pairSessions[sessionId];
    // 未知会话（过期/伪造）或已被消费过（重放）→ 拒。consumed 防同 nonce 二次提交。
    if (session == null || session.consumed) {
      return _pairDenied('declined');
    }
    // 单次消费：无论本次成功失败，会话即作废，杜绝 nonce 重放。
    session.consumed = true;
    _pairSessions.remove(sessionId);

    // TODO-1330 / BUG：pinRequired 会话一旦 confirm 到达，说明 client 已读到 host 屏上
    // 的 PIN（用它算了 proof），host 那个常驻 PIN 弹窗就该收起——无论本次 proof 对错
    // （PIN 已一次性消费，重试要走新会话拿新 PIN）。在此单点触发，避开后面多个 return
    // 分支各自补一遍。免 PIN 会话没有常驻弹窗，不触发。
    if (session.pinRequired) onPairSessionResolved?.call();

    // TODO-961 M3：本会话来源标识，供爆破限速按来源聚合失败计数。优先 client 自报的
    // 稳定 deviceId，回退来源 IP；二者都缺时为 null → 无稳定身份可锁，退化为不限速的
    // 单会话路径（该路径已被 session.consumed 单次消费保护，一个会话只能撞一次）。
    final String? sourceKey = _pinRateLimitSourceKey(session);
    if (session.pinRequired) {
      // 先查锁定态（再触碰 PIN 比对）：锁定则直接拒，杜绝继续撞。锁定判定只看来源与
      // 时钟，与 PIN 内容完全无关，故不引入「前缀正确就更慢」的计时侧信道。
      if (sourceKey != null && _pinRateLimiter.isLockedOut(sourceKey, _now())) {
        return _pairRateLimited();
      }
      final String? pinProof = body?['pinProof']?.toString();
      if (pinProof == null || pinProof.trim().isEmpty) {
        // 缺 proof 同样计一次失败：否则攻击者可用「开会话→空 proof」零成本探测锁定态
        // 之外的东西。记后若已锁定，返回 429 让 client 知道被限速。
        if (sourceKey != null &&
            _pinRateLimiter.recordFailure(sourceKey, _now())) {
          return _pairRateLimited();
        }
        // 401：PIN 校验未通过（缺 proof）——不再问 host（不弹窗）。
        return _pairUnauthorized();
      }
      final bool ok = HibikiPairingProtocol.verifyPinProof(
        pin: session.pin,
        clientNonce: session.clientNonce,
        hostNonce: session.hostNonce,
        submittedProof: pinProof,
      );
      if (!ok) {
        // 记一次来源级失败；若因此达阈值进入锁定，返回 429（限速），否则 401（PIN 错）。
        if (sourceKey != null &&
            _pinRateLimiter.recordFailure(sourceKey, _now())) {
          return _pairRateLimited();
        }
        return _pairUnauthorized();
      }
    }

    // TODO-1296 / BUG-592: pinRequired 会话的 host 审批已在 CREATE 阶段完成——会话能
    // 存在于 _pairSessions 即代表 host 当时已点允许（见 _handlePairV2），故此处不再二次
    // 弹窗，只凭 pinProof 校验通过即派 token（双重确认 = 早前的人工允许 + 此刻的 proof
    // 校验，两者仍缺一不可）。免 PIN 会话（pinRequired=false）没有 CREATE 阶段审批，仍在
    // 此弹审批（无 PIN 可显示，行为不变）。
    if (!session.pinRequired) {
      final bool approved = await approve(HibikiPairRequest(
        deviceName: session.deviceName,
        remoteAddress: session.remoteAddress,
        pinVerified: true,
        pinRequired: false,
      ));
      if (!approved) return _pairDenied('declined');
    }

    // TODO-961 M3：成功配对 → 清零该来源的 PIN 失败计数与锁定态（不株连未来尝试）。
    if (sourceKey != null) _pinRateLimiter.recordSuccess(sourceKey);

    // TODO-961 M1b：per-peer token 派发。仅当 host 接线了落库回调（onPeerPaired）
    // **且** client 上报了稳定 deviceId 时，才生成本设备专属 token 并写库、回给该
    // client。任一缺失（纯协议单测无 DB / 旧 client 不上报 deviceId）则回退共享
    // [_token]——既有行为零变化、老设备继续可配对（Never break userspace）。
    final String issuedToken = await _issuePeerTokenOrFallback(session);
    return _jsonResponse(<String, dynamic>{
      'token': issuedToken,
      if (_securityContext != null && _hostFingerprint != null)
        'hostFingerprint': _hostFingerprint,
    });
  }

  /// confirm 成功后派发访问 token：有 [onPeerPaired] 回调且会话带 clientDeviceId
  /// 时生成 per-peer token、经回调落库并清 token 缓存（吊销/新增即时生效），返回该
  /// token；否则回退共享 [_token]（无 DB 接线 / 旧 client 无 deviceId 的兼容路径）。
  Future<String> _issuePeerTokenOrFallback(HibikiPairSession session) async {
    final Future<void> Function(HibikiPairedPeerRegistration)? persist =
        onPeerPaired;
    final String? peerId = session.clientDeviceId?.trim();
    if (persist == null || peerId == null || peerId.isEmpty) {
      return _token;
    }
    final String peerToken = generateToken();
    await persist(HibikiPairedPeerRegistration(
      peerId: peerId,
      token: peerToken,
      deviceName: session.deviceName,
      remoteAddress: session.remoteAddress,
    ));
    // 新 token 立即受理：清缓存促下次 auth 从 provider 重载（含刚写入的这行）。
    invalidatePeerTokenCache();
    return peerToken;
  }

  /// 401，机器可读 reason='pin'：PIN proof 校验未通过。与 403/declined 区分，让
  /// client 提示「PIN 错误，请重输」而非「对端拒绝」。绝不在 body 里回显任何 PIN。
  shelf.Response _pairUnauthorized() => shelf.Response(
        401,
        body: jsonEncode(<String, String>{'reason': 'pin'}),
        headers: <String, String>{'Content-Type': 'application/json'},
      );

  /// TODO-961 M3：429，机器可读 reason='rate_limited'：该来源 PIN 失败过多已被锁定
  /// 退避。与 401/pin 区分，让 client 提示「尝试过多，请稍后再试」而非「PIN 错误」。
  /// 绝不回显剩余锁定时长的精确值以外的信息，也绝不泄露 PIN 是否部分正确。
  shelf.Response _pairRateLimited() => shelf.Response(
        429,
        body: jsonEncode(<String, String>{'reason': 'rate_limited'}),
        headers: <String, String>{'Content-Type': 'application/json'},
      );

  /// TODO-961 M3：本会话在 PIN 爆破限速里的来源标识。优先 client 自报的稳定
  /// deviceId（同一物理设备换 IP 也锁得住），回退请求来源 IP。二者都缺（无稳定身份）
  /// 时返回 null → 调用方退化为不限速的单会话路径（已由 consumed 单次消费保护）。
  static String? _pinRateLimitSourceKey(HibikiPairSession session) {
    final String? deviceId = session.clientDeviceId?.trim();
    if (deviceId != null && deviceId.isNotEmpty) return 'dev:$deviceId';
    final String? remote = session.remoteAddress?.trim();
    if (remote != null && remote.isNotEmpty) return 'ip:$remote';
    return null;
  }

  /// Source IP of the request's TCP connection, or null when shelf_io did not
  /// attach connection info (e.g. some test harnesses).
  static String? _remoteAddress(shelf.Request request) {
    final Object? info = request.context['shelf.io.connection_info'];
    if (info is HttpConnectionInfo) return info.remoteAddress.address;
    return null;
  }

  Future<shelf.Response> _handleLookupApi(
    shelf.Request request,
    String method,
    String reqPath,
  ) async {
    if (reqPath == '/api/lookup/dictionary') {
      if (method != 'POST') return shelf.Response(405);
      return _handleDictionaryLookup(request);
    }
    if (reqPath == '/api/lookup/audio') {
      if (method != 'POST') return shelf.Response(405);
      return _handleAudioLookup(request);
    }
    if (reqPath == '/api/lookup/audio/file') {
      if (method != 'GET' && method != 'HEAD') return shelf.Response(405);
      return _handleAudioFile(request, method == 'HEAD');
    }
    return shelf.Response.notFound('Not found');
  }

  Future<shelf.Response> _handleDictionaryLookup(shelf.Request request) async {
    final HibikiRemoteLookupService? service = _remoteLookupService;
    if (service == null) return shelf.Response.notFound('Remote lookup off');
    final Map<String, dynamic>? body = await _readJsonObject(request);
    if (body == null) return shelf.Response(400, body: 'Invalid JSON');
    // 契约与 YomitanApiServer 共享（BUG-530，单一真相源）。
    return _jsonResponse(await buildRemoteDictionaryLookupResponse(
      body,
      lookup: service,
      history: _historyService,
    ));
  }

  Future<shelf.Response> _handleAudioLookup(shelf.Request request) async {
    final HibikiRemoteLookupService? service = _remoteLookupService;
    if (service == null) return shelf.Response.notFound('Remote lookup off');
    final Map<String, dynamic>? body = await _readJsonObject(request);
    if (body == null) return shelf.Response(400, body: 'Invalid JSON');

    final String expression = body['expression']?.toString() ?? '';
    final String reading = body['reading']?.toString() ?? '';
    if (expression.trim().isEmpty) return _audioMissResponse();

    final RemoteAudioLookup? lookup = await service.lookupAudio(
      expression: expression,
      reading: reading,
    );
    if (lookup == null) return _audioMissResponse();

    // BUG-908(a)：签发前先按 TTL 清过期，再把数量收束到 [_maxAudioTokens] 内（淘汰
    // 最旧者）。否则只 POST 不 GET 的调用者会让 [_remoteAudioTokens] 无界膨胀——GET
    // 侧的 [_pruneAudioTokens] 永远不会被触发。
    _pruneAudioTokens();
    _enforceAudioTokenCap();
    final String id = _generateAudioToken();
    _remoteAudioTokens[id] = _RemoteAudioToken(
      bytes: lookup.bytes,
      contentType: lookup.contentType,
      createdAt: _now(),
    );
    final Uri url = request.requestedUri.replace(
      path: '/api/lookup/audio/file',
      queryParameters: <String, String>{'id': id},
    );
    return _jsonResponse(<String, dynamic>{
      'type': 'audioResult',
      'url': url.toString(),
      'contentType': lookup.contentType,
    });
  }

  shelf.Response _handleAudioFile(shelf.Request request, bool headOnly) {
    _pruneAudioTokens();
    final String? id = request.url.queryParameters['id'];
    final _RemoteAudioToken? token = id == null ? null : _remoteAudioTokens[id];
    if (token == null) return shelf.Response.notFound('Not found');
    // TODO-766: 命中即续期。重置该 token 的时间戳，使其 5 分钟窗口从「最近一次被
    // 访问」起算，正在使用中的音频不会中途被 [_pruneAudioTokens] 清掉。
    token.createdAt = _now();
    return shelf.Response.ok(
      headOnly ? null : token.bytes,
      headers: <String, String>{
        'Content-Type': token.contentType,
        'Content-Length': '${token.bytes.length}',
      },
    );
  }

  shelf.Response _audioMissResponse() => _jsonResponse(<String, dynamic>{
        'type': 'audioResult',
        'url': null,
        'contentType': null,
      });

  static bool _isDictionaryMediaPath(String urlPath) =>
      urlPath == 'api/media/dictionary';

  /// Validates that [request]'s query token (?token= etc.) equals [_token].
  /// Used to admit the dictionary media endpoint without Basic auth (a web
  /// page <img> GET has no Authorization header). Constant-time comparison.
  bool _dictionaryMediaTokenValid(shelf.Request request) {
    for (final String name in _kDictionaryMediaTokenParams) {
      final String? value = request.url.queryParameters[name];
      if (value != null &&
          _constantTimeEquals(
            Uint8List.fromList(utf8.encode(value)),
            Uint8List.fromList(utf8.encode(_token)),
          )) {
        return true;
      }
    }
    return false;
  }

  /// TODO-1215: GET /api/media/dictionary?dictionary=<name>&path=<rel>&token=<t>
  /// -- dictionary gaiji / pitch-accent SVG (etc.) media bytes. The browser
  /// extension popup rewrites a term's <img src> from the in-app image:// URL
  /// to this endpoint (a real browser has no image:// handler). Bytes are
  /// resolved by the injected [_dictionaryMediaProvider] (bridged to
  /// HoshiDicts.getMediaFile in-app); the MIME reuses the same
  /// [dictionaryMediaMimeType] as the app scheme handler.
  shelf.Response _handleDictionaryMedia(shelf.Request request, bool headOnly) {
    final Uint8List? Function(String, String)? provider =
        _dictionaryMediaProvider;
    if (provider == null) return shelf.Response.notFound('Media off');
    final String dictionary = request.url.queryParameters['dictionary'] ?? '';
    final String path = normalizeDictionaryMediaPath(
      request.url.queryParameters['path'] ?? '',
    );
    if (dictionary.isEmpty || path.isEmpty) {
      return shelf.Response.notFound('Not found');
    }
    final Uint8List? bytes = provider(dictionary, path);
    if (bytes == null || bytes.isEmpty) {
      return shelf.Response.notFound('Not found');
    }
    final String mime = dictionaryMediaMimeType(path);
    return shelf.Response.ok(
      headOnly ? null : bytes,
      headers: <String, String>{
        'Content-Type': mime,
        'Content-Length': '${bytes.length}',
        // The extension loads the image cross-origin on a real web page (and
        // may drawImage it onto a canvas for monochrome recolor); allow CORS
        // so any read-back path never taints the canvas. Media is
        // non-sensitive and already token-authenticated.
        'Access-Control-Allow-Origin': '*',
      },
    );
  }

  Future<shelf.Response> _handleMine(shelf.Request request) async {
    final HibikiRemoteMiningService? svc = _miningService;
    if (svc == null) return shelf.Response.notFound('Mining off');
    final Map<String, dynamic>? body = await _readJsonObject(request);
    if (body == null) return shelf.Response(400, body: 'Invalid JSON');
    // 契约与 YomitanApiServer 共享（BUG-530，单一真相源）。fields 缺失/类型错 → 400。
    try {
      return _jsonResponse(await buildRemoteMineResponse(body, mining: svc));
    } on FormatException {
      return shelf.Response(400, body: 'Missing fields');
    }
  }

  /// TODO-1176：浏览器扩展查词弹窗制卡按钮真查重（`+`→`✓`）。契约与 YomitanApiServer
  /// 共享（单一真相源）。未注入挖词 service 时返回 `{duplicate:false}`（弹窗降级为「+」，
  /// 绝不阻断查词）。
  Future<shelf.Response> _handleDuplicate(shelf.Request request) async {
    final HibikiRemoteMiningService? svc = _miningService;
    final Map<String, dynamic>? body = await _readJsonObject(request);
    if (body == null) return shelf.Response(400, body: 'Invalid JSON');
    if (svc == null) {
      return _jsonResponse(<String, dynamic>{'duplicate': false});
    }
    return _jsonResponse(await buildRemoteDuplicateResponse(body, mining: svc));
  }

  /// TODO-963 M2: 无鉴权轻量探测。手动输入 IP 的 client 在「填 IP → 探测 → 配对」流程
  /// 里用它确认地址可达、读 host 展示名 + 是否支持 v2 配对 + （TLS 开时）host 证书指纹
  /// 供 TOFU 钉扎。只读、不含任何数据/凭据。绝不回传 token。
  shelf.Response _handlePing() {
    return _jsonResponse(<String, dynamic>{
      'app': 'hibiki',
      'pairing': <String, dynamic>{'v2': true},
      'tls': <String, dynamic>{
        'enabled': _securityContext != null,
        if (_hostFingerprint != null) 'fingerprint': _hostFingerprint,
      },
      if (_deviceName != null && _deviceName.isNotEmpty)
        'deviceName': _deviceName,
    });
  }

  shelf.Response _handleCapabilities() {
    final bool lib = _libraryService != null;
    return _jsonResponse(<String, dynamic>{
      'liveLibrary': <String, dynamic>{
        'dictionaries': lib,
        'books': lib,
        'audio': lib,
        'videos': lib,
      },
      // TODO-961 M1 能力协商（设计稿 §1.1 / §2.5）：老 client 读不到也不崩。
      'tls': <String, dynamic>{
        'enabled': _securityContext != null,
        if (_hostFingerprint != null) 'fingerprint': _hostFingerprint,
      },
      'pairing': <String, dynamic>{'v2': true},
    });
  }

  Future<shelf.Response> _handleLibraryDictionaries(
    shelf.Request request,
    String method,
    String reqPath,
  ) async {
    final HibikiLibraryHostService? svc = _libraryService;
    if (svc == null) return shelf.Response.notFound('Library service off');

    if (reqPath == '/api/library/dictionaries') {
      if (method != 'GET') return shelf.Response(405);
      final List<RemoteDictionaryInfo> list = await svc.listDictionaries();
      return shelf.Response.ok(
        jsonEncode(<Map<String, Object?>>[
          for (final RemoteDictionaryInfo d in list) d.toJson()
        ]),
        headers: <String, String>{'Content-Type': 'application/json'},
      );
    }

    // reqPath 已在 _handleRequest 经 Uri.decodeFull 解码，此处无需再解码。
    // 原先的 Uri.decodeComponent 调用会对已解码的 CJK 字符再次解析，
    // 导致 "Illegal percent encoding in URI"（Dart 不接受非 ASCII 作为
    // decodeComponent 输入）。直接 substring 即可得到正确的词典名。
    final String name = reqPath.substring('/api/library/dictionaries/'.length);
    if (name.isEmpty) {
      return shelf.Response.notFound('Missing dictionary name');
    }
    // HBK-AUDIT-012: reject path-traversal attempts.  Dictionary names must
    // never contain path separators or dot-dot sequences; if they did they
    // could escape the dictionary resource root on the host (DELETE being the
    // most dangerous).  This single gate covers all three methods below.
    if (name.contains('/') || name.contains('\\') || name.contains('..')) {
      return shelf.Response.forbidden('Invalid dictionary name');
    }

    switch (method) {
      case 'GET':
        // 经导出缓存 + Range/If-Range（TTL 内续传钉在同一份字节上；旧 client
        // 不发 Range 收到 200 全量，行为不变）。
        File file;
        try {
          file = await _exportCache.obtain(
              'dict', name, () => svc.exportDictionary(name));
        } on StateError {
          return shelf.Response.notFound('Dictionary not found');
        }
        return serveFileWithRange(file, request,
            etag: ExportPackageCache.etagFor(file));

      case 'PUT':
        final Directory tmpDir =
            Directory.systemTemp.createTempSync('hibiki_dict_in');
        final File tmp = File(p.join(tmpDir.path, '$name.hibikidict'));
        final IOSink sink = tmp.openWrite();
        try {
          await request.read().forEach(sink.add);
          await sink.close();
          await svc.importDictionary(tmp);
          return shelf.Response(200);
        } catch (e) {
          try {
            await sink.close();
          } catch (_) {
            // best-effort
          }
          return shelf.Response(500, body: 'Import failed: $e');
        } finally {
          try {
            tmpDir.deleteSync(recursive: true);
          } catch (_) {
            // best-effort
          }
        }

      case 'DELETE':
        await svc.deleteDictionary(name);
        return shelf.Response(204);

      default:
        return shelf.Response(405);
    }
  }

  Future<shelf.Response> _handleLibraryBooks(
    shelf.Request request,
    String method,
    String reqPath,
  ) async {
    final HibikiLibraryHostService? svc = _libraryService;
    if (svc == null) return shelf.Response.notFound('Library service off');

    if (reqPath == '/api/library/books') {
      if (method != 'GET') return shelf.Response(405);
      final List<RemoteBookInfo> list = await svc.listBooks();
      return shelf.Response.ok(
        jsonEncode(<Map<String, Object?>>[
          for (final RemoteBookInfo b in list)
            _remoteBookJsonForRequest(b, request)
        ]),
        headers: <String, String>{'Content-Type': 'application/json'},
      );
    }

    // reqPath 已在 _handleRequest 经 Uri.decodeFull 解码，此处无需再解码。
    const String bookPrefix = '/api/library/books/';
    const String coverSuffix = '/cover';
    if (reqPath.startsWith(bookPrefix) && reqPath.endsWith(coverSuffix)) {
      if (method != 'GET') return shelf.Response(405);
      final String coverBookId = reqPath.substring(
          bookPrefix.length, reqPath.length - coverSuffix.length);
      if (coverBookId.isEmpty) {
        return shelf.Response.notFound('Missing book title');
      }
      if (coverBookId.contains('/') ||
          coverBookId.contains('\\') ||
          coverBookId.contains('..')) {
        return shelf.Response.forbidden('Invalid book title');
      }
      final File? cover = await _resolveBookCover(svc, coverBookId);
      if (cover == null) return shelf.Response.notFound('Book cover not found');
      return serveFileWithRange(cover, request);
    }

    // GET/PUT /api/library/books/<bookKey>/progress — 跨设备阅读进度（TODO-767）。
    // GET 让 client 拉取 host 真相源进度；PUT 让 client 上报本端进度（host 取较新者）。
    // 与 video /position 分支对称，但落 host 自己的 reader_positions DB（非 prefs）。
    const String progressSuffix = '/progress';
    if (reqPath.startsWith(bookPrefix) && reqPath.endsWith(progressSuffix)) {
      final String progressBookKey = reqPath.substring(
          bookPrefix.length, reqPath.length - progressSuffix.length);
      if (progressBookKey.isEmpty) {
        return shelf.Response.notFound('Missing book key');
      }
      if (progressBookKey.contains('/') ||
          progressBookKey.contains('\\') ||
          progressBookKey.contains('..')) {
        return shelf.Response.forbidden('Invalid book key');
      }
      switch (method) {
        case 'GET':
          final RemoteBookProgress progress =
              await svc.getBookProgress(progressBookKey);
          return shelf.Response.ok(
            jsonEncode(progress.toJson()),
            headers: <String, String>{'Content-Type': 'application/json'},
          );
        case 'PUT':
          final String body = await request.readAsString();
          Map<String, dynamic> json;
          try {
            json = jsonDecode(body) as Map<String, dynamic>;
          } catch (_) {
            return shelf.Response(400, body: 'Invalid JSON');
          }
          await svc.putBookProgress(
            progressBookKey,
            RemoteBookProgress.fromJson(json.cast<String, Object?>()),
          );
          return shelf.Response(200);
        default:
          return shelf.Response(405);
      }
    }

    final String bookId = reqPath.substring(bookPrefix.length);
    if (bookId.isEmpty) {
      return shelf.Response.notFound('Missing book title');
    }
    // HBK-AUDIT-012: reject path-traversal attempts.  Book titles must
    // never contain path separators or dot-dot sequences.
    if (bookId.contains('/') ||
        bookId.contains('\\') ||
        bookId.contains('..')) {
      return shelf.Response.forbidden('Invalid book title');
    }

    switch (method) {
      case 'GET':
        // 经导出缓存 + Range/If-Range（.epub 扩展名保留 → Content-Type 仍是
        // application/epub+zip；见 _guessContentType）。
        File file;
        try {
          file = await _exportCache.obtain(
              'book', bookId, () => svc.exportBook(bookId));
        } on StateError {
          return shelf.Response.notFound('Book not found');
        }
        return serveFileWithRange(file, request,
            etag: ExportPackageCache.etagFor(file));

      case 'PUT':
        final Directory tmpDir =
            Directory.systemTemp.createTempSync('hibiki_book_in');
        final File tmp = File(p.join(tmpDir.path, '$bookId.epub'));
        final IOSink sink = tmp.openWrite();
        try {
          await request.read().forEach(sink.add);
          await sink.close();
          await svc.importBook(tmp);
          return shelf.Response(200);
        } catch (e) {
          try {
            await sink.close();
          } catch (_) {
            // best-effort
          }
          return shelf.Response(500, body: 'Import failed: $e');
        } finally {
          try {
            tmpDir.deleteSync(recursive: true);
          } catch (_) {
            // best-effort
          }
        }

      case 'DELETE':
        await svc.deleteBook(bookId);
        return shelf.Response(204);

      default:
        return shelf.Response(405);
    }
  }

  Map<String, Object?> _remoteBookJsonForRequest(
    RemoteBookInfo book,
    shelf.Request request,
  ) {
    final Map<String, Object?> json = book.toJson()
      ..remove('coverUrl')
      ..remove('hasCover');
    if (_coverFile(book.coverPath) != null) {
      json['hasCover'] = true;
      json['coverUrl'] = request.requestedUri.replace(
        pathSegments: <String>[
          'api',
          'library',
          'books',
          book.downloadId,
          'cover',
        ],
        queryParameters: <String, String>{},
      ).toString();
    }
    return json;
  }

  Future<File?> _resolveBookCover(
    HibikiLibraryHostService service,
    String bookId,
  ) async {
    // 单行直查（bookCoverPath 按 bookKey 优先、title 兜底），不再每张封面重跑
    // 整份 listBooks()（逐书标签/有声书/合集重活），与 [_resolveVideoCover] 对称。
    return _coverFile(await service.bookCoverPath(bookId));
  }

  Future<shelf.Response> _handleLibraryLocalAudio(
    shelf.Request request,
    String method,
    String reqPath,
  ) async {
    final HibikiLibraryHostService? svc = _libraryService;
    if (svc == null) return shelf.Response.notFound('Library service off');

    if (reqPath == '/api/library/localaudio') {
      if (method != 'GET') return shelf.Response(405);
      final List<RemoteLocalAudioInfo> list = await svc.listLocalAudio();
      return shelf.Response.ok(
        jsonEncode(<Map<String, Object?>>[
          for (final RemoteLocalAudioInfo a in list) a.toJson()
        ]),
        headers: <String, String>{'Content-Type': 'application/json'},
      );
    }

    // reqPath 已在 _handleRequest 经 Uri.decodeFull 解码，此处无需再解码。
    final String displayName =
        reqPath.substring('/api/library/localaudio/'.length);
    if (displayName.isEmpty) {
      return shelf.Response.notFound('Missing displayName');
    }
    // HBK-AUDIT-012: reject path-traversal attempts.
    if (displayName.contains('/') ||
        displayName.contains('\\') ||
        displayName.contains('..')) {
      return shelf.Response.forbidden('Invalid displayName');
    }

    switch (method) {
      case 'GET':
        // 经导出缓存 + Range/If-Range。
        File file;
        try {
          file = await _exportCache.obtain('localaudio', displayName,
              () => svc.exportLocalAudio(displayName));
        } on StateError {
          return shelf.Response.notFound('Local audio not found');
        }
        return serveFileWithRange(file, request,
            etag: ExportPackageCache.etagFor(file));

      case 'PUT':
        final Directory tmpDir =
            Directory.systemTemp.createTempSync('hibiki_localaudio_in');
        final File tmp = File(p.join(tmpDir.path, '$displayName.localaudio'));
        final IOSink sink = tmp.openWrite();
        try {
          await request.read().forEach(sink.add);
          await sink.close();
          await svc.importLocalAudio(tmp);
          return shelf.Response(200);
        } catch (e) {
          try {
            await sink.close();
          } catch (_) {
            // best-effort
          }
          return shelf.Response(500, body: 'Import failed: $e');
        } finally {
          try {
            tmpDir.deleteSync(recursive: true);
          } catch (_) {
            // best-effort
          }
        }

      case 'DELETE':
        await svc.deleteLocalAudio(displayName);
        return shelf.Response(204);

      default:
        return shelf.Response(405);
    }
  }

  Future<shelf.Response> _handleLibraryAudiobooks(
    shelf.Request request,
    String method,
    String reqPath,
  ) async {
    final HibikiLibraryHostService? svc = _libraryService;
    if (svc == null) return shelf.Response.notFound('Library service off');

    if (reqPath == '/api/library/audiobooks') {
      if (method != 'GET') return shelf.Response(405);
      final List<RemoteAudiobookInfo> list = await svc.listAudiobooks();
      return shelf.Response.ok(
        jsonEncode(<Map<String, Object?>>[
          for (final RemoteAudiobookInfo ab in list) ab.toJson()
        ]),
        headers: <String, String>{'Content-Type': 'application/json'},
      );
    }

    // reqPath 已在 _handleRequest 经 Uri.decodeFull 解码，此处无需再解码。
    // GET/PUT /api/library/audiobooks/<bookKey>/position — 跨设备有声书播放断点
    // (BUG-471)。GET 让 client 拉取 host 真相源进度；PUT 让 client 上报本端进度
    // (host 取较新者)。与 video /position 分支对称。必须在下面的整包 bookKey 提取
    // 之前匹配，否则 `<key>/position` 会被当成含 `/` 的非法 bookKey 拒绝。
    const String audiobookPrefix = '/api/library/audiobooks/';
    const String positionSuffix = '/position';
    if (reqPath.startsWith(audiobookPrefix) &&
        reqPath.endsWith(positionSuffix)) {
      final String positionBookKey = reqPath.substring(
          audiobookPrefix.length, reqPath.length - positionSuffix.length);
      if (positionBookKey.isEmpty) {
        return shelf.Response.notFound('Missing bookKey');
      }
      if (positionBookKey.contains('/') ||
          positionBookKey.contains('\\') ||
          positionBookKey.contains('..')) {
        return shelf.Response.forbidden('Invalid bookKey');
      }
      // 先确认该有声书在 host DB 真实存在，防任意 key 写脏 prefs；与视频 position
      // 先 resolveVideoFile 同语义。BUG-471a：改用廉价的 audiobookExists（单次 DB
      // 查询）替代旧的 exportAudiobook 打包探测——旧实现每次 GET/PUT position 都把整
      // 本有声书音频/字幕/封面打成 .hibikiaudio 临时文件再删，live sweep 对每本共享
      // 有声书每轮触发一次造成大量无谓 zip I/O + CPU。
      try {
        if (!await svc.audiobookExists(positionBookKey)) {
          return shelf.Response.notFound('Audiobook not found');
        }
      } on ArgumentError {
        return shelf.Response.forbidden('Invalid bookKey');
      }
      switch (method) {
        case 'GET':
          final ({int positionMs, int updatedAtMs}) p =
              await svc.getAudiobookPosition(positionBookKey);
          return shelf.Response.ok(
            jsonEncode(<String, Object?>{
              'positionMs': p.positionMs,
              'positionUpdatedAtMs': p.updatedAtMs,
            }),
            headers: <String, String>{'Content-Type': 'application/json'},
          );
        case 'PUT':
          final String body = await request.readAsString();
          Map<String, dynamic> json;
          try {
            json = jsonDecode(body) as Map<String, dynamic>;
          } catch (_) {
            return shelf.Response(400, body: 'Invalid JSON');
          }
          final int posMs = (json['positionMs'] as num?)?.toInt() ?? 0;
          final int updatedAtMs =
              (json['positionUpdatedAtMs'] as num?)?.toInt() ?? 0;
          await svc.putAudiobookPosition(positionBookKey, posMs, updatedAtMs);
          return shelf.Response(200);
        default:
          return shelf.Response(405);
      }
    }

    final String bookKey = reqPath.substring('/api/library/audiobooks/'.length);
    if (bookKey.isEmpty) {
      return shelf.Response.notFound('Missing bookKey');
    }
    // HBK-AUDIT-012: reject path-traversal attempts.
    if (bookKey.contains('/') ||
        bookKey.contains('\\') ||
        bookKey.contains('..')) {
      return shelf.Response.forbidden('Invalid bookKey');
    }

    switch (method) {
      case 'GET':
        // 经导出缓存 + Range/If-Range（大有声书包中断续传的最大受益者）。
        File file;
        try {
          file = await _exportCache.obtain(
              'audiobook', bookKey, () => svc.exportAudiobook(bookKey));
        } on StateError {
          return shelf.Response.notFound('Audiobook not found');
        }
        return serveFileWithRange(file, request,
            etag: ExportPackageCache.etagFor(file));

      case 'PUT':
        final Directory tmpDir =
            Directory.systemTemp.createTempSync('hibiki_audiobook_in');
        final File tmp = File(p.join(tmpDir.path, '$bookKey.audiobook'));
        final IOSink sink = tmp.openWrite();
        try {
          await request.read().forEach(sink.add);
          await sink.close();
          await svc.importAudiobook(tmp, bookKeyOverride: bookKey);
          return shelf.Response(200);
        } catch (e) {
          try {
            await sink.close();
          } catch (_) {
            // best-effort
          }
          return shelf.Response(500, body: 'Import failed: $e');
        } finally {
          try {
            tmpDir.deleteSync(recursive: true);
          } catch (_) {
            // best-effort
          }
        }

      case 'DELETE':
        await svc.deleteAudiobook(bookKey);
        return shelf.Response(204);

      default:
        return shelf.Response(405);
    }
  }

  // ── 视频端点（P4-2）──────────────────────────────────────────────────────────

  /// 从视频子路径提取视频 id。
  ///
  /// [reqPath] 已经过 Uri.decodeFull 解码（含前导 `/`）。
  /// 格式为 `/api/library/videos/<id>/<suffix>`，其中：
  /// - [suffix] 为 `stream`、`streamurl`、`subtitle` 或 `cover`
  /// - id 允许包含 `/`（如 `video/my_film`），但不允许 `..`（路径穿越）
  ///
  /// 解析失败（id 为空或含 `..`）时返回 null。
  /// 解析 `?episode=N` query 成集下标（TODO-885）；缺省 / 非法 / 负数都回退 0
  /// （= 当前集 / 单视频，向后兼容）。
  static int _episodeIndexFromRequest(shelf.Request request) {
    final String? raw = request.url.queryParameters['episode'];
    if (raw == null) return 0;
    final int? n = int.tryParse(raw);
    if (n == null || n < 0) return 0;
    return n;
  }

  static String? _extractVideoId(String reqPath, String suffix) {
    const String prefix = '/api/library/videos/';
    final String fullSuffix = '/$suffix';
    if (!reqPath.startsWith(prefix)) return null;
    if (!reqPath.endsWith(fullSuffix)) return null;
    final String id =
        reqPath.substring(prefix.length, reqPath.length - fullSuffix.length);
    if (id.isEmpty) return null;
    // 只拒 `..`（路径穿越），允许 `/`（bookUid 形如 video/xxx）
    if (id.contains('..') || id.contains('\\')) return null;
    return id;
  }

  Future<shelf.Response> _handleLibraryVideos(
    shelf.Request request,
    String method,
    String reqPath,
  ) async {
    final HibikiLibraryHostService? svc = _libraryService;
    if (svc == null) return shelf.Response.notFound('Library service off');

    // GET /api/library/videos — 列表（需 Basic 鉴权，中间件已处理）
    if (reqPath == '/api/library/videos') {
      if (method != 'GET') return shelf.Response(405);
      final List<RemoteVideoInfo> list = await svc.listVideos();
      return shelf.Response.ok(
        jsonEncode(<Map<String, Object?>>[
          for (final RemoteVideoInfo v in list)
            _remoteVideoJsonForRequest(v, request)
        ]),
        headers: <String, String>{'Content-Type': 'application/json'},
      );
    }

    // GET /api/library/videos/<id>/cover — 视频封面（需 Basic 鉴权）
    final String? coverId = _extractVideoId(reqPath, 'cover');
    if (coverId != null) {
      if (method != 'GET') return shelf.Response(405);
      final File? cover = await _resolveVideoCover(svc, coverId);
      if (cover == null) {
        return shelf.Response.notFound('Video cover not found');
      }
      return serveFileWithRange(cover, request);
    }

    // GET /api/library/videos/<id>/streamurl — 签发短时 token（需 Basic 鉴权）
    final String? streamUrlId = _extractVideoId(reqPath, 'streamurl');
    if (streamUrlId != null) {
      if (method != 'GET') return shelf.Response(405);
      // TODO-885: 远端播放列表按集——?episode=N 决定流式哪一集（DB-only 反查）。
      final int episodeIndex = _episodeIndexFromRequest(request);
      final File? file =
          await svc.resolveVideoFile(streamUrlId, episodeIndex: episodeIndex);
      if (file == null) return shelf.Response.notFound('Video not found');
      final String tokenValue = _generateVideoToken();
      _videoStreamTokens[tokenValue] = _VideoStreamToken(
        videoId: streamUrlId,
        createdAt: _now(),
        episodeIndex: episodeIndex,
      );
      final String encodedId = Uri.encodeFull(streamUrlId);
      // stream / subtitle URL 都带 episode=N，让 client 取流 / 下字幕命中同一集。
      final Map<String, String> streamQuery = <String, String>{
        'token': tokenValue,
        if (episodeIndex > 0) 'episode': '$episodeIndex',
      };
      final Uri streamUri = request.requestedUri.replace(
        path: '/api/library/videos/$encodedId/stream',
        queryParameters: streamQuery,
      );
      // subtitle URL 不含 token（走 Basic 鉴权），但带 episode=N。
      final File? sub = await svc.resolveVideoSubtitle(streamUrlId,
          episodeIndex: episodeIndex);
      final Uri? subtitleUri = sub != null
          ? request.requestedUri.replace(
              path: '/api/library/videos/$encodedId/subtitle',
              queryParameters: <String, String>{
                if (episodeIndex > 0) 'episode': '$episodeIndex',
              },
            )
          : null;
      final List<RemoteVideoEmbeddedSubtitleTrack> embeddedTracks =
          await _embeddedSubtitleTracksForRequest(
        file,
        request,
        streamUrlId,
        episodeIndex,
      );
      return _jsonResponse(<String, dynamic>{
        'url': streamUri.toString(),
        'subtitleUrl': subtitleUri?.toString(),
        if (sub != null) 'subtitleFileName': p.basename(sub.path),
        if (embeddedTracks.isNotEmpty)
          'embeddedSubtitleTracks': <Map<String, Object?>>[
            for (final RemoteVideoEmbeddedSubtitleTrack track in embeddedTracks)
              track.toJson(),
          ],
      });
    }

    // GET /api/library/videos/<id>/stream — 流式传输（豁免 Basic，靠 token 鉴权）
    final String? streamId = _extractVideoId(reqPath, 'stream');
    if (streamId != null) {
      if (method != 'GET') return shelf.Response(405);
      _pruneVideoTokens();
      final String? tokenValue = request.url.queryParameters['token'];
      if (tokenValue == null || tokenValue.isEmpty) {
        return shelf.Response(401,
            body: 'Missing token',
            headers: <String, String>{'Content-Type': 'text/plain'});
      }
      final _VideoStreamToken? tok = _videoStreamTokens[tokenValue];
      if (tok == null || tok.videoId != streamId) {
        return shelf.Response(403,
            body: 'Invalid or expired token',
            headers: <String, String>{'Content-Type': 'text/plain'});
      }
      // TODO-885: 用 token 绑定的集下标反查（token 是 streamurl 签发时定的，client 不能
      // 自己改集——?episode 只决定 streamurl 阶段，stream 阶段以 token 为准）。
      final File? file =
          await svc.resolveVideoFile(streamId, episodeIndex: tok.episodeIndex);
      if (file == null) return shelf.Response.notFound('Video not found');
      return serveFileWithRange(file, request);
    }

    // GET /api/library/videos/<id>/subtitle — 字幕（需 Basic 鉴权，中间件已处理）
    final String? subtitleId = _extractVideoId(reqPath, 'subtitle');
    if (subtitleId != null) {
      if (method != 'GET') return shelf.Response(405);
      final int episodeIndex = _episodeIndexFromRequest(request);
      final String? embeddedIndexText =
          request.url.queryParameters['embeddedStreamIndex'];
      final File? sub = embeddedIndexText == null
          ? await svc.resolveVideoSubtitle(subtitleId,
              episodeIndex: episodeIndex)
          : await _resolveEmbeddedVideoSubtitle(
              svc,
              subtitleId,
              int.tryParse(embeddedIndexText),
              episodeIndex,
            );
      if (sub == null) return shelf.Response.notFound('Subtitle not found');
      final int length = sub.lengthSync();
      return shelf.Response.ok(
        sub.openRead(),
        headers: <String, String>{
          'Content-Type': _guessContentType(sub.path),
          'Content-Length': '$length',
        },
      );
    }

    // GET/PUT /api/library/videos/<id>/position — 跨设备播放断点（TODO-653）
    // GET 让 client 拉取 host 真相源进度；PUT 让 client 上报本端进度（host 取较新者）。
    final String? positionId = _extractVideoId(reqPath, 'position');
    if (positionId != null) {
      final int episodeIndex = _episodeIndexFromRequest(request);
      // 先确认该视频 id（含集下标）在 host DB 真实存在，防止任意 id 写脏 prefs。
      final File? file =
          await svc.resolveVideoFile(positionId, episodeIndex: episodeIndex);
      if (file == null) return shelf.Response.notFound('Video not found');
      switch (method) {
        case 'GET':
          final ({int positionMs, int updatedAtMs}) p = await svc
              .getVideoPosition(positionId, episodeIndex: episodeIndex);
          return _jsonResponse(<String, dynamic>{
            'positionMs': p.positionMs,
            'positionUpdatedAtMs': p.updatedAtMs,
          });
        case 'PUT':
          final String body = await request.readAsString();
          Map<String, dynamic> json;
          try {
            json = jsonDecode(body) as Map<String, dynamic>;
          } catch (_) {
            return shelf.Response(400, body: 'Invalid JSON');
          }
          final int posMs = (json['positionMs'] as num?)?.toInt() ?? 0;
          final int updatedAtMs =
              (json['positionUpdatedAtMs'] as num?)?.toInt() ?? 0;
          await svc.putVideoPosition(positionId, posMs, updatedAtMs,
              episodeIndex: episodeIndex);
          return shelf.Response(200);
        default:
          return shelf.Response(405);
      }
    }

    // PUT /api/library/videos/<id> — client→host 上传本地视频文件并注册进 host 视频库
    // （syncVideoFiles 开关驱动的 live push）。走到此处的 PUT 必是「裸 id 无 suffix」：
    // 所有带 suffix 的端点（cover/streamurl/stream/subtitle/position）已在上方消化（非
    // GET 的 suffix 请求返回 405，position 的 PUT 已被上面 switch 接管）。id 允许含 `/`
    // （bookUid 形如 video/xxx），但拒 `..` / `\`（路径穿越）。title / 原始文件名经
    // URL-encode 走 header（HTTP header 只收 ASCII，日文标题必须编码）。
    if (method == 'PUT' && reqPath.startsWith('/api/library/videos/')) {
      const String prefix = '/api/library/videos/';
      final String id = reqPath.substring(prefix.length);
      if (id.isEmpty || id.contains('..') || id.contains('\\')) {
        return shelf.Response(400, body: 'Invalid video id');
      }
      final String title =
          _decodeHeaderValue(request, 'x-hibiki-video-title') ?? id;
      final String? fileName =
          _decodeHeaderValue(request, 'x-hibiki-video-filename');
      final Directory tmpDir =
          Directory.systemTemp.createTempSync('hibiki_video_in');
      final File tmp = File(p.join(tmpDir.path, 'upload.bin'));
      final IOSink sink = tmp.openWrite();
      try {
        await request.read().forEach(sink.add);
        await sink.close();
        await svc.importVideo(tmp,
            id: id, title: title, originalFileName: fileName);
        return shelf.Response(200);
      } catch (e) {
        try {
          await sink.close();
        } catch (_) {
          // best-effort
        }
        return shelf.Response(500, body: 'Video import failed: $e');
      } finally {
        try {
          tmpDir.deleteSync(recursive: true);
        } catch (_) {
          // best-effort
        }
      }
    }

    return shelf.Response.notFound('Not found');
  }

  /// 从请求 header 读一个 URL-encoded 值并解码（HTTP header 只收 ASCII，非 ASCII 值
  /// 由 client 端 [Uri.encodeComponent] 编码）。缺失/空返回 null；解码失败退回原文。
  static String? _decodeHeaderValue(shelf.Request request, String name) {
    final String? raw = request.headers[name];
    if (raw == null || raw.isEmpty) return null;
    try {
      return Uri.decodeComponent(raw);
    } catch (_) {
      return raw;
    }
  }

  Map<String, Object?> _remoteVideoJsonForRequest(
    RemoteVideoInfo video,
    shelf.Request request,
  ) {
    final Map<String, Object?> json = video.toJson()
      ..remove('coverUrl')
      ..remove('hasCover');
    if (_coverFile(video.coverPath) != null) {
      final String encodedId = Uri.encodeFull(video.id);
      json['hasCover'] = true;
      json['coverUrl'] = request.requestedUri.replace(
        path: '/api/library/videos/$encodedId/cover',
        queryParameters: <String, String>{},
      ).toString();
    }
    return json;
  }

  Future<List<RemoteVideoEmbeddedSubtitleTrack>>
      _embeddedSubtitleTracksForRequest(
    File videoFile,
    shelf.Request request,
    String videoId,
    int episodeIndex,
  ) async {
    final List<EmbeddedSubtitleTrack> tracks =
        await listEmbeddedSubtitleTracks(videoFile.path);
    final String encodedId = Uri.encodeFull(videoId);
    final String videoStem = p.basenameWithoutExtension(videoFile.path);
    return <RemoteVideoEmbeddedSubtitleTrack>[
      for (final EmbeddedSubtitleTrack track in tracks)
        _remoteEmbeddedSubtitleTrackForRequest(
          track,
          request,
          encodedId,
          videoStem,
          episodeIndex,
        ),
    ];
  }

  RemoteVideoEmbeddedSubtitleTrack _remoteEmbeddedSubtitleTrackForRequest(
    EmbeddedSubtitleTrack track,
    shelf.Request request,
    String encodedId,
    String videoStem,
    int episodeIndex,
  ) {
    final String? extension = subtitleExtensionForCodec(track.codec);
    final bool isText = extension != null;
    return RemoteVideoEmbeddedSubtitleTrack(
      streamIndex: track.streamIndex,
      codec: track.codec,
      language: track.language,
      title: track.title,
      isText: isText,
      url: isText
          ? request.requestedUri.replace(
              path: '/api/library/videos/$encodedId/subtitle',
              queryParameters: <String, String>{
                'embeddedStreamIndex': '${track.streamIndex}',
                if (episodeIndex > 0) 'episode': '$episodeIndex',
              },
            ).toString()
          : null,
      fileName: isText
          ? '${_safeDownloadStem(videoStem)}.embedded.${track.streamIndex}$extension'
          : null,
    );
  }

  static String _safeDownloadStem(String value) {
    final String safe = value.replaceAll(RegExp(r'[^A-Za-z0-9._-]+'), '_');
    return safe.isEmpty ? 'video' : safe;
  }

  Future<File?> _resolveEmbeddedVideoSubtitle(
    HibikiLibraryHostService service,
    String id,
    int? streamIndex,
    int episodeIndex,
  ) async {
    if (streamIndex == null || streamIndex < 0) return null;
    final File? videoFile =
        await service.resolveVideoFile(id, episodeIndex: episodeIndex);
    if (videoFile == null) return null;
    final List<EmbeddedSubtitleTrack> tracks =
        await listEmbeddedSubtitleTracks(videoFile.path);
    for (final EmbeddedSubtitleTrack track in tracks) {
      if (track.streamIndex != streamIndex) continue;
      if (subtitleFormatForCodec(track.codec) == null) return null;
      return extractEmbeddedSubtitleTrackFile(
        videoPath: videoFile.path,
        streamIndex: track.streamIndex,
        codec: track.codec,
      );
    }
    return null;
  }

  Future<File?> _resolveVideoCover(
    HibikiLibraryHostService service,
    String id,
  ) async {
    // 单行直查（videoCoverPath = 1 次 DB 查询 + stat）。旧实现每张封面请求重跑
    // 整份 listVideos()（每行一次目录扫描 + 多次 DB 查询），N 张封面 = O(N²)，
    // 500 视频的封面墙一次浏览拖成分钟级——这是「互联视频极慢」的主根因。
    return _coverFile(await service.videoCoverPath(id));
  }

  static File? _coverFile(String? path) {
    if (path == null || path.isEmpty) return null;
    final File file = File(path);
    return file.existsSync() ? file : null;
  }

  String _generateVideoToken() {
    final Random random = Random.secure();
    final List<int> bytes = List<int>.generate(24, (_) => random.nextInt(256));
    return base64UrlEncode(bytes);
  }

  void _pruneVideoTokens() {
    // 视频播放时间长，token 有效期设为 6 小时
    final DateTime cutoff = _now().subtract(const Duration(hours: 6));
    _videoStreamTokens.removeWhere(
      (String _, _VideoStreamToken token) => token.createdAt.isBefore(cutoff),
    );
  }

  /// 聚合（统计 + 收藏）跨设备 live 端点（TODO-1056 phase C）。
  ///
  /// GET /api/library/aggregate — materialize host 自己的聚合快照（四张统计表 +
  /// 挖掘计数 + 收藏词 + 收藏句）返回 JSON，供 client 拉取 host 真相源。
  /// PUT /api/library/aggregate — client 上报（已在 client 端与 host 并集合并的）
  /// 快照，host 用 MAX / 并集 upsert 折叠进自己 DB（幂等，删除不跨端传播）。
  ///
  /// 鉴权：不在中间件豁免名单，故自动走 Basic token 全量校验（已配对 peer 才可访问）。
  /// 容错：坏 JSON → 400；service 未接线 → 404；apply 内部错误经 500 暴露（不静默）。
  Future<shelf.Response> _handleLibraryAggregate(
    shelf.Request request,
    String method,
    String reqPath,
  ) async {
    final HibikiLibraryHostService? svc = _libraryService;
    if (svc == null) return shelf.Response.notFound('Library service off');

    switch (method) {
      case 'GET':
        final AggregateSnapshot snapshot = await svc.getAggregateSnapshot();
        return shelf.Response.ok(
          jsonEncode(snapshot.toJson()),
          // charset=utf-8 必带：快照里的书名/标题/义项含 CJK，client 用
          // package:http `.body` 默认按 latin1 解码会乱码（同 _jsonResponse）。
          headers: <String, String>{
            'Content-Type': 'application/json; charset=utf-8'
          },
        );
      case 'PUT':
        final Map<String, dynamic>? json = await _readJsonObject(request);
        if (json == null) return shelf.Response(400, body: 'Invalid JSON');
        // fromJson 容错：未知高版本 / 缺字段 / 坏行降级为空或跳过，绝不抛。
        final AggregateSnapshot snapshot = AggregateSnapshot.fromJson(json);
        await svc.applyAggregateSnapshot(snapshot);
        return shelf.Response(200);
      default:
        return shelf.Response(405);
    }
  }

  /// 合集清单跨设备 live 端点（多端库联合视图 §2.3 任务5.2）。
  ///
  /// GET /api/library/collections — 返回 host 当前合集全量快照清单
  /// （[HibikiLibraryHostService.getCollectionManifest] 的 canonicalJson），供 client
  /// 拉取 host 合集真相源做读-合并-写。
  /// POST /api/library/collections — client 上报本端合集清单，host 经
  /// [HibikiLibraryHostService.mergeCollectionManifest] 并入自己 DB（成员并集 + 移出/
  /// 删除墓碑防复活 + 手动序整合集 LWW，语义在 CollectionSyncEngine），返回合并后清单。
  ///
  /// 鉴权：不在中间件豁免名单，故自动走 Basic token 全量校验（已配对 peer 才可访问，
  /// 与 aggregate 端点同纪律）。容错：坏 JSON / 非法/高版本清单 → 400（不静默按旧
  /// 语义误读新字段污染 host 数据，与 [CollectionManifest.fromJson] 的版本闸门一致）。
  Future<shelf.Response> _handleLibraryCollections(
    shelf.Request request,
    String method,
    String reqPath,
  ) async {
    final HibikiLibraryHostService? svc = _libraryService;
    if (svc == null) return shelf.Response.notFound('Library service off');

    switch (method) {
      case 'GET':
        final CollectionManifest manifest = await svc.getCollectionManifest();
        return shelf.Response.ok(
          manifest.canonicalJson(),
          // charset=utf-8 必带：合集名含 CJK，client 用 package:http `.body` 默认按
          // latin1 解码会乱码（同 aggregate / _jsonResponse）。
          headers: <String, String>{
            'Content-Type': 'application/json; charset=utf-8'
          },
        );
      case 'POST':
        final Map<String, dynamic>? json = await _readJsonObject(request);
        if (json == null) return shelf.Response(400, body: 'Invalid JSON');
        CollectionManifest incoming;
        try {
          incoming = CollectionManifest.fromJson(json);
        } on FormatException catch (e) {
          return shelf.Response(400, body: 'Invalid manifest: $e');
        }
        final CollectionManifest merged =
            await svc.mergeCollectionManifest(incoming);
        return shelf.Response.ok(
          merged.canonicalJson(),
          headers: <String, String>{
            'Content-Type': 'application/json; charset=utf-8'
          },
        );
      default:
        return shelf.Response(405);
    }
  }

  Future<Map<String, dynamic>?> _readJsonObject(shelf.Request request) async {
    try {
      final String body = await request.readAsString();
      final dynamic decoded = jsonDecode(body);
      if (decoded is Map<String, dynamic>) return decoded;
      if (decoded is Map) return Map<String, dynamic>.from(decoded);
    } catch (_) {
      return null;
    }
    return null;
  }

  shelf.Response _jsonResponse(Map<String, dynamic> body) {
    return shelf.Response.ok(
      jsonEncode(body),
      // TODO-752a：必须带 charset=utf-8。否则远程查词 client 用 package:http 的
      // `.body` 读取时按 latin1 默认解码，CJK 词典义项/书名直接乱码。
      headers: <String, String>{
        'Content-Type': 'application/json; charset=utf-8'
      },
    );
  }

  String _generateAudioToken() {
    final Random random = Random.secure();
    final List<int> bytes = List<int>.generate(18, (_) => random.nextInt(256));
    return base64UrlEncode(bytes);
  }

  void _pruneAudioTokens() {
    final DateTime cutoff = _now().subtract(const Duration(minutes: 5));
    _remoteAudioTokens.removeWhere(
      (String _, _RemoteAudioToken token) => token.createdAt.isBefore(cutoff),
    );
  }

  /// BUG-908(a)：守住音频 token 上限。TTL prune 之后仍达到 [_maxAudioTokens] 时，按
  /// createdAt 淘汰最旧者直到回到上限内（对照 [_enforcePairSessionCap]）。签发前调用，
  /// 使插入新 token 后总数 <= [_maxAudioTokens]。只 POST 不 GET 的膨胀攻击的兜底。
  void _enforceAudioTokenCap() {
    while (_remoteAudioTokens.length >= _maxAudioTokens) {
      String? oldestKey;
      DateTime? oldestAt;
      for (final MapEntry<String, _RemoteAudioToken> e
          in _remoteAudioTokens.entries) {
        if (oldestAt == null || e.value.createdAt.isBefore(oldestAt)) {
          oldestAt = e.value.createdAt;
          oldestKey = e.key;
        }
      }
      if (oldestKey == null) break;
      _remoteAudioTokens.remove(oldestKey);
    }
  }

  /// BUG-908(a) 测试钩子：当前驻留的音频 token 数（验证 cap 逐出行为）。
  @visibleForTesting
  int get remoteAudioTokenCount => _remoteAudioTokens.length;

  /// TODO-961 M1：清掉 [_pairSessionTtl] 之前创建的配对会话。对照
  /// [_pruneAudioTokens] / [_pruneVideoTokens]：按 createdAt + 注入的 [_now] 判定，
  /// 可单测。在 pair/v2 创建与 confirm 两处调用，使过期会话既不堆积也不可被 confirm。
  void _prunePairSessions() {
    final DateTime cutoff = _now().subtract(_pairSessionTtl);
    _pairSessions.removeWhere(
      (String _, HibikiPairSession s) => s.createdAt.isBefore(cutoff),
    );
  }

  /// TODO-961 M1：守住会话上限。prune 之后仍超过 [_maxPairSessions] 时，按 createdAt
  /// 淘汰最旧的会话直到回到上限内（攻击者用全新 nonce 高频发起 pair/v2、每个都还在
  /// TTL 内时的兜底）。正常一次一会话（_pairDialogOpen 串行审批），此路径几乎不触发。
  void _enforcePairSessionCap() {
    while (_pairSessions.length >= _maxPairSessions) {
      String? oldestKey;
      DateTime? oldestAt;
      for (final MapEntry<String, HibikiPairSession> e
          in _pairSessions.entries) {
        if (oldestAt == null || e.value.createdAt.isBefore(oldestAt)) {
          oldestAt = e.value.createdAt;
          oldestKey = e.key;
        }
      }
      if (oldestKey == null) break;
      _pairSessions.remove(oldestKey);
    }
  }

  /// 测试钩子：当前进行中的配对会话数（验证 prune/cap 行为）。
  @visibleForTesting
  int get pendingPairSessionCount => _pairSessions.length;

  /// TODO-961 M3 测试钩子：当前限速器跟踪的来源记录数（验证 prune 不泄漏）。
  @visibleForTesting
  int get pinRateLimitTrackedSourceCount => _pinRateLimiter.trackedSourceCount;

  Future<shelf.Response> _handlePropfind(
      shelf.Request request, String davPath, String fsPath) async {
    final depth = request.headers['depth'] ?? '1';
    // BUG-908(b)：逐项 stat 一律异步，避免在事件循环上做阻塞式系统调用（大目录
    // PROPFIND 会串起成百上千次同步 stat，卡住整个 server）。
    final entity = await FileSystemEntity.type(fsPath);

    if (entity == FileSystemEntityType.notFound) {
      return shelf.Response.notFound('Not found');
    }

    final entries = <_DavEntry>[];
    final normPath = davPath.endsWith('/') ? davPath : '$davPath/';

    if (entity == FileSystemEntityType.directory) {
      entries.add(_DavEntry(
        href: normPath,
        isCollection: true,
        displayName: p.basename(fsPath),
        contentLength: 0,
      ));

      if (depth == '1') {
        final dir = Directory(fsPath);
        await for (final child in dir.list()) {
          final childName = p.basename(child.path);
          final isDir = child is Directory;
          final childHref = '$normPath$childName${isDir ? '/' : ''}';
          // BUG-908(b)：文件长度用异步 stat（await for 循环里安全 await，不打乱 XML
          // 组装顺序）；目录不必取长度。
          final length = isDir ? 0 : (await (child as File).stat()).size;
          entries.add(_DavEntry(
            href: childHref,
            isCollection: isDir,
            displayName: childName,
            contentLength: length,
          ));
        }
      }
    } else {
      final file = File(fsPath);
      // BUG-908(b)：单文件长度也用异步 stat。
      final int fileLength = (await file.stat()).size;
      entries.add(_DavEntry(
        href: davPath,
        isCollection: false,
        displayName: p.basename(fsPath),
        contentLength: fileLength,
      ));
    }

    final xml = StringBuffer('<?xml version="1.0" encoding="utf-8"?>\n')
      ..write('<d:multistatus xmlns:d="DAV:">\n');
    for (final entry in entries) {
      xml
        ..write('<d:response>\n')
        ..write('<d:href>${_xmlEscape(Uri.encodeFull(entry.href))}</d:href>\n')
        ..write('<d:propstat>\n')
        ..write('<d:prop>\n')
        ..write(
            '<d:displayname>${_xmlEscape(entry.displayName)}</d:displayname>\n')
        ..write('<d:resourcetype>')
        ..write(entry.isCollection ? '<d:collection/>' : '')
        ..write('</d:resourcetype>\n');
      if (!entry.isCollection) {
        xml.write(
            '<d:getcontentlength>${entry.contentLength}</d:getcontentlength>\n');
      }
      xml
        ..write('</d:prop>\n')
        ..write('<d:status>HTTP/1.1 200 OK</d:status>\n')
        ..write('</d:propstat>\n')
        ..write('</d:response>\n');
    }
    xml.write('</d:multistatus>');

    return shelf.Response(207,
        body: xml.toString(),
        headers: {'Content-Type': 'application/xml; charset=utf-8'});
  }

  Future<shelf.Response> _handleGet(String fsPath) async {
    final file = File(fsPath);
    if (!file.existsSync()) return shelf.Response.notFound('Not found');
    return shelf.Response.ok(
      file.openRead(),
      headers: {
        'Content-Type': _guessContentType(fsPath),
        'Content-Length': '${file.lengthSync()}',
      },
    );
  }

  Future<shelf.Response> _handlePut(
      shelf.Request request, String fsPath) async {
    final parent = Directory(p.dirname(fsPath));
    if (!parent.existsSync()) parent.createSync(recursive: true);
    final file = File(fsPath);
    final existed = file.existsSync();
    final sink = file.openWrite();
    try {
      await request.read().forEach(sink.add);
      await sink.close();
    } catch (e) {
      // The request stream errored mid-body. Close the sink and remove the
      // truncated file rather than leaving a corrupt file behind a 201/204
      // response — matching the download paths' cleanup (HBK-AUDIT-029).
      try {
        await sink.close();
      } catch (_) {/* best-effort: failure is non-critical here */}
      if (file.existsSync()) {
        try {
          file.deleteSync();
        } catch (_) {/* best-effort: failure is non-critical here */}
      }
      return shelf.Response(500, body: 'Write failed');
    }
    return shelf.Response(existed ? 204 : 201);
  }

  Future<shelf.Response> _handleMkcol(String fsPath) async {
    final dir = Directory(fsPath);
    if (dir.existsSync()) return shelf.Response(405);
    dir.createSync(recursive: true);
    return shelf.Response(201);
  }

  Future<shelf.Response> _handleDelete(String fsPath) async {
    final type = FileSystemEntity.typeSync(fsPath);
    if (type == FileSystemEntityType.notFound) {
      return shelf.Response.notFound('Not found');
    }
    if (type == FileSystemEntityType.directory) {
      await Directory(fsPath).delete(recursive: true);
    } else {
      await File(fsPath).delete();
    }
    return shelf.Response(204);
  }

  Future<shelf.Response> _handleHead(String fsPath) async {
    final file = File(fsPath);
    if (!file.existsSync()) return shelf.Response.notFound('Not found');
    return shelf.Response.ok(null, headers: {
      'Content-Type': _guessContentType(fsPath),
      'Content-Length': '${file.lengthSync()}',
    });
  }

  static String _guessContentType(String filePath) {
    final ext = p.extension(filePath).toLowerCase();
    switch (ext) {
      case '.json':
        return 'application/json';
      case '.epub':
        return 'application/epub+zip';
      case '.mp3':
        return 'audio/mpeg';
      case '.m4a':
      case '.m4b':
        return 'audio/mp4';
      case '.ogg':
        return 'audio/ogg';
      case '.flac':
        return 'audio/flac';
      case '.jpg':
      case '.jpeg':
        return 'image/jpeg';
      case '.png':
        return 'image/png';
      // ── 视频格式（P4-1）──────────────────────────────────────────────────────
      case '.mp4':
      case '.m4v':
        return 'video/mp4';
      case '.mkv':
        return 'video/x-matroska';
      case '.webm':
        return 'video/webm';
      case '.avi':
        return 'video/x-msvideo';
      case '.mov':
        return 'video/quicktime';
      case '.ts':
      case '.m2ts':
      case '.mts':
        return 'video/mp2t';
      case '.flv':
        return 'video/x-flv';
      case '.wmv':
        return 'video/x-ms-wmv';
      case '.mpg':
      case '.mpeg':
        return 'video/mpeg';
      case '.ogv':
        return 'video/ogg';
      case '.3gp':
        return 'video/3gpp';
      // ── 字幕格式 ──────────────────────────────────────────────────────────────
      case '.srt':
        return 'text/plain; charset=utf-8';
      case '.ass':
      case '.ssa':
        return 'text/plain; charset=utf-8';
      case '.vtt':
        return 'text/vtt; charset=utf-8';
      default:
        return 'application/octet-stream';
    }
  }

  static String _xmlEscape(String s) => s
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;');
}

// ── Range 流式传输辅助（P4-1）────────────────────────────────────────────────

/// HTTP `Range: bytes=` 解析结果。
///
/// [start] / [end] 均为闭区间（如 `0..99` 表示前 100 字节）。
/// [unsatisfiable] 为 true 时表示范围越界或格式合法但不可满足（应回 416）。
class ByteRange {
  const ByteRange({required this.start, required this.end});

  /// 不可满足的特殊单例（start==-1, end==-1）。
  static const ByteRange unsatisfiable = ByteRange(start: -1, end: -1);

  final int start;
  final int end;

  bool get isUnsatisfiable => start == -1 && end == -1;

  /// 区间字节数（闭区间长度）。
  int get length => isUnsatisfiable ? 0 : end - start + 1;

  @override
  String toString() =>
      isUnsatisfiable ? 'ByteRange.unsatisfiable' : 'ByteRange($start-$end)';
}

/// 纯函数：解析 `Range: bytes=<spec>` 头，返回闭区间 [ByteRange]。
///
/// 支持三种合法格式（RFC 7233）：
/// - `bytes=start-end`：完整范围（两端均含）。
/// - `bytes=start-`：从 [start] 到文件末尾。
/// - `bytes=-suffix`：文件最后 [suffix] 字节。
///
/// 以下情况返回 [ByteRange.unsatisfiable]（调用方回 416）：
/// - [rangeHeader] 为 null/空：**不返回 unsatisfiable，返回 null**（表示无 Range 头，
///   调用方回 200 全量）——通过返回 `null` 区分「无头」与「不可满足」。
/// - 格式不符（非 `bytes=` 前缀、缺 `-`、非数字）：返回 unsatisfiable。
/// - suffix=0：返回 unsatisfiable（RFC 7233 §2.1 suffix-length 为 0 无意义）。
/// - 解析后范围越界（start >= fileLength）：返回 unsatisfiable。
/// - start > end（规范化后）：返回 unsatisfiable。
ByteRange? parseByteRange(String? rangeHeader, int fileLength) {
  if (rangeHeader == null || rangeHeader.isEmpty) return null;
  if (!rangeHeader.startsWith('bytes=')) return ByteRange.unsatisfiable;

  final String spec = rangeHeader.substring(6).trim(); // 去掉 'bytes='
  final int dashIdx = spec.indexOf('-');
  if (dashIdx < 0) return ByteRange.unsatisfiable;

  final String startStr = spec.substring(0, dashIdx).trim();
  final String endStr = spec.substring(dashIdx + 1).trim();

  int start;
  int end;

  if (startStr.isEmpty) {
    // `-suffix` 形式
    final int? suffix = int.tryParse(endStr);
    if (suffix == null || suffix <= 0) return ByteRange.unsatisfiable;
    start = fileLength - suffix;
    if (start < 0) start = 0;
    end = fileLength - 1;
  } else {
    // `start-` 或 `start-end` 形式
    final int? parsedStart = int.tryParse(startStr);
    if (parsedStart == null || parsedStart < 0) {
      return ByteRange.unsatisfiable;
    }
    start = parsedStart;

    if (endStr.isEmpty) {
      // `start-` 形式
      end = fileLength - 1;
    } else {
      final int? parsedEnd = int.tryParse(endStr);
      if (parsedEnd == null || parsedEnd < 0) {
        return ByteRange.unsatisfiable;
      }
      // RFC 7233: end 超出文件末尾时钳制到 fileLength-1（不算越界）
      end = parsedEnd < fileLength ? parsedEnd : fileLength - 1;
    }
  }

  // 越界检查：start 超出文件末尾才是真正不可满足
  if (fileLength == 0 || start >= fileLength) {
    return ByteRange.unsatisfiable;
  }
  if (start > end) return ByteRange.unsatisfiable;

  return ByteRange(start: start, end: end);
}

/// shelf handler helper：对 [file] 提供 Range 感知流式响应。
///
/// - 有合法 `Range` 头 → `206 Partial Content` + `Content-Range` + 字节区间流。
/// - 无 `Range` 头 → `200 OK` + 全量流。
/// - 不可满足的 Range → `416 Range Not Satisfiable` + `Content-Range: bytes */total`。
///
/// 所有路径均加 `Accept-Ranges: bytes`（告知客户端支持 Range）。
/// Content-Type 由 [HibikiSyncServer._guessContentType] 按扩展名确定。
/// 响应体全程流式（`file.openRead(start, end+1)`），不把文件读入内存。
///
/// [etag] 非空时：所有响应带 `ETag` 头；且 Range 请求按 RFC 7233 §3.2 校验
/// `If-Range`——验证器不匹配（服务端字节已换代，如导出缓存过期重导出）时**忽略
/// Range 降级 200 全量**，绝不让 client 把两代字节拼成损坏文件。这是导出包
/// （epub/词典/有声书/本地音频）断点续传的正确性前提：`export*` 重打包不保证
/// 字节稳定，续传必须钉在同一份缓存文件上（见 [HibikiSyncServer._exportCache]）。
///
/// 函数名无下划线前缀（公开），便于测试文件直接导入使用。
Future<shelf.Response> serveFileWithRange(
  File file,
  shelf.Request request, {
  String? etag,
}) async {
  if (!file.existsSync()) {
    return shelf.Response.notFound('File not found');
  }

  final int fileLength = file.lengthSync();
  final String contentType = HibikiSyncServer._guessContentType(file.path);
  String? rangeHeader = request.headers['range'];
  if (etag != null && rangeHeader != null) {
    final String? ifRange = request.headers['if-range'];
    if (ifRange != etag) {
      // 验证器不匹配或缺失：client 手里的 .part 可能属于上一代字节（导出缓存
      // 过期重打包），忽略 Range 整包 200 重发（client 侧 ResumableDownloader
      // 收到 200 会丢弃旧 part 从 0 重写）。带 etag 的调用方声明「字节可能
      // 换代」，故续传**必须**验证器精确匹配——缺 If-Range 的盲 Range 也拒绝，
      // 正确性优先于续传收益（etag == null 的调用方如视频流不受影响）。
      rangeHeader = null;
    }
  }
  final ByteRange? range = parseByteRange(rangeHeader, fileLength);

  // 无 Range 头：200 全量
  if (range == null) {
    return shelf.Response.ok(
      file.openRead(),
      headers: <String, String>{
        'Content-Type': contentType,
        'Content-Length': '$fileLength',
        'Accept-Ranges': 'bytes',
        if (etag != null) 'ETag': etag,
      },
    );
  }

  // Range 不可满足：416
  if (range.isUnsatisfiable) {
    return shelf.Response(
      416,
      headers: <String, String>{
        'Content-Range': 'bytes */$fileLength',
        'Accept-Ranges': 'bytes',
        if (etag != null) 'ETag': etag,
      },
    );
  }

  // 合法 Range：206 Partial Content
  final int rangeLength = range.length;
  return shelf.Response(
    206,
    body: file.openRead(range.start, range.end + 1),
    headers: <String, String>{
      'Content-Type': contentType,
      'Content-Length': '$rangeLength',
      'Content-Range': 'bytes ${range.start}-${range.end}/$fileLength',
      'Accept-Ranges': 'bytes',
      if (etag != null) 'ETag': etag,
    },
  );
}

/// 导出包进程级缓存：包端点（epub/词典/有声书/本地音频）Range 续传的字节稳定性
/// 基础。
///
/// `export*` 每次调用重新打包，zip 条目时间戳等使两次导出的字节**不保证相同**——
/// 若直接对每请求的临时导出文件做 Range，「第一次 200 的前半 + 第二次 206 的
/// 后半」会拼出损坏包。因此导出结果搬进缓存目录保留 [ttl]：TTL 内同一 (kind,id)
/// 的续传请求命中同一份字节；过期重导出后 ETag 变化，`If-Range` 不匹配自动降级
/// 200 全量（见 [serveFileWithRange]）。
///
/// 并发：同 key 的 in-flight 导出去重（并发首下载只打包一次）；换代旧文件删除是
/// best-effort（Windows 上被正在流式的请求占用则删不掉，留给 [dispose] 整目录
/// 清理——缓存目录是 `createTempSync` 的进程私有目录，进程退出后 OS 临时目录
/// 策略兜底）。
class ExportPackageCache {
  ExportPackageCache({this.ttl = const Duration(minutes: 15)});

  final Duration ttl;
  Directory? _root;
  final Map<String, File> _latest = <String, File>{};
  final Map<String, Future<File>> _inFlight = <String, Future<File>>{};
  int _seq = 0;

  Directory get _dir =>
      _root ??= Directory.systemTemp.createTempSync('hibiki_export_cache');

  /// 取 (kind,id) 的缓存导出文件；TTL 内直接命中，否则经 [export] 重新打包。
  /// [export] 返回的临时文件（连同其父临时目录）所有权移交本缓存。
  Future<File> obtain(
    String kind,
    String id,
    Future<File> Function() export,
  ) {
    final String key = '$kind|$id';
    final File? hit = _latest[key];
    if (hit != null && hit.existsSync()) {
      try {
        if (DateTime.now().difference(hit.lastModifiedSync()) < ttl) {
          return Future<File>.value(hit);
        }
      } catch (_) {
        // stat 失败：当 miss 处理，走重导出。
      }
    }
    // 注意回调必须用块体：`=> _inFlight.remove(key)` 会把被移除的 Future（即本
    // whenComplete 链自身）作为回调返回值交还 whenComplete，而 whenComplete 对
    // 返回的 Future 会等其完成——自己等自己，永久死锁。
    return _inFlight[key] ??= _produce(key, export).whenComplete(() {
      _inFlight.remove(key);
    });
  }

  /// 缓存文件的强验证器（`"pkg-<代数>-<size>-<mtimeMs>"`）：字节换代 ⇒ 值必变。
  /// 代数取自缓存文件名前缀 `e<seq>_`（进程内单调，快速换代时 size+mtime 粒度
  /// 不够也不撞车）；mtime 兜底跨进程重启的唯一性。纯 ASCII（CJK 词典名不进
  /// ETag——header 值必须 ASCII 安全）。
  static String etagFor(File file) {
    final String base = p.basename(file.path);
    final int us = base.indexOf('_');
    final String seq =
        (base.startsWith('e') && us > 1) ? base.substring(1, us) : '0';
    final int mtime = file.lastModifiedSync().millisecondsSinceEpoch;
    return '"pkg-$seq-${file.lengthSync()}-$mtime"';
  }

  Future<File> _produce(String key, Future<File> Function() export) async {
    final File exported = await export();
    // 保留原始文件名（扩展名决定 Content-Type，如 .epub → application/epub+zip），
    // 前缀序号防同名不同 key 撞车。
    final File target =
        File(p.join(_dir.path, 'e${_seq++}_${p.basename(exported.path)}'));
    try {
      exported.renameSync(target.path);
    } on FileSystemException {
      // 跨盘 rename 失败：复制兜底。
      exported.copySync(target.path);
    }
    try {
      exported.parent.deleteSync(recursive: true);
    } catch (_) {
      // best-effort：导出方的临时父目录
    }
    final File? old = _latest[key];
    _latest[key] = target;
    if (old != null) {
      try {
        old.deleteSync();
      } catch (_) {
        // Windows 占用中：留给 dispose 整目录清理。
      }
    }
    return target;
  }

  /// 清空缓存目录（服务器 stop 时调用；best-effort）。
  void dispose() {
    _latest.clear();
    _inFlight.clear();
    final Directory? root = _root;
    _root = null;
    if (root == null) return;
    try {
      root.deleteSync(recursive: true);
    } catch (_) {
      // best-effort：仍被占用的文件随 OS 临时目录策略清理。
    }
  }
}

class _DavEntry {
  const _DavEntry({
    required this.href,
    required this.isCollection,
    required this.displayName,
    required this.contentLength,
  });

  final String href;
  final bool isCollection;
  final String displayName;
  final int contentLength;
}

class _RemoteAudioToken {
  _RemoteAudioToken({
    required this.bytes,
    required this.contentType,
    required this.createdAt,
  });

  final Uint8List bytes;
  final String contentType;

  /// TODO-766: 不是 final——每次被 [_handleAudioFile] 命中都刷新，重置 5 分钟
  /// 过期窗口，使「正在被访问」的音频 token 不会在使用途中过期（惠及播放与制卡）。
  DateTime createdAt;
}

/// 视频流短时 token（P4-2）。
///
/// token 绑定到特定 [videoId]，到期时间由 [_pruneVideoTokens] 管控（6 小时）。
/// 有效期长于音频 token（5 分钟）是因为视频播放时长远超音频片段。
class _VideoStreamToken {
  const _VideoStreamToken({
    required this.videoId,
    required this.createdAt,
    this.episodeIndex = 0,
  });

  /// 绑定的视频 id（即 VideoBooks.bookUid，可含 `/`）。
  final String videoId;
  final DateTime createdAt;

  /// 远端播放列表集下标（TODO-885）；单视频 / 当前集恒 0。
  final int episodeIndex;
}
