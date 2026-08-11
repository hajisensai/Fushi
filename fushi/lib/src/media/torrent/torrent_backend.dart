/// 种子下载后端抽象：把「外接 qBittorrent WebUI」与将来「内置 libtorrent
/// 引擎」统一到同一组接口与中性数据类后面，上层（轮询服务 / 推送对话框）
/// 只依赖本文件，不关心后端实现。
library;

import 'dart:typed_data';

/// A fully resolved input for [TorrentBackend]. Providers must resolve remote
/// `.torrent` URLs before handing work to a backend so every backend sees the
/// same validated bytes and no temporary provider credential is persisted.
sealed class TorrentAddPayload {
  const TorrentAddPayload({required this.torrentId});

  /// The backend-visible 40-character torrent id when known.
  final String? torrentId;
}

class TorrentMagnetPayload extends TorrentAddPayload {
  const TorrentMagnetPayload({
    required this.magnetUri,
    required super.torrentId,
  });

  final String magnetUri;
}

class TorrentMetainfoPayload extends TorrentAddPayload {
  TorrentMetainfoPayload({
    required Uint8List bytes,
    required this.fileName,
    required super.torrentId,
    this.v1InfoHash,
    this.v2InfoHash,
  }) : bytes = Uint8List.fromList(bytes);

  final Uint8List bytes;
  final String fileName;
  final String? v1InfoHash;
  final String? v2InfoHash;
}

/// Optional capability for backends which can ingest validated metainfo
/// bytes. Existing fakes and read-only backends are not forced to implement it.
abstract interface class TorrentMetainfoBackend implements TorrentBackend {
  Future<bool> addTorrentMetainfo(
    TorrentMetainfoPayload payload, {
    required String category,
    bool sequential = false,
    bool firstLastPiecePrio = false,
  });
}

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
    this.totalSizeBytes = -1,
    this.downRateBps = 0,
    this.upRateBps = 0,
    this.downloadedBytes = 0,
    this.uploadedBytes = 0,
    this.numPeers = 0,
    this.numSeeds = -1,
    this.numLeechs = -1,
    this.swarmSeeds = -1,
    this.swarmLeechs = -1,
    this.numConnections = -1,
    this.activeDurationSeconds = -1,
    this.seedingDurationSeconds = -1,
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

  /// 用户实际选中下载的文件总大小；后端未提供时为 -1。
  /// qBittorrent 对应 `total_size`，内置引擎对应 libtorrent `total_wanted`。
  final int totalSizeBytes;

  /// 实时下载速率（字节/秒）。BUG-1294：native/qb 一直导出这些字段，此前在
  /// 本抽象层被整体丢弃，UI 无从显示速度/流量。
  final int downRateBps;

  /// 实时上传速率（字节/秒）。
  final int upRateBps;

  /// 累计下载字节（流量显示用）。
  final int downloadedBytes;

  /// 累计上传字节。
  final int uploadedBytes;

  /// 当前连接的 peer 数。
  final int numPeers;

  /// TODO-2482：以下为详情页拆分字段，`-1` = 后端未提供（旧 DLL / 旧 qb /
  /// 解析缺字段）。[numPeers] 保持「已连接 peer 总数（含 seed）」的旧语义
  /// 不变，既有消费方不迁移。
  ///
  /// 已连接的 seed 数（qb `num_seeds` / native `num_seeds`）。
  final int numSeeds;

  /// 已连接的 leecher 数（qb `num_leechs`；native 侧 = peers - seeds）。
  final int numLeechs;

  /// swarm 总 seed 数（tracker scrape；qb `num_complete`）。
  final int swarmSeeds;

  /// swarm 总 leecher 数（tracker scrape；qb `num_incomplete`）。
  final int swarmLeechs;

  /// 连接数（含握手中的连接，>= [numPeers]；qb 无对应字段时 -1）。
  final int numConnections;

  /// 任务活跃总时长（秒；qb `time_active` / native `active_duration`）。
  final int activeDurationSeconds;

  /// 做种总时长（秒；qb `seeding_time` / native `seeding_duration`）。
  final int seedingDurationSeconds;

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
  static const Set<String> _errorStates = <String>{'error', 'missingFiles'};

  /// 是否已下载完成：state 属于做种类直接算完成；否则要求进度打满
  /// （`progress >= 1.0` 或 `amountLeft == 0`）且 state 不是 error 类。
  bool get isComplete {
    if (_seedingStates.contains(state)) return true;
    if (_errorStates.contains(state)) return false;
    return progress >= 1.0 || amountLeft == 0;
  }

  /// 后端已明确进入不可继续的错误态。暂停态不是失败：暂停/恢复后计划仍继续
  /// downloading，并保留实时进度。
  bool get isFailure => _errorStates.contains(state);
}

