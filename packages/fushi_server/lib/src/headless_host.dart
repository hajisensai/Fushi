/// 无头 host：把引擎里的互联服务器、本地库服务、远程 OCR 任务管理器、TLS 身份、
/// 配对回调和 mDNS 广播组装成一个可 start/stop 的进程级对象。
///
/// 与 app 的 `FushiSyncServerController._startOrchestration` 一一对应：
/// 同一份 `FushiSyncServer`、同一份 `LocalLibraryHostService`、同一份
/// `MangaOcrHostJobManager`，区别只在回调的实现（没有 UI：PIN 打到日志与 WebUI、
/// 审批以 PIN 为准）。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:fushi_core/fushi_core.dart';
import 'package:drift/drift.dart' show Value;
import 'package:fushi_engine/asr/asr_host_job_runner.dart';
import 'package:fushi_engine/epub/epub_importer.dart';
import 'package:fushi_engine/foundation/engine_log.dart';
import 'package:fushi_engine/sync/interconnect_host_addresses.dart';
import 'package:fushi_engine/sync/interconnect_p2p.dart';
import 'package:fushi_engine/media/video/video_book_repository.dart';
import 'package:fushi_engine/media/video/video_cover_extractor.dart';
import 'package:fushi_engine/ocr/manga_ocr_local_model.dart';
import 'package:fushi_engine/ocr/manga_ocr_service_impl.dart';
import 'package:fushi_engine/sync/fushi_manga_ocr_host.dart';
import 'package:fushi_engine/sync/fushi_sync_server.dart';
import 'package:fushi_engine/sync/host_jobs/host_job_manager.dart';
import 'package:fushi_engine/sync/host_jobs/host_job_runner.dart';
import 'package:fushi_engine/sync/local_audio_library_store.dart';
import 'package:fushi_engine/sync/local_library_host_service.dart';
import 'package:fushi_engine/sync/manga_sync_package.dart';
import 'package:fushi_engine/sync/override_title_db.dart';
import 'package:fushi_engine/sync/pairing/fushi_pairing_protocol.dart';
import 'package:fushi_engine/sync/subscriptions/host_subscription_host.dart';
import 'package:fushi_engine/sync/sync_asset_package_service.dart';
import 'package:fushi_engine/sync/tls/fushi_tls_identity.dart';
import 'package:fushi_server/src/anki_landing.dart';
import 'package:fushi_server/src/config/server_config.dart';
import 'package:fushi_server/src/assistant_host.dart';
import 'package:fushi_server/src/download_host.dart';
import 'package:fushi_server/src/host_bindings.dart';
import 'package:fushi_server/src/lan_advertiser.dart';
import 'package:fushi_server/src/profile_hub.dart';
import 'package:fushi_server/src/server_identity.dart';
import 'package:fushi_server/src/server_paths.dart';
import 'package:fushi_server/src/server_prefs.dart';
import 'package:fushi_server/src/video_scrape_host.dart';
import 'package:path/path.dart' as p;

/// 当前待输入的配对 PIN（无头进程的「审批弹窗」：CLI 日志 + WebUI 状态）。
class PendingPairing {
  const PendingPairing({
    required this.pin,
    required this.deviceName,
    required this.remoteAddress,
    required this.createdAt,
  });

  final String pin;
  final String? deviceName;
  final String? remoteAddress;
  final DateTime createdAt;
}

/// 串行化库变动（对应 app 的 `runExclusiveWithSync`）。
class _AsyncMutex {
  Future<void> _tail = Future<void>.value();

  Future<void> run(Future<void> Function() body) {
    final Completer<void> done = Completer<void>();
    final Future<void> prev = _tail;
    _tail = done.future;
    return prev.then((_) => body()).whenComplete(done.complete);
  }
}

class HeadlessHost {
  HeadlessHost({
    required ServerConfig config,
    required this.paths,
    required this.db,
    required this.prefs,
    required this.identity,
    bool Function()? p2pAvailable,
  })  : _config = config,
        _p2pAvailable =
            p2pAvailable ?? (() => InterconnectP2pRuntime.isAvailable);

  ServerConfig _config;

  /// 当前配置（WebUI 改完经 [applyConfig] 推进来）。只有运行期可变的项从这里
  /// 实时读（公网地址 / 局域网 PIN / P2P）；端口、绑定、TLS 这类要重启的，在
  /// [start] 时取快照（见 [_loopbackOnly]），不跟着新配置漂。
  ServerConfig get config => _config;

