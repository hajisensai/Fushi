/// 用户文件夹里的定时还原点副本（docs/specs/2026-11-25-auto-backup-restore-points.md 第三期）。
///
/// 移动端的定时还原点照旧先写进本机还原点存储（原子、可修剪）；设了用户文件夹时，每份写好的点再
/// **原样复制**一份到文件夹（`<文件夹>/<id>/backup.zip` + `restore_point.json`，元数据最后写 = 完整
/// 标记，与本机存储同一约定），文件夹里的副本按同一套保留规则修剪。文件夹可能是 SD 卡、同步盘或
/// iCloud Drive，几台设备可能共用：副本元数据带写入设备的 id（[RestorePoint.deviceId]），保留规则
/// **只修剪本机写的副本**，别的设备的副本只列出、从不自动删。
///
/// 本文件只有与平台无关的部分：文件夹句柄 [AutoBackupMirrorFolder]、副本 [MirroredRestorePoint]、
/// 文件夹操作接口 [BackupFolderMirror] 与它的 `dart:io` 实现 [IoBackupFolderMirror]（iOS 激活书签之后、
/// 测试）、保留规则 [planMirrorRetention]、取回本机 [copyMirroredPointToStore]。平台半边（Android SAF、
/// iOS 安全作用域书签）在 `backup_folder_platform.dart`。不 import AppModel（import 大环守卫）。
library;

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart' show sha1;
import 'package:flutter/foundation.dart' show immutable;
import 'package:fushi_core/fushi_core.dart';
import 'package:path/path.dart' as p;

/// 用户选的文件夹：平台句柄 + 显示名。
@immutable
class AutoBackupMirrorFolder {
  const AutoBackupMirrorFolder({required this.handle, required this.label});

  /// Android：SAF 树 URI（已持久授权）；iOS：base64 安全作用域书签。
  final String handle;

  /// 给用户看的文件夹名。
  final String label;

  /// 稳定的短标识（状态文件里记「已复制到哪个文件夹」用；不把书签原文写进状态）。
  String get key =>
      sha1.convert(utf8.encode(handle)).toString().substring(0, 16);

  @override
  bool operator ==(Object other) =>
      other is AutoBackupMirrorFolder &&
      other.handle == handle &&
      other.label == label;

  @override
  int get hashCode => Object.hash(handle, label);
}

/// 文件夹里一份完整的定时还原点副本。
@immutable
class MirroredRestorePoint {
  const MirroredRestorePoint({required this.point, required this.metaText});

  /// 解析出的元数据；[RestorePoint.directory] 是副本在文件夹里的位置（路径或平台句柄），只作显示 /
  /// 诊断，读写一律按 [id] 经 [BackupFolderMirror]。
  final RestorePoint point;

  /// 元数据原文（取回本机时原样写回，不丢字段）。
  final String metaText;

  String get id => point.id;
}

/// 列文件夹的结果。
@immutable
class MirrorFolderListing {
  const MirrorFolderListing({required this.points, this.notDownloaded = 0});

  /// 完整的定时还原点副本，新的在前。
  final List<MirroredRestorePoint> points;

  /// 元数据还在云端、没下载到本机的副本数（iCloud Drive 的 `.<名>.icloud` 占位）：列不出内容，
  /// 页面提示去「文件」App 里下载。
  final int notDownloaded;
}

/// 文件夹不可用：没授权 / 授权被收回、文件夹被删或改名、外接存储没插。
class BackupFolderUnavailableException implements Exception {
  const BackupFolderUnavailableException(this.detail);

  final String detail;

  @override
  String toString() => 'backup folder unavailable: $detail';
}

/// 一个用户文件夹上的副本操作（按还原点 id 寻址，不暴露平台句柄）。
abstract interface class BackupFolderMirror {
  /// 列出完整的定时还原点副本（新的在前）。
  Future<MirrorFolderListing> list();

