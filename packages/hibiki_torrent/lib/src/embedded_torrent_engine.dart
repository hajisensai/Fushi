import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

import 'ffi/hibiki_torrent_bindings.dart';

/// 内置 libtorrent 引擎的 Dart 侧薄封装（阶段1b：真实下载管线）。
///
/// [EmbeddedTorrentEngine] 负责加载原生库与无 session 的全局调用；
/// [EmbeddedTorrentSession] 是一个 libtorrent session 的高层句柄封装
/// （磁力/元数据/顺序下载/进度/边下边播原语）。
class EmbeddedTorrentEngine {
  EmbeddedTorrentEngine._(this.bindings);

  /// 底层 FFI 绑定（高级封装之外的逃生口）。
  final HibikiTorrentBindings bindings;

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
    return EmbeddedTorrentEngine._(HibikiTorrentBindings(lib));
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

  static DynamicLibrary _openByPlatformDefault() {
    if (Platform.isWindows)
      return DynamicLibrary.open('hibiki_torrent_ffi.dll');
    if (Platform.isMacOS) {
      return DynamicLibrary.open('libhibiki_torrent_ffi.dylib');
    }
    if (Platform.isLinux || Platform.isAndroid) {
      return DynamicLibrary.open('libhibiki_torrent_ffi.so');
    }
    if (Platform.isIOS) return DynamicLibrary.process();
    throw UnsupportedError(
        'hibiki_torrent: unsupported platform ${Platform.operatingSystem}');
  }

  /// libtorrent 运行时版本串（如 "2.0.11.0"）。
  String libtorrentVersion() {
    final Pointer<Char> p = bindings.ht_libtorrent_version();
    if (p == nullptr) return '';
    return p.cast<Utf8>().toDartString();
  }