  /// 原生 libfushi_p2p 是否可用（测试可注入）。
  final bool Function() _p2pAvailable;
  final ServerPaths paths;
  final FushiDatabase db;
  final ServerPrefs prefs;
  final ServerIdentity identity;

  FushiSyncServer? _server;
  LanAdvertiser? _advertiser;
  InterconnectP2pRuntime? _p2p;
  MangaOcrServiceImpl? _ocrService;
  Map<String, MangaOcrServiceImpl> _ocrModelServices = const <String, MangaOcrServiceImpl>{};
  HostJobManager? _jobs;
  ServerDownloadHost? _downloads;
  ServerAnkiLanding? _anki;
  ServerVideoScrape? _videoScrape;
  final _AsyncMutex _mutex = _AsyncMutex();

  /// 互联「配置文件」寄存处（对端推来 / 拉走的配置方案；WebUI 列表与指定也走它）。
  late final ServerProfileHub profiles = ServerProfileHub(
    directory: paths.interconnectProfiles,
    readPinnedId: () => prefs.getRaw(ServerProfileHub.pinnedPrefKey),
    writePinnedId: (String? id) =>
        prefs.setRaw(ServerProfileHub.pinnedPrefKey, id ?? ''),
  );

  /// [start] 时的绑定地址是否只监听本机（重启前改了 `bind` 也按实际监听判）。
  bool _loopbackOnly = false;

  /// P2P 挂载 / 卸载一律串行（见 [_serializeP2p]）。
  Future<void> _p2pOps = Future<void>.value();
  bool _p2pListening = false;
  String? _p2pLastError;
  PendingPairing? _pendingPairing;
  String? _hostFingerprint;
  SecurityContext? _securityContext;

  /// 给 CLI / WebUI 看的状态。
  PendingPairing? get pendingPairing => _pendingPairing;
  String? get hostFingerprint => _hostFingerprint;

  /// 互联端口用的 TLS 上下文；admin 端口复用同一份自签证书。
  SecurityContext? get securityContext => _securityContext;
  bool get isRunning => _server != null;
  int get port => _server?.port ?? config.port;
  MangaOcrServiceImpl? get ocrService => _ocrService;

  /// 对端可点名的漫画 OCR 模型（key → 服务）：本平台列得出的每个本机模型一份。
  /// WebUI 逐个显示就绪态、逐个下载。
  Map<String, MangaOcrServiceImpl> get ocrModelServices => _ocrModelServices;
  HostJobManager? get jobs => _jobs;
  ServerDownloadHost? get downloads => _downloads;
  HostSubscriptionHost? get subscriptions => _downloads?.subscriptions;

  /// 进程共享的视频刮削（扫描补刮 / 下载导入 / 客户端远程重刮共用）。[start] 之后非空。
  ServerVideoScrape? get videoScrape => _videoScrape;

  /// Anki 落地（手机的待发卡经互联同步进来，这里写进 Anki 并同步）。
  ServerAnkiLanding? get anki => _anki;

  /// 吊销 peer 后让服务器重读 token 集（否则旧 token 还在缓存里能用到重启）。
  void invalidatePeerTokens() => _server?.invalidatePeerTokenCache();

  /// 配对 PIN 出现/消失时的观察者（WebUI SSE、CLI 打印）。
  final StreamController<PendingPairing?> pairingEvents =
      StreamController<PendingPairing?>.broadcast();

