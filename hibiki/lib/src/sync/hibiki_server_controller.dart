import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:flutter/material.dart';
import 'package:hibiki/src/ocr/manga_ocr_service.dart';
import 'package:hibiki/src/platform/desktop/desktop_device_info_service.dart';
import 'package:hibiki/src/sync/hibiki_library_host_service.dart';
import 'package:hibiki/src/sync/hibiki_manga_ocr_host.dart';
import 'package:hibiki/src/sync/hibiki_remote_lookup_service.dart';
import 'package:hibiki/src/sync/hibiki_sync_server.dart';
import 'package:hibiki/src/sync/interconnect_device_name.dart';
import 'package:hibiki/src/sync/lan_discovery_service.dart';
import 'package:hibiki/src/sync/pairing/hibiki_pairing_protocol.dart';
import 'package:hibiki/src/sync/sync_error_messages.dart';
import 'package:hibiki/src/sync/sync_repository.dart';
import 'package:hibiki/src/sync/sync_root_migration.dart';
import 'package:hibiki/src/sync/tls/hibiki_tls_identity.dart';
import 'package:hibiki/utils.dart';
import 'package:hibiki_core/hibiki_core.dart';
import 'package:hibiki_dictionary/hibiki_dictionary.dart';
import 'package:hibiki_platform/hibiki_platform.dart';

/// Result of a [HibikiSyncServerController.start] attempt, so the caller (the
/// settings toggle) can surface the right message while a headless app-init
/// start can just log a failure.
sealed class HibikiServerStartOutcome {
  const HibikiServerStartOutcome();
}

class HibikiServerStarted extends HibikiServerStartOutcome {
  const HibikiServerStarted();
}

class HibikiServerPortInUse extends HibikiServerStartOutcome {
  const HibikiServerPortInUse(this.port);
  final int port;
}

class HibikiServerStartError extends HibikiServerStartOutcome {
  const HibikiServerStartError(this.message);
  final String message;
}

/// App-level owner of the embedded Hibiki LAN sync server + its broadcast.
///
/// Previously the [HibikiSyncServer] and [LanBroadcastService] were owned by the
/// sync-settings page widget, whose `dispose()` stopped them — so simply
/// navigating away from "Sync & backup" killed the host (BUG-085). This
/// controller is owned by [AppModel] for the whole session (mirroring
/// [SyncConflictPrompter]); it starts on launch when hosting is enabled and only
/// stops when the user disables it or the app exits. The settings page becomes a
/// thin view that drives [start] / [stop] and reflects [isRunning].
///
/// The pairing-approval prompt runs through the app-wide [navigatorKey], so a
/// peer can pair even while the user is on another screen.
class HibikiSyncServerController extends ChangeNotifier {
  HibikiSyncServerController({
    required GlobalKey<NavigatorState> navigatorKey,
    required HibikiDatabase Function() database,
    required String Function() syncDataDir,
    required HibikiRemoteLookupService Function() remoteLookupServiceFactory,
    HibikiRemoteMiningService Function()? miningServiceFactory,
    HibikiRemoteHistoryService Function()? historyServiceFactory,
    HibikiLibraryHostService Function()? libraryServiceFactory,
    MangaOcrService Function()? mangaOcrServiceFactory,
    PlatformDeviceInfoService? deviceInfo,
  })  : _navigatorKey = navigatorKey,
        _database = database,
        _syncDataDir = syncDataDir,
        _remoteLookupServiceFactory = remoteLookupServiceFactory,
        _miningServiceFactory = miningServiceFactory,
        _historyServiceFactory = historyServiceFactory,
        _libraryServiceFactory = libraryServiceFactory,
        _mangaOcrServiceFactory = mangaOcrServiceFactory,
        // Headless/test construction without an injected service falls back to
        // the desktop (machine-hostname) source; production wires the real
        // per-platform service so mobile hosts advertise their model, not
        // Android's "localhost" (TODO-1356).
        _deviceInfo = deviceInfo ?? DesktopDeviceInfoService();

  final GlobalKey<NavigatorState> _navigatorKey;
  final HibikiDatabase Function() _database;
  final String Function() _syncDataDir;
  final HibikiRemoteLookupService Function() _remoteLookupServiceFactory;
  final HibikiRemoteMiningService Function()? _miningServiceFactory;
  final HibikiRemoteHistoryService Function()? _historyServiceFactory;
  final HibikiLibraryHostService Function()? _libraryServiceFactory;

