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
import 'package:fushi_engine/srs/sync2/srs_host_directory.dart';
import 'package:fushi_engine/srs/ankiconnect/srs_ankiconnect_endpoint.dart';
import 'package:fushi_engine/srs/ankiconnect/srs_ankiconnect_handler.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_engine/srs/srs_profile_link.dart';
import 'package:fushi_engine/srs/sync2/srs_sync2_round.dart'
    show SrsSync2Report;
import 'package:fushi_engine/sync/local_directory_asset_store.dart';
import 'package:fushi_engine/sync/sync_asset_store.dart';
import 'package:fushi_srs/fushi_srs.dart';

import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/models/home_tab.dart';
import 'package:fushi/src/pages/implementations/srs/srs_sync_settings.dart'
    show
        SrsProfileConflictAdopt,
        SrsProfileConflictChoice,
        SrsProfileConflictKeepSeparate,
        showSrsProfileConflictDialog;
import 'package:fushi/src/profile/profile_view_model.dart';
import 'package:fushi/src/srs/srs_app_host.dart';
import 'package:fushi/src/srs/srs_legacy_backup_cleanup.dart';
import 'package:fushi/src/srs/srs_directory_key.dart';
import 'package:fushi/src/srs/srs_interconnect_watch.dart';
import 'package:fushi_engine/srs/srs_remote_store.dart';
import 'package:fushi_engine/srs/srs_media_store.dart';
import 'package:fushi_engine/srs/srs_optimization_scheduler.dart';
import 'package:fushi/src/srs/srs_providers.dart';
import 'package:fushi/src/srs/srs_sync_scheduler.dart';
import 'package:fushi/src/sync/interconnect_sync_backend.dart';
import 'package:fushi/src/sync/sync_auto_trigger.dart';
import 'package:fushi/src/sync/sync_backend.dart';
import 'package:fushi/src/sync/sync_repository.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/utils/misc/error_log_service.dart';
import 'package:fushi/src/utils/misc/fushi_toast.dart';
import 'package:fushi_engine/srs/srs_op_ledger.dart';

/// 读当前 profile 正在暂缓的并入（[SrsSyncScheduler.deferredProfileMerge]，状态由引擎的 linker 持有）；模块关着 /
/// 没有暂缓时得 null。同步状态页每次重读状态时调。单独一个 provider 是让页面测试能注入（运行时整套不在页面测试范围）。
final Provider<Future<SrsDeferredProfileMerge?> Function()>
srsDeferredProfileMergeReaderProvider =
    Provider<Future<SrsDeferredProfileMerge?> Function()>(
      (Ref ref) =>
          () async =>
              ref.read(srsAppRuntimeProvider)?.sync.deferredProfileMerge(),
    );