  Future<void> start() async {
    if (_server != null) return;
    await paths.ensureLayout();

    SecurityContext? securityContext;
    if (config.tls) {
      final FushiTlsIdentity tlsIdentity =
          await FushiTlsIdentityStore(dataDir: paths.syncData.path)
              .loadOrCreate();
      securityContext = SecurityContext()
        ..useCertificateChainBytes(utf8.encode(tlsIdentity.certificatePem))
        ..usePrivateKeyBytes(utf8.encode(tlsIdentity.privateKeyPem));
      _hostFingerprint = tlsIdentity.fingerprintSha256;
    }
    _securityContext = securityContext;

    final MangaOcrServiceImpl ocrService = MangaOcrServiceImpl();
    _ocrService = ocrService;
    _ocrModelServices = <String, MangaOcrServiceImpl>{
      for (final MangaOcrLocalModel model in MangaOcrLocalModel.values)
        if (MangaOcrLocalModel.forPlatform(model.key) == model)
          model.key: model == MangaOcrLocalModel.mangaOcr ? ocrService : MangaOcrServiceImpl(localModel: model),
    };
    final MangaOcrHostJobManager ocrJobs = MangaOcrHostJobManager(
      service: ocrService,
      modelServices: _ocrModelServices,
      jobRoot: paths.mangaOcrJobs,
    );

    // 通用任务（第 1 期：ASR）。任务目录持久化，重启可续。
    final HostJobManager jobs = HostJobManager(
      jobRoot: paths.hostJobs,
      runners: <HostJobRunner>[
        AsrHostJobRunner(
          serviceFactory: createServerAsrTranscriptionService,
          resolveVideoPath: _resolveVideoPath,
        ),
      ],
    );
    await jobs.load();
    _jobs = jobs;

    // 视频刮削：一个进程一套，与 app 的 HomePage 同一装配形状（见 video_scrape_host.dart）。
    final ServerVideoScrape videoScrape = ServerVideoScrape(
      db: db,
      prefs: prefs,
      config: () => config,
    );
    _videoScrape = videoScrape;

    // 代下载（第 2 期）：qBittorrent 配了才起管线；没配也挂接口，能力位如实报 supported=false。
    final ServerDownloadHost downloads = ServerDownloadHost(
      config: config,
      paths: paths,
      db: db,
      prefs: prefs,
      identity: identity,
      scrape: videoScrape,
    );
    await downloads.start();
    _downloads = downloads;

    _loopbackOnly = _isLoopbackBind(config.bind);
    final FushiSyncServer server = FushiSyncServer(
      syncDataDir: paths.syncData.path,
      port: config.port,
      token: identity.hostToken,
      allowLan: !_loopbackOnly,
      libraryService: buildLibraryService(),
      mangaOcrJobs: ocrJobs,
      hostJobs: jobs,
      downloads: downloads,
      subscriptions: downloads.subscriptions,
      securityContext: securityContext,
      hostFingerprint: _hostFingerprint,
      deviceName: config.deviceName,
      // 无头服务端的 host 偏好读侧（「允许为对端转码视频」等），与 app 侧同一张
      // `preferences` 表、同一份默认值。
      prefs: prefs,
      // 「AI 下视频」助手会话：手机把下载执行设备设成服务端时整场在这里跑。没配
      // `ai:` 段时能力位如实报 no_provider（路由照挂，客户端好区分「不懂」与「没配」）。
      assistant: createServerAssistantHost(config: () => config, prefs: prefs, db: db, downloads: downloads),
    )
      ..onPairRequest = _approvePairing
      ..onPairPinGenerated = _generatePin
      ..onPairSessionResolved = _clearPendingPairing
      // 这里与下面公网地址的 provider 都读 [config] getter：WebUI 改完即生效。
      ..lanRequiresPinProvider = (() async => config.lanRequiresPin)
      ..onPeerPaired = _persistPairedPeer
      ..pairedPeerTokensProvider = _loadPairedPeerTokens
      // 地址集：与 LAN 广播同一个设备 id；公网 / 反代地址与 app 同一个偏好键。
      ..hostId = identity.deviceId
      ..publicUrlsProvider = (() async => config.publicUrls);
    await server.start();
    _server = server;
    // P2P 挂不上只留痕（[_serializeP2p] 吞错并记 lastError）：server 已经起来了，
    // 这里抛出去会让它没有拥有者（泄漏一个在跑的 server，审查问题 12）。
    await _attachP2p(server);

    final ServerAnkiLanding anki = ServerAnkiLanding(
      prefs: prefs,
      db: db,
      support: paths.support,
      syncData: paths.syncData,
      deviceId: identity.deviceId,
      deviceName: config.deviceName,
    )..start();
    _anki = anki;

    _advertiser = LanAdvertiser(
      deviceName: config.deviceName,
      deviceId: identity.deviceId,
      port: server.port,
      tlsEnabled: securityContext != null,
    );
    await _advertiser!.start();
    engineLog.logDiagnostic(
      'HeadlessHost',
      'listening on ${config.bind}:${server.port} '
          '(${securityContext != null ? 'https' : 'http'}, device=${config.deviceName})',
    );
  }

  static bool _isLoopbackBind(String bind) =>
      bind == '127.0.0.1' || bind == 'localhost';

