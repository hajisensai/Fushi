/// 互联 host 收到的设备备份（自动备份第四期 A，docs/specs/2026-11-25-auto-backup-restore-points.md
/// 「Phase 4A」）：设备把定时还原点复制到配对的服务器时，经通用 WebDAV 写进 host 的同步根
/// `fushi-data/__backups__/<设备键>/<还原点 id>/backup.zip + restore_point.json`。
///
/// 这里只读盘、删盘，给无头服务端的 admin API 与 app 当 host 时的还原点页共用：按设备分组列出、取
/// 某一份的 zip、删一份 / 删一台设备的全部。路径上的每一段都来自网络（设备写的目录名）或请求参数，
/// 动盘之前一律校验：设备键只认小写十六进制（[isDeviceBackupKey]），还原点 id 只认定时点的形状
/// （[isScheduledRestorePointId]），解析出的路径必须在根之内，链接（符号链接 / 联接点）不跟。
///
/// host 自己从不自动删这些副本（D13）：设备按自己的保留规则修剪它写的那些；别的只有管理员删。
library;

import 'dart:io';

import 'package:path/path.dart' as p;

import 'restore_points.dart';

/// 同步根下放设备备份的命名空间（一级文件夹）。`__x__` 形状 = 保留命名空间：同步对比、云端书架、
/// 「删远端」、互联 host 的文件箱清理都不碰它（引擎 `isReservedSyncNamespaceName`）。app 的云端副本与
/// 服务器副本共用这一个名字。
const String kDeviceBackupsNamespace = '__backups__';

final RegExp _kDeviceKeyPattern = RegExp(r'^[0-9a-f]{1,64}$');

/// [key] 是不是一个合格的设备目录名：app 写的是同步设备 id 的 sha1 前 16 位（`backupDeviceKey`），这里
/// 放宽到 1–64 位小写十六进制，别的（`..`、分隔符、大写、空）一律不认。
bool isDeviceBackupKey(String key) => _kDeviceKeyPattern.hasMatch(key);

/// 一份收到的定时还原点副本。
class ReceivedDeviceBackup {
  const ReceivedDeviceBackup({
    required this.deviceKey,
    required this.point,
    required this.bytes,
  });

  /// 设备目录名（设备键）。
  final String deviceKey;

  /// 元数据（[RestorePoint.directory] 是盘上的目录）。
  final RestorePoint point;

  /// 盘上实际占用（目录里普通文件的大小之和）。
  final int bytes;

  String get id => point.id;

  Map<String, Object?> toJson() => <String, Object?>{
    'id': point.id,
    'createdAtMs': point.createdAtMs,
    'bytes': bytes,
    'schema': point.fromSchema,
    if (point.appVersion != null) 'appVersion': point.appVersion,
    if (point.categories != null) 'categories': point.categories,
    if (point.includesSrsMedia != null) 'srsMedia': point.includesSrsMedia,
    if (point.fullDatabase != null) 'fullDatabase': point.fullDatabase,
  };
}

/// 一台设备的全部副本。
class ReceivedDeviceBackupGroup {
  const ReceivedDeviceBackupGroup({
    required this.deviceKey,
    required this.deviceName,
    required this.copies,
    required this.totalBytes,
    required this.incomplete,
  });

  final String deviceKey;

  /// 最新一份元数据里的设备名；都没有时为 null。
  final String? deviceName;

  /// 完整的副本（有元数据），新的在前。
  final List<ReceivedDeviceBackup> copies;

  /// 设备目录下的全部占用（含没写完 / 读不了的目录）。
  final int totalBytes;

  /// 没有合格元数据的目录数（上传中、被打断、坏的）。设备自己下次会清掉它写的半截副本。
  final int incomplete;

  int? get newestAtMs => copies.isEmpty ? null : copies.first.point.createdAtMs;

  Map<String, Object?> toJson() => <String, Object?>{
    'device': deviceKey,
    'name': deviceName,
    'count': copies.length,
    'bytes': totalBytes,
    'newestAtMs': newestAtMs,
    'incomplete': incomplete,
    'copies': <Map<String, Object?>>[
      for (final ReceivedDeviceBackup c in copies) c.toJson(),
    ],
  };
}

/// host 同步根下的设备备份收件箱。[syncRootDirectory] 是 WebDAV 根下的 `fushi-data/`（无头服务端：
/// `<数据目录>/interconnect/sync-data/fushi-data`；app 当 host：它的 `sync-data/fushi-data`）。
class DeviceBackupInbox {
  DeviceBackupInbox(String syncRootDirectory)
    : root = p.normalize(
        p.absolute(p.join(syncRootDirectory, kDeviceBackupsNamespace)),
      );

  /// `<同步根>/__backups__` 的绝对路径。
  final String root;

  /// 只认真实目录（不跟链接：设备只能经 WebDAV 写普通文件 / 目录，链接只可能是别人放的）。
  static bool _isRealDirectory(String path) =>
      FileSystemEntity.typeSync(path, followLinks: false) ==
      FileSystemEntityType.directory;

  /// [segments] 拼在根下，且确实在根里面；否则抛 [ArgumentError]。
  String _inside(List<String> segments) {
    final String path = p.normalize(p.joinAll(<String>[root, ...segments]));
    if (!p.isWithin(root, path)) {
      throw ArgumentError.value(segments.join('/'), 'path', 'outside inbox');
    }
    return path;
  }

