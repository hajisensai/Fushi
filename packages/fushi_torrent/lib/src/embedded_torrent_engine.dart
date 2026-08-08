import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

import 'ffi/fushi_torrent_bindings.dart';

/// 内置 libtorrent 引擎的 Dart 侧薄封装（阶段1b：真实下载管线）。
///
/// [EmbeddedTorrentEngine] 负责加载原生库与无 session 的全局调用；
/// [EmbeddedTorrentSession] 是一个 libtorrent session 的高层句柄封装
/// （磁力/元数据/顺序下载/进度/边下边播原语）。
class EmbeddedTorrentEngine {
  EmbeddedTorrentEngine._(this.bindings);

  /// 直接用一组已有的 [FushiTorrentBindings] 构造引擎，跳过动态库加载。
  ///
  /// 存在的理由：随包的 native 库是 Windows 预编译产物，CI 的绝大多数测试环境
  /// 里根本没有它（要 `FUSHI_TORRENT_LIB`），于是"限速开关有没有真的传到
  /// native"这类不变量就没有任何**必跑**的用例守着。配合
  /// [FushiTorrentBindings.fromLookup] + `Pointer.fromFunction`，可以在纯 Dart
  /// 里把整条 Dart 侧链路（session → bindings → C 入参）跑通并断言，不依赖 DLL。
  EmbeddedTorrentEngine.fromBindings(this.bindings);

  /// 底层 FFI 绑定（高级封装之外的逃生口）。
  final FushiTorrentBindings bindings;

  /// 加载本地原生库并构造引擎。[libraryPath] 显式指定 DLL/so/dylib 绝对路径
  /// （standalone 构建产物或 harness 传入）；缺省按平台默认名从系统搜索路径找。
  factory EmbeddedTorrentEngine.open({String? libraryPath}) {
    if (libraryPath != null && Platform.isWindows) {
      // Windows LoadLibrary 不把目标 DLL 所在目录纳入其依赖搜索路径（打包
      // 后依赖在 exe 旁没这问题；standalone 测试/harness 会 126）。先把同
      // 目录里 vcpkg applocal 部署的依赖 DLL 预载进进程，之后按模块名即可
      // 命中。依赖间有先后（libssl 依赖 libcrypto），用「有进展就再来一轮」
      // 消序。
      _preloadSiblingLibraries(libraryPath);
    }
    final DynamicLibrary lib = libraryPath != null
        ? DynamicLibrary.open(libraryPath)
        : _openByPlatformDefault();
    return EmbeddedTorrentEngine._(FushiTorrentBindings(lib));
  }

  static void _preloadSiblingLibraries(String libraryPath) {
    final Directory dir = File(libraryPath).parent;
    if (!dir.existsSync()) return;
    final String target = libraryPath.replaceAll('\\', '/').split('/').last;
    List<String> pending = dir
        .listSync()
        .whereType<File>()
        .map((File f) => f.path)
        .where((String path) {
      final String name = path.replaceAll('\\', '/').split('/').last;
      return name.toLowerCase().endsWith('.dll') && name != target;
    }).toList();
    bool progressed = true;
    while (progressed && pending.isNotEmpty) {
      progressed = false;
      final List<String> failed = <String>[];
      for (final String path in pending) {
        try {
          DynamicLibrary.open(path);
          progressed = true;
        } on ArgumentError {
          failed.add(path); // 依赖未就绪或无关库；留待下一轮/放弃。
        }
      }
      pending = failed;
    }
  }

  /// 平台默认库名候选。
  ///
  /// 曾经带 `hibiki_torrent_ffi` 旧名兜底，理由是「改名前发布的包里躺着的是旧名，
  /// 按名加载走 exe 同目录，只认新名会让存量用户静默回退外接 qb」。W9 起该理由
  /// 不成立：Windows 安装器 [InstallDelete] 已显式删除升级路径上的旧名 DLL
  /// （见 fushi.iss），macOS/Android 的包是整体替换，任何平台的 exe 同目录都不会
  /// 再有旧名产物。留着回退反而危险——新 DLL 万一缺失时会静默加载上一版的旧 ABI，
  /// 拿新 bindings 去调旧符号，失败方式比「引擎不可用」难查得多。
  /// iOS 静态链进主二进制，不参与按名查找。
  static List<String> defaultLibraryNames() {
    if (Platform.isWindows) {
      return const <String>['fushi_torrent_ffi.dll'];
    }
    if (Platform.isMacOS) {
      return const <String>['libfushi_torrent_ffi.dylib'];
    }
    if (Platform.isLinux || Platform.isAndroid) {
      return const <String>['libfushi_torrent_ffi.so'];
    }
    return const <String>[];
  }

  static DynamicLibrary _openByPlatformDefault() {
    if (Platform.isIOS) return DynamicLibrary.process();
    final List<String> names = defaultLibraryNames();
    if (names.isEmpty) {
      throw UnsupportedError(
          'fushi_torrent: unsupported platform ${Platform.operatingSystem}');
    }
    ArgumentError? lastError;
    for (final String name in names) {
      try {
        return DynamicLibrary.open(name);
      } on ArgumentError catch (e) {
        lastError = e; // 该候选名不存在/加载失败，退到下一个名字。
      }
    }
    throw lastError!;
  }

  /// libtorrent 运行时版本串（如 "2.0.11.0"）。
  String libtorrentVersion() {
    final Pointer<Char> p = bindings.ht_libtorrent_version();
    if (p == nullptr) return '';
    return p.cast<Utf8>().toDartString();
  }