  // ── P2P 隧道 ──────────────────────────────────────────────────────────
  //
  // 配置 `p2p: true` 且随包带了 libfushi_p2p 时：起 iroh 端点、开信任区监听口、
  // 把 `p2p://<nodeId>` 加进地址集。私钥存服务端偏好表（设备身份，不进用户手改
  // 的配置文件）。失败只留痕，不影响互联本身。
  //
  // 挂载 / 卸载 / 换中继一律经 [_serializeP2p] 排队（与 app 侧
  // `FushiServerController._serializeP2p` 同一形态）：并发的「开了又立刻关」若不
  // 串行，后到的卸载会先落空、先到的挂载随后才挂上——配置显示已关、隧道却对
  // 公网开着。每次配置变更都在队尾追加动作，所以任何一次挂载之后若配置已变，
  // 紧跟着的那次卸载必然排在它后面执行。

  Future<void> _serializeP2p(Future<void> Function() op) {
    final Future<void> next = _p2pOps.then((_) => op());
    _p2pOps = next.then<void>((_) {}, onError: (Object e, StackTrace st) {
      _p2pLastError = '$e';
      engineLog.log('HeadlessHost.p2p', e, st);
    });
    return _p2pOps;
  }

  /// 这台 server 此刻是否应该开着隧道。只监听本机时地址集为空、对外不可达：
  /// 开隧道等于给公网单开一扇门。
  bool _p2pWanted(FushiSyncServer server) =>
      identical(_server, server) && config.p2p && !_loopbackOnly;

  /// 开：起端点 → 信任区监听口 → iroh 入站转发 → 地址集带上 `p2p://`。
  Future<void> _attachP2p(FushiSyncServer server) => _serializeP2p(() async {
        if (!_p2pWanted(server) || _p2pListening) return;
        if (!_p2pAvailable()) {
          engineLog.logDiagnostic(
            'HeadlessHost',
            'p2p: true 但没找到 libfushi_p2p（放在 bin/../lib/ 或设 FUSHI_P2P_LIB），P2P 隧道未启用',
          );
          return;
        }
        _p2pLastError = null;
        final InterconnectP2pRuntime runtime = _p2p ??= InterconnectP2pRuntime(
          loadSecret: () async =>
              prefs.getPref(kInterconnectP2pSecretPref) as String?,
          saveSecret: (String secret) =>
              prefs.setPref(kInterconnectP2pSecretPref, secret),
          // 实时读：换中继时 [_detachP2p] 关掉旧端点，下一次 ensure 按新值重建。
          loadRelayUrls: () async => config.p2pRelays,
        );
        final InterconnectP2pNode? node = await runtime.ensure();
        if (node == null) {
          _p2pLastError = 'P2P 端点启动失败（详见日志）';
          return;
        }
        final int port = await server.startP2pListener();
        // 先挂身份解析器再放流量进来：限流按隧道对端 NodeId 分桶。查当前 node
        // 而不是捕获这一个——换中继会重建端点。
        server.p2pPeerResolver = (int p) => runtime.current?.hostPeer(p);
        node.hostListen(port);
        server.extraAddressesProvider =
            () => runtime.hostAddresses(tls: server.usesTls);
        _p2pListening = true;
        engineLog.logDiagnostic('HeadlessHost', 'p2p node ${node.nodeId}');
      });

  /// 关：停 iroh 入站 → 摘地址集 → 关信任区监听口 → 关端点（关掉才不再连公共
  /// 中继；NodeId 不变，私钥持久）。对未挂载的状态幂等。
  Future<void> _detachP2p(FushiSyncServer server) => _serializeP2p(() async {
        _p2pListening = false;
        final InterconnectP2pRuntime? runtime = _p2p;
        runtime?.current?.hostStop();
        server.extraAddressesProvider = null;
        server.p2pPeerResolver = null;
        await server.stopP2pListener();
        await runtime?.dispose();
      });

  /// 运行中改配置（WebUI）：内存配置换新，「远程可达」三项即时生效——公网地址
  /// 由 provider 实时读；P2P 开关与中继变更在正在跑的 host 上挂载 / 卸载 / 重建
  /// 端点。返回时本次变更引起的 P2P 动作（以及排在它之前的）都已落地。
  Future<void> applyConfig(ServerConfig next) async {
    final ServerConfig prev = _config;
    _config = next;
    final FushiSyncServer? server = _server;
    if (server == null) return;
    final bool relaysChanged = !_sameStrings(prev.p2pRelays, next.p2pRelays);
    if (prev.p2p == next.p2p && !relaysChanged) return;
    // 换中继 = 先整个卸下（关旧端点）再按新中继挂上，与 app 的 setP2pRelayUrls 同序。
    if (!next.p2p || relaysChanged) await _detachP2p(server);
    if (next.p2p) await _attachP2p(server);
  }