/// 支持真实取消/删除种子的后端能力。单独拆接口，避免只读 fake 被迫伪造支持；
/// qBittorrent 与内置引擎都实现，调用方仅在 capability 存在时触发。
abstract interface class TorrentRemovalBackend implements TorrentBackend {
  Future<bool> removeTorrent(String torrentId, {bool deleteFiles = false});
}

/// TODO-2481：支持暂停/恢复单个种子的后端能力。与 [TorrentRemovalBackend]
/// 同姿态的可选能力接口：UI 用 `backend is TorrentPauseBackend` 探测，
/// 只读 fake 不被迫伪造支持。
///
/// qBittorrent 与内置引擎都实现；内置引擎在随包 DLL 过旧（缺
/// `ht_pause_torrent` 符号）时 [pauseControlAvailable] 为 false ——
/// 类型探测过了也要看这一位，否则按钮点了永远失败。
abstract interface class TorrentPauseBackend implements TorrentBackend {
  /// 运行时能力位：底层是否真的具备暂停/恢复原语。
  bool get pauseControlAvailable;

  /// 暂停种子（qb：stop/pause；内置：清 auto_managed 再 pause）。
  /// 失败（种子不存在/后端不支持）返回 false，绝不抛。
  Future<bool> pauseTorrent(String torrentId);

  /// 恢复种子（qb：start/resume；内置：恢复 auto_managed 并 resume）。
  Future<bool> resumeTorrent(String torrentId);
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

/// TODO-2482：任务详情能力接口（qb/hayase 式四 tab 详情页的数据面）。
///
/// 与 [TorrentRemovalBackend] / [TorrentPauseBackend] 同姿态的可选能力：
/// UI 用 `backend is TorrentDetailBackend` 探测，缺能力的后端不被迫伪造；
/// 探测过了还要看 [detailAvailable]（内置引擎随包 DLL 过旧、缺详情符号时
/// 为 false，此时各查询返回 null，UI 显示「当前后端不支持」）。
///
/// 所有查询方法容错：失败/种子不存在/后端拿不到一律返回 null，绝不抛
/// （与 [TorrentBackend] 契约同姿态）。
abstract interface class TorrentDetailBackend implements TorrentBackend {
  /// 运行时能力位：底层是否真的具备详情查询原语。
  bool get detailAvailable;

  /// 某种子当前连接的 peer 列表；种子不存在/失败返回 null。
  Future<List<TorrentPeerDetail>?> listPeers(String torrentId);

  /// 某种子的 tracker 列表（含 scrape 数与错误信息）。
  Future<List<TorrentTrackerDetail>?> listTrackers(String torrentId);

  /// 每个文件的下载优先级，按文件 index 对位（与
  /// [TorrentBackend.listFiles] 的 `index` 同一值域）。
  Future<List<TorrentFilePriority>?> filePriorities(String torrentId);

  /// 设置单个文件的优先级（[TorrentFilePriority.skip] = 不下载）。
  Future<bool> setFilePriority(
    String torrentId,
    int fileIndex,
    TorrentFilePriority priority,
  );

  /// 会话级协议状态（DHT/LSD/PEX/端口映射/监听端口/全局速率）。
  Future<TorrentSessionStatusInfo?> sessionStatus();

  /// 某种子的 piece 位图（0 = 缺、1 = 下载中、2 = 已持有）。
  Future<TorrentPieceStates?> pieceStates(String torrentId);
}

/// 文件下载优先级的后端无关值域。
///
/// 映射：内置引擎（libtorrent download_priority）skip=0 / normal=4 / high=7；
/// qb（filePrio）skip=0 / normal=1 / high=6。
enum TorrentFilePriority { skip, normal, high }

/// 详情页 Peers tab 的单行（后端无关）。
class TorrentPeerDetail {
  const TorrentPeerDetail({
    required this.address,
    required this.port,
    this.client = '',
    this.progress = 0.0,
    this.downSpeedBps = 0,
    this.upSpeedBps = 0,
    this.downloadedBytes = 0,
    this.uploadedBytes = 0,
    this.flags = '',
  });