  /// 从本地文件/目录生成 .torrent（本地做种与确定性测试支撑）。
  FtAddResult makeTorrent({
    required String contentPath,
    required String outTorrentPath,
  }) {
    final Pointer<Char> content = contentPath.toNativeUtf8().cast<Char>();
    final Pointer<Char> out = outTorrentPath.toNativeUtf8().cast<Char>();
    try {
      return FtAddResult._fromJson(
          _consumeJson(bindings.ht_make_torrent(content, out)));
    } finally {
      malloc.free(content);
      malloc.free(out);
    }
  }

  /// 创建底层 session 句柄（低层 API；一般用 [EmbeddedTorrentSession.open]）。
  /// [listenInterfaces] null/空 = 不监听（阶段1a 空壳语义，冒烟测试用）。
  Pointer<Void> createSession(
      {String? listenInterfaces, bool enableDht = false}) {
    if (listenInterfaces == null || listenInterfaces.isEmpty) {
      return bindings.ht_session_create(nullptr, enableDht ? 1 : 0);
    }
    final Pointer<Char> listen = listenInterfaces.toNativeUtf8().cast<Char>();
    try {
      return bindings.ht_session_create(listen, enableDht ? 1 : 0);
    } finally {
      malloc.free(listen);
    }
  }

  /// 销毁 session 句柄（[nullptr] 为 no-op）。
  void destroySession(Pointer<Void> session) =>
      bindings.ht_session_destroy(session);

  /// 读走并释放原生 JSON 串。
  Object? _consumeJson(Pointer<Char> p) {
    if (p == nullptr) return null;
    try {
      return jsonDecode(p.cast<Utf8>().toDartString());
    } on FormatException {
      return null;
    } finally {
      bindings.ht_free_string(p);
    }
  }
}

/// 添加/生成种子操作的结果。
class FtAddResult {
  const FtAddResult({required this.ok, this.id, this.error});

  final bool ok;

  /// 成功时的 infohash（小写十六进制）。
  final String? id;

  final String? error;

  factory FtAddResult._fromJson(Object? json) {
    if (json is! Map<String, dynamic>) {
      return const FtAddResult(ok: false, error: 'bad native response');
    }
    return FtAddResult(
      ok: json['ok'] == true,
      id: json['id'] as String?,
      error: json['error'] as String?,
    );
  }
}

/// 一个种子任务的状态快照（native `ht_list_torrents` 单项）。
class FtTorrentStatus {
  const FtTorrentStatus({
    required this.id,
    required this.name,
    required this.progress,
    required this.state,
    required this.savePath,
    required this.contentPath,
    required this.total,
    required this.done,
    required this.left,
    required this.downRate,
    required this.upRate,
    required this.uploaded,
    required this.downloaded,
    required this.numPeers,
    required this.hasMetadata,
    required this.isFinished,
    required this.isSeeding,
    required this.sequential,
    this.numSeeds = -1,
    this.numConnections = -1,
    this.numComplete = -1,
    this.numIncomplete = -1,
    this.isPaused = false,
    this.activeDurationSeconds = -1,
    this.seedingDurationSeconds = -1,
    this.finishedDurationSeconds = -1,
  });

  final String id;
  final String name;

  /// 0.0 ~ 1.0。
  final double progress;

  /// "metadata" | "checking" | "downloading" | "finished" | "seeding" | "error"
  final String state;
  final String savePath;

  /// 单文件 = 文件路径、多文件 = 内容根目录、无元数据 = ''。
  final String contentPath;
  final int total;
  final int done;

  /// 剩余字节；元数据未就绪 = -1（未知，不当完成）。
  final int left;
  final int downRate;
  final int upRate;

  /// 累计上传字节（做种时长/分享率上限判定用）。
  final int uploaded;

  /// 累计下载字节（分享率分母；元数据未就绪时为 0）。
  final int downloaded;
  final int numPeers;
  final bool hasMetadata;
  final bool isFinished;
  final bool isSeeding;
  final bool sequential;

  /// TODO-2482 详情批次（老 DLL 的 JSON 缺这些键时取安全默认 -1/false）。
  ///
  /// 已连接的 seed 数。
  final int numSeeds;

  /// 连接数（含握手中，>= [numPeers]）。
  final int numConnections;

  /// tracker scrape 的 swarm 总 seed 数（未 scrape 到 = -1）。
  final int numComplete;

  /// tracker scrape 的 swarm 总 leecher 数。
  final int numIncomplete;

  /// 引擎侧 paused flag（宿主的用户暂停真相在 Dart 侧，这里只是引擎观测）。
  final bool isPaused;

  /// 活跃总时长（秒，跨会话由 fastResume 累计）。
  final int activeDurationSeconds;

  /// 做种总时长（秒）。
  final int seedingDurationSeconds;

  /// 完成后总时长（秒）。
  final int finishedDurationSeconds;

