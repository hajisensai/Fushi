import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:fushi_engine/dictionary/dictionary_media_types.dart';
import 'package:fushi_engine/foundation/engine_log.dart';
import 'package:fushi_engine/foundation/pref_store.dart';
import 'package:fushi_engine/media/video/bluray/bluray_remote_title.dart';
import 'package:fushi_engine/media/video/live_transcode.dart';
import 'package:fushi_engine/sync/bluray_clip_relay_pool.dart';
import 'package:fushi_engine/sync/disc_share_routes.dart';
import 'package:fushi_engine/media/video/disc/disc_share_manifest.dart'
    show buildDiscShareManifest, DiscShareManifest;
import 'package:fushi_engine/media/video/video_duration_probe.dart'
    show probeVideoDurationMs;
import 'package:fushi_engine/media/video/video_subtitle_source.dart'
    show
        EmbeddedSubtitleTrack,
        extractEmbeddedSubtitleTrackFile,
        listEmbeddedSubtitleTracks,
        subtitleExtensionForCodec,
        subtitleFormatForCodec;
import 'package:fushi_engine/sync/aggregate_snapshot.dart';
import 'package:fushi_engine/sync/collection_manifest.dart';
import 'package:fushi_engine/sync/repr_digest.dart';
import 'package:fushi_engine/sync/media_link_sync.dart';
import 'package:fushi_engine/sync/tag_sync.dart';
import 'package:fushi_engine/media/video/metadata/video_metadata_models.dart'
    show VideoMetadataWork;
import 'package:fushi_engine/media/video/metadata/video_metadata_provider.dart'
    show VideoMetadataLookup;
import 'package:fushi_engine/media/video/metadata/video_metadata_wire.dart';
import 'package:fushi_engine/sync/video_metadata_manifest.dart';
import 'package:fushi_engine/sync/fushi_library_host_service.dart';
import 'package:fushi_engine/media/video/dandanplay_file_key.dart'
    show DandanplayFileKey;
import 'package:fushi_engine/sync/graphic_subtitle_track_export.dart';
import 'package:fushi_engine/leaderboard/leaderboard_device_link.dart';
import 'package:fushi_engine/sync/interconnect_leaderboard_link.dart';
import 'package:fushi_engine/sync/interconnect_profile_transfer.dart';
import 'package:fushi_engine/sync/interconnect_service_config.dart';
import 'package:fushi_engine/sync/interconnect_transcode_prefs.dart';
import 'package:fushi_engine/sync/fushi_manga_ocr_host.dart';
import 'package:fushi_engine/sync/assistant/host_assistant.dart';
import 'package:fushi_engine/sync/assistant/host_assistant_routes.dart';
import 'package:fushi_engine/sync/downloads/host_download_host.dart';
import 'package:fushi_engine/sync/downloads/host_download_routes.dart';
import 'package:fushi_engine/sync/subscriptions/host_subscription_host.dart';
import 'package:fushi_engine/sync/subscriptions/host_subscription_routes.dart';
import 'package:fushi_engine/sync/host_jobs/host_job_manager.dart';
import 'package:fushi_engine/sync/host_jobs/host_job_routes.dart';
import 'package:fushi_engine/sync/interconnect_dav_tree_listing.dart';
import 'package:fushi_engine/sync/interconnect_device_name.dart';
import 'package:fushi_engine/sync/interconnect_host_addresses.dart';
import 'package:fushi_engine/sync/host_update/host_update_protocol.dart';
import 'package:fushi_engine/sync/fushi_remote_api_handlers.dart';
import 'package:fushi_engine/sync/pairing/fushi_pair_link.dart';
import 'package:fushi_engine/sync/pairing/fushi_pairing_protocol.dart';
import 'package:fushi_engine/sync/pairing/interconnect_device_key.dart';
import 'package:fushi_engine/sync/fushi_remote_lookup_service.dart';
import 'package:fushi_engine/sync/game_stream/game_stream_protocol.dart';
import 'package:fushi_engine/sync/game_stream/game_stream_service.dart';
import 'package:fushi_engine/sync/remote_lookup_routes.dart';
import 'package:fushi_engine/srs/srs_remote_review.dart';
import 'package:fushi_engine/srs/srs_remote_review_routes.dart';
import 'package:fushi_engine/sync/srs_change_feed.dart';
import 'package:fushi_engine/sync/video_remote_service.dart';
import 'package:fushi_core/fushi_core.dart'
    show SyncTombstoneKind, fushiDebugPrint, mimeTypeForFilePath;
import 'package:fushi_engine/sync/ttu_filename.dart' show sanitizeTtuFilename;
import 'package:meta/meta.dart';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:shelf/shelf.dart' as shelf;
import 'package:shelf/shelf_io.dart' as shelf_io;

part 'fushi_sync_server/auth.part.dart';
part 'fushi_sync_server/pairing.part.dart';
part 'fushi_sync_server/lookup.part.dart';
part 'fushi_sync_server/library.part.dart';
part 'fushi_sync_server/video.part.dart';
part 'fushi_sync_server/video_metadata.part.dart';
part 'fushi_sync_server/sync_state.part.dart';
part 'fushi_sync_server/webdav.part.dart';
part 'fushi_sync_server/game_stream.part.dart';
part 'fushi_sync_server/leaderboard_link.part.dart';
part 'fushi_sync_server/host_update.part.dart';

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

/// 请求上下文里标记信任区的键：P2P 隧道监听口进来的请求为 `'p2p'`。
const String kFushiRequestZone = 'fushi.zone';

/// P2P 隧道请求在配对审批 / 已配对设备列表里显示的来源（而不是 127.0.0.1）。
const String kFushiP2pRemoteAddress = 'P2P tunnel';

/// 请求上下文里隧道对端 NodeId 的键（只在 [kFushiRequestZone] 为 `'p2p'` 且
/// [FushiSyncServer.p2pPeerResolver] 查得到时存在）。
const String kFushiP2pPeer = 'fushi.p2p.peer';

/// A pairing attempt from a peer that POSTed /api/pair. Carries what the host
/// UI needs to identify the requester in its confirmation prompt.
class FushiPairRequest {
  const FushiPairRequest({
    required this.deviceName,
    required this.remoteAddress,
    this.pinVerified,
    this.pinRequired = false,
    this.clientDeviceId,
    this.ownerDeviceGrant,
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

  /// v2 配对里 client 上报的设备 id（= 配对成功后 [FushiPairedPeerRegistration.peerId]）。
  /// 自报值、可被冒报，**只作展示 / 诊断**：「这是我的设备」不按它记账，而是挂在
  /// [ownerDeviceGrant]（本会话）上。旧 /api/pair（v1）与没上报 id 的旧 client 为 null。
  final String? clientDeviceId;

  /// 本会话的「这是我的设备」选项。非 null = client 上报了互联设备公钥、本会话可以授予
  /// 该资格：host 审批 UI 选「允许 · 这是我的设备」时置 `granted = true`，confirm 时只有
  /// 设备钥匙验签通过才真正落成「我的设备」。null = 不提供该选项（旧 client 没有设备钥匙 /
  /// v1 配对），UI 只给普通「允许」。
  final FushiPairOwnerDeviceGrant? ownerDeviceGrant;
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
    this.ownerDevice = false,
    this.deviceKeyFingerprint,
  });

