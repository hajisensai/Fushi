import 'dart:io';

import 'package:fushi_engine/foundation/engine_log.dart';
import 'package:fushi_engine/srs/sync2/srs_location_store.dart'
    show kSrsSync2Namespace;
import 'package:fushi_engine/sync/sync_root_folder.dart';
import 'package:path/path.dart' as p;

/// 互联 host 同步根（`<sync-data>/fushi-data/`）下的这个一级目录是不是**保留命名空间**——
/// 还有人读的共享数据，host 启动清理绝不能碰（BUG-4906）。
///
/// 全部保留命名空间（2026-11-21 穷举，ensureNamespace / LocalDirectoryAssetStore 的全部调用点）：
/// `__dictionaries__` `__local_audio__` `__aggregate__` `__collections__` `__videos__`
/// `__tombstones__` `__fonts__` `__settings__` `__pending_mines__`（host 的
/// `AnkiBoxLanding` 读）与复习同步的 `fushi-srs`（host 的 SRS 运行时读）。前九个一律
/// `__x__` 形状，按前缀判，新命名空间照这个形状起名就自动受保护；`fushi-srs` 是唯一例外，
/// 单独列出。守卫 `fushi/test/sync/interconnect_file_box_prune_reserved_guard_test.dart`
/// 扫源码里的全部命名空间常量，确认每一个都落在这里。
bool isInterconnectFileBoxReservedName(String name) =>
    name.startsWith('__') || name == kSrsSync2Namespace;

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
/// 1. 名字不是保留命名空间（[isInterconnectFileBoxReservedName]）；
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
      if (isInterconnectFileBoxReservedName(name)) continue;
      try {
        if (!await _isFlatDirectory(child)) continue;
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

Future<bool> _isFlatDirectory(Directory dir) async {
  await for (final FileSystemEntity e in dir.list(followLinks: false)) {
    if (e is! File) return false;
  }
  return true;
}
