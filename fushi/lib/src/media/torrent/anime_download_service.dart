import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart'
    show ValueNotifier, immutable, mapEquals;
import 'package:path/path.dart' as p;

import 'package:fushi/src/media/torrent/anime_download_config.dart';
import 'package:fushi/src/media/torrent/anime_download_plan.dart';
import 'package:fushi/src/media/torrent/anime_download_subtitle_resolver.dart';
import 'package:fushi/src/media/torrent/qb_torrent_backend.dart';
import 'package:fushi/src/media/torrent/qbittorrent_client.dart';
import 'package:fushi/src/media/torrent/torrent_backend.dart';
import 'package:fushi/src/media/video/video_filename_parser.dart';
import 'package:fushi/src/media/video/video_sidecar.dart'
    show listSidecarSubtitles;

/// 入库回调的结果：入库成功后新合集的 id（回填进计划）。
class AnimeDownloadImportOutcome {
  const AnimeDownloadImportOutcome({required this.collectionId});

  final int collectionId;
}

/// 单个下载中任务的实时观测值（BUG-1494：进度之外补上速度/流量/peer 数）。
///
/// 值语义相等（==/hashCode），供「内容没变不通知」的发布路径用。
@immutable
class DownloadTaskStats {
  const DownloadTaskStats({
    required this.progress,
    required this.downRateBps,
    required this.upRateBps,
    required this.downloadedBytes,
    required this.uploadedBytes,
    required this.numPeers,
    required this.state,
    required this.amountLeft,
  });

  /// 从后端快照投影。
  factory DownloadTaskStats.fromSnapshot(TorrentSnapshot info) {
    return DownloadTaskStats(
      progress: info.progress.clamp(0.0, 1.0).toDouble(),
      downRateBps: info.downRateBps,
      upRateBps: info.upRateBps,
      downloadedBytes: info.downloadedBytes,
      uploadedBytes: info.uploadedBytes,
      numPeers: info.numPeers,
      state: info.state,
      amountLeft: info.amountLeft,
    );
  }

  /// 下载进度 0.0 ~ 1.0。
  final double progress;

  /// 实时下载速率（字节/秒）。
  final int downRateBps;

  /// 实时上传速率（字节/秒）。
  final int upRateBps;

  /// 累计下载字节。
  final int downloadedBytes;

  /// 累计上传字节。
  final int uploadedBytes;

  /// 当前连接的 peer 数。
  final int numPeers;

  /// 后端状态字符串（TODO-2481：此前投影时被丢弃。qb 与内置引擎词汇不同，
  /// UI 一律经 `torrent_task_display.dart` 的纯函数映射，不裸比较）。
  final String state;

  /// 剩余待下载字节；-1 = 未知（TODO-2481：ETA 分子，此前投影时被丢弃）。
  final int amountLeft;

  @override
  bool operator ==(Object other) {
    return other is DownloadTaskStats &&
        other.progress == progress &&
        other.downRateBps == downRateBps &&
        other.upRateBps == upRateBps &&
        other.downloadedBytes == downloadedBytes &&
        other.uploadedBytes == uploadedBytes &&
        other.numPeers == numPeers &&
        other.state == state &&
        other.amountLeft == amountLeft;
  }

  @override
  int get hashCode => Object.hash(progress, downRateBps, upRateBps,
      downloadedBytes, uploadedBytes, numPeers, state, amountLeft);
}

/// 把种子文件列表解析为视频绝对路径列表。纯函数。
///
/// [files] 非空：`savePath` join 种子内相对路径 `name`，按扩展名
/// （[kVideoExtensions]）过滤出视频；为空（老版本 qb / 接口失败）退化用
/// [TorrentSnapshot.contentPath] 当单文件（仍要求视频扩展名，否则返回空）。
List<String> resolveVideoAbsolutePaths(
  TorrentSnapshot info,
  List<TorrentFileEntry> files,
) {
  if (files.isEmpty) {
    final String ext = p.extension(info.contentPath).toLowerCase();
    if (info.contentPath.isNotEmpty && kVideoExtensions.contains(ext)) {
      return <String>[info.contentPath];
    }
    return const <String>[];
  }
  final List<String> out = <String>[];
  for (final TorrentFileEntry f in files) {
    if (kVideoExtensions.contains(p.extension(f.name).toLowerCase())) {
      out.add(p.join(info.savePath, f.name));
    }
  }
  return out;
}

