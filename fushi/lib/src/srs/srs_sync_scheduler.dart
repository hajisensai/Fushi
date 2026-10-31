/// 复习（SRS）同步的调度：什么时候、用哪个后端跑一轮同步 v2（`srsSync2Round`，
/// docs/specs/2026-10-25-srs-sync-v2-design.md）。每条已认证的同步通道就是一个存储位置（同步 + 媒体用途，
/// 设计 §6.5 的「已登录过的网盘账号直接复用」），布局 `fushi-srs/<profileUid>/v3/`（旧根 `v2/` 只剩围栏，见 srs_location_migration.dart）。
///
/// 三个触发点，都只在复习模块开着时存在（由 `srs_app_runtime.dart` 装配）：
/// 1. 常规同步每条通道成功后（`syncChannelPostRunHook`，与常规同步同一把互斥锁、同一个
///    已认证后端，云盘与互联都算）；
/// 2. 进入复习 tab 时（节流：距上次至少 [kSrsSyncMinInterval]）；
/// 3. 牌组列表「立即同步」/ AnkiConnect `sync` 动作（不节流）。
/// 2、3 除各条通道外还跑本机直接读写的目录（[SrsLocalDirectory]：本机作为互联 host 时
/// 客户端写进来的那块目录——host 自己不是任何一条通道的客户端）。
/// 4. 本机作为互联 host、已配对设备往 SRS 目录写了文件（[notifyLocalDirectoryWritten]，去抖
///    [kSrsHostWriteDebounce]）：只跑本机目录。host 自己经本机文件系统读写这块目录，不走互联，
///    所以它的同步不会再触发自己；客户端也不因 host 同步而被触发——没有循环。
///
/// 自动同步开关（[SrsSyncScheduler.isAutoSyncEnabled]，设置 › 同步「自动同步复习数据」，反馈 VNz9dsLeIy）
/// 只管不由用户直接发起的那几处：1（[autoSyncWithBackend]，互联快速通道同走它）、4（[notifyLocalDirectoryWritten]）与本机写入后的
/// 推送（[autoPush]）；app 侧互联快速通道也读它。关掉后只剩 2、3：用户点了「立即同步」，或自己进了复习页。
///
/// 目录身份拿不到（云盘账户还没认出来）时这一轮跳过该后端（报告 error =
/// [kSrsSyncDirectoryIdentityUnavailable]），不把同一个目录当成新目录起步 / 重发。
///
/// 每条通道 / 目录各跑一轮引擎，进度按目录记（[SrsSyncEngine.directoryKey]，身份见
/// `srs_directory_key.dart`）：同一份本机数据同时经云盘与互联同步，每个目录都收到全部批次。
///
/// 每轮成功拿到服务器时间后 `store.anchorTime(...)`（铁律 F 第一层校时）；后端拿不到
/// 服务器时间（报告 error = `server time unavailable`）时提示一次「当前同步后端不支持
/// 复习数据同步」；可信时间与墙钟偏差超过 10 分钟时提示一次「系统时间不准」。
/// 没配置任何同步后端时什么都不做。
///
/// 每个目录跑引擎之前先做 profile 关联（[SrsProfileLinker]，铁律 E）：profileUid 是每台设备
/// 本机随机生成的，不关联的话两台设备各写各的 `fushi-srs/<profileUid>/`，互联 / 云盘「同步成功」
/// 而复习数据从不互通。跑完再在本机写入者目录里发布 profile 说明文件（必须在引擎之后：引擎靠
/// 「本机写入者目录不见了」判断自己被当作退役设备清理过，先建目录会把这个信号盖掉）。
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:fushi/src/diagnostics/previous_exit_log.dart';
import 'package:fushi/src/srs/srs_sync_progress.dart';
import 'package:fushi/src/sync/dropbox_sync_backend.dart';
import 'package:fushi/src/sync/obfuscating_sync_backend.dart';
import 'package:fushi/utils.dart' show ErrorLogService;
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_engine/srs/sync2/srs_folder_location.dart';
import 'package:fushi_engine/srs/sync2/srs_location_crypto.dart';
import 'package:fushi_engine/srs/sync2/srs_location_migration.dart';
import 'package:fushi_engine/srs/sync2/srs_location_store.dart';
import 'package:fushi_engine/srs/sync2/srs_sync2_round.dart';
import 'package:fushi_engine/srs/srs_media_sync.dart';
import 'package:fushi_engine/srs/srs_profile_link.dart';
import 'package:fushi_engine/sync/sync_asset_store.dart';

/// 两次「进入复习 tab」触发之间的最小间隔。
const Duration kSrsSyncMinInterval = Duration(seconds: 60);

/// 本轮既没收到远端操作、也没发出本机段时，媒体对账最多隔多久仍跑一次（补上次没下载成的文件）。
/// 有新操作的一轮（新笔记引用了新媒体 / 别的设备传来了笔记）照常立刻对账。
const Duration kSrsMediaReconcileInterval = Duration(minutes: 30);

/// 「两边都有笔记、无法自动关联」的判定结果复用多久（判定要把同步目录里全部 profile 列一遍、逐个下载说明文件）。
const Duration kSrsProfileConflictRecheck = Duration(minutes: 30);

/// 可信时间与系统时钟的偏差超过它就提示一次。
const int kSrsClockSkewWarnMs = 10 * 60 * 1000;

/// 后端拿不到服务器时间时的错误串（v2 不依赖服务器时间同步，保留给只想校时的调用方识别）。
const String kSrsSyncServerTimeUnavailable = 'server time unavailable';

/// 位置上的数据来自更新版本、本机读不了（设计 §8：停写并提示升级，不覆盖任何一方）。
const String kSrsSyncNeedsUpgrade = 'srs sync data needs a newer app';

/// 后端所指同步目录的稳定身份暂时拿不到（例如云盘账户还没认出来）：这一轮不同步它。
const String kSrsSyncDirectoryIdentityUnavailable =
    'directory identity unavailable';

/// 本机的 SRS 副本此刻打不开（模块关着 / 还在打开 / 调度器已卸下）：这一轮没同步。
const String kSrsSyncStoreUnavailable = 'srs store unavailable';

/// 升级到同步 v2 后还没确认过首次同步（设计 §13 第 5 条：首次 v2 同步弹窗确认一次，说明「并入、不覆盖」）。
const String kSrsSyncAwaitingConfirm = 'srs first v2 sync not confirmed';

/// 只说明「本机此刻不该同步」、与网络 / 对端无关的报告错误：推送不为它们退避。
const Set<String> kSrsSyncLocalStateErrors = <String>{
  kSrsSyncStoreUnavailable,
  kSrsSyncAwaitingConfirm,
};

