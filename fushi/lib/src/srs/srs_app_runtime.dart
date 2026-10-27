/// 复习模块（SRS）在 app 进程里的常驻装配：只在模块开着时存在。
///
/// 模块开着时 [srsAppRuntimeProvider] 建一个 [SrsAppRuntime]，它装上：
/// - [SrsAppHost.current]：app 外查词窗 deferred 桥与 Fushi API `/api/srs/*` 的入口；
/// - AnkiConnect v6 兼容端点（Fushi API 根路径）+ `fushiAnkiConnectCompatInstanceId`；
/// - 常规同步的通道后置步骤（`syncChannelPostRunHook`）+ 进入复习 tab 的节流同步；
/// - 自动优化的空闲调度（前台、不在复习页、最多每 6 小时检查一次）。
///
/// 模块关掉（或 provider 被销毁）时 [SrsAppRuntime.dispose] 把上面全部卸下、置回 null：
/// 关着时 app 里没有任何 SRS 定时器、监听、端点或同步步骤（用户硬要求：零行为变化、
/// 零额外开销）。main.dart 在 `appModel.initialise()` 之后 listen 本 provider 保活。
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fushi_anki/fushi_anki_core.dart'
    show fushiAnkiConnectCompatInstanceId;
import 'package:fushi_engine/srs/ankiconnect/srs_ankiconnect_endpoint.dart';
import 'package:fushi_engine/srs/ankiconnect/srs_ankiconnect_handler.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_engine/srs/srs_profile_link.dart';
import 'package:fushi_engine/sync/local_directory_asset_store.dart';
import 'package:fushi_engine/sync/sync_asset_store.dart';
import 'package:fushi_srs/fushi_srs.dart';

import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/models/home_tab.dart';
import 'package:fushi/src/pages/implementations/home_page.dart'
    show homeShellTabNotifier;
import 'package:fushi/src/profile/profile_view_model.dart';
import 'package:fushi/src/srs/srs_app_host.dart';
import 'package:fushi/src/srs/srs_legacy_backup_cleanup.dart';
import 'package:fushi/src/srs/srs_directory_key.dart';
import 'package:fushi/src/srs/srs_interconnect_watch.dart';
import 'package:fushi/src/srs/srs_media_store.dart';
import 'package:fushi/src/srs/srs_optimization_scheduler.dart';
import 'package:fushi/src/srs/srs_providers.dart';
import 'package:fushi/src/srs/srs_sync_scheduler.dart';
import 'package:fushi/src/sync/interconnect_sync_backend.dart';
import 'package:fushi/src/sync/sync_auto_trigger.dart';
import 'package:fushi/src/sync/sync_backend.dart';
import 'package:fushi/src/sync/sync_repository.dart';
import 'package:fushi/utils.dart';

/// 模块开着时的常驻装配（见文件头）；关着时为 null。
final Provider<SrsAppRuntime?> srsAppRuntimeProvider = Provider<SrsAppRuntime?>(
  (Ref ref) {
    if (!ref.watch(srsModuleEnabledProvider)) return null;
    final AppModel app = ref.read(appProvider);
    final SrsRevisionOrigin revisionOrigin = SrsRevisionOrigin();
    final SrsAppRuntime runtime = SrsAppRuntime(
      app: app,
      readStore: () async {
        try {
          return await ref.read(srsStoreProvider.future);
        } catch (e, stack) {
          ErrorLogService.instance.log('SrsAppRuntime.readStore', e, stack);
          return null;
        }
      },
      readMedia: () async {
        try {
          return await ref.read(srsMediaStoreProvider.future);
        } catch (e, stack) {
          ErrorLogService.instance.log('SrsAppRuntime.readMedia', e, stack);
          return null;
        }
      },
      engine: () => ref.read(srsEngineProvider),
      bumpRevision: () => ref.read(srsRevisionProvider.notifier).state++,
      bumpPulledRevision: () =>
          revisionOrigin.bumpPulled(ref.read(srsRevisionProvider.notifier)),
      // 同步前的 profile 关联（铁律 E）：采用目录里已有的 uid 后按新身份重开 store。
      profileLinker: SrsDbProfileLinker(
        db: app.database,
        activeProfileId: () async {
          final int id = ref.read(profileViewModelProvider).activeProfileId;
          return id > 0 ? id : app.database.resolveActiveProfileId();
        },
        reopenStore: () async {
          ref.invalidate(srsStoreProvider);
          return ref.read(srsStoreProvider.future);
        },
        onError: ErrorLogService.instance.log,
      ),
    );
    // 本机写了复习数据：去抖后经互联快速通道推一轮（设计 §6.3）。同步拉进来的变更不触发
    // （反馈 I1Bg6uMZ32：拉入 → 修订号 +1 → 又推一轮同步，见 [SrsRevisionOrigin]）。
    listenSrsLocalWrites(ref, revisionOrigin, runtime.localPush.trigger);
    // 复习页的评分 / 撤销等只发这个信号（不叫醒被盖住的列表，见 srsLocalWriteProvider）。
    ref.listen<int>(
      srsLocalWriteProvider,
      (int? previous, int next) => runtime.localPush.trigger(),
    );
    // RWKV 排程服务随模块常驻（store.rwkv 由它装配；对象很轻，重活按需启动）。
    ref.listen<AsyncValue<Object?>>(
      srsRwkvServiceProvider,
      (AsyncValue<Object?>? previous, AsyncValue<Object?> next) {},
      fireImmediately: true,
    );
    runtime.install();
    ref.onDispose(runtime.dispose);
    return runtime;
  },
);

