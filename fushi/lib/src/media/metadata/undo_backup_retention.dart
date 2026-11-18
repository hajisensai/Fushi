/// 撤销备份目录的过期清理（书元数据写回与刮削层共用）。
///
/// **按文件名里的时间戳判过期，不看修改时间**：备份文件名统一是
/// `<microsecondsSinceEpoch>_<…>`。`File.copy` 在 Windows / macOS 上保留源文件的
/// 修改时间，按 `lastModified` 判会把「刚为 30 天前写入的封面做的备份」当成过期删掉，
/// 同一次多本操作里后一本的 prune 就删了前一本的备份，撤销只恢复一半。
library;

import 'dart:io';

import 'package:path/path.dart' as p;

import 'package:fushi/src/utils/misc/error_log_service.dart';

/// 备份文件名前缀里的创建时间；不是这种命名时为 null。
DateTime? undoBackupCreatedAt(String path) {
  final String name = p.basename(path);
  final int cut = name.indexOf('_');
  if (cut <= 0) return null;
  final int? micros = int.tryParse(name.substring(0, cut));
  return micros == null ? null : DateTime.fromMicrosecondsSinceEpoch(micros);
}

/// 删掉 [dir] 下（不递归）创建早于 [cutoff] 的备份。名字里没有时间戳的文件退回看
/// 修改时间。
Future<void> pruneUndoBackups(
  Directory dir, {
  required DateTime cutoff,
  required String logTag,
}) async {
  if (!dir.existsSync()) return;
  await for (final FileSystemEntity e in dir.list(followLinks: false)) {
    if (e is! File) continue;
    try {
      final DateTime created =
          undoBackupCreatedAt(e.path) ?? await e.lastModified();
      if (created.isBefore(cutoff)) await e.delete();
    } on FileSystemException catch (err) {
      ErrorLogService.instance.logDiagnostic(logTag, '$err');
    }
  }
}
