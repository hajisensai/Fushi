/// 一个同步位置上跑一轮复习同步 v2 / 一轮媒体同步的生产实现，app 与无头服务端共用。
///
/// 从 app 的 `srs_sync_scheduler.dart` 平移来：位置的后端身份 / 并发写上限是 app 的云盘细节（Dropbox 逐个写、
/// 防扫盘混淆包一层），由调用方经 [SrsLocationBackend] 传进来；本机设备信息怎么取（型号 / 版本）也由调用方给。
library;

import 'dart:io';

import 'package:fushi_engine/foundation/engine_log.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_engine/srs/srs_media_sync.dart';
import 'package:fushi_engine/srs/sync2/srs_location_crypto.dart';
import 'package:fushi_engine/srs/sync2/srs_location_migration.dart';
import 'package:fushi_engine/srs/sync2/srs_location_store.dart';
import 'package:fushi_engine/srs/sync2/srs_sync2_round.dart';
import 'package:fushi_engine/sync/sync_asset_store.dart';

/// 同步数据来自更新版本的 Fushi（这一轮不同步该位置）。
const String kSrsSyncNeedsUpgrade = 'srs sync data needs a newer app';

/// 一个同步后端 + 它在 [SrsAssetLocationStore] 里的身份与并发写上限。
class SrsLocationBackend {
  const SrsLocationBackend(
    this.store, {
    this.maxConcurrentWrites,
    Object? identity,
  }) : _identity = identity;

  final SyncAssetStore store;

  /// 同时在途的写 / 删上限；null = 不限。
  final int? maxConcurrentWrites;

  final Object? _identity;

  /// 进程内建文件夹单飞按它认（包装后端传里层）；默认就是 [store] 本身。
  Object get identity => _identity ?? store;

  /// [store] 上 `fushi-srs/<profileUid>/<folder>/` 的位置实例。
  SrsAssetLocationStore location(
    String profileUid, {
    String folder = kSrsSync2Folder,
  }) => SrsAssetLocationStore(
    store: store,
    profileUid: profileUid,
    folder: folder,
    maxConcurrentWrites: maxConcurrentWrites,
    backendIdentity: identity,
  );
}

/// 本进程里已经确认旧集合根扫干净的位置（进程重启后的第一轮再扫一遍，接住围栏那一刻还在跑的旧版本晚到的写入）。
final SrsLocationMigrationMemo srsLocationMigrationMemo =
    SrsLocationMigrationMemo();

/// 现有同步后端上的集合根（`fushi-srs/<profileUid>/v3/`）跑一轮同步 v2。先 [srsPrepareLocation]：立住旧根 `v2/`
/// 上让旧版本停下的围栏，旧根上的设备段迁过来。[directoryKey] 就是这个位置的稳定身份（本机按它记每个位置传到了哪）。
///
/// 一轮成功之后旧根还有媒体残留：交给 [v1MediaMigrations] 在后台搬（[srsMigrateV1Media]，不挡这一轮；
/// [onV1Bound] = 补了绑定、请一轮同步把它发出去）；没给就在这一轮里搬。[publishDeviceInfo] = 本机型号 / 版本 /
/// 平台随这一轮的 head 发布（别的设备据此认出这台设备）。
Future<SrsSync2Report> srsRunLocationRound(
  SrsLocationBackend backend,
  SrsDbStore store,
  String directoryKey, {
  SrsLocationKey? locationKey,
  Future<void> Function(SrsDbStore store)? publishDeviceInfo,
  void Function(int done, int total)? onFetchProgress,
  void Function()? onUploadStart,
  Future<void> Function(String? keyHex)? beforeUpload,
  bool Function()? shouldStop,
  SrsSyncStepCallback? onStep,
  SrsV1MediaMigrations? v1MediaMigrations,
  Future<void> Function()? onV1Bound,
}) async {
  SrsLocationStore currentRoot() => backend.location(store.profileUid);
  SrsLocationStore v1Root() =>
      backend.location(store.profileUid, folder: kSrsSync2V1Folder);
  final SrsLocationStore location = currentRoot();
  final SrsLocationPrepared prepared = await srsPrepareLocation(
    host: store,
    v1: v1Root(),
    current: location,
    locationId: directoryKey,
    key: locationKey,
    nowMs: () => store.now().$1,
    writers: SrsAssetV1Writers(backend.store, store.profileUid),
    memo: srsLocationMigrationMemo,
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
  if (publishDeviceInfo != null) await publishDeviceInfo(store);
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
          writers: SrsAssetV1Writers(backend.store, store.profileUid),
          memo: srsLocationMigrationMemo,
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
  engineLog.log(
    'srsPrepareLocation',
    StateError('srs v1 leftovers on $locationId: $leftover'),
    prepared.leftoverStack ?? StackTrace.current,
  );
}

/// 旧根媒体迁移删旧文件时逐个出的错：那些文件留着下一次再删，同步照样算成功，但每个错都记日志。
void srsLogV1MediaReport(SrsV1MediaReport report, String locationId) {
  for (final (Object e, StackTrace stack) in report.cleanupErrors) {
    engineLog.log(
      'srsMigrateV1Media.cleanup',
      StateError('srs v1 media cleanup on $locationId: $e'),
      stack,
    );
  }
  report.cleanupErrors.clear();
}

/// 一轮媒体同步：见 srs_media_sync.dart。[uploadOnly] = 发段之前只传本机的媒体（[srsSyncMedia]）。
Future<SrsMediaSyncReport> srsRunLocationMedia(
  SrsLocationBackend backend,
  SrsDbStore store,
  Directory mediaRoot, {
  SrsMediaCipher? cipher,
  required String locationId,
  bool uploadOnly = false,
}) => srsSyncMedia(
  cipher: cipher,
  locationId: locationId,
  uploadOnly: uploadOnly,
  location: backend.location(store.profileUid),
  store: store,
  mediaRoot: mediaRoot,
);