/// 复习同步一轮的活动面包屑名（[ActivityBreadcrumb]）。
const String kSrsSyncActivity = 'srs_sync';

/// [SrsSyncScheduler.syncWithBackend] 的轮次统计：排队数、在跑数、被合并的请求数、连续
/// 失败数与上次失败时刻。只用于诊断（面包屑 / 失败日志）。
class SrsSyncRoundStats {
  int queued = 0;
  int running = 0;
  int coalesced = 0;
  int consecutiveFailures = 0;
  DateTime? lastFailureAt;

  String describe() =>
      'queued=$queued running=$running coalesced=$coalesced '
      'consecutiveFailures=$consecutiveFailures';
}

/// 已配对设备往本机 host 的 SRS 目录写入后，等这么久没有新写入再跑一次本机目录。
/// 一轮客户端同步会连写探针 / 批次 / cursor 几个文件，去抖把它们并成一次。
const Duration kSrsHostWriteDebounce = Duration(seconds: 3);

/// 一次 SRS 同步（测试注入假实现）。[directoryKey] 是 [backend] 所指同步目录的稳定身份；[locationKey] = 本机为
/// 这个位置记的密钥（调度器一律传进来，注入的实现与生产实现走同一条加密路径）。
typedef SrsSyncRunner =
    Future<SrsSync2Report> Function(
      SyncAssetStore backend,
      SrsDbStore store,
      String directoryKey, {
      SrsLocationKey? locationKey,
    });

/// [backend] 上同时在途的写 / 删上限（[SrsAssetLocationStore.maxConcurrentWrites]）：Dropbox 同一命名空间的并发写会
/// 互相锁冲突（429 `too_many_write_operations`），逐个写；其余后端不限，由一轮同步的并发上限决定。
int? srsMaxConcurrentWritesOf(SyncAssetStore backend) {
  final SyncAssetStore inner = backend is ObfuscatingSyncBackend
      ? backend.inner
      : backend;
  return inner is DropboxSyncBackend ? 1 : null;
}

/// 本进程里已经确认旧集合根扫干净的位置（进程重启后的第一轮再扫一遍，接住围栏那一刻还在跑的旧版本晚到的写入）。
final SrsLocationMigrationMemo _srsMigrationMemo = SrsLocationMigrationMemo();

/// 生产实现：现有同步后端上的集合根（`fushi-srs/<profileUid>/v3/`）跑一轮同步 v2。先 [srsPrepareLocation]：立住
/// 旧根 `v2/` 上让旧版本停下的围栏，旧根上有协议 1 的数据就迁过来。[directoryKey] 就是这个位置的稳定身份（本机按
/// 它记每个位置传到了哪）。
Future<SrsSync2Report> srsDefaultSyncRunner(
  SyncAssetStore backend,
  SrsDbStore store,
  String directoryKey, {
  SrsLocationKey? locationKey,
  void Function(int done, int total)? onFetchProgress,
  void Function()? onUploadStart,
  Future<void> Function(String? keyHex)? beforeUpload,
  bool Function()? shouldStop,
}) async {
  final SrsLocationStore location = SrsAssetLocationStore(
    store: backend,
    profileUid: store.profileUid,
    maxConcurrentWrites: srsMaxConcurrentWritesOf(backend),
  );
  final SrsLocationStore v1 = SrsAssetLocationStore(
    store: backend,
    profileUid: store.profileUid,
    maxConcurrentWrites: srsMaxConcurrentWritesOf(backend),
    folder: kSrsSync2V1Folder,
  );
  final SrsV1Writers writers = SrsAssetV1Writers(backend, store.profileUid);
  final SrsLocationPrepared prepared = await srsPrepareLocation(
    host: store,
    v1: v1,
    current: location,
    locationId: directoryKey,
    key: locationKey,
    nowMs: () => store.now().$1,
    recordPresence: true,
    writers: writers,
    memo: _srsMigrationMemo,
  );
  if (prepared.needsUpgrade || prepared.error != null) {
    final SrsSync2Report r = SrsSync2Report()
      ..needsUpgrade = prepared.needsUpgrade
      ..error = prepared.needsUpgrade ? kSrsSyncNeedsUpgrade : prepared.error
      ..kdf = prepared.kdf;
    return r;
  }
  srsLogMigrationLeftover(prepared, directoryKey);
  final SrsSync2Report r = await srsSync2Round(
    host: store,
    location: location,
    locationId: directoryKey,
    nowMs: () => store.now().$1,
    wallClockMs: store.trustedClock.wallNowMs,
    key: locationKey,
    onFetchProgress: onFetchProgress,
    onUploadStart: onUploadStart,
    beforeUpload: beforeUpload,
    shouldStop: shouldStop,
  );
  if (r.needsUpgrade) r.error = kSrsSyncNeedsUpgrade;
  if (r.error == null) {
    // 按名字存的旧媒体：这一轮把补上的绑定发布到这个位置之后才删。
    await srsFinishLocationMigration(
      host: store,
      v1: v1,
      prepared: prepared,
      progressId: srsLocationProgressId(
        directoryKey,
        r.encrypted ? locationKey?.keyHex : null,
      ),
      writers: writers,
    );
    srsLogMigrationCleanup(prepared, directoryKey);
  }
  return r;
}

/// 旧根残留没处理成（读失败 / 解不开 / 新根口令问题）：不挡新根，但必须落日志（带原始栈），下一轮再试。
void srsLogMigrationLeftover(SrsLocationPrepared prepared, String locationId) {
  final String? leftover = prepared.leftoverError;
  if (leftover == null) return;
  ErrorLogService.instance.log(
    'srsPrepareLocation',
    StateError('srs v1 leftovers on $locationId: $leftover'),
    prepared.leftoverStack ?? StackTrace.current,
  );
}

/// 迁移收尾删旧文件时逐个出的错：那些文件留着下一轮再删，这一轮的同步照样算成功，但每个错都记日志。
void srsLogMigrationCleanup(SrsLocationPrepared prepared, String locationId) {
  for (final (Object e, StackTrace stack) in prepared.cleanupErrors) {
    ErrorLogService.instance.log(
      'srsFinishLocationMigration',
      StateError('srs v1 cleanup on $locationId: $e'),
      stack,
    );
  }
  prepared.cleanupErrors.clear();
}

/// 本机直接读写的同步目录：本机作为互联 host 时，别的设备经互联写进来的就是这块目录，
/// 本机自己的复习数据也要在这里发布、从这里读别人的（它不是任何一条同步通道）。
class SrsLocalDirectory {
  const SrsLocalDirectory({required this.directoryKey, required this.store});

