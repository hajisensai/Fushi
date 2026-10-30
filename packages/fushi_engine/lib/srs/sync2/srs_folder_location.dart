/// 用户自己加的「文件夹」存储位置（docs/specs/2026-10-25-srs-sync-v2-design.md §6.5、§10.3）。
///
/// 已有的同步通道（云盘 / 互联）各自就是一个同步 + 媒体位置；这里补上设计里的「＋ 本地文件夹」：U 盘、NAS 挂载点、
/// 被别的同步工具（Syncthing 等）同步的目录。每个位置有三种用途，可多选：
/// - **同步**：收发操作段（与云盘通道同一协议、同一目录布局）；
/// - **媒体**：镜像媒体文件，按 90 天保留期清理；
/// - **归档**：接收全部段 / head / 媒体，**永不删除任何东西**（不清旧 head、不清媒体；只有用户确认的
///   彻底清除会重写段），默认不开。
///
/// 目录布局与云盘的集合根相同（`<文件夹>/fushi-srs/<profileUid>/v3/`），所以归档位置随时能改成同步位置直接用。
/// 协议 1 的旧根 `v2/` 只剩围栏（srs_location_migration.dart）：每一轮先 [srsPrepareLocation]，旧根上有数据就迁过来。
library;

import 'dart:io';

import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_engine/srs/srs_media_sync.dart';
import 'package:fushi_engine/srs/sync2/srs_location_crypto.dart';
import 'package:fushi_engine/srs/sync2/srs_location_migration.dart';
import 'package:fushi_engine/srs/sync2/srs_location_store.dart';
import 'package:fushi_engine/srs/sync2/srs_sync2_round.dart';
import 'package:path/path.dart' as p;

/// 一个文件夹位置的配置（设备本地：路径只在这台设备上有意义）。
class SrsFolderLocation {
  const SrsFolderLocation({
    required this.id,
    required this.path,
    this.sync = true,
    this.media = true,
    this.archive = false,
  });

  factory SrsFolderLocation.fromJson(Map<String, Object?> j) =>
      SrsFolderLocation(
        id: j['id'] as String? ?? '',
        path: j['path'] as String? ?? '',
        sync: j['sync'] as bool? ?? true,
        media: j['media'] as bool? ?? true,
        archive: j['archive'] as bool? ?? false,
      );

  /// 稳定身份（本机按 `folder:<id>` 记这个位置传到了哪）。
  final String id;
  final String path;
  final bool sync;
  final bool media;
  final bool archive;

  /// 本机记上传进度用的位置身份。
  String get locationId => 'folder:$id';

  /// 一个用途都没勾：保留配置但不跑（取消用途不删文件）。
  bool get idle => !sync && !media && !archive;

  SrsFolderLocation copyWith({bool? sync, bool? media, bool? archive}) =>
      SrsFolderLocation(
        id: id,
        path: path,
        sync: sync ?? this.sync,
        media: media ?? this.media,
        archive: archive ?? this.archive,
      );

  Map<String, Object?> toJson() => <String, Object?>{
    'id': id,
    'path': path,
    'sync': sync,
    'media': media,
    'archive': archive,
  };
}

/// [location] 在磁盘上的集合根（`<文件夹>/fushi-srs/<profileUid>/v3/`）。
Directory srsFolderCollectionRoot(
  SrsFolderLocation location,
  String profileUid,
) => Directory(
  p.join(location.path, kSrsSync2Namespace, profileUid, kSrsSync2Folder),
);

/// [location] 上协议 1 的旧集合根（`<文件夹>/fushi-srs/<profileUid>/v2/`，迁移之后只剩围栏）。
Directory srsFolderV1CollectionRoot(
  SrsFolderLocation location,
  String profileUid,
) => Directory(
  p.join(location.path, kSrsSync2Namespace, profileUid, kSrsSync2V1Folder),
);

/// 一个文件夹位置这一轮的结果（[ops] 里带加密握手的结论：kdf / encryptionEnabled / 口令错误）。
class SrsFolderSyncReport {
  SrsFolderSyncReport({this.ops, this.media, this.handshake, this.prepared});

  /// 操作同步这一轮的结果（只做媒体的位置：握手没过时带着错误，否则为 null）。
  final SrsSync2Report? ops;
  final SrsMediaSyncReport? media;

  /// 只做媒体的位置的 `meta.json` 握手结论（kdf / 本机刚开的加密已写上 / 用没用密钥）。
  final SrsSync2Report? handshake;

  /// 这一轮开头的位置准备 / v1 迁移结论（[srsPrepareLocation]）。
  final SrsLocationPrepared? prepared;

  /// 这个位置这一轮的加密结论（调度器据此记加密状态、把本机刚开的加密标成已生效）。
  SrsSync2Report? get crypto => ops ?? handshake;
}

