import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:fushi/src/dictionary/dictionary_media_types.dart';
import 'package:fushi/src/media/video/video_subtitle_source.dart'
    show
        EmbeddedSubtitleTrack,
        extractEmbeddedSubtitleTrackFile,
        listEmbeddedSubtitleTracks,
        subtitleExtensionForCodec,
        subtitleFormatForCodec;
import 'package:fushi/src/sync/aggregate_snapshot.dart';
import 'package:fushi/src/sync/collection_manifest.dart';
import 'package:fushi/src/sync/fushi_library_host_service.dart';
import 'package:fushi/src/sync/interconnect_profile_transfer.dart';
import 'package:fushi/src/sync/interconnect_service_config.dart';
import 'package:fushi/src/sync/fushi_manga_ocr_host.dart';
import 'package:fushi/src/sync/interconnect_device_name.dart';
import 'package:fushi/src/sync/fushi_remote_api_handlers.dart';
import 'package:fushi/src/sync/pairing/fushi_pairing_protocol.dart';
import 'package:fushi/src/sync/fushi_remote_lookup_service.dart';
import 'package:fushi/src/sync/remote_lookup_routes.dart';
import 'package:fushi_core/fushi_core.dart' show mimeTypeForFilePath;
import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;
import 'package:shelf/shelf.dart' as shelf;
import 'package:shelf/shelf_io.dart' as shelf_io;

