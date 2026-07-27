import 'package:path/path.dart' as p;

import 'package:hibiki/src/media/torrent/torrent_backend.dart';

/// TODO-1961-c+d：把「引擎侧改名/移动」与「库路径迁移」绑成**一个**用户操作。
///
/// 两件事必须成对完成，缺一即断：
/// - 只改引擎 → 做种保住了，但库里 `videoPath` 是死路径，条目点开就是文件不存在；
/// - 只改库 → 库对了，但引擎按旧路径读盘，做种当场断。
///
/// 顺序是**引擎先、库后**，因为引擎那步才是可能失败的一步（目标已存在、权限、
/// 超时）。引擎失败就直接返回，库一个字节都不动 —— 这样失败态永远是「什么都
/// 没变」，而不是需要人工修的半吊子状态。库那步失败则如实报告：磁盘已经动了，
/// 用户必须知道库还指着旧路径（而不是以为整件事没发生）。
class DownloadRelocateService {
  const DownloadRelocateService({
    required TorrentBackend Function() backendFactory,
    required Future<int> Function(
            {required String fromPath, required String toPath})
        migrateLibraryPaths,
  })  : _backendFactory = backendFactory,
        _migrateLibraryPaths = migrateLibraryPaths;

  final TorrentBackend Function() _backendFactory;
  final Future<int> Function({
    required String fromPath,
    required String toPath,
  }) _migrateLibraryPaths;

  /// 改名：把种子内下标 [fileIndex] 的文件改成 [newRelativePath]
  /// （种子内相对路径，可含子目录，分隔符 `/`）。
  ///
  /// [saveRoot] 是该种子当前的 save_path，用来把种子内相对路径拼成库里存的
  /// 绝对路径 —— 库存的是绝对路径，重映射必须在同一坐标系里做。
  Future<RelocateOutcome> renameFile({
    required String infoHash,
    required int fileIndex,
    required String currentRelativePath,
    required String newRelativePath,
    required String saveRoot,
  }) async {
    final String trimmed = newRelativePath.trim();
    if (trimmed.isEmpty) {
      return const RelocateOutcome.engineFailed('new name is empty');
    }
    // 种子内路径跨平台固定用 POSIX `/`；只有拼进本地 save root 时才转成
    // 宿主分隔符。否则 Windows 会把传给 qB/libtorrent 的路径改成 `\`。
    final String normalized =
        p.posix.normalize(trimmed.replaceAll(r'\', '/'));
    final List<String> segments = p.posix.split(normalized);
    if (p.posix.isAbsolute(normalized) ||
        p.windows.rootPrefix(trimmed).isNotEmpty ||
        normalized == '.' ||
        segments.isEmpty ||
        segments.first == '..') {
      return const RelocateOutcome.engineFailed(
          'new name must stay inside the torrent');
    }
    final String normalizedCurrent =
        p.posix.normalize(currentRelativePath.replaceAll(r'\', '/'));
    if (normalized == normalizedCurrent) {
      // 名字没变：不打扰引擎，也不动库。
      return const RelocateOutcome.unchanged();
    }
    return _run(
      op: (TorrentBackend backend) =>
          backend.renameFile(infoHash, fileIndex, normalized),
      fromPath: p.join(saveRoot, currentRelativePath),
      toPath: p.joinAll(<String>[saveRoot, ...segments]),
    );
  }

  /// 移动：把整个种子的内容搬到 [newSaveRoot]。
  ///
  /// 库侧按「旧 save_path → 新 save_path」整体重映射：该种子下的每个视频、每个
  /// 字幕 sidecar 都跟着走，不需要逐文件登记。
  Future<RelocateOutcome> moveTorrent({
    required String infoHash,
    required String currentSaveRoot,
    required String newSaveRoot,
  }) async {
    final String trimmed = newSaveRoot.trim();
    if (trimmed.isEmpty) {
      return const RelocateOutcome.engineFailed('destination is empty');
    }
    if (p.equals(p.normalize(trimmed), p.normalize(currentSaveRoot))) {
      return const RelocateOutcome.unchanged();
    }
    return _run(
      op: (TorrentBackend backend) => backend.moveStorage(infoHash, trimmed),
      fromPath: currentSaveRoot,
      toPath: trimmed,
    );
  }

  /// 共用骨架：引擎先动，成了再迁库。后端连接每次现开现关（与
  /// `AnimeDownloadService` 每 tick 建后端的姿态一致）。
  Future<RelocateOutcome> _run({
    required Future<TorrentStorageResult> Function(TorrentBackend) op,
    required String fromPath,
    required String toPath,
  }) async {
    final TorrentBackend backend = _backendFactory();
    TorrentStorageResult result;
    try {
      result = await op(backend);
    } catch (e) {
      return RelocateOutcome.engineFailed('$e');
    } finally {
      backend.close();
    }
    if (!result.ok) {
      // 引擎没动 → 库也不动。失败态 = 什么都没变。
      return RelocateOutcome.engineFailed(
          result.error ?? 'backend refused the operation');
    }
    try {
      final int rows =
          await _migrateLibraryPaths(fromPath: fromPath, toPath: toPath);
      return RelocateOutcome.success(
          newPath: result.path ?? toPath, rows: rows);
    } catch (e) {
      // 磁盘已经动了，库没跟上 —— 必须如实报告，绝不当成功。
      return RelocateOutcome.libraryFailed('$e',
          newPath: result.path ?? toPath);
    }
  }
}

/// 一次改名/移动的结局。UI 据此给出不同的提示（三种情况不能混为一谈）。
class RelocateOutcome {
  /// 目标与现状相同：什么都没做（也不该报错）。
  const RelocateOutcome.unchanged()
      : status = RelocateStatus.unchanged,
        newPath = null,
        rowsMigrated = 0,
        error = null;

  /// 引擎拒绝/失败：**磁盘与库都没动**。
  const RelocateOutcome.engineFailed(String reason)
      : status = RelocateStatus.engineFailed,
        newPath = null,
        rowsMigrated = 0,
        error = reason;

  /// 引擎成功、库迁移失败：磁盘已经动了，库还指着旧路径（需要用户知道）。
  const RelocateOutcome.libraryFailed(String reason, {this.newPath})
      : status = RelocateStatus.libraryFailed,
        rowsMigrated = 0,
        error = reason;

  /// 两步都成了。
  const RelocateOutcome.success({required this.newPath, required int rows})
      : status = RelocateStatus.success,
        rowsMigrated = rows,
        error = null;

  final RelocateStatus status;

  /// 新路径（改名 = 种子内相对路径；移动 = 新的 save_path）。
  final String? newPath;

  /// 库里被改到的行数（成功时有意义）。
  final int rowsMigrated;

  /// 失败原因（后端原文优先）。
  final String? error;

  bool get isSuccess => status == RelocateStatus.success;
}

enum RelocateStatus { success, unchanged, engineFailed, libraryFailed }