/// 对一个文件夹位置跑一轮：同步 / 归档用途跑操作同步，媒体 / 归档用途跑媒体镜像。文件夹不在（U 盘没插）时
/// 抛 [FileSystemException]，调用方记一次、下次再试。
Future<SrsFolderSyncReport> srsSyncFolderLocation({
  required SrsFolderLocation location,
  required SrsDbStore store,
  Directory? mediaRoot,
  SrsLocationKey? key,
  SrsLocationMigrationMemo? migrationMemo,
}) async {
  if (location.idle) return SrsFolderSyncReport();
  if (!Directory(location.path).existsSync()) {
    throw FileSystemException('storage location not available', location.path);
  }
  final SrsLocationStore root = SrsDirectoryLocationStore(
    srsFolderCollectionRoot(location, store.profileUid),
  );
  final Directory v1Dir = srsFolderV1CollectionRoot(location, store.profileUid);
  // 先立围栏、迁走 v1 数据（每一轮都做：旧版本绝不能在旧根上重新建一个 v1 集合）。没过的（口令 / 更新的版本 /
  // meta 读不到）整个位置都不碰，结论照握手的样子交回。
  final SrsLocationPrepared prepared = await srsPrepareLocation(
    host: store,
    v1: SrsDirectoryLocationStore(v1Dir),
    current: root,
    locationId: location.locationId,
    key: key,
    nowMs: () => store.now().$1,
    v1PlainMediaFolder: kSrsV1FolderMediaMoved,
    fenceFolderMedia: () => srsFenceV1FolderMedia(v1Dir),
    removeEmptyDirs: () => srsRemoveEmptyV1FolderDirs(v1Dir),
    memo: migrationMemo,
    archive: location.archive,
  );
  if (prepared.needsUpgrade || prepared.error != null) {
    return SrsFolderSyncReport(
      ops: SrsSync2Report()
        ..needsUpgrade = prepared.needsUpgrade
        ..error = prepared.error
        ..kdf = prepared.kdf,
      prepared: prepared,
    );
  }
  SrsSync2Report? ops;
  // 发段之前那一步传上去的媒体数（并进下面完整对账的结果）。
  int uploadedEarly = 0;
  if (location.sync || location.archive) {
    ops = await srsSync2Round(
      host: store,
      location: root,
      locationId: location.locationId,
      nowMs: () => store.now().$1,
      key: key,
      // 勾了归档就一个旧 head 也不删（归档位置永不删除，§10.3）。
      archive: location.archive,
      // 媒体先于引用它的段（设计 §6.1 写入纪律 3，审查 S-10）：发段之前先把本机的媒体传上去。这一步出错不拦操作
      // 同步——同一个错误在下面的完整媒体对账里照样抛给调用方。
      beforeUpload: mediaRoot != null && (location.media || location.archive)
          ? (String? keyHex) async {
              try {
                uploadedEarly += (await srsSyncMedia(
                  location: root,
                  store: store,
                  mediaRoot: mediaRoot,
                  archive: location.archive,
                  cipher: keyHex == null ? null : SrsMediaCipher(store, keyHex),
                  uploadOnly: true,
                )).uploaded;
              } on FileSystemException {
                // 见上：完整对账会再报。
              }
            }
          : null,
    );
    // 加密位置口令不对 / 没有：媒体也不碰（明文媒体不能写进加密位置）。位置来自更新版本（`minReader` 比本机新）
    // 同样整个位置都不碰：以前这里只看 error，needsUpgrade 时照样按明文跑媒体对账（往 `media/` 写、按过期清），
    // 旧版本就不能靠提高最低读者版本把自己挡在新格式的位置之外。
    if (ops.error != null || ops.needsUpgrade) {
      return SrsFolderSyncReport(ops: ops, prepared: prepared);
    }
  }
  String? mediaKey = (ops?.encrypted ?? false) ? key!.keyHex : null;
  SrsSync2Report? handshake;
  if (ops == null && mediaRoot != null && location.media) {
    // 只做媒体的位置：同一份 meta.json 握手（本机开过加密而位置上 kdf 不见了同样停下，不传明文媒体；本机刚开
    // 加密也在这里把 kdf 写上）。
    final SrsLocationHandshake h = await srsLocationHandshake(
      root,
      key: key,
      collection: (await store.sync2Command(<String, Object?>{
        'op': 'identity',
        'now': store.now().$1,
      })).map['collection'],
      nowMs: store.now().$1,
      protocol: kSrsSync2Protocol,
      minReader: kSrsSync2MinReader,
    );
    // 握手结论照样交回（调度器据此记加密状态、把本机刚开的加密标成已生效）。
    handshake = SrsSync2Report()
      ..needsUpgrade = h.needsUpgrade
      ..error = h.error
      ..kdf = h.kdf
      ..encryptionEnabled = h.encryptionEnabled
      ..encrypted = h.keyHex != null;
    if (h.needsUpgrade || h.error != null) {
      return SrsFolderSyncReport(ops: handshake, prepared: prepared);
    }
    mediaKey = h.keyHex;
  }
  SrsMediaSyncReport? media;
  if (mediaRoot != null && (location.media || location.archive)) {
    media = await srsSyncMedia(
      location: root,
      store: store,
      mediaRoot: mediaRoot,
      archive: location.archive,
      cipher: mediaKey == null ? null : SrsMediaCipher(store, mediaKey),
    );
  }
  media?.uploaded += uploadedEarly;
  return SrsFolderSyncReport(
    ops: ops,
    media: media,
    handshake: handshake,
    prepared: prepared,
  );
}