  factory FtTorrentStatus._fromJson(Map<String, dynamic> json) {
    return FtTorrentStatus(
      id: json['id'] as String? ?? '',
      name: json['name'] as String? ?? '',
      progress: (json['progress'] as num?)?.toDouble() ?? 0.0,
      state: json['state'] as String? ?? '',
      savePath: json['save_path'] as String? ?? '',
      contentPath: json['content_path'] as String? ?? '',
      total: (json['total'] as num?)?.toInt() ?? 0,
      done: (json['done'] as num?)?.toInt() ?? 0,
      left: (json['left'] as num?)?.toInt() ?? -1,
      downRate: (json['down_rate'] as num?)?.toInt() ?? 0,
      upRate: (json['up_rate'] as num?)?.toInt() ?? 0,
      uploaded: (json['uploaded'] as num?)?.toInt() ?? 0,
      downloaded: (json['downloaded'] as num?)?.toInt() ?? 0,
      numPeers: (json['num_peers'] as num?)?.toInt() ?? 0,
      hasMetadata: json['has_metadata'] == true,
      isFinished: json['is_finished'] == true,
      isSeeding: json['is_seeding'] == true,
      sequential: json['sequential'] == true,
      numSeeds: (json['num_seeds'] as num?)?.toInt() ?? -1,
      numConnections: (json['num_connections'] as num?)?.toInt() ?? -1,
      numComplete: (json['num_complete'] as num?)?.toInt() ?? -1,
      numIncomplete: (json['num_incomplete'] as num?)?.toInt() ?? -1,
      isPaused: json['is_paused'] == true,
      activeDurationSeconds: (json['active_duration'] as num?)?.toInt() ?? -1,
      seedingDurationSeconds: (json['seeding_duration'] as num?)?.toInt() ?? -1,
      finishedDurationSeconds:
          (json['finished_duration'] as num?)?.toInt() ?? -1,
    );
  }
}

/// 种子内单个文件（native `ht_torrent_files` 单项）。
class FtFileEntry {
  const FtFileEntry({
    required this.index,
    required this.path,
    required this.size,
    required this.done,
  });

  final int index;

  /// 种子内相对路径。
  final String path;
  final int size;

  /// 已下载字节（piece 粒度，已过 hash 校验）。
  final int done;

  factory FtFileEntry._fromJson(Map<String, dynamic> json) {
    return FtFileEntry(
      index: (json['index'] as num?)?.toInt() ?? -1,
      path: json['path'] as String? ?? '',
      size: (json['size'] as num?)?.toInt() ?? 0,
      done: (json['done'] as num?)?.toInt() ?? 0,
    );
  }
}

/// 分片持有位图。
class FtPieceMap {
  const FtPieceMap({required this.numPieces, required this.have});

  final int numPieces;

  /// '0'/'1' 串，'1' = 已校验持有。
  final String have;

  /// 已持有 piece 数。
  int get haveCount => have.codeUnits.where((int c) => c == 0x31).length;
}

/// 某种子当前连接的单个 peer（反吸血判定输入）。
class FtPeerInfo {
  const FtPeerInfo({
    required this.ip,
    required this.port,
    required this.peerId,
    required this.client,
    required this.progress,
    required this.totalUpload,
    required this.totalDownload,
    required this.upSpeed,
    required this.downSpeed,
    required this.remoteInterested,
    this.flagsBits = 0,
    this.sourceBits = 0,
  });

  final String ip;
  final int port;

  /// 20 字节 peer_id 的可打印化（不可打印字节转 '.'；前 8 字节常是
  /// "-XL0012-" 式客户端指纹）。
  final String peerId;
  final String client;

  /// peer 自报进度 0~1（可伪造）。
  final double progress;

  /// 我实际喂给该 peer 的字节（可信，PCB 判定依据）。
  final int totalUpload;
  final int totalDownload;
  final int upSpeed;
  final int downSpeed;
  final bool remoteInterested;

  /// TODO-2482：桥自定义的稳定 peer flags 位掩码（bit 含义见
  /// `fushi_torrent.h` 的 ht_torrent_peers 契约；老 DLL 缺键 = 0）。
  final int flagsBits;

  /// peer 来源位掩码（bit0 tracker/bit1 dht/bit2 pex/bit3 lsd/
  /// bit4 fastResume/bit5 incoming）。
  final int sourceBits;

  factory FtPeerInfo._fromJson(Map<String, dynamic> json) {
    return FtPeerInfo(
      ip: json['ip'] as String? ?? '',
      port: (json['port'] as num?)?.toInt() ?? 0,
      peerId: json['peer_id'] as String? ?? '',
      client: json['client'] as String? ?? '',
      progress: (json['progress'] as num?)?.toDouble() ?? 0.0,
      totalUpload: (json['total_upload'] as num?)?.toInt() ?? 0,
      totalDownload: (json['total_download'] as num?)?.toInt() ?? 0,
      upSpeed: (json['up_speed'] as num?)?.toInt() ?? 0,
      downSpeed: (json['down_speed'] as num?)?.toInt() ?? 0,
      remoteInterested: json['remote_interested'] == true,
      flagsBits: (json['flags'] as num?)?.toInt() ?? 0,
      sourceBits: (json['source'] as num?)?.toInt() ?? 0,
    );
  }
}

/// TODO-2482：某种子的单个 tracker（native `ht_torrent_trackers` 单项）。
class FtTrackerInfo {
  const FtTrackerInfo({
    required this.url,
    required this.tier,
    required this.working,
    required this.updating,
    required this.fails,
    required this.lastError,
    required this.message,
    required this.scrapeComplete,
    required this.scrapeIncomplete,
    required this.scrapeDownloaded,
  });

  final String url;
  final int tier;

  /// 任一 endpoint 已成功 announce 且当前无错。
  final bool working;

  /// 任一 endpoint 正在等 tracker 响应。
  final bool updating;

  /// 连续失败次数（各 endpoint 取最大）。
  final int fails;

  /// 最近失败的 error_code 文本（空 = 无）。
  final String lastError;

  /// tracker 返回的错误/警告原文（空 = 无）。
  final String message;

  /// scrape 的 swarm seed 数（-1 = 未返回）。
  final int scrapeComplete;

  /// scrape 的 swarm leecher 数。
  final int scrapeIncomplete;

  /// scrape 的累计完成下载数。
  final int scrapeDownloaded;

