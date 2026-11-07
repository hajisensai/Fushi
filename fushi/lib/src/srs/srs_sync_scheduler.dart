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
import 'package:fushi/src/srs/srs_device_identity.dart';
import 'package:fushi/src/srs/srs_sync_progress.dart';
import 'package:fushi/src/sync/dropbox_sync_backend.dart';
import 'package:fushi/src/sync/obfuscating_sync_backend.dart';
import 'package:fushi/src/utils/misc/error_log_service.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_engine/srs/sync2/srs_folder_location.dart';
import 'package:fushi_engine/srs/sync2/srs_location_crypto.dart';
import 'package:fushi_engine/srs/sync2/srs_location_migration.dart';
import 'package:fushi_engine/srs/sync2/srs_location_store.dart';
import 'package:fushi_engine/srs/sync2/srs_sync2_pull_first.dart';
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

/// 用户在同步与历史页关掉了这个位置的复习同步：这一轮跳过它（不算成功，也不算失败）。
const String kSrsSyncLocationDisabled = 'srs sync location disabled';

/// 只说明「本机此刻不该同步」、与网络 / 对端无关的报告错误：推送不为它们退避。
const Set<String> kSrsSyncLocalStateErrors = <String>{
  kSrsSyncStoreUnavailable,
  kSrsSyncAwaitingConfirm,
  kSrsSyncLocationDisabled,
};

/// 复习同步一轮的活动面包屑名（[ActivityBreadcrumb]）。
const String kSrsSyncActivity = 'srs_sync';

/// 旧根媒体后台迁移的活动面包屑名：进程死在迁移里时，下次启动报出死在第几个文件。
const String kSrsV1MigrateActivity = 'srs_v1_migrate';

/// 一条同步路径（一类后端，见 [SrsSyncScheduler.roundStatsFor] / [SrsSyncScheduler.folderRoundStats]）的
/// 轮次统计：排队数、在跑数、被合并的请求数、连续失败数与上次失败时刻。只用于诊断（面包屑 / 失败日志）。
/// 各路径各记一份：文件夹位置成功不会清掉云盘攒下的连续失败，面包屑里的排队数也只是这条路径自己的。
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
int? srsMaxConcurrentWritesOf(SyncAssetStore backend) =>
    srsBackendIdentityOf(backend) is DropboxSyncBackend ? 1 : null;

/// [backend] 的身份（[SrsAssetLocationStore.backendIdentity]）：防扫盘混淆每次解析都新包一层、`ensureFolder` 原样
/// 透传给里层的单例后端，按里层认。一轮同步、发段前的媒体上传、完整媒体对账、后台旧根迁移各建各的位置实例，同一
/// 身份上建文件夹进程内单飞，才不会在 Google Drive 上并发建出同名的 `media/<前2>/`（PR #2768 审查）。
Object srsBackendIdentityOf(SyncAssetStore backend) =>
    backend is ObfuscatingSyncBackend ? backend.inner : backend;

/// [backend] 上 `fushi-srs/<profileUid>/<folder>/` 的位置实例（见 [srsBackendIdentityOf]）。
SrsAssetLocationStore srsAssetLocation(
  SyncAssetStore backend,
  String profileUid, {
  String folder = kSrsSync2Folder,
}) => SrsAssetLocationStore(
  store: backend,
  profileUid: profileUid,
  folder: folder,
  maxConcurrentWrites: srsMaxConcurrentWritesOf(backend),
  backendIdentity: srsBackendIdentityOf(backend),
);

/// 本进程里已经确认旧集合根扫干净的位置（进程重启后的第一轮再扫一遍，接住围栏那一刻还在跑的旧版本晚到的写入）。
final SrsLocationMigrationMemo _srsMigrationMemo = SrsLocationMigrationMemo();