part 'fushi_sync_server/auth.part.dart';
part 'fushi_sync_server/pairing.part.dart';
part 'fushi_sync_server/lookup.part.dart';
part 'fushi_sync_server/library.part.dart';
part 'fushi_sync_server/video.part.dart';
part 'fushi_sync_server/sync_state.part.dart';
part 'fushi_sync_server/webdav.part.dart';

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
class FushiPairRequest {
  const FushiPairRequest({
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
/// 通过注入的 [FushiSyncServer.onPeerPaired] 回调把本记录交给 controller 写进
/// `fushi_paired_peers` 表（server 不直连 DB，保持可单测 / 存储层无依赖）。
class FushiPairedPeerRegistration {
  const FushiPairedPeerRegistration({
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

/// Thrown by [FushiSyncServer.start] when the requested port is already bound
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

// ── 跨域共享的顶层 helper（原 FushiSyncServer 的 private static；extension 体内看不到宿主类
//    的 static，故提到库顶层——对包外零可见性变化）。

bool _constantTimeEquals(Uint8List a, Uint8List b) {
  final len = a.length > b.length ? a.length : b.length;
  var result = a.length ^ b.length;
  for (var i = 0; i < len; i++) {
    result |= (i < a.length ? a[i] : 0) ^ (i < b.length ? b[i] : 0);
  }
  return result == 0;
}

String? _extractVideoId(String reqPath, String suffix) {
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

/// 从请求 header 读一个 URL-encoded 值并解码（HTTP header 只收 ASCII，非 ASCII 值
/// 由 client 端 [Uri.encodeComponent] 编码）。缺失/空返回 null；解码失败退回原文。
String? _decodeHeaderValue(shelf.Request request, String name) {
  final String? raw = request.headers[name];
  if (raw == null || raw.isEmpty) return null;
  try {
    return Uri.decodeComponent(raw);
  } catch (_) {
    return raw;
  }
}

File? _coverFile(String? path) {
  if (path == null || path.isEmpty) return null;
  final File file = File(path);
  return file.existsSync() ? file : null;
}

/// MIME 推断收敛到 hibiki_core 单一映射表 [mimeTypeForFilePath]（命名统一轮 G8）。
/// 旧本地 switch 副本缺 `.webp` → webp 封面按 application/octet-stream 下发，
/// 对端 WebView 拒绝内联渲染（BUG-1122）；查共享表后随表修复。保留薄 shim 供
/// 本文件既有调用方。
String _guessContentType(String filePath) => mimeTypeForFilePath(filePath);

class FushiSyncServer {
  FushiSyncServer({
    required String syncDataDir,
    required int port,
    required String token,
    bool allowLan = false,
    FushiRemoteLookupService? remoteLookupService,
    FushiRemoteMiningService? miningService,
    FushiRemoteHistoryService? historyService,
    FushiLibraryHostService? libraryService,
    MangaOcrHostJobManager? mangaOcrJobs,
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
        _mangaOcrJobs = mangaOcrJobs,
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
  final FushiRemoteLookupService? _remoteLookupService;
  final FushiRemoteMiningService? _miningService;
  final FushiRemoteHistoryService? _historyService;
  final FushiLibraryHostService? _libraryService;

  /// 漫画 P3：互联 host 代跑 OCR 的任务管理器（`/api/ocr/*` + capabilities
  /// `mangaOcr` 字段）。null = 未接线（headless/单测/host 未启用），端点 404、
  /// capabilities 不带该字段——老 client / 老 host 双向兼容。
  final MangaOcrHostJobManager? _mangaOcrJobs;

  /// TODO-1215: dictionary media (gaiji/accent SVG, etc.) byte provider.
  /// Injected rather than depending on the FushiDicts singleton directly, so
  /// the server has no compile-time coupling to the dictionary engine and
  /// stays unit-testable. Returns null -> the media endpoint answers 404.
  final Uint8List? Function(String dictionary, String path)?
      _dictionaryMediaProvider;
  final DateTime Function() _now;

  /// 单词音频 token（TTL 5 分钟 + BUG-908(a) 上限 128）与查词/制卡端点的 handler
  /// 正文都收在 [RemoteLookupRoutes]，与 YomitanApiServer 共用一份。
  late final RemoteAudioTokenStore _audioTokens =
      RemoteAudioTokenStore(now: _now);
  late final RemoteLookupRoutes _lookupRoutes = RemoteLookupRoutes(
    audioTokens: _audioTokens,
    lookup: _remoteLookupService,
    mining: _miningService,
  );

  final Map<String, _VideoStreamToken> _videoStreamTokens =
      <String, _VideoStreamToken>{};

  /// BUG-908(d)：WebDAV 写操作（PUT / MKCOL / DELETE）的按路径串行闸门。key 是目标
  /// 文件系统绝对路径，value 是该路径上最近一次写的完成 future。新的写先 await 同一
  /// 路径上前一次写的 future 再执行——同一路径的写串行、不同路径可并行。读操作
  /// （PROPFIND / GET / HEAD）不入闸。仅单路径链式 await、绝不嵌套持锁，故无死锁。
  final Map<String, Future<void>> _davWriteChain = <String, Future<void>>{};

  /// TODO-961 M1：进行中的 v2 配对会话（pair/v2 创建、pair/v2/confirm 消费）。
  /// 内存态、不落盘；server 重启即清空（半截配对作废，安全侧）。
  final Map<String, FushiPairSession> _pairSessions =
      <String, FushiPairSession>{};

  /// TODO-961 M3：PIN 爆破限速器。按来源（client 自报 deviceId，回退来源 IP）聚合
  /// PIN 校验失败；同一来源在滑动窗口内累计到阈值即锁定退避一段时间，期间 confirm
  /// 直接被拒（不再触碰 PIN 比对）。粒度选「来源」而非「会话」的理由见
  /// [FushiPinRateLimiter] 文档：[FushiPairSession.consumed] 已让单会话只能撞一次，
  /// 真正的爆破面是不断开新会话逐个撞——只有按来源聚合才挡得住。纯内存态，随
  /// [_prunePairSessions] 一并 prune 防泄漏；server 重启即清空。
  final FushiPinRateLimiter _pinRateLimiter = FushiPinRateLimiter();

  HttpServer? _server;

  /// Interactive pairing approval. When a client POSTs /api/pair, the server
  /// asks the host UI via this callback (Bluetooth-style "device X wants to
  /// pair — allow?") and only hands out [_token] when it resolves true. While
  /// null (no UI wired), every pairing request is refused, so the raw token is
  /// never handed out without a deliberate human approval on the host device.
  Future<bool> Function(FushiPairRequest request)? onPairRequest;

  /// TODO-961 M1: host 生成 6 位 PIN 并喂给审批弹窗显示的供给器。pair/v2 创建会话时
  /// 调用一次拿到本会话 PIN（同一 PIN 显示给用户、又用于 confirm 时重算比对）。
  /// null（无 UI 接线）时 server 自行用 [FushiPairingProtocol.generatePin] 兜底，
  /// 但因 PIN 不显示给任何人，pinRequired=true 的会话将无法被 confirm（安全侧默认拒）。
  String Function(FushiPairSession session)? onPairPinGenerated;

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
  /// `fushi_paired_peers` 表）。注入而非直连 DB，保持 server 存储层无依赖、可单测。
  /// null（未接线，如纯协议单测）时 confirm 回退派发共享 [_token]，不落 per-peer 行
  /// ——既有 pair_v2 行为零变化（Never break userspace）。
  Future<void> Function(FushiPairedPeerRegistration registration)? onPeerPaired;

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
    // 漫画 P3：host 停机时中止在跑的 OCR 任务（页边界停，断点缓存保留）。
    await _mangaOcrJobs?.disposeAll();
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

  /// TODO-961 M1b：配对新增一台设备 / 吊销一台设备后调用，清 per-peer token 缓存，
  /// 使下一次 [_validateAuth] 从 [pairedPeerTokensProvider] 重新拉取最新集合。
  /// controller 在 upsert / revoke 后调它，保证吊销即时生效、新 token 立即受理。
  void invalidatePeerTokenCache() {
    _cachedPeerTokens = null;
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
      return _lookupRoutes.handleMine(request);
    }
    if (reqPath == '/api/mine/forward') {
      if (method != 'POST') return shelf.Response(405);
      return _lookupRoutes.handleMineForward(request);
    }
    if (reqPath.startsWith('/api/anki/note-type/')) {
      if (method != 'POST') return shelf.Response(405);
      return _lookupRoutes.handleAnkiNoteType(request, reqPath);
    }
    if (reqPath.startsWith('/api/anki/media/dedup/')) {
      if (method != 'POST') return shelf.Response(405);
      return _handleAnkiMediaDedup(request, reqPath);
    }
    if (reqPath == '/api/media/dictionary') {
      if (method != 'GET' && method != 'HEAD') return shelf.Response(405);
      return _handleDictionaryMedia(request, method == 'HEAD');
    }
    if (reqPath == '/api/duplicate') {
      if (method != 'POST') return shelf.Response(405);
      return _lookupRoutes.handleDuplicate(request);
    }
    if (reqPath == '/api/extension/status') {
      if (method != 'POST') return shelf.Response(405);
      return jsonResponse(<String, dynamic>{
        'app': 'fushi',
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
    // 漫画 P3：互联 host 代跑 OCR。鉴权走上方 middleware（无豁免），处理逻辑在
    // fushi_manga_ocr_host.dart（本文件是共享热点，只留最小分发）。
    if (reqPath == '/api/ocr/job' || reqPath.startsWith('/api/ocr/job/')) {
      final MangaOcrHostJobManager? mangaOcr = _mangaOcrJobs;
      if (mangaOcr == null) return shelf.Response.notFound('Manga OCR off');
      return handleMangaOcrRequest(mangaOcr, request, method, reqPath);
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
    if (reqPath == '/api/library/activity') {
      return _handleLibraryActivity(request, method);
    }
    if (reqPath == '/api/library/collections') {
      return _handleLibraryCollections(request, method, reqPath);
    }
    if (reqPath == '/api/interconnect/service-config') {
      return _handleInterconnectServiceConfig(request, method);
    }
    if (reqPath == kInterconnectProfilePath) {
      return _handleInterconnectProfile(request, method);
    }
    if (reqPath == '/api/tombstones') {
      return _handleTombstones(request, method);
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

  /// BUG-1568 测试钩子：当前驻留的视频流 token 数（验证签发侧 cap 逐出行为）。
  @visibleForTesting
  int get videoStreamTokenCount => _videoStreamTokens.length;

  /// BUG-908(a) 测试钩子：当前驻留的音频 token 数（验证 cap 逐出行为）。
  @visibleForTesting
  int get remoteAudioTokenCount => _audioTokens.count;

  /// 测试钩子：当前进行中的配对会话数（验证 prune/cap 行为）。
  @visibleForTesting
  int get pendingPairSessionCount => _pairSessions.length;

  /// TODO-961 M3 测试钩子：当前限速器跟踪的来源记录数（验证 prune 不泄漏）。
  @visibleForTesting
  int get pinRateLimitTrackedSourceCount => _pinRateLimiter.trackedSourceCount;
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
/// Content-Type 由 [_guessContentType] 按扩展名确定。
/// 响应体全程流式（`file.openRead(start, end+1)`），不把文件读入内存。
///
/// [etag] 非空时：所有响应带 `ETag` 头；且 Range 请求按 RFC 7233 §3.2 校验
/// `If-Range`——验证器不匹配（服务端字节已换代，如导出缓存过期重导出）时**忽略
/// Range 降级 200 全量**，绝不让 client 把两代字节拼成损坏文件。这是导出包
/// （epub/词典/有声书/本地音频）断点续传的正确性前提：`export*` 重打包不保证
/// 字节稳定，续传必须钉在同一份缓存文件上（见 [FushiSyncServer._exportCache]）。
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
  final String contentType = _guessContentType(file.path);
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