  factory FtTrackerInfo._fromJson(Map<String, dynamic> json) {
    return FtTrackerInfo(
      url: json['url'] as String? ?? '',
      tier: (json['tier'] as num?)?.toInt() ?? 0,
      working: json['working'] == true,
      updating: json['updating'] == true,
      fails: (json['fails'] as num?)?.toInt() ?? 0,
      lastError: json['last_error'] as String? ?? '',
      message: json['message'] as String? ?? '',
      scrapeComplete: (json['scrape_complete'] as num?)?.toInt() ?? -1,
      scrapeIncomplete: (json['scrape_incomplete'] as num?)?.toInt() ?? -1,
      scrapeDownloaded: (json['scrape_downloaded'] as num?)?.toInt() ?? -1,
    );
  }
}

/// TODO-2482：一条端口映射回执（native `ht_session_status` 内嵌）。
class FtPortMapping {
  const FtPortMapping({
    required this.transport,
    required this.protocol,
    required this.externalPort,
    required this.ok,
    required this.error,
  });

  /// `upnp` | `natpmp`。
  final String transport;

  /// `tcp` | `udp` | ''（error 回执不带协议）。
  final String protocol;
  final int externalPort;
  final bool ok;
  final String error;

  factory FtPortMapping._fromJson(Map<String, dynamic> json) {
    return FtPortMapping(
      transport: json['transport'] as String? ?? '',
      protocol: json['protocol'] as String? ?? '',
      externalPort: (json['external_port'] as num?)?.toInt() ?? 0,
      ok: json['ok'] == true,
      error: json['error'] as String? ?? '',
    );
  }
}

/// TODO-2482：会话协议状态快照（native `ht_session_status`）。
class FtSessionStatus {
  const FtSessionStatus({
    required this.listenPort,
    required this.dhtRunning,
    required this.dhtNodes,
    required this.lsdEnabled,
    required this.upnpEnabled,
    required this.natpmpEnabled,
    required this.pexEnabled,
    required this.downRate,
    required this.upRate,
    required this.portMappings,
  });

  final int listenPort;
  final bool dhtRunning;

  /// DHT 路由表节点数（-1 = 尚未统计到；native 非阻塞，首轮为 -1）。
  final int dhtNodes;
  final bool lsdEnabled;
  final bool upnpEnabled;
  final bool natpmpEnabled;
  final bool pexEnabled;

  /// 会话级全局速率（字节/秒，含协议开销；-1 = 未知）。
  final int downRate;
  final int upRate;
  final List<FtPortMapping> portMappings;

  factory FtSessionStatus._fromJson(Map<String, dynamic> json) {
    final Object? mappings = json['port_mappings'];
    return FtSessionStatus(
      listenPort: (json['listen_port'] as num?)?.toInt() ?? 0,
      dhtRunning: json['dht_running'] == true,
      dhtNodes: (json['dht_nodes'] as num?)?.toInt() ?? -1,
      lsdEnabled: json['lsd_enabled'] == true,
      upnpEnabled: json['upnp_enabled'] == true,
      natpmpEnabled: json['natpmp_enabled'] == true,
      pexEnabled: json['pex_enabled'] == true,
      downRate: (json['down_rate'] as num?)?.toInt() ?? -1,
      upRate: (json['up_rate'] as num?)?.toInt() ?? -1,
      portMappings: mappings is List
          ? mappings
              .whereType<Map<String, dynamic>>()
              .map(FtPortMapping._fromJson)
              .toList(growable: false)
          : const <FtPortMapping>[],
    );
  }
}

/// 单个 piece 完成事件（发生序）。
class FtPieceEvent {
  const FtPieceEvent({required this.id, required this.piece});

  final String id;
  final int piece;
}

/// 一次异步存储操作（[EmbeddedTorrentSession.renameFile] /
/// [EmbeddedTorrentSession.moveStorage]）的结果。
class FtStorageOpResult {
  const FtStorageOpResult({required this.ok, this.path, this.error});

  /// 操作是否成功落地（引擎已回执且无错）。
  final bool ok;

  /// 成功时的新路径：改名 = 种子内新相对路径；移动 = 新的 save_path。
  final String? path;

  /// 失败原因（引擎原文，或超时 / 种子不存在等）。**必须**反馈给用户。
  final String? error;

  factory FtStorageOpResult._fromJson(Object? json) {
    if (json is! Map<String, dynamic>) {
      return const FtStorageOpResult(ok: false, error: 'bad native response');
    }
    return FtStorageOpResult(
      ok: json['ok'] == true,
      path: json['path'] as String?,
      error: json['error'] as String?,
    );
  }
}

/// 一轮 [EmbeddedTorrentSession.saveResumeData] 的结果。
class FtResumeSaveResult {
  const FtResumeSaveResult({
    required this.saved,
    required this.failed,
    this.timedOut = 0,
  });

  /// 成功落盘的种子数。
  final int saved;

  /// 引擎回执失败 + 写盘失败的种子数。
  final int failed;

  /// 在超时预算内没等到回执的种子数。**不是错误**：下一轮保存会再试，
  /// 这些种子只是这次没更新到盘上（盘上仍是上一轮的 resume）。
  final int timedOut;
}

/// 一个 libtorrent session 的高层封装。所有方法容错：底层失败返回
/// false / null / 空列表，不抛（与 TorrentBackend 契约同姿态）。
class EmbeddedTorrentSession {
  EmbeddedTorrentSession._(this._engine, this._session);

  final EmbeddedTorrentEngine _engine;
  Pointer<Void> _session;

  FushiTorrentBindings get _b => _engine.bindings;