  /// 漫画 P3：互联 host 代跑 OCR 的服务工厂。null（headless/单测）= 不接线，
  /// server 的 `/api/ocr/*` 端点 404、capabilities 不带 `mangaOcr` 字段。
  final MangaOcrService Function()? _mangaOcrServiceFactory;
  final PlatformDeviceInfoService _deviceInfo;

  HibikiSyncServer? _server;
  LanBroadcastService? _broadcast;
  // Active LAN discovery browsers registered for app-exit teardown. Discovery is
  // owned by the sync-settings page widget (it lives only while that page is
  // open), but its underlying Bonsoir browser posts mDNS events onto the
  // process message pump from an OS DNS callback thread. If those events are
  // still queued when the Flutter engine/messenger is torn down at process exit,
  // the native bonsoir_windows plugin dereferences a null messenger and the
  // process crashes (TODO-036). Registering live browsers here lets the
  // app-exit hook stop them — i.e. DestroyWindow the bonsoir message window and
  // DnsServiceBrowseCancel — BEFORE the engine is destroyed, cutting the event
  // source at its root. A [Set.identity] keys on object identity so the same
  // service registers/unregisters cleanly.
  final Set<LanDiscoveryService> _activeDiscoveries =
      Set<LanDiscoveryService>.identity();
  // One pairing prompt at a time: a peer must not be able to stack approval
  // dialogs on the host by hammering /api/pair.
  bool _pairDialogOpen = false;

  // TODO-961 M1: 最近一次 v2 配对会话 host 屏显的 6 位 PIN（pair/v2 阶段生成、
  // confirm 阶段的审批弹窗显示）。一次一会话（_pairDialogOpen 串行化），故单值即可。
  String? _pendingPairPin;

  // TODO-1330 / BUG：pinRequired 会话在 host 点「允许」后，弹窗不关、常驻显示 PIN 等
  // 对方输入；此句柄用于外部（client confirm 到达 / TTL）收起那个常驻弹窗。null=当前
  // 没有常驻 PIN 弹窗。串行化同 _pairDialogOpen，故单值即可。
  VoidCallback? _pendingPairPinDismiss;

  // TODO-1330 / BUG-708：区分「审批未决」与「已允许后常驻显示 PIN 等对方输入」两态。
  // 常驻态只是被动显示 PIN、审批决定早已交回，不该继续占用审批槽；否则一次配对被取消 /
  // 未 confirm 时那个常驻弹窗会驻留至 TTL（≈90s），期间任何新配对（尤其「重新配对」）都被
  // _pairDialogOpen 挡成 declined，用户无法重配。此标记让新请求识别常驻弹窗并先收起它再开
  // 新审批。true 仅在 host 已允许、进入常驻 PIN 显示阶段期间。
  bool _pairDialogLingering = false;
  // 收起常驻弹窗后等它彻底 teardown（whenComplete 清共享单值态）的信号，避免新旧弹窗争用
  // _pendingPairPin / _pendingPairPinDismiss 单值字段。仅在等待收起旧常驻弹窗期间非 null。
  Completer<void>? _pairDialogClosed;

  // BUG-987：当前打开的审批弹窗对应的来源地址（remoteAddress）。用于「同源重试
  // supersede 未决弹窗」——第一次配对被 client 放弃（超时/断网/取消）后，host 那个仍
  // 处于「审批未决」的申请框会驻留至 60s autoDeny，期间同一 client「重新刷新」重发的
  // 配对请求都被 _pairDialogOpen 挡成 declined、看不到新申请框。此字段让 _promptPairApproval
  // 识别「新请求与滞留弹窗同源」并先收起旧框再开新框；不同来源仍保留防叠弹拒绝（防恶意
  // peer 顶掉别人正在审批的框）。null=当前无打开的弹窗。
  String? _pairDialogRemoteAddress;

  bool get isRunning => _server?.isRunning ?? false;
  int? get boundPort => _server?.port;

