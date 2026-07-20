import 'dart:io';

import 'package:hibiki/src/media/torrent/anime_download_config.dart';
import 'package:hibiki/src/media/torrent/anti_leech.dart';
import 'package:hibiki/src/media/torrent/embedded_torrent_backend.dart';
import 'package:hibiki/src/media/torrent/torrent_upload_policy.dart';
import 'package:hibiki_torrent/hibiki_torrent.dart';

/// 内置 libtorrent 引擎的 app 侧宿主：拥有**常驻**引擎 + 单个 session
/// （所有内置下载共享），按需派发短命 [EmbeddedTorrentBackend] 适配器给
/// `AnimeDownloadService` 的每 tick 用（适配器 close 不连累会话）。
///
/// 生命周期：app 启动时（桌面、且用户选内置后端）`open` 一次，AppModel
/// 释放时 `dispose`。DLL 加载失败（未构建/缺依赖）返回 null，上层回退外接
/// qb 或静默不动作，绝不 crash 启动流程。
///
/// 反吸血：持有全局单例 [AntiLeechEngine]（共享连坐段），`sweepAntiLeech`
/// 每次把所有种子的 peer 喂进引擎判定，新增封段全量重建 libtorrent
/// ip_filter（见 [project_libtorrent_phase1b_pr227] 的阶段3 接线）。
class EmbeddedTorrentHost {
  EmbeddedTorrentHost._({
    required EmbeddedTorrentEngine engine,
    required EmbeddedTorrentSession session,
    required String baseSavePath,
    required int Function() clockMs,
  })  : _engine = engine,
        _session = session,
        _baseSavePath = baseSavePath,
        _clockMs = clockMs;

  final EmbeddedTorrentEngine _engine;
  final EmbeddedTorrentSession _session;
  final String _baseSavePath;
  final int Function() _clockMs;

  /// 全局反吸血引擎（共享连坐段，见 anti_leech.dart 类 doc 建议）。
  final AntiLeechEngine _antiLeech = AntiLeechEngine();

  /// 当前 ip_filter 里的封段快照（避免无变化时重复 set_ip_filter）。
  Set<String> _appliedBans = <String>{};

  /// 上传/做种策略（默认开箱即关上传）。config 变更时由 AppModel 更新。
  QbConnectionConfig _uploadConfig = const QbConnectionConfig();

  /// 每个种子进入做种阶段的时刻（做种时长上限判定基准）。
  final Map<String, int> _seedStartMs = <String, int>{};

  /// 已下发的 per-torrent 上传模式（避免无变化时重复 FFI 调用）。
  final Map<String, bool> _appliedUpload = <String, bool>{};

  /// 底层引擎版本串（诊断/probe 用）。
  String get libtorrentVersion => _engine.libtorrentVersion();

  /// 打开宿主。[libraryPath] 显式 DLL 路径（缺省按平台默认名搜系统路径）；
  /// [baseSavePath] 内置下载根目录；[listenInterfaces] 监听接口（桌面默认
  /// 全网 6881，端口占用时 libtorrent 自行回退）；[clockMs] 单调毫秒时钟
  /// 注入（反吸血引擎判定基准，测试可注入假时钟）。
  /// 任何失败（DLL 加载 / session 创建）返回 null。
  static EmbeddedTorrentHost? open({
    String? libraryPath,
    required String baseSavePath,
    String listenInterfaces = '0.0.0.0:6881',
    bool enableDht = true,
    int Function()? clockMs,
  }) {
    EmbeddedTorrentEngine engine;
    try {
      engine = EmbeddedTorrentEngine.open(libraryPath: libraryPath);
    } on ArgumentError {
      return null; // DLL 缺失/未构建
    } on Object {
      return null;
    }
    final EmbeddedTorrentSession? session = EmbeddedTorrentSession.open(
      engine,
      listenInterfaces: listenInterfaces,
      enableDht: enableDht,
    );
    if (session == null) return null;
    return EmbeddedTorrentHost._(
      engine: engine,
      session: session,
      baseSavePath: baseSavePath,
      clockMs: clockMs ?? _defaultClockMs,
    );
  }

  static int _defaultClockMs() => DateTime.now().millisecondsSinceEpoch;

  /// 应用用户可调的全局资源限制（速率 + 连接数）。[downloadKbps]/[uploadKbps]
  /// 单位 KB/s（0 = 不限），[maxConnections]（0 = 引擎默认）。config 变更时
  /// 由 AppModel 调用，即时生效。
  bool applyLimits({
    int downloadKbps = 0,
    int uploadKbps = 0,
    int maxConnections = 0,
  }) {
    return _session.applyLimits(
      downloadBps: downloadKbps > 0 ? downloadKbps * 1024 : 0,
      uploadBps: uploadKbps > 0 ? uploadKbps * 1024 : 0,
      connectionsLimit: maxConnections,
    );
  }

  /// 派发一个短命后端适配器（共享常驻 session；其 close 不销毁会话）。
  /// 供 `AnimeDownloadService.backendFactory` 每 tick 调用。
  EmbeddedTorrentBackend backendView() {
    return EmbeddedTorrentBackend(
      session: _session,
      baseSavePath: _baseSavePath,
      closesSession: false,
    );
  }

