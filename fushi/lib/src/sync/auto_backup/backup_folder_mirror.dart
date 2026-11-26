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
import 'package:flutter/foundation.dart' show debugPrint, immutable;
import 'package:fushi_core/fushi_core.dart';
import 'package:path/path.dart' as p;

/// 写进还原点 / 副本元数据、云端设备子目录名的设备键：同步设备 id 的 sha1 前 16 位（副本在共用文件夹 /
/// 云端，原始 id 不露出去；同一台设备永远同一个键）。
String backupDeviceKey(String rawDeviceId) =>
    sha1.convert(utf8.encode(rawDeviceId)).toString().substring(0, 16);

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
  const MirroredRestorePoint({
    required this.point,
    required this.metaText,
    this.inOwnSlot = true,
  });

  /// 解析出的元数据；[RestorePoint.directory] 是副本在文件夹里的位置（路径或平台句柄），只作显示 /
  /// 诊断，读写一律按 [id] 经 [BackupFolderMirror]。
  final RestorePoint point;

  /// 元数据原文（取回本机时原样写回，不丢字段）。
  final String metaText;

  /// 这份副本就在本机 [BackupFolderMirror.upload] / [BackupFolderMirror.delete] 按 [id] 寻址的位置上。
  /// 平铺的用户文件夹（`<folder>/<id>/`）只有这一个位置，恒为 true；云端 / 服务器按设备分目录
  /// （`<命名空间>/<设备>/<id>/`），别的设备目录里的副本为 false——两台设备碰巧同一毫秒写出同一个 id 时，
  /// 本机的清理 / 「已经传过」的判断不能把对方那份当成自己的。
  final bool inOwnSlot;

  String get id => point.id;
}

/// 列文件夹的结果。
@immutable
class MirrorFolderListing {
  const MirrorFolderListing({
    required this.points,
    this.notDownloaded = 0,
    this.unreadable = const <String>{},
  });

  /// 完整的定时还原点副本，新的在前。
  final List<MirroredRestorePoint> points;

  /// 目录在、但这一次读不出元数据的副本 id（读失败、云端这一步出错、iCloud 没下载的占位、元数据坏了）：
  /// 可能是完整的，只是这次没读到。清理半截副本时**不删**它们——只有确定没有元数据的（不在 [points]
  /// 也不在这里）才算半截。
  final Set<String> unreadable;

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

/// 副本操作失败的已知原因（[code] 写进状态文件、界面按码给本地化文案；不带平台原文，原文可能含路径 /
/// 服务器地址）。
class BackupMirrorException implements Exception {
  const BackupMirrorException(this.code);

  /// `kBackupMirrorError*` 之一。
  final String code;

  @override
  String toString() => 'backup copy failed: $code';
}

/// 文件夹里找不到这份副本 / 副本里的文件（被别处删了、还没同步下来）。
const String kBackupMirrorErrorNotFound = 'copy_not_found';

/// 本机这一侧读写失败（本机的还原点文件不见了、本机目录写不进）。
const String kBackupMirrorErrorLocalIo = 'copy_local_io';

/// 文件夹所在的提供者不支持需要的操作（例如覆盖写）。
const String kBackupMirrorErrorUnsupported = 'copy_unsupported';

/// 提供者把新建的文件 / 目录改了名（同名已存在时加后缀）。
const String kBackupMirrorErrorRenamed = 'copy_renamed';

/// 文件夹还在从云端加载（提供者只给了一部分内容），稍后再试。
const String kBackupMirrorErrorLoading = 'copy_loading';

/// 其它读写失败。
const String kBackupMirrorErrorFailed = 'copy_failed';

/// 云端：登录失效 / 没有权限（去同步设置重新登录）。
const String kBackupMirrorErrorCloudAuth = 'cloud_auth';

/// 云端：连不上（没网、服务器 / 互联主机不在线）。
const String kBackupMirrorErrorCloudUnreachable = 'cloud_unreachable';

/// 云端：空间不够。
const String kBackupMirrorErrorCloudQuota = 'cloud_quota';

/// 云端：其它失败（原文只进调试日志的类型名，不进状态：可能含服务器地址）。
const String kBackupMirrorErrorCloudFailed = 'cloud_failed';

/// 云端副本开着，却没有支持的同步后端（只配了互联：第四期起它归「复制到服务器」）。
const String kBackupMirrorErrorCloudNoService = 'cloud_no_service';

/// 服务器副本开着，却没有设置互联服务器。
const String kBackupMirrorErrorServerNoServer = 'server_no_server';

/// 一个副本目标（用户文件夹 / 云端）上的副本操作（按还原点 id 寻址，不暴露平台句柄）。
abstract interface class BackupFolderMirror {
  /// 列出完整的定时还原点副本（新的在前）。
  Future<MirrorFolderListing> list();