  /// Register a live LAN discovery browser so [shutdownForExit] can stop it
  /// before the Flutter engine is torn down. Idempotent.
  void registerDiscovery(LanDiscoveryService discovery) {
    _activeDiscoveries.add(discovery);
  }

  /// Drop a discovery browser from the exit-teardown set once its owner has
  /// already disposed it (e.g. the sync-settings page closed). Idempotent.
  void unregisterDiscovery(LanDiscoveryService discovery) {
    _activeDiscoveries.remove(discovery);
  }

  /// App-exit teardown: stop every Bonsoir event source still alive (the LAN
  /// broadcast owned here for the whole session, plus any discovery browser the
  /// settings page registered) so no mDNS event is delivered to a torn-down
  /// engine/messenger (TODO-036, Windows null-messenger crash). Must be awaited
  /// on the app-close signal BEFORE the window/engine is destroyed.
  ///
  /// Deliberately does NOT persist `serverEnabled=false`: this is an app exit,
  /// not a user toggle-off, so the next launch restores hosting.
  Future<void> shutdownForExit() async {
    // Snapshot first: dispose() mutates the owner's state, and unregister calls
    // can land mid-iteration.
    final List<LanDiscoveryService> discoveries =
        _activeDiscoveries.toList(growable: false);
    _activeDiscoveries.clear();
    for (final LanDiscoveryService discovery in discoveries) {
      await discovery.dispose();
    }
    await stop();
  }

  /// 进程退出快速变体（TODO-086/BUG-191）：用于即将 `exit(0)` 的快杀路径。
  /// 对每个 Bonsoir 事件源**同步 await 切断 Dart 订阅**（TODO-036 防崩的关键），
  /// 但把原生 method-channel stop 改 fire-and-forget——不再像 [shutdownForExit]
  /// 那样 await 可能不归的原生 stop（根因B：Bonsoir 原生 stop 吃满 3 秒）。
  /// 随后的 exit(0) 进程级终止会回收原生线程，无需等其完成。broadcast 同理。
  Future<void> shutdownForExitFast() async {
    final List<LanDiscoveryService> discoveries =
        _activeDiscoveries.toList(growable: false);
    _activeDiscoveries.clear();
    for (final LanDiscoveryService discovery in discoveries) {
      await discovery.cutEventSourceForExit();
    }
    _broadcast?.cutEventSourceForExit();
    _broadcast = null;
    // HTTP 服务器（shelf）无 mDNS 事件源、不触发 TODO-036；其 close 也可能慢，
    // 同样 fire-and-forget，exit(0) 兜底回收 socket。
    unawaited(_server?.stop());
    _server = null;
    notifyListeners();
  }

  SyncRepository get _repo => SyncRepository(_database());

  /// Start the host on launch iff the user previously enabled it. Fire-and-
  /// forget friendly: any bind failure self-disables + is reported via the
  /// returned outcome (callers at init just log it).
  Future<HibikiServerStartOutcome> startIfEnabled() async {
    if (!await _repo.isServerEnabled()) return const HibikiServerStarted();
    return start();
  }