  /// 对端稳定身份（client 配对时上报的 deviceId）。表 UNIQUE 键，upsert 幂等基准。
  final String peerId;

  /// 本设备专属的长期访问凭据（confirm 派发，写库并回给该 client）。
  final String token;

  /// 对端自报展示名（可空）。
  final String? deviceName;

  /// 配对时对端来源 IP（诊断/展示，可空）。
  final String? remoteAddress;

  /// 本次配对是否授予「我的设备」资格：本会话审批选了「这是我的设备」**且** client 在
  /// confirm 里用设备私钥签过本会话、验签通过。扫码票据配对 / 旧 client 恒 false。
  final bool ownerDevice;

  /// 本次配对里验签通过的设备公钥指纹（`interconnectDeviceKeyFingerprint`）；client 没
  /// 证明设备钥匙时为 null。host 据此判断这台 peer 之后能不能被手动标成「我的设备」。
  final String? deviceKeyFingerprint;
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
  final String message = '${e.osError?.message ?? ''} ${e.message}'
      .toLowerCase();
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
  'fushiApiKey',
  'fushi_api_key',
  // 旧名保留兼容（见 fushi_api_server.dart 的 _apiKeyParameterNames）。
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
  final String id = reqPath.substring(
    prefix.length,
    reqPath.length - fullSuffix.length,
  );
  if (id.isEmpty) return null;
  // 只拒 `..`（路径穿越），允许 `/`（bookUid 形如 video/xxx）
  if (id.contains('..') || id.contains('\\')) return null;
  return id;
}

/// 从请求 header 读一个 URL-encoded 值并解码（HTTP header 只收 ASCII，非 ASCII 值
/// 由 client 端 [Uri.encodeComponent] 编码）。缺失/空返回 null；解码失败退回原文。
/// 先读新名，读不到再读改名前的旧名（[interconnectHeaderNameCandidates]）。
String? _decodeHeaderValue(shelf.Request request, String name) {
  final String? raw = _interconnectHeaderValue(request, name);
  if (raw == null) return null;
  try {
    return Uri.decodeComponent(raw);
  } catch (_) {
    return raw;
  }
}

/// 读互联自定义 header 的原文：新名优先，缺失/空时回退改名前的旧名。
String? _interconnectHeaderValue(shelf.Request request, String name) {
  for (final String candidate in interconnectHeaderNameCandidates(name)) {
    final String? raw = request.headers[candidate];
    if (raw != null && raw.isNotEmpty) return raw;
  }
  return null;
}

/// [file] 是普通文件（跟随链接）则返回其长度，否则 / stat 失败返回 null。一次 async
/// stat 同时代替 `existsSync` + `lengthSync`（BUG-3756：host 路径上不留同步 stat）。
Future<int?> _regularFileLength(File file) async {
  try {
    final FileStat stat = await file.stat();
    return stat.type == FileSystemEntityType.file ? stat.size : null;
  } on FileSystemException {
    return null;
  }
}

/// [path] 指向的封面文件存在则返回，否则 null。async：视频 / 合集封面常和视频一起
/// 落在网络盘上，host 跑在 app 主 isolate 上，同步 existsSync 冷目录时会冻结全部
/// 端点与 UI（BUG-3756）。
Future<File?> _coverFile(String? path) async {
  if (path == null || path.isEmpty) return null;
  final File file = File(path);
  try {
    return await file.exists() ? file : null;
  } on FileSystemException {
    return null;
  }
}