  /// 引擎（版本查询等）。
  EmbeddedTorrentEngine get engine => _engine;

  /// 建 session。[listenInterfaces] libtorrent 语法（如 "0.0.0.0:6881" /
  /// "127.0.0.1:0"，端口 0 = 系统分配）；null/空 = 不监听 —— 注意
  /// libtorrent 的**出站连接也绑定在 listen socket 上**，不监听的 session
  /// 连不出任何 peer，只适合空壳/探测用途；要下载必须给监听接口。
  /// [enableDht] 公网磁力需要；本地测试关。失败返回 null。
  static EmbeddedTorrentSession? open(
    EmbeddedTorrentEngine engine, {
    String? listenInterfaces,
    bool enableDht = false,
  }) {
    final Pointer<Void> s = engine.createSession(
        listenInterfaces: listenInterfaces, enableDht: enableDht);
    if (s == nullptr) return null;
    return EmbeddedTorrentSession._(engine, s);
  }

  bool get isClosed => _session == nullptr;

  /// 实际监听端口；未监听返回 0。
  int get listenPort => isClosed ? 0 : _b.ht_session_listen_port(_session);

  /// 全局速率上限（字节/秒；<=0 = 不限）。
  bool setRateLimits({int downloadBps = 0, int uploadBps = 0}) {
    if (isClosed) return false;
    return _b.ht_session_set_rate_limits(_session, downloadBps, uploadBps) == 1;
  }

  /// 底层库是否支持把限速套到局域网 peer（见 [applyLimits] 的
  /// `limitLocalPeers`）。老的预编译 DLL 没有这个符号时为 false。
  bool get supportsLocalPeerRateLimit => _b.hasApplyLimitsEx;

  /// 一次设全局资源限制（用户可调）：速率上限（字节/秒，<=0 不限）+ 全局最大
  /// 连接数（<=0 保持 libtorrent 默认）。
  ///
  /// [limitLocalPeers] = true 时限速同时作用于局域网 peer。libtorrent 的全局
  /// 限速**默认不约束局域网 peer**（官方文档明写），要覆盖它只能设 local peer
  /// class 的上限，所以这个参数必须传到 native，Dart 侧无从模拟。
  ///
  /// 若底层库不支持（[supportsLocalPeerRateLimit] 为 false）而调用方又要求
  /// `limitLocalPeers: true`，则退回老入口应用全局限速并返回 **false**——限速
  /// 本身生效了，但"也管局域网"这个请求没被满足，调用方据此提示用户，绝不
  /// 假装成功。
  bool applyLimits({
    int downloadBps = 0,
    int uploadBps = 0,
    int connectionsLimit = 0,
    bool limitLocalPeers = false,
  }) {
    if (isClosed) return false;
    if (!_b.hasApplyLimitsEx) {
      final bool ok = _b.ht_apply_limits(
              _session, downloadBps, uploadBps, connectionsLimit) ==
          1;
      return ok && !limitLocalPeers;
    }
    return _b.ht_apply_limits_ex(_session, downloadBps, uploadBps,
            connectionsLimit, limitLocalPeers ? 1 : 0) ==
        1;
  }

  /// 应用内存占用设置（把 libtorrent 压进内存预算；<=0 的字段保持默认）。
  /// 1 成功 0 失败。
  bool applyMemorySettings({
    int connectionsLimit = 0,
    int maxQueuedDiskBytes = 0,
    int sendBufferWatermark = 0,
    int maxPeerlistSize = 0,
  }) {
    if (isClosed) return false;
    return _b.ht_apply_memory_settings(
          _session,
          connectionsLimit,
          maxQueuedDiskBytes,
          sendBufferWatermark,
          maxPeerlistSize,
        ) ==
        1;
  }

  /// 应用会话级设置（端口/DHT/LSD/UPnP/NAT-PMP/加密/匿名/活跃数/上传槽）。
  /// [encPolicy] 0=首选 1=强制 2=禁用；[listenPort]/[activeDownloads]/
  /// [activeSeeds]/[maxUploadSlots] <=0 保持默认。1 成功 0 失败。
  bool applySessionSettings({
    int listenPort = 0,
    bool enableDht = true,
    bool enableLsd = true,
    bool enableUpnp = true,
    bool enableNatpmp = true,
    int encPolicy = 0,
    bool anonymousMode = false,
    int activeDownloads = 0,
    int activeSeeds = 0,
    int maxUploadSlots = 0,
  }) {
    if (isClosed) return false;
    return _b.ht_apply_session_settings(
          _session,
          listenPort,
          enableDht ? 1 : 0,
          enableLsd ? 1 : 0,
          enableUpnp ? 1 : 0,
          enableNatpmp ? 1 : 0,
          encPolicy,
          anonymousMode ? 1 : 0,
          activeDownloads,
          activeSeeds,
          maxUploadSlots,
        ) ==
        1;
  }

  /// 【已废弃，仅存量兼容】历史上传开关。BUG-1293：libtorrent 的
  /// `upload_mode` flag 语义是「不再发出 piece 请求」= **停止下载**，与旧
  /// 注释宣称的「只下不上」正好相反——旧 DLL 的 `enabled: false` 会掐死下载。
  /// 新代码一律走 [setUnchokeSlots]（会话级停上传）/ [pauseTorrent]（做种停止）；
  /// 新 DLL 里本函数 `enabled: true` 只清 flag（治愈残留）、false 为 no-op。
  bool setUploadMode({String infoHash = '', required bool enabled}) {
    if (isClosed) return false;
    final Pointer<Char> id = infoHash.toNativeUtf8().cast<Char>();
    try {
      return _b.ht_set_upload_mode(_session, id, enabled ? 1 : 0) == 1;
    } finally {
      malloc.free(id);
    }
  }