  /// Bind the server (idempotent while already running) and advertise on the
  /// LAN. Persists `serverEnabled=true` after a successful bind.
  ///
  /// On failure the user's persistent intent (`serverEnabled`) is deliberately
  /// preserved so that a transient port conflict (another process holds the port
  /// at launch) does not permanently erase the user's preference — the next
  /// launch will retry automatically (BUG-160 / HBK-AUDIT-167 revised).
  /// The intent is only cleared when the user explicitly disables hosting via
  /// [stop(persistDisabled: true)].
  Future<HibikiServerStartOutcome> start() async {
    if (isRunning) return const HibikiServerStarted();
    final SyncRepository repo = _repo;
    final int port = await repo.getServerPort();
    String? token = await repo.getServerPassword();
    if (token == null) {
      token = HibikiSyncServer.generateToken();
      await repo.setServerPassword(token);
    }
    // TODO-961 M1: 仅当用户显式开启 TLS 时，加载（必要时生成）自签证书身份并起
    // HTTPS。默认关 → securityContext/hostFingerprint 均 null → 明文 HTTP 老路径，
    // 行为零变化（Never break userspace）。指纹随配对响应回传供 client TOFU 钉扎。
    SecurityContext? securityContext;
    String? hostFingerprint;
    if (await repo.getServerTlsEnabled()) {
      final HibikiTlsIdentity identity =
          await HibikiTlsIdentityStore(dataDir: _syncDataDir()).loadOrCreate();
      securityContext = SecurityContext()
        ..useCertificateChainBytes(utf8.encode(identity.certificatePem))
        ..usePrivateKeyBytes(utf8.encode(identity.privateKeyPem));
      hostFingerprint = identity.fingerprintSha256;
    }
    final String deviceName = await _deviceName();
    final HibikiSyncServer server = HibikiSyncServer(
      syncDataDir: _syncDataDir(),
      port: port,
      token: token,
      allowLan: true,
      remoteLookupService: _remoteLookupServiceFactory(),
      miningService: _miningServiceFactory?.call(),
      historyService: _historyServiceFactory?.call(),
      libraryService: _libraryServiceFactory?.call(),
      // 漫画 P3：远程 OCR 任务管理器。上传页图落 <syncDataDir>/manga_ocr_jobs
      // （TTL 自清理）。每次 start 新建管理器，stop 时 server 内部 disposeAll。
      mangaOcrJobs: _buildMangaOcrJobManager(),
      securityContext: securityContext,
      hostFingerprint: hostFingerprint,
      deviceName: deviceName,
      // TODO-1215: bridge dictionary media bytes (gaiji/accent SVG) to the
      // FFI engine so the browser extension's rewritten <img> GET can fetch
      // them. Null-safe: before the engine is initialised it yields null and
      // the endpoint answers 404.
      dictionaryMediaProvider: (String dict, String mediaPath) =>
          FushiDicts.isInitialized
              ? FushiDicts.instance.getMediaFile(dict, mediaPath)
              : null,
    )
      ..onPairRequest = _promptPairApproval
      // TODO-961 M1: host 生成并暂存本会话 PIN，供 confirm 阶段审批弹窗显示。
      ..onPairPinGenerated = _generatePairPin
      // TODO-1330 / BUG：client 提交 confirm（已读到 PIN）后收起 host 常驻 PIN 弹窗。
      ..onPairSessionResolved = _dismissPendingPairPinDialog
      ..lanRequiresPinProvider = _repo.getLanRequiresPin
      // TODO-961 M1b: confirm 成功后把 per-peer 凭据落库 + 供给 auth 校验的有效 token
      // 集合。server 不直连 DB，经这两个回调打通存储层（清缓存在 server 内部完成）。
      ..onPeerPaired = _persistPairedPeer
      ..pairedPeerTokensProvider = _loadPairedPeerTokens;
    // Fushi 改名迁移（host 侧）：host 的 WebDAV 根映射到 server.syncDataDir，
    // client 的同步根是其下的 `fushi-data/` 子目录。旧安装磁盘上还留着
    // `hibiki-data/` → 本地整目录 rename（同盘原子，不搬数据）。幂等；失败留痕
    // 降级（client 会新建空新根，下次 host 启动重试），绝不挡 server 启动。
    await migrateLegacySyncRootDirectory(
      syncDataDir: server.syncDataDir,
      onError: (Object e, StackTrace st) => ErrorLogService.instance
          .log('HibikiServerController.migrateLegacySyncRoot', e, st),
    );
    try {
      await server.start();
      _server = server;
      await repo.setServerEnabled(true);
      // Advertise the ACTUAL bound port so peers discover the host even when the
      // requested port was 0/auto or differs from the configured one.
      // TODO-961: TXT 带上 tls 标志，发现方按它优先走 https 探测。
      await _startBroadcast(server.port, tlsEnabled: securityContext != null);
      notifyListeners();
      return const HibikiServerStarted();
    } on SyncServerPortInUseException catch (e) {
      _server = null;
      // Do NOT clear serverEnabled: the bind failure is transient (another
      // process holds the port).  The intent remains true so the next launch
      // retries automatically.
      notifyListeners();
      return HibikiServerPortInUse(e.port);
    } catch (e) {
      _server = null;
      // Same rationale: a general error at bind time must not permanently erase
      // the user's hosting preference.
      notifyListeners();
      return HibikiServerStartError(friendlySyncErrorDetail(e));
    }
  }