  /// 把本机还原点 [local] 复制进文件夹 `<id>/`：先复制 [RestorePoint.files] 里的每个文件（已有的
  /// 同名文件覆盖，接得上被打断的上一次），最后写元数据 [metaText]。
  Future<void> upload(RestorePoint local, {required String metaText});

  /// 把副本 [copy] 的文件复制到本机目录 [destDirectory]（不写元数据）。
  Future<void> download(MirroredRestorePoint copy, String destDirectory);

  /// 删掉文件夹里的 `<id>/`（不存在不算错）。
  Future<void> delete(String id);
}

/// 副本的元数据：本机元数据原文加上写入设备（[RestorePoint.deviceId] / [RestorePoint.deviceName]）。
String mirrorMetaText(
  RestorePoint local, {
  required String deviceId,
  required String deviceName,
}) {
  final Map<String, Object?> json = local.toJson()
    ..['deviceId'] = deviceId
    ..['deviceName'] = deviceName;
  return jsonEncode(json);
}

/// 文件夹副本的保留：只看 [deviceId] 写的副本（别的设备的、以及没有设备标记的不动），规则同本机
/// 定时还原点（[kRestorePointScheduledRetention]：48 小时全留、7 日 4 周 3 月、5 GB 上限）；
/// [protectId]（刚复制的那份）永不删。返回要删的副本。
List<MirroredRestorePoint> planMirrorRetention(
  List<MirroredRestorePoint> copies, {
  required String deviceId,
  required DateTime now,
  String? protectId,
  BackupRetentionPolicy policy = kRestorePointScheduledRetention,
}) {
  final List<MirroredRestorePoint> own =
      <MirroredRestorePoint>[
        for (final MirroredRestorePoint c in copies)
          if (c.point.deviceId == deviceId &&
              c.point.kind == RestorePointKind.scheduled)
            c,
      ]..sort(
        (MirroredRestorePoint a, MirroredRestorePoint b) =>
            b.point.createdAtMs.compareTo(a.point.createdAtMs),
      );
  return planBackupRetention<MirroredRestorePoint>(
    own,
    timestampOf: (MirroredRestorePoint c) => c.point.createdAt,
    now: now.toUtc(),
    policy: policy,
    sizeOf: (MirroredRestorePoint c) => c.point.totalBytes,
    protect: (MirroredRestorePoint c) => c.id == protectId,
  );
}

/// 把文件夹副本 [copy] 取回本机还原点存储 [store]（之后它就是一个普通的定时还原点，补回 / 替换 /
/// 导出照常）。先复制进 [store] 旁边的临时目录、写元数据，再整个目录改名进存储根：存储里永远看不到
/// 半截的点，并发的修剪也删不到它。本机已有同 id 的完整点直接返回它。
Future<RestorePoint> copyMirroredPointToStore(
  BackupFolderMirror mirror,
  MirroredRestorePoint copy,
  RestorePointStore store,
) async {
  final String target = p.join(store.root, copy.id);
  final RestorePoint? existing = RestorePoint.tryRead(target);
  if (existing != null) return existing;
  final Directory staging = Directory(
    p.join(store.dbDirectory, '.restore_point_download'),
  );
  if (staging.existsSync()) staging.deleteSync(recursive: true);
  final Directory work = Directory(p.join(staging.path, copy.id))
    ..createSync(recursive: true);
  try {
    await mirror.download(copy, work.path);
    for (final RestorePointFile f in copy.point.files) {
      final File local = File(p.join(work.path, f.name));
      if (!local.existsSync() || local.lengthSync() != f.size) {
        throw FileSystemException('incomplete copy of ${f.name}', local.path);
      }
    }
    File(
      p.join(work.path, kRestorePointMetaFileName),
    ).writeAsStringSync(copy.metaText, flush: true);
    Directory(store.root).createSync(recursive: true);
    // 本机有一个同名的半截目录（没有元数据）：是坏的残留，换掉。
    final Directory stale = Directory(target);
    if (stale.existsSync()) stale.deleteSync(recursive: true);
    work.renameSync(target);
  } finally {
    if (staging.existsSync()) {
      try {
        staging.deleteSync(recursive: true);
      } on FileSystemException {
        // 临时目录删不掉：下次取回时先删；不把已经成功的取回报成失败。
      }
    }
  }
  final RestorePoint? point = RestorePoint.tryRead(target);
  if (point == null) {
    throw FileSystemException('copied restore point is unreadable', target);
  }
  return point;
}