  /// 底层库是否支持上传策略正确原语（[setUnchokeSlots] + [pauseTorrent]）。
  /// 旧的预编译 DLL 没有这两个符号时为 false，上传策略应整体降级为不动作。
  bool get supportsUploadControl => _b.hasUploadControl;

  /// 会话级 unchoke 槽位：[slots] >= 0 精确设置（0 = 不给任何 peer unchoke
  /// 槽位 = 停止上传 payload，下载不受影响——piece 请求是协议消息不占槽）；
  /// [slots] < 0 恢复 libtorrent 出厂默认。库不支持（老 DLL）返回 false。
  bool setUnchokeSlots(int slots) {
    if (isClosed || !_b.hasUploadControl) return false;
    return _b.ht_set_unchoke_slots(_session, slots) == 1;
  }

  /// 种子暂停/恢复（做种停止的正确原语）。[infoHash] 空串 = 全量；
  /// [pause] true = 清 auto_managed 再 pause（否则队列管理器自动恢复）、
  /// false = 恢复 auto_managed 并 resume。库不支持（老 DLL）返回 false。
  bool pauseTorrent(String infoHash, {required bool pause}) {
    if (isClosed || !_b.hasUploadControl) return false;
    final Pointer<Char> id = infoHash.toNativeUtf8().cast<Char>();
    try {
      return _b.ht_pause_torrent(_session, id, pause ? 1 : 0) == 1;
    } finally {
      malloc.free(id);
    }
  }

  /// 添加磁力链接。
  FtAddResult addMagnet(
    String magnetUri, {
    required String savePath,
    bool sequential = false,
  }) {
    if (isClosed) return const FtAddResult(ok: false, error: 'session closed');
    final Pointer<Char> magnet = magnetUri.toNativeUtf8().cast<Char>();
    final Pointer<Char> save = savePath.toNativeUtf8().cast<Char>();
    try {
      return FtAddResult._fromJson(_engine._consumeJson(
          _b.ht_add_magnet(_session, magnet, save, sequential ? 1 : 0)));
    } finally {
      malloc.free(magnet);
      malloc.free(save);
    }
  }

  /// 添加本地 .torrent 文件（本地做种 / 恢复下载）。
  FtAddResult addTorrentFile(
    String torrentPath, {
    required String savePath,
    bool sequential = false,
  }) {
    if (isClosed) return const FtAddResult(ok: false, error: 'session closed');
    final Pointer<Char> torrent = torrentPath.toNativeUtf8().cast<Char>();
    final Pointer<Char> save = savePath.toNativeUtf8().cast<Char>();
    try {
      return FtAddResult._fromJson(_engine._consumeJson(
          _b.ht_add_torrent_file(_session, torrent, save, sequential ? 1 : 0)));
    } finally {
      malloc.free(torrent);
      malloc.free(save);
    }
  }

  /// 手动连接 peer（本地测试 / LAN 直连）。
  bool connectPeer(String infoHash, String ip, int port) {
    if (isClosed) return false;
    final Pointer<Char> id = infoHash.toNativeUtf8().cast<Char>();
    final Pointer<Char> addr = ip.toNativeUtf8().cast<Char>();
    try {
      return _b.ht_connect_peer(_session, id, addr, port) == 1;
    } finally {
      malloc.free(id);
      malloc.free(addr);
    }
  }

  /// 列出 session 内所有种子。
  List<FtTorrentStatus> listTorrents() {
    if (isClosed) return const <FtTorrentStatus>[];
    final Object? json = _engine._consumeJson(_b.ht_list_torrents(_session));
    if (json is! List) return const <FtTorrentStatus>[];
    return json
        .whereType<Map<String, dynamic>>()
        .map(FtTorrentStatus._fromJson)
        .toList(growable: false);
  }

  /// 某种子的文件列表；元数据未就绪返回 null。
  List<FtFileEntry>? torrentFiles(String infoHash) {
    if (isClosed) return null;
    final Pointer<Char> id = infoHash.toNativeUtf8().cast<Char>();
    try {
      final Object? json =
          _engine._consumeJson(_b.ht_torrent_files(_session, id));
      if (json is! Map<String, dynamic> || json['ok'] != true) return null;
      final Object? files = json['files'];
      if (files is! List) return null;
      return files
          .whereType<Map<String, dynamic>>()
          .map(FtFileEntry._fromJson)
          .toList(growable: false);
    } finally {
      malloc.free(id);
    }
  }

  /// 分片持有位图；元数据未就绪返回 null。
  FtPieceMap? torrentPieces(String infoHash) {
    if (isClosed) return null;
    final Pointer<Char> id = infoHash.toNativeUtf8().cast<Char>();
    try {
      final Object? json =
          _engine._consumeJson(_b.ht_torrent_pieces(_session, id));
      if (json is! Map<String, dynamic> || json['ok'] != true) return null;
      return FtPieceMap(
        numPieces: (json['num_pieces'] as num?)?.toInt() ?? 0,
        have: json['have'] as String? ?? '',
      );
    } finally {
      malloc.free(id);
    }
  }

  /// 排空累计的 piece 完成事件（发生序）。
  List<FtPieceEvent> pollPieceEvents() {
    if (isClosed) return const <FtPieceEvent>[];
    final Object? json =
        _engine._consumeJson(_b.ht_poll_piece_events(_session));
    if (json is! List) return const <FtPieceEvent>[];
    return json
        .whereType<Map<String, dynamic>>()
        .map((Map<String, dynamic> e) => FtPieceEvent(
              id: e['id'] as String? ?? '',
              piece: (e['piece'] as num?)?.toInt() ?? -1,
            ))
        .toList(growable: false);
  }

