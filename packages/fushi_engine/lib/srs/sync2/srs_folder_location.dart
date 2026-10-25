/// 用户自己加的「文件夹」存储位置（docs/specs/2026-10-25-srs-sync-v2-design.md §6.5、§10.3）。
///
/// 已有的同步通道（云盘 / 互联）各自就是一个同步 + 媒体位置；这里补上设计里的「＋ 本地文件夹」：U 盘、NAS 挂载点、
/// 被别的同步工具（Syncthing 等）同步的目录。每个位置有三种用途，可多选：
/// - **同步**：收发操作段（与云盘通道同一协议、同一目录布局）；
/// - **媒体**：镜像媒体文件，按 90 天保留期清理；
/// - **归档**：接收全部段 / head / 媒体，**永不删除任何东西**（不清旧 head、不清媒体；只有用户确认的
///   彻底清除会重写段），默认不开。
///
/// 目录布局与云盘的集合根相同（`<文件夹>/fushi-srs/<profileUid>/v2/`），所以归档位置随时能改成同步位置直接用。
library;

import 'dart:io';

import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_engine/srs/srs_media_sync.dart';
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

/// [location] 在磁盘上的集合根（`<文件夹>/fushi-srs/<profileUid>/v2/`）。
Directory srsFolderCollectionRoot(
  SrsFolderLocation location,
  String profileUid,
) => Directory(
  p.join(location.path, kSrsSync2Namespace, profileUid, kSrsSync2Folder),
);

/// 一个文件夹位置这一轮的结果。
class SrsFolderSyncReport {
  SrsFolderSyncReport({this.ops, this.media});

  final SrsSync2Report? ops;
  final SrsMediaSyncReport? media;
}

/// 对一个文件夹位置跑一轮：同步 / 归档用途跑操作同步，媒体 / 归档用途跑媒体镜像。文件夹不在（U 盘没插）时
/// 抛 [FileSystemException]，调用方记一次、下次再试。
Future<SrsFolderSyncReport> srsSyncFolderLocation({
  required SrsFolderLocation location,
  required SrsDbStore store,
  Directory? mediaRoot,
}) async {
  if (location.idle) return SrsFolderSyncReport();
  if (!Directory(location.path).existsSync()) {
    throw FileSystemException('storage location not available', location.path);
  }
  final SrsLocationStore root = SrsDirectoryLocationStore(
    srsFolderCollectionRoot(location, store.profileUid),
  );
  SrsSync2Report? ops;
  if (location.sync || location.archive) {
    ops = await srsSync2Round(
      host: store,
      location: root,
      locationId: location.locationId,
      nowMs: () => store.now().$1,
      // 勾了归档就一个旧 head 也不删（归档位置永不删除，§10.3）。
      archive: location.archive,
    );
  }
  SrsMediaSyncReport? media;
  if (mediaRoot != null && (location.media || location.archive)) {
    media = await srsSyncMedia(
      location: root,
      store: store,
      mediaRoot: mediaRoot,
      archive: location.archive,
    );
  }
  return SrsFolderSyncReport(ops: ops, media: media);
}