  /// 漫画 P3：按注入的 OCR 服务工厂构造远程 OCR 任务管理器；未注入返回 null
  /// （server 端点整体关闭）。上传页图落 `<syncDataDir>/manga_ocr_jobs`（TTL
  /// 自清理），每次 [start] 新建、server stop 时其内部 disposeAll。
  MangaOcrHostJobManager? _buildMangaOcrJobManager() {
    final MangaOcrService Function()? factory = _mangaOcrServiceFactory;
    if (factory == null) return null;
    return MangaOcrHostJobManager(
      service: factory(),
      jobRoot: Directory(
        '${_syncDataDir()}${Platform.pathSeparator}manga_ocr_jobs',
      ),
    );
  }

  /// Stop the host. [persistDisabled] writes `serverEnabled=false` (the user
  /// toggled it off); an app-exit/transient stop leaves the flag untouched so a
  /// future launch restores hosting.
  Future<void> stop({bool persistDisabled = false}) async {
    await _broadcast?.stop();
    _broadcast = null;
    await _server?.stop();
    _server = null;
    if (persistDisabled) await _repo.setServerEnabled(false);
    notifyListeners();
  }

  /// Bounce the server so a freshly-persisted token / port takes effect.
  Future<HibikiServerStartOutcome> restart() async {
    await stop();
    return start();
  }

  Future<void> _startBroadcast(
    int boundPort, {
    required bool tlsEnabled,
  }) async {
    final SyncRepository repo = _repo;
    final String deviceId = await repo.getOrCreateDeviceId();
    _broadcast = LanBroadcastService(
      deviceName: await _deviceName(),
      deviceId: deviceId,
      port: boundPort,
      tlsEnabled: tlsEnabled,
    );
    await _broadcast!.start();
  }

  /// Human-readable advertisement name shown to peers (host `/api/ping` + LAN
  /// broadcast). Sourced from the platform device-info service: the machine
  /// hostname on desktop, the real hardware model on mobile — never Android's
  /// meaningless "localhost" hostname (TODO-1356).
  Future<String> _deviceName() => resolveInterconnectDeviceName(_deviceInfo);

  /// TODO-961 M1: server 在 pair/v2 创建会话时回调，host 生成本会话 6 位 PIN 并
  /// 暂存，供随后的 confirm 审批弹窗显示给用户。返回的 PIN 同时被 server 用于
  /// confirm 阶段重算 HMAC proof 比对——同一值，绝不过线。
  String _generatePairPin(HibikiPairSession session) {
    final String pin = HibikiPairingProtocol.generatePin();
    _pendingPairPin = pin;
    return pin;
  }

  /// TODO-961 M1b: server confirm 成功回调——把一台新配对设备的 per-peer 凭据 upsert
  /// 进 `hibiki_paired_peers`（peerId UNIQUE，重复配对同一设备只轮换其 token）。
  /// token 是敏感凭据，绝不写日志。
  Future<void> _persistPairedPeer(
      HibikiPairedPeerRegistration registration) async {
    await _database().upsertPairedPeer(HibikiPairedPeersCompanion.insert(
      peerId: registration.peerId,
      token: registration.token,
      pairedAtMs: DateTime.now().millisecondsSinceEpoch,
      deviceName: Value<String?>(registration.deviceName),
      lastSeenIp: Value<String?>(registration.remoteAddress),
    ));
  }

  /// TODO-961 M1b: 供给 server auth 校验用的全部有效（未吊销）per-peer token 集合。
  /// 吊销 = 删行，故只需读全表 token。
  Future<Set<String>> _loadPairedPeerTokens() async {
    final List<HibikiPairedPeerRow> peers = await _database().getPairedPeers();
    return peers.map((HibikiPairedPeerRow p) => p.token).toSet();
  }

  /// 全部已配对设备（供「移除已配对设备」UI 列表）。按配对先后升序。
  Future<List<HibikiPairedPeerRow>> pairedPeers() =>
      _database().getPairedPeers();

  /// TODO-961 M1b: 吊销一台已配对设备（删其 per-peer token 行），返回是否真的删了。
  /// 删后清 server 端 token 缓存 → 该设备下一次请求即被 401（吊销即时生效）。
  Future<bool> revokePeer(String peerId) async {
    final int deleted = await _database().revokePairedPeer(peerId);
    if (deleted > 0) _server?.invalidatePeerTokenCache();
    return deleted > 0;
  }