  /// TODO-1961-c：引擎侧给种子内第 [fileIndex] 个文件改名（[newPath] 是种子内
  /// 相对路径，可含子目录，分隔符 `/`）。**做种不断** —— 引擎知道数据换了名字，
  /// 继续从新名字读盘上传。
  ///
  /// 返回 [FtStorageOpResult]：失败时 `error` 原样带回引擎给的原因，调用方
  /// 必须显示给用户（不得吞成一个光秃秃的 false）。
  FtStorageOpResult renameFile(
    String infoHash,
    int fileIndex,
    String newPath, {
    int timeoutMs = 15000,
  }) {
    if (isClosed) {
      return const FtStorageOpResult(ok: false, error: 'session closed');
    }
    final Pointer<Char> id = infoHash.toNativeUtf8().cast<Char>();
    final Pointer<Char> target = newPath.toNativeUtf8().cast<Char>();
    try {
      return FtStorageOpResult._fromJson(_engine._consumeJson(
          _b.ht_rename_file(_session, id, fileIndex, target, timeoutMs)));
    } finally {
      malloc.free(id);
      malloc.free(target);
    }
  }

  /// TODO-1961-c：引擎侧把种子内容整体移动到 [newSavePath]（做种不断）。
  ///
  /// 目标已有同名文件时**整体失败**（libtorrent `fail_if_exist`），绝不覆盖
  /// 用户数据、也绝不留下搬了一半的内容目录。
  FtStorageOpResult moveStorage(
    String infoHash,
    String newSavePath, {
    int timeoutMs = 15000,
  }) {
    if (isClosed) {
      return const FtStorageOpResult(ok: false, error: 'session closed');
    }
    final Pointer<Char> id = infoHash.toNativeUtf8().cast<Char>();
    final Pointer<Char> target = newSavePath.toNativeUtf8().cast<Char>();
    try {
      return FtStorageOpResult._fromJson(_engine
          ._consumeJson(_b.ht_move_storage(_session, id, target, timeoutMs)));
    } finally {
      malloc.free(id);
      malloc.free(target);
    }
  }

  /// TODO-1961-a：把当前所有已有元数据的种子的 resume data 落盘到 [dir]
  /// （每种子一个 `<infohash>.resume`，原子写）。
  ///
  /// 同步阻塞最多 [timeoutMs] 毫秒等引擎回执（内部 wait_for_alert 挂起，不是
  /// sleep 轮询）；通常几十毫秒内收齐。调用时机是「周期性 + 退出前」，不是每 tick。
  FtResumeSaveResult saveResumeData(String dir, {int timeoutMs = 5000}) {
    if (isClosed) return const FtResumeSaveResult(saved: 0, failed: 0);
    final Pointer<Char> out = dir.toNativeUtf8().cast<Char>();
    try {
      final Object? json = _engine
          ._consumeJson(_b.ht_save_resume_data(_session, out, timeoutMs));
      if (json is! Map<String, dynamic> || json['ok'] != true) {
        return const FtResumeSaveResult(saved: 0, failed: 0);
      }
      return FtResumeSaveResult(
        saved: (json['saved'] as num?)?.toInt() ?? 0,
        failed: (json['failed'] as num?)?.toInt() ?? 0,
        timedOut: (json['timed_out'] as num?)?.toInt() ?? 0,
      );
    } finally {
      malloc.free(out);
    }
  }

  /// TODO-1961-a：把 [dir] 下所有 `*.resume` 重新 add 回会话（启动续跑）。
  /// 目录不存在 = 首次运行，返回空列表而非错误。返回成功加回的 infohash 列表。
  List<String> loadResumeDir(String dir) {
    if (isClosed) return const <String>[];
    final Pointer<Char> path = dir.toNativeUtf8().cast<Char>();
    try {
      final Object? json =
          _engine._consumeJson(_b.ht_load_resume_dir(_session, path));
      if (json is! Map<String, dynamic> || json['ok'] != true) {
        return const <String>[];
      }
      final Object? ids = json['ids'];
      if (ids is! List) return const <String>[];
      return ids.whereType<String>().toList(growable: false);
    } finally {
      malloc.free(path);
    }
  }

  /// 流式播放原语：单 piece 截止期（毫秒）。
  bool setPieceDeadline(String infoHash, int piece, int deadlineMs) {
    if (isClosed) return false;
    final Pointer<Char> id = infoHash.toNativeUtf8().cast<Char>();
    try {
      return _b.ht_set_piece_deadline(_session, id, piece, deadlineMs) == 1;
    } finally {
      malloc.free(id);
    }
  }

  /// 首尾 piece 提优（qb firstLastPiecePrio 等价物）。
  /// 1 = 已应用、0 = 元数据未就绪（稍后重试）、-1 = 种子不存在。
  int applyFirstLastPriority(String infoHash) {
    if (isClosed) return -1;
    final Pointer<Char> id = infoHash.toNativeUtf8().cast<Char>();
    try {
      return _b.ht_apply_first_last_priority(_session, id);
    } finally {
      malloc.free(id);
    }
  }