/// 阅读库支持的书籍扩展名（当前只有 EPUB —— reader_fushi 走 EPUB）。
const Set<String> kBookExtensions = <String>{'.epub'};

/// 把种子文件列表解析为书籍（epub）绝对路径列表。纯函数，与
/// [resolveVideoAbsolutePaths] 同姿态（files 为空退化用 contentPath 单文件）。
List<String> resolveBookAbsolutePaths(
  TorrentSnapshot info,
  List<TorrentFileEntry> files,
) {
  if (files.isEmpty) {
    final String ext = p.extension(info.contentPath).toLowerCase();
    if (info.contentPath.isNotEmpty && kBookExtensions.contains(ext)) {
      return <String>[info.contentPath];
    }
    return const <String>[];
  }
  final List<String> out = <String>[];
  for (final TorrentFileEntry f in files) {
    if (kBookExtensions.contains(p.extension(f.name).toLowerCase())) {
      out.add(p.join(info.savePath, f.name));
    }
  }
  return out;
}

/// 把计划里的字幕配对到视频（key = 视频绝对路径）。纯函数。
///
/// 视频集号用 [parseVideoFilename] 从文件名解析。配对规则：
/// ① 集号相等；② 恰好 1 视频 + 1 字幕且任一方集号缺失 → 直接配对；
/// ③ 其余不配。同集多字幕时选列表里第一个（= 计划生成时的偏好顺序）。
Map<String, PlanSubtitle> pairSubtitlesToVideos(
  List<String> videoAbsolutePaths,
  List<PlanSubtitle> subtitles,
) {
  final Map<String, PlanSubtitle> out = <String, PlanSubtitle>{};
  if (videoAbsolutePaths.isEmpty || subtitles.isEmpty) return out;

  // 规则 ①：集号相等。
  for (final String video in videoAbsolutePaths) {
    final int? episode = parseVideoFilename(p.basename(video)).episode;
    if (episode == null) continue;
    for (final PlanSubtitle sub in subtitles) {
      if (sub.episode == episode) {
        out[video] = sub;
        break;
      }
    }
  }

  // 规则 ②：恰好 1v1 且任一方集号缺失（双方都有但不等 → 规则 ③ 不配）。
  if (out.isEmpty && videoAbsolutePaths.length == 1 && subtitles.length == 1) {
    final int? videoEp = parseVideoFilename(
      p.basename(videoAbsolutePaths.first),
    ).episode;
    final int? subEp = subtitles.first.episode;
    if (videoEp == null || subEp == null) {
      out[videoAbsolutePaths.first] = subtitles.first;
    }
  }
  return out;
}

/// 字幕 sidecar 目标路径：`<视频目录>/<视频名去扩展>[.<lang>].<字幕扩展名>`。
/// 纯函数。language 为 null/空省略 lang 段；字幕扩展名从 [PlanSubtitle.fileName]
/// 取（小写），取不到退化 `.srt`。
String sidecarPathFor(String videoAbsolutePath, PlanSubtitle sub) {
  final String dir = p.dirname(videoAbsolutePath);
  final String stem = p.basenameWithoutExtension(videoAbsolutePath);
  String ext = p.extension(sub.fileName).toLowerCase();
  if (ext.isEmpty) ext = '.srt';
  final String? language = sub.language;
  final String langSegment =
      (language == null || language.isEmpty) ? '' : '.$language';
  return p.join(dir, '$stem$langSegment$ext');
}

