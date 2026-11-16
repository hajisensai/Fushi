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

  /// [store] 上 `fushi-srs/<dir>/<folder>/` 的位置实例（[dir] = 集合的位置目录名，[srsLocationDir]）。
  SrsAssetLocationStore location(
    String dir, {
    String folder = kSrsSync2Folder,
  }) => SrsAssetLocationStore(
    store: store,
    profileUid: dir,
    folder: folder,
    maxConcurrentWrites: maxConcurrentWrites,
    backendIdentity: identity,
  );
}

/// 本进程里已经确认旧集合根扫干净的位置（进程重启后的第一轮再扫一遍，接住围栏那一刻还在跑的旧版本晚到的写入）。
final SrsLocationMigrationMemo srsLocationMigrationMemo =
    SrsLocationMigrationMemo();

/// 这个 profile 的集合在同步位置上的目录名（`fushi-srs/<dir>/`）：内核 `identity` 回包的 `dir`（设计 §5.1），不再按
/// profile uid 拼——并入别的集合 / 采用对方集合之后两者不同。
Future<String> srsLocationDir(SrsDbStore store) async =>
    (await store.sync2Command(<String, Object?>{
          'op': 'identity',
          'now': store.now().$1,
        })).map['dir']!
        as String;

/// 现有同步后端上的集合目录（`fushi-srs/<dir>/`）跑一轮复习同步：新根 `v4/` 收发，旧根 `v3/` 只读它的 `meta.json`
/// 并改写成让协议 3 的版本停下的围栏（内核 `location_root`，G8-7）。[directoryKey] 就是这个位置的稳定身份（本机按它
/// 记每个位置传到了哪）。[publishDeviceInfo] = 本机型号 / 版本 / 平台随这一轮的 head 发布。
///
/// 协议 1 旧根 `v2/` 的一次性迁移（[srsPrepareLocation]）与 v1 媒体搬家不再在这里跑：它们按协议 3 的命令写新根，
/// 新代的旧根接手（`oldroot.rs`）还没接线（交接说明「G8-7 同步一轮」未做项）。[v1MediaMigrations] / [onV1Bound]
/// 保留参数形状，暂不使用。
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
  final String dir = await srsLocationDir(store);
  if (publishDeviceInfo != null) await publishDeviceInfo(store);
  final SrsSync2Report r = await srsSync2Round(
    host: store,
    location: backend.location(dir, folder: kSrs4Root),
    oldRoot: backend.location(dir),
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

/// 一轮媒体同步：见 srs_media_sync.dart。[uploadOnly] = 发段之前只传本机的媒体（[srsSyncMedia]）。媒体仍在旧根
/// `v3/` 下（存量集合的新根 meta 记 `media: v3`）；新代的媒体命令归 G8-7b，接上之前这一步报未接线。
Future<SrsMediaSyncReport> srsRunLocationMedia(
  SrsLocationBackend backend,
  SrsDbStore store,
  Directory mediaRoot, {
  SrsMediaCipher? cipher,
  required String locationId,
  bool uploadOnly = false,
}) async => srsSyncMedia(
  cipher: cipher,
  locationId: locationId,
  uploadOnly: uploadOnly,
  location: backend.location(await srsLocationDir(store)),
  store: store,
  mediaRoot: mediaRoot,
);