/// 把 [srsAppRuntimeProvider] 挂到根容器上保活（main.dart 在 initialise 之后调一次）。
void installSrsAppRuntime(ProviderContainer container) {
  container.listen<SrsAppRuntime?>(
    srsAppRuntimeProvider,
    (SrsAppRuntime? previous, SrsAppRuntime? next) {},
    fireImmediately: true,
  );
}

class SrsAppRuntime {
  SrsAppRuntime({
    required this.app,
    required Future<SrsDbStore?> Function() readStore,
    required Future<SrsMediaStore?> Function() readMedia,
    required FsrsEngine? Function() engine,
    required void Function() bumpRevision,
    required void Function() bumpPulledRevision,
    SrsProfileLinker? profileLinker,
  }) : _profileLinker = profileLinker,
       _readStore = readStore,
       _readMedia = readMedia,
       _engine = engine,
       _bumpRevision = bumpRevision,
       _bumpPulledRevision = bumpPulledRevision;

  final AppModel app;
  final Future<SrsDbStore?> Function() _readStore;
  final Future<SrsMediaStore?> Function() _readMedia;
  final FsrsEngine? Function() _engine;

  /// 本机写入（自动优化应用了新参数）：界面重读 + 推给别的设备。
  final void Function() _bumpRevision;

  /// 同步拉进了别的设备的变更：界面重读，不再推送（[SrsRevisionOrigin]）。
  final void Function() _bumpPulledRevision;
  final SrsProfileLinker? _profileLinker;

  late final SrsSyncScheduler sync = SrsSyncScheduler(
    readStore: _readStore,
    channels: (Future<void> Function(SyncAssetStore backend) body) =>
        runOnAuthenticatedSyncChannels(
          db: app.database,
          body: (SyncBackend backend) => body(backend),
        ),
    directoryKeyOf: (SyncAssetStore backend) =>
        srsDirectoryKeyOf(backend, SyncRepository(app.database)),
    localDirectories: _localDirectories,
    folderLocations: () async => app.srsFolderLocations,
    profileLinker: _profileLinker,
    onDataChanged: _bumpPulledRevision,
    onNotice: _showSyncNotice,
    readMediaRoot: () async => (await _readMedia())?.root,
    // 库关着（备份恢复 / 数据根迁移 / 退出）时不开新一轮；重开后自动恢复。
    canRun: () => app.isInitialised,
    // 首次 v2 同步要用户确认一次（复习页弹窗，见 ensureSrsFirstSyncConfirmed）。
    firstSyncConfirmed: () => app.srsSync2MergeConfirmed,
    // 本机作为 host 发布了新数据：唤醒连着它的设备（长轮询 /api/srs/changes）。
    onLocalDirectoryPublished: app.syncServerController.notifySrsChanged,
    // 每个位置的端到端加密密钥（设备本地凭据；同步与历史页里开 / 输入口令）。
    locationKey: (String id) => app.srsLocationKeys[id],
    onEncryptionEnabled: app.setSrsLocationKey,
    // 设置 › 同步「自动同步复习数据」（反馈 VNz9dsLeIy）：关掉后只剩手动同步与进复习页的节流同步。
    autoSyncEnabled: () => SyncRepository(app.database).isSrsAutoSyncEnabled(),
  );

  /// 互联快速通道（srs_interconnect_watch.dart）：长轮询所连 host，有新数据立刻同步这一条通道。
  late final SrsInterconnectWatcher interconnectWatch = SrsInterconnectWatcher(
    // 快速通道是自动同步：开关关着时不挂长轮询（watcher 空闲重查时会再问，打开后自动恢复）。
    ready: () async =>
        await _interconnectReady() && await sync.isAutoSyncEnabled(),
    wait: InterconnectSyncBackend.instance.waitSrsChanges,
    onChange: () async {
      await sync.autoSyncWithBackend(InterconnectSyncBackend.instance);
    },
  );