  final String directoryKey;
  final SyncAssetStore store;
}

/// 一轮媒体同步（测试注入假实现）。[cipher] = 位置开了加密时的媒体封装（调度器一律传进来）；[locationId] = 位置的
/// 稳定身份（[SrsSyncEngine.directoryKey] 同一身份）：位置上有什么读日志投影，不每轮列媒体目录。
typedef SrsMediaSyncRunner =
    Future<SrsMediaSyncReport> Function(
      SyncAssetStore backend,
      SrsDbStore store,
      Directory mediaRoot, {
      SrsMediaCipher? cipher,
      required String locationId,
    });

/// 生产实现：见 packages/fushi_engine/lib/srs/srs_media_sync.dart。[uploadOnly] = 发段之前只传本机的媒体
/// （[srsSyncMedia]）。
Future<SrsMediaSyncReport> srsDefaultMediaSyncRunner(
  SyncAssetStore backend,
  SrsDbStore store,
  Directory mediaRoot, {
  SrsMediaCipher? cipher,
  required String locationId,
  bool uploadOnly = false,
}) => srsSyncMedia(
  cipher: cipher,
  locationId: locationId,
  uploadOnly: uploadOnly,
  location: SrsAssetLocationStore(
    store: backend,
    profileUid: store.profileUid,
    maxConcurrentWrites: srsMaxConcurrentWritesOf(backend),
  ),
  store: store,
  mediaRoot: mediaRoot,
);

/// 「对所有已认证通道跑一次」的入口（生产：`runOnAuthenticatedSyncChannels`）。
/// 返回跑成功的通道数与抛错通道的异常。
typedef SrsChannelRunner =
    Future<({int ran, List<Object> errors})> Function(
      Future<void> Function(SyncAssetStore backend) body,
    );

/// 一轮同步报告里带回的错误（[SrsSyncReport.error]）：引擎没抛异常，但这个目录这轮没同步成。
class SrsSyncReportError implements Exception {
  const SrsSyncReportError(this.message);

  final String message;

  @override
  String toString() => message;
}

/// 「立即同步」的结果：[ran] = 同步成功的目录数，[errors] = 没同步成的目录各自的原因。
/// 两者都为空 = 没配置任何同步后端、本机也没开互联服务。
class SrsSyncNowResult {
  const SrsSyncNowResult({required this.ran, this.errors = const <Object>[]});

  final int ran;
  final List<Object> errors;

  bool get unconfigured => ran == 0 && errors.isEmpty;
}

/// 一个位置最近一轮的加密状态。
class SrsLocationCryptoState {
  const SrsLocationCryptoState({this.kdf, this.encrypted = false, this.error});

  /// 位置开了加密时它的参数（输入口令时用同一份盐派生）。
  final SrsKdf? kdf;

  /// 这一轮用密钥收发了。
  final bool encrypted;

  /// [kSrsLocationCryptoErrors] 之一，或 null。
  final String? error;
}

/// 位置的加密握手没过、这一轮不同步该位置的原因（同步与历史页按它提示用户）。
const Set<String> kSrsLocationCryptoErrors = <String>{
  kSrsSync2NeedsKey,
  kSrsSync2WrongKey,
  kSrsSync2EncryptionMissing,
  kSrsSync2BadKdf,
};

/// 只提示一次的通知类别。
/// 一个位置上没法自动关联的 profile（[SrsSyncNotice.profileNotLinked]）：目录里有多个有数据的同一 profile，或本机
/// 与对方都有用户笔记（见 srs_profile_link.dart [SrsProfileLinkChoose]）。由用户选采用哪一个。
class SrsProfileConflict {
  const SrsProfileConflict({
    required this.directoryKey,
    required this.localUid,
    required this.candidates,
    required this.localHasNotes,
  });

  /// 冲突所在的同步位置（[SrsSyncEngine.directoryKey] 同一身份）。
  final String directoryKey;

  /// 判定时本机 profile 的 uid：冲突只属于这个 profile（用户之后切了 profile，这个冲突就不再适用）。
  final String localUid;

  /// 可以采用的 profile（按 uid 排序）。
  final List<SrsRemoteProfile> candidates;

  /// 本机 profile 有用户笔记：选定后并入，而不是直接改用。
  final bool localHasNotes;

  /// 「保持本机独立」按它记（本机 profile + 位置 + 候选）：同一位置出现了别的候选、或换了本机 profile 会再提示。
  String get ignoreKey => <String>[
    directoryKey,
    localUid,
    for (final SrsRemoteProfile c in candidates) c.uid,
  ].join('|');
}

enum SrsSyncNotice {
  /// 当前同步后端拿不到服务器时间，复习数据没法同步。
  backendUnsupported,

  /// 系统时间与可信时间偏差超过 10 分钟。
  clockSkew,

  /// 同步目录里有另一台设备的同一个 profile，但两边都有用户笔记，没法自动关联
  /// （详情见 [SrsSyncScheduler.profileConflict]；app 侧弹窗让用户处理，不走 toast）。
  profileNotLinked,

  /// 升级到同步 v2 后首次同步还没确认（[kSrsSyncAwaitingConfirm]），复习数据暂不同步。
  awaitingConfirm,
}

class SrsSyncScheduler {
  SrsSyncScheduler({
    required Future<SrsDbStore?> Function() readStore,
    required SrsChannelRunner channels,
    required Future<String?> Function(SyncAssetStore backend) directoryKeyOf,
    required void Function() onDataChanged,
    required void Function(SrsSyncNotice notice) onNotice,
    Future<List<SrsLocalDirectory>> Function()? localDirectories,
    Future<List<SrsFolderLocation>> Function()? folderLocations,
    SrsProfileLinker? profileLinker,
    SrsSyncRunner? runner,
    Future<Directory?> Function()? readMediaRoot,
    SrsMediaSyncRunner mediaRunner = srsDefaultMediaSyncRunner,
    DateTime Function()? clock,
    Duration hostWriteDebounce = kSrsHostWriteDebounce,
    bool Function()? canRun,
    bool Function()? firstSyncConfirmed,
    void Function()? onLocalDirectoryPublished,
    SrsLocationKey? Function(String locationId)? locationKey,
    Future<void> Function(String locationId, SrsLocationKey key)?
    onEncryptionEnabled,
    Future<bool> Function()? autoSyncEnabled,
  }) : _profileLinker = profileLinker,
       _autoSyncEnabled = autoSyncEnabled,
       _locationKey = locationKey,
       _onEncryptionEnabled = onEncryptionEnabled,
       _onLocalDirectoryPublished = onLocalDirectoryPublished,
       _firstSyncConfirmed = firstSyncConfirmed ?? _alwaysRun,
       _canRun = canRun ?? _alwaysRun,
       _hostWriteDebounce = hostWriteDebounce,
       _readMediaRoot = readMediaRoot,
       _mediaRunner = mediaRunner,
       _readStore = readStore,
       _channels = channels,
       _directoryKeyOf = directoryKeyOf,
       _localDirectories = localDirectories,
       _folderLocations = folderLocations,
       _onDataChanged = onDataChanged,
       _onNotice = onNotice,
       _injectedRunner = runner,
       _clock = clock ?? DateTime.now;

