/// 云端副本：已配置的同步后端当作又一个副本目标
/// （docs/specs/2026-11-25-auto-backup-restore-points.md「Cloud copies」，D8–D11）。
///
/// 同一个 [BackupFolderMirror] 接口，控制器里「先写本机、再复制」「元数据最后写 = 完整」「半截副本按 id
/// 精确清」「只修剪本机写的副本」「还原点页取回本机」全部照用。只依赖 [SyncAssetStore]（fushi_engine），
/// 不 import AppModel / 具体后端：宿主把后端、命名空间、加锁与重试（[CloudStoreGuard]）和错误归类注入进来。
///
/// 布局（在后端自己的同步根 `fushi-data/` 下，沿用它已有的空间 / 授权范围，不要新的 OAuth 范围）：
/// `fushi-data/__backups__/<设备键>/<还原点 id>/backup.zip` + `restore_point.json`。每台设备一个子目录：
/// 保留规则只动本机目录里本机写的副本；列表跨全部设备目录（另一台设备取回）。zip 经后端的 `putAsset`
/// 上传（云端后端会混淆内容字节，只有 Fushi 能还原），元数据经 `putBytesAsset`（不混淆、小）。
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' show sha1;
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:fushi/src/sync/auto_backup/backup_folder_mirror.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/sync/sync_asset_store.dart';
import 'package:path/path.dart' as p;

/// 同步根下放云端副本的命名空间（一级文件夹）。`__x__` 形状 = 保留命名空间
/// （引擎 `isReservedSyncNamespaceName`）：对比弹窗、云端书架不会把它当成远端书列出来，「删远端」删不到它，
/// 互联 host 的文件箱清理也不碰。名字只在 fushi_core 写一次（[kDeviceBackupsNamespace]：互联 host 按它列出
/// 收到的设备备份），云端副本与服务器副本共用。
const String kCloudBackupNamespace = kDeviceBackupsNamespace;

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

/// 云端副本目标在状态文件里的键：后端类型 + 账号 / 服务器身份的 sha1 前 12 位（[accountIdentity]：账号
/// 邮箱、服务器地址 + 用户名、互联主机证书指纹……原文不落盘、不进日志）。换了账号 / 服务器就是另一个
/// 目标：上一个账号的「已上传」不会让新账号跳过，上一个账号的失败也不挡新账号补传。身份查不出来（邮箱
/// 这次没拿到）时只用类型。
String cloudBackupTargetKey(String backendType, String? accountIdentity) {
  final String identity = accountIdentity?.trim() ?? '';
  if (identity.isEmpty) return 'cloud-$backendType';
  final String digest = sha1
      .convert(utf8.encode('$backendType|$identity'))
      .toString()
      .substring(0, 12);
  return 'cloud-$backendType-$digest';
}

/// 服务器副本（第四期 D12）目标在状态文件里的键：`server-` + 互联 host 身份（配对记下的 hostId，老条目退到
/// 所连地址）的 sha1 前 12 位。换了服务器就是另一个目标；原文不落盘、不进日志。身份为空时只用 `server`。
String serverBackupTargetKey(String? hostIdentity) {
  final String identity = hostIdentity?.trim() ?? '';
  if (identity.isEmpty) return 'server';
  final String digest = sha1
      .convert(utf8.encode('fushiServer|$identity'))
      .toString()
      .substring(0, 12);
  return 'server-$digest';
}

/// 服务器副本的保留（D13）：服务器是用户自己的机器，本机写的副本按本机 / 用户文件夹同一套规则修剪（48 小时
/// 全留、7 日 4 周 3 月、5 GB）；别的设备写的、取回的从不自动删，服务器自己也从不自动删。
const BackupRetentionPolicy kServerBackupRetention =
    kRestorePointScheduledRetention;

