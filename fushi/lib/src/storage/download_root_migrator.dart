import 'dart:io';

import 'package:fushi_core/fushi_core.dart';
import 'package:path/path.dart' as p;

import 'package:fushi/src/storage/data_root_migrator.dart';
import 'package:fushi/src/storage/directory_move.dart';
import 'package:fushi/src/storage/download_layout.dart';

/// 搬已下载内容失败的类别（UI 据此选文案；细节在 [DownloadRootMoveReport.detail]）。
enum DownloadRootMoveFailure {
  /// 还有下载任务在往旧目录里写，先等它们结束 / 取消。
  busy,

  /// 新旧目录互相嵌套（搬着搬着把目标搬进自己）。
  nested,

  /// 复制文件失败（空间不足 / 权限 / 文件被占用）。旧目录与书库都没动。
  copyFailed,

  /// 改写书库里的路径失败。已回滚：书库仍指旧目录，旧文件都在。
  databaseFailed,
}

/// 一次搬移的结果。
class DownloadRootMoveReport {
  const DownloadRootMoveReport._({
    required this.movedDomains,
    required this.leftoverDirectories,
    this.failure,
    this.detail,
  });

  /// 成功（[leftoverDirectories] 可能非空：数据已在新目录，旧目录删不干净）。
  const DownloadRootMoveReport.success({
    required List<String> movedDomains,
    List<String> leftoverDirectories = const <String>[],
  }) : this._(
         movedDomains: movedDomains,
         leftoverDirectories: leftoverDirectories,
       );

  /// 失败：[failure] 非空，[detail] 是给人看的原因（路径 + 系统报错）。
  const DownloadRootMoveReport.failed(
    DownloadRootMoveFailure failure, {
    String? detail,
    List<String> movedDomains = const <String>[],
  }) : this._(
         movedDomains: movedDomains,
         leftoverDirectories: const <String>[],
         failure: failure,
         detail: detail,
       );

  final List<String> movedDomains;

  /// 搬完后没删掉的旧目录（文件被占用等）。数据已经在新目录、书库已指过去，
  /// 这些只是多占的空间，用户可以手动删。
  final List<String> leftoverDirectories;
  final DownloadRootMoveFailure? failure;
  final String? detail;

  bool get succeeded => failure == null;
}

/// 改下载根时把可搬的下载域（[kMigratableDownloadDomains]：在线漫画、音乐插件）
/// 从旧根搬到新根，并改写书库里指向它们的绝对路径。
///
/// 每个域独立三步，任一步失败都留在一致状态、报原因，不静默：
///  1. **落文件**：目标不存在时先试 `rename`（同卷 O(1)）；跨卷或目标已有内容时
///     [copyTreeMerging]（不删源）。复制失败 → 返回 [DownloadRootMoveFailure.copyFailed]，
///     旧目录和书库都没动；目标里已复制的部分下次选同一目录时合并续上。
///  2. **改书库**：[DataRootMigrator.rebaseOpenDatabasePaths] 单事务改写全部路径列
///     （覆盖面的真相源是 `path_rebase_coverage.dart`，与数据根迁移共用一份清单）。
///     失败 → 事务回滚；第 1 步是 rename 的改名回去 → [DownloadRootMoveFailure.databaseFailed]。
///  3. **删旧目录**（只有复制路径需要）：删不掉记进 [DownloadRootMoveReport.leftoverDirectories]。
///
/// 调用方负责：搬之前确认没有在写这些目录的下载任务（[busyReason]），搬成功后再
/// 把下载根偏好切到新根。
class DownloadRootMigrator {
  const DownloadRootMigrator({
    required this.database,
    this.domains = kMigratableDownloadDomains,
  });

  final FushiDatabase database;
  final List<String> domains;

  /// 旧根下有没有任何一个可搬的域有文件（决定要不要问用户「搬不搬」）。
  Future<bool> hasMovableContent(String oldRoot) async {
    for (final String domain in domains) {
      if (await directoryHasFiles(
        Directory(DownloadLayout.domainPath(oldRoot, domain)),
      )) {
        return true;
      }
    }
    return false;
  }

  /// 把 [oldRoot] 下的各个域搬到 [newRoot]。[busyReason] 非空就拒绝（不动任何东西）。
  Future<DownloadRootMoveReport> move({
    required String oldRoot,
    required String newRoot,
    String? busyReason,
  }) async {
    if (busyReason != null) {
      return DownloadRootMoveReport.failed(
        DownloadRootMoveFailure.busy,
        detail: busyReason,
      );
    }
    final String from = p.normalize(oldRoot);
    final String to = p.normalize(newRoot);
    if (p.equals(from, to)) {
      return const DownloadRootMoveReport.success(movedDomains: <String>[]);
    }
    for (final String domain in domains) {
      final String source = DownloadLayout.domainPath(from, domain);
      final String target = DownloadLayout.domainPath(to, domain);
      if (p.isWithin(source, to) ||
          p.equals(source, to) ||
          p.isWithin(target, from) ||
          p.equals(target, from)) {
        return DownloadRootMoveReport.failed(
          DownloadRootMoveFailure.nested,
          detail: '$from → $to',
        );
      }
    }
    final List<String> moved = <String>[];
    final List<String> leftovers = <String>[];
    for (final String domain in domains) {
      final Directory source = Directory(
        DownloadLayout.domainPath(from, domain),
      );
      final Directory target = Directory(DownloadLayout.domainPath(to, domain));
      if (!await directoryHasFiles(source)) continue;

      // 1. 落文件。
      bool renamed = false;
      try {
        await target.parent.create(recursive: true);
        if (!await target.exists()) {
          try {
            await source.rename(target.path);
            renamed = true;
          } on FileSystemException {
            // 跨卷：走复制。
          }
        }
        if (!renamed) await copyTreeMerging(source, target);
      } on FileSystemException catch (error) {
        return DownloadRootMoveReport.failed(
          DownloadRootMoveFailure.copyFailed,
          detail: _describe(error),
          movedDomains: moved,
        );
      }

      // 2. 改书库。
      try {
        await DataRootMigrator.rebaseOpenDatabasePaths(
          db: database,
          docs: DocumentsPathRebaser(
            oldRoot: source.path,
            newRoot: target.path,
            scopeTopLevelNames: null,
          ),
          // 只有偏好改写用得到 support 根；这里不碰偏好（见 includePreferences）。
          newSupportRoot: '',
          includePreferences: false,
        );
      } on Object catch (error) {
        String detail = error.toString();
        if (renamed) {
          try {
            await target.rename(source.path);
          } on FileSystemException catch (rollback) {
            detail = '$detail; ${_describe(rollback)}';
          }
        }
        return DownloadRootMoveReport.failed(
          DownloadRootMoveFailure.databaseFailed,
          detail: detail,
          movedDomains: moved,
        );
      }

      // 3. 删旧目录。
      if (!renamed) {
        try {
          await source.delete(recursive: true);
        } on FileSystemException {
          leftovers.add(source.path);
        }
      }
      moved.add(domain);
    }
    return DownloadRootMoveReport.success(
      movedDomains: moved,
      leftoverDirectories: leftovers,
    );
  }

  static String _describe(FileSystemException error) {
    final String path = error.path ?? '';
    final String os = error.osError?.message ?? '';
    return <String>[
      error.message,
      if (path.isNotEmpty) path,
      if (os.isNotEmpty) os,
    ].join(' — ');
  }
}