  final Future<SrsDbStore?> Function() _readStore;
  final SrsChannelRunner _channels;
  final Future<String?> Function(SyncAssetStore backend) _directoryKeyOf;
  final SrsProfileLinker? _profileLinker;
  final Duration _hostWriteDebounce;
  Timer? _hostWriteTimer;

  /// 坏文件只记一次日志（每轮都会再跳过同一个文件）。
  final Set<String> _loggedSkipped = <String>{};
  final Future<List<SrsLocalDirectory>> Function()? _localDirectories;
  final Future<List<SrsFolderLocation>> Function()? _folderLocations;

  /// 每个文件夹位置最近一次的错误（同步与历史页显示；成功一轮即清掉）。
  final Map<String, Object> folderErrors = <String, Object>{};
  final void Function() _onDataChanged;
  final void Function(SrsSyncNotice notice) _onNotice;

  /// 测试注入的一轮；null = 生产实现（[srsDefaultSyncRunner]，带进度与收手检查）。
  final SrsSyncRunner? _injectedRunner;

  Future<SrsSync2Report> _runner(
    SyncAssetStore backend,
    SrsDbStore store,
    String directoryKey, {
    SrsLocationKey? locationKey,
  }) =>
      _injectedRunner?.call(
        backend,
        store,
        directoryKey,
        locationKey: locationKey,
      ) ??
      srsDefaultSyncRunner(
        backend,
        store,
        directoryKey,
        locationKey: locationKey,
        onFetchProgress: (int done, int total) =>
            srsSyncProgress.value = SrsSyncProgress(
              stage: SrsSyncStage.downloading,
              done: done,
              total: total,
            ),
        onUploadStart: () => srsSyncProgress.value = const SrsSyncProgress(
          stage: SrsSyncStage.uploading,
        ),
        beforeUpload: (String? keyHex) =>
            _mediaBeforeUpload(backend, store, directoryKey, keyHex),
        shouldStop: () => _halted,
      );

  /// 发段之前先把本机的媒体传上去（设计 §6.1 写入纪律 3，审查 S-10）：本机新加 / 改过的媒体的绑定随这一轮的段
  /// 发出，读到这些段的设备马上就能拿到内容。只在本机内容可能变了（内容指纹与本位置上次对账时不同）或本位置还没
  /// 对账过时跑；失败只记日志，不影响复习数据本身的同步。
  Future<void> _mediaBeforeUpload(
    SyncAssetStore backend,
    SrsDbStore store,
    String key,
    String? keyHex,
  ) async {
    final Future<Directory?> Function()? readMediaRoot = _readMediaRoot;
    if (readMediaRoot == null || _halted) return;
    if (_mediaReconciledAt[key] != null &&
        _mediaReconciledContent[key] == store.contentFingerprint) {
      return;
    }
    try {
      final Directory? root = await readMediaRoot();
      if (root == null) return;
      srsSyncProgress.value = const SrsSyncProgress(stage: SrsSyncStage.media);
      await srsDefaultMediaSyncRunner(
        backend,
        store,
        root,
        cipher: keyHex == null ? null : SrsMediaCipher(store, keyHex),
        locationId: key,
        uploadOnly: true,
      );
    } catch (e, stack) {
      ErrorLogService.instance.log(
        'SrsSyncScheduler.mediaBeforeUpload',
        e,
        stack,
      );
    }
  }

  final Future<Directory?> Function()? _readMediaRoot;
  final SrsMediaSyncRunner _mediaRunner;
  final DateTime Function() _clock;

  final Set<SrsSyncNotice> _noticed = <SrsSyncNotice>{};
  DateTime? _lastThrottledAt;

  /// 最近一次检出的 profile 冲突（[SrsSyncNotice.profileNotLinked]）；app 侧据此弹窗。
  SrsProfileConflict? profileConflict;

  /// 各（位置, 本机 profile uid）最近一次 profile 关联判定（键见 [_linkKey]）：冲突的判定 [kSrsProfileConflictRecheck]
  /// 内复用，「已关联上」（本机 uid 目录里已有别的设备）永久复用——两者都不会因为再列一遍目录而改变，每轮重列只是
  /// 白走一圈网盘请求。键里必须带 uid：调度器跨 profile 切换常驻，只按位置记会让切过去的 profile 永远跳过关联。
  final Map<String, ({DateTime at, SrsProfileConflict? conflict})>
  _linkDecided = <String, ({DateTime at, SrsProfileConflict? conflict})>{};

  /// 各位置最近一次媒体对账成功的时刻（见 [kSrsMediaReconcileInterval]）。
  final Map<String, DateTime> _mediaReconciledAt = <String, DateTime>{};

  /// 各位置最近一次媒体对账开跑时本机内容指纹（[SrsDbStore.contentFingerprint]）。
  final Map<String, String> _mediaReconciledContent = <String, String>{};
  bool _disposed = false;

  /// 底层库此刻能不能用（app 侧 = 库已打开）。关库（备份恢复 / 数据根迁移 / 退出）
  /// 期间为 false：新一轮不开、在跑的一轮在下一个检查点收手；重开后自动恢复。
  final bool Function() _canRun;

  static bool _alwaysRun() => true;

  /// 自动同步开关（null = 恒开）。见文件头。
  final Future<bool> Function()? _autoSyncEnabled;

  /// 复习数据的自动同步此刻是否开着（每次触发时现读，改设置立即生效）。
  Future<bool> isAutoSyncEnabled() async =>
      await _autoSyncEnabled?.call() ?? true;

  /// 首次 v2 同步是否已确认（没确认前一轮也不跑，见 [kSrsSyncAwaitingConfirm]）。
  final bool Function() _firstSyncConfirmed;

  /// 本机目录（本机作为互联 host 时）的一轮传上了新段：app 据此唤醒已配对设备的长轮询。
  final void Function()? _onLocalDirectoryPublished;