/// 番剧下载完成监听服务：周期轮询种子后端，对完成的计划落位字幕 sidecar
/// 并调用入库回调（骨架对齐 `VideoWatchTracker` 的 start/stop + Timer.periodic）。
///
/// 职责边界：**不直接碰 Drift/仓库**——入库逻辑经 [importer] 回调注入
/// （AppModel 接线时组装 importSplitPlaylist 等），使本服务可纯 fake 测试。
class AnimeDownloadService {
  AnimeDownloadService({
    required this.store,
    required QbConnectionConfig? Function() configProvider,
    required Future<AnimeDownloadImportOutcome?> Function(
      AnimeDownloadPlan plan,
      List<String> videoAbsolutePaths,
    ) importer,
    TorrentBackend Function(QbConnectionConfig config)? backendFactory,
    Future<int?> Function(
      AnimeDownloadPlan plan,
      List<String> bookAbsolutePaths,
    )? bookImporter,
    Future<ResolvedPlanSubtitles> Function(
      AnimeDownloadPlan plan,
      List<String> videoAbsolutePaths,
    )? subtitleResolver,
    void Function()? onTick,
    this.interval = const Duration(seconds: 20),
  })  : _configProvider = configProvider,
        _importer = importer,
        _bookImporter = bookImporter,
        _subtitleResolver = subtitleResolver,
        _backendFactory = backendFactory ?? _defaultBackendFactory,
        _onTick = onTick;

  /// 种子在后端里消失（用户手动删除）后，计划保留等待的时长；
  /// 超过（按 [AnimeDownloadPlan.createdAtMs] 判断）标 failed。
  static const Duration torrentMissingTimeout = Duration(hours: 48);

  /// 默认后端工厂：外接 qBittorrent WebUI（AppModel 不传工厂时走这里）。
  static TorrentBackend _defaultBackendFactory(QbConnectionConfig config) {
    return QbTorrentBackend(
      QBittorrentClient(
        baseUrl: config.baseUrl,
        username: config.username,
        password: config.password,
      ),
    );
  }

  final AnimeDownloadPlanStore store;
  final QbConnectionConfig? Function() _configProvider;
  final Future<AnimeDownloadImportOutcome?> Function(
    AnimeDownloadPlan plan,
    List<String> videoAbsolutePaths,
  ) _importer;

  /// 书籍（epub）入库回调（AppModel 接线 EpubImporter；null = 不支持书，
  /// 遇书内容按失败处理）。返回成功入库的书本数（0/null = 无/失败）。
  final Future<int?> Function(
    AnimeDownloadPlan plan,
    List<String> bookAbsolutePaths,
  )? _bookImporter;

  /// 延迟字幕解析回调（[AnimeDownloadPlan.subtitlePending] 的计划完成时调用，
  /// 用包内真实视频文件名反查 Jimaku，见 [JimakuPlanSubtitleResolver]）。
  /// null = 不支持补取，pending 计划会显式落 [AnimeDownloadPlan.subtitleUnavailable]。
  final Future<ResolvedPlanSubtitles> Function(
    AnimeDownloadPlan plan,
    List<String> videoAbsolutePaths,
  )? _subtitleResolver;

  final TorrentBackend Function(QbConnectionConfig config) _backendFactory;

  /// 每 tick 起始（早于「无 pending 计划则跳过」判断）无条件跑一次的钩子；
  /// 内置引擎接反吸血扫描（种子做种期仍需封吸血 peer，不能被 pending 门控）。
  final void Function()? _onTick;
  final Duration interval;

  Timer? _timer;
  bool _ticking = false;
  final Map<String, Future<void>> _planOperationTails =
      <String, Future<void>>{};
  final Map<String, Future<bool>> _importNowInFlight = <String, Future<bool>>{};

  /// 下载中计划的实时进度（planId → 0.0~1.0），每轮 tick 从后端快照
  /// [TorrentSnapshot.progress] 透传（服务本就轮询 listTorrents，UI 不再另建
  /// 连接）。只含「后端在列且未完成」的计划；完成/失败/消失自动移出。
  /// UI（任务行）用 ValueListenableBuilder 订阅换成确定进度环 + 百分比。
  final ValueNotifier<Map<String, double>> downloadProgress =
      ValueNotifier<Map<String, double>>(const <String, double>{});

  /// 下载中计划的实时观测值（planId → 速度/流量/peer 数；BUG-1494）。
  /// 键集合与 [downloadProgress] 一致，UI 任务行用它渲染速度与流量。
  final ValueNotifier<Map<String, DownloadTaskStats>> downloadStats =
      ValueNotifier<Map<String, DownloadTaskStats>>(
          const <String, DownloadTaskStats>{});

