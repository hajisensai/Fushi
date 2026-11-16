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

  /// 某个域落到新目录失败（空间不足 / 权限 / 文件被占用）。**所有**域都已撤回：
  /// 旧目录、书库、下载根偏好都没动。
  copyFailed,

  /// 改写书库里的路径失败。事务已回滚、所有域都已撤回：书库仍指旧目录，旧文件都在。
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
  ///
  /// 搬移是全有或全无的，失败时没有任何域留在新目录，[movedDomains] 恒为空。
  const DownloadRootMoveReport.failed(
    DownloadRootMoveFailure failure, {
    String? detail,
  }) : this._(
         movedDomains: const <String>[],
         leftoverDirectories: const <String>[],
         failure: failure,
         detail: detail,
       );

  /// 已搬到新根的域（只在成功时非空）。
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
/// **全有或全无**（跨域也成立）：调用方只在成功时切下载根偏好，所以任何一个域
/// 失败都必须把本次已落到新根的域全部撤回——否则已搬走的域会落在一个既不是当前根、
/// 也不在历史根里的目录，新下载与「重新入库」扫描都看不到它。分三阶段：
///  1. **全部域落文件**（不删源）：目标不存在时先试 `rename`（同卷 O(1)）；跨卷或
///     目标已有内容时 [copyTreeMerging]。任何一个域失败 → 撤回本次所有已落的域
///     （rename 的改名回去、本次新建的目标目录删掉；目标原本就有的内容不碰，合并
///     复制的部分下次选同一目录时续上）→ [DownloadRootMoveFailure.copyFailed]。
///  2. **改书库**：[DataRootMigrator.rebaseOpenDatabasePaths] 用一个事务改写所有
///     已落域的路径列（覆盖面的真相源是 `path_rebase_coverage.dart`，与数据根迁移
///     共用一份清单）。失败 → 事务回滚 + 同样撤回全部域 →
///     [DownloadRootMoveFailure.databaseFailed]。
///  3. **删旧目录**（只有复制落地的域需要）：删不掉记进
///     [DownloadRootMoveReport.leftoverDirectories]（数据已在新根、书库已指过去）。
///
/// 撤回本身失败（改名回不去 / 删不掉）时把原因拼进 [DownloadRootMoveReport.detail]，
/// 不静默。调用方负责：搬之前确认没有在写这些目录的下载任务（[busyReason]），搬
/// 成功后再把下载根偏好切到新根。
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
    // 1. 全部域落文件（不删源）。
    final List<_PlacedDomain> placed = <_PlacedDomain>[];
    for (final String domain in domains) {
      final Directory source = Directory(
        DownloadLayout.domainPath(from, domain),
      );
      final Directory target = Directory(DownloadLayout.domainPath(to, domain));
      if (!await directoryHasFiles(source)) continue;
      final bool targetExisted = await target.exists();
      bool renamed = false;
      try {
        await target.parent.create(recursive: true);
        if (!targetExisted) {
          try {
            await source.rename(target.path);
            renamed = true;
          } on FileSystemException {
            // 跨卷：走复制。
          }
        }
        if (!renamed) await copyTreeMerging(source, target);
      } on FileSystemException catch (error) {
        final List<String> rollback = await _rollback(<_PlacedDomain>[
          ...placed,
          _PlacedDomain(
            domain: domain,
            source: source,
            target: target,
            renamed: renamed,
            createdTarget: !targetExisted,
          ),
        ]);
        return DownloadRootMoveReport.failed(
          DownloadRootMoveFailure.copyFailed,
          detail: <String>[_describe(error), ...rollback].join('; '),
        );
      }
      placed.add(
        _PlacedDomain(
          domain: domain,
          source: source,
          target: target,
          renamed: renamed,
          createdTarget: !targetExisted,
        ),
      );
    }
    if (placed.isEmpty) {
      return const DownloadRootMoveReport.success(movedDomains: <String>[]);
    }

    // 2. 一个事务改写所有已落域的书库路径。
    try {
      await DataRootMigrator.rebaseOpenDatabasePaths(
        db: database,
        docs: DocumentsPathRebaser(
          oldRoot: from,
          newRoot: to,
          scopeTopLevelNames: <String>{
            for (final _PlacedDomain item in placed) item.domain,
          },
        ),
        // 只有偏好改写用得到 support 根；这里不碰偏好（见 includePreferences）。
        newSupportRoot: '',
        includePreferences: false,
      );
    } on Object catch (error) {
      final List<String> rollback = await _rollback(placed);
      return DownloadRootMoveReport.failed(
        DownloadRootMoveFailure.databaseFailed,
        detail: <String>[error.toString(), ...rollback].join('; '),
      );
    }

    // 3. 删旧目录（复制落地的域）。
    final List<String> leftovers = <String>[];
    for (final _PlacedDomain item in placed) {
      if (item.renamed) continue;
      try {
        await item.source.delete(recursive: true);
      } on FileSystemException {
        leftovers.add(item.source.path);
      }
    }
    return DownloadRootMoveReport.success(
      movedDomains: <String>[
        for (final _PlacedDomain item in placed) item.domain,
      ],
      leftoverDirectories: leftovers,
    );
  }

  /// 撤回本次已落到新根的域（倒序）：rename 的改名回去，本次新建的目标目录删掉
  /// （目标原本就有的内容不碰）。返回撤回失败的原因（空 = 全部撤回）。
  static Future<List<String>> _rollback(List<_PlacedDomain> placed) async {
    final List<String> problems = <String>[];
    for (final _PlacedDomain item in placed.reversed) {
      try {
        if (item.renamed) {
          await item.target.rename(item.source.path);
        } else if (item.createdTarget && await item.target.exists()) {
          await item.target.delete(recursive: true);
        }
      } on FileSystemException catch (error) {
        problems.add(_describe(error));
      }
    }
    return problems;
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

/// 第 1 阶段已落到新根的一个域（撤回与删源用）。
class _PlacedDomain {
  const _PlacedDomain({
    required this.domain,
    required this.source,
    required this.target,
    required this.renamed,
    required this.createdTarget,
  });

  final String domain;
  final Directory source;
  final Directory target;

  /// 经 `rename` 落地（源已不在原处，撤回要改名回去）；false = 复制落地（源还在）。
  final bool renamed;

  /// 目标目录是本次新建的（撤回时整个删掉）；false = 目标原本就有内容，不碰。
  final bool createdTarget;
}
