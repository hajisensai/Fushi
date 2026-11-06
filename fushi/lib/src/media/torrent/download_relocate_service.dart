import 'package:path/path.dart' as p;

import 'package:fushi_engine/media/torrent/torrent_backend.dart';
import 'package:fushi_engine/media/video/download/video_download_path_mapping.dart';
import 'package:fushi_engine/media/video/video_path_migration.dart';

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
///
/// **两套坐标（BUG-3539）**：后端报告的 save_path、收的 moveStorage 目标都是
/// **后端坐标**（外接远端 qBittorrent 是它那台机器上的路径）；库与任务文件行存的
/// 是**本机坐标**。两者之间只认下载流水线同一份路径映射契约
/// （[effectiveVideoDownloadPathMappings]：显式映射优先，没配映射只在后端保存
/// 位置真实存在于本机时按同机处理）。映射不到就在动引擎**之前**拒绝——既不把
/// 本机路径发给远端，也不拿远端路径去改本机库。
class DownloadRelocateService {
  const DownloadRelocateService({
    required TorrentBackend Function() backendFactory,
    required Future<List<VideoDownloadPathMapping>> Function() pathMappings,
    required Future<int> Function(DownloadRelocation relocation)
    applyRelocation,
  }) : _backendFactory = backendFactory,
       _pathMappings = pathMappings,
       _applyRelocation = applyRelocation;

  final TorrentBackend Function() _backendFactory;
  final Future<List<VideoDownloadPathMapping>> Function() _pathMappings;
  final Future<int> Function(DownloadRelocation relocation) _applyRelocation;

  /// 改名：把种子内下标 [fileIndex] 的文件改成 [newRelativePath]
  /// （种子内相对路径，可含子目录，分隔符 `/`）。
  ///
  /// [backendSaveRoot] 是后端报告的该种子当前 save_path（后端坐标），经路径映射
  /// 换成本机路径后才能拼出库里存的绝对路径。
  Future<RelocateOutcome> renameFile({
    required String infoHash,
    required int fileIndex,
    required String currentRelativePath,
    required String newRelativePath,
    required String backendSaveRoot,
  }) async {
    final String trimmed = newRelativePath.trim();
    if (trimmed.isEmpty) {
      return const RelocateOutcome.engineFailed('new name is empty');
    }
    // 种子内路径跨平台固定用 POSIX `/`；只有拼进本地 save root 时才转成
    // 宿主分隔符。否则 Windows 会把传给 qB/libtorrent 的路径改成 `\`。
    final List<String>? segments = _torrentRelativeSegments(trimmed);
    if (segments == null || p.windows.rootPrefix(trimmed).isNotEmpty) {
      return const RelocateOutcome.engineFailed(
        'new name must stay inside the torrent',
      );
    }
    final String normalized = p.posix.joinAll(segments);
    final List<String>? currentSegments = _torrentRelativeSegments(
      currentRelativePath,
    );
    if (currentSegments != null &&
        p.posix.joinAll(currentSegments) == normalized) {
      // 名字没变：不打扰引擎，也不动库。
      return const RelocateOutcome.unchanged();
    }
    if (currentSegments == null) {
      return const RelocateOutcome.engineFailed(
        'current file path is outside the torrent',
      );
    }
    final _LocalSaveRoot? root = await _localSaveRoot(backendSaveRoot);
    if (root == null) return _unmappedSaveRoot;
    final DownloadRelocation relocation = DownloadRelocation(
      infoHash: infoHash,
      movedFiles: MovedMediaFiles(<String, String>{
        p.joinAll(<String>[root.localPath, ...currentSegments]): p.joinAll(
          <String>[root.localPath, ...segments],
        ),
      }),
      renamedFileIndex: fileIndex,
      renamedRelativePath: normalized,
    );
    return _run(
      op: (TorrentBackend backend) =>
          backend.renameFile(infoHash, fileIndex, normalized),
      describe: () => relocation,
      fallbackNewPath: normalized,
    );
  }

  /// 移动：把整个种子的内容搬到本机目录 [newLocalSaveRoot]（用户在本机挑的
  /// 文件夹，本机坐标）。
  ///
  /// 发给后端的是它经路径映射换成的后端坐标；库侧只改**种子自己的文件**——动
  /// 引擎前从后端现取文件列表，逐文件登记旧 → 新（引擎不搬的字幕 sidecar 原地
  /// 不动，库也不该改它，BUG-3538）。
  Future<RelocateOutcome> moveTorrent({
    required String infoHash,
    required String backendSaveRoot,
    required String newLocalSaveRoot,
  }) async {
    final String trimmed = newLocalSaveRoot.trim();
    if (trimmed.isEmpty) {
      return const RelocateOutcome.engineFailed('destination is empty');
    }
    final _LocalSaveRoot? root = await _localSaveRoot(backendSaveRoot);
    if (root == null) return _unmappedSaveRoot;
    final String destination = p.normalize(p.absolute(trimmed));
    if (p.equals(destination, root.localPath)) {
      return const RelocateOutcome.unchanged();
    }
    // 目的地按同一份有效映射换成后端坐标。没配显式映射时，能走到这里说明后端
    // 保存位置真实存在于本机（同机），目的地所在的盘也按同机处理。
    final String? remoteDestination = videoDownloadLocalToRemote(
      root.configured.isEmpty
          ? effectiveVideoDownloadPathMappings(
              const <VideoDownloadPathMapping>[],
              sameMachineAnchors: <String?>[root.localPath, destination],
            )
          : root.configured,
      destination,
    );
    if (remoteDestination == null) {
      return const RelocateOutcome.engineFailed(
        'destination is outside every download path mapping',
      );
    }
    List<TorrentFileEntry> files = const <TorrentFileEntry>[];
    return _run(
      prepare: (TorrentBackend backend) async {
        files = await backend.listFiles(infoHash);
      },
      op: (TorrentBackend backend) =>
          backend.moveStorage(infoHash, remoteDestination),
      describe: () {
        final Map<String, String> moves = <String, String>{};
        for (final TorrentFileEntry file in files) {
          final List<String>? segments = _torrentRelativeSegments(file.name);
          if (segments == null) continue;
          moves[p.joinAll(<String>[root.localPath, ...segments])] = p.joinAll(
            <String>[destination, ...segments],
          );
        }
        return DownloadRelocation(
          infoHash: infoHash,
          movedFiles: MovedMediaFiles(moves),
          newBackendSavePath: remoteDestination,
        );
      },
      fallbackNewPath: remoteDestination,
    );
  }