  /// 发布新一轮进度快照；内容没变不通知（避免无谓重建任务行）。
  void _publishProgress(
    Map<String, double> next, [
    Map<String, DownloadTaskStats> stats = const <String, DownloadTaskStats>{},
  ]) {
    if (!mapEquals(downloadStats.value, stats)) {
      downloadStats.value = Map<String, DownloadTaskStats>.unmodifiable(stats);
    }
    if (mapEquals(downloadProgress.value, next)) return;
    downloadProgress.value = Map<String, double>.unmodifiable(next);
  }

  /// 有活跃下载（内置引擎）时的加密轮询间隔。20s 的常规 tick 对「速度/进度在
  /// 动」的观感来说等于静止（BUG-1494）；内置引擎的 listTorrents 是本进程内
  /// 同步 FFI，3s 一次开销可忽略。外接 qb 保持 [interval]：每 tick 都是一次
  /// 全新 WebUI 登录，提频会放大认证失败计数（qb 默认 5 次封 IP 一小时）。
  static const Duration activeInterval = Duration(seconds: 3);

  /// 当前定时器的周期（诊断/测试用；未启动为 null）。
  Duration? get currentPollInterval => _currentPeriod;
  Duration? _currentPeriod;

  /// 启动周期轮询（先立即 tick 一次，再按周期轮询）。
  void start() {
    if (_timer != null) return;
    _startTimer(interval);
    unawaited(tick());
  }

  void _startTimer(Duration period) {
    _currentPeriod = period;
    _timer = Timer.periodic(period, (_) => unawaited(tick()));
  }

  /// 停止周期轮询（进行中的 tick 自然收尾，不打断）。
  void stop() {
    _timer?.cancel();
    _timer = null;
    _currentPeriod = null;
  }

  /// 轮询周期决策（纯函数，可无定时器单测）：只有「内置引擎 + 有活跃下载」
  /// 才提频到 [active]；外接 qb 恒用 [idle]（见 [activeInterval] 注释）。
  static Duration resolvePollInterval({
    required QbConnectionConfig? config,
    required bool hasActiveDownloads,
    required bool isDesktop,
    required Duration idle,
    Duration active = activeInterval,
  }) {
    final bool embedded = config != null &&
        config.resolveBackend(isDesktop: isDesktop) ==
            QbConnectionConfig.backendEmbedded;
    return embedded && hasActiveDownloads ? active : idle;
  }

  /// tick 后按 [resolvePollInterval] 重排定时器周期。
  void _reschedule() {
    if (_timer == null) return; // 未 start / 已 stop：不自启。
    final Duration want = resolvePollInterval(
      config: _configProvider(),
      hasActiveDownloads: downloadProgress.value.isNotEmpty,
      isDesktop: _isDesktop(),
      idle: interval,
    );
    if (want == _currentPeriod) return;
    _timer?.cancel();
    _startTimer(want);
  }

  static bool _isDesktop() =>
      Platform.isWindows || Platform.isLinux || Platform.isMacOS;

  /// 轮询一次（可单独调用；测试用）。内置防重入：上一 tick 未完成则跳过。
  /// 整体容错：网络/文件系统异常静默跳过，下轮再试。
  Future<void> tick() async {
    if (_ticking) return;
    _ticking = true;
    try {
      await _tickOnce();
    } catch (_) {
      // 网络异常等：静默跳过，下轮再试。
    } finally {
      _ticking = false;
    }
    _reschedule();
  }

  /// 边下边播（提前入库）：不等种子完成，立刻按计划入库。顺序下载模式下视频
  /// 从下载初期即可顺序播放；还没下到的集在库里表现为缺失态，下载补齐后自然
  /// 可播。成功后只标 [AnimeDownloadPlan.importedEarly]，计划仍保持 downloading，
  /// 继续轮询真实进度；真正完成后才转 imported，且不会重复导入视频。
  ///
  /// 预检种子元数据已解析出视频文件（磁力刚添加时文件列表为空——此时直接
  /// 返回 false 且**不动计划状态**，避免误标 failed）。返回 true = 已入库。
  Future<bool> importNow(String planId) {
    final Future<bool>? existing = _importNowInFlight[planId];
    if (existing != null) return existing;
    late final Future<bool> operation;
    operation = _runPlanSerial<bool>(planId, () => _importNowUnlocked(planId))
        .whenComplete(() {
      if (identical(_importNowInFlight[planId], operation)) {
        _importNowInFlight.remove(planId);
      }
    });
    _importNowInFlight[planId] = operation;
    return operation;
  }

