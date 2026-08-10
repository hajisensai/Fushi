import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:fushi/src/media/torrent/anime_download_config.dart';
import 'package:fushi/src/media/torrent/anti_leech.dart';
import 'package:fushi/src/media/torrent/download_save_root.dart';
import 'package:fushi/src/media/torrent/embedded_torrent_backend.dart';
import 'package:fushi/src/media/torrent/torrent_memory.dart';
import 'package:fushi/src/media/torrent/torrent_upload_policy.dart';
import 'package:fushi_torrent/fushi_torrent.dart';
import 'package:path/path.dart' as p;

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
    required String resumeDir,
    required int Function() clockMs,
  })  : _engine = engine,
        _session = session,
        _saveRoots = saveRoots,
        _resumeDir = resumeDir,
        _clockMs = clockMs;

  final EmbeddedTorrentEngine _engine;
  final EmbeddedTorrentSession _session;
  final int Function() _clockMs;

  /// resume data 目录（`<计划目录>/resume`，每种子一个 `<infohash>.resume`）。
  ///
  /// TODO-1961-a：它**跟数据根走、不跟下载根走** —— resume 描述的是「哪些种子
  /// 该活着」这一 app 状态，不是下载内容本身。用户改下载目录时它不该被搬走。
  final String _resumeDir;

  /// 上次成功保存 resume 的时刻（节流基准，0 = 本次会话还没存过）。
  int _lastResumeSaveMs = 0;

  /// resume 保存最小间隔。每 tick（20s）都全量写盘没有收益：resume 只在
  /// 「进度显著推进」后才有新信息，而崩溃丢失最多一分钟进度会由 libtorrent
  /// 启动时的文件校验补回来（校验只读盘，不重下）。
  static const Duration resumeSaveInterval = Duration(minutes: 1);

  /// 周期保存时给 native 的等待预算（毫秒）。
  ///
  /// `ht_save_resume_data` 是**主 isolate 同步 FFI**：这段时间 UI 完全冻结。
  /// native 侧收齐回执即返回，预算只是最坏情况上限——但最坏情况每分钟发生一次，
  /// 5s（native 默认）是不可接受的卡顿。没收齐的种子下一轮再存，盘上仍是上一轮
  /// 的 resume，不丢数据。彻底不阻塞需要把 session 挪进独立 isolate（session
  /// 指针不可跨 isolate 并发访问），是另一个量级的改动，本轮只压住最坏情况。
  static const int periodicSaveTimeoutMs = 1500;

  /// 退出前最后一次保存的等待预算（毫秒）：比周期保存宽（这是最后机会），
  /// 但仍远小于 native 默认 5s —— 退出卡 5s 用户会以为 app 挂死。
  static const int shutdownSaveTimeoutMs = 2500;

  /// 是否已经用**真实**计划集合恢复过一次（[restoreFromResume] 拿到非 null
  /// keepIds 时置位）。启动竞态下 host 可能先于计划加载被建出来，那次 open
  /// 会跳过恢复，真相源到位后由 AppModel 据此补做。
  bool _hasRestored = false;
  bool get hasRestored => _hasRestored;

  /// 最近一次 resume 保存的引擎回执（诊断用；从未保存过为 null）。
  FtResumeSaveResult? _lastResumeSaveResult;
  FtResumeSaveResult? get lastResumeSaveResult => _lastResumeSaveResult;

  /// 本会话是否已记过一条「首次保存成功」日志（避免每分钟刷屏）。
  bool _loggedFirstResumeSave = false;

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

  /// 已下发的会话级上传开关（null = 尚未下发；避免每 tick 重复 FFI）。
  /// BUG-1493：「关上传」的正确原语是会话级 unchoke 槽位清零，不是
  /// upload_mode（那是「停止下载」，正好相反）。
  bool? _appliedSessionUploadEnabled;

  /// 已下发的 per-torrent 暂停状态（做种超限/关上传时停止做种用）。
  final Map<String, bool> _appliedPaused = <String, bool>{};

  /// TODO-2481/2482：用户显式暂停的种子（infohash 小写）。与策略暂停
  /// [_appliedPaused] 分开记：[sweepUploadPolicy] 对这里的种子整体跳过，
  /// 不得替用户 resume。
  ///
  /// TODO-2482 起**跨会话持久**：落盘 `<resumeDir>/user_paused.json`
  /// （见 [readUserPausedFile]），[restoreFromResume] 加回种子后按它补
  /// pause。选宿主落盘而不是 native 保留 paused 旗标，理由：① native
  /// 「add 即开始跑」契约不动，老 DLL/新 Dart 组合行为不漂；② 引擎的
  /// paused 旗标分不清「用户按的」与「策略按的」——策略暂停恢复条件解除
  /// 后应自动 resume，混进一个旗标就没法裁决了；用户意图本来就是 app 态，
  /// 真相源在宿主。
  final Set<String> _userPaused = <String>{};

  /// TODO-2526：暂停记录里「本轮瞬时加载失败但 `.resume` 还在盘上」的部分。
  /// 与 [_userPaused]（本会话已真实按下暂停的种子）分开持有：这些种子不在
  /// session 里，无处可 pause，但用户意图仍然有效 —— 下次启动加载成功时
  /// 必须还能按暂停落。所有写盘点经 [_persistUserPaused] 把两者并集写出，
  /// 否则任何一处「拿内存集整写覆盖文件」都会把这些记录冲掉。
  ///
  /// 两个消费点（都表达「用户最新动作否决了旧暂停记录」）：
  /// - [sweepUploadPolicy]：记录的种子出现在 session 里 = 用户本会话把它
  ///   重新 add 回来了（restore 只在启动跑一次），最新意图是「跑」；
  /// - [resumeTorrentByUser]：显式恢复必须连这里的记录一起清，否则并集
  ///   写盘仍记暂停，下次启动吞掉这次恢复。
  final Set<String> _pausedAwaitingRestore = <String>{};

  /// 用户暂停集的唯一写盘出口（[_userPaused] ∪ [_pausedAwaitingRestore]）。
  void _persistUserPaused() {
    writeUserPausedFile(
      _resumeDir,
      _userPaused.union(_pausedAwaitingRestore),
    );
  }

  /// 是否已做过一次性「清 upload_mode 残留」治愈（BUG-1493：旧版本给种子打上
  /// 的 upload_mode flag 会随 resume 复活，掐死下载；开机清一次即可）。
  bool _healedUploadMode = false;

  /// 底层 DLL 不支持上传策略原语时只记一次日志（避免每 tick 刷屏）。
  bool _loggedUploadControlUnsupported = false;

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
    required String resumeDir,
    Set<String>? restoreIds,
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
    final EmbeddedTorrentHost host = EmbeddedTorrentHost._(
      engine: engine,
      session: session,
      saveRoots:
          TorrentSaveRoots(active: baseSavePath, legacy: legacySavePaths),
      resumeDir: resumeDir,
      clockMs: clockMs ?? _defaultClockMs,
    );
    // TODO-1961-a：会话一建起来就把上次的种子加回来（续传 + 继续做种）。
    // [restoreIds] = 当前仍存在的计划 id 集合：**计划是真相源**，用户删掉的
    // 任务不能靠残留的 resume 文件复活成一个 UI 里看不见、却在偷偷做种的种子。
    host.restoreFromResume(restoreIds);
    return host;
  }

  static int _defaultClockMs() => DateTime.now().millisecondsSinceEpoch;

  /// 仅测试用：用现成 engine/session（可为 fromLookup 假绑定）构造宿主，
  /// 跳过 DLL 加载与 resume 恢复。存在的理由与
  /// `apply_limits_local_peers_test` 相同：要 DLL 的用例在 CI 整组 skip，
  /// 上传策略「绝不下发 upload_mode、关上传走 unchoke/pause」这条命脉
  /// （BUG-1493）必须有任何环境都会跑的用例守着。
  @visibleForTesting
  static EmbeddedTorrentHost forTesting({
    required EmbeddedTorrentEngine engine,
    required EmbeddedTorrentSession session,
    required String baseSavePath,
    required String resumeDir,
    int Function()? clockMs,
  }) {
    return EmbeddedTorrentHost._(
      engine: engine,
      session: session,
      saveRoots: TorrentSaveRoots(active: baseSavePath),
      resumeDir: resumeDir,
      clockMs: clockMs ?? _defaultClockMs,
    );
  }

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

  /// 见顶层 [pruneResumeFiles]（宿主内唯一的剪枝入口）。
  int _pruneResumeFiles(Set<String>? keepIds) =>
      pruneResumeFiles(resumeDir: _resumeDir, keepIds: keepIds);

  /// TODO-1961-a：把上次会话存下的种子加回来（续传 + 继续做种）。
  /// 先按 [keepIds] 剪枝再加载，保证被删计划的种子不会复活。
  /// 返回真正加回来的种子数。
  ///
  /// [keepIds] 为 null = 计划集合尚未加载：**既不剪枝也不加载**（见
  /// [pruneResumeFiles] 的哨兵约定）。不加载是因为没有真相源就无法判断哪些
  /// `.resume` 属于已被删掉的计划，加回来就是幽灵做种；真相源到位后由
  /// `AppModel._restoreEmbeddedTorrentSession` 看着 [hasRestored] 补一次。
  int restoreFromResume(Set<String>? keepIds) {
    if (keepIds == null) {
      debugPrint('[torrent] resume restore skipped: plan ids not loaded yet');
      return 0;
    }
    _pruneResumeFiles(keepIds);
    _hasRestored = true;
    try {
      final List<String> ids = _session.loadResumeDir(_resumeDir);
      if (ids.isNotEmpty) {
        debugPrint('[torrent] restored ${ids.length} torrent(s) from resume');
      }
      _restoreUserPaused(ids);
      return ids.length;
    } on Object catch (e) {
      debugPrint('[torrent] resume restore failed: $e');
      return 0;
    }
  }

  /// TODO-2482：按落盘的用户暂停集把刚加回来的种子重新按下暂停。
  ///
  /// `ht_load_resume_dir` 的契约是「加回来即开始跑」（清 paused 旗标），
  /// 所以用户暂停必须在这里补执行。add 与 pause 之间种子有一瞬是跑态（可能
  /// 发出 announce），这是该方案的已知代价，换来 native 契约零变更。
  ///
  /// TODO-2526：无主记录的剪除判据是「resume 目录里是否还有对应 `.resume`
  /// 文件」（见 [retainUserPausedRecords]），**不是**「本轮是否加载成功」——
  /// 加载失败可能是瞬时的（文件被占用/坏一次），按加载结果剪会让下次成功
  /// 加载的种子以跑态复活，用户按过的暂停凭空消失。文件还在但没加载成功的
  /// 记录进 [_pausedAwaitingRestore] 保留。
  void _restoreUserPaused(List<String> restoredIds) {
    final Set<String> wanted = readUserPausedFile(_resumeDir);
    if (wanted.isEmpty) return;
    final Set<String> restored = <String>{
      for (final String id in restoredIds) id.toLowerCase(),
    };
    for (final String id in wanted) {
      if (!restored.contains(id)) continue;
      if (_session.pauseTorrent(id, pause: true)) {
        _userPaused.add(id);
      }
    }
    final Set<String> keep = retainUserPausedRecords(
      resumeDir: _resumeDir,
      wanted: wanted,
      restoredIds: restoredIds,
    );
    _pausedAwaitingRestore
      ..clear()
      ..addAll(keep.difference(restored));
    if (!setEquals(keep, wanted)) {
      _persistUserPaused();
    }
  }

  /// TODO-1961-a：把当前所有种子的 resume data 落盘（每 [resumeSaveInterval]
  /// 至多一次；[force] 忽略节流，退出前用）。保存后按 [keepIds] 剪枝，
  /// 把本轮写出的无主种子文件一并清掉；[keepIds] 为 null 时**只保存不剪枝**
  /// （保存是非破坏性的，剪枝不是——见 [pruneResumeFiles]）。
  ///
  /// 返回本轮实际落盘的种子数（被节流跳过时返回 null，出错返回 0）。
  /// 失败/超时/异常一律 [debugPrint]：resume 长期写不进去是「重启后所有下载
  /// 蒸发」的前兆，静默吞掉等于让用户和开发者都看不见它坏了。
  int? saveResumeSnapshot(Set<String>? keepIds, {bool force = false}) {
    final int nowMs = _clockMs();
    if (!force &&
        _lastResumeSaveMs != 0 &&
        nowMs - _lastResumeSaveMs < resumeSaveInterval.inMilliseconds) {
      return null;
    }
    _lastResumeSaveMs = nowMs;
    final Stopwatch sw = Stopwatch()..start();
    try {
      final FtResumeSaveResult result = _session.saveResumeData(
        _resumeDir,
        timeoutMs: force ? shutdownSaveTimeoutMs : periodicSaveTimeoutMs,
      );
      sw.stop();
      _lastResumeSaveResult = result;
      if (result.failed > 0 || result.timedOut > 0) {
        debugPrint('[torrent] resume save: ${result.saved} saved, '
            '${result.failed} failed, ${result.timedOut} timed out '
            '(${sw.elapsedMilliseconds}ms)');
      } else if (!_loggedFirstResumeSave && result.saved > 0) {
        _loggedFirstResumeSave = true;
        debugPrint('[torrent] resume save: ${result.saved} saved '
            '(${sw.elapsedMilliseconds}ms)');
      } else if (sw.elapsedMilliseconds >= 500) {
        // 主 isolate 同步 FFI：卡这么久 UI 是真冻住的，必须留痕。
        debugPrint('[torrent] resume save blocked the UI isolate for '
            '${sw.elapsedMilliseconds}ms (${result.saved} saved)');
      }
      _pruneResumeFiles(keepIds);
      return result.saved;
    } on Object catch (e) {
      debugPrint('[torrent] resume save threw: $e');
      return 0;
    }
  }

  /// 底层 DLL 是否支持把限速套到局域网 peer（老的预编译 DLL 没有该符号）。
  bool get supportsLocalPeerRateLimit => _session.supportsLocalPeerRateLimit;

  /// 应用用户可调的全局资源限制（速率 + 连接数）。[downloadKbps]/[uploadKbps]
  /// 单位 KB/s（0 = 不限），[maxConnections]（0 = 引擎默认）。config 变更时
  /// 由 AppModel 调用，即时生效。
  ///
  /// [limitLocalPeers] = true 时限速同时作用于局域网 peer（默认 false =
  /// libtorrent 原生行为：局域网 peer 不受限速）。底层 DLL 太旧不支持时返回
  /// false（全局限速仍已应用）。
  bool applyLimits({
    int downloadKbps = 0,
    int uploadKbps = 0,
    int maxConnections = 0,
    bool limitLocalPeers = false,
  }) {
    return _session.applyLimits(
      downloadBps: downloadKbps > 0 ? downloadKbps * 1024 : 0,
      uploadBps: uploadKbps > 0 ? uploadKbps * 1024 : 0,
      connectionsLimit: maxConnections,
      limitLocalPeers: limitLocalPeers,
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
  ///
  /// native 侧会把 `maxUploadSlots > 0` 写进 unchoke_slots_limit——这会覆盖
  /// [sweepUploadPolicy] 下发的「关上传 = 0 槽位」，所以这里把已下发缓存置空，
  /// 让下一次 sweep（AppModel 在本调用之后紧接着 setUploadPolicy）重新裁决。
  bool applySessionSettings(QbConnectionConfig config) {
    _appliedSessionUploadEnabled = null;
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
  ///
  /// TODO-2481：暂停状态的真相在本宿主（适配器每 tick 重建，自持状态活
  /// 不过一轮），暂停/恢复/显示查询经 [EmbeddedPauseControl] 回注宿主。
  EmbeddedTorrentBackend backendView() {
    return EmbeddedTorrentBackend(
      session: _session,
      saveRoots: _saveRoots,
      closesSession: false,
      pauseControl: EmbeddedPauseControl(
        available: () => supportsPauseControl,
        pause: pauseTorrentByUser,
        resume: resumeTorrentByUser,
        isPaused: isTorrentPausedForDisplay,
      ),
    );
  }

  /// TODO-2481：底层 DLL 是否具备 per-torrent 暂停/恢复原语
  /// （与上传策略同一组符号；老随包 DLL 没有）。
  bool get supportsPauseControl => _session.supportsUploadControl;

  /// TODO-2481：用户显式暂停一个种子（清 auto_managed 再 pause，
  /// 否则队列管理器会自动恢复）。成功后记入 [_userPaused]。
  bool pauseTorrentByUser(String infoHash) {
    final String id = infoHash.toLowerCase();
    if (!_session.pauseTorrent(id, pause: true)) return false;
    _userPaused.add(id);
    // TODO-2482：用户暂停跨会话持久（真相源在宿主，落盘随 fastResume 目录）。
    _persistUserPaused();
    return true;
  }

  /// TODO-2481：用户显式恢复。同时清掉策略暂停记录 [_appliedPaused]，
  /// 让 [sweepUploadPolicy] 下一轮重新裁决 —— 做种超限的种子会被策略再次
  /// 暂停，这是策略语义使然，不是抢用户的手。
  bool resumeTorrentByUser(String infoHash) {
    final String id = infoHash.toLowerCase();
    if (!_session.pauseTorrent(id, pause: false)) return false;
    _userPaused.remove(id);
    // TODO-2526：该种子可能带着 awaiting 暂停记录（启动瞬时加载失败）又被
    // 用户重新 add 进 session —— 显式恢复必须两处记录都清，否则并集写盘
    // 仍记暂停，下次启动把用户这次恢复吞掉、强制按回暂停。
    _pausedAwaitingRestore.remove(id);
    _appliedPaused.remove(id);
    _persistUserPaused();
    return true;
  }

  /// TODO-2481：该种子当前是否处于（用户或策略）暂停态。native 的
  /// state_label 不导出 paused（libtorrent 里 paused 是 flag 不是 state），
  /// 快照层据此把 state 覆写成 pausedDL/pausedUP 供 UI 显示。
  bool isTorrentPausedForDisplay(String infoHash) {
    final String id = infoHash.toLowerCase();
    return _userPaused.contains(id) || _appliedPaused[id] == true;
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
      for (final FtTorrentStatus t in _session.listTorrents()) {
        final List<FtPeerInfo>? peers = _session.torrentPeers(t.id);
        if (peers == null || peers.isEmpty) continue;
        final TorrentContext ctx = TorrentContext(
          infoHash: t.id,
          totalSize: t.total,
          completedSize: t.done,
          isSeeding: t.isSeeding,
        );
        final List<PeerSnapshot> snapshots = <PeerSnapshot>[
          for (final FtPeerInfo pi in peers)
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

  /// 上传/做种策略扫描（BUG-1493 重写）。
  ///
  /// 旧实现把「不上传」翻译成 per-torrent `setUploadMode(enabled: false)`，而
  /// libtorrent 的 `upload_mode` flag 语义是「不再发出 piece 请求」= **停止
  /// 下载**——默认关上传的用户所有种子在 add 后一个 tick 内下载速率归零。
  ///
  /// 现映射（policy 本身不变，见 [shouldAllowUpload]）：
  /// - **会话级**：总开关 [QbConnectionConfig.uploadEnabled] 关 →
  ///   [EmbeddedTorrentSession.setUnchokeSlots] 清零（不给任何 peer unchoke
  ///   槽位 = 停止上传 payload；我们的下载请求是协议消息，不受影响）。开 →
  ///   还原为用户的 maxUploadSlots（未设则 libtorrent 默认）。
  ///   下载中种子的「不上传」只会由总开关触发（policy 对下载中恒 allow），
  ///   所以会话级开关足以覆盖，无需 per-torrent 原语。
  /// - **per-torrent**：做种（isFinished）超时/分享率达标/总开关关 →
  ///   [EmbeddedTorrentSession.pauseTorrent]（数据已完整，暂停只停做种，
  ///   与 qb 到达分享率后暂停同语义）；条件解除 → resume。
  ///   **绝不 pause 未完成的种子**（那才是真的掐死下载）。
  ///
  /// 老 DLL 没有新原语时整体降级为不动作（宁可上传也不掐下载），只记一次日志。
  /// 每 tick 由 `AnimeDownloadService` 调用；仅状态变化时下发 FFI。异常静默吞。
  /// 返回本轮实际改变的对象数（会话开关算 1，每个种子算 1）。
  int sweepUploadPolicy() {
    try {
      final int nowMs = _clockMs();
      int changed = 0;

      // 一次性治愈：清掉旧版本/旧 resume 打在种子上的 upload_mode 残留
      // （新旧 DLL 对 enabled: true 都是「只清 flag」，幂等且无副作用）。
      if (!_healedUploadMode) {
        if (_session.setUploadMode(enabled: true)) {
          _healedUploadMode = true;
        }
      }

      if (!_session.supportsUploadControl) {
        if (!_loggedUploadControlUnsupported) {
          _loggedUploadControlUnsupported = true;
          debugPrint('[torrent] upload policy skipped: bundled DLL lacks '
              'ht_set_unchoke_slots/ht_pause_torrent (upload stays enabled; '
              'downloads unaffected)');
        }
        return 0;
      }

      // ① 会话级总开关。
      final bool uploadEnabled = _uploadConfig.uploadEnabled;
      if (_appliedSessionUploadEnabled != uploadEnabled) {
        final int slots = uploadEnabled
            ? (_uploadConfig.maxUploadSlots > 0
                ? _uploadConfig.maxUploadSlots
                : -1)
            : 0;
        if (_session.setUnchokeSlots(slots)) {
          _appliedSessionUploadEnabled = uploadEnabled;
          changed++;
        }
      }

      // ② per-torrent：只对已完成（做种）种子暂停/恢复。
      final Set<String> live = <String>{};
      for (final FtTorrentStatus t in _session.listTorrents()) {
        live.add(t.id);
        // TODO-2481：用户显式暂停的种子策略整体跳过 —— 既不重复 pause，
        // 也绝不替用户 resume（否则下一 tick 就把用户按下的暂停偷偷抢回）。
        if (_userPaused.contains(t.id)) continue;
        if (t.isSeeding) {
          _seedStartMs.putIfAbsent(t.id, () => nowMs);
        }
        if (!t.isFinished) continue;
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
        final bool wantPaused = !allow;
        if (_appliedPaused[t.id] != wantPaused) {
          if (_session.pauseTorrent(t.id, pause: wantPaused)) {
            _appliedPaused[t.id] = wantPaused;
            changed++;
          }
        }
      }
      // 清理已移除种子的残留状态。
      _seedStartMs.removeWhere((String k, int v) => !live.contains(k));
      _appliedPaused.removeWhere((String k, bool v) => !live.contains(k));
      final int pausedBefore = _userPaused.length;
      _userPaused.removeWhere((String k) => !live.contains(k));
      // TODO-2526：awaiting 记录的种子出现在 live 里 = 用户本会话把它重新
      // add 回来了（restore 只在启动跑一次，不会二次入 session）——最新
      // 意图是「跑」，旧暂停记录随之作废。不清的话它整个会话跑态、下次
      // 启动却被按回暂停，吞掉用户的重新添加。
      final int awaitingBefore = _pausedAwaitingRestore.length;
      _pausedAwaitingRestore.removeWhere(live.contains);
      // 种子被删掉时把它的用户暂停记录一并从盘上剪掉（与内存同步）。
      // 只剪 [_userPaused]（本会话在 session 里出现过的）；不在 live 里的
      // [_pausedAwaitingRestore] 记录不能据此误剪，它们的去留由下次启动
      // 的 .resume 文件存在性裁决。
      if (_userPaused.length != pausedBefore ||
          _pausedAwaitingRestore.length != awaitingBefore) {
        _persistUserPaused();
      }
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
  ///
  /// TODO-1961-a：关 session **之前**强制存一次 resume —— 这是「下次启动能
  /// 续传/继续做种」的最后一道保存点，节流在这里必须让路（[force]）。
  /// [keepIds] 同 [saveResumeSnapshot]：当前仍存在的计划 id 集合。
  void dispose({Set<String>? keepIds}) {
    saveResumeSnapshot(keepIds, force: true);
    _session.close();
  }
}

/// TODO-1961-a：resume 目录里**无主**（不在 [keepIds] 里）的文件全删，返回删除数。
///
/// 唯一的剪枝入口（load 与 save 之后都走它）—— 「计划集合」是真相源，resume
/// 目录只是它的落盘镜像。不剪枝的后果很具体：用户删掉一个下载任务后，残留的
/// `.resume` 会在下次启动把种子加回来，UI 里看不见它，却在后台占带宽做种。
///
/// **[keepIds] 为 null = 计划集合尚未加载 → 拒绝剪枝，返回 -1。**
/// 这个哨兵必须能与「真的一个计划都没有」（空集合 → 全删，合法）区分开：把两者
/// 混为一谈，启动竞态里一次「还没加载完」的剪枝就会用空集合删光用户所有
/// `.resume`（= 全部下载/做种任务永久蒸发，且 UI 上无声无息）。
///
/// 顶层函数而非 [EmbeddedTorrentHost] 私有方法，是为了让这条不变量能在**没有
/// 原生 DLL 的环境**（含 CI）里被直接测到——host 的行为层用例要 DLL，永远 skip。
///
/// 单个文件删不掉不影响其它；目录不存在返回 0。
///
/// [keepIds] 内部按小写比对（infohash 的大小写只是书写差异）——调用方大小写
/// 不一致时的后果是「全都不匹配 → 全删」，太贵，不能靠约定。
int pruneResumeFiles({
  required String resumeDir,
  required Set<String>? keepIds,
}) {
  if (keepIds == null) {
    debugPrint('[torrent] resume prune refused: plan ids not loaded yet');
    return -1;
  }
  final Set<String> keep = <String>{
    for (final String id in keepIds) id.toLowerCase(),
  };
  int removed = 0;
  try {
    final Directory dir = Directory(resumeDir);
    if (!dir.existsSync()) return 0;
    for (final FileSystemEntity entity in dir.listSync()) {
      if (entity is! File || !entity.path.endsWith('.resume')) continue;
      final String id = p.basenameWithoutExtension(entity.path).toLowerCase();
      if (keep.contains(id)) continue;
      try {
        entity.deleteSync();
        removed++;
      } on FileSystemException catch (e) {
        debugPrint('[torrent] resume prune failed for ${entity.path}: $e');
      }
    }
  } on FileSystemException catch (e) {
    debugPrint('[torrent] resume prune aborted: $e');
    return removed;
  }
  return removed;
}

/// TODO-2482：用户暂停集落盘文件名（放 resume 目录旁，跟数据根走 ——
/// 它和 fastResume 一样描述「哪些种子该处于什么态」这一 app 状态）。
const String kUserPausedFileName = 'user_paused.json';

/// 读用户暂停集（`<resumeDir>/user_paused.json`，JSON 字符串数组，
/// infohash 小写）。文件不存在/坏 JSON 返回空集 —— 暂停态丢了顶多是
/// 种子恢复跑（用户可再按一次），不是数据损坏，不值得为它失败。
///
/// 顶层函数而非宿主私有方法：与 [pruneResumeFiles] 同理，让这条持久化
/// 契约能在没有原生 DLL 的环境（含 CI）被直接测到。
Set<String> readUserPausedFile(String resumeDir) {
  try {
    final File file = File(p.join(resumeDir, kUserPausedFileName));
    if (!file.existsSync()) return <String>{};
    final Object? json = jsonDecode(file.readAsStringSync());
    if (json is! List) return <String>{};
    return <String>{
      for (final Object? id in json)
        if (id is String && id.isNotEmpty) id.toLowerCase(),
    };
  } on Object catch (e) {
    debugPrint('[torrent] user paused read failed: $e');
    return <String>{};
  }
}

/// TODO-2526：重启恢复时用户暂停集里哪些记录该保留。
///
/// 判据：种子本轮真的加回来了（在 [restoredIds] 里），**或** resume 目录里
/// 还有它的 `<infohash>.resume` 文件。后者覆盖「瞬时加载失败」——文件还在
/// 说明任务没被删，暂停意图必须保留到下次成功加载；只有文件已不存在
/// （计划已删/已被剪枝）才是真无主。
///
/// 顶层函数而非宿主私有方法：与 [pruneResumeFiles] 同理，让这条不变量能在
/// 没有原生 DLL 的环境（含 CI）被直接测到。比对一律小写归一。
Set<String> retainUserPausedRecords({
  required String resumeDir,
  required Set<String> wanted,
  required Iterable<String> restoredIds,
}) {
  final Set<String> restored = <String>{
    for (final String id in restoredIds) id.toLowerCase(),
  };
  return <String>{
    for (final String id in wanted)
      if (restored.contains(id.toLowerCase()) ||
          File(p.join(resumeDir, '${id.toLowerCase()}.resume')).existsSync())
        id.toLowerCase(),
  };
}

/// 原子写用户暂停集（先写 `.tmp` 再 rename，与 native resume 落盘同姿态，
/// 绝不留半个文件）。失败 [debugPrint] 不抛（下一次状态变更会再写）。
void writeUserPausedFile(String resumeDir, Set<String> infoHashes) {
  try {
    final Directory dir = Directory(resumeDir);
    if (!dir.existsSync()) dir.createSync(recursive: true);
    final String target = p.join(resumeDir, kUserPausedFileName);
    final File tmp = File('$target.tmp');
    tmp.writeAsStringSync(
      jsonEncode(<String>[
        for (final String id in infoHashes) id.toLowerCase(),
      ]),
      flush: true,
    );
    tmp.renameSync(target);
  } on Object catch (e) {
    debugPrint('[torrent] user paused write failed: $e');
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