  /// 本机变动后去抖推送：连着互联 host 就同步那条通道；本机自己是 host 就跑本机目录（唤醒连它的设备）。
  late final SrsLocalPush localPush = SrsLocalPush(push: _pushInterconnect);

  Future<bool> _interconnectReady() async {
    if (!app.isInitialised || !app.srsSync2MergeConfirmed) return false;
    final AppLifecycleState? state = WidgetsBinding.instance.lifecycleState;
    if (state != null && state != AppLifecycleState.resumed) return false;
    final SyncRepository repo = SyncRepository(app.database);
    if (!await repo.isInterconnectEnabled()) return false;
    final InterconnectSyncBackend backend = InterconnectSyncBackend.instance;
    await backend.restoreAuth(repo);
    return backend.isAuthenticated;
  }

  Future<void> _pushInterconnect() async {
    try {
      await sync.autoPush(
        () async => await _interconnectReady()
            ? InterconnectSyncBackend.instance
            : null,
      );
    } catch (e, stack) {
      ErrorLogService.instance.log('SrsAppRuntime.pushInterconnect', e, stack);
    }
  }

  /// 关库前等 SRS 同步收尾（登记到 [AppModel.addDatabaseCloseQuiescer]）。
  late final Future<void> Function() _quiesceSync = sync.quiesce;

  late final SrsOptimizationScheduler optimizer = SrsOptimizationScheduler(
    readStore: _readStore,
    engine: _engine,
    jobFactory: () {
      final FsrsEngine? e = _engine();
      return SrsIsolateOptimizationJob(
        libraryPath: e is FfiFsrsEngine ? e.library.libraryPath : null,
      );
    },
    canRunNow: _idleForOptimization,
    onApplied: _bumpRevision,
  );

  AppLifecycleListener? _lifecycle;
  bool _installed = false;
  SrsAnkiConnectEndpoint? _endpoint;

  /// 装进常规同步的通道后置步骤（卸下时按身份核对，不误卸别人装的）。
  late final SyncChannelPostRunHook _postRunHook = _postRun;

  Future<void> _postRun(SyncBackend backend) async {
    await sync.autoSyncWithBackend(backend);
  }

  /// 本机开着互联服务时，客户端经互联写进来的同步目录（host 自己不是任何一条通道的客户端，
  /// 不在这里同步，它的复习数据就到不了连它的设备、也读不到它们的）。目录身份与客户端看到的
  /// hostId 相同（host 的 hostId 就是本机设备 id）。
  Future<List<SrsLocalDirectory>> _localDirectories() async {
    final Directory? root = app.syncServerController.clientSyncRoot;
    if (root == null) return const <SrsLocalDirectory>[];
    final String hostId = await SyncRepository(
      app.database,
    ).getOrCreateDeviceId();
    return <SrsLocalDirectory>[
      SrsLocalDirectory(
        directoryKey: srsInterconnectDirectoryKey(hostId),
        store: LocalDirectoryAssetStore(root),
      ),
    ];
  }

  StreamSubscription<String>? _hostWrites;

  /// 已配对设备往本机 host 的 SRS 目录写了文件（只看 SRS 命名空间，书 / 视频等同步不触发）。
  void _onHostClientWrite(String relativePath) {
    if (srsIsHostSrsPath(relativePath)) sync.notifyLocalDirectoryWritten();
  }

  /// AnkiConnect 兼容端点的本实例 id（防自环）。
  final String instanceId = srsAnkiConnectNewInstanceId();

  void install() {
    if (_installed) return;
    _installed = true;
    NavigatorState? navigator() => app.navigatorKey.currentState;
    SrsAppHost.current = SrsAppHost(
      readStore: _readStore,
      openNote: (String noteId) => srsPushNoteEditor(navigator(), noteId),
      openBrowse: () => srsPushBrowse(navigator()),
    );
    fushiAnkiConnectCompatInstanceId = instanceId;
    final SrsAnkiConnectEndpoint endpoint = buildAnkiConnectEndpoint();
    _endpoint = endpoint;
    app.srsAnkiConnectEndpoint = endpoint;
    syncChannelPostRunHook = _postRunHook;
    homeShellTabNotifier.addListener(_onHomeTabChanged);
    srsActiveReviewSessions.addListener(_onReviewSessionsChanged);
    _lifecycle = AppLifecycleListener(onStateChange: _onLifecycle);
    optimizer.start();
    app.addDatabaseCloseQuiescer(_quiesceSync);
    _hostWrites = app.syncServerController.clientSyncWrites.listen(
      _onHostClientWrite,
    );
    interconnectWatch.start();
    // 旧版定时备份已由同步 v2 的时间线 / 归档 / 手动导出取代：本机旧备份文件（仍可经「导入」恢复）从升级后
    // 第一次看到起留 30 天再清（起算时刻持久化在目录里的标记文件，见 srs_legacy_backup_cleanup.dart）。
    unawaited(
      srsCleanupLegacyBackups().catchError((Object e, StackTrace stack) {
        ErrorLogService.instance.log('srsCleanupLegacyBackups', e, stack);
        return 0;
      }),
    );
  }