  Future<bool> _importNowUnlocked(String planId) async {
    final QbConnectionConfig? config = _configProvider();
    if (config == null || !config.isConfigured) return false;
    final List<AnimeDownloadPlan> plans = await store.loadAll();
    AnimeDownloadPlan? plan;
    for (final AnimeDownloadPlan candidate in plans) {
      if (candidate.id == planId &&
          candidate.status == AnimeDownloadPlan.statusDownloading) {
        plan = candidate;
        break;
      }
    }
    if (plan == null) return false;
    final TorrentBackend client = _backendFactory(config);
    try {
      final List<TorrentSnapshot> torrents = await client.listTorrents(
        category: config.category.isEmpty ? null : config.category,
      );
      TorrentSnapshot? info;
      for (final TorrentSnapshot t in torrents) {
        if (t.hash.toLowerCase() == plan.id.toLowerCase()) {
          info = t;
          break;
        }
      }
      if (info == null) return false;
      // 预检：元数据未解析（文件列表还空）时不入库、不动计划状态。
      final List<TorrentFileEntry> files = await client.listFiles(info.hash);
      final (List<String> videos, _) = _classifyContent(plan, info, files);
      if (videos.isEmpty) return false;
      if (!info.isComplete) {
        // BUG-1496：这里手上就有完整快照，必须把观测值一起带上。`_publishProgress`
        // 是无条件覆盖 `downloadStats`，只传进度等于把**全表**的速度/流量清空，
        // 任务行要一直等到下一轮 tick 才恢复。
        _publishProgress(<String, double>{
          ...downloadProgress.value,
          plan.id: info.progress.clamp(0.0, 1.0).toDouble(),
        }, <String, DownloadTaskStats>{
          ...downloadStats.value,
          plan.id: DownloadTaskStats.fromSnapshot(info),
        });
      }
      await _finishPlan(
        client,
        plan,
        info,
        keepDownloading: !info.isComplete,
        importBooks: info.isComplete,
      );
    } catch (_) {
      return false;
    } finally {
      client.close();
    }
    final List<AnimeDownloadPlan> after = await store.loadAll();
    for (final AnimeDownloadPlan p in after) {
      if (p.id == planId) {
        return p.status == AnimeDownloadPlan.statusImported || p.importedEarly;
      }
    }
    return false;
  }

  /// 删除计划并在后端支持时真实取消种子。与 importNow/tick 共用 per-plan
  /// 串行边界，避免「删除后旧 tick 晚回又 save 把计划复活」。
  Future<bool> deletePlan(String planId, {bool deleteFiles = false}) =>
      _runPlanSerial<bool>(planId, () async {
        final QbConnectionConfig? config = _configProvider();
        if (config != null && config.isConfigured) {
          final TorrentBackend backend = _backendFactory(config);
          try {
            if (backend is TorrentRemovalBackend) {
              await backend.removeTorrent(planId, deleteFiles: deleteFiles);
            }
          } finally {
            backend.close();
          }
        }
        await store.delete(planId);
        return !(await store.loadAll()).any(
          (AnimeDownloadPlan plan) => plan.id == planId,
        );
      });

  Future<T> _runPlanSerial<T>(
    String planId,
    Future<T> Function() operation,
  ) async {
    final Future<void> previous =
        _planOperationTails[planId] ?? Future<void>.value();
    final Completer<void> done = Completer<void>();
    final Future<void> tail = done.future;
    _planOperationTails[planId] = tail;
    await previous;
    try {
      return await operation();
    } finally {
      done.complete();
      if (identical(_planOperationTails[planId], tail)) {
        _planOperationTails.remove(planId);
      }
    }
  }