  /// 每个位置的本机密钥（设计 §9：每个位置一个可选的端到端加密开关；见 srs_location_crypto.dart）。
  final SrsLocationKey? Function(String locationId)? _locationKey;

  /// 本机刚开的加密已写进位置的 `meta.json`：调用方把密钥标成已生效。
  final Future<void> Function(String locationId, SrsLocationKey key)?
  _onEncryptionEnabled;

  /// 各位置最近一轮看到的加密状态（同步与历史页显示「已加密 / 需要口令 / 口令不对」）。
  final Map<String, SrsLocationCryptoState> locationCrypto =
      <String, SrsLocationCryptoState>{};

  /// 已经上报过摘要不一致的设备（每次启动每台只报一次）。
  final Set<String> _digestReported = <String>{};

  /// 设计 §4.5：两台设备在同一版本向量下派生状态摘要不同 = 确定性 bug，自动上报日志（不让用户处理）。
  Future<void> _reportDigestMismatch(SrsDbStore store) async {
    try {
      final Map<String, Object?> status = await store.sync2Status();
      for (final Object? d
          in (status['devices'] as List?) ?? const <Object?>[]) {
        if (d is! Map || d['digestMismatch'] != true) continue;
        final String id = d['device'] as String? ?? '';
        if (!_digestReported.add(id)) continue;
        ErrorLogService.instance.log(
          'SrsSync2.digestMismatch',
          StateError(
            'SRS state digest differs from device $id at the same version vector',
          ),
          StackTrace.current,
        );
      }
    } catch (e, stack) {
      ErrorLogService.instance.log('SrsSyncScheduler.digest', e, stack);
    }
  }

  /// 记下一轮的加密结论；本机刚开的加密生效了就交给调用方保存。
  Future<void> _noteCrypto(String locationId, SrsSync2Report? r) async {
    if (r == null) return;
    locationCrypto[locationId] = SrsLocationCryptoState(
      kdf: r.kdf,
      encrypted: r.encrypted,
      error: kSrsLocationCryptoErrors.contains(r.error) ? r.error : null,
    );
    final SrsLocationKey? k = _locationKey?.call(locationId);
    if (r.encryptionEnabled && k != null) {
      await _onEncryptionEnabled?.call(locationId, k.enabled());
    }
  }

  /// 媒体对账在 [locationId] 上有内容对象用这把密钥解不开（第一块就认证不过：密钥证明不了是对的，见
  /// srs_media_sync.dart [SrsMediaSyncReport.undecryptable]）：按口令不对提示（[kSrsSync2WrongKey]，与握手报的同一条
  /// 提示）。这些对象不记可疑、持有者也不覆盖重传——修不好的是密钥，不是对象。
  void _noteMediaKey(String locationId, SrsMediaSyncReport? media) {
    if (media == null || media.undecryptable.isEmpty) return;
    final SrsLocationCryptoState? was = locationCrypto[locationId];
    locationCrypto[locationId] = SrsLocationCryptoState(
      kdf: was?.kdf,
      encrypted: was?.encrypted ?? true,
      error: kSrsSync2WrongKey,
    );
  }

  /// 调度器已卸下，或库正关着：这一轮不该开始 / 不该继续。
  bool get _halted => _disposed || !_canRun();

  /// 已经提示过的通知（测试读）。
  Set<SrsSyncNotice> get noticed => Set<SrsSyncNotice>.unmodifiable(_noticed);

  void dispose() {
    _disposed = true;
    _hostWriteTimer?.cancel();
    _hostWriteTimer = null;
  }

  /// 关库前调用：撤掉待触发的本机目录同步，等在跑（及已排队）的一轮结束。
  ///
  /// 调用方先让 [canRun] 变 false（app 侧先把库标成未初始化），排队中的轮次一进来就
  /// 收手；在跑的一轮在下一个检查点收手，并且它此刻还持着 store 独占区——关库若不等
  /// 它，就会在半截同步上把连接关掉（反馈 OMWOurRQKb 日志：`SrsDbStore._loadLocal`
  /// 「connection was closed」）。
  Future<void> quiesce() async {
    _hostWriteTimer?.cancel();
    _hostWriteTimer = null;
    await _tail;
  }

  /// 已配对设备往本机 host 的 SRS 目录写了文件：去抖后只跑本机目录（见文件头第 4 条）。自动同步关着时
  /// 不跑（开关在到点时读）。
  void notifyLocalDirectoryWritten() {
    if (_disposed || _localDirectories == null) return;
    _hostWriteTimer?.cancel();
    _hostWriteTimer = Timer(_hostWriteDebounce, () {
      _hostWriteTimer = null;
      unawaited(_syncLocalDirectoriesIfAuto());
    });
  }

  Future<void> _syncLocalDirectoriesIfAuto() async {
    if (!await isAutoSyncEnabled()) return;
    await syncLocalDirectories();
  }

  /// 自动触发的一轮（常规同步一条通道跑完后的复习步骤，文件头第 1 条；互联快速通道看到 host 有新数据）：
  /// 自动同步关着时不跑，返回 null。
  Future<SrsSync2Report?> autoSyncWithBackend(SyncAssetStore backend) async {
    if (!await isAutoSyncEnabled()) return null;
    return syncWithBackend(backend);
  }

  /// 本机写了复习数据后的推送：[interconnect] 给出此刻可用的互联后端（没连上为 null）就同步它，
  /// 再跑本机目录（本机作为 host 时唤醒连它的设备）。自动同步关着时什么都不做。
  ///
  /// [exclusive] 包住「取互联后端 + 跑它的一轮」：app 侧传常规同步的那把互斥（`runExclusiveWithSync`），
  /// 推送与常规同步不再并发改同一个单例后端的会话 / 选路缓存（反馈 XDV7Mzc2gw）。本机目录只读写本机文件
  /// 系统、不碰共享后端，放在锁外，不延长常规同步的等待。
  ///
  /// 返回互联这一步是否成功（没连上 / 自动同步关着 / 首次同步未确认这类本机状态都不算失败）：
  /// [SrsLocalPush] 据此做失败退避。互联那一轮抛的错照常抛给调用方。
  Future<bool> autoPush(
    Future<SyncAssetStore?> Function() interconnect, {
    Future<bool> Function(Future<bool> Function() body)? exclusive,
  }) async {
    if (!await isAutoSyncEnabled()) return true;
    Future<bool> pushInterconnect() async {
      final SyncAssetStore? backend = await interconnect();
      if (backend == null) return true;
      final String? error = (await syncWithBackend(backend)).error;
      return error == null || kSrsSyncLocalStateErrors.contains(error);
    }

    final bool ok =
        await (exclusive?.call(pushInterconnect) ?? pushInterconnect());
    await syncLocalDirectories();
    return ok;
  }

