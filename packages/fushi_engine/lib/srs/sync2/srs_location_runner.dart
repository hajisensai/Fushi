/// 一个同步位置上跑一轮复习同步 v2 / 一轮媒体同步的生产实现，app 与无头服务端共用。
///
/// 从 app 的 `srs_sync_scheduler.dart` 平移来：位置的后端身份 / 并发写上限是 app 的云盘细节（Dropbox 逐个写、
/// 防扫盘混淆包一层），由调用方经 [SrsLocationBackend] 传进来；本机设备信息怎么取（型号 / 版本）也由调用方给。
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_engine/srs/srs_media_sync.dart';
import 'package:fushi_engine/srs/sync2/srs_location_crypto.dart';
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
    locationDir: dir,
    folder: folder,
    maxConcurrentWrites: maxConcurrentWrites,
    backendIdentity: identity,
  );
}

/// 这个 profile 的集合在同步位置上的目录名（`fushi-srs/<dir>/`）：内核 `identity` 回包的 `dir`（设计 §5.1），不再按
/// profile uid 拼——并入别的集合 / 采用对方集合之后两者不同。
Future<String> srsLocationDir(SrsDbStore store) async =>
    (await store.sync2Command(<String, Object?>{
          'op': 'identity',
          'now': store.now().$1,
        })).map['dir']!
        as String;

/// 现有同步后端上的集合目录（`fushi-srs/<dir>/`）跑一轮复习同步：新根 `v4/` 收发；旧根 `v3/` 的 `meta.json` 改写成让
/// 协议 3 的版本停下的围栏（内核 `location_root`，G8-7），旧根上的段收进本机承袭日志（旧根接手，G8-7b）。
/// [directoryKey] 就是这个位置的稳定身份（本机按它记每个位置传到了哪）。[publishDeviceInfo] = 本机型号 / 版本 / 平台
/// 随这一轮的 head 发布。
///
/// 只有协议 1 旧根 `v2/` 的位置内核明确拒绝（D21，`srs_location_protocol1_root`），不再一次性迁移（以前的
/// `srsPrepareLocation` 按协议 3 的命令写 `v3/`，会拆掉围栏）；v1 媒体搬家同样不跑，两者的装配已删（第五波）。
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
}) async {
  final String dir = await srsLocationDir(store);
  if (publishDeviceInfo != null) await publishDeviceInfo(store);
  final SrsSync2Report r = await srsSync2Round(
    host: store,
    location: backend.location(dir, folder: kSrs4Root),
    oldRoot: backend.location(dir),
    protocol1Root: backend.location(dir, folder: kSrsSync2V1Folder),
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

/// 一轮媒体同步：见 srs_media_sync.dart。[uploadOnly] = 发段之前只传本机的媒体（[srsSyncMedia]）。媒体在哪个根由
/// 新根 `v4/meta.json` 的 `media` 定（存量集合 `v3`、新集合 `v4`，内核 `location_root` 写定，[srsLocationMediaFolder]）。
Future<SrsMediaSyncReport> srsRunLocationMedia(
  SrsLocationBackend backend,
  SrsDbStore store,
  Directory mediaRoot, {
  SrsMediaCipher? cipher,
  required String locationId,
  bool uploadOnly = false,
  void Function(int done, int total)? onProgress,
  bool Function()? deferRemaining,
}) async {
  final String dir = await srsLocationDir(store);
  return srsSyncMedia(
    cipher: cipher,
    locationId: locationId,
    uploadOnly: uploadOnly,
    onProgress: onProgress,
    deferRemaining: deferRemaining,
    location: backend.location(
      dir,
      folder: await srsLocationMediaFolder(
        backend.location(dir, folder: kSrs4Root),
      ),
    ),
    store: store,
    mediaRoot: mediaRoot,
  );
}

/// 位置上媒体所在的根目录名：新根 [root4] 的 `meta.json` 的 `media`（只认 `v3` / `v4`）。新根 meta 只由一轮同步的
/// `location_root` 写，媒体同步总在它之后跑；读不到或认不得就报错（不猜，猜错会把媒体写进被围栏的旧根或反过来）。
Future<String> srsLocationMediaFolder(SrsLocationStore root4) async {
  final Uint8List? meta = await root4.get('meta.json');
  if (meta == null) {
    throw StateError('srs media: the location has no v4/meta.json yet');
  }
  final Object? media = (jsonDecode(utf8.decode(meta)) as Map)['media'];
  if (media != kSrsSync2Folder && media != kSrs4Root) {
    throw StateError('srs media: unknown media root $media in v4/meta.json');
  }
  return media! as String;
}