  static bool _sameStrings(List<String> a, List<String> b) =>
      a.length == b.length &&
      Iterable<int>.generate(a.length).every((int i) => a[i] == b[i]);

  /// 原生库是否可用（WebUI 据此置灰开关）。
  bool get p2pAvailable => _p2pAvailable();

  /// 给 WebUI / admin API 的 P2P 状态。未生效时 `reason` 说明原因：
  /// `unavailable`（没有原生库）/ `disabled`（没开）/ `host_stopped` /
  /// `loopback_bind`（只监听本机）/ `start_failed`（见 `lastError` 与日志）。
  Map<String, Object?> p2pStatus() {
    final InterconnectP2pRuntime? runtime = _p2p;
    final InterconnectP2pNode? node = runtime?.current;
    final bool active = _p2pListening && node != null;
    // 拨号提示（home relay / 直连地址）从地址集里的 `p2p://` 反解，与对端看到的一致。
    final String? p2pUrl = active
        ? runtime!
            .hostAddresses(tls: _server?.usesTls ?? false)
            .map((InterconnectHostAddress a) => a.url)
            .firstOrNull
        : null;
    final ({
      String nodeId,
      bool tls,
      String? relayUrl,
      List<String> directAddrs,
    })? hints = p2pUrl == null ? null : parseInterconnectP2pUrl(p2pUrl);
    return <String, Object?>{
      'available': p2pAvailable,
      'enabled': config.p2p,
      'active': active,
      'nodeId': node?.nodeId,
      'address': p2pUrl,
      'relayUrl': hints?.relayUrl,
      'directAddrs': hints?.directAddrs ?? const <String>[],
      'reason': active ? null : _p2pInactiveReason(),
      'lastError': _p2pLastError,
    };
  }

  String _p2pInactiveReason() {
    if (!p2pAvailable) return 'unavailable';
    if (!config.p2p) return 'disabled';
    if (_server == null) return 'host_stopped';
    if (_loopbackOnly) return 'loopback_bind';
    return 'start_failed';
  }

  Future<void> stop() async {
    final ServerAnkiLanding? anki = _anki;
    _anki = null;
    await anki?.stop();
    final LanAdvertiser? adv = _advertiser;
    _advertiser = null;
    await adv?.stop();
    final FushiSyncServer? server = _server;
    _server = null;
    // 排在所有在飞的 P2P 动作之后卸下（之前的挂载先落地、再被这次拆掉）。
    if (server != null) await _detachP2p(server);
    await server?.stop();
    final ServerDownloadHost? downloads = _downloads;
    _downloads = null;
    await downloads?.stop();
    // 下载管线借用它，管线停了再关。
    _videoScrape?.close();
    _videoScrape = null;
    await pairingEvents.close();
  }

  // ── 配对回调 ──────────────────────────────────────────────────────────

  /// 无头进程没有「允许/拒绝」按钮：要 PIN 的会话，PIN 本身就是人因（谁能读到
  /// 服务端日志/WebUI 上的 PIN 谁才配得上）；免 PIN 会话只在配置显式关掉
  /// `lan_requires_pin` 时放行。
  Future<bool> _approvePairing(FushiPairRequest request) async {
    if (request.pinRequired) return true;
    return !config.lanRequiresPin;
  }

  String _generatePin(FushiPairSession session) {
    final String pin = FushiPairingProtocol.generatePin();
    final PendingPairing pending = PendingPairing(
      pin: pin,
      deviceName: session.deviceName,
      remoteAddress: session.remoteAddress,
      createdAt: DateTime.now(),
    );
    _pendingPairing = pending;
    // PIN 是敏感值，但它的存在意义就是给操作服务端的人读：打到 stdout（日志文件
    // 也记，与 app 在屏幕上显示同级）。
    stdout.writeln(
      '[pair] ${session.deviceName ?? 'unknown device'} '
      '(${session.remoteAddress ?? '?'}) requests pairing — PIN: $pin',
    );
    pairingEvents.add(pending);
    return pin;
  }

  void _clearPendingPairing() {
    _pendingPairing = null;
    if (!pairingEvents.isClosed) pairingEvents.add(null);
  }

