/// 云端副本：已配置的同步后端当作又一个副本目标
/// （docs/specs/2026-11-25-auto-backup-restore-points.md「Cloud copies」，D8–D11）。
///
/// 同一个 [BackupFolderMirror] 接口，控制器里「先写本机、再复制」「元数据最后写 = 完整」「半截副本按 id
/// 精确清」「只修剪本机写的副本」「还原点页取回本机」全部照用。只依赖 [SyncAssetStore]（fushi_engine），
/// 不 import AppModel / 具体后端：宿主把后端、命名空间、加锁与重试（[CloudStoreGuard]）和错误归类注入进来。
///
/// 布局（在后端自己的同步根 `fushi-data/` 下，沿用它已有的空间 / 授权范围，不要新的 OAuth 范围）：
/// `fushi-data/fushi-backups/<设备键>/<还原点 id>/backup.zip` + `restore_point.json`。每台设备一个子目录：
/// 保留规则只动本机目录里本机写的副本；列表跨全部设备目录（另一台设备取回）。zip 经后端的 `putAsset`
/// 上传（云端后端会混淆内容字节，只有 Fushi 能还原），元数据经 `putBytesAsset`（不混淆、小）。
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:fushi/src/sync/auto_backup/backup_folder_mirror.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/sync/sync_asset_store.dart';
import 'package:path/path.dart' as p;

/// 同步根下放云端副本的命名空间（一级文件夹）。
const String kCloudBackupNamespace = 'fushi-backups';

/// 云端副本的保留（D11）：比本机少，7 天每天 + 4 周每周各留最新一份，另有 5 GB 上限防配额被占满；最新
/// 一份永远留。只算本机写的副本。
const BackupRetentionPolicy kCloudBackupRetention = BackupRetentionPolicy(
  keepMinimum: 1,
  keepAllWithin: Duration.zero,
  dailyDays: 7,
  weeklyWeeks: 4,
  monthlyMonths: 0,
  maxTotalBytes: 5 * 1024 * 1024 * 1024,
);

/// 包住每一次后端调用：宿主在这里拿同步通道的资源锁（后端是带可变状态的进程级单例，不能和同步并发用），
/// [idempotent] 的调用（列、读、建目录、删）按同步层的瞬时错误规则重试；上传不重试（失败由控制器清掉
/// 半截副本，下一个时段重来）。
typedef CloudStoreGuard =
    Future<T> Function<T>(
      Future<T> Function() body, {
      required bool idempotent,
    });

Future<T> _unguarded<T>(
  Future<T> Function() body, {
  required bool idempotent,
}) => body();

String _defaultClassify(Object error) => kBackupMirrorErrorCloudFailed;

/// 同步后端上的云端副本。
class SyncAssetStoreBackupMirror implements BackupFolderMirror {
  SyncAssetStoreBackupMirror({
    required this.store,
    required Future<String> Function() namespace,
    required this.deviceFolder,
    CloudStoreGuard guard = _unguarded,
    String Function(Object error) classify = _defaultClassify,
  }) : _namespaceOf = namespace,
       _guard = guard,
       _classify = classify;

  final SyncAssetStore store;

  /// 这台设备的子目录名（设备键，不是原始设备 id）。
  final String deviceFolder;

  final Future<String> Function() _namespaceOf;
  final CloudStoreGuard _guard;
  final String Function(Object error) _classify;

  Future<String>? _namespace;

  /// 后端调用：已知错误原样抛，其余按宿主的规则归成错误码（[BackupMirrorException]）。原文可能带服务器
  /// 地址 / 响应正文，只把类型名写进调试日志。
  Future<T> _call<T>(
    Future<T> Function() body, {
    bool idempotent = true,
  }) async {
    try {
      return await _guard<T>(body, idempotent: idempotent);
    } on BackupMirrorException {
      rethrow;
    } on ArgumentError {
      rethrow;
    } catch (e) {
      final String code = _classify(e);
      debugPrint(
        'AutoBackup: cloud copy step failed: ${e.runtimeType} -> $code',
      );
      throw BackupMirrorException(code);
    }
  }

  Future<String> _ns() async {
    final Future<String> pending = _namespace ??= _call<String>(_namespaceOf);
    try {
      return await pending;
    } catch (_) {
      _namespace = null;
      rethrow;
    }
  }

  /// 连接 / 登录级的错误：整个列表都不可能成功，不按「这一份坏了」跳过。
  static bool _fatal(BackupMirrorException e) =>
      e.code == kBackupMirrorErrorCloudAuth ||
      e.code == kBackupMirrorErrorCloudUnreachable;

