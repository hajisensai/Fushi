/// 种子下载后端抽象：把「外接 qBittorrent WebUI」与将来「内置 libtorrent
/// 引擎」统一到同一组接口与中性数据类后面，上层（轮询服务 / 推送对话框）
/// 只依赖本文件，不关心后端实现。
library;

/// 某一时刻单个种子任务的快照（后端无关）。
class TorrentSnapshot {
  const TorrentSnapshot({
    required this.hash,
    required this.name,
    required this.progress,
    required this.state,
    required this.savePath,
    required this.contentPath,
    required this.amountLeft,
  });

  /// 种子 infohash（小写十六进制），后续查文件列表用。
  final String hash;

  /// 种子显示名。
  final String name;

  /// 下载进度 0.0 ~ 1.0。
  final double progress;

  /// 后端状态字符串（qBittorrent：`downloading` / `uploading` / `stalledUP` 等）。
  final String state;

  /// 保存目录。
  final String savePath;

  /// 内容根路径：单文件为文件路径，多文件为目录。
  final String contentPath;

  /// 剩余待下载字节数；解析不出为 -1（= 未知，不当作完成）。
  final int amountLeft;

  /// 做种/完成类状态：数据已全部落盘，只在做种或做种停止。
  static const Set<String> _seedingStates = <String>{
    'uploading',
    'stalledUP',
    'pausedUP',
    'stoppedUP',
    'queuedUP',
    'forcedUP',
  };

  /// 错误类状态：即使进度显示 100% 也不视为可用完成态。
  static const Set<String> _errorStates = <String>{
    'error',
    'missingFiles',
  };

  /// 是否已下载完成：state 属于做种类直接算完成；否则要求进度打满
  /// （`progress >= 1.0` 或 `amountLeft == 0`）且 state 不是 error 类。
  bool get isComplete {
    if (_seedingStates.contains(state)) return true;
    if (_errorStates.contains(state)) return false;
    return progress >= 1.0 || amountLeft == 0;
  }
}

/// 种子内的单个文件（后端无关）。
class TorrentFileEntry {
  const TorrentFileEntry({
    required this.name,
    required this.size,
    required this.progress,
    required this.index,
  });

  /// 种子内相对路径（如 `Season 01/EP01.mkv`）。
  final String name;

  /// 文件大小（字节）。
  final int size;

  /// 该文件的下载进度 0.0 ~ 1.0。
  final double progress;

  /// 文件在种子内的序号；缺省 -1。
  final int index;
}

/// 种子下载后端接口。所有方法容错：异常/失败一律返回
/// null / false / 空列表，绝不抛（与现有 qb 客户端契约一致）。
abstract interface class TorrentBackend {
  /// 连接/就绪测试。成功返回可读的版本/标识字符串（qb = WebUI 版本号），
  /// 失败返回 null。
  Future<String?> probeConnection();

  /// 确保分类/标签可用（qb = createCategory；内置引擎将来 no-op 返 true）。
  Future<bool> prepareCategory(String category);

  /// 添加下载：[magnetOrUrl] 是 magnet 链接或 .torrent URL。
  ///
  /// [sequential] 开顺序下载、[firstLastPiecePrio] 开首尾块优先：两者齐开时
  /// 视频文件从下载初期就可顺序播放（边下边播的前置条件）。
  Future<bool> addTorrent(
    String magnetOrUrl, {
    required String category,
    bool sequential = false,
    bool firstLastPiecePrio = false,
  });

  /// 列种子；[category] 非空时只列该分类。
  Future<List<TorrentSnapshot>> listTorrents({String? category});

  /// 列某个种子内的文件；[torrentId] 是 infohash。
  Future<List<TorrentFileEntry>> listFiles(String torrentId);

  /// TODO-1961-c：给种子内的一个文件改名（[newPath] 是种子内相对路径，可含
  /// 子目录，分隔符 `/`）。**必须走后端**而不是 `File.rename` —— 引擎按自己
  /// 记的路径读盘上传，绕过它改名 = 当场掐断做种。
  ///
  /// 与本接口其它方法不同，这里返回 [TorrentStorageResult] 而不是 bool：
  /// 失败原因（目标已存在 / 权限不足）必须能原样呈现给用户。
  Future<TorrentStorageResult> renameFile(
    String torrentId,
    int fileIndex,
    String newPath,
  );

  /// TODO-1961-c：把种子内容整体移动到 [newSavePath]。同样必须走后端。
  /// 目标已存在同名文件时应当失败而不是覆盖用户数据。
  Future<TorrentStorageResult> moveStorage(
    String torrentId,
    String newSavePath,
  );

  /// 释放底层连接资源。
  void close();
}

/// 改名 / 移动的结果。失败时 [error] 必须带上可读原因（后端原文优先）。
class TorrentStorageResult {
  const TorrentStorageResult({required this.ok, this.path, this.error});

  const TorrentStorageResult.failure(String reason)
      : ok = false,
        path = null,
        error = reason;

  /// 是否成功落地。
  final bool ok;

  /// 成功时的新路径（改名 = 种子内相对路径；移动 = 新的 save_path）。
  final String? path;

  /// 失败原因。调用方**必须**反馈给用户，不得静默吞掉。
  final String? error;
}