  /// TODO-1330 / BUG：client 提交 confirm 后收起 host 那个常驻显示 PIN 的审批弹窗
  /// （见 [_promptPairApproval]）。作为 server 的 [HibikiSyncServer.onPairSessionResolved]
  /// 回调接线；无常驻弹窗时（免 PIN / 已关）为 no-op。
  void _dismissPendingPairPinDialog() {
    _pendingPairPinDismiss?.call();
  }

  /// 测试缝（BUG-708）：直接驱动 host 审批弹窗，模拟 server 在 `_handlePairV2` 里
  /// 「先 [_generatePairPin] 暂存 PIN，再调 [onPairRequest]」的时序。[seedPin] 非空时
  /// 先写入 [_pendingPairPin]（等价 [_generatePairPin] 的效果），供 pinRequired 会话的
  /// 弹窗显示。返回值与真实审批一致（true=允许 / false=拒绝或被叠弹挡下）。
  @visibleForTesting
  Future<bool> debugPromptPairApproval(
    HibikiPairRequest request, {
    String? seedPin,
  }) {
    if (seedPin != null) _pendingPairPin = seedPin;
    return _promptPairApproval(request);
  }

  /// Server callback: a peer POSTed /api/pair. Ask the host user to allow the
  /// token handout via the app-wide navigator so the prompt appears even when
  /// the user is not on the sync page. Resolves false (refuse) on a stacked
  /// request, a missing context, an explicit deny, or a 60s no-answer timeout.
  ///
  /// TODO-1330 / BUG（公网配对 PIN 时序）：把「审批结果」与「弹窗生命周期」解耦。旧
  /// 实现里 host 点「允许」会立刻 pop 弹窗并清 [_pendingPairPin]，但 client 要等
  /// pair/v2 收到审批结果后才弹 PIN 输入框——于是 client 要输 PIN 时，host 屏上的 PIN
  /// 早没了。现在：点允许即把结果交回 server（[approval] completer，好让 client 拿到
  /// 会话去弹 PIN 框），但对 **pinRequired** 会话**不关窗**，继续常驻显示 PIN，直到
  /// client 提交 confirm（[onPairSessionResolved] → [_dismissPendingPairPinDialog]）、
  /// 用户手动关、或会话 TTL 超时。免 PIN 会话行为不变（无 PIN 可显示，点选即关）。
  Future<bool> _promptPairApproval(HibikiPairRequest request) async {
    // 先收起一个应被本次新请求取代的旧弹窗，等它彻底 teardown（whenComplete 清共享单值
    // 态）再开新框，并把本会话刚生成的 PIN（可能被旧 teardown 清空）恢复回来。两种取代：
    //   (a) TODO-1330 / BUG-708：旧弹窗是「已允许、常驻显示 PIN 等对方输入」（lingering）——
    //       它已不占审批槽，收起它让「取消后重新配对」不被误判为 stacked 而拒绝。
    //   (b) BUG-987：旧弹窗仍「审批未决」但与本次新请求同源（同 remoteAddress）——第一次
    //       配对被 client 放弃（超时/断网/取消）后那个未决框会驻留至 60s autoDeny，期间同一
    //       client「重新刷新」重发的配对都被 _pairDialogOpen 挡成 declined、看不到新申请框。
    //       同源取代它即可让重试重新弹框；不同来源的未决框保留（防恶意 peer 顶掉别人正在
    //       审批的框），仍由 _showPairApprovalDialog 的 _pairDialogOpen 拒绝。
    final bool supersedeStale = _pairDialogOpen &&
        (_pairDialogLingering || _isSamePairSource(request.remoteAddress));
    if (supersedeStale) {
      final String? incomingPin = _pendingPairPin;
      final Completer<void> closed = Completer<void>();
      _pairDialogClosed = closed;
      _pendingPairPinDismiss?.call();
      await closed.future.timeout(const Duration(seconds: 2), onTimeout: () {});
      _pendingPairPin = incomingPin;
    }
    return _showPairApprovalDialog(request);
  }