/// 生产实现：现有同步后端上的集合根（`fushi-srs/<profileUid>/v3/`）跑一轮同步 v2。先 [srsPrepareLocation]：立住
/// 旧根 `v2/` 上让旧版本停下的围栏，旧根上的设备段迁过来。[directoryKey] 就是这个位置的稳定身份（本机按它记每个位置
/// 传到了哪）。
///
/// 一轮成功之后旧根还有媒体残留：交给 [v1MediaMigrations] 在后台搬（[srsMigrateV1Media]，不挡这一轮、不占调度器的
/// 串行队列；[onV1Bound] = 补了绑定、请一轮同步把它发出去）；没给就在这一轮里搬。
Future<SrsSync2Report> srsDefaultSyncRunner(
  SyncAssetStore backend,
  SrsDbStore store,
  String directoryKey, {
  SrsLocationKey? locationKey,
  void Function(int done, int total)? onFetchProgress,
  void Function()? onUploadStart,
  Future<void> Function(String? keyHex)? beforeUpload,
  bool Function()? shouldStop,
  SrsSyncStepCallback? onStep,
  SrsV1MediaMigrations? v1MediaMigrations,
  Future<void> Function()? onV1Bound,
}) async {
  SrsLocationStore currentRoot() => srsAssetLocation(backend, store.profileUid);
  SrsLocationStore v1Root() =>
      srsAssetLocation(backend, store.profileUid, folder: kSrsSync2V1Folder);
  final SrsLocationStore location = currentRoot();
  final SrsLocationPrepared prepared = await srsPrepareLocation(
    host: store,
    v1: v1Root(),
    current: location,
    locationId: directoryKey,
    key: locationKey,
    nowMs: () => store.now().$1,
    writers: SrsAssetV1Writers(backend, store.profileUid),
    memo: _srsMigrationMemo,
    onStep: onStep,
  );
  if (prepared.needsUpgrade || prepared.error != null) {
    final SrsSync2Report r = SrsSync2Report()
      ..needsUpgrade = prepared.needsUpgrade
      ..error = prepared.needsUpgrade ? kSrsSyncNeedsUpgrade : prepared.error
      ..kdf = prepared.kdf;
    return r;
  }
  srsLogMigrationLeftover(prepared, directoryKey);
  // 本机型号 / 版本 / 平台随这一轮的 head 发布（别的设备的同步页 / 冲突中心据此认出这台设备）。
  await srsPublishDeviceInfo(store);
  final SrsSync2Report r = await srsSync2Round(
    host: store,
    location: location,
    locationId: directoryKey,
    nowMs: () => store.now().$1,
    bootClockMs: store.trustedClock.bootNowMs,
    key: locationKey,
    onFetchProgress: onFetchProgress,
    onUploadStart: onUploadStart,
    beforeUpload: beforeUpload,
    shouldStop: shouldStop,
    onStep: onStep,
  );
  if (r.needsUpgrade) r.error = kSrsSyncNeedsUpgrade;
  if (r.error == null && prepared.mediaLeftover) {
    // 本机这一轮在新根上读全了（没有缺段 / 坏段）才看得到已有的全部绑定；按名字存的旧文件等本位置的上传水位到了才删。
    final bool canBind =
        prepared.devicesSettled && r.missing == 0 && r.errors.isEmpty;
    final String progressId = srsLocationProgressId(
      directoryKey,
      r.encrypted ? locationKey?.keyHex : null,
    );
    Future<SrsV1MediaReport> job(void Function(int, int)? onProgress) =>
        srsMigrateV1Media(
          host: store,
          // 自己的实例（一轮的列表缓存不跟后台迁移共用）；建文件夹按后端身份进程内单飞，读按全部同名文件夹，
          // 与并发的一轮 / 媒体对账不会建出两个同名前缀目录、也不会有对象落进读不到的那个。
          v1: v1Root(),
          current: currentRoot(),
          locationId: directoryKey,
          key: locationKey,
          nowMs: () => store.now().$1,
          canBind: canBind,
          progressId: progressId,
          recordPresence: true,
          writers: SrsAssetV1Writers(backend, store.profileUid),
          memo: _srsMigrationMemo,
          onProgress: onProgress,
          shouldStop: shouldStop,
          onBound: onV1Bound,
        );
    if (v1MediaMigrations == null) {
      srsLogV1MediaReport(await job(null), directoryKey);
    } else {
      v1MediaMigrations.start(directoryKey, job);
    }
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

/// 旧根媒体迁移删旧文件时逐个出的错：那些文件留着下一次再删，同步照样算成功，但每个错都记日志。
void srsLogV1MediaReport(SrsV1MediaReport report, String locationId) {
  for (final (Object e, StackTrace stack) in report.cleanupErrors) {
    ErrorLogService.instance.log(
      'srsMigrateV1Media.cleanup',
      StateError('srs v1 media cleanup on $locationId: $e'),
      stack,
    );
  }
  report.cleanupErrors.clear();
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
  location: srsAssetLocation(backend, store.profileUid),
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

/// 文件夹位置一轮报告的分类（[classifySrsFolderReport]）。
///
/// - `stopped`：收手了（库要关 / 位置被关掉），不是这个位置的错，下一轮接着做；
/// - `locationError`：这个位置这一轮没同步成的原因（握手没过但不是口令类问题：`meta.json` 读不到 / 位置来自
///   更新版本 / 操作同步出错）；成功、收手或口令类问题（[kSrsLocationCryptoErrors]，由
///   [SrsSyncScheduler.locationCrypto] 显示）为 null。
typedef SrsFolderRoundOutcome = ({bool stopped, String? locationError});

/// 文件夹位置一轮报告的唯一分类：诊断里的连续失败与界面上的 [SrsSyncScheduler.folderErrors] 都按它，不各写一份。
/// 口令类问题（缺口令 / 口令不对 / 加密设置不见了）是用户还没处理的配置状态，每一轮都会原样再报，不算这一轮失败——
/// 否则没配口令的位置每轮都刷一条 roundFailed 诊断、连续失败数一直涨。
SrsFolderRoundOutcome classifySrsFolderReport(SrsFolderSyncReport r) {
  if (r.ops?.error == kSrsSync2Stopped) {
    return (stopped: true, locationError: null);
  }
  final String? error = (r.crypto?.needsUpgrade ?? false)
      ? kSrsSyncNeedsUpgrade
      : r.crypto?.error;
  return (
    stopped: false,
    locationError: error != null && !kSrsLocationCryptoErrors.contains(error)
        ? error
        : null,
  );
}

/// 只提示一次的通知类别。
/// 一个位置上没法自动关联的 profile（[SrsSyncNotice.profileNotLinked]）：目录里有多个有数据的同一 profile，或本机
/// 与对方都有用户笔记（见 srs_profile_link.dart [SrsProfileLinkChoose]）。由用户选采用哪一个。
class SrsProfileConflict {
  const SrsProfileConflict({
    required this.directoryKey,
    required this.localUid,
    required this.candidates,
    required this.localHasNotes,
    this.localNoteCount = 0,
  });

  /// 冲突所在的同步位置（[SrsSyncEngine.directoryKey] 同一身份）。
  final String directoryKey;

  /// 判定时本机 profile 的 uid：冲突只属于这个 profile（用户之后切了 profile，这个冲突就不再适用）。
  final String localUid;

  /// 可以采用的 profile（按 uid 排序）。
  final List<SrsRemoteProfile> candidates;

  /// 本机 profile 有用户笔记：选定后并入，而不是直接改用。
  final bool localHasNotes;

  /// 本机 profile 的用户笔记数：弹窗里与各候选报的笔记数并排给用户对比。
  final int localNoteCount;

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

/// [SrsSyncScheduler.ensureMigrated] 迁移之前那轮只拉不发的范围：[within] 非 null = 只收调用方这一轮的那条位置；
/// 否则 [channels] 为真 = 经通道运行器收全部通道（要排通道锁）。本机目录 / 文件夹位置总是收。
typedef _SrsMigrateScope = ({SyncAssetStore? within, bool channels});

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
    bool Function(String locationId)? locationDisabled,
    Duration migratePullBudget = kSrsPullBeforeMigrateBudget,
  }) : _profileLinker = profileLinker,
       _migratePullBudget = migratePullBudget,
       _locationDisabled = locationDisabled,
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
    Future<void> Function()? onV1Bound,
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
        onFetchProgress: _reportFetchProgress,
        onUploadStart: _reportUploadStart,
        beforeUpload: (String? keyHex) =>
            _mediaBeforeUpload(backend, store, directoryKey, keyHex),
        // 每批之后看一次：位置被关 / 调度器卸下，或这一轮用的副本开始作废（换配置 / 重开，见 [_syncWithBackend]）。
        shouldStop: () => _locationStopped(directoryKey) || store.isWindingDown,
        onStep: _step,
        v1MediaMigrations: _v1Media,
        onV1Bound: onV1Bound,
      );

  /// 旧根媒体残留的后台迁移（[srsMigrateV1Media]）：不进 [_serially]，迁移期间别的位置照常同步。
  late final SrsV1MediaMigrations _v1Media = SrsV1MediaMigrations(
    // 关库 / 切 profile / 用户关掉了这个位置：排着的下一次不再起（它开头就要把两棵树整个列一遍）。
    shouldStop: _locationStopped,
    onProgress: _onV1MediaProgress,
    onReport: (String locationId, SrsV1MediaReport r) =>
        srsLogV1MediaReport(r, locationId),
    onError: (String locationId, Object e, StackTrace stack) =>
        ErrorLogService.instance.log(
          'srsMigrateV1Media',
          StateError('srs v1 media migration on $locationId: $e'),
          stack,
        ),
  );

  @visibleForTesting
  SrsV1MediaMigrations get v1MediaMigrations => _v1Media;

  /// 迁移进度：给界面（[srsMigrationProgress]，阶段 [SrsSyncStage.migrating]）与活动面包屑（进程死在迁移里时
  /// 下次启动报出死在哪、那一刻的内存）。
  void _onV1MediaProgress(SrsV1MediaProgress? p) {
    if (p == null) {
      srsMigrationProgress.value = null;
      ActivityBreadcrumb.clear(kSrsV1MigrateActivity);
      return;
    }
    srsMigrationProgress.value = SrsSyncProgress(
      stage: SrsSyncStage.migrating,
      done: p.done,
      total: p.total,
    );
    ActivityBreadcrumb.mark(
      kSrsV1MigrateActivity,
      'done=${p.done} total=${p.total} ${_memoryDescription()}',
    );
  }

  /// 后台迁移补了一批绑定：请一轮同步把它发到这个位置（发布了旧文件才能删）。排着的同一轮会被合并
  /// （[syncWithBackend]），不会越排越长；自动同步关着时不请，等用户 / 下一个触发点的那一轮。
  Future<void> _publishV1Bindings(
    SyncAssetStore backend,
    String? directoryKey,
  ) async {
    if (_halted || !await isAutoSyncEnabled()) return;
    try {
      await syncWithBackend(backend, directoryKey: directoryKey);
    } catch (e, stack) {
      ErrorLogService.instance.log('SrsSyncScheduler.publishV1', e, stack);
    }
  }

  /// 一轮的阶段进度（云盘 / 互联 / 文件夹位置三条路径共用）：拉段 + 收段按段数报、开始发件报一次、开始传媒体报一次。
  static void _reportFetchProgress(int done, int total) =>
      srsSyncProgress.value = SrsSyncProgress(
        stage: SrsSyncStage.downloading,
        done: done,
        total: total,
      );

  static void _reportUploadStart() => srsSyncProgress.value =
      const SrsSyncProgress(stage: SrsSyncStage.uploading);

  static void _reportMediaStart() =>
      srsSyncProgress.value = const SrsSyncProgress(stage: SrsSyncStage.media);

  /// 当前这一轮的细分步骤写进活动面包屑（[_trackRound] 装上、跑完卸下）：进程死在一轮里时，下次启动报
  /// 「上次进程在 srs_sync 进行中没了」带上死在哪一步、那一刻的内存（反馈 i8qNDs_V_D：大库上卡在「开始」
  /// 4.5 分钟后被系统杀，原本只知道阶段名）。
  void _step(String step) => _stepSink?.call(step);
  void Function(String step)? _stepSink;

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
    if (readMediaRoot == null || _locationStopped(key)) return;
    if (_mediaReconciledAt[key] != null &&
        _mediaReconciledContent[key] == store.contentFingerprint) {
      return;
    }
    try {
      final Directory? root = await readMediaRoot();
      if (root == null) return;
      _reportMediaStart();
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

  /// 用户关掉了复习同步的位置（按位置身份；null = 都开着）。每轮开头现读；在跑的一轮与这个位置的后台迁移在下一个
  /// 检查点也看它（[_locationStopped]），关掉之后马上收手，不等卡住的那一轮自己跑完。
  final bool Function(String locationId)? _locationDisabled;

  bool _isLocationDisabled(String locationId) =>
      _locationDisabled?.call(locationId) ?? false;

  /// [locationId] 上在跑的一轮 / 后台迁移此刻该收手：调度器卸下 / 库关着，或用户关掉了这个位置。
  bool _locationStopped(String locationId) =>
      _halted || _isLocationDisabled(locationId);

  /// 复习数据的自动同步此刻是否开着（每次触发时现读，改设置立即生效）。
  Future<bool> isAutoSyncEnabled() async =>
      await _autoSyncEnabled?.call() ?? true;

  /// 首次 v2 同步是否已确认（没确认前一轮也不跑，见 [kSrsSyncAwaitingConfirm]）。
  final bool Function() _firstSyncConfirmed;

  /// 旧库迁移之前那轮只拉不发最多等多久（[ensureMigrated]）。
  final Duration _migratePullBudget;

  /// 正在做的 [ensureMigrated]，按 store、再按**拉取范围**（[_SrsMigrateScope]）：同一范围的几条入口同时撞上只拉、
  /// 只迁移一次。范围是 future 身份的一部分，因为它决定这个 future 要等哪些锁：收全部通道的那份（[_syncAll] 开头，
  /// 锁外、队列外发起）要走 [_channels]、排通道锁；拿着通道锁 / 在 [_serially] 里的一轮去等它，就是它等锁、锁等它
  /// （以前只按 store 去重：一轮把 [_syncAll] 那份要拉全部通道的 future 拿去 await，两边互等到拉取预算到点，之后在
  /// 什么都没拉到时照常迁移，重复的操作流又出来了）。不同范围各跑各的：拉取各自做完，迁移的队列在内核里，谁先
  /// 做完谁置 [SrsDbStore.sync2Migrated]，另一份的迁移随即空转返回（[SrsDbStore.migrateLegacy]）。
  final Expando<Map<_SrsMigrateScope, Future<void>>> _migrations =
      Expando<Map<_SrsMigrateScope, Future<void>>>('srsMigrations');

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
    // 后台迁移也持着 store：在下一个文件之前看到 [_halted] 收手，等它退出。
    await _v1Media.idle();
  }

  /// 等排队的轮次与后台迁移都停下来（迁移请的发布轮又会再交一次迁移，来回直到都空）。
  @visibleForTesting
  Future<void> settle() async {
    do {
      await _tail;
      await _v1Media.idle();
      await Future<void>.delayed(Duration.zero);
    } while (_queuedRounds.isNotEmpty ||
        _queuedFolderRound != null ||
        _roundStats.values.any((SrsSyncRoundStats s) => s.running > 0) ||
        _v1Media.progress != null);
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
    final String label = _backendLabel(backend);
    final SrsSyncRoundStats stats = _statsOf(label);
    final Future<SrsSync2Report>? queued = _queuedRounds[requestKey];
    if (queued != null) {
      stats.coalesced++;
      return queued;
    }
    stats.queued++;
    late final Future<SrsSync2Report> round;
    round = _serially(() {
      if (identical(_queuedRounds[requestKey], round)) {
        _queuedRounds.remove(requestKey);
      }
      stats.queued--;
      return _trackRound(
        label,
        stats,
        () => _syncWithBackend(backend, directoryKey),
        errorOf: (SrsSync2Report r) => r.error,
        countedOf: (SrsSync2Report r) =>
            !kSrsSyncLocalStateErrors.contains(r.error) &&
            r.error != kSrsSync2Stopped,
      );
    });
    _queuedRounds[requestKey] = round;
    return round;
  }

  /// 排着还没开跑的 [syncWithBackend] 轮次（见其合并说明）。
  final Map<(SyncAssetStore, String?), Future<SrsSync2Report>> _queuedRounds =
      <(SyncAssetStore, String?), Future<SrsSync2Report>>{};

  /// 轮次统计（诊断用），按同步路径分开记：云盘 / 互联按后端类型，文件夹位置一份（[kSrsFolderRoundLabel]）。
  final Map<String, SrsSyncRoundStats> _roundStats =
      <String, SrsSyncRoundStats>{};

  SrsSyncRoundStats _statsOf(String label) =>
      _roundStats.putIfAbsent(label, SrsSyncRoundStats.new);

  static String _backendLabel(SyncAssetStore backend) =>
      backend.runtimeType.toString();

  /// [backend] 这类后端的轮次统计。
  @visibleForTesting
  SrsSyncRoundStats roundStatsFor(SyncAssetStore backend) =>
      _statsOf(_backendLabel(backend));

  /// 文件夹位置的轮次统计。
  @visibleForTesting
  SrsSyncRoundStats get folderRoundStats => _statsOf(kSrsFolderRoundLabel);

  /// 文件夹位置那条路径在面包屑 / 诊断里的后端名。
  static const String kSrsFolderRoundLabel = 'folder';

  /// 一轮的取证：开跑时**同步**写活动面包屑（后端、排队数、连续失败数、RSS），阶段变化时
  /// 覆写，跑完删掉——进程死在同步里（三次小米闪退都在补传积压期间、Dart 零日志），下次
  /// 启动 [PreviousExitLog] 会报「上次进程在 srs_sync 进行中没了」+ 当时的阶段与内存。
  /// 失败时把队列 / 失败计数 / 内存写进诊断段，随反馈上传。
  ///
  /// [stats] 是这条路径自己的统计；[errorOf] 从这一轮的结果里取错误（null = 成功），用来记连续失败。
  /// [countedOf] 为 false 的一轮（收手、本机状态没就绪、位置被关掉）既不算失败也不算成功：连续失败数原样不动。
  Future<T> _trackRound<T>(
    String backendLabel,
    SrsSyncRoundStats stats,
    Future<T> Function() body, {
    required String? Function(T result) errorOf,
    bool Function(T result)? countedOf,
  }) async {
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
    _stepSink = (String step) => ActivityBreadcrumb.mark(
      kSrsSyncActivity,
      describe('${lastStage?.name ?? 'start'}:$step'),
    );
    srsSyncProgress.addListener(onProgress);
    try {
      final T result = await body();
      final String? error = errorOf(result);
      if (!(countedOf?.call(result) ?? true)) {
        // 不计：见上。
      } else if (error == null) {
        stats.consecutiveFailures = 0;
      } else {
        _noteRoundFailure(stats, describe, 'report error: $error');
      }
      return result;
    } catch (e) {
      _noteRoundFailure(stats, describe, e);
      rethrow;
    } finally {
      srsSyncProgress.removeListener(onProgress);
      _stepSink = null;
      stats.running--;
      ActivityBreadcrumb.clear(kSrsSyncActivity);
    }
  }

  void _noteRoundFailure(
    SrsSyncRoundStats stats,
    String Function(String) describe,
    Object error,
  ) {
    final DateTime now = _clock();
    final DateTime? previous = stats.lastFailureAt;
    stats
      ..consecutiveFailures += 1
      ..lastFailureAt = now;
    ErrorLogService.instance.logDiagnostic(
      'SrsSyncScheduler.roundFailed',
      '${describe('failed')} previousFailureAt=${previous?.toIso8601String()}: '
          '$error',
    );
  }

  /// 在 [store] 上跑一轮 [_runner]。副本途中被作废（[SrsDbStore.retire]，作废已发起时在检查点收手）按收手交回
  /// （[kSrsSync2Stopped]）：已提交的片留在库里，下一轮从断点续；收段会话由作废那一刻放掉（内核回到空闲）。
  /// 跑完时副本已开始作废也按收手交回：之后的发布 / 校时 / 媒体对账都写这份副本，交给新副本那一轮去做。
  /// 作废的不是这份副本（别的错误）照常抛出。
  Future<SrsSync2Report> _runRoundOn(
    SyncAssetStore backend,
    SrsDbStore store,
    String directoryKey, {
    SrsLocationKey? locationKey,
    Future<void> Function()? onV1Bound,
  }) async {
    final SrsSync2Report report;
    try {
      report = await _runner(
        backend,
        store,
        directoryKey,
        locationKey: locationKey,
        onV1Bound: onV1Bound,
      );
    } on SrsStoreRetiredError catch (e) {
      if (!identical(e.store, store)) rethrow;
      return SrsSync2Report()..error = kSrsSync2Stopped;
    }
    if (store.isWindingDown && report.error == null) {
      report.error = kSrsSync2Stopped;
    }
    return report;
  }

  static String _memoryDescription() =>
      'rss=${ProcessInfo.currentRss >> 20}MB maxRss=${ProcessInfo.maxRss >> 20}MB';

  /// [replaced]：上一轮用的、途中被作废的副本（[_runRoundOn] 换副本重排时给）；读到的还是它就不再跑。
  Future<SrsSync2Report> _syncWithBackend(
    SyncAssetStore backend,
    String? directoryKey, {
    SrsDbStore? replaced,
  }) async {
    if (_halted) return SrsSync2Report()..error = kSrsSyncStoreUnavailable;
    if (!_firstSyncConfirmed()) {
      _noticeOnce(SrsSyncNotice.awaitingConfirm);
      return SrsSync2Report()..error = kSrsSyncAwaitingConfirm;
    }
    _step('store');
    SrsDbStore? store = await _readStore();
    if (store == null ||
        _halted ||
        identical(store, replaced) ||
        store.isWindingDown) {
      return SrsSync2Report()..error = kSrsSyncStoreUnavailable;
    }
    _step('directoryKey');
    final String? key = directoryKey ?? await _directoryKeyOf(backend);
    if (key == null) {
      // 位置身份拿不到：上传进度按身份记，换个身份只是多传一遍（段名唯一、内容不变），但宁可这轮不同步。
      return SrsSync2Report()..error = kSrsSyncDirectoryIdentityUnavailable;
    }
    if (_isLocationDisabled(key)) {
      return SrsSync2Report()..error = kSrsSyncLocationDisabled;
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
      _step('link');
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
          localNoteCount: link.localNoteCount,
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
    // 首次同步确认之后的第一轮：旧库先并成操作再上传（BUG-4011）。在一轮里只从这一条位置收（不再拿通道锁）。
    _step('migrate');
    await ensureMigrated(store, within: backend);
    if (_halted) return SrsSync2Report()..error = kSrsSyncStoreUnavailable;
    // 引擎在一轮开头写探针取服务器时间，整轮（上传 / 拉取 / 快照，大库能跑几十分钟）跑完才回来：
    final SrsLocationKey? locKey = _locationKey?.call(key);
    final SrsDbStore roundStore = store;
    final SrsSync2Report report = await _runRoundOn(
      backend,
      roundStore,
      key,
      locationKey: locKey,
      onV1Bound: () async =>
          unawaited(_publishV1Bindings(backend, directoryKey)),
    );
    if (report.error == kSrsSync2Stopped && roundStore.isWindingDown) {
      // 这一轮用的副本途中被换掉（切配置 / profile 关联重开）：已在检查点收手，之后的发布 / 校时 / 媒体对账都不在
      // 它上面做。用新副本马上重排一轮；只重排一次：新副本又在途中被换掉时按收手交回，由下一次触发接着跑。
      if (replaced == null && !_halted && !_isLocationDisabled(key)) {
        _step('storeReplaced');
        return _syncWithBackend(backend, directoryKey, replaced: roundStore);
      }
      return report;
    }
    if (_isLocationDisabled(key)) {
      // 一轮跑到一半用户关掉了这个位置：在下一个检查点收了手（[kSrsSync2Stopped]）或恰好跑完。之后的发布 / 媒体对账
      // 都不做，按「关掉」交回——立即同步不把它算成失败，也不算这个位置同步成功。
      return report..error = kSrsSyncLocationDisabled;
    }
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
    // 服务器时间与写 head 那次上传同一刻的开机时钟配对（[SrsSync2Report.serverTimeBootMs]），与这一轮跑了多久无关。
    final int? serverTime = report.serverTimeMs;
    final int? observedAt = report.serverTimeBootMs;
    if (serverTime != null && observedAt != null) {
      await store.anchorTime(serverTime, observedAtBootMs: observedAt);
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
    if (report.error == null &&
        readMediaRoot != null &&
        mediaDue &&
        !_locationStopped(key)) {
      // 完整对账跟在事件之后：先拿到引用它们的笔记与绑定，再按内容哈希补齐两边缺的文件（本机的媒体已在发段之前
      // 传过一遍，见 [_mediaBeforeUpload]）。
      // 媒体失败只记日志，不影响复习数据本身的同步结果。
      try {
        final Directory? root = await readMediaRoot();
        if (root != null) {
          _reportMediaStart();
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
  ///
  /// [onAdopted]：改用 / 并入一结束（跑「立即同步」之前）就回调结果。并入暂缓（[SrsProfileAdoptDeferred]，undo 撤销
  /// 的日志还没同步到）不是失败、不抛：并入标记已写，冲突就此解决（不再弹），之后每一轮 [SrsProfileLinker.link] 续做；
  /// 接着这一轮同步照跑，正是它把缺的日志送进来。
  Future<SrsSyncNowResult> adoptProfile(
    SrsProfileConflict conflict,
    String uid, {
    void Function(SrsProfileAdoptResult result)? onAdopted,
  }) async {
    final SrsProfileLinker? linker = _profileLinker;
    if (linker == null) return const SrsSyncNowResult(ran: 0);
    bool done = false;
    SrsProfileAdoptResult? adoptedResult;
    Future<void> adopt(SyncAssetStore? within) => _serially(() async {
      done = true;
      final SrsDbStore? store = await _readStore();
      if (store == null || _halted) return;
      if (store.profileUid != conflict.localUid) {
        throw StateError(
          'active SRS profile changed since the conflict was detected '
          '(${conflict.localUid} -> ${store.profileUid})',
        );
      }
      final SrsProfileAdoptResult result = await linker.adopt(
        store,
        uid,
        within: within,
      );
      adoptedResult = result;
      if (identical(profileConflict, conflict)) profileConflict = null;
      // 暂缓时也要清：否则冲突判定在复用期内跳过 [SrsProfileLinker.link]，并入要等复用期过了才续做。
      _linkDecided.clear();
      if (result is SrsProfileAdopted) _onDataChanged();
    });
    // 候选在某条通道上：在那条通道的锁里并入（并入之前要从它收目标 uid 的数据，BUG-4011；通道锁不可重入，先锁后
    // [_serially] 与常规轮次同一顺序）。[_channels] 把每条通道的错误收进 errors，这里原样抛出。
    Object? failure;
    StackTrace? failureStack;
    await _channels((SyncAssetStore backend) async {
      if (done || await _directoryKeyOf(backend) != conflict.directoryKey) {
        return;
      }
      try {
        await adopt(backend);
      } catch (e, stack) {
        failure = e;
        failureStack = stack;
      }
    });
    final Object? error = failure;
    if (error != null) Error.throwWithStackTrace(error, failureStack!);
    // 候选在本机目录 / 文件夹位置上（或那条通道此刻不可用）：不拿通道锁并入。
    if (!done) await adopt(null);
    final SrsProfileAdoptResult? result = adoptedResult;
    if (result != null) onAdopted?.call(result);
    return syncNow();
  }

  /// 当前 profile 正在暂缓的并入（[SrsProfileLinker.deferredMerge]：并入标记还在、最近一次重跑是暂缓）；没有、没配
  /// linker 或 store 不可用时为 null。并入做完后自动回到 null。同步状态页按它显示「profile 合并暂缓中」。
  Future<SrsDeferredProfileMerge?> deferredProfileMerge() async {
    final SrsProfileLinker? linker = _profileLinker;
    if (linker == null || _halted) return null;
    final SrsDbStore? store = await _readStore();
    if (store == null || store.isWindingDown) return null;
    return linker.deferredMerge(store);
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
    // 首次同步确认之后（复习页弹框「开始同步」接着就是这一轮）：旧库在任何一轮上传之前并成操作，迁移前从全部
    // 位置先收一轮（这里还没拿通道锁、也不在 [_serially] 里，可以走 [_channels]；见 [ensureMigrated]）。
    if (_firstSyncConfirmed()) {
      final SrsDbStore? store = await _readStore();
      if (store != null && !_halted) await ensureMigrated(store);
    }
    if (fullMediaReconcile) _mediaReconciledAt.clear();
    _linkDecided.removeWhere(
      (String _, ({DateTime at, SrsProfileConflict? conflict}) d) =>
          d.conflict != null,
    );
    // 通道跑完、但报告带错的轮次（runner 已把它记成跑成功）：关掉的位置只扣数、不算错。
    int notSynced = 0;
    final List<Object> errors = <Object>[];
    final ({int ran, List<Object> errors}) channels = await _channels((
      SyncAssetStore backend,
    ) async {
      final String? error = (await syncWithBackend(backend)).error;
      if (error != null) {
        notSynced++;
        if (error != kSrsSyncLocationDisabled) {
          errors.add(SrsSyncReportError(error));
        }
      }
    });
    errors.addAll(channels.errors);
    final SrsSyncNowResult local = await syncLocalDirectories();
    errors.addAll(local.errors);
    final SrsSyncNowResult folders = await syncFolderLocations();
    errors.addAll(folders.errors);
    return SrsSyncNowResult(
      ran: channels.ran - notSynced + local.ran + folders.ran,
      errors: errors,
    );
  }

  /// 跑用户加的文件夹存储位置（设计 §6.5：U 盘 / NAS / 被别的同步工具同步的目录）。文件夹此刻不在
  /// （U 盘没插）只记进 [folderErrors]，不算这轮「立即同步」失败——它是可选的冗余副本。
  ///
  /// **排队中的请求合并**（同 [syncWithBackend]，PR #2768 审查）：文件夹位置的后台迁移每补一批绑定就请一轮把它发出去，
  /// 本地文件夹一批几百个文件转眼就做完，以前每次都往 [_serially] 的 FIFO 里追加一整轮（对所有文件夹位置跑同步 +
  /// 完整媒体对账），大库排上百轮，又把通道与互联 host 目录的轮次堵在后面。已有一轮**排着还没开跑**就复用它：那一轮
  /// 开跑时会看到此刻之前补上的全部绑定。已经开跑的不复用（它可能已经过了取发件箱那一步）。
  Future<SrsSyncNowResult> syncFolderLocations() {
    final SrsSyncRoundStats stats = folderRoundStats;
    final Future<SrsSyncNowResult>? queued = _queuedFolderRound;
    if (queued != null) {
      stats.coalesced++;
      return queued;
    }
    stats.queued++;
    late final Future<SrsSyncNowResult> round;
    round = _serially(() {
      if (identical(_queuedFolderRound, round)) _queuedFolderRound = null;
      stats.queued--;
      return _syncFolderLocations();
    });
    _queuedFolderRound = round;
    return round;
  }

  /// 排着还没开跑的 [syncFolderLocations]（见其合并说明）。
  Future<SrsSyncNowResult>? _queuedFolderRound;

  Future<SrsSyncNowResult> _syncFolderLocations() async {
    final Future<List<SrsFolderLocation>> Function()? read = _folderLocations;
    if (read == null || _halted || !_firstSyncConfirmed()) {
      return const SrsSyncNowResult(ran: 0);
    }
    final SrsDbStore? store = await _readStore();
    if (store == null || _halted) return const SrsSyncNowResult(ran: 0);
    // 旧库先并成操作再同步（[ensureMigrated]；这里在 [_serially] 里，不拿通道锁）。
    await ensureMigrated(store, channels: false);
    if (_halted) return const SrsSyncNowResult(ran: 0);
    final Directory? mediaRoot = await _readMediaRoot?.call();
    int ran = 0;
    bool changed = false;
    for (final SrsFolderLocation l in await read()) {
      if (l.idle || _locationStopped(l.locationId)) continue;
      try {
        // 每个位置从「准备」重新报起；进度 / 面包屑与云盘、互联那条路径同一套（以前这里一个都不接：大库首次从
        // 文件夹收几百个段跑好几分钟，界面全程停在「正在准备」，进程死在里面也不留面包屑）。
        srsSyncProgress.value = const SrsSyncProgress();
        // 分类只做一次（[classifySrsFolderReport]）：诊断的连续失败与下面的界面分流用同一个结论。
        final (
          SrsFolderSyncReport r,
          SrsFolderRoundOutcome outcome,
        ) = await _trackRound(
          kSrsFolderRoundLabel,
          folderRoundStats,
          () async {
            await srsPublishDeviceInfo(store);
            final SrsFolderSyncReport report = await srsSyncFolderLocation(
              location: l,
              store: store,
              mediaRoot: mediaRoot,
              key: _locationKey?.call(l.locationId),
              migrationMemo: _srsMigrationMemo,
              v1MediaMigrations: _v1Media,
              onV1Bound: () async => unawaited(_publishFolderV1Bindings()),
              onFetchProgress: _reportFetchProgress,
              onUploadStart: _reportUploadStart,
              onMediaStart: _reportMediaStart,
              shouldStop: () =>
                  _locationStopped(l.locationId) || store.isWindingDown,
              onStep: _step,
            );
            return (report, classifySrsFolderReport(report));
          },
          errorOf: ((SrsFolderSyncReport, SrsFolderRoundOutcome) x) =>
              x.$2.locationError,
          countedOf: ((SrsFolderSyncReport, SrsFolderRoundOutcome) x) =>
              !x.$2.stopped,
        );
        final SrsLocationPrepared? prepared = r.prepared;
        if (prepared != null) {
          srsLogMigrationLeftover(prepared, l.locationId);
        }
        if (outcome.stopped) continue;
        await _noteCrypto(l.locationId, r.crypto);
        _noteMediaKey(l.locationId, r.media);
        // 口令类问题不进 folderErrors，由 [locationCrypto] 显示（需要口令 / 口令不对 / 加密设置不见了）。
        final String? error = outcome.locationError;
        if (error != null) {
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
  }

  /// 文件夹位置的后台迁移补了一批绑定：请一轮把它发出去（同 [_publishV1Bindings]）。
  Future<void> _publishFolderV1Bindings() async {
    if (_halted || !await isAutoSyncEnabled()) return;
    try {
      await syncFolderLocations();
    } catch (e, stack) {
      ErrorLogService.instance.log('SrsSyncScheduler.publishV1', e, stack);
    }
  }

  /// 推迟的旧库迁移（BUG-4011；app 打开 store 时 `deferMigration`，srs_providers.dart）：**首次同步确认之前不迁移、
  /// 也不拉**（用户拍板：弹框没回答前什么都不做，选「稍后」同样不做）；确认之后、第一轮上传之前，先从已配置的同步
  /// 位置只拉不发收一轮（[pullInto]，最多等 [_migratePullBudget]），再迁移——迁移只包还没有任何设备的操作代表的
  /// 旧行，第二台设备就只补差，不再把同一份旧库整个再包一遍。已迁移时立即返回（每个 profile 一生一次）。
  ///
  /// 拉取出错 / 到点只记日志、照常迁移（之后靠收敛合并）；迁移本身出错原样抛给这一轮（这一轮不上传）。
  ///
  /// [within]：调用方正在跑这条位置的一轮（[_syncWithBackend]，在 [_serially] 里、可能还拿着通道锁）：只从它和
  /// 本机目录 / 文件夹位置收，不走 [_channels]（通道锁不可重入，[_serially] 也会和锁里排队的轮次互等）。
  /// [channels] 为假：同样不走 [_channels]（文件夹位置那一轮）。只有 [_syncAll] 开头（锁外、队列外）收全部通道。
  ///
  /// 去重按拉取范围（[_migrations]）：持锁 / 在队列里的调用方永远不会拿到一份要排通道锁的 future，各自只等自己
  /// 那份（它只拉调用方已经握着的位置），不形成锁依赖环。
  Future<void> ensureMigrated(
    SrsDbStore store, {
    SyncAssetStore? within,
    bool channels = true,
  }) {
    if (store.sync2Migrated || _halted || !_firstSyncConfirmed()) {
      return Future<void>.value();
    }
    final Map<_SrsMigrateScope, Future<void>> running = _migrations[store] ??=
        <_SrsMigrateScope, Future<void>>{};
    // [within] 给出时 [pullInto] 不看 [channels]：同一个范围。
    final _SrsMigrateScope scope = (
      within: within,
      channels: within == null && channels,
    );
    final Future<void>? same = running[scope];
    if (same != null) return same;
    final Future<void> f = () async {
      try {
        await store.migrateLegacy(
          beforeMigrate: (SrsDbStore s) async {
            try {
              await pullInto(
                s,
                budget: _migratePullBudget,
                purpose: 'migrate',
                within: within,
                channels: channels,
              );
            } catch (e, stack) {
              // 拉取出错不挡迁移（照常迁移，靠收敛合并），但必须留日志。
              ErrorLogService.instance.log(
                'SrsSyncScheduler.ensureMigrated.pull',
                e,
                stack,
              );
            }
          },
        );
      } finally {
        running.remove(scope);
      }
    }();
    running[scope] = f;
    return f;
  }

  /// 只拉不发（BUG-4011，sync2/srs_sync2_pull_first.dart）：把已配置的同步位置（云盘 / 互联通道、本机目录、
  /// 文件夹位置）上 [store] 这个 profile 已有的操作收进 [store]，最多等 [budget]。两个用处：
  /// - 本机旧库迁移之前（[ensureMigrated]）：迁移只包还没有任何设备的操作代表的旧行，先收到别的设备迁出的那份，
  ///   第二台设备就只补差；
  /// - 档案合并之前（[SrsDbProfileLinker.pullBeforeMerge]，在那条位置的一轮里，[within] 给出它）：目标 uid 的数据
  ///   先在本机，合并沿用目标的写入者。
  ///
  /// 通道：[within] 非 null = 只收这一条（调用方正在它的一轮里）；否则 [channels] 为真才经 [_channels] 收全部
  /// （通道锁不可重入：只能在锁外、[_serially] 外这样调）。不写位置、不做 profile 关联、不对账媒体。首次同步没确认 /
  /// 库关着时不拉（与常规同步同一道门）；关掉的位置跳过。每个位置失败都记日志、接着拉下一个；到点没拉完记一条
  /// 诊断，已收的照用。
  Future<void> pullInto(
    SrsDbStore store, {
    required Duration budget,
    required String purpose,
    SyncAssetStore? within,
    bool channels = true,
  }) async {
    if (_halted || !_firstSyncConfirmed()) return;
    void log(Object e, StackTrace stack) => ErrorLogService.instance.log(
      'SrsSyncScheduler.pullInto.$purpose',
      e,
      stack,
    );
    final Stopwatch watch = Stopwatch()..start();
    int pulled = 0;
    final bool done = await srsSync2PullWithin(
      store,
      (SrsSync2Host host) async {
        final Set<String> seen = <String>{};
        Future<void> one(
          String locationId,
          SrsLocationStore Function() location,
        ) async {
          if (!seen.add(locationId) || _locationStopped(locationId)) return;
          try {
            final SrsSync2Report r = await srsSync2PullOnly(
              host: host,
              location: location(),
              locationId: locationId,
              nowMs: () => store.now().$1,
              key: _locationKey?.call(locationId),
              shouldStop: () => _locationStopped(locationId),
            );
            pulled += r.applied;
            if (r.needsUpgrade || r.error != null) {
              ErrorLogService.instance.logDiagnostic(
                'SrsSyncScheduler.pullInto.$purpose',
                'location $locationId not pulled: '
                    '${r.needsUpgrade ? kSrsSyncNeedsUpgrade : r.error}',
              );
            }
          } on SrsSync2PullClosed {
            rethrow;
          } catch (e, stack) {
            log(e, stack);
          }
        }

        final SyncAssetStore? current = within;
        if (current != null) {
          final String? key = await _directoryKeyOf(current);
          if (key != null) {
            await one(key, () => srsAssetLocation(current, store.profileUid));
          }
        } else if (channels) {
          final ({int ran, List<Object> errors}) all = await _channels((
            SyncAssetStore backend,
          ) async {
            final String? key = await _directoryKeyOf(backend);
            if (key == null) return;
            await one(key, () => srsAssetLocation(backend, store.profileUid));
          });
          for (final Object e in all.errors) {
            if (e is! SrsSync2PullClosed) log(e, StackTrace.current);
          }
        }
        final Future<List<SrsLocalDirectory>> Function()? local =
            _localDirectories;
        if (local != null) {
          for (final SrsLocalDirectory d in await local()) {
            await one(
              d.directoryKey,
              () => srsAssetLocation(d.store, store.profileUid),
            );
          }
        }
        final Future<List<SrsFolderLocation>> Function()? folders =
            _folderLocations;
        if (folders != null) {
          for (final SrsFolderLocation l in await folders()) {
            if (!l.sync || !Directory(l.path).existsSync()) continue;
            await one(
              l.locationId,
              () => SrsDirectoryLocationStore(
                srsFolderCollectionRoot(l, store.profileUid),
              ),
            );
          }
        }
      },
      budget: budget,
      onError: log,
    );
    if (!done) {
      ErrorLogService.instance.logDiagnostic(
        'SrsSyncScheduler.pullInto.$purpose',
        'budget ${budget.inSeconds}s over after ${watch.elapsedMilliseconds} ms '
            '(applied $pulled); continuing with what was pulled',
      );
    }
  }

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
        if (error == kSrsSyncLocationDisabled) continue;
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