  /// 某种子当前连接的 peer 列表；种子不存在返回 null。
  List<FtPeerInfo>? torrentPeers(String infoHash) {
    if (isClosed) return null;
    final Pointer<Char> id = infoHash.toNativeUtf8().cast<Char>();
    try {
      final Object? json =
          _engine._consumeJson(_b.ht_torrent_peers(_session, id));
      if (json is! Map<String, dynamic> || json['ok'] != true) return null;
      final Object? peers = json['peers'];
      if (peers is! List) return null;
      return peers
          .whereType<Map<String, dynamic>>()
          .map(FtPeerInfo._fromJson)
          .toList(growable: false);
    } finally {
      malloc.free(id);
    }
  }

  /// TODO-2482：底层库是否具备详情批次原语（trackers/文件优先级/会话状态）。
  /// 老的预编译 DLL 没有这些符号时为 false，详情查询应整体降级为 null。
  bool get supportsDetailInfo => _b.hasDetailInfo;

  /// TODO-2482：某种子的 tracker 列表；种子不存在/库不支持返回 null。
  /// 纯 DHT 磁力（无 tracker）返回空列表。
  List<FtTrackerInfo>? torrentTrackers(String infoHash) {
    if (isClosed || !_b.hasDetailInfo) return null;
    final Pointer<Char> id = infoHash.toNativeUtf8().cast<Char>();
    try {
      final Object? json =
          _engine._consumeJson(_b.ht_torrent_trackers(_session, id));
      if (json is! Map<String, dynamic> || json['ok'] != true) return null;
      final Object? trackers = json['trackers'];
      if (trackers is! List) return null;
      return trackers
          .whereType<Map<String, dynamic>>()
          .map(FtTrackerInfo._fromJson)
          .toList(growable: false);
    } finally {
      malloc.free(id);
    }
  }

  /// TODO-2482：每个文件的下载优先级（0~7，下标 = 文件 index）；
  /// 元数据未就绪/种子不存在/库不支持返回 null。
  List<int>? getFilePriorities(String infoHash) {
    if (isClosed || !_b.hasDetailInfo) return null;
    final Pointer<Char> id = infoHash.toNativeUtf8().cast<Char>();
    try {
      final Object? json =
          _engine._consumeJson(_b.ht_get_file_priorities(_session, id));
      if (json is! Map<String, dynamic> || json['ok'] != true) return null;
      final Object? priorities = json['priorities'];
      if (priorities is! List) return null;
      return priorities
          .whereType<num>()
          .map((num p) => p.toInt())
          .toList(growable: false);
    } finally {
      malloc.free(id);
    }
  }

  /// TODO-2526：每个 piece 的下载优先级（0~7，下标 = piece index；诊断/
  /// 测试用）。元数据未就绪/种子不存在/库不支持（老 DLL 缺符号）返回 null。
  List<int>? getPiecePriorities(String infoHash) {
    if (isClosed || !_b.hasPiecePriorities) return null;
    final Pointer<Char> id = infoHash.toNativeUtf8().cast<Char>();
    try {
      final Object? json =
          _engine._consumeJson(_b.ht_get_piece_priorities(_session, id));
      if (json is! Map<String, dynamic> || json['ok'] != true) return null;
      final Object? priorities = json['priorities'];
      if (priorities is! List) return null;
      return priorities
          .whereType<num>()
          .map((num p) => p.toInt())
          .toList(growable: false);
    } finally {
      malloc.free(id);
    }
  }

  /// TODO-2482：设置单个文件的下载优先级（0~7，0 = 不下载）。
  /// 库不支持（老 DLL）返回 false。写成功后 native 会对该种子重放一次
  /// 首尾 piece 提优（跳过 priority=0 的文件），见头文件契约（TODO-2526）。
  bool setFilePriority(String infoHash, int fileIndex, int priority) {
    if (isClosed || !_b.hasDetailInfo) return false;
    final Pointer<Char> id = infoHash.toNativeUtf8().cast<Char>();
    try {
      return _b.ht_set_file_priority(_session, id, fileIndex, priority) == 1;
    } finally {
      malloc.free(id);
    }
  }

  /// TODO-2482：会话协议状态。非阻塞：native 只收割已到的统计 alert，
  /// dhtNodes 首轮 -1、下一轮即有值；速率要到**第三轮**才有值（第二轮
  /// 收割到首个采样只够建基线，第三轮才差分得出）。库不支持返回 null。
  FtSessionStatus? sessionStatus() {
    if (isClosed || !_b.hasDetailInfo) return null;
    final Object? json = _engine._consumeJson(_b.ht_session_status(_session));
    if (json is! Map<String, dynamic> || json['ok'] != true) return null;
    return FtSessionStatus._fromJson(json);
  }

  /// 用 CIDR 列表整体重建 session 的 ip_filter（空列表 = 清空）。已连接的
  /// 命中 peer 会被断开，新连接直接拒绝。
  bool applyIpFilter(Iterable<String> cidrs) {
    if (isClosed) return false;
    final Pointer<Char> joined = cidrs.join('\n').toNativeUtf8().cast<Char>();
    try {
      return _b.ht_apply_ip_filter(_session, joined) == 1;
    } finally {
      malloc.free(joined);
    }
  }

  /// 移除种子；[deleteFiles] 连已下载数据一起删。
  bool removeTorrent(String infoHash, {bool deleteFiles = false}) {
    if (isClosed) return false;
    final Pointer<Char> id = infoHash.toNativeUtf8().cast<Char>();
    try {
      return _b.ht_remove_torrent(_session, id, deleteFiles ? 1 : 0) == 1;
    } finally {
      malloc.free(id);
    }
  }

  /// 销毁底层 session（幂等）。
  void close() {
    if (isClosed) return;
    final Pointer<Void> s = _session;
    _session = nullptr;
    _engine.destroySession(s);
  }
}
