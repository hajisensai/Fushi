import 'dart:io';

import 'package:fushi_engine/foundation/engine_log.dart';
import 'package:fushi_engine/srs/sync2/srs_location_store.dart'
    show kSrsSync2Namespace;
import 'package:fushi_engine/sync/sync_reserved_namespaces.dart';
import 'package:fushi_engine/sync/sync_root_folder.dart';
import 'package:path/path.dart' as p;

/// 清掉互联 host 上**已无人读取**的客户端「文件箱」书文件夹（BUG-4906）。
///
/// [syncDataDir] 是 host 的 WebDAV 根（`FushiSyncServer.syncDataDir`，即 `<数据根>/sync-data`），
/// 清理范围只有其下 [kSyncRootFolderName] 的一级子目录。
///
/// 背景：互联客户端过去把每本书的 `<书名>/`（`<书名>.epub`、有声书音频、`progress_*` /
/// `statistics_*` / `audioBook_*` JSON、`cover_*`）经 WebDAV 写进 host 的同步根，但 host
/// 从来不读这些文件夹——进度 / 统计 / 有声书断点 / 书内容各有 live 端点。新客户端早已不写
/// （内容自 2.7、JSON 自 2026-11-07 起），可 host 从来没有任何路径收走旧版本写下的东西，
/// 用户机器上攒到 6.7 GB。
///
/// 删除判据（两条都满足才删）：
/// 1. 名字不是保留命名空间（[isReservedSyncNamespaceName]）；
/// 2. 目录是平的：只有文件、没有子目录 / 链接。书文件夹从来是平的；带子目录的东西不是
///    文件箱写出来的，不认识就不碰。
///
/// 同步根下直接放的文件（旧的根 spill）不归这里管：客户端每轮的 `pruneRootSpill` 会收。
///
/// 还在跑 2026-11-07 前版本的客户端仍会往书文件夹写进度 JSON / 封面（几 KB / 本），它们
/// 读到书文件夹没了只会按「远端缺失 → 导出本机」再写一份，不会删本机任何东西；这些残余
/// 在 host 下次启动时再收一遍。
///
/// 必须在 server 绑端口**之前**跑（没有客户端在写，不和 WebDAV 写竞争）。单个目录删失败
/// （文件被占用 / 权限）只记日志、跳过，不挡启动，下次启动重试。返回删掉的目录名。
Future<List<String>> pruneDeadInterconnectFileBox(String syncDataDir) async {
  final Directory root = Directory(p.join(syncDataDir, kSyncRootFolderName));
  final List<String> removed = <String>[];
  try {
    if (!await root.exists()) return removed;
    final List<FileSystemEntity> children = await root
        .list(followLinks: false)
        .toList();
    for (final FileSystemEntity child in children) {
      if (child is! Directory) continue;
      final String name = p.basename(child.path);
      try {
        if (!await _isDeadFileBoxFolder(child)) continue;
        await child.delete(recursive: true);
        removed.add(name);
      } catch (e, stack) {
        engineLog.log('pruneDeadInterconnectFileBox($name)', e, stack);
      }
    }
  } catch (e, stack) {
    engineLog.log('pruneDeadInterconnectFileBox', e, stack);
  }
  if (removed.isNotEmpty) {
    engineLog.logDiagnostic(
      'pruneDeadInterconnectFileBox',
      'removed ${removed.length} dead file-box folder(s) under '
          '${root.path}',
    );
  }
  return removed;
}

/// [dir]（同步根的一级子目录）是不是 [pruneDeadInterconnectFileBox] 会删的死文件箱书文件夹：
/// 名字不是保留命名空间、且只有文件。清理与存储页归类共用这一个判据。
Future<bool> _isDeadFileBoxFolder(Directory dir) async {
  if (isReservedSyncNamespaceName(p.basename(dir.path))) return false;
  await for (final FileSystemEntity e in dir.list(followLinks: false)) {
    if (e is! File) return false;
  }
  return true;
}

/// 互联 host 同步数据（`<sync-data>`）按用途归类后的占用字节数（存储页用，BUG-4906）。
///
/// 三类之和 + [otherBytes] = `<sync-data>` 整棵树的大小。
class InterconnectSyncDataUsage {
  const InterconnectSyncDataUsage({
    required this.sharedBytes,
    required this.srsBytes,
    required this.deadFileBoxBytes,
    required this.deadFileBoxFolders,
    required this.otherBytes,
  });

  /// 互联客户端共享数据：同步根下的 `__x__` 保留命名空间（字典 / 本地音源 / 聚合 / 合集 /
  /// 视频 / 墓碑 / 字体 / 设置 / 待发制卡）。只读展示，不提供清理。
  final int sharedBytes;

  /// 复习同步：同步根下的 `fushi-srs/`。只读展示，不提供清理。
  final int srsBytes;

  /// 旧版残留：[pruneDeadInterconnectFileBox] 会删的死文件箱书文件夹合计。
  final int deadFileBoxBytes;

  /// 旧版残留的文件夹个数。
  final int deadFileBoxFolders;

  /// 其余（同步根下认不出的带子目录目录、根下散落文件、`<sync-data>` 下同步根以外的东西）。
  final int otherBytes;

  int get totalBytes => sharedBytes + srsBytes + deadFileBoxBytes + otherBytes;

  static const InterconnectSyncDataUsage empty = InterconnectSyncDataUsage(
    sharedBytes: 0,
    srsBytes: 0,
    deadFileBoxBytes: 0,
    deadFileBoxFolders: 0,
    otherBytes: 0,
  );
}

/// 量出 [syncDataDir]（`<数据根>/sync-data`）各类占用；目录不存在时全 0。只读，不跟随链接。
/// 读不了的子项按 0 计（存储页是估算，不因一个被占用的文件整页失败）。
Future<InterconnectSyncDataUsage> measureInterconnectSyncData(
  String syncDataDir,
) async {
  final Directory base = Directory(syncDataDir);
  if (!await base.exists()) return InterconnectSyncDataUsage.empty;
  final String rootPath = p.join(syncDataDir, kSyncRootFolderName);
  int shared = 0, srs = 0, dead = 0, deadFolders = 0, other = 0;
  await for (final FileSystemEntity top in base.list(followLinks: false)) {
    if (top.path != rootPath || top is! Directory) {
      other += await _treeBytes(top);
      continue;
    }
    await for (final FileSystemEntity child in top.list(followLinks: false)) {
      final int bytes = await _treeBytes(child);
      final String name = p.basename(child.path);
      if (child is! Directory) {
        other += bytes;
      } else if (name == kSrsSync2Namespace) {
        srs += bytes;
      } else if (isReservedSyncNamespaceName(name)) {
        shared += bytes;
      } else if (await _isDeadFileBoxFolder(child)) {
        dead += bytes;
        deadFolders++;
      } else {
        other += bytes;
      }
    }
  }
  return InterconnectSyncDataUsage(
    sharedBytes: shared,
    srsBytes: srs,
    deadFileBoxBytes: dead,
    deadFileBoxFolders: deadFolders,
    otherBytes: other,
  );
}

Future<int> _treeBytes(FileSystemEntity entity) async {
  try {
    if (entity is File) return await entity.length();
    if (entity is! Directory) return 0;
    int total = 0;
    await for (final FileSystemEntity e in entity.list(
      recursive: true,
      followLinks: false,
    )) {
      if (e is File) {
        try {
          total += await e.length();
        } catch (_) {
          // 估算：读不了长度的单个文件按 0 计。
        }
      }
    }
    return total;
  } catch (_) {
    return 0;
  }
}
