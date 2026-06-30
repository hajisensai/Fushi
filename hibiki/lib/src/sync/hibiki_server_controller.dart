import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:hibiki/src/sync/hibiki_library_host_service.dart';
import 'package:hibiki/src/sync/hibiki_remote_lookup_service.dart';
import 'package:hibiki/src/sync/hibiki_sync_server.dart';
import 'package:hibiki/src/sync/lan_discovery_service.dart';
import 'package:hibiki/src/sync/pairing/hibiki_pairing_protocol.dart';
import 'package:hibiki/src/sync/sync_error_messages.dart';
import 'package:hibiki/src/sync/sync_repository.dart';
import 'package:hibiki/src/sync/tls/hibiki_tls_identity.dart';
import 'package:hibiki/utils.dart';
import 'package:hibiki_core/hibiki_core.dart';

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
  })  : _navigatorKey = navigatorKey,
        _database = database,
        _syncDataDir = syncDataDir,
        _remoteLookupServiceFactory = remoteLookupServiceFactory,
        _miningServiceFactory = miningServiceFactory,
        _historyServiceFactory = historyServiceFactory,
        _libraryServiceFactory = libraryServiceFactory;

  final GlobalKey<NavigatorState> _navigatorKey;
  final HibikiDatabase Function() _database;
  final String Function() _syncDataDir;
  final HibikiRemoteLookupService Function() _remoteLookupServiceFactory;
  final HibikiRemoteMiningService Function()? _miningServiceFactory;
  final HibikiRemoteHistoryService Function()? _historyServiceFactory;
  final HibikiLibraryHostService Function()? _libraryServiceFactory;

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
    final HibikiSyncServer server = HibikiSyncServer(
      syncDataDir: _syncDataDir(),
      port: port,
      token: token,
      allowLan: true,
      remoteLookupService: _remoteLookupServiceFactory(),
      miningService: _miningServiceFactory?.call(),
      historyService: _historyServiceFactory?.call(),
      libraryService: _libraryServiceFactory?.call(),
      securityContext: securityContext,
      hostFingerprint: hostFingerprint,
      deviceName: _deviceName(),
    )
      ..onPairRequest = _promptPairApproval
      // TODO-961 M1: host 生成并暂存本会话 PIN，供 confirm 阶段审批弹窗显示。
      ..onPairPinGenerated = _generatePairPin
      ..lanRequiresPinProvider = _repo.getLanRequiresPin;
    try {
      await server.start();
      _server = server;
      await repo.setServerEnabled(true);
      // Advertise the ACTUAL bound port so peers discover the host even when the
      // requested port was 0/auto or differs from the configured one.
      await _startBroadcast(server.port);
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

  Future<void> _startBroadcast(int boundPort) async {
    final SyncRepository repo = _repo;
    final String deviceId = await repo.getOrCreateDeviceId();
    _broadcast = LanBroadcastService(
      deviceName: _deviceName(),
      deviceId: deviceId,
      port: boundPort,
    );
    await _broadcast!.start();
  }

  /// Human-readable advertisement name. Platform.localHostname is the machine
  /// name on desktop; falls back to a generic label on mobile or on error.
  String _deviceName() {
    try {
      final String host = Platform.localHostname;
      if (host.trim().isNotEmpty) return 'Hibiki · $host';
    } catch (_) {/* localHostname can throw on some platforms */}
    return 'Hibiki';
  }

  /// TODO-961 M1: server 在 pair/v2 创建会话时回调，host 生成本会话 6 位 PIN 并
  /// 暂存，供随后的 confirm 审批弹窗显示给用户。返回的 PIN 同时被 server 用于
  /// confirm 阶段重算 HMAC proof 比对——同一值，绝不过线。
  String _generatePairPin(HibikiPairSession session) {
    final String pin = HibikiPairingProtocol.generatePin();
    _pendingPairPin = pin;
    return pin;
  }

  /// Server callback: a peer POSTed /api/pair. Ask the host user to allow the
  /// token handout via the app-wide navigator so the prompt appears even when
  /// the user is not on the sync page. Resolves false (refuse) on a stacked
  /// request, a missing context, an explicit deny, or a 60s no-answer timeout.
  Future<bool> _promptPairApproval(HibikiPairRequest request) async {
    if (_pairDialogOpen) return false;
    final BuildContext? ctx = _navigatorKey.currentContext;
    if (ctx == null) return false;
    _pairDialogOpen = true;
    Timer? autoDeny;
    try {
      final bool? approved = await showAppDialog<bool>(
        context: ctx,
        builder: (BuildContext dialogCtx) {
          // Auto-refuse after 60s so a forgotten prompt never leaks the token
          // and the waiting client gets a deterministic answer.
          autoDeny ??= Timer(const Duration(seconds: 60), () {
            if (Navigator.of(dialogCtx).canPop()) {
              Navigator.pop(dialogCtx, false);
            }
          });
          final HibikiDesignTokens tokens = HibikiDesignTokens.of(dialogCtx);
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
                  Text(t.sync_pair_request_body),
                  SizedBox(height: tokens.spacing.gap),
                  Text(
                    _pairRequesterLabel(request),
                    style: Theme.of(dialogCtx).textTheme.bodyMedium?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                  ),
                  // TODO-961 M1: v2 配对（request.pinVerified != null）显示本会话
                  // PIN，让用户口头/屏显把 PIN 念给 client 输入。PIN 只在 host 屏幕
                  // 显示，绝不过线（client 只回传 HMAC proof）。
                  if (request.pinVerified != null &&
                      _pendingPairPin != null) ...<Widget>[
                    SizedBox(height: tokens.spacing.gap),
                    Text(t.sync_pair_pin_label),
                    SizedBox(height: tokens.spacing.gap),
                    Text(
                      _pendingPairPin!,
                      style: Theme.of(dialogCtx)
                          .textTheme
                          .headlineMedium
                          ?.copyWith(
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
                children: <Widget>[
                  adaptiveDialogAction(
                    context: dialogCtx,
                    isDestructiveAction: true,
                    onPressed: () => Navigator.pop(dialogCtx, false),
                    child: Text(t.sync_pair_deny),
                  ),
                  adaptiveDialogAction(
                    context: dialogCtx,
                    isDefaultAction: true,
                    onPressed: () => Navigator.pop(dialogCtx, true),
                    child: Text(t.sync_pair_allow),
                  ),
                ],
              ),
            ),
          );
        },
      );
      return approved ?? false;
    } finally {
      autoDeny?.cancel();
      _pairDialogOpen = false;
      _pendingPairPin = null;
    }
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