  /// 串行化：通道后置步骤（常规同步互斥锁里）、进复习 tab、「立即同步」、本机 host 目录可能同时触发，
  /// 而它们改的是同一份本机同步状态（同一个 SrsDbStore），一次只跑一个目录。
  Future<void> _tail = Future<void>.value();

  Future<T> _serially<T>(Future<T> Function() body) {
    final Future<T> run = _tail.then((_) async {
      if (_halted) return body();
      srsSyncProgress.value = const SrsSyncProgress();
      try {
        return await body();
      } finally {
        srsSyncProgress.value = null;
      }
    });
    _tail = run.then<void>((_) {}, onError: (Object _) {});
    return run;
  }

  /// 用一个已认证后端跑一轮（常规同步的通道后置步骤直接调它）。store 打不开（或调度器已卸下）
  /// 时这一轮没跑，报告带 [kSrsSyncStoreUnavailable]——「立即同步」据此如实报未同步，不算成功。
  /// [directoryKey] 缺省时按后端算（[directoryKeyOf]）。
  ///
  /// **排队中的同一请求合并**（反馈 XDV7Mzc2gw / kB2ltk0u9F / U37Aku3oeL）：本机推送（每答一张
  /// 卡去抖 5 s 触发一次）、长轮询、进复习 tab、后置步骤都走这里；host 时断时续时每轮要先花
  /// 数秒逐个探测死地址再失败，旧实现把每次触发都追加进 [_serially] 的 FIFO，队列越排越长、
  /// 同一个后端在一轮长同步之后被连续重放。同一后端 + 同一 [directoryKey] 已有一轮**排着
  /// 还没开跑**时直接复用它的 future：那一轮开跑时会看到此刻之前的全部本机改动，合并不丢数据。
  /// 已经开跑的不复用（它可能已经过了取发件箱那一步）。
  Future<SrsSync2Report> syncWithBackend(
    SyncAssetStore backend, {
    String? directoryKey,
  }) {
    final (SyncAssetStore, String?) requestKey = (backend, directoryKey);
    final Future<SrsSync2Report>? queued = _queuedRounds[requestKey];
    if (queued != null) {
      _roundStats.coalesced++;
      return queued;
    }
    _roundStats.queued++;
    late final Future<SrsSync2Report> round;
    round = _serially(() {
      if (identical(_queuedRounds[requestKey], round)) {
        _queuedRounds.remove(requestKey);
      }
      _roundStats.queued--;
      return _trackRound(
        backend.runtimeType.toString(),
        () => _syncWithBackend(backend, directoryKey),
      );
    });
    _queuedRounds[requestKey] = round;
    return round;
  }

  /// 排着还没开跑的 [syncWithBackend] 轮次（见其合并说明）。
  final Map<(SyncAssetStore, String?), Future<SrsSync2Report>> _queuedRounds =
      <(SyncAssetStore, String?), Future<SrsSync2Report>>{};

  /// 轮次统计（诊断用）。
  final SrsSyncRoundStats _roundStats = SrsSyncRoundStats();

  @visibleForTesting
  SrsSyncRoundStats get roundStats => _roundStats;

  /// 一轮的取证：开跑时**同步**写活动面包屑（后端、排队数、连续失败数、RSS），阶段变化时
  /// 覆写，跑完删掉——进程死在同步里（三次小米闪退都在补传积压期间、Dart 零日志），下次
  /// 启动 [PreviousExitLog] 会报「上次进程在 srs_sync 进行中没了」+ 当时的阶段与内存。
  /// 失败时把队列 / 失败计数 / 内存写进诊断段，随反馈上传。
  Future<SrsSync2Report> _trackRound(
    String backendLabel,
    Future<SrsSync2Report> Function() body,
  ) async {
    final SrsSyncRoundStats stats = _roundStats;
    stats.running++;
    String describe(String stage) =>
        'stage=$stage backend=$backendLabel ${stats.describe()} '
        '${_memoryDescription()}';
    SrsSyncStage? lastStage;
    void onProgress() {
      final SrsSyncStage? stage = srsSyncProgress.value?.stage;
      if (stage == null || stage == lastStage) return;
      lastStage = stage;
      ActivityBreadcrumb.mark(kSrsSyncActivity, describe(stage.name));
    }

    ActivityBreadcrumb.mark(kSrsSyncActivity, describe('start'));
    srsSyncProgress.addListener(onProgress);
    try {
      final SrsSync2Report report = await body();
      if (report.error == null) {
        stats.consecutiveFailures = 0;
      } else {
        _noteRoundFailure(describe, 'report error: ${report.error}');
      }
      return report;
    } catch (e) {
      _noteRoundFailure(describe, e);
      rethrow;
    } finally {
      srsSyncProgress.removeListener(onProgress);
      stats.running--;
      ActivityBreadcrumb.clear(kSrsSyncActivity);
    }
  }

  void _noteRoundFailure(String Function(String) describe, Object error) {
    final DateTime now = _clock();
    final DateTime? previous = _roundStats.lastFailureAt;
    _roundStats
      ..consecutiveFailures += 1
      ..lastFailureAt = now;
    ErrorLogService.instance.logDiagnostic(
      'SrsSyncScheduler.roundFailed',
      '${describe('failed')} previousFailureAt=${previous?.toIso8601String()}: '
          '$error',
    );
  }

  static String _memoryDescription() =>
      'rss=${ProcessInfo.currentRss >> 20}MB maxRss=${ProcessInfo.maxRss >> 20}MB';

