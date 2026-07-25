import 'dart:io';

import 'package:hibiki/src/media/torrent/download_save_root.dart';
import 'package:hibiki/src/media/torrent/torrent_backend.dart';
import 'package:hibiki_torrent/hibiki_torrent.dart';

/// [TorrentBackend] 的内置 libtorrent 实现（阶段1b：Windows 先行）。
///
/// 映射约定：
/// - 分类 = `<活动下载根>/<category>/` 子目录：add 落到活动根的分类目录，
///   listTorrents 按 [TorrentSaveRoots.ownsCategoryPath] 认**所有**根（活动 +
///   历史）—— 目录即真相，不另建分类账本。TODO-1961：用户改下载目录后，旧任务
///   的 savePath 仍指着旧根，只认单根会让它们整批从下载页消失。
/// - [addTorrent] 只接受 magnet 链接与本地 .torrent 文件路径；
///   http(s) .torrent URL 是外接 qb 的能力，内置引擎的选种链路
///   （Nyaa）本来就产 magnet，不为不存在的调用方加下载器。
/// - firstLastPiecePrio：libtorrent 无 add 期开关（元数据未就绪无从提优），
///   记入 [_pendingFirstLast]，在每次 [listTorrents] 轮询时补应用 ——
///   上层服务本就以 20s tick 轮询，无需额外定时器。
/// - close 只关本后端持有的 session；引擎（DLL）进程级共享不关。
class EmbeddedTorrentBackend implements TorrentBackend {
  EmbeddedTorrentBackend({
    required EmbeddedTorrentSession session,
    required TorrentSaveRoots saveRoots,
    bool closesSession = true,
  })  : _session = session,
        _saveRoots = saveRoots,
        _closesSession = closesSession;

  final EmbeddedTorrentSession _session;

  /// 活动根 + 历史根。写入只用活动根，列表认全部（见类注释）。
  final TorrentSaveRoots _saveRoots;

  /// close() 是否真的销毁底层 session。standalone/测试用途持有自己的
  /// session → true；app 侧 [EmbeddedTorrentHost] 派发的短命适配器共享
  /// 常驻 session → false（每 tick 建/关适配器不能连累会话）。
  final bool _closesSession;

  /// 已添加但 firstLastPiecePrio 尚未应用成功（等元数据）的种子。
  final Set<String> _pendingFirstLast = <String>{};

  /// 就绪测试 = 引擎版本串（如 `libtorrent 2.0.11.0`）；session 已关返回 null。
  @override
  Future<String?> probeConnection() async {
    if (_session.isClosed) return null;
    final String version = _session.engine.libtorrentVersion();
    return version.isEmpty ? null : 'libtorrent $version';
  }

  /// 分类目录建好即可用（永远建在**活动**根下）。
  @override
  Future<bool> prepareCategory(String category) async {
    try {
      await Directory(_categoryPath(category)).create(recursive: true);
      return true;
    } on FileSystemException {
      return false;
    }
  }

  @override
  Future<bool> addTorrent(
    String magnetOrUrl, {
    required String category,
    bool sequential = false,
    bool firstLastPiecePrio = false,
  }) async {
    final String savePath = _categoryPath(category);
    if (!await prepareCategory(category)) return false;
    final HtAddResult result;
    if (magnetOrUrl.startsWith('magnet:')) {
      result = _session.addMagnet(magnetOrUrl,
          savePath: savePath, sequential: sequential);
    } else if (magnetOrUrl.toLowerCase().endsWith('.torrent') &&
        !magnetOrUrl.contains('://')) {
      result = _session.addTorrentFile(magnetOrUrl,
          savePath: savePath, sequential: sequential);
    } else {
      // http(s) .torrent URL：内置引擎不支持（见类注释）。
      return false;
    }
    if (!result.ok || result.id == null) return false;
    if (firstLastPiecePrio) {
      // 立即试一次（.torrent 文件路径元数据现成）；不成留待轮询补。
      if (_session.applyFirstLastPriority(result.id!) != 1) {
        _pendingFirstLast.add(result.id!);
      }
    }
    return true;
  }

  @override
  Future<List<TorrentSnapshot>> listTorrents({String? category}) async {
    _applyPendingFirstLast();
    return _session
        .listTorrents()
        .where((HtTorrentStatus t) =>
            category == null ||
            _saveRoots.ownsCategoryPath(t.savePath, category))
        .map(_toSnapshot)
        .toList(growable: false);
  }

  @override
  Future<List<TorrentFileEntry>> listFiles(String torrentId) async {
    final List<HtFileEntry>? files = _session.torrentFiles(torrentId);
    if (files == null) return const <TorrentFileEntry>[];
    return files
        .map((HtFileEntry f) => TorrentFileEntry(
              name: f.path,
              size: f.size,
              progress: f.size <= 0 ? 1.0 : (f.done / f.size).clamp(0.0, 1.0),
              index: f.index,
            ))
        .toList(growable: false);
  }

  @override
  void close() {
    if (_closesSession) _session.close();
  }

  String _categoryPath(String category) => _saveRoots.categoryPathFor(category);

  /// 元数据未就绪时挂起的首尾块提优，随轮询补应用。
  void _applyPendingFirstLast() {
    if (_pendingFirstLast.isEmpty) return;
    _pendingFirstLast.removeWhere((String id) {
      final int result = _session.applyFirstLastPriority(id);
      // 1 = 应用成功；-1 = 种子已不存在 —— 两者都不必再试。
      return result != 0;
    });
  }

  TorrentSnapshot _toSnapshot(HtTorrentStatus t) {
    return TorrentSnapshot(
      hash: t.id,
      name: t.name,
      progress: t.progress,
      state: t.state,
      savePath: t.savePath,
      contentPath: t.contentPath,
      amountLeft: t.left,
    );
  }
}