  /// 反吸血扫描：遍历所有种子的 peer，喂进 [AntiLeechEngine] 判定，
  /// 若封段集较上次有变化则全量重建 libtorrent ip_filter。返回本轮新增
  /// 封禁的 peer 数（诊断用）。异常静默吞（不打断下载轮询）。
  int sweepAntiLeech() {
    try {
      final int nowMs = _clockMs();
      int newlyBanned = 0;
      for (final HtTorrentStatus t in _session.listTorrents()) {
        final List<HtPeerInfo>? peers = _session.torrentPeers(t.id);
        if (peers == null || peers.isEmpty) continue;
        final TorrentContext ctx = TorrentContext(
          infoHash: t.id,
          totalSize: t.total,
          completedSize: t.done,
          isSeeding: t.isSeeding,
        );
        final List<PeerSnapshot> snapshots = <PeerSnapshot>[
          for (final HtPeerInfo pi in peers)
            PeerSnapshot(
              ip: pi.ip,
              peerId: pi.peerId,
              client: pi.client,
              reportedProgress: pi.progress,
              totalUpload: pi.totalUpload,
              totalDownload: pi.totalDownload,
              port: pi.port,
              uploadSpeed: pi.upSpeed,
              peerInterested: pi.remoteInterested,
            ),
        ];
        final Map<String, BanVerdict> verdicts =
            _antiLeech.evaluate(snapshots, ctx, nowMs: nowMs);
        newlyBanned += verdicts.values.where((BanVerdict v) => v.banned).length;
      }
      // 抄 ClientBlocker banTime：清理到期封段（banTimeMs>0 时生效）→ 变化随
      // 下面的 setEquals 比较自然触发 ip_filter 重建。
      _antiLeech.pruneExpired(nowMs);
      final Set<String> bans = _antiLeech.bannedCidrs;
      if (!_setEquals(bans, _appliedBans)) {
        if (_session.applyIpFilter(bans)) {
          _appliedBans = Set<String>.from(bans);
        }
      }
      return newlyBanned;
    } on Object {
      return 0;
    }
  }

  /// 更新上传/做种策略并立即重扫一次让新策略生效（用户在设置里改上传开关/
  /// 做种上限时由 AppModel 调用）。
  void setUploadPolicy(QbConnectionConfig config) {
    _uploadConfig = config;
    sweepUploadPolicy();
  }

  /// 上传/做种策略扫描：按 [torrent_upload_policy] 算出每个种子的期望上传状态
  /// （总开关关 / 做种超时 / 分享率达标 → 停传），仅在期望状态变化时下发
  /// `setUploadMode`（避免每 tick 重复 FFI）。返回本轮实际改变的种子数。
  /// 与 [sweepAntiLeech] 同在 `AnimeDownloadService` 每 tick 调用。异常静默吞。
  int sweepUploadPolicy() {
    try {
      final int nowMs = _clockMs();
      int changed = 0;
      final Set<String> live = <String>{};
      for (final HtTorrentStatus t in _session.listTorrents()) {
        live.add(t.id);
        if (t.isSeeding) {
          _seedStartMs.putIfAbsent(t.id, () => nowMs);
        }
        final int? startMs = _seedStartMs[t.id];
        final int elapsedMs = startMs == null ? 0 : nowMs - startMs;
        final bool allow = shouldAllowUpload(
          _uploadConfig,
          TorrentUploadMetrics(
            isSeeding: t.isSeeding,
            uploaded: t.uploaded,
            downloaded: t.downloaded,
            seedingElapsedMs: elapsedMs,
          ),
        );
        if (_appliedUpload[t.id] != allow) {
          if (_session.setUploadMode(infoHash: t.id, enabled: allow)) {
            _appliedUpload[t.id] = allow;
            changed++;
          }
        }
      }
      // 清理已移除种子的残留状态。
      _seedStartMs.removeWhere((String k, int v) => !live.contains(k));
      _appliedUpload.removeWhere((String k, bool v) => !live.contains(k));
      return changed;
    } on Object {
      return 0;
    }
  }

  static bool _setEquals(Set<String> a, Set<String> b) {
    if (a.length != b.length) return false;
    for (final String e in a) {
      if (!b.contains(e)) return false;
    }
    return true;
  }

  /// 释放常驻 session（app 退出时）。
  void dispose() {
    _session.close();
  }
}

/// 平台默认内置 DLL 路径解析：flutter runner 把 native 依赖放在可执行文件
/// 旁（Windows）。阶段2 未接进 windows runner 前，这里返回 null 让
/// [EmbeddedTorrentHost.open] 走系统搜索路径（或由调用方显式传 libraryPath）。
String? defaultEmbeddedTorrentLibraryPath() {
  if (Platform.isWindows) {
    // runner 集成后 DLL 与 hibiki.exe 同目录，DynamicLibrary 按名即可命中；
    // 此处不硬编码 build 产物路径（那是 standalone 测试的事）。
    return null;
  }
  return null;
}