  Future<SrsSync2Report> _syncWithBackend(
    SyncAssetStore backend,
    String? directoryKey,
  ) async {
    if (_halted) return SrsSync2Report()..error = kSrsSyncStoreUnavailable;
    if (!_firstSyncConfirmed()) {
      _noticeOnce(SrsSyncNotice.awaitingConfirm);
      return SrsSync2Report()..error = kSrsSyncAwaitingConfirm;
    }
    SrsDbStore? store = await _readStore();
    if (store == null || _halted) {
      return SrsSync2Report()..error = kSrsSyncStoreUnavailable;
    }
    final String? key = directoryKey ?? await _directoryKeyOf(backend);
    if (key == null) {
      // 位置身份拿不到：上传进度按身份记，换个身份只是多传一遍（段名唯一、内容不变），但宁可这轮不同步。
      return SrsSync2Report()..error = kSrsSyncDirectoryIdentityUnavailable;
    }
    final SrsProfileLinker? linker = _profileLinker;
    bool adopted = false;
    final String linkKey = _linkKey(key, store.profileUid);
    final ({DateTime at, SrsProfileConflict? conflict})? decided =
        _linkDecided[linkKey];
    final bool reuseLink =
        decided != null &&
        (decided.conflict == null ||
            _clock().difference(decided.at) < kSrsProfileConflictRecheck);
    if (linker != null && !reuseLink) {
      final SrsProfileLinkOutcome link = await linker.link(backend, store);
      adopted = !identical(link.store, store);
      store = link.store;
      final List<SrsRemoteProfile>? choose = link.choose;
      if (choose != null) {
        final SrsProfileConflict conflict = SrsProfileConflict(
          directoryKey: key,
          localUid: store.profileUid,
          candidates: choose,
          localHasNotes: link.localHasNotes,
        );
        profileConflict = conflict;
        _linkDecided[linkKey] = (at: _clock(), conflict: conflict);
        // 每次重新判出都通知（不是 [_noticeOnce]）：用户选了「稍后」或冲突换了内容，下一次判定还要能再问；
        // 判定本身按 [kSrsProfileConflictRecheck] 复用，不会每轮都通知。
        _onNotice(SrsSyncNotice.profileNotLinked);
      } else if (link.linked) {
        _linkDecided[_linkKey(key, store.profileUid)] = (
          at: _clock(),
          conflict: null,
        );
      }
      if (_halted) return SrsSync2Report()..error = kSrsSyncStoreUnavailable;
    }
    // 引擎在一轮开头写探针取服务器时间，整轮（上传 / 拉取 / 快照，大库能跑几十分钟）跑完才回来：
    final SrsLocationKey? locKey = _locationKey?.call(key);
    final SrsSync2Report report = await _runner(
      backend,
      store,
      key,
      locationKey: locKey,
    );
    await _noteCrypto(key, report);
    if (linker != null && report.error == null && !_halted) {
      try {
        await linker.publish(backend, store, key);
      } catch (e, stack) {
        // 说明文件只用来让别的设备认出同一个 profile，写失败下一轮再写。
        ErrorLogService.instance.log('SrsSyncScheduler.profileInfo', e, stack);
      }
    }
    for (final String f in report.errors) {
      if (_loggedSkipped.add('$key|$f')) {
        ErrorLogService.instance.log(
          'SrsSyncScheduler.skippedFile',
          StateError('SRS sync skipped a segment in $key: $f'),
          StackTrace.current,
        );
      }
    }
    // 服务器时间与写 head 那次上传同一刻的墙钟配对（[SrsSync2Report.serverTimeWallMs]），与这一轮跑了多久无关。
    final int? serverTime = report.serverTimeMs;
    if (serverTime != null) {
      await store.anchorTime(
        serverTime,
        observedAtWallMs: report.serverTimeWallMs,
      );
      final int? skew = store.trustedClock.wallSkewMs;
      if (skew != null && skew.abs() > kSrsClockSkewWarnMs) {
        _noticeOnce(SrsSyncNotice.clockSkew);
      }
    }
    if (report.error == kSrsSyncNeedsUpgrade) {
      _noticeOnce(SrsSyncNotice.backendUnsupported);
    }
    if (report.error == null && !_halted) await _reportDigestMismatch(store);
    bool mediaChanged = false;
    final Future<Directory?> Function()? readMediaRoot = _readMediaRoot;
    // 媒体对账要逐个过一遍全部引用的媒体、扫三遍笔记引用：只在媒体引用可能变了（本机或别的设备改了笔记 / 笔记类型
    // = 内容指纹变了）、或本位置还没对账过 / 距上次满 [kSrsMediaReconcileInterval] 时跑。复习日志不引用媒体：以前
    // 「这一轮上传 / 应用过操作」就算，于是边背卡边推送的每一轮都整套对账一遍，同步收尾时 UI 卡顿。
    final DateTime? reconciled = _mediaReconciledAt[key];
    final String content = store.contentFingerprint;
    final bool mediaDue =
        adopted ||
        report.fork ||
        reconciled == null ||
        _mediaReconciledContent[key] != content ||
        _clock().difference(reconciled) >= kSrsMediaReconcileInterval;
    if (report.error == null && readMediaRoot != null && mediaDue && !_halted) {
      // 完整对账跟在事件之后：先拿到引用它们的笔记与绑定，再按内容哈希补齐两边缺的文件（本机的媒体已在发段之前
      // 传过一遍，见 [_mediaBeforeUpload]）。
      // 媒体失败只记日志，不影响复习数据本身的同步结果。
      try {
        final Directory? root = await readMediaRoot();
        if (root != null) {
          srsSyncProgress.value = const SrsSyncProgress(
            stage: SrsSyncStage.media,
          );
          final SrsMediaSyncReport media = await _mediaRunner(
            backend,
            store,
            root,
            cipher: report.encrypted && locKey != null
                ? SrsMediaCipher(store, locKey.keyHex)
                : null,
            locationId: key,
          );
          mediaChanged = media.downloaded > 0;
          _noteMediaKey(key, media);
          _mediaReconciledAt[key] = _clock();
          _mediaReconciledContent[key] = content;
        }
      } catch (e, stack) {
        ErrorLogService.instance.log('SrsSyncScheduler.media', e, stack);
      }
    }
    if (adopted ||
        report.changed ||
        report.applied > 0 ||
        report.fork ||
        mediaChanged) {
      _onDataChanged();
    }
    return report;
  }

  /// 用户在冲突弹窗里选了 [uid]（[conflict] 的候选）：本机 profile 改用它（本机有笔记时并入，见
  /// [SrsProfileLinker.adopt]），之后跑一轮「立即同步」把两边的数据收发齐。与同步串行（同一个 store）。
  ///
  /// 弹窗开着的时候用户可能已经切到别的 profile：此刻的 profile 不是 [conflict] 判定时的那个就抛
  /// [StateError]、什么都不动——否则会把另一个 profile 并进不相干的候选。
  Future<SrsSyncNowResult> adoptProfile(
    SrsProfileConflict conflict,
    String uid,
  ) async {
    final SrsProfileLinker? linker = _profileLinker;
    if (linker == null) return const SrsSyncNowResult(ran: 0);
    await _serially(() async {
      final SrsDbStore? store = await _readStore();
      if (store == null || _halted) return;
      if (store.profileUid != conflict.localUid) {
        throw StateError(
          'active SRS profile changed since the conflict was detected '
          '(${conflict.localUid} -> ${store.profileUid})',
        );
      }
      await linker.adopt(store, uid);
      if (identical(profileConflict, conflict)) profileConflict = null;
      _linkDecided.clear();
      _onDataChanged();
    });
    return syncNow();
  }