  Future<void> _persistPairedPeer(
      FushiPairedPeerRegistration registration) async {
    await db.upsertPairedPeer(FushiPairedPeersCompanion.insert(
      peerId: registration.peerId,
      token: registration.token,
      pairedAtMs: DateTime.now().millisecondsSinceEpoch,
      deviceName: Value<String?>(registration.deviceName),
      lastSeenIp: Value<String?>(registration.remoteAddress),
    ));
    _server?.invalidatePeerTokenCache();
    engineLog.logDiagnostic(
      'HeadlessHost',
      'paired: ${registration.deviceName ?? registration.peerId}',
    );
  }

  Future<Set<String>> _loadPairedPeerTokens() async {
    final List<FushiPairedPeerRow> peers = await db.getPairedPeers();
    return peers.map((FushiPairedPeerRow r) => r.token).toSet();
  }

  /// `asr` 任务的 `videoId` → host 库里的视频文件（分集 0）。
  Future<String?> _resolveVideoPath(String videoId) async {
    final VideoBookRow? row = await VideoBookRepository(db).getByBookUid(videoId);
    if (row == null) return null;
    final File f = File(row.videoPath);
    return await f.exists() ? f.path : null;
  }

  // ── 库服务 ────────────────────────────────────────────────────────────

  /// 本地音频库的存储中转登记（BUG-2815）：库副本落 `<support>/local_audio_<n>.db`、
  /// 登记落 `local_audio_dbs` 偏好——与 app 的 `LocalAudioManager` 同目录同键，
  /// 服务端不做查词发音，只存、列、导出、删。
  late final LocalAudioLibraryStore localAudio = LocalAudioLibraryStore(
    prefs: prefs,
    databaseDirectory: paths.support,
  );

  /// 互联 host 的库服务装配（[start] 用；测试也直接拿它挂到自建的 TLS
  /// [FushiSyncServer] 上驱动端点，免得起整套下载 / ASR / 局域网广播）。
  LocalLibraryHostService buildLibraryService() => LocalLibraryHostService(
        db: db,
        dictionaryResourceRoot: paths.dictionaryResources,
        packages: SyncAssetPackageService(db: db),
        // 第 0 期服务端不装词典 FFI 引擎，导入/删除词典只改 DB 与目录。
        refreshDictionaryCache: () async {},
        runExclusive: _mutex.run,
        importBookFromFile: (File bookFile) async {
          if (await isMangaPackage(bookFile)) {
            return importMangaPackageFile(
              db: db,
              file: bookFile,
              title: p.basenameWithoutExtension(bookFile.path),
            );
          }
          return EpubImporter.importFromPath(
            db: db,
            filePath: bookFile.path,
            fileName: p.basename(bookFile.path),
          );
        },
        localAudioStagingDir: paths.temp,
        // 以前三件都没接：清单恒空、推送传完才抛 UnsupportedError（BUG-2815）。
        localAudioEntriesProvider: () => localAudio.entries,
        onLocalAudioImported: localAudio.importPackage,
        removeLocalAudioEntry: localAudio.remove,
        audioDatabaseRoot: Directory(p.join(paths.documents.path, 'audiobooks')),
        videoSubtitleLangCode: config.subtitleLanguage,
        // 客户端经互联发起的重刮 / 手动指定身份 / 分集排序：以前这里没接，
        // 这些请求在服务端恒返回空结果或 notPlanned。
        scrapeController: () async => _videoScrape?.controller,
        uploadedVideoRoot: Directory(p.join(paths.documents.path, 'remote_videos')),
        extractVideoCover: (
                {required String videoPath, required String bookUid}) =>
            extractVideoCover(videoPath: videoPath, bookUid: bookUid),
        // 互联「配置文件」搬运：服务端只寄存、不 apply（见 ServerProfileHub）。开关每次
        // 现读配置（`profile_transfer`，默认关），WebUI 改完即生效；关着时端点回 403。
        isProfileTransferEnabled: () async => config.profileTransfer,
        exportActiveProfileJson: profiles.exportShared,
        importProfileJson: profiles.importJson,
        // 书名覆盖：服务端没有 MediaSource 内存缓存，只写 DB（LWW 判据同 app）。
        adoptOverrideTitle: ({
          required String bookKey,
          required String title,
          required int updatedAt,
        }) =>
            adoptOverrideTitleInDb(
              db,
              bookKey: bookKey,
              title: title,
              updatedAt: updatedAt,
            ),
      );
}