  void dispose() {
    if (!_installed) return;
    _installed = false;
    homeShellTabNotifier.removeListener(_onHomeTabChanged);
    srsActiveReviewSessions.removeListener(_onReviewSessionsChanged);
    _lifecycle?.dispose();
    _lifecycle = null;
    optimizer.dispose();
    app.removeDatabaseCloseQuiescer(_quiesceSync);
    unawaited(_hostWrites?.cancel());
    _hostWrites = null;
    interconnectWatch.stop();
    localPush.dispose();
    sync.dispose();
    if (identical(syncChannelPostRunHook, _postRunHook)) {
      syncChannelPostRunHook = null;
    }
    if (identical(app.srsAnkiConnectEndpoint, _endpoint)) {
      app.srsAnkiConnectEndpoint = null;
    }
    _endpoint = null;
    if (fushiAnkiConnectCompatInstanceId == instanceId) {
      fushiAnkiConnectCompatInstanceId = null;
    }
    SrsAppHost.current = null;
  }

  /// AnkiConnect v6 兼容端点（Fushi API 根路径）。API key 与 Fushi API 同一个偏好。
  SrsAnkiConnectEndpoint buildAnkiConnectEndpoint() {
    NavigatorState? navigator() => app.navigatorKey.currentState;
    return SrsAnkiConnectEndpoint(
      handler: SrsAnkiConnectHandler(
        store: () async {
          final SrsDbStore? store = await _readStore();
          if (store == null) throw StateError('Fushi review is not available');
          return store;
        },
        instanceId: instanceId,
        apiKey: () {
          final String key = app.fushiApiKey;
          return key.isEmpty ? null : key;
        },
        onSync: () => unawaited(
          sync.syncNow().catchError((Object e, StackTrace stack) {
            ErrorLogService.instance.log('SrsAnkiConnect.sync', e, stack);
            return const SrsSyncNowResult(ran: 0);
          }),
        ),
        onGuiBrowse: (String? query, List<String> cardIds) async {
          await srsPushBrowse(navigator(), query: query);
        },
        onGuiEditNote: (String noteId) async {
          await srsPushNoteEditor(navigator(), noteId);
        },
        mediaSink: (String filename, Uint8List bytes) async {
          final SrsMediaStore? media = await _readMedia();
          if (media == null) throw StateError('Fushi review is not available');
          return media.store(filename, bytes);
        },
      ),
    );
  }

  /// 牌组列表「立即同步」：对所有已认证通道跑一轮（结果区分没配置 / 失败 / 成功）。
  Future<SrsSyncNowResult> syncNow() => sync.syncNow();

  void _onHomeTabChanged() {
    if (homeShellTabNotifier.value != HomeTab.srs) return;
    unawaited(
      sync.syncThrottled().catchError((Object e, StackTrace stack) {
        ErrorLogService.instance.log('SrsAppRuntime.tabSync', e, stack);
        return false;
      }),
    );
  }

  void _onReviewSessionsChanged() {
    final int now = srsActiveReviewSessions.value;
    if (now > 0) optimizer.cancel();
  }

  void _onLifecycle(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) optimizer.cancel();
    // 回到前台：快速通道马上重新挂上（不等空闲重查的间隔）。
    if (state == AppLifecycleState.resumed) interconnectWatch.nudge();
  }

  /// 自动优化的空闲判据：app 在前台、不在复习页。
  bool _idleForOptimization() {
    if (srsActiveReviewSessions.value > 0) return false;
    final AppLifecycleState? state = WidgetsBinding.instance.lifecycleState;
    return state == null || state == AppLifecycleState.resumed;
  }

  void _showSyncNotice(SrsSyncNotice notice) {
    FushiToast.show(
      msg: switch (notice) {
        SrsSyncNotice.backendUnsupported => t.srs_sync_backend_unsupported,
        SrsSyncNotice.clockSkew => t.srs_sync_clock_skew,
        SrsSyncNotice.profileNotLinked => t.srs_sync_profile_not_linked(
          name: sync.lastUnlinkedProfile ?? '',
        ),
        SrsSyncNotice.awaitingConfirm => t.srs_sync_awaiting_confirm,
      },
      severity: ToastSeverity.warning,
    );
  }
}