/// 模块开着时的常驻装配（见文件头）；关着时为 null。
final Provider<SrsAppRuntime?>
srsAppRuntimeProvider = Provider<SrsAppRuntime?>((Ref ref) {
  if (!ref.watch(srsModuleEnabledProvider)) return null;
  final AppModel app = ref.read(appProvider);
  final SrsRevisionOrigin revisionOrigin = SrsRevisionOrigin();
  late final SrsAppRuntime runtime;
  runtime = SrsAppRuntime(
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
    bumpPulledRevision: () {
      revisionOrigin.bumpPulled(ref.read(srsRevisionProvider.notifier));
      // BUG-4075 取证：修订号「同步拉入」的一跳（本机写入的一跳在下面 listenSrsLocalWrites 里记）。
      SrsOpLedger.mark('rev:pulled');
      // 别的设备可能改了复习翻日时刻：本机统计日界跟上（单向，不写回复习）。
      unawaited(runtime.adoptSyncedDayRollover());
    },
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
      mediaRoot: () async =>
          SrsMediaStore.mediaRootFor(await ref.read(srsSupportRootProvider)()),
      onError: ErrorLogService.instance.log,
      // 并入之前先把目标 uid 已有的数据收进来（BUG-4011：合并沿用目标里已有的写入者，不再改名造出第二份）。
      // 等多久、从哪收都在调度器里定（[SrsSyncScheduler.pullBeforeMerge]：按进度判，只从正在跑的那条通道和本机
      // 目录 / 文件夹位置收）。
      pullBeforeMerge: (SrsDbStore target, SyncAssetStore? within) =>
          runtime.sync.pullBeforeMerge(target, within),
    ),
  );
  // 旧库迁移推迟到首次同步确认之后（BUG-4011）：store 打开时不迁移（srs_providers.dart `deferMigration`），
  // 由调度器在确认后的第一轮上传之前先收一轮再迁移（[SrsSyncScheduler.ensureMigrated]）。
  // 本机写了复习数据：去抖后经互联与云盘通道各推一轮（设计 §6.3，反馈 O4MSorhpie）。同步拉进来的变更不触发
  // （反馈 I1Bg6uMZ32：拉入 → 修订号 +1 → 又推一轮同步，见 [SrsRevisionOrigin]）。
  // BUG-4075 取证：修订号每跳一次按来源记一笔（`rev:local` 本机写入 / `rev:pulled` 同步拉入，后者在
  // bumpPulledRevision 里记）：停在复习页不动时它跳不跳、跳多少次、是谁在跳，直接看内存采样里的 marks。
  // 不另挂直接 listen 修订号的监听：那样分不出来源（srs_revision_origin_test 接线守卫）。
  listenSrsLocalWrites(ref, revisionOrigin, () {
    SrsOpLedger.mark('rev:local');
    runtime.notifyLocalWrite();
  });
  // 复习页的评分 / 撤销等只发这个信号（不叫醒被盖住的列表，见 srsLocalWriteProvider）。
  ref.listen<int>(
    srsLocalWriteProvider,
    (int? previous, int next) => runtime.notifyLocalWrite(),
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
});

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

  /// 同步拉入之后：生效的翻日时刻是本机没见过的修改（别的设备的用户改了日界）就让本机统计日界跟上；还是本机
  /// 写下 / 采纳过的那条就不动（[AppModel.adoptSyncedDayRollover]）。复习自己的「今天」不靠这一步，
  /// `SrsDbStore.dayContext` 直接读字段。
  Future<void> adoptSyncedDayRollover() async {
    try {
      final SrsDbStore? store = await _readStore();
      if (store == null) return;
      await app.adoptSyncedDayRollover(
        store.profileUid,
        store.syncedDayRollover,
      );
    } catch (e, stack) {
      ErrorLogService.instance.log(
        'SrsAppRuntime.adoptSyncedDayRollover',
        e,
        stack,
      );
    }
  }

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
    // 同步与历史页「存储位置」上逐个关掉的通道位置（只停复习同步，通道本身照常）。
    locationDisabled: (String id) => app.srsDisabledLocations.contains(id),
    // 一轮跑完问通道那头的设备（互联 host）加入复习同步了没有（BUG-4320）：没加入时摘要 / 立即同步不说「已同步」。
    peerJoined: srsChannelPeerJoined,
  );

  /// 互联快速通道（srs_interconnect_watch.dart）：长轮询所连 host，有新数据立刻同步这一条通道。
  ///
  /// 与常规同步的互斥（反馈 XDV7Mzc2gw）：`ready`（`restoreAuth` 改单例后端的凭据 / 会话）与 `onChange` 的一轮
  /// 都在 [runExclusiveWithSync] 里跑，和常规同步、推送串行。长轮询请求本身**不**拿锁：它一挂就是 25 s，拿锁
  /// 会把常规同步挡住；它只读已解析好的会话发一个独立请求、不改共享状态（会话在锁里的 `ready` 之后才可能被
  /// 常规同步换掉，换掉时这条请求失败，走 watcher 自己的退避重连）。
  late final SrsInterconnectWatcher interconnectWatch = SrsInterconnectWatcher(
    // 快速通道是自动同步：开关关着时不挂长轮询（watcher 空闲重查时会再问，打开后自动恢复）。
    ready: () => runExclusiveWithSync(
      () async => await _interconnectReady() && await sync.isAutoSyncEnabled(),
    ),
    wait: InterconnectSyncBackend.instance.waitSrsChanges,
    onChange: () => runExclusiveWithSync(() async {
      await sync.autoSyncWithBackend(InterconnectSyncBackend.instance);
    }),
    // host 重新可达：推送不必再等退避期满。
    onReachable: () => localPush.resetBackoff(),
  );

  /// 本机变动后去抖推送（设计 §6.3），按通道分两条、各自一个 [SrsLocalPush]（反馈 O4MSorhpie：以前只推互联，云盘
  /// 通道要等进复习 tab / 常规同步 / 「立即同步」才带上答卡记录）：
  /// - [localPush]：互联通道 + 本机目录（本机自己是 host 时唤醒连它的设备）；
  /// - [cloudPush]：云盘通道（OneDrive / WebDAV / Google Drive 等，`enabledSyncChannelBackends` 里非互联的那条）。
  /// 两条各自失败退避（[SrsLocalPush]）：host 不可达时互联那条退避，不拖住云盘那条；反之亦然。
  /// 复习页开着时按最长等待批量推（[kSrsLocalPushMaxWait]，审查 S-8），离开复习页 / 进后台立即推。
  late final SrsLocalPush localPush = SrsLocalPush(
    push: () => _push(interconnect: true),
    batching: _reviewing,
  );

  /// 云盘通道那条推送（见 [localPush]）。
  late final SrsLocalPush cloudPush = SrsLocalPush(
    push: () => _push(interconnect: false),
    batching: _reviewing,
  );

  static bool _reviewing() => srsActiveReviewSessions.value > 0;

  /// 两条推送的名字（限流日志 / [SrsSyncScheduler.autoPushSkipReason]）。
  static const String kInterconnectPushLane = 'interconnect';
  static const String kCloudPushLane = 'cloud';

  /// 本机写了复习数据：两条推送都排上。
  void notifyLocalWrite() {
    localPush.trigger();
    cloudPush.trigger();
  }

  /// 下一次推送是 app 正要进后台时的那一次（[_onLifecycle]）：放过前台检查，每条推送只这一次。
  bool _interconnectPushOnLeave = false;
  bool _cloudPushOnLeave = false;

  /// 此刻能不能为复习同步联网：库开着、首次同步已确认、app 在前台（或 [allowBackground]：进后台时的那一次推送）。
  bool _syncAllowedNow({bool allowBackground = false}) {
    if (!app.isInitialised || !app.srsSync2MergeConfirmed) return false;
    final AppLifecycleState? state = WidgetsBinding.instance.lifecycleState;
    return allowBackground ||
        state == null ||
        state == AppLifecycleState.resumed;
  }

  Future<bool> _interconnectReady() async {
    if (!_syncAllowedNow()) return false;
    final SyncRepository repo = SyncRepository(app.database);
    if (!await repo.isInterconnectEnabled()) return false;
    final InterconnectSyncBackend backend = InterconnectSyncBackend.instance;
    await backend.restoreAuth(repo);
    return backend.isAuthenticated;
  }

  /// 一条推送：[interconnect] 选互联那组通道（+ 本机目录）还是云盘那组。通道的启用 / 认证由
  /// `runOnAuthenticatedSyncChannels` 逐条判（与「立即同步」同一套），它也拿常规同步的互斥（反馈 XDV7Mzc2gw）。
  /// 返回这条推送是否推成（[SrsLocalPush] 的退避依据）；失败照常记日志。
  Future<bool> _push({required bool interconnect}) async {
    final bool leaving = interconnect
        ? _interconnectPushOnLeave
        : _cloudPushOnLeave;
    if (interconnect) {
      _interconnectPushOnLeave = false;
    } else {
      _cloudPushOnLeave = false;
    }
    try {
      return await sync.autoPush(
        (Future<void> Function(SyncAssetStore backend) body) =>
            runOnAuthenticatedSyncChannels(
              db: app.database,
              where: (SyncChannel c) => c.isInterconnect == interconnect,
              body: (SyncBackend backend) => body(backend),
            ),
        lane: interconnect ? kInterconnectPushLane : kCloudPushLane,
        ready: () async => _syncAllowedNow(allowBackground: leaving),
        localDirectories: interconnect,
      );
    } catch (e, stack) {
      ErrorLogService.instance.log(
        'SrsAppRuntime.push(${interconnect ? kInterconnectPushLane : kCloudPushLane})',
        e,
        stack,
      );
      return false;
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
    final SrsSync2Report? r = await sync.autoSyncWithBackend(backend);
    // 常规同步经这条通道跑通了一轮：它可达，这条通道的推送不必再等退避期满。
    if (r != null && r.error == null) {
      (backend is InterconnectSyncBackend ? localPush : cloudPush)
          .resetBackoff();
    }
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
  StreamSubscription<({String path, String peerName})>? _hostUploads;

  /// 本进程里已交给内核的补充名（设备 → 名字），每个段一次 PUT，不必每次都过 FFI。
  final Map<String, String> _hintedDevices = <String, String>{};

  /// 已配对对端直接写了某台设备自己的段：用对端名给这台设备补名字（老版本没有自报名字时同步页 / 冲突中心显示它）。
  void _onHostClientUpload(({String path, String peerName}) u) {
    final String? device = srsHostUploadedSegmentDevice(u.path);
    if (device == null || _hintedDevices[device] == u.peerName) return;
    _hintedDevices[device] = u.peerName;
    unawaited(() async {
      try {
        await (await _readStore())?.sync2DeviceHint(device, u.peerName);
      } catch (e, stack) {
        _hintedDevices.remove(device);
        ErrorLogService.instance.log('SrsAppRuntime.deviceHint', e, stack);
      }
    }());
  }

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
      remoteStore: SrsRemoteStoreService(
        readStore: _readStore,
        readMedia: (String name) async => (await _readMedia())?.load(name),
        // 已配对设备的远程写入与本机写入一样：本机界面重读，互联推送照常发出。
        onWrite: (String _) => _bumpRevision(),
      ),
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
    _hostUploads = app.syncServerController.clientUploads.listen(
      _onHostClientUpload,
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
    unawaited(_hostUploads?.cancel());
    _hostUploads = null;
    interconnectWatch.stop();
    localPush.dispose();
    cloudPush.dispose();
    sync.dispose();
    if (identical(syncChannelPostRunHook, _postRunHook)) {
      syncChannelPostRunHook = null;
    }
    if (identical(app.srsAnkiConnectEndpoint, _endpoint)) {
      app.srsAnkiConnectEndpoint = null;
    }
    if (_endpoint case final SrsAnkiConnectEndpoint endpoint) {
      unawaited(
        endpoint.handler.close().catchError((Object e, StackTrace stack) {
          ErrorLogService.instance.log('SrsAnkiConnect.close', e, stack);
        }),
      );
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
          syncNow().catchError((Object e, StackTrace stack) {
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
  /// 用户手动同步也清掉推送的失败退避（用户明说「现在就同步」）。
  ///
  /// 这一轮跑遍全部通道与本机目录，是两条推送的超集：此刻排着的推送由它带上、撤掉（[SrsLocalPush.takePending]，
  /// BUG-4382）。以前排着的推送在「已同步」提示之后去抖到期又各跑一轮空同步，同步状态行在提示后继续走。这一轮
  /// 没同步成功（有错 / 抛错）就把撤掉的推送排回去，本机改动照常等推送补上。
  Future<SrsSyncNowResult> syncNow() => srsSyncSupersedingPushes(
    <SrsLocalPush>[localPush, cloudPush],
    sync.syncNow,
    synced: (SrsSyncNowResult r) => r.errors.isEmpty,
  );

  void _onHomeTabChanged() {
    if (homeShellTabNotifier.value != HomeTab.srs) return;
    _maybeShowProfileConflict(tabEntry: true);
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
    // 离开复习页：复习中攒着的变动立即推（审查 S-8）。
    if (now == 0) {
      localPush.flush();
      cloudPush.flush();
    }
  }

  void _onLifecycle(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) optimizer.cancel();
    // 正在进后台：待推的立即推（之后前台检查会挡住推送，后台也可能很快被挂起）。
    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.hidden) {
      if (localPush.pending) {
        _interconnectPushOnLeave = true;
        localPush.flush();
      }
      if (cloudPush.pending) {
        _cloudPushOnLeave = true;
        cloudPush.flush();
      }
    }
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
    final String msg;
    switch (notice) {
      case SrsSyncNotice.profileNotLinked:
        // 冲突要用户拿主意，不是一闪而过的 toast：进复习页时弹窗（见 [_maybeShowProfileConflict]）。
        _pendingConflict = sync.profileConflict;
        _maybeShowProfileConflict();
        return;
      case SrsSyncNotice.backendUnsupported:
        msg = t.srs_sync_backend_unsupported;
      case SrsSyncNotice.clockSkew:
        msg = t.srs_sync_clock_skew;
      case SrsSyncNotice.awaitingConfirm:
        msg = t.srs_sync_awaiting_confirm;
    }
    FushiToast.show(msg: msg, severity: ToastSeverity.warning);
  }

  /// 偏好：用户选了「保持分开」的 profile 冲突（[SrsProfileConflict.ignoreKey] 列表）。
  static const String kIgnoredProfileConflictsPrefKey =
      'srs_sync_ignored_profile_conflicts';

  /// 检出、还没给用户看（或用户选了「稍后」）的 profile 冲突。
  SrsProfileConflict? _pendingConflict;

  /// 用户选了「稍后」的那个冲突（[SrsProfileConflict.ignoreKey]）：重判出同一个冲突时不当场再弹，等下次进复习页。
  String? _deferredConflictKey;
  bool _conflictDialogOpen = false;

  /// 冲突弹窗选定候选后的提示：做完了说已关联；并入暂缓（[SrsProfileAdoptDeferred]）不是失败，说已排队、等撤销
  /// 记录同步到后自动完成（同步状态页同时显示暂缓状态）。真正的失败由调用方按错误提示。
  static void _showProfileAdoptResult(SrsProfileAdoptResult result) {
    switch (result) {
      case SrsProfileAdopted():
        FushiToast.show(msg: t.srs_sync_profile_conflict_done);
      case SrsProfileAdoptDeferred():
        FushiToast.show(
          msg: t.srs_sync_profile_merge_queued,
          severity: ToastSeverity.info,
          toastLength: Toast.LENGTH_LONG,
        );
    }
  }

  List<String> _ignoredConflicts() {
    if (!app.isPreferencesReady) return const <String>[];
    final Object? raw = app.prefsRepo.getPref(kIgnoredProfileConflictsPrefKey);
    return raw is List
        ? <String>[for (final Object? x in raw) '$x']
        : const <String>[];
  }

  /// 有待处理的冲突、用户此刻在复习页（在用复习时才打扰）、没被忽略过：弹窗。[tabEntry] = 用户刚进复习页：
  /// 「稍后」过的冲突只在这时再问，同步后台重判出来时不当场再弹。
  ///
  /// [_pendingConflict] 是检出那一刻的快照：之后另一台设备可能已经解决了它（采用了本机的 profile），笔记数也会变。
  /// 弹窗之前按同步位置的现状重判（[SrsSyncScheduler.recheckProfileConflict]），只问此刻仍成立的冲突、报现在的数。
  void _maybeShowProfileConflict({bool tabEntry = false}) {
    final SrsProfileConflict? pending = _pendingConflict;
    if (pending == null || _conflictDialogOpen) return;
    if (_ignoredConflicts().contains(pending.ignoreKey)) {
      _pendingConflict = null;
      return;
    }
    if (homeShellTabNotifier.value != HomeTab.srs) return;
    if (!tabEntry && pending.ignoreKey == _deferredConflictKey) return;
    if (app.navigatorKey.currentContext == null) return;
    _pendingConflict = null;
    _conflictDialogOpen = true;
    bool askAgain = false;
    unawaited(() async {
      try {
        final SrsProfileConflict? conflict = await sync.recheckProfileConflict(
          pending,
        );
        // 已经不成立（另一边解决了）、本机切了 profile 或位置此刻连不上：不问；之后判出来会重新通知。
        if (conflict == null) return;
        if (_ignoredConflicts().contains(conflict.ignoreKey)) return;
        final BuildContext? context = app.navigatorKey.currentContext;
        if (homeShellTabNotifier.value != HomeTab.srs ||
            context == null ||
            !context.mounted) {
          _pendingConflict ??= conflict;
          return;
        }
        final SrsProfileConflictChoice? choice =
            await showSrsProfileConflictDialog(context, conflict);
        switch (choice) {
          case null:
            // 稍后：留着，下次进复习页再问（期间重判出新的冲突以新的为准）。
            _pendingConflict ??= conflict;
            _deferredConflictKey = conflict.ignoreKey;
            return;
          case SrsProfileConflictKeepSeparate():
            if (!app.isPreferencesReady) return;
            await app.prefsRepo.setPref(
              kIgnoredProfileConflictsPrefKey,
              <String>[..._ignoredConflicts(), conflict.ignoreKey],
            );
          case SrsProfileConflictAdopt(:final String uid):
            try {
              await sync.adoptProfile(
                conflict,
                uid,
                onAdopted: _showProfileAdoptResult,
              );
            } on SrsProfileConflictStale catch (e) {
              // 弹窗开着的时候冲突变了：什么都没动。已经解决就告诉用户；换了候选就按新的再问一次。
              final SrsProfileConflict? current = e.current;
              if (current == null) {
                FushiToast.show(msg: t.srs_sync_profile_conflict_resolved);
              } else {
                _pendingConflict = current;
                askAgain = true;
              }
            } catch (e, stack) {
              ErrorLogService.instance.log(
                'SrsAppRuntime.adoptProfile',
                e,
                stack,
              );
              FushiToast.show(
                msg: t.srs_sync_profile_conflict_failed,
                severity: ToastSeverity.error,
              );
            }
        }
      } catch (e, stack) {
        ErrorLogService.instance.log('SrsAppRuntime.profileConflict', e, stack);
      } finally {
        _conflictDialogOpen = false;
        if (askAgain) _maybeShowProfileConflict(tabEntry: true);
      }
    }());
  }
}