  static const RelocateOutcome _unmappedSaveRoot = RelocateOutcome.engineFailed(
    'the download location is not reachable on this device; '
    'configure a download path mapping for this backend',
  );

  /// 后端坐标的 save_path → 本机路径（经有效映射）；映射不到返回 null。
  Future<_LocalSaveRoot?> _localSaveRoot(String backendSaveRoot) async {
    final String remote = backendSaveRoot.trim();
    if (remote.isEmpty) return null;
    final List<VideoDownloadPathMapping> configured;
    try {
      configured = await _pathMappings();
    } catch (_) {
      return null;
    }
    final String? local = videoDownloadRemoteToLocal(
      effectiveVideoDownloadPathMappings(
        configured,
        sameMachineAnchors: <String?>[remote],
      ),
      remote,
    );
    if (local == null) return null;
    return _LocalSaveRoot(
      localPath: p.normalize(p.absolute(local)),
      configured: configured,
    );
  }

  /// 共用骨架：引擎先动，成了再迁库。后端连接每次现开现关（与
  /// `AnimeDownloadService` 每 tick 建后端的姿态一致）。
  Future<RelocateOutcome> _run({
    Future<void> Function(TorrentBackend)? prepare,
    required Future<TorrentStorageResult> Function(TorrentBackend) op,
    required DownloadRelocation Function() describe,
    required String fallbackNewPath,
  }) async {
    final TorrentBackend backend = _backendFactory();
    TorrentStorageResult result;
    try {
      // 动引擎之前现取要登记的东西（如移动前的文件列表）；取不到就不动引擎。
      await prepare?.call(backend);
      result = await op(backend);
      if (!result.ok) {
        // 引擎没动 → 库也不动。失败态 = 什么都没变。
        return RelocateOutcome.engineFailed(
          result.error ?? 'backend refused the operation',
        );
      }
    } catch (e) {
      return RelocateOutcome.engineFailed('$e');
    } finally {
      backend.close();
    }
    try {
      final int rows = await _applyRelocation(describe());
      return RelocateOutcome.success(
        newPath: result.path ?? fallbackNewPath,
        rows: rows,
      );
    } catch (e) {
      // 磁盘已经动了，库没跟上 —— 必须如实报告，绝不当成功。
      return RelocateOutcome.libraryFailed(
        '$e',
        newPath: result.path ?? fallbackNewPath,
      );
    }
  }

  /// 种子内相对路径 → POSIX 段；绝对路径 / 逃逸出种子（`..`）返回 null。
  static List<String>? _torrentRelativeSegments(String relativePath) {
    final String portable = relativePath.trim().replaceAll(r'\', '/');
    if (portable.isEmpty || p.posix.isAbsolute(portable)) return null;
    final String normalized = p.posix.normalize(portable);
    if (normalized == '.') return null;
    final List<String> segments = p.posix.split(normalized);
    if (segments.isEmpty || segments.first == '..') return null;
    return segments;
  }
}

class _LocalSaveRoot {
  const _LocalSaveRoot({required this.localPath, required this.configured});

  /// 种子当前保存位置的本机路径。
  final String localPath;

  /// 该后端配置档的显式映射（空 = 同机）。
  final List<VideoDownloadPathMapping> configured;
}

/// 一次改名/移动的结局。UI 据此给出不同的提示（三种情况不能混为一谈）。
class RelocateOutcome {
  /// 目标与现状相同：什么都没做（也不该报错）。
  const RelocateOutcome.unchanged()
    : status = RelocateStatus.unchanged,
      newPath = null,
      rowsMigrated = 0,
      error = null;

  /// 引擎拒绝/失败（或动引擎前就判定做不成）：**磁盘与库都没动**。
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

  /// 新路径（改名 = 种子内相对路径；移动 = 新的 save_path，后端坐标）。
  final String? newPath;

  /// 库里被改到的行数（成功时有意义）。
  final int rowsMigrated;

  /// 失败原因（后端原文优先）。
  final String? error;

  bool get isSuccess => status == RelocateStatus.success;
}

enum RelocateStatus { success, unchanged, engineFailed, libraryFailed }
