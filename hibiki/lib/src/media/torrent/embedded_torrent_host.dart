import 'dart:io';

import 'package:hibiki/src/media/torrent/anime_download_config.dart';
import 'package:hibiki/src/media/torrent/anti_leech.dart';
import 'package:hibiki/src/media/torrent/download_save_root.dart';
import 'package:hibiki/src/media/torrent/embedded_torrent_backend.dart';
import 'package:hibiki/src/media/torrent/torrent_memory.dart';
import 'package:hibiki/src/media/torrent/torrent_upload_policy.dart';
import 'package:hibiki_torrent/hibiki_torrent.dart';

/// 内置 libtorrent 引擎的 app 侧宿主：拥有**常驻**引擎 + 单个 session
/// （所有内置下载共享），按需派发短命 [EmbeddedTorrentBackend] 适配器给
/// `AnimeDownloadService` 的每 tick 用（适配器 close 不连累会话）。
///
/// 生命周期：**首次真的要用下载后端时**懒建（见 `AppModel._ensureEmbeddedTorrentHost`），
/// AppModel 释放时 `dispose`。DLL 加载失败（未构建/缺依赖）返回 null，上层回退外接
/// qb 或静默不动作，绝不 crash 启动流程。
///
/// BUG-1053：绝不能在 app 启动时无条件 [open]。[open] 会创建 libtorrent session ——
/// 绑 6881（TCP+UDP，全网卡）并**默认开 DHT**，于是一个种子都没有的用户，只要开着
/// Hibiki 就在持续收发全球 DHT 小包，把家用路由器的 NAT/conntrack 表撑爆，表现为
/// 「每隔一段时间整机网络高延迟，关掉 Hibiki 就好」。能力探测请用 [probeAvailable]，
/// 它只加载 DLL、**不建 session、不碰网络**。
///
/// 反吸血：持有全局单例 [AntiLeechEngine]（共享连坐段），`sweepAntiLeech`
/// 每次把所有种子的 peer 喂进引擎判定，新增封段全量重建 libtorrent
/// ip_filter（见 [project_libtorrent_phase1b_pr227] 的阶段3 接线）。
class EmbeddedTorrentHost {
  EmbeddedTorrentHost._({
    required EmbeddedTorrentEngine engine,
    required EmbeddedTorrentSession session,
    required TorrentSaveRoots saveRoots,
    required int Function() clockMs,
  })  : _engine = engine,
        _session = session,
        _saveRoots = saveRoots,
        _clockMs = clockMs;

  final EmbeddedTorrentEngine _engine;
  final EmbeddedTorrentSession _session;
  final int Function() _clockMs;

  /// 下载根集合：[TorrentSaveRoots.active] 收新任务，历史根只参与列表过滤。
  /// TODO-1961：**非 final** —— 用户在设置里改下载目录时 [setActiveSaveRoot] 就地
  /// 换活动根，旧根降级为历史根。不能重建 host 来换根：重建 = 销毁 session =
  /// 掐断当前所有下载与做种，正是「只影响新增任务」要避免的。
  TorrentSaveRoots _saveRoots;

  /// 全局反吸血引擎（共享连坐段，见 anti_leech.dart 类 doc 建议）。用户在设置里
  /// 调开关/阈值时 [applyAntiLeechConfig] 会用新 [AntiLeechConfig] 重建它。
  AntiLeechEngine _antiLeech = AntiLeechEngine();

  /// 反吸血总开关（关时 [sweepAntiLeech] 清空 ip_filter 且不再判定）。
  bool _antiLeechEnabled = true;

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
  /// [baseSavePath] 内置下载根目录（新任务落点）；[legacySavePaths] 历史下载根
  /// （用户改过下载目录时的旧根，只参与列表过滤，永不写入）；[listenInterfaces]
  /// 监听接口（桌面默认全网 6881，端口占用时 libtorrent 自行回退）；[clockMs]
  /// 单调毫秒时钟注入（反吸血引擎判定基准，测试可注入假时钟）。
  /// 任何失败（DLL 加载 / session 创建）返回 null。
  static EmbeddedTorrentHost? open({
    String? libraryPath,
    required String baseSavePath,
    Iterable<String> legacySavePaths = const <String>[],
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
      saveRoots:
          TorrentSaveRoots(active: baseSavePath, legacy: legacySavePaths),
      clockMs: clockMs ?? _defaultClockMs,
    );
  }

  static int _defaultClockMs() => DateTime.now().millisecondsSinceEpoch;

  /// 缓存的能力探测结果（DLL 只需加载一次，`DynamicLibrary` 也无法卸载）。
  static bool? _availabilityCache;