  Future<void> _tickOnce() async {
    // 反吸血等后端维护钩子先跑：与是否有等待入库的计划无关（做种期也要封）。
    _onTick?.call();

    final QbConnectionConfig? config = _configProvider();
    if (config == null || !config.isConfigured) {
      _publishProgress(const <String, double>{});
      return;
    }

    final List<AnimeDownloadPlan> plans = await store.loadAll();
    final List<AnimeDownloadPlan> pending = <AnimeDownloadPlan>[
      for (final AnimeDownloadPlan plan in plans)
        if (plan.status == AnimeDownloadPlan.statusDownloading) plan,
    ];
    // 没有等待中的计划就不建连接。
    if (pending.isEmpty) {
      _publishProgress(const <String, double>{});
      return;
    }

    final TorrentBackend client = _backendFactory(config);
    try {
      final List<TorrentSnapshot> torrents = await client.listTorrents(
        category: config.category.isEmpty ? null : config.category,
      );
      final Map<String, TorrentSnapshot> byHash = <String, TorrentSnapshot>{
        for (final TorrentSnapshot t in torrents) t.hash.toLowerCase(): t,
      };
      final int nowMs = DateTime.now().millisecondsSinceEpoch;
      final Map<String, double> progressNext = <String, double>{
        for (final AnimeDownloadPlan plan in pending)
          if (byHash[plan.id.toLowerCase()] case final TorrentSnapshot info
              when !info.isComplete && !info.isFailure)
            plan.id: info.progress.clamp(0.0, 1.0).toDouble(),
      };
      final Map<String, DownloadTaskStats> statsNext =
          <String, DownloadTaskStats>{
        for (final AnimeDownloadPlan plan in pending)
          if (byHash[plan.id.toLowerCase()] case final TorrentSnapshot info
              when !info.isComplete)
            plan.id: DownloadTaskStats.fromSnapshot(info),
      };
      _publishProgress(progressNext, statsNext);

      for (final AnimeDownloadPlan plan in pending) {
        final TorrentSnapshot? info = byHash[plan.id.toLowerCase()];
        await _runPlanSerial<void>(plan.id, () async {
          final AnimeDownloadPlan? current = await _loadDownloadingPlan(
            plan.id,
          );
          if (current == null) return;
          if (info == null) {
            // 用户在后端删了种子：超时才失败，否则等下轮（可能刚添加还没上列表）。
            // 这条写路径也必须处于 per-plan 串行边界；否则 deletePlan 删完 JSON 后，
            // 旧 tick 仍可能拿着 stale plan 晚回 save，把已删任务复活。
            if (nowMs - current.createdAtMs >
                torrentMissingTimeout.inMilliseconds) {
              await store.save(
                current.copyWith(
                  status: AnimeDownloadPlan.statusFailed,
                  failReason: 'torrent missing',
                ),
              );
            }
            return;
          }
          if (info.isFailure) {
            await store.save(
              current.copyWith(
                status: AnimeDownloadPlan.statusFailed,
                failReason: 'torrent backend state: ${info.state}',
                importInProgress: false,
              ),
            );
            return;
          }
          if (!info.isComplete) return;
          await _finishPlan(client, current, info);
        });
      }
    } finally {
      client.close();
    }
  }

  Future<AnimeDownloadPlan?> _loadDownloadingPlan(String planId) async {
    for (final AnimeDownloadPlan plan in await store.loadAll()) {
      if (plan.id == planId &&
          plan.status == AnimeDownloadPlan.statusDownloading) {
        return plan;
      }
    }
    return null;
  }

  /// 按计划 [AnimeDownloadPlan.contentKind] 把已完成文件分流成（视频, 书）两组
  /// 绝对路径。纯映射：video 只取视频、book 只取书、auto 两者都取。
  (List<String>, List<String>) _classifyContent(
    AnimeDownloadPlan plan,
    TorrentSnapshot info,
    List<TorrentFileEntry> files,
  ) {
    switch (plan.contentKind) {
      case AnimeDownloadPlan.kindBook:
        return (const <String>[], resolveBookAbsolutePaths(info, files));
      case AnimeDownloadPlan.kindAuto:
        return (
          resolveVideoAbsolutePaths(info, files),
          resolveBookAbsolutePaths(info, files),
        );
      case AnimeDownloadPlan.kindVideo:
      default:
        return (resolveVideoAbsolutePaths(info, files), const <String>[]);
    }
  }