  @override
  Future<MirrorFolderListing> list() async {
    final String ns = await _ns();
    final List<MirroredRestorePoint> points = <MirroredRestorePoint>[];
    for (final AssetEntry device in await _call(() => store.listChildren(ns))) {
      if (!device.isFolder) continue;
      final List<AssetEntry> dirs;
      try {
        dirs = await _call(() => store.listChildren(device.id));
      } on BackupMirrorException catch (e) {
        if (_fatal(e)) rethrow;
        continue;
      }
      for (final AssetEntry dir in dirs) {
        if (!dir.isFolder || !isScheduledRestorePointId(dir.name)) continue;
        try {
          final MirroredRestorePoint? copy = await _readCopy(dir);
          if (copy != null) points.add(copy);
        } on BackupMirrorException catch (e) {
          if (_fatal(e)) rethrow;
        } on FormatException {
          // 元数据坏了 / 不是 UTF-8：当作不完整，跳过。
        }
      }
    }
    points.sort(
      (MirroredRestorePoint a, MirroredRestorePoint b) =>
          b.point.createdAtMs.compareTo(a.point.createdAtMs),
    );
    return MirrorFolderListing(points: points);
  }

  Future<MirroredRestorePoint?> _readCopy(AssetEntry dir) async {
    final List<AssetEntry> files = await _call(
      () => store.listChildren(dir.id),
    );
    AssetEntry? meta;
    for (final AssetEntry f in files) {
      if (!f.isFolder && f.name == kRestorePointMetaFileName) meta = f;
    }
    if (meta == null) return null;
    final String metaId = meta.id;
    final Uint8List? bytes = await _call(() => store.getBytesAsset(metaId));
    if (bytes == null) return null;
    final String text = utf8.decode(bytes);
    final RestorePoint? point = RestorePoint.tryParse(
      text,
      id: dir.name,
      directory: dir.id,
    );
    if (point == null || point.kind != RestorePointKind.scheduled) return null;
    return MirroredRestorePoint(point: point, metaText: text);
  }

  @override
  Future<void> upload(RestorePoint local, {required String metaText}) async {
    for (final RestorePointFile f in local.files) {
      if (!File(p.join(local.directory, f.name)).existsSync()) {
        throw const BackupMirrorException(kBackupMirrorErrorLocalIo);
      }
    }
    final String ns = await _ns();
    final String device = await _call(
      () => store.ensureFolder(ns, deviceFolder),
    );
    final String dir = await _call(() => store.ensureFolder(device, local.id));
    // 先删旧元数据：被打断的上一次若已写过元数据，覆盖文件的途中不能看起来「完整」。
    for (final AssetEntry e in await _call(() => store.listChildren(dir))) {
      if (!e.isFolder && e.name == kRestorePointMetaFileName) {
        await _call(() => store.deleteAsset(e.id));
      }
    }
    for (final RestorePointFile f in local.files) {
      final File file = File(p.join(local.directory, f.name));
      await _call(() => store.putAsset(dir, f.name, file), idempotent: false);
    }
    await _call(
      () => store.putBytesAsset(
        dir,
        kRestorePointMetaFileName,
        Uint8List.fromList(utf8.encode(metaText)),
      ),
      idempotent: false,
    );
  }

  @override
  Future<void> download(MirroredRestorePoint copy, String destDirectory) async {
    // [RestorePoint.directory] 是列表时拿到的目录资产 id（各后端的 id 都稳定：Drive 文件 id、Dropbox /
    // WebDAV / FTP / SFTP 路径）。
    final String dirId = copy.point.directory;
    final Map<String, AssetEntry> byName = <String, AssetEntry>{
      for (final AssetEntry e in await _call(() => store.listChildren(dirId)))
        if (!e.isFolder) e.name: e,
    };
    for (final RestorePointFile f in copy.point.files) {
      final AssetEntry? entry = byName[f.name];
      if (entry == null) {
        throw const BackupMirrorException(kBackupMirrorErrorNotFound);
      }
      await _call(
        () => store.getAsset(entry.id, File(p.join(destDirectory, f.name))),
      );
    }
  }

  /// 删掉 `<id>/`：先找本机目录，再找别的设备的目录（还原点页删别的设备的副本）。不存在不算错（FTP 删
  /// 不存在的文件会抛，所以只删列表里确实有的）。
  @override
  Future<void> delete(String id) async {
    if (!isScheduledRestorePointId(id)) {
      throw ArgumentError.value(id, 'id', 'not a restore point id');
    }
    final String ns = await _ns();
    final List<AssetEntry> devices = await _call(() => store.listChildren(ns));
    devices.sort(
      (AssetEntry a, AssetEntry b) => (b.name == deviceFolder ? 1 : 0)
          .compareTo(a.name == deviceFolder ? 1 : 0),
    );
    for (final AssetEntry device in devices) {
      if (!device.isFolder) continue;
      for (final AssetEntry dir in await _call(
        () => store.listChildren(device.id),
      )) {
        if (dir.isFolder && dir.name == id) {
          await _call(() => store.deleteAsset(dir.id, isFolder: true));
          return;
        }
      }
    }
  }
}