/// iCloud Drive 没下载到本机的文件占位名：`.<原名>.icloud`。
bool _isICloudPlaceholderOf(String name, String original) =>
    name == '.$original.icloud';

/// 直接按文件系统路径读写的文件夹（iOS 在安全作用域书签激活期间、测试）。
class IoBackupFolderMirror implements BackupFolderMirror {
  IoBackupFolderMirror(this.root);

  final String root;

  Directory get _dir => Directory(root);

  void _requireRoot() {
    if (!_dir.existsSync()) throw BackupFolderUnavailableException(root);
  }

  @override
  Future<MirrorFolderListing> list() async {
    _requireRoot();
    final List<MirroredRestorePoint> points = <MirroredRestorePoint>[];
    int notDownloaded = 0;
    for (final FileSystemEntity e in _dir.listSync(followLinks: false)) {
      if (e is! Directory) continue;
      final String id = p.basename(e.path);
      final File meta = File(p.join(e.path, kRestorePointMetaFileName));
      if (!meta.existsSync()) {
        final bool placeholder = Directory(e.path)
            .listSync(followLinks: false)
            .any(
              (FileSystemEntity f) => _isICloudPlaceholderOf(
                p.basename(f.path),
                kRestorePointMetaFileName,
              ),
            );
        if (placeholder) notDownloaded++;
        continue;
      }
      final String text = meta.readAsStringSync();
      final RestorePoint? point = RestorePoint.tryParse(
        text,
        id: id,
        directory: e.path,
      );
      if (point == null || point.kind != RestorePointKind.scheduled) continue;
      points.add(MirroredRestorePoint(point: point, metaText: text));
    }
    points.sort(
      (MirroredRestorePoint a, MirroredRestorePoint b) =>
          b.point.createdAtMs.compareTo(a.point.createdAtMs),
    );
    return MirrorFolderListing(points: points, notDownloaded: notDownloaded);
  }

  @override
  Future<void> upload(RestorePoint local, {required String metaText}) async {
    _requireRoot();
    final Directory dest = Directory(p.join(root, local.id))
      ..createSync(recursive: true);
    // 先删旧的元数据：被打断的上一次若已写过元数据又在覆盖文件，中途看起来不能是「完整」的。
    final File meta = File(p.join(dest.path, kRestorePointMetaFileName));
    if (meta.existsSync()) meta.deleteSync();
    for (final RestorePointFile f in local.files) {
      await File(
        p.join(local.directory, f.name),
      ).copy(p.join(dest.path, f.name));
    }
    final File tmp = File('${meta.path}.tmp');
    tmp.writeAsStringSync(metaText, flush: true);
    tmp.renameSync(meta.path);
  }

  @override
  Future<void> download(MirroredRestorePoint copy, String destDirectory) async {
    _requireRoot();
    final String src = p.join(root, copy.id);
    for (final RestorePointFile f in copy.point.files) {
      final File file = File(p.join(src, f.name));
      if (!file.existsSync()) {
        throw FileSystemException('not downloaded to this device', file.path);
      }
      await file.copy(p.join(destDirectory, f.name));
    }
  }

  @override
  Future<void> delete(String id) async {
    _requireRoot();
    final Directory dir = Directory(p.join(root, id));
    if (dir.existsSync()) await dir.delete(recursive: true);
  }
}