/// MIME 推断收敛到 fushi_core 单一映射表 [mimeTypeForFilePath]（命名统一轮 G8）。
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
    HostJobManager? hostJobs,
    HostSubscriptionHost? subscriptions,
    HostDownloadHost? downloads,
    HostAssistantProvider? assistant,
    SecurityContext? securityContext,
    String? hostFingerprint,
    String? deviceName,
    DateTime Function()? now,
    PrefStore? prefs,
    Uint8List? Function(String dictionary, String path)?
    dictionaryMediaProvider,
    Map<String, String> Function()? dictionaryStylesProvider,
    FushiRemoteGameStreamService? gameStreamService,
    VideoRemoteService? videoRemoteService,
    @visibleForTesting BlurayClipRelayPool? blurayClipRelays,
  }) : syncDataDir = p.join(syncDataDir, 'sync-data'),
       _blurayClipRelays = blurayClipRelays ?? BlurayClipRelayPool(),
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
       _hostJobs = hostJobs,
       _downloads = downloads,
       _assistant = assistant == null ? null : HostAssistantSessions(assistant),
       _subscriptions = subscriptions,
       _dictionaryMediaProvider = dictionaryMediaProvider,
       _dictionaryStylesProvider = dictionaryStylesProvider,
       _gameStreamService = gameStreamService,
       _videoRemoteService = videoRemoteService,
       _prefs = prefs,
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

  /// 通用任务（ASR 等，设计 §3.4）。null = host 不提供，`/api/jobs` 404、能力位无 `jobs`。
  final HostJobManager? _hostJobs;

  /// 代下载（设计 §3.3）。null = host 不提供，`/api/downloads` 404、能力位无 `downloads`。
  final HostDownloadHost? _downloads;

  /// AI 助手会话（手机把一句话交给电脑的 AI 去办）。null = host 不提供，
  /// `/api/assistant` 404、能力位无 `assistant`。
  final HostAssistantSessions? _assistant;

  /// 内容订阅（host 自建自跑）。null = 不提供，`/api/subscriptions` 404、能力位无 `subscriptions`。
  final HostSubscriptionHost? _subscriptions;

  /// TODO-1215: dictionary media (gaiji/accent SVG, etc.) byte provider.
  /// Injected rather than depending on the FushiDicts singleton directly, so
  /// the server has no compile-time coupling to the dictionary engine and
  /// stays unit-testable. Returns null -> the media endpoint answers 404.
  final Uint8List? Function(String dictionary, String path)?
  _dictionaryMediaProvider;

  /// 词典名 → 该词典自带的 CSS（与 app 内弹窗 `window.dictionaryStyles` 同源）。查词
  /// 结果来自本机时，对端弹窗也必须用本机的词典样式渲染——对端未必装了同名词典，
  /// 装了也可能是另一个版本。null = 端点 404（老调用方 / 单测不接线）。
  final Map<String, String> Function()? _dictionaryStylesProvider;

  /// `/api/lookup/dictionary` 的 `stylesRevision` 门控用的样式快照（BUG-3425），按
  /// [_dictionaryStylesProvider] 返回的 map **身份**复用：词典集合不变就不重算指纹。
  RemotePopupDictionaryCss? _peerPopupDictionaryCss;
  final FushiRemoteGameStreamService? _gameStreamService;
  final VideoRemoteService? _videoRemoteService;

  /// 偏好读侧（互联 host 的实时转码开关）。null = 调用方没接线（老调用方、单测），
  /// 按默认值走，行为与从前一致。
  final PrefStore? _prefs;
  final DateTime Function() _now;

  /// 单词音频 token（TTL 5 分钟 + BUG-908(a) 上限 128）与查词/制卡端点的 handler
  /// 正文都收在 [RemoteLookupRoutes]，与 FushiApiServer 共用一份。
  late final RemoteAudioTokenStore _audioTokens = RemoteAudioTokenStore(
    now: _now,
  );
  late final RemoteLookupRoutes _lookupRoutes = RemoteLookupRoutes(
    audioTokens: _audioTokens,
    lookup: _remoteLookupService,
    mining: _miningService,
  );

  final Map<String, _VideoStreamToken> _videoStreamTokens =
      <String, _VideoStreamToken>{};

  /// 远端原盘的共享会话（`disc_share_routes.dart`）：token 在路径里，按空闲续期。
  late final DiscShareTokenStore _discShares = DiscShareTokenStore(now: _now);

  /// 蓝光标题分段的解密会话（按流 token 复用，空闲回收；见 [BlurayClipRelayPool]）。
  final BlurayClipRelayPool _blurayClipRelays;

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

  /// 已鉴权的对端经 WebDAV 成功写入（PUT）或删除（DELETE）了同步目录里的一个文件后回调，
  /// 参数是相对 [syncDataDir] 的路径（`/` 分隔，如 `fushi-data/fushi-srs/<profile>/v2/devices/<id>/head-…json`）。
  /// host 自己也参与同一套资产协议时（复习同步：app 作为 host 直接读写这块目录）据此去抖触发
  /// 一轮本机同步。host 经本机文件系统写，不走这里，所以不会自己触发自己。
  void Function(String relativePath)? onClientWrite;

  /// 复习同步的「有新段」通知（`GET /api/srs/changes` 长轮询，srs_change_feed.dart）。对端写进 `fushi-srs/`
  /// 时这里自己 bump；host 自己的复习数据发布到本机目录后由 app 调 [notifySrsChanged]。
  final SrsChangeFeed srsChanges = SrsChangeFeed();

  /// host 自己的复习数据刚发布到本机同步目录（app 侧在本机目录一轮上传了段之后调）。
  void notifySrsChanged() => srsChanges.bump();

  /// TODO-961 M1b: 供给当前全部未吊销的 per-peer token（auth 校验入站请求时，除共享
  /// [_token] 外接受任一 peer token）。注入而非直连 DB。首次 auth 时惰性加载并缓存；
  /// [invalidatePeerTokenCache] 在配对/吊销后清缓存促其下次重载。null 时只认共享 token。
  Future<Set<String>> Function()? pairedPeerTokensProvider;

  /// 「跟随已配对设备自动登录 Fushi 账户」的 host 能力（app 装配，见
  /// `interconnect_leaderboard_link.dart`）。null（旧调用方 / 无头服务端 / 单测）→
  /// 端点 404、`/api/capabilities` 不声明，行为同升级前。
  InterconnectLeaderboardLinkHost? leaderboardLinkHost;

  /// 复习远程刷卡（docs/specs/2026-11-01-srs-remote-review-design.md）：每个请求现取，复习模块关着时回 null →
  /// `/api/srs/review/*` 404、`/api/capabilities` 不声明 [kSrsRemoteReviewCapability]。
  SrsRemoteReviewService? Function()? srsRemoteReviewProvider;

  /// 本 host 的稳定设备 id（与 LAN 广播 TXT `id=` 同值）。非 null 时
  /// `/api/capabilities` 公布 `hostId` + `addresses`，client 据此把同一台 host 的
  /// 多条地址归为一组、自动学习新地址（docs/specs/2026-09-28-interconnect-remote-reach.md
  /// §1）。null（老调用方 / 单测）→ 不公布，client 行为同升级前。
  String? hostId;

  /// 「立即给这个视频补字幕」（`POST /api/library/videos/<id>/subtitle/backfill`）。
  /// 补字幕服务住在 app（字幕来源 / 刮削身份 / AI 重排都在那边装配），无头服务端
  /// 不接——null 时该端点回 501，能力位 `videoSubtitleBackfill=false`。
  VideoSubtitleBackfillRunner? videoSubtitleBackfill;

  /// 图形字幕整轨回传（`GET /api/library/videos/<id>/graphicsubtitle`）用的抽取实现。
  /// 由装配方注入（app 与无头服务端都注入引擎的
  /// `InterconnectGraphicSubtitleExporter`，见 `interconnect_graphic_subtitle_export.dart`）——null 时该端点回 501，能力位 `videoGraphicSubtitleTrack=false`，client 的
  /// 图形字幕时间表退回边播边记。见 `graphic_subtitle_track_export.dart`。
  GraphicSubtitleTrackExporter? graphicSubtitleTrackExporter;

  /// 远程更新本机 app（`GET/POST /api/host/update`，反馈 Pp8XPyve0N）。实现是各平台
  /// app 的现有自更新流程；无头服务端不接——null 时端点 404、能力位 `hostUpdate=false`。
  HostSelfUpdater? hostSelfUpdater;

  /// 触发远程更新的一次性 nonce（GET 签发、POST 核销）。
  late final HostUpdateNonceStore _hostUpdateNonces = HostUpdateNonceStore(
    now: _now,
  );

  /// 用户在 host 上填的公网 / 反代 / DDNS 地址（每次 capabilities 实时读）。
  Future<List<String>> Function()? publicUrlsProvider;

  /// 网卡之外的附加地址（P2P 节点等），每次 capabilities 实时读。
  List<InterconnectHostAddress> Function()? extraAddressesProvider;

  /// 测试缝：替换网卡枚举。
  @visibleForTesting
  Future<List<NetworkInterface>> Function()? interfaceLister;

  /// 当前有效的一次性配对票据（同时只有一张：重新打开二维码即作废旧的）。
  FushiPairTicket? _pairTicket;

  /// 签发一次性配对票据（host 屏上显示二维码 / 复制链接时调用），旧票据随之作废。
  /// secret 为 24 字节随机数（192 bit），代替 PIN 进 HMAC，不可爆破。
  FushiPairTicket issuePairTicket({Duration ttl = const Duration(minutes: 5)}) {
    final FushiPairTicket ticket = FushiPairTicket(
      id: FushiPairingProtocol.generateNonce(),
      secret: FushiPairingProtocol.generateNonce(),
      expiresAt: _now().add(ttl),
    );
    _pairTicket = ticket;
    return ticket;
  }

  /// 关掉二维码时调用：票据立即作废，已凭票据开出、还没 confirm 的会话一并作废。
  void revokePairTicket() {
    _pairTicket = null;
    _pairSessions.removeWhere(
      (String _, FushiPairSession s) => s.ticketId != null,
    );
  }

  /// 组装配对链接（二维码 / 复制链接 / NFC 贴纸共用）。[ticket] 为 null 时是不带
  /// 票据的长期链接（贴纸）。没有 hostId 的 host 无从被分组，抛 [StateError]。
  Future<FushiPairLink> buildPairLink({FushiPairTicket? ticket}) async {
    final String? id = hostId;
    if (id == null) throw StateError('host id not configured');
    return FushiPairLink(
      hostId: id,
      addresses: await _hostAddresses(),
      deviceName: _deviceName,
      fingerprint: _hostFingerprint,
      ticketId: ticket?.id,
      ticketSecret: ticket?.secret,
    );
  }

  /// 本 host 当前可公布的地址集。只在 LAN 开放时有意义——仅本机监听时公布网卡
  /// 地址等于告诉 client 一堆连不上的地址。
  Future<List<InterconnectHostAddress>> _hostAddresses() async {
    if (!_allowLan || _server == null) return const <InterconnectHostAddress>[];
    return listInterconnectHostAddresses(
      port: port,
      tls: _securityContext != null,
      publicUrls:
          await (publicUrlsProvider?.call() ??
              Future<List<String>>.value(const <String>[])),
      extra:
          extraAddressesProvider?.call() ?? const <InterconnectHostAddress>[],
      interfaceLister: interfaceLister,
    );
  }

  /// [pairedPeerTokensProvider] 结果的缓存（避免每个请求打一次 DB）。null=未加载。
  /// 配对新增 / 吊销后经 [invalidatePeerTokenCache] 置 null，下次 auth 重新拉取。
  Set<String>? _cachedPeerTokens;

  bool get isRunning => _server != null;

  /// 是否以 HTTPS 对外服务（P2P 地址据此带 `?tls=1`）。
  bool get usesTls => _securityContext != null;
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
    // correctly-authenticating host is reported as "No reachable Fushi server
    // address", a chicken-and-egg deadlock that never bootstraps (BUG-035).
    // Deliberately outside the bind try/catch below: a read-only/permission
    // failure here should fail-fast and bubble to the caller's error handling
    // (sync_settings_schema._startServer catch-all) rather than masquerade as a
    // port-in-use error — and since it runs before serve(), a failure leaves no
    // half-bound socket to roll back.
    await Directory(syncDataDir).create(recursive: true);
    final shelf.Handler handler = _buildHandler();
    try {
      _server = await _bindListener(handler);
    } on SocketException catch (e) {
      if (isAddressInUseError(e)) {
        throw SyncServerPortInUseException(_requestedPort);
      }
      rethrow;
    }
  }

  shelf.Handler _buildHandler() => const shelf.Pipeline()
      .addMiddleware(_gzipTextMiddleware())
      .addMiddleware(_authMiddleware())
      .addHandler(_handleRequest);

  shelf.Handler? _inProcessHandler;

  /// 进程内调用互联 API：与网络请求同一条 pipeline（鉴权、路由、错误码一致），
  /// 以 host token 的身份通过 Basic 鉴权。
  ///
  /// 只给**已鉴权的可信进程内调用方**用——无头服务端的 admin API 先验过
  /// admin_token，再经它让管理员用到「只对已配对 peer 开放」的库 / 刮削 / 进度
  /// 等接口，不必另写一套同功能路由。配对路由依赖对端地址，不走这里：调用方
  /// 负责挡掉（见 fushi_server 的 `/api/admin/host/*`）。
  Future<shelf.Response> handleInProcess(shelf.Request request) async {
    final shelf.Handler handler = _inProcessHandler ??= _buildHandler();
    final String basic = base64Encode(utf8.encode('admin:$_token'));
    return handler(
      request.change(
        headers: <String, String>{'authorization': 'Basic $basic'},
      ),
    );
  }

  /// P2P 隧道的信任区监听口（docs/specs/2026-09-28-interconnect-remote-reach.md §5）。
  HttpServer? _p2pServer;

  /// 为 P2P 隧道单独开一个 loopback 监听口，与主监听口同一个 handler，但请求带
  /// `fushi.zone = p2p` 标记。隧道流量在 host 看来来自 127.0.0.1——不单独标出来，
  /// 配对判据会把它当「本机 / 局域网」免 PIN，任何拿到 NodeId 的人都能配上。
  /// 返回监听端口（重复调用返回同一个）。同样起 TLS：隧道里仍是端到端钉扎的
  /// 自签证书，与直连同一套信任。
  Future<int> startP2pListener() {
    final HttpServer? existing = _p2pServer;
    if (existing != null) return Future<int>.value(existing.port);
    return _p2pStarting ??= _bindP2pListener().whenComplete(
      () => _p2pStarting = null,
    );
  }

  Future<int>? _p2pStarting;

  /// 隧道监听口上一条连接的对端端口 → 隧道对端 NodeId。原生隧道把每条流转发成
  /// 一条到本监听口的 TCP 连接并登记其源端口（`fp2p_host_peer`）；装配方（app 的
  /// controller / 无头 host）起 P2P 时接上，停时置 null。
  String? Function(int remotePort)? p2pPeerResolver;

  /// 本请求的隧道对端 NodeId（查不到 → null）。
  String? _resolveTunnelPeer(shelf.Request request) {
    final String? Function(int remotePort)? resolve = p2pPeerResolver;
    final Object? info = request.context['shelf.io.connection_info'];
    if (resolve == null || info is! HttpConnectionInfo) return null;
    return resolve(info.remotePort);
  }

  /// 主机已停就拒绝；bind 期间主机被停（[stop] 在 await 之间落地）就把刚绑上的
  /// 口立刻关掉——否则留下一个挂着完整 handler 的孤儿监听口，iroh 继续把公网流量
  /// 转进来，「主机已关闭」之后对端仍能访问库（审查问题 5）。
  Future<int> _bindP2pListener() async {
    if (_server == null) throw StateError('sync server is not running');
    final shelf.Handler inner = _buildHandler();
    final HttpServer server = await shelf_io.serve(
      (shelf.Request request) {
        final String? peer = _resolveTunnelPeer(request);
        return inner(
          request.change(
            context: <String, Object>{
              kFushiRequestZone: 'p2p',
              if (peer != null) kFushiP2pPeer: peer,
            },
          ),
        );
      },
      InternetAddress.loopbackIPv4,
      0,
      securityContext: _securityContext,
    );
    if (_server == null) {
      await server.close(force: true);
      throw StateError('sync server stopped while binding the P2P listener');
    }
    _p2pServer = server;
    return server.port;
  }

  Future<void> stopP2pListener() async {
    final Future<int>? starting = _p2pStarting;
    if (starting != null) {
      // 在飞的 bind 落地后再关，免得它在我们关完之后才把口挂上。
      await starting.then<void>((_) {}, onError: (Object _) {});
    }
    final HttpServer? server = _p2pServer;
    _p2pServer = null;
    await server?.close(force: true);
  }

  /// 仅本机 → loopback v4。允许 LAN → IPv6 双栈（`::`、`v6Only:false`，同一个端口
  /// 同时收 v4 与 v6）：国内家宽普遍没有公网 v4 却有公网 v6，只监听 v4 等于把这
  /// 条最便宜的直连路堵死。v4 对端在双栈 socket 上报成 `::ffff:a.b.c.d`，由
  /// [FushiPairingProtocol.unmapIPv4MappedAddress] 还原。
  ///
  /// 系统禁用了 IPv6（内核关掉 / 容器无 v6 栈）时 `::` 根本绑不上，这是平台能力
  /// 边界，回落只监听 v4——行为与升级前一致。端口被占不在此回落：它在 v4 上同样会
  /// 撞，交给调用方报 [SyncServerPortInUseException]。
  Future<HttpServer> _bindListener(shelf.Handler handler) async {
    if (!_allowLan) {
      return shelf_io.serve(
        handler,
        InternetAddress.loopbackIPv4,
        _requestedPort,
        securityContext: _securityContext,
      );
    }
    // 明文 host 维持升级前的只监听 v4（在 NAT 之后）：双栈会让它在全局 IPv6 上
    // 直接对公网可达，token 与数据明文跑在公网上，用户却没有任何开关。开了 TLS
    // 才双栈——此时公网上的对端也只能经指纹钉扎的 TLS 进来。
    if (_securityContext == null) {
      return shelf_io.serve(handler, InternetAddress.anyIPv4, _requestedPort);
    }
    try {
      return await shelf_io.serve(
        handler,
        InternetAddress.anyIPv6,
        _requestedPort,
        securityContext: _securityContext,
      );
    } on SocketException catch (e) {
      if (isAddressInUseError(e)) rethrow;
      engineLog.logDiagnostic(
        'FushiSyncServer.bind',
        'IPv6 dual-stack bind failed, IPv4 only: $e',
      );
      return shelf_io.serve(
        handler,
        InternetAddress.anyIPv4,
        _requestedPort,
        securityContext: _securityContext,
      );
    }
  }

  /// 导出包缓存（epub/词典/有声书/本地音频 GET 的 Range 续传字节稳定性基础）。
  final ExportPackageCache _exportCache = ExportPackageCache();

  Future<void> stop() async {
    final HttpServer? main = _server;
    // 先摘主句柄：在飞的隧道口 bind 落地时据此发现主机已停并自行关掉。
    _server = null;
    await stopP2pListener();
    await main?.close(force: true);
    await _blurayClipRelays.closeAll();
    _discShares.clear();
    _exportCache.dispose();
    // 漫画 P3：host 停机时中止在跑的 OCR 任务（页边界停，断点缓存保留）。
    await _mangaOcrJobs?.disposeAll();
    await _hostJobs?.disposeAll();
    await _assistant?.dispose();
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
        final String accept = (request.headers['accept-encoding'] ?? '')
            .toLowerCase();
        if (!accept.contains('gzip')) return response;
        final String type = (response.headers['content-type'] ?? '')
            .toLowerCase();
        final bool compressible =
            type.contains('application/json') || type.contains('xml');
        if (!compressible) return response;
        if (response.headers['content-encoding'] != null) return response;
        // 按块攒进 BytesBuilder：展开成 List<int> 会把每字节装箱成 8 字节槽，几百 KB
        // 的清单要多拷一份、多占 8 倍内存（同 game_stream.part.dart 的上传体）。
        final BytesBuilder body = BytesBuilder(copy: false);
        await response.read().forEach(body.add);
        final List<int> gzipped = gzip.encode(body.takeBytes());
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
    if (reqPath == '/api/game-stream/sessions' ||
        reqPath.startsWith('/api/game-stream/sessions/') ||
        reqPath == '/api/game-stream/join' ||
        reqPath == '/api/game-stream/signal' ||
        reqPath == '/api/game-stream/stop' ||
        reqPath == '/api/game-stream/mine' ||
        reqPath == '/api/game-stream/library' ||
        reqPath == '/api/game-stream/library/cover' ||
        reqPath == '/api/game-stream/launch' ||
        reqPath == '/api/game-stream/launch/status') {
      return _handleGameStream(request, method, reqPath);
    }
    if (reqPath.startsWith('/api/video-remote/')) {
      return _handleVideoRemote(request, method, reqPath);
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
    if (reqPath.startsWith('/api/anki/source/')) {
      if (method != 'POST') return shelf.Response(405);
      return _lookupRoutes.handleSourceNote(request, reqPath);
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
    // 复习同步快速通道（设计 §6.3）：令牌变了立刻回，没变挂到下一次写入或超时。鉴权走上方 middleware。
    if (reqPath == '/api/srs/changes') {
      if (method != 'GET') return shelf.Response(405);
      final int token = await srsChanges.waitAfter(
        int.tryParse(request.url.queryParameters['after'] ?? ''),
      );
      return jsonResponse(<String, dynamic>{'token': token});
    }
    // 复习远程刷卡：客户端不下载卡组，在本机复习上出卡 / 作答。鉴权走上方 middleware。
    if (reqPath.startsWith(kSrsRemoteReviewPathPrefix)) {
      final SrsRemoteReviewService? review = srsRemoteReviewProvider?.call();
      if (review == null) return shelf.Response.notFound('SRS review off');
      return handleSrsRemoteReviewRequest(review, request, method, reqPath);
    }
    if (reqPath == '/api/capabilities') {
      if (method != 'GET') return shelf.Response(405);
      final shelf.Response response = await _handleCapabilities();
      final bool srsRemoteReview = srsRemoteReviewProvider?.call() != null;
      if (_videoRemoteService == null &&
          !_leaderboardLinkAvailable &&
          !srsRemoteReview) {
        return response;
      }
      final Map<String, dynamic> capabilities =
          jsonDecode(await response.readAsString()) as Map<String, dynamic>;
      if (_videoRemoteService != null) {
        capabilities['videoRemoteControlV1'] = true;
      }
      if (_leaderboardLinkAvailable) {
        capabilities[kInterconnectLeaderboardLinkCapability] = true;
      }
      if (srsRemoteReview) capabilities[kSrsRemoteReviewCapability] = true;
      return jsonResponse(capabilities);
    }
    if (reqPath == '/api/host/addresses') {
      if (method != 'GET') return shelf.Response(405);
      return _handleHostAddresses();
    }
    if (reqPath == kHostUpdatePath) {
      return _handleHostUpdate(request, method);
    }
    // 漫画 P3：互联 host 代跑 OCR。鉴权走上方 middleware（无豁免），处理逻辑在
    // fushi_manga_ocr_host.dart（本文件是共享热点，只留最小分发）。
    if (reqPath == '/api/ocr/job' || reqPath.startsWith('/api/ocr/job/')) {
      final MangaOcrHostJobManager? mangaOcr = _mangaOcrJobs;
      if (mangaOcr == null) return shelf.Response.notFound('Manga OCR off');
      return handleMangaOcrRequest(mangaOcr, request, method, reqPath);
    }
    // 通用任务协议（设计 §3.4）：/api/ocr/job 原样冻结，新任务类型一律走这里。
    if (reqPath == '/api/jobs' || reqPath.startsWith('/api/jobs/')) {
      final HostJobManager? jobs = _hostJobs;
      if (jobs == null) return shelf.Response.notFound('Host jobs off');
      return handleHostJobRequest(jobs, request, method, reqPath);
    }
    if (reqPath == '/api/downloads' || reqPath.startsWith('/api/downloads/')) {
      final HostDownloadHost? downloads = _downloads;
      if (downloads == null) {
        return shelf.Response.notFound('Host downloads off');
      }
      return handleHostDownloadRequest(downloads, request, method, reqPath);
    }
    if (reqPath == '/api/assistant' || reqPath.startsWith('/api/assistant/')) {
      final HostAssistantSessions? assistant = _assistant;
      if (assistant == null) {
        return shelf.Response.notFound('Host assistant off');
      }
      return handleHostAssistantRequest(assistant, request, method, reqPath);
    }
    if (reqPath == '/api/subscriptions' ||
        reqPath.startsWith('/api/subscriptions/')) {
      final HostSubscriptionHost? subscriptions = _subscriptions;
      if (subscriptions == null) {
        return shelf.Response.notFound('Host subscriptions off');
      }
      return handleHostSubscriptionRequest(
        subscriptions,
        request,
        method,
        reqPath,
      );
    }
    if (reqPath == '/api/library/dictionaries' ||
        reqPath.startsWith('/api/library/dictionaries/')) {
      return _handleLibraryDictionaries(request, method, reqPath);
    }
    if (reqPath == '/api/library/books' ||
        reqPath.startsWith('/api/library/books/')) {
      return _handleLibraryBooks(request, method, reqPath);
    }
    if (reqPath.startsWith('/api/library/manga/')) {
      return _handleLibraryManga(request, method, reqPath);
    }
    if (reqPath == '/api/library/localaudio' ||
        reqPath.startsWith('/api/library/localaudio/')) {
      return _handleLibraryLocalAudio(request, method, reqPath);
    }
    if (reqPath == '/api/library/audiobooks' ||
        reqPath.startsWith('/api/library/audiobooks/')) {
      return _handleLibraryAudiobooks(request, method, reqPath);
    }
    // 视频刮削元数据（7c/7a/7b），必须排在 videos 前缀判定之前（互不为前缀，但
    // 放一起读）；host 不实现 VideoMetadataHost → 404。
    if (reqPath == '/api/library/metadata' ||
        reqPath.startsWith('/api/library/metadata/')) {
      return _handleLibraryVideoMetadata(request, method, reqPath);
    }
    if (reqPath == '/api/library/videos' ||
        reqPath.startsWith('/api/library/videos/')) {
      return _handleLibraryVideos(request, method, reqPath);
    }
    // 远端原盘的只读盘目录（会话 token 鉴权，豁免 Basic 见 auth 中间件）。
    if (reqPath.startsWith(kDiscShareRoutePrefix)) {
      if (_libraryService is! VideoDiscShareHost) {
        return shelf.Response.notFound('Disc share off');
      }
      return handleDiscShareRequest(_discShares, request, method, reqPath);
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
    if (reqPath == '/api/library/tags') {
      return _handleLibraryTags(request, method);
    }
    if (reqPath == '/api/library/media-links') {
      return _handleLibraryMediaLinks(request, method);
    }
    if (reqPath == '/api/interconnect/service-config') {
      return _handleInterconnectServiceConfig(request, method);
    }
    if (reqPath == kInterconnectProfilePath) {
      return _handleInterconnectProfile(request, method);
    }
    if (reqPath == kInterconnectLeaderboardLinkPath) {
      return _handleInterconnectLeaderboardLink(request, method);
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
        return _reportClientWrite(
          reqPath,
          await _serializeDavWrite(fsPath, () => _handlePut(request, fsPath)),
          published: true,
        );
      case 'MKCOL':
        return _serializeDavWrite(fsPath, () => _handleMkcol(fsPath));
      case 'DELETE':
        return _reportClientWrite(
          reqPath,
          await _serializeDavWrite(fsPath, () => _handleDelete(fsPath)),
        );
      case 'HEAD':
        return _handleHead(fsPath);
      case 'OPTIONS':
        return shelf.Response.ok(
          '',
          headers: {
            'Allow': 'OPTIONS, GET, POST, PUT, DELETE, MKCOL, PROPFIND, HEAD',
            'DAV': '1',
          },
        );
      default:
        return shelf.Response(405);
    }
  }

  /// 写成功（2xx）才回调 [onClientWrite]；回调异常不影响响应。[published] = 这次写带来了新内容（PUT）：
  /// 只有它推进复习同步的长轮询令牌。删旧 head（客户端每发一个新 head 就清两代前的）没有任何新数据，
  /// 以前也推进令牌，等于每轮多唤醒一次全部设备。
  shelf.Response _reportClientWrite(
    String reqPath,
    shelf.Response response, {
    bool published = false,
  }) {
    if (published &&
        response.statusCode >= 200 &&
        response.statusCode < 300 &&
        // 复习同步的命名空间（srs/sync2/srs_location_store.dart kSrsSync2Namespace）下的 head：段先于 head
        // 写，head 落地才说明这一轮的段齐了，只在这时唤醒长轮询。
        reqPath.contains('/fushi-srs/') &&
        p.posix.basename(reqPath).startsWith('head-')) {
      srsChanges.bump();
    }
    final void Function(String relativePath)? cb = onClientWrite;
    if (cb != null && response.statusCode >= 200 && response.statusCode < 300) {
      try {
        cb(reqPath.startsWith('/') ? reqPath.substring(1) : reqPath);
      } catch (e, stack) {
        engineLog.log('FushiSyncServer.onClientWrite', e, stack);
      }
    }
    return response;
  }

  Future<shelf.Response> _handleVideoRemote(
    shelf.Request request,
    String method,
    String path,
  ) async {
    if (method != 'POST') return shelf.Response(405);
    final VideoRemoteService? service = _videoRemoteService;
    if (service == null) return shelf.Response.notFound('Video remote off');
    final String operation = path.substring('/api/video-remote/'.length);
    if (!videoRemoteOperations.contains(operation)) {
      return shelf.Response.notFound('Unknown video remote operation');
    }
    // The middleware accepts legacy shared credentials for old library clients.
    // Exclusive remote ownership must instead be tied to a paired credential;
    // neither a body peerId nor the Basic username is an authenticated identity.
    final String? authorization = request.headers['authorization'];
    if (!await _validatePeerAuth(authorization)) {
      return shelf.Response(
        403,
        body: '{"error":"paired_peer_required"}',
        headers: <String, String>{'content-type': 'application/json'},
      );
    }
    final String peerId = sha256
        .convert(utf8.encode(_basicPassword(authorization!)!))
        .toString();
    final BytesBuilder bytes = BytesBuilder(copy: false);
    await for (final List<int> chunk in request.read()) {
      bytes.add(chunk);
      if (bytes.length > 2 * 1024 * 1024) {
        return shelf.Response(413);
      }
    }
    final Map<String, dynamic> body;
    try {
      final Object? decoded = jsonDecode(utf8.decode(bytes.takeBytes()));
      if (decoded is! Map<String, dynamic>) throw const FormatException();
      body = decoded;
    } on FormatException {
      return shelf.Response(
        400,
        body: '{"error":"invalid_json"}',
        headers: <String, String>{'content-type': 'application/json'},
      );
    }
    try {
      return jsonResponse(await service.handle(operation, body, peerId));
    } on VideoRemoteException catch (error) {
      return shelf.Response(
        error.status,
        body: jsonEncode(<String, String>{'error': error.code}),
        headers: <String, String>{'content-type': 'application/json'},
      );
    } catch (error, stack) {
      // 适配层把可预期失败都翻成 [VideoRemoteException]；走到这里的是真缺陷。
      // 记日志并回稳定机器码，手机按码本地化，不把内部异常文本发给对端。
      engineLog.log('FushiSyncServer.videoRemote.$operation', error, stack);
      return shelf.Response(
        500,
        body: jsonEncode(<String, String>{'error': videoRemoteInternalError}),
        headers: <String, String>{'content-type': 'application/json'},
      );
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
/// [ifRangeRequired]（默认 true，上面的导出包语义）：带 Range 却**缺** `If-Range`
/// 时同样降级 200。源文件原地的视频流传 false——播放器（mpv）的 seek Range 不带
/// `If-Range`，必须照常 206；而带了 `If-Range` 的下载续传仍按验证器精确匹配，
/// 不匹配（host 上文件已被替换）照样 200 全量（RFC 7233 §3.2 的原本语义）。
///
/// [reprDigest]：整份表示（不是本次 Range 片段）的 RFC 9530 `Repr-Digest` 头值
/// （`sha-256=:<base64>:`）。200 / 206 都带：续传的 client 把各段拼完后据它做整体
/// 校验，判定「拼出来的就是 host 那份字节」（Sn4fYseBt4）。
///
/// 函数名无下划线前缀（公开），便于测试文件直接导入使用。
Future<shelf.Response> serveFileWithRange(
  File file,
  shelf.Request request, {
  String? etag,
  bool ifRangeRequired = true,
  String? reprDigest,
}) async {
  // 一次 async stat 同时拿存在性与长度：视频流 / 漫画页 / 导出包都经这里，源文件
  // 可能在网络盘上，同步 existsSync + lengthSync 会冻结 host 所在 isolate（BUG-3756）。
  final FileStat stat;
  try {
    stat = await file.stat();
  } on FileSystemException {
    return shelf.Response.notFound('File not found');
  }
  if (stat.type != FileSystemEntityType.file) {
    return shelf.Response.notFound('File not found');
  }

  final int fileLength = stat.size;
  final String contentType = _guessContentType(file.path);
  String? rangeHeader = request.headers['range'];
  if (etag != null && rangeHeader != null) {
    final String? ifRange = request.headers['if-range'];
    if (ifRange == null ? ifRangeRequired : ifRange != etag) {
      // 验证器不匹配或缺失：client 手里的 .part 可能属于上一代字节（导出缓存
      // 过期重打包），忽略 Range 整包 200 重发（client 侧 ResumableDownloader
      // 收到 200 会丢弃旧 part 从 0 重写）。带 etag 的调用方声明「字节可能
      // 换代」，故续传**必须**验证器精确匹配——缺 If-Range 的盲 Range 也拒绝，
      // 正确性优先于续传收益（[ifRangeRequired] 为 false 的视频流对盲 Range
      // 照常 206，见函数文档）。
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
        if (reprDigest != null) kReprDigestHeader: reprDigest,
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
      if (reprDigest != null) kReprDigestHeader: reprDigest,
    },
  );
}

/// 视频源文件的强验证器（`"vid-<size>-<mtimeMs>"`），给 `/stream` 的 ETag /
/// `If-Range` 用：host 上同一路径的文件被替换（换版本、重新压制）时 size 或 mtime
/// 必变，client 手里的 `.part` 续传因验证器不匹配降级 200 全量，不会把两份文件
/// 拼成坏片。与导出包的 `pkg-` 验证器（[ExportPackageCache.etagFor]）刻意分开：
/// 那边钉的是进程内缓存的代数，这里钉的是用户库里的原文件。纯 ASCII。
///
/// async（一次 stat 取 size + mtime）：源文件常在网络盘上（BUG-3756）。文件不存在 /
/// stat 失败抛 [FileSystemException]，与旧 `lengthSync` 同一契约。
Future<String> videoFileEtag(File file) async {
  final FileStat stat = await file.stat();
  if (stat.type == FileSystemEntityType.notFound) {
    throw FileSystemException('Cannot stat video file', file.path);
  }
  return '"vid-${stat.size}-${stat.modified.millisecondsSinceEpoch}"';
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
///
/// **TTL 从最后一次使用起算**（Sn4fYseBt4）：旧实现按缓存文件 mtime（= 导出时刻）
/// 判过期，一个大包（如几 GB 的本地音频库）传了 15 分钟以上再断，续传请求必然
/// 撞上重导出 → ETag 换代 → 200 从 0 重下，断点续传对恰恰最需要它的大文件失效。
/// 现在每次 [obtain] 命中、以及正在流式发送这份字节（[markUsed]）都把它续期，
/// 只有「闲置满 [ttl]」才换代。
///
/// 每份导出同时算一次整包 SHA-256（[reprDigestFor]，后台 isolate 跑，不占 host
/// 所在 isolate），随响应发 `Repr-Digest`，供 client 续传拼完后做整体校验。
class ExportPackageCache {
  ExportPackageCache({this.ttl = const Duration(minutes: 15)});

  final Duration ttl;
  Directory? _root;
  final Map<String, File> _latest = <String, File>{};
  final Map<String, Future<File>> _inFlight = <String, Future<File>>{};

  /// key → 最后一次使用（命中 / 生产 / 流式发送）时刻；滑动 TTL 的依据。
  final Map<String, DateTime> _lastUsed = <String, DateTime>{};

  /// 缓存文件路径 → `Repr-Digest` 头值（`sha-256=:<base64>:`）。
  final Map<String, String> _reprDigests = <String, String>{};
  int _seq = 0;

  /// 把 (kind,id) 的当前缓存标记为「刚被用过」，滑动 TTL 续期。流式发送这份字节的
  /// 响应体每出一块就调一次（O(1) 的 map 写），长传输期间缓存不会被判闲置换代。
  void markUsed(String kind, String id) {
    final String key = '$kind|$id';
    if (_latest.containsKey(key)) _lastUsed[key] = DateTime.now();
  }

  /// [file]（必须是本缓存 [obtain] 交出的文件）的 `Repr-Digest` 头值；没算出来
  /// （哈希失败）时 null，响应就不带该头，client 退回只做长度校验。
  String? reprDigestFor(File file) => _reprDigests[file.path];

  Directory get _dir =>
      _root ??= Directory.systemTemp.createTempSync('fushi_export_cache');

  /// 取 (kind,id) 的缓存导出文件；TTL 内直接命中，否则经 [export] 重新打包。
  /// [export] 返回的临时文件（连同其父临时目录）所有权移交本缓存。
  ///
  /// 命中判据走 async stat（包下载端点在 host 所在 isolate 上跑，同步 stat 会和别的
  /// 请求抢 isolate，BUG-3756）。await 之后再读 [_inFlight] / [_latest]：两段之间别的
  /// 请求可能已换代，命中判据只认 await 后仍是「当前代」的那份。
  Future<File> obtain(
    String kind,
    String id,
    Future<File> Function() export,
  ) async {
    final String key = '$kind|$id';
    final File? hit = _latest[key];
    if (hit != null) {
      try {
        final FileStat stat = await hit.stat();
        final DateTime? lastUsed = _lastUsed[key];
        if (identical(_latest[key], hit) &&
            stat.type == FileSystemEntityType.file &&
            lastUsed != null &&
            DateTime.now().difference(lastUsed) < ttl) {
          _lastUsed[key] = DateTime.now();
          return hit;
        }
      } on FileSystemException {
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

  /// 让 (kind,id) 的缓存导出作废，下一次 [obtain] 必定重新打包。旧文件 best-effort
  /// 删除（Windows 上被正在流式的请求占用则删不掉，留给 [dispose]）。
  Future<void> invalidate(String kind, String id) async {
    _lastUsed.remove('$kind|$id');
    final File? old = _latest.remove('$kind|$id');
    if (old == null) return;
    _reprDigests.remove(old.path);
    try {
      await old.delete();
    } catch (_) {
      // 占用中：留给 dispose 整目录清理。
    }
  }

  /// 缓存文件的强验证器（`"pkg-<代数>-<size>-<mtimeMs>"`）：字节换代 ⇒ 值必变。
  /// 代数取自缓存文件名前缀 `e<seq>_`（进程内单调，快速换代时 size+mtime 粒度
  /// 不够也不撞车）；mtime 兜底跨进程重启的唯一性。纯 ASCII（CJK 词典名不进
  /// ETag——header 值必须 ASCII 安全）。
  ///
  /// async（一次 stat 取 size + mtime），理由同 [videoFileEtag]。
  static Future<String> etagFor(File file) async {
    final String base = p.basename(file.path);
    final int us = base.indexOf('_');
    final String seq = (base.startsWith('e') && us > 1)
        ? base.substring(1, us)
        : '0';
    final FileStat stat = await file.stat();
    if (stat.type == FileSystemEntityType.notFound) {
      throw FileSystemException('Cannot stat export package', file.path);
    }
    return '"pkg-$seq-${stat.size}-${stat.modified.millisecondsSinceEpoch}"';
  }

  Future<File> _produce(String key, Future<File> Function() export) async {
    final File exported = await export();
    // 保留原始文件名（扩展名决定 Content-Type，如 .epub → application/epub+zip），
    // 前缀序号防同名不同 key 撞车。
    final File target = File(
      p.join(_dir.path, 'e${_seq++}_${p.basename(exported.path)}'),
    );
    try {
      await exported.rename(target.path);
    } on FileSystemException {
      // 跨盘 rename 失败：复制兜底。
      await exported.copy(target.path);
    }
    try {
      await exported.parent.delete(recursive: true);
    } catch (_) {
      // best-effort：导出方的临时父目录
    }
    // 整包摘要只算这一次（同一份字节在 TTL 内被反复续传），放后台 isolate：
    // 几 GB 的包同步哈希会冻住 host 所在 isolate（BUG-3756 同理）。
    try {
      _reprDigests[target.path] = await computeReprDigestSha256(target);
    } catch (e, stack) {
      // 只损失整体校验（client 退回长度校验），不影响下载本身。
      engineLog.log('ExportPackageCache.reprDigest', e, stack);
    }
    final File? old = _latest[key];
    _latest[key] = target;
    _lastUsed[key] = DateTime.now();
    if (old != null) {
      _reprDigests.remove(old.path);
      try {
        await old.delete();
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
    _lastUsed.clear();
    _reprDigests.clear();
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
    this.modified,
  });

  final String href;
  final bool isCollection;
  final String displayName;
  final int contentLength;

  /// 文件在 host 上的修改时间（host 的时钟 = 互联的服务器时间）；目录不填。
  final DateTime? modified;
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
    this.transcodeProfile,
    this.transcodeAudioStreamIndex,
    this.transcodeDurationMs,
  });

  /// 绑定的视频 id（即 VideoBooks.bookUid，可含 `/`）。
  final String videoId;
  final DateTime createdAt;

  /// 远端播放列表集下标（TODO-885）；单视频 / 当前集恒 0。
  final int episodeIndex;

  /// 非 null 时 `/stream` 走实时转码（弱网降码率），null 是原文件 Range 直传。
  ///
  /// 档位**绑定在 token 上**而不是由 `/stream` 的 query 决定：`/stream` 是唯一豁免
  /// Basic 鉴权的视频路径（auth.part.dart），谁拿到 URL 谁就能取流，让它自带 query
  /// 就等于把「在 host 上起一个任意参数的 ffmpeg」敞开给 URL 持有者。签发侧
  /// （`/streamurl`，要 Basic）定档，取流侧只认 token 里的那一份。
  final VideoTranscodeProfile? transcodeProfile;

  /// 转码流选哪条音轨（多音轨番剧的日配/中配）。null = 源的第一条音轨。转码后的流
  /// 只能带一条音轨，播放器侧的音轨切换在这条流上是空的——所以选哪条必须在签发时定。
  final int? transcodeAudioStreamIndex;

  /// 转码流的源时长（毫秒），签发时 ffprobe 一次。
  ///
  /// HLS playlist 要按它切段，每个分段请求也要按它算自己的时间范围。存在 token 上
  /// 而不是每次请求重探：一次播放会打几十上百个分段请求，每个都 ffprobe 一遍纯属
  /// 白烧 CPU，而同一个 token 指向的文件在其生命周期内不会变。
  final int? transcodeDurationMs;
}