  String _deviceDir(String deviceKey) {
    if (!isDeviceBackupKey(deviceKey)) {
      throw ArgumentError.value(deviceKey, 'device', 'not a device key');
    }
    return _inside(<String>[deviceKey]);
  }

  String _copyDir(String deviceKey, String id) {
    if (!isScheduledRestorePointId(id)) {
      throw ArgumentError.value(id, 'id', 'not a restore point id');
    }
    _deviceDir(deviceKey);
    return _inside(<String>[deviceKey, id]);
  }

  static int _sizeOf(Directory dir) {
    int total = 0;
    try {
      for (final FileSystemEntity e in dir.listSync(
        recursive: true,
        followLinks: false,
      )) {
        if (e is File) {
          try {
            total += e.lengthSync();
          } on FileSystemException {
            // 正在被删 / 改名：不计。
          }
        }
      }
    } on FileSystemException {
      // 列到一半目录没了：照已数到的算。
    }
    return total;
  }

  /// 读 [dir] 这一份副本；没有合格元数据（或不是定时点）返回 null。
  ReceivedDeviceBackup? _readCopy(String deviceKey, Directory dir) {
    final RestorePoint? point = RestorePoint.tryRead(dir.path);
    if (point == null || point.kind != RestorePointKind.scheduled) return null;
    // 元数据列的文件都得在：设备写完 zip 才写元数据，缺了就是坏的 / 被动过。
    for (final RestorePointFile f in point.files) {
      if (FileSystemEntity.typeSync(
            p.join(dir.path, f.name),
            followLinks: false,
          ) !=
          FileSystemEntityType.file) {
        return null;
      }
    }
    return ReceivedDeviceBackup(
      deviceKey: deviceKey,
      point: point,
      bytes: _sizeOf(dir),
    );
  }

  /// 按设备分组列出（最新副本新的设备在前）。名字不合格的目录 / 文件不列、不碰。
  List<ReceivedDeviceBackupGroup> list() {
    final List<ReceivedDeviceBackupGroup> groups =
        <ReceivedDeviceBackupGroup>[];
    if (!_isRealDirectory(root)) return groups;
    final List<FileSystemEntity> devices;
    try {
      devices = Directory(root).listSync(followLinks: false);
    } on FileSystemException {
      return groups;
    }
    for (final FileSystemEntity device in devices) {
      final String key = p.basename(device.path);
      if (device is! Directory || !isDeviceBackupKey(key)) continue;
      final List<ReceivedDeviceBackup> copies = <ReceivedDeviceBackup>[];
      int incomplete = 0;
      List<FileSystemEntity> dirs;
      try {
        dirs = device.listSync(followLinks: false);
      } on FileSystemException {
        dirs = const <FileSystemEntity>[];
      }
      for (final FileSystemEntity dir in dirs) {
        if (dir is! Directory ||
            !isScheduledRestorePointId(p.basename(dir.path))) {
          continue;
        }
        final ReceivedDeviceBackup? copy = _readCopy(key, dir);
        if (copy == null) {
          incomplete++;
        } else {
          copies.add(copy);
        }
      }
      if (copies.isEmpty && incomplete == 0) continue;
      copies.sort(
        (ReceivedDeviceBackup a, ReceivedDeviceBackup b) =>
            b.point.createdAtMs.compareTo(a.point.createdAtMs),
      );
      String? name;
      for (final ReceivedDeviceBackup c in copies) {
        final String? n = c.point.deviceName?.trim();
        if (n != null && n.isNotEmpty) {
          name = n;
          break;
        }
      }
      groups.add(
        ReceivedDeviceBackupGroup(
          deviceKey: key,
          deviceName: name,
          copies: copies,
          totalBytes: _sizeOf(device),
          incomplete: incomplete,
        ),
      );
    }
    groups.sort(
      (ReceivedDeviceBackupGroup a, ReceivedDeviceBackupGroup b) =>
          (b.newestAtMs ?? 0).compareTo(a.newestAtMs ?? 0),
    );
    return groups;
  }

  /// 一份完整副本；键 / id 不合格抛 [ArgumentError]，不存在或不完整返回 null。
  ReceivedDeviceBackup? find(String deviceKey, String id) {
    final String path = _copyDir(deviceKey, id);
    if (!_isRealDirectory(_deviceDir(deviceKey)) || !_isRealDirectory(path)) {
      return null;
    }
    return _readCopy(deviceKey, Directory(path));
  }

  /// 那份副本的备份 zip（完整的才给）。Interconnect 不混淆内容，这就是一份普通的 Fushi 备份包。
  File? archiveOf(String deviceKey, String id) {
    final ReceivedDeviceBackup? copy = find(deviceKey, id);
    final String? archive = copy?.point.archivePath;
    return archive == null ? null : File(archive);
  }

  /// 删一份（含没写完的）；不存在返回 false。
  Future<bool> deleteCopy(String deviceKey, String id) async {
    final String path = _copyDir(deviceKey, id);
    if (!_isRealDirectory(_deviceDir(deviceKey)) || !_isRealDirectory(path)) {
      return false;
    }
    await Directory(path).delete(recursive: true);
    return true;
  }

  /// 删一台设备的全部副本；不存在返回 false。
  Future<bool> deleteDevice(String deviceKey) async {
    final String path = _deviceDir(deviceKey);
    if (!_isRealDirectory(path)) return false;
    await Directory(path).delete(recursive: true);
    return true;
  }
}