  /// 内置引擎在本机是否可用——**只加载 DLL，不创建 session**（不绑端口、不起
  /// DHT、不产生任何网络流量）。
  ///
  /// BUG-1053：UI 的「内置引擎就绪」判定（下载对话框/下载页）以前是
  /// `_embeddedTorrentHost != null`，逼得 AppModel 必须在启动时就把真 session 开
  /// 起来才能让按钮可用。拆成「能力探测」与「真实会话」两件事之后，就绪判定走
  /// 这里，session 留到真的要下载时再建。
  static bool probeAvailable({String? libraryPath}) {
    final bool? cached = _availabilityCache;
    if (cached != null) return cached;
    bool ok;
    try {
      EmbeddedTorrentEngine.open(libraryPath: libraryPath);
      ok = true;
    } on ArgumentError {
      ok = false; // DLL 缺失/未构建
    } on Object {
      ok = false;
    }
    _availabilityCache = ok;
    return ok;
  }

  /// 仅测试用：清掉 [probeAvailable] 的缓存。
  static void resetAvailabilityProbeForTesting() => _availabilityCache = null;

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

  /// 应用内存占用设置（把 libtorrent 压进内存预算，见 [TorrentMemorySettings]）。
  /// [connectionsLimit] 传 0 时不覆盖（让用户显式 maxConnections 或 applyLimits
  /// 决定）。config 变更/启动时由 AppModel 调用。
  bool applyMemorySettings(
    TorrentMemorySettings settings, {
    int connectionsLimit = 0,
  }) {
    return _session.applyMemorySettings(
      connectionsLimit: connectionsLimit,
      maxQueuedDiskBytes: settings.maxQueuedDiskBytes,
      sendBufferWatermark: settings.sendBufferWatermark,
      maxPeerlistSize: settings.maxPeerlistSize,
    );
  }

  /// 应用会话级设置（qb 关键项：端口/DHT/LSD/UPnP/NAT-PMP/加密/匿名/活跃数/
  /// 上传槽）到常驻 session。config 变更/启动时由 AppModel 调用。
  bool applySessionSettings(QbConnectionConfig config) {
    return _session.applySessionSettings(
      listenPort: config.listenPort,
      enableDht: config.enableDht,
      enableLsd: config.enableLsd,
      enableUpnp: config.enableUpnp,
      enableNatpmp: config.enableNatpmp,
      encPolicy: config.encryptionMode,
      anonymousMode: config.anonymousMode,
      activeDownloads: config.maxActiveDownloads,
      activeSeeds: config.maxActiveSeeds,
      maxUploadSlots: config.maxUploadSlots,
    );
  }

  /// 用配置里的反吸血开关/阈值重建反吸血引擎（丢弃旧封禁状态，会自然重建）。
  /// 总开关关时下一次 [sweepAntiLeech] 会清空 ip_filter。config 变更时调用。
  void applyAntiLeechConfig(QbConnectionConfig config) {
    _antiLeechEnabled = config.antiLeechEnabled;
    _antiLeech = AntiLeechEngine(
      config: AntiLeechConfig(
        banByProgressUploaded: config.banProgressCheat,
        banByRelativeProgressUploaded: config.banRelativeProgressCheat,
        maxIpPortCount: config.maxIpPortCount,
        banTimeMs:
            config.banTimeMinutes > 0 ? config.banTimeMinutes * 60 * 1000 : 0,
      ),
    );
  }

  /// 派发一个短命后端适配器（共享常驻 session；其 close 不销毁会话）。
  /// 供 `AnimeDownloadService.backendFactory` 每 tick 调用。
  EmbeddedTorrentBackend backendView() {
    return EmbeddedTorrentBackend(
      session: _session,
      saveRoots: _saveRoots,
      closesSession: false,
    );
  }

  /// 当前下载根集合（活动根 + 历史根）。诊断/设置页展示用。
  TorrentSaveRoots get saveRoots => _saveRoots;

  /// TODO-1961：用户在设置里改下载目录时就地换活动根 —— **只影响之后新增的任务**。
  /// 已在跑的种子保持各自的 savePath 不动（不 move_storage、不重建 session），
  /// 旧根降级为历史根后仍被 [EmbeddedTorrentBackend.listTorrents] 认得，
  /// 下载页不会因为改目录而丢任务。
  void setActiveSaveRoot(String newActiveRoot) {
    _saveRoots = _saveRoots.withActive(newActiveRoot);
  }

  /// 反吸血扫描：遍历所有种子的 peer，喂进 [AntiLeechEngine] 判定，
  /// 若封段集较上次有变化则全量重建 libtorrent ip_filter。返回本轮新增
  /// 封禁的 peer 数（诊断用）。异常静默吞（不打断下载轮询）。
  int sweepAntiLeech() {
    try {
      // 总开关关：清掉可能残留的 ip_filter 封段，之后不判定。
      if (!_antiLeechEnabled) {
        if (_appliedBans.isNotEmpty && _session.applyIpFilter(<String>{})) {
          _appliedBans = <String>{};
        }
        return 0;
      }
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
