import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'package:hibiki/src/media/torrent/anime_download_config.dart';
import 'package:hibiki/src/media/torrent/anime_download_plan.dart';
import 'package:hibiki/src/media/torrent/qbittorrent_client.dart';
import 'package:hibiki/src/media/video/video_filename_parser.dart';

/// 入库回调的结果：入库成功后新合集的 id（回填进计划）。
class AnimeDownloadImportOutcome {
  const AnimeDownloadImportOutcome({required this.collectionId});

  final int collectionId;
}

/// 把 qBittorrent 文件列表解析为视频绝对路径列表。纯函数。
///
/// [files] 非空：`savePath` join 种子内相对路径 `name`，按扩展名
/// （[kVideoExtensions]）过滤出视频；为空（老版本 qb / 接口失败）退化用
/// [QbTorrentInfo.contentPath] 当单文件（仍要求视频扩展名，否则返回空）。
List<String> resolveVideoAbsolutePaths(
  QbTorrentInfo info,
  List<QbTorrentFile> files,
) {
  if (files.isEmpty) {
    final String ext = p.extension(info.contentPath).toLowerCase();
    if (info.contentPath.isNotEmpty && kVideoExtensions.contains(ext)) {
      return <String>[info.contentPath];
    }
    return const <String>[];
  }
  final List<String> out = <String>[];
  for (final QbTorrentFile f in files) {
    if (kVideoExtensions.contains(p.extension(f.name).toLowerCase())) {
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
    final int? videoEp =
        parseVideoFilename(p.basename(videoAbsolutePaths.first)).episode;
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

/// 番剧下载完成监听服务：周期轮询 qBittorrent，对完成的计划落位字幕 sidecar
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
    QBittorrentClient Function(QbConnectionConfig config)? clientFactory,
    this.interval = const Duration(seconds: 20),
  })  : _configProvider = configProvider,
        _importer = importer,
        _clientFactory = clientFactory ?? _defaultClientFactory;

  /// 种子在 qBittorrent 里消失（用户手动删除）后，计划保留等待的时长；
  /// 超过（按 [AnimeDownloadPlan.createdAtMs] 判断）标 failed。
  static const Duration torrentMissingTimeout = Duration(hours: 48);

  static QBittorrentClient _defaultClientFactory(QbConnectionConfig config) {
    return QBittorrentClient(
      baseUrl: config.baseUrl,
      username: config.username,
      password: config.password,
    );
  }

  final AnimeDownloadPlanStore store;
  final QbConnectionConfig? Function() _configProvider;
  final Future<AnimeDownloadImportOutcome?> Function(
    AnimeDownloadPlan plan,
    List<String> videoAbsolutePaths,
  ) _importer;
  final QBittorrentClient Function(QbConnectionConfig config) _clientFactory;
  final Duration interval;

  Timer? _timer;
  bool _ticking = false;

  /// 启动周期轮询（先立即 tick 一次，再每 [interval] 一次）。
  void start() {
    if (_timer != null) return;
    _timer = Timer.periodic(interval, (_) => unawaited(tick()));
    unawaited(tick());
  }

  /// 停止周期轮询（进行中的 tick 自然收尾，不打断）。
  void stop() {
    _timer?.cancel();
    _timer = null;
  }

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
  }

  /// 边下边播（提前入库）：不等种子完成，立刻按计划入库。顺序下载模式下视频
  /// 从下载初期即可顺序播放；还没下到的集在库里表现为缺失态，下载补齐后自然
  /// 可播。成功后计划标 imported，完成轮询自然跳过，不会重复入库。
  ///
  /// 预检种子元数据已解析出视频文件（磁力刚添加时文件列表为空——此时直接
  /// 返回 false 且**不动计划状态**，避免误标 failed）。返回 true = 已入库。
  Future<bool> importNow(String planId) async {
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
    final QBittorrentClient client = _clientFactory(config);
    try {
      final List<QbTorrentInfo> torrents = await client.fetchTorrents(
        category: config.category.isEmpty ? null : config.category,
      );
      QbTorrentInfo? info;
      for (final QbTorrentInfo t in torrents) {
        if (t.hash.toLowerCase() == plan.id.toLowerCase()) {
          info = t;
          break;
        }
      }
      if (info == null) return false;
      // 预检：元数据未解析（文件列表还空）时不入库、不动计划状态。
      final List<QbTorrentFile> files =
          await client.fetchTorrentFiles(info.hash);
      if (resolveVideoAbsolutePaths(info, files).isEmpty) return false;
      await _finishPlan(client, plan, info);
    } catch (_) {
      return false;
    } finally {
      client.close();
    }
    final List<AnimeDownloadPlan> after = await store.loadAll();
    for (final AnimeDownloadPlan p in after) {
      if (p.id == planId) {
        return p.status == AnimeDownloadPlan.statusImported;
      }
    }
    return false;
  }

  Future<void> _tickOnce() async {
    final QbConnectionConfig? config = _configProvider();
    if (config == null || !config.isConfigured) return;

    final List<AnimeDownloadPlan> plans = await store.loadAll();
    final List<AnimeDownloadPlan> pending = <AnimeDownloadPlan>[
      for (final AnimeDownloadPlan plan in plans)
        if (plan.status == AnimeDownloadPlan.statusDownloading) plan,
    ];
    // 没有等待中的计划就不建连接。
    if (pending.isEmpty) return;

    final QBittorrentClient client = _clientFactory(config);
    try {
      final List<QbTorrentInfo> torrents = await client.fetchTorrents(
        category: config.category.isEmpty ? null : config.category,
      );
      final Map<String, QbTorrentInfo> byHash = <String, QbTorrentInfo>{
        for (final QbTorrentInfo t in torrents) t.hash.toLowerCase(): t,
      };
      final int nowMs = DateTime.now().millisecondsSinceEpoch;

      for (final AnimeDownloadPlan plan in pending) {
        final QbTorrentInfo? info = byHash[plan.id.toLowerCase()];
        if (info == null) {
          // 用户在 qb 里删了种子：超时标 failed，否则等下轮（可能刚添加还没上列表）。
          if (nowMs - plan.createdAtMs > torrentMissingTimeout.inMilliseconds) {
            await store.save(plan.copyWith(
              status: AnimeDownloadPlan.statusFailed,
              failReason: 'torrent missing',
            ));
          }
          continue;
        }
        if (!info.isComplete) continue;
        await _finishPlan(client, plan, info);
      }
    } finally {
      client.close();
    }
  }

  /// 单个计划的完成处理：解析视频路径 → 字幕 sidecar 落位 → 入库回调 →
  /// 状态落盘（成功 imported + collectionId；失败 failed，不重试）。
  Future<void> _finishPlan(
    QBittorrentClient client,
    AnimeDownloadPlan plan,
    QbTorrentInfo info,
  ) async {
    final List<QbTorrentFile> files = await client.fetchTorrentFiles(info.hash);
    final List<String> videos = resolveVideoAbsolutePaths(info, files);

    // 先落 sidecar 再入库：播放器按 sidecar 自动发现即可认到字幕，
    // 不依赖 DB 特殊路径。
    await _placeSidecars(videos, plan.subtitles);

    AnimeDownloadImportOutcome? outcome;
    String? importError;
    try {
      outcome = await _importer(plan, videos);
    } catch (e) {
      importError = 'import failed: $e';
    }
    if (outcome != null) {
      await store.save(plan.copyWith(
        status: AnimeDownloadPlan.statusImported,
        collectionId: outcome.collectionId,
      ));
    } else {
      await store.save(plan.copyWith(
        status: AnimeDownloadPlan.statusFailed,
        failReason: importError ?? 'import failed',
      ));
    }
  }

  /// 把配对到的字幕从暂存复制成视频 sidecar。已存在同名文件跳过不覆盖；
  /// 单条复制失败跳过不影响其它。
  Future<void> _placeSidecars(
    List<String> videoAbsolutePaths,
    List<PlanSubtitle> subtitles,
  ) async {
    final Map<String, PlanSubtitle> pairs =
        pairSubtitlesToVideos(videoAbsolutePaths, subtitles);
    for (final MapEntry<String, PlanSubtitle> entry in pairs.entries) {
      try {
        final File target = File(sidecarPathFor(entry.key, entry.value));
        if (await target.exists()) continue;
        final File staged = File(entry.value.stagedPath);
        if (!await staged.exists()) continue;
        await target.parent.create(recursive: true);
        await staged.copy(target.path);
      } catch (_) {
        // 单条失败跳过。
      }
    }
  }
}