  /// 单个计划的处理：按内容类型分流 → 视频落 sidecar + 视频库入库、书走
  /// 阅读库入库 → 状态落盘。
  ///
  /// [keepDownloading] 只用于「边下边播」：视频入库成功后记录
  /// [AnimeDownloadPlan.importedEarly]，但保留 downloading 状态与进度轮询。真实
  /// 完成 tick 再进来时跳过重复视频导入，只补书籍分流并把状态转 imported。
  Future<void> _finishPlan(
    TorrentBackend client,
    AnimeDownloadPlan plan,
    TorrentSnapshot info, {
    bool keepDownloading = false,
    bool importBooks = true,
  }) async {
    final List<TorrentFileEntry> files = await client.listFiles(info.hash);
    final (List<String> videos, List<String> books) = _classifyContent(
      plan,
      info,
      files,
    );

    AnimeDownloadImportOutcome? outcome;
    int booksImported = 0;
    String? importError;

    // 字幕：pending 的计划到这一刻才第一次知道包内真实文件名，现在才配得准
    // （BUG-1206）。resolved/none 的老计划原样透传，行为不变。
    AnimeDownloadPlan resolved = plan;

    // 视频：先补字幕 → 落 sidecar → 入库（播放器按 sidecar 自动发现字幕）。
    if (videos.isNotEmpty) {
      resolved = await _resolveSubtitles(plan, videos);
      await _placeSidecars(videos, resolved.subtitles);
      if (!plan.importedEarly) {
        resolved = resolved.copyWith(importInProgress: true);
        if (await store.save(resolved)) {
          try {
            outcome = await _importer(resolved, videos);
          } catch (e) {
            importError = 'video import failed: $e';
          }
        } else {
          importError = 'video import marker persist failed';
        }
      }
    }

    // 书：走阅读库入库回调（epub）。
    if (importBooks && books.isNotEmpty) {
      final Future<int?> Function(AnimeDownloadPlan, List<String>)?
          bookImporter = _bookImporter;
      if (bookImporter == null) {
        importError ??= 'book import unsupported';
      } else {
        try {
          booksImported = await bookImporter(plan, books) ?? 0;
        } catch (e) {
          importError ??= 'book import failed: $e';
        }
      }
    }

    if (keepDownloading) {
      // 提前入库失败不应把仍在正常下载的任务标成 failed；保留下载状态，用户可
      // 稍后再试。字幕解析结论仍落盘，避免下一次重复网络决策。
      await store.save(
        resolved.copyWith(
          importedEarly: outcome != null || plan.importedEarly,
          collectionId: outcome?.collectionId,
          importInProgress: false,
        ),
      );
      return;
    }

    final bool imported =
        plan.importedEarly || outcome != null || booksImported > 0;
    if (imported) {
      await store.save(
        resolved.copyWith(
          status: AnimeDownloadPlan.statusImported,
          collectionId: outcome?.collectionId,
          importInProgress: false,
        ),
      );
    } else {
      await store.save(
        resolved.copyWith(
          status: AnimeDownloadPlan.statusFailed,
          failReason: importError ?? 'import failed',
          importInProgress: false,
        ),
      );
    }
  }