  /// BUG-987：新配对请求的来源是否与当前打开的审批弹窗同源（同 remoteAddress）。用于
  /// 「同源重试取代未决弹窗」。任一来源为空（无法解析来源 IP）时保守判为不同源——不取代，
  /// 避免把两个匿名来源误当同源互相顶掉别人的审批框。
  bool _isSamePairSource(String? incoming) {
    final String? current = _pairDialogRemoteAddress;
    if (current == null || current.isEmpty) return false;
    if (incoming == null || incoming.isEmpty) return false;
    return current == incoming;
  }

  /// 实际展示 host 审批 / 常驻 PIN 弹窗并返回审批结果（[_promptPairApproval] 处理完
  /// 「收起上一个常驻弹窗」的异步收尾后调用）。本方法内**没有任何 await**——弹窗用
  /// unawaited 打开、结果经 [approval] completer 回传——故其对 [_navigatorKey] 当前
  /// context 的使用不跨异步间隙（避免误用陈旧 BuildContext）。
  Future<bool> _showPairApprovalDialog(HibikiPairRequest request) {
    // 仍处于「审批未决」的弹窗才真正占槽——此时拒绝新请求（防恶意 peer 叠弹审批）。
    if (_pairDialogOpen) return Future<bool>.value(false);
    final BuildContext? ctx = _navigatorKey.currentContext;
    if (ctx == null) return Future<bool>.value(false);
    _pairDialogOpen = true;
    _pairDialogLingering = false;
    // BUG-987：记录本框来源，供同源新请求识别并取代滞留的未决框（见 _promptPairApproval）。
    _pairDialogRemoteAddress = request.remoteAddress;

    final Completer<bool> approval = Completer<bool>();
    // 只有「真的要显示 PIN」的 pinRequired 会话才走常驻分支；免 PIN / 无 PIN 走旧的
    // 「点选即关」行为（无 PIN 可留、留了也没意义）。
    final bool lingerAfterApprove =
        request.pinRequired && _pendingPairPin != null;
    Timer? autoDeny;
    Timer? lingerTimeout;
    BuildContext? dialogCtx;
    StateSetter? setDialogState;
    bool approvedPhase = false;
    bool popped = false;

    void popDialog() {
      final BuildContext? dc = dialogCtx;
      if (!popped && dc != null && Navigator.of(dc).canPop()) {
        popped = true;
        Navigator.pop(dc);
      }
    }

    // 外部收起句柄（client confirm 到达 / TTL 超时经此收起常驻 PIN 弹窗）。
    _pendingPairPinDismiss = popDialog;

    void onDeny() {
      if (!approval.isCompleted) approval.complete(false);
      popDialog();
    }

    void onAllow() {
      // 先把结果交回 server（免得 client 一直等），再决定是否关窗。
      if (!approval.isCompleted) approval.complete(true);
      if (lingerAfterApprove) {
        // 常驻 PIN 阶段：不关窗，转成「等对方输入此 PIN」，直到 confirm / 手动 / TTL。
        // 标记「常驻」态：审批决定已交回，此弹窗只被动显示 PIN，不再占审批槽（BUG-708）。
        approvedPhase = true;
        _pairDialogLingering = true;
        setDialogState?.call(() {});
        // 安全兜底：对齐 server 会话 TTL（≈90s）到点仍没 confirm 就自动收起，避免
        // host 屏上留一个永不消失的 PIN 弹窗。
        lingerTimeout ??= Timer(const Duration(seconds: 90), popDialog);
      } else {
        popDialog();
      }
    }

    unawaited(showAppDialog<void>(
      context: ctx,
      // 审批 / 常驻 PIN 阶段都统一走按钮，禁止点遮罩误关（PIN 要一直看得见）。
      barrierDismissible: false,
      builder: (BuildContext dCtx) {
        dialogCtx = dCtx;
        // Auto-refuse after 60s so a forgotten prompt never leaks the token and
        // the waiting client gets a deterministic answer. 进入常驻 PIN 阶段
        // （已允许）后失效——那时结果已交回，只等对方输入。
        autoDeny ??= Timer(const Duration(seconds: 60), () {
          if (!approvedPhase) onDeny();
        });
        return StatefulBuilder(
          builder: (BuildContext c, StateSetter setLocal) {
            setDialogState = setLocal;
            final HibikiDesignTokens tokens = HibikiDesignTokens.of(c);
            final bool waiting = approvedPhase;
            // PIN 只在 host 屏幕显示，绝不过线（client 只回传 HMAC proof）。仅当本会话
            // 真要求 PIN（request.pinRequired）才显示，免 PIN 会话不显示「幽灵 PIN」。
            final bool showPin = request.pinRequired && _pendingPairPin != null;
            return HibikiDialogFrame(
              maxWidth: 420,
              insetPadding: EdgeInsets.symmetric(
                horizontal: tokens.spacing.card,
                vertical: tokens.spacing.card,
              ),
              scrollable: false,
              child: HibikiModalSheetFrame(
                title: t.sync_pair_request_title,
                scrollable: true,
                bodyPadding: EdgeInsets.fromLTRB(
                  tokens.spacing.card,
                  0,
                  tokens.spacing.card,
                  tokens.spacing.gap,
                ),
                footerPadding: EdgeInsets.fromLTRB(
                  tokens.spacing.card,
                  tokens.spacing.gap,
                  tokens.spacing.card,
                  tokens.spacing.card,
                ),
                body: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    // 已允许 → 提示「等对方输入此 PIN」；未决 → 原「设备请求配对」文案。
                    Text(waiting
                        ? t.sync_pair_pin_waiting
                        : t.sync_pair_request_body),
                    SizedBox(height: tokens.spacing.gap),
                    Text(
                      _pairRequesterLabel(request),
                      style: Theme.of(c).textTheme.bodyMedium?.copyWith(
                            fontWeight: FontWeight.w600,
                          ),
                    ),
                    if (showPin) ...<Widget>[
                      SizedBox(height: tokens.spacing.gap),
                      Text(t.sync_pair_pin_label),
                      SizedBox(height: tokens.spacing.gap),
                      Text(
                        _pendingPairPin!,
                        style: Theme.of(c).textTheme.headlineMedium?.copyWith(
                          fontFeatures: const <FontFeature>[
                            FontFeature.tabularFigures(),
                          ],
                          letterSpacing: 4,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ],
                  ],
                ),
                footer: Wrap(
                  alignment: WrapAlignment.end,
                  spacing: tokens.spacing.gap,
                  children: waiting
                      // 常驻 PIN 阶段：只留「关闭」（结果已交回，用户输完后手动收起）。
                      ? <Widget>[
                          adaptiveDialogAction(
                            context: c,
                            isDefaultAction: true,
                            onPressed: popDialog,
                            child: Text(t.dialog_close),
                          ),
                        ]
                      : <Widget>[
                          adaptiveDialogAction(
                            context: c,
                            isDestructiveAction: true,
                            onPressed: onDeny,
                            child: Text(t.sync_pair_deny),
                          ),
                          adaptiveDialogAction(
                            context: c,
                            isDefaultAction: true,
                            onPressed: onAllow,
                            child: Text(t.sync_pair_allow),
                          ),
                        ],
                ),
              ),
            );
          },
        );
      },
    ).whenComplete(() {
      autoDeny?.cancel();
      lingerTimeout?.cancel();
      _pairDialogOpen = false;
      _pairDialogLingering = false;
      _pairDialogRemoteAddress = null;
      _pendingPairPin = null;
      _pendingPairPinDismiss = null;
      // 若有新配对正等本（常驻）弹窗收起，放行它继续（BUG-708）。
      if (_pairDialogClosed?.isCompleted == false) {
        _pairDialogClosed?.complete();
      }
      _pairDialogClosed = null;
      // 弹窗被系统/其它路径关掉而用户没点过按钮时，兜底判为拒绝。
      if (!approval.isCompleted) approval.complete(false);
    }));

    return approval.future;
  }

  /// "<name> · <ip>" when both are known, else whichever is present, else a
  /// generic label so the prompt always names a requester.
  String _pairRequesterLabel(HibikiPairRequest request) {
    final String name = request.deviceName?.trim() ?? '';
    final String ip = request.remoteAddress?.trim() ?? '';
    if (name.isNotEmpty && ip.isNotEmpty) return '$name · $ip';
    if (name.isNotEmpty) return name;
    if (ip.isNotEmpty) return ip;
    return t.sync_pair_unknown_device;
  }
}
