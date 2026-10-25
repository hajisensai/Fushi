/// 旧版复习自动备份的收尾清理（docs/specs/2026-10-25-srs-sync-v2-plan.md P7）。
///
/// 同步 v2 不再定时拍快照（设计 §10：时间线 + 归档 + 手动导出）。升级后不再有新备份写进旧目录，所以旧目录里
/// 最新文件的修改时间就是「最后一次旧备份」——它满 [kSrsLegacyBackupGrace] 才整体删除。判据只看正面证据：
/// 目录里任何文件比宽限期新都不删（例如用户刚把旧备份手动拷回来）。
library;

import 'dart:io';

import 'package:path/path.dart' as p;

import 'package:fushi/src/storage/app_paths.dart';

/// 旧备份在升级后保留多久。
const Duration kSrsLegacyBackupGrace = Duration(days: 30);

/// 清理旧版自动备份目录：`<documents>/srs_backups`，以及更早第一版放过的 `<支持目录>/srs_backups`。
/// 返回删掉的目录数。[roots] / [now] 供测试注入。
Future<int> srsCleanupLegacyBackups({
  List<Directory>? roots,
  DateTime? now,
}) async {
  final List<Directory> dirs =
      roots ??
      <Directory>[
        await AppPaths.srsBackupsDirectory(),
        Directory(
          p.join((await AppPaths.supportRootDirectory()).path, 'srs_backups'),
        ),
      ];
  final DateTime cutoff = (now ?? DateTime.now()).subtract(
    kSrsLegacyBackupGrace,
  );
  int removed = 0;
  for (final Directory d in dirs) {
    if (!d.existsSync()) continue;
    DateTime? newest;
    await for (final FileSystemEntity e in d.list(
      recursive: true,
      followLinks: false,
    )) {
      if (e is! File) continue;
      final DateTime m = (await e.stat()).modified;
      if (newest == null || m.isAfter(newest)) newest = m;
    }
    if (newest != null && newest.isAfter(cutoff)) continue;
    await d.delete(recursive: true);
    removed++;
  }
  return removed;
}