  /// peer IP（qb 侧可能是域名形式的 ip 字段原文）。
  final String address;
  final int port;

  /// 客户端标识（如 `qBittorrent/4.6.5`）。
  final String client;

  /// peer 自报进度 0~1（可伪造）。
  final double progress;
  final int downSpeedBps;
  final int upSpeedBps;

  /// 累计从该 peer 下到的字节。
  final int downloadedBytes;

  /// 累计喂给该 peer 的字节。
  final int uploadedBytes;

  /// qb 风格 flag 字母串（如 `D U K`；内置引擎经
  /// `formatTorrentPeerFlags` 从原始位掩码格式化）。
  final String flags;
}

/// tracker 工作状态的后端无关值域（qb trackers `status` 同值域）。
enum TorrentTrackerStatus {
  /// 已禁用（qb 0；DHT/PEX/LSD 伪条目也归此类）。
  disabled,

  /// 尚未联系过（qb 1）。
  notContacted,

  /// 工作中（qb 2）。
  working,

  /// 正在更新（qb 3）。
  updating,

  /// 不工作（qb 4；含连续失败）。
  notWorking,
}

/// 详情页 Trackers tab 的单行（后端无关）。`-1` = scrape 未提供。
class TorrentTrackerDetail {
  const TorrentTrackerDetail({
    required this.url,
    this.tier = 0,
    this.status = TorrentTrackerStatus.notContacted,
    this.seeds = -1,
    this.leeches = -1,
    this.downloaded = -1,
    this.message = '',
  });

  final String url;
  final int tier;
  final TorrentTrackerStatus status;

  /// scrape 的 seed 数（qb `num_seeds` / native `scrape_complete`）。
  final int seeds;

  /// scrape 的 leecher 数（qb `num_leeches` / native `scrape_incomplete`）。
  final int leeches;

  /// scrape 的累计完成下载数（qb `num_downloaded` / `scrape_downloaded`）。
  final int downloaded;

  /// 最近一次 announce 的错误/提示信息（tracker 原文，空串 = 无）。
  final String message;
}

/// 一条端口映射结果（UPnP / NAT-PMP）。
class TorrentPortMappingInfo {
  const TorrentPortMappingInfo({
    required this.transport,
    required this.protocol,
    this.externalPort = 0,
    this.ok = false,
    this.error = '',
  });

  /// `upnp` | `natpmp`。
  final String transport;

  /// `tcp` | `udp`。
  final String protocol;

  /// 映射成功时的外部端口（失败为 0）。
  final int externalPort;
  final bool ok;

  /// 失败原因（路由器/协议原文，空串 = 无）。
  final String error;
}

/// 会话级协议状态。`null` 字段 = 该后端不知道（UI 整行不渲染）；
/// 速率 `-1` = 未知。
class TorrentSessionStatusInfo {
  const TorrentSessionStatusInfo({
    this.dhtEnabled,
    this.dhtNodes = -1,
    this.lsdEnabled,
    this.pexEnabled,
    this.listenPort = 0,
    this.downRateBps = -1,
    this.upRateBps = -1,
    this.portMappings = const <TorrentPortMappingInfo>[],
  });

  /// DHT 是否开启（qb 走 preferences，native 走 is_dht_running）。
  final bool? dhtEnabled;

  /// DHT 路由表节点数（-1 = 未知/尚未统计到）。
  final int dhtNodes;
  final bool? lsdEnabled;
  final bool? pexEnabled;

  /// 实际监听端口（0 = 未知/未监听）。
  final int listenPort;

  /// 会话级全局下行速率（字节/秒；-1 = 未知）。
  final int downRateBps;
  final int upRateBps;
  final List<TorrentPortMappingInfo> portMappings;
}

/// 某种子的 piece 位图（详情页 Overview 的 piece bar）。
class TorrentPieceStates {
  const TorrentPieceStates({required this.states});

  /// 每 piece 一项：0 = 缺、1 = 下载中、2 = 已持有（qb pieceStates 值域；
  /// 内置引擎位图只有 0/2 两态）。
  final List<int> states;

  int get numPieces => states.length;

  int get haveCount {
    int n = 0;
    for (final int s in states) {
      if (s == 2) n++;
    }
    return n;
  }
}