  static String _linkKey(String directoryKey, String profileUid) =>
      '$directoryKey\u0000$profileUid';

  /// 对所有已认证通道、以及本机直接读写的目录（本机作为互联 host 时）各跑一轮（不节流）。
  /// 通道抛错与报告里带回错误的目录都记进 [SrsSyncNowResult.errors]，不算同步成功。
  ///
  /// 用户明确要求的一轮（「立即同步」、AnkiConnect `sync`）：媒体全量对账、冲突判定重做，不复用上次结论。
  Future<SrsSyncNowResult> syncNow() => _syncAll(fullMediaReconcile: true);

  /// 跑一轮全部通道。[fullMediaReconcile] = 不复用上次媒体对账的结论（只有用户手动「立即同步」）；否则媒体对账照
  /// 内容指纹门控（[_mediaReconciledContent] / [kSrsMediaReconcileInterval]），没变就不重做（审查 S-11：以前进复习
  /// 页的节流同步也清空对账时刻，每次进页都把几万个媒体整套对一遍）。
  Future<SrsSyncNowResult> _syncAll({required bool fullMediaReconcile}) async {
    if (_halted) return const SrsSyncNowResult(ran: 0);
    if (fullMediaReconcile) _mediaReconciledAt.clear();
    _linkDecided.removeWhere(
      (String _, ({DateTime at, SrsProfileConflict? conflict}) d) =>
          d.conflict != null,
    );
    int reportFailures = 0;
    final List<Object> errors = <Object>[];
    final ({int ran, List<Object> errors}) channels = await _channels((
      SyncAssetStore backend,
    ) async {
      final String? error = (await syncWithBackend(backend)).error;
      if (error != null) {
        reportFailures++;
        errors.add(SrsSyncReportError(error));
      }
    });
    errors.addAll(channels.errors);
    final SrsSyncNowResult local = await syncLocalDirectories();
    errors.addAll(local.errors);
    final SrsSyncNowResult folders = await syncFolderLocations();
    errors.addAll(folders.errors);
    return SrsSyncNowResult(
      ran: channels.ran - reportFailures + local.ran + folders.ran,
      errors: errors,
    );
  }

  /// 跑用户加的文件夹存储位置（设计 §6.5：U 盘 / NAS / 被别的同步工具同步的目录）。文件夹此刻不在
  /// （U 盘没插）只记进 [folderErrors]，不算这轮「立即同步」失败——它是可选的冗余副本。
  Future<SrsSyncNowResult> syncFolderLocations() => _serially(() async {
    final Future<List<SrsFolderLocation>> Function()? read = _folderLocations;
    if (read == null || _halted || !_firstSyncConfirmed()) {
      return const SrsSyncNowResult(ran: 0);
    }
    final SrsDbStore? store = await _readStore();
    if (store == null || _halted) return const SrsSyncNowResult(ran: 0);
    final Directory? mediaRoot = await _readMediaRoot?.call();
    int ran = 0;
    bool changed = false;
    for (final SrsFolderLocation l in await read()) {
      if (l.idle || _halted) continue;
      try {
        final SrsFolderSyncReport r = await srsSyncFolderLocation(
          location: l,
          store: store,
          mediaRoot: mediaRoot,
          key: _locationKey?.call(l.locationId),
          migrationMemo: _srsMigrationMemo,
        );
        final SrsLocationPrepared? prepared = r.prepared;
        if (prepared != null) {
          srsLogMigrationLeftover(prepared, l.locationId);
          srsLogMigrationCleanup(prepared, l.locationId);
        }
        await _noteCrypto(l.locationId, r.crypto);
        _noteMediaKey(l.locationId, r.media);
        // 握手没过但不是口令类问题（meta.json 读不到 / 位置来自更新版本）：如实记成这个位置没同步成。
        // 口令类问题由 [locationCrypto] 显示（需要口令 / 口令不对 / 加密设置不见了）。
        final String? error = (r.crypto?.needsUpgrade ?? false)
            ? kSrsSyncNeedsUpgrade
            : r.crypto?.error;
        if (error != null && !kSrsLocationCryptoErrors.contains(error)) {
          folderErrors[l.id] = SrsSyncReportError(error);
          continue;
        }
        folderErrors.remove(l.id);
        ran++;
        final SrsSync2Report? ops = r.ops;
        if (ops != null && (ops.changed || ops.applied > 0 || ops.fork)) {
          changed = true;
        }
        if ((r.media?.downloaded ?? 0) > 0) changed = true;
      } catch (e, stack) {
        folderErrors[l.id] = e;
        if (e is! FileSystemException) {
          ErrorLogService.instance.log('SrsSyncScheduler.folder', e, stack);
        }
      }
    }
    if (changed) _onDataChanged();
    return SrsSyncNowResult(ran: ran);
  });

  /// 只跑本机直接读写的目录（本机作为互联 host 时）。
  Future<SrsSyncNowResult> syncLocalDirectories() async {
    final Future<List<SrsLocalDirectory>> Function()? local = _localDirectories;
    if (local == null || _halted) return const SrsSyncNowResult(ran: 0);
    int ran = 0;
    final List<Object> errors = <Object>[];
    for (final SrsLocalDirectory d in await local()) {
      try {
        final SrsSync2Report report = await syncWithBackend(
          d.store,
          directoryKey: d.directoryKey,
        );
        final String? error = report.error;
        if (error != null) {
          errors.add(SrsSyncReportError(error));
        } else {
          ran++;
          if (report.uploaded > 0) _onLocalDirectoryPublished?.call();
        }
      } catch (e, stack) {
        errors.add(e);
        ErrorLogService.instance.log(
          'SrsSyncScheduler.localDirectory',
          e,
          stack,
        );
      }
    }
    return SrsSyncNowResult(ran: ran, errors: errors);
  }

  /// 节流版（进入复习 tab）：距上一次节流触发不足 [kSrsSyncMinInterval] 时跳过，返回 false。媒体对账走内容指纹
  /// 门控，不做全量（只有手动「立即同步」做，见 [syncNow]）。
  Future<bool> syncThrottled() async {
    final DateTime now = _clock();
    final DateTime? last = _lastThrottledAt;
    if (last != null && now.difference(last) < kSrsSyncMinInterval) {
      return false;
    }
    _lastThrottledAt = now;
    await _syncAll(fullMediaReconcile: false);
    return true;
  }

  void _noticeOnce(SrsSyncNotice notice) {
    if (_noticed.add(notice)) _onNotice(notice);
  }
}