  /// 把本机还原点 [local] 复制进文件夹 `<id>/`：先复制 [RestorePoint.files] 里的每个文件（已有的
  /// 同名文件覆盖，接得上被打断的上一次），最后写元数据 [metaText]。
  Future<void> upload(RestorePoint local, {required String metaText});

  /// 把副本 [copy] 的文件复制到本机目录 [destDirectory]（不写元数据）。
  Future<void> download(MirroredRestorePoint copy, String destDirectory);

  /// 删掉**本机写入位置**上的 `<id>/`（不存在不算错）：自动备份的清理半截副本、修剪、上传失败后的收尾
  /// 只走这里。按设备分目录的目标（云端 / 服务器）只在本机目录里找，别的设备的同名副本不碰。
  Future<void> delete(String id);

  /// 删掉列表里的这一份 [copy]（还原点页「删除」：可能是别的设备的副本），按它被列出来的位置寻址，
  /// 不按 id 去猜是哪台设备的（不存在不算错）。
  Future<void> deleteCopy(MirroredRestorePoint copy);
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

/// 把副本 [copy] 取回本机还原点存储 [store]（之后它就是一个普通的定时还原点，补回 / 替换 / 导出照常；
/// 元数据记下 [RestorePoint.copiedBackAtMs]，定时备份的保留规则从不自动删它）。先复制进 [store] 旁边的
/// 临时目录、写元数据，再整个目录改名进存储根：存储里永远看不到半截的点，并发的修剪也删不到它。本机已有
/// 同 id 的完整点直接返回它。id 不是定时还原点的形状（外来的名字，可能是 `..`）时抛 [ArgumentError]。
Future<RestorePoint> copyMirroredPointToStore(
  BackupFolderMirror mirror,
  MirroredRestorePoint copy,
  RestorePointStore store, {
  int? nowMs,
}) async {
  if (!isScheduledRestorePointId(copy.id)) {
    throw ArgumentError.value(copy.id, 'copy.id', 'not a restore point id');
  }
  final String target = p.join(store.root, copy.id);
  final RestorePoint? existing = RestorePoint.tryRead(target);
  if (existing != null) return existing;
  // 取回先落在库目录下的临时目录、再改名进存储（同一个卷）：不够放就不开始下载（[NotEnoughSpaceException]）。
  ensureFreeSpace(<SpaceNeed>[
    SpaceNeed(store.dbDirectory, copy.point.totalBytes),
  ]);
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
    File(p.join(work.path, kRestorePointMetaFileName)).writeAsStringSync(
      copiedBackMetaText(
        copy.metaText,
        nowMs ?? DateTime.now().millisecondsSinceEpoch,
      ),
      flush: true,
    );
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

/// 取回本机的元数据：原文加上 `copiedBackAtMs`（其余字段原样保留）。
String copiedBackMetaText(String metaText, int nowMs) {
  final Object? raw = jsonDecode(metaText);
  if (raw is! Map<String, Object?>) {
    throw const FormatException('restore point meta is not an object');
  }
  return jsonEncode(<String, Object?>{...raw, 'copiedBackAtMs': nowMs});
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
    final Set<String> unreadable = <String>{};
    int notDownloaded = 0;
    for (final FileSystemEntity e in _dir.listSync(followLinks: false)) {
      if (e is! Directory) continue;
      final String id = p.basename(e.path);
      if (!isScheduledRestorePointId(id)) continue;
      // 一份读不了（权限、坏的子目录、读到一半被删）只跳过它，不让整个文件夹列不出来。
      try {
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
          if (placeholder) {
            notDownloaded++;
            unreadable.add(id);
          }
          continue;
        }
        final String text = meta.readAsStringSync();
        final RestorePoint? point = RestorePoint.tryParse(
          text,
          id: id,
          directory: e.path,
        );
        if (point == null || point.kind != RestorePointKind.scheduled) {
          unreadable.add(id);
          continue;
        }
        points.add(MirroredRestorePoint(point: point, metaText: text));
      } on FileSystemException catch (err) {
        debugPrint('AutoBackup: skipping unreadable copy $id: $err');
        unreadable.add(id);
      } on FormatException catch (err) {
        debugPrint('AutoBackup: skipping unreadable copy $id: $err');
        unreadable.add(id);
      }
    }
    points.sort(
      (MirroredRestorePoint a, MirroredRestorePoint b) =>
          b.point.createdAtMs.compareTo(a.point.createdAtMs),
    );
    return MirrorFolderListing(
      points: points,
      notDownloaded: notDownloaded,
      unreadable: unreadable,
    );
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
    if (!isScheduledRestorePointId(id)) {
      throw ArgumentError.value(id, 'id', 'not a restore point id');
    }
    final Directory dir = Directory(p.join(root, id));
    if (dir.existsSync()) await dir.delete(recursive: true);
  }

  /// 平铺的文件夹：每个 id 只有一个位置。
  @override
  Future<void> deleteCopy(MirroredRestorePoint copy) => delete(copy.id);
}