  /// 从本地文件/目录生成 .torrent（本地做种与确定性测试支撑）。
  HtAddResult makeTorrent({
    required String contentPath,
    required String outTorrentPath,
  }) {
    final Pointer<Char> content = contentPath.toNativeUtf8().cast<Char>();
    final Pointer<Char> out = outTorrentPath.toNativeUtf8().cast<Char>();
    try {
      return HtAddResult._fromJson(
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
class HtAddResult {
  const HtAddResult({required this.ok, this.id, this.error});

  final bool ok;

  /// 成功时的 infohash（小写十六进制）。
  final String? id;

  final String? error;

  factory HtAddResult._fromJson(Object? json) {
    if (json is! Map<String, dynamic>) {
      return const HtAddResult(ok: false, error: 'bad native response');
    }
    return HtAddResult(
      ok: json['ok'] == true,
      id: json['id'] as String?,
      error: json['error'] as String?,
    );
  }
}

/// 一个种子任务的状态快照（native `ht_list_torrents` 单项）。
class HtTorrentStatus {
  const HtTorrentStatus({
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

  factory HtTorrentStatus._fromJson(Map<String, dynamic> json) {
    return HtTorrentStatus(
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
    );
  }
}

/// 种子内单个文件（native `ht_torrent_files` 单项）。
class HtFileEntry {
  const HtFileEntry({
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

  factory HtFileEntry._fromJson(Map<String, dynamic> json) {
    return HtFileEntry(
      index: (json['index'] as num?)?.toInt() ?? -1,
      path: json['path'] as String? ?? '',
      size: (json['size'] as num?)?.toInt() ?? 0,
      done: (json['done'] as num?)?.toInt() ?? 0,
    );
  }
}

/// 分片持有位图。
class HtPieceMap {
  const HtPieceMap({required this.numPieces, required this.have});

  final int numPieces;

  /// '0'/'1' 串，'1' = 已校验持有。
  final String have;

  /// 已持有 piece 数。
  int get haveCount => have.codeUnits.where((int c) => c == 0x31).length;
}

/// 某种子当前连接的单个 peer（反吸血判定输入）。
class HtPeerInfo {
  const HtPeerInfo({
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

  factory HtPeerInfo._fromJson(Map<String, dynamic> json) {
    return HtPeerInfo(
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
    );
  }
}

/// 单个 piece 完成事件（发生序）。
class HtPieceEvent {
  const HtPieceEvent({required this.id, required this.piece});

  final String id;
  final int piece;
}

/// 一个 libtorrent session 的高层封装。所有方法容错：底层失败返回
/// false / null / 空列表，不抛（与 TorrentBackend 契约同姿态）。
class EmbeddedTorrentSession {
  EmbeddedTorrentSession._(this._engine, this._session);

  final EmbeddedTorrentEngine _engine;
  Pointer<Void> _session;

  HibikiTorrentBindings get _b => _engine.bindings;

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

  /// 一次设全局资源限制（用户可调）：速率上限（字节/秒，<=0 不限）+ 全局最大
  /// 连接数（<=0 保持 libtorrent 默认）。
  bool applyLimits({
    int downloadBps = 0,
    int uploadBps = 0,
    int connectionsLimit = 0,
  }) {
    if (isClosed) return false;
    return _b.ht_apply_limits(
            _session, downloadBps, uploadBps, connectionsLimit) ==
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

  /// 上传模式开关（做种/上传总开关）。[infoHash] 空串 = 对所有种子生效；
  /// [enabled] false = 停止上传但保持连接与下载（libtorrent upload_mode，
  /// 「只下不上」的正规做法；限速设 0 是不限而非禁传）。1 成功 0 失败。
  bool setUploadMode({String infoHash = '', required bool enabled}) {
    if (isClosed) return false;
    final Pointer<Char> id = infoHash.toNativeUtf8().cast<Char>();
    try {
      return _b.ht_set_upload_mode(_session, id, enabled ? 1 : 0) == 1;
    } finally {
      malloc.free(id);
    }
  }

  /// 添加磁力链接。
  HtAddResult addMagnet(
    String magnetUri, {
    required String savePath,
    bool sequential = false,
  }) {
    if (isClosed) return const HtAddResult(ok: false, error: 'session closed');
    final Pointer<Char> magnet = magnetUri.toNativeUtf8().cast<Char>();
    final Pointer<Char> save = savePath.toNativeUtf8().cast<Char>();
    try {
      return HtAddResult._fromJson(_engine._consumeJson(
          _b.ht_add_magnet(_session, magnet, save, sequential ? 1 : 0)));
    } finally {
      malloc.free(magnet);
      malloc.free(save);
    }
  }

  /// 添加本地 .torrent 文件（本地做种 / 恢复下载）。
  HtAddResult addTorrentFile(
    String torrentPath, {
    required String savePath,
    bool sequential = false,
  }) {
    if (isClosed) return const HtAddResult(ok: false, error: 'session closed');
    final Pointer<Char> torrent = torrentPath.toNativeUtf8().cast<Char>();
    final Pointer<Char> save = savePath.toNativeUtf8().cast<Char>();
    try {
      return HtAddResult._fromJson(_engine._consumeJson(
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
  List<HtTorrentStatus> listTorrents() {
    if (isClosed) return const <HtTorrentStatus>[];
    final Object? json = _engine._consumeJson(_b.ht_list_torrents(_session));
    if (json is! List) return const <HtTorrentStatus>[];
    return json
        .whereType<Map<String, dynamic>>()
        .map(HtTorrentStatus._fromJson)
        .toList(growable: false);
  }

  /// 某种子的文件列表；元数据未就绪返回 null。
  List<HtFileEntry>? torrentFiles(String infoHash) {
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
          .map(HtFileEntry._fromJson)
          .toList(growable: false);
    } finally {
      malloc.free(id);
    }
  }

  /// 分片持有位图；元数据未就绪返回 null。
  HtPieceMap? torrentPieces(String infoHash) {
    if (isClosed) return null;
    final Pointer<Char> id = infoHash.toNativeUtf8().cast<Char>();
    try {
      final Object? json =
          _engine._consumeJson(_b.ht_torrent_pieces(_session, id));
      if (json is! Map<String, dynamic> || json['ok'] != true) return null;
      return HtPieceMap(
        numPieces: (json['num_pieces'] as num?)?.toInt() ?? 0,
        have: json['have'] as String? ?? '',
      );
    } finally {
      malloc.free(id);
    }
  }

  /// 排空累计的 piece 完成事件（发生序）。
  List<HtPieceEvent> pollPieceEvents() {
    if (isClosed) return const <HtPieceEvent>[];
    final Object? json =
        _engine._consumeJson(_b.ht_poll_piece_events(_session));
    if (json is! List) return const <HtPieceEvent>[];
    return json
        .whereType<Map<String, dynamic>>()
        .map((Map<String, dynamic> e) => HtPieceEvent(
              id: e['id'] as String? ?? '',
              piece: (e['piece'] as num?)?.toInt() ?? -1,
            ))
        .toList(growable: false);
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
  List<HtPeerInfo>? torrentPeers(String infoHash) {
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
          .map(HtPeerInfo._fromJson)
          .toList(growable: false);
    } finally {
      malloc.free(id);
    }
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