/// 后端错误的文字（鉴权 / 连不上这类按类型认的错误已经先排除）→ 云端副本错误码。限流（Google Drive 的
/// `rateLimitExceeded` / 「Quota exceeded for quota metric」、HTTP 429、Dropbox `too_many_*`）是瞬时的，
/// 归「连不上」（稍后再试）；只有空间满了（Drive `storageQuotaExceeded`、Dropbox `insufficient_space`、
/// WebDAV 507、FTP 552……）才是「空间不够」。只看小写后的字样，原文不往外传。
String classifyCloudBackupErrorText(String text) {
  final String l = text.toLowerCase();
  const List<String> rateLimited = <String>[
    'ratelimitexceeded',
    'rate limit',
    'rate_limit',
    'quota exceeded for quota metric',
    'too_many_requests',
    'too many requests',
    'too_many_write_operations',
    'http 429',
    'status: 429',
  ];
  if (rateLimited.any(l.contains)) return kBackupMirrorErrorCloudUnreachable;
  const List<String> storageFull = <String>[
    'storagequotaexceeded',
    'storage quota',
    'insufficient_space',
    'insufficient storage',
    'quotalimitreached',
    'exceeded storage allocation',
    'http 507',
    'status: 507',
    'quota',
  ];
  if (storageFull.any(l.contains)) return kBackupMirrorErrorCloudQuota;
  return kBackupMirrorErrorCloudFailed;
}

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

  /// 别的设备的目录列不出来（非致命错误）只跳过那台设备；**本机的目录**列不出来整份列表失败——不然本机
  /// 的副本全都「看不见」，清理会把完整的副本当成半截删掉。单份副本读不了的记进
  /// [MirrorFolderListing.unreadable]。
  @override
  Future<MirrorFolderListing> list() async {
    final String ns = await _ns();
    final List<MirroredRestorePoint> points = <MirroredRestorePoint>[];
    final Set<String> unreadable = <String>{};
    for (final AssetEntry device in await _call(() => store.listChildren(ns))) {
      if (!device.isFolder) continue;
      final List<AssetEntry> dirs;
      try {
        dirs = await _call(() => store.listChildren(device.id));
      } on BackupMirrorException catch (e) {
        if (_fatal(e) || device.name == deviceFolder) rethrow;
        continue;
      }
      final bool own = device.name == deviceFolder;
      for (final AssetEntry dir in dirs) {
        if (!dir.isFolder || !isScheduledRestorePointId(dir.name)) continue;
        try {
          final ({MirroredRestorePoint? copy, bool metaPresent}) read =
              await _readCopy(dir, own: own);
          final MirroredRestorePoint? copy = read.copy;
          if (copy != null) {
            points.add(copy);
          } else if (read.metaPresent) {
            unreadable.add(dir.name);
          }
        } on BackupMirrorException catch (e) {
          if (_fatal(e)) rethrow;
          unreadable.add(dir.name);
        } on FormatException {
          // 元数据不是 UTF-8：读不了，不当成半截。
          unreadable.add(dir.name);
        }
      }
    }
    points.sort(
      (MirroredRestorePoint a, MirroredRestorePoint b) =>
          b.point.createdAtMs.compareTo(a.point.createdAtMs),
    );
    return MirrorFolderListing(points: points, unreadable: unreadable);
  }

  /// 读 `<id>/` 的元数据。`metaPresent` 为 false = 确定没有元数据（半截副本）；为 true 而 `copy` 为 null
  /// = 元数据在但解析不出定时还原点（坏的 / 别的东西）。
  Future<({MirroredRestorePoint? copy, bool metaPresent})> _readCopy(
    AssetEntry dir, {
    required bool own,
  }) async {
    final List<AssetEntry> files = await _call(
      () => store.listChildren(dir.id),
    );
    AssetEntry? meta;
    for (final AssetEntry f in files) {
      if (!f.isFolder && f.name == kRestorePointMetaFileName) meta = f;
    }
    if (meta == null) return (copy: null, metaPresent: false);
    final String metaId = meta.id;
    final Uint8List? bytes = await _call(() => store.getBytesAsset(metaId));
    // 列的时候在、读的时候没了（刚被删）：按没有元数据算。
    if (bytes == null) return (copy: null, metaPresent: false);
    final String text = utf8.decode(bytes);
    final RestorePoint? point = RestorePoint.tryParse(
      text,
      id: dir.name,
      directory: dir.id,
    );
    if (point == null || point.kind != RestorePointKind.scheduled) {
      return (copy: null, metaPresent: true);
    }
    return (
      copy: MirroredRestorePoint(point: point, metaText: text, inOwnSlot: own),
      metaPresent: true,
    );
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

  /// 删掉**本机目录**里的 `<id>/`（自动清理 / 修剪 / 上传失败收尾）。别的设备目录里碰巧同名的那份
  /// （同一毫秒写出的 id）不碰。不存在不算错（FTP 删不存在的文件会抛，所以只删列表里确实有的）。
  @override
  Future<void> delete(String id) async {
    if (!isScheduledRestorePointId(id)) {
      throw ArgumentError.value(id, 'id', 'not a restore point id');
    }
    final String ns = await _ns();
    for (final AssetEntry device in await _call(() => store.listChildren(ns))) {
      if (!device.isFolder || device.name != deviceFolder) continue;
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

  /// 删掉列表里的那一份（还原点页，可能是别的设备的）：按列表给出的目录资产 id（[RestorePoint.directory]，
  /// 各后端都稳定）删，正好是那台设备目录下的那个 `<id>/`。
  @override
  Future<void> deleteCopy(MirroredRestorePoint copy) async {
    if (!isScheduledRestorePointId(copy.id)) {
      throw ArgumentError.value(copy.id, 'id', 'not a restore point id');
    }
    final String dirId = copy.point.directory;
    await _call(() => store.deleteAsset(dirId, isFolder: true));
  }
}