  /// 把 [AnimeDownloadPlan.subtitlePending] 的计划按 [videoAbsolutePaths]
  /// （包内真实视频）补取字幕，返回已带结论的计划副本。
  ///
  /// 非 pending（老计划：选种时就下好了字幕，或压根不要字幕）原样返回——**绝不
  /// 重取、绝不覆盖**已有的 [AnimeDownloadPlan.subtitles]。
  ///
  /// 任何失败路径都落 [AnimeDownloadPlan.subtitleUnavailable] + 原因，不静默：
  /// 视频照常入库（字幕缺失不该让整个下载判失败），用户在任务行能看见「字幕未
  /// 匹配」并用字幕对话框手动补。
  Future<AnimeDownloadPlan> _resolveSubtitles(
    AnimeDownloadPlan plan,
    List<String> videoAbsolutePaths,
  ) async {
    if (plan.subtitleStatus != AnimeDownloadPlan.subtitlePending) return plan;
    final Future<ResolvedPlanSubtitles> Function(
      AnimeDownloadPlan,
      List<String>,
    )? resolver = _subtitleResolver;
    if (resolver == null) {
      return plan.copyWith(
        subtitleStatus: AnimeDownloadPlan.subtitleUnavailable,
        subtitleNote: 'subtitle resolver unavailable',
      );
    }
    try {
      final ResolvedPlanSubtitles result = await resolver(
        plan,
        videoAbsolutePaths,
      );
      if (result.subtitles.isEmpty) {
        return plan.copyWith(
          subtitleStatus: AnimeDownloadPlan.subtitleUnavailable,
          subtitleNote: result.failureReason ?? 'no matching subtitle',
        );
      }
      return plan.copyWith(
        subtitles: result.subtitles,
        subtitleStatus: AnimeDownloadPlan.subtitleResolved,
      );
    } catch (e) {
      return plan.copyWith(
        subtitleStatus: AnimeDownloadPlan.subtitleUnavailable,
        subtitleNote: 'subtitle resolve failed: $e',
      );
    }
  }

  /// 把配对到的字幕从暂存复制成视频 sidecar。**该集已有任何 sidecar 就整条跳过**；
  /// 单条复制失败跳过不影响其它。
  ///
  /// 去重键是**语言无关**的（比对「这一集有没有 sidecar」，不是「有没有同名文件」）。
  /// 旧实现拿 [sidecarPathFor] 的全名当键，那只在 `language` 恒为 null（写出来永远是
  /// `x.srt`）时才等价。本 PR 让 `detectSubtitleLanguage` 认出 Netflix 的 `ja[cc]`
  /// 后 language 不再为 null，目标名变成 `x.ja.srt`，老的 `x.srt` 就挡不住写入了 →
  /// **同一集重下一次多出一份字幕**，且 [pickSidecar] 的优先级里带语言标记的排在前面，
  /// 默认选中还会从老档悄悄切到 `.ja` 档。用户看得见，且随重下次数累积。
  ///
  /// 为什么是「跳过」而不是「替换掉老档」：老档可能是用户手放的或手改过的字幕，
  /// 覆盖/删除它是破坏性的——原注释「已存在同名文件跳过不覆盖」表达的本来就是
  /// 「不动用户已有的字幕」，这里只是把键修正成它真正该有的粒度。副作用是默认选中
  /// **保持在老档不变**（因为压根不写第二份），这正是确定的、可预期的行为。
  Future<void> _placeSidecars(
    List<String> videoAbsolutePaths,
    List<PlanSubtitle> subtitles,
  ) async {
    final Map<String, PlanSubtitle> pairs = pairSubtitlesToVideos(
      videoAbsolutePaths,
      subtitles,
    );
    for (final MapEntry<String, PlanSubtitle> entry in pairs.entries) {
      try {
        final File target = File(sidecarPathFor(entry.key, entry.value));
        if (await _episodeAlreadyHasSidecar(entry.key)) continue;
        final File staged = File(entry.value.stagedPath);
        if (!await staged.exists()) continue;
        await target.parent.create(recursive: true);
        await staged.copy(target.path);
      } catch (_) {
        // 单条失败跳过。
      }
    }
  }

  /// [videoAbsolutePath] 这一集在同目录里是否已经有 sidecar 字幕（**任何语言、任何
  /// 格式**）。复用 [listSidecarSubtitles]——它是「属于这个视频的 sidecar」的既有唯一
  /// 判据（互联字幕推送也用它），不在这里另写一套后缀匹配。
  ///
  /// 目录不存在 / 读不动 → false（当作没有，让复制照常尝试；真失败会落到调用方的
  /// try/catch）。
  Future<bool> _episodeAlreadyHasSidecar(String videoAbsolutePath) async {
    final Directory dir = Directory(p.dirname(videoAbsolutePath));
    if (!await dir.exists()) return false;
    final List<String> names = <String>[];
    await for (final FileSystemEntity e in dir.list(followLinks: false)) {
      if (e is File) names.add(p.basename(e.path));
    }
    return listSidecarSubtitles(
      p.basenameWithoutExtension(videoAbsolutePath),
      names,
    ).isNotEmpty;
  }
}
