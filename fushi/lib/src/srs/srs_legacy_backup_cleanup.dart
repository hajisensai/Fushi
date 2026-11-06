/// 旧版复习自动备份的收尾清理（docs/specs/2026-10-25-srs-sync-v2-plan.md P7）。
///
/// 同步 v2 不再定时拍快照（设计 §10：时间线 + 归档 + 手动导出），但旧备份仍可经「同步与历史 › 导入」恢复
/// （`srs_fushisrs.dart` 认得旧格式）。宽限期 [kSrsLegacyBackupGrace] 从**本机升级到 v2 后第一次看到这个
/// 目录的那一刻**起算，而不是从目录里最新文件的修改时间起算——只剩几个月前手动备份的用户，升级后第一次启动
/// 就会被后者判成「早已过期」整目录删掉，连恢复的机会都没有。
///
/// 这个时刻持久化在目录自己里的标记文件 [kSrsLegacyBackupMarker]（毫秒时间戳）：标记跟它管的那份数据放在一起，
/// 两个旧根（documents / 支持目录）各记各的；不放 srs.db 的 `sync2_self.migrated_at`，因为那是按 profile 记的、
/// 随 srs.db 走，而旧备份目录跨 profile 共用、可能比 srs.db 活得久（重装后 documents 还在）。
///
/// 判据（只看正面证据）：
/// - 没有标记 / 标记读不出：写下「此刻」，这一次不删；
/// - 标记未满宽限期：不删；
/// - 目录里任何文件（标记本身除外）比宽限期新：不删（例如用户刚把旧备份手动拷回来）。
library;

import 'dart:io';

import 'package:path/path.dart' as p;

import 'package:fushi/src/storage/app_paths.dart';

/// 旧备份在升级后保留多久。
const Duration kSrsLegacyBackupGrace = Duration(days: 30);

/// 旧备份根目录里记「本机升级到 v2 后第一次看到它」时刻的标记文件。
const String kSrsLegacyBackupMarker = '.fushi-srs-v2-upgraded-at';

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
  final DateTime at = now ?? DateTime.now();
  final DateTime cutoff = at.subtract(kSrsLegacyBackupGrace);
  int removed = 0;
  for (final Directory d in dirs) {
    if (!d.existsSync()) continue;
    final DateTime? upgradedAt = await _readMarker(d);
    if (upgradedAt == null) {
      await _writeMarker(d, at);
      continue;
    }
    if (upgradedAt.isAfter(cutoff)) continue;
    final String marker = p.join(d.path, kSrsLegacyBackupMarker);
    bool fresh = false;
    await for (final FileSystemEntity e in d.list(
      recursive: true,
      followLinks: false,
    )) {
      if (e is! File || p.equals(e.path, marker)) continue;
      if ((await e.stat()).modified.isAfter(cutoff)) {
        fresh = true;
        break;
      }
    }
    if (fresh) continue;
    await d.delete(recursive: true);
    removed++;
  }
  return removed;
}

/// 标记里的时刻；没有或读不出返回 null。
Future<DateTime?> _readMarker(Directory d) async {
  final File f = File(p.join(d.path, kSrsLegacyBackupMarker));
  if (!f.existsSync()) return null;
  try {
    final int? ms = int.tryParse((await f.readAsString()).trim());
    return ms == null ? null : DateTime.fromMillisecondsSinceEpoch(ms);
  } on FileSystemException {
    return null;
  }
}

/// 写标记（先写临时文件再改名：写到一半崩溃不会留下半截标记被当成「读不出」反复重写）。
Future<void> _writeMarker(Directory d, DateTime at) async {
  final File tmp = File(p.join(d.path, '$kSrsLegacyBackupMarker.tmp'));
  await tmp.writeAsString('${at.millisecondsSinceEpoch}', flush: true);
  await tmp.rename(p.join(d.path, kSrsLegacyBackupMarker));
}
