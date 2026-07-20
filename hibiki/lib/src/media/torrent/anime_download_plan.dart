import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

/// 计划里一条已暂存的字幕（选种那一刻从 Jimaku 下载并落地到暂存目录）。
class PlanSubtitle {
  const PlanSubtitle({
    required this.fileName,
    required this.stagedPath,
    this.episode,
    this.language,
  });

  /// 从字幕文件名解析出的集号；null = 未识别。
  final int? episode;

  /// Jimaku 原始文件名（含扩展名，sidecar 落位时取扩展名用）。
  final String fileName;

  /// 已下载落地的暂存绝对路径。
  final String stagedPath;

  /// 语言代码（`ja` / `zh` / ...）；null = 未识别。
  final String? language;
}

/// 番剧下载计划：选种那一刻生成的唯一状态载体。
///
/// 完成钩子（`AnimeDownloadService`）只按计划执行 sidecar 落位与入库回调，
/// 不再做任何网络决策；计划以 JSON 落盘（见 [AnimeDownloadPlanStore]）。
class AnimeDownloadPlan {
  const AnimeDownloadPlan({
    required this.id,
    required this.createdAtMs,
    required this.seriesTitle,
    required this.torrentTitle,
    required this.magnet,
    required this.qbCategory,
    this.anilistId,
    this.coverUrl,
    this.subtitles = const <PlanSubtitle>[],
    this.status = statusDownloading,
    this.failReason,
    this.collectionId,
    this.contentKind = kindVideo,
  });

  /// 内容类型：视频（走视频库入库，番剧默认）。
  static const String kindVideo = 'video';

  /// 内容类型：书（epub → 阅读库）。
  static const String kindBook = 'book';

  /// 内容类型：自动（按文件扩展名分流：视频→视频库、epub→阅读库）。
  static const String kindAuto = 'auto';

  /// 下载中（qBittorrent 未完成，等下轮 tick）。
  static const String statusDownloading = 'downloading';

  /// 已入库（[collectionId] 已回填）。
  static const String statusImported = 'imported';

  /// 失败（原因见 [failReason]；不重试，用户可在 UI 重下）。
  static const String statusFailed = 'failed';

  /// 计划 id = 种子 infoHash（小写十六进制），与 qBittorrent 列表比对用。
  final String id;

  /// 计划创建时刻（epoch 毫秒）；种子在 qb 里消失时按此判断超时。
  final int createdAtMs;

  /// AniList id；null = 未关联。
  final int? anilistId;

  /// 合集名（AniList displayTitle）。
  final String seriesTitle;

  /// AniList 封面 URL；null = 无。
  final String? coverUrl;

  /// 种子标题（Nyaa 显示名）。
  final String torrentTitle;

  /// 推给 qBittorrent 的 URL（magnet 或 .torrent URL）。
  final String magnet;

  /// 该下载在 qBittorrent 里的分类。
  final String qbCategory;

  /// 选种时一并暂存的字幕列表（顺序 = 计划生成时的偏好顺序）。
  final List<PlanSubtitle> subtitles;

  /// [statusDownloading] / [statusImported] / [statusFailed]。
  final String status;

  /// 失败原因；仅 [statusFailed] 时有意义。
  final String? failReason;

  /// 入库后回填的合集 id；仅 [statusImported] 时有意义。
  final int? collectionId;

  /// 内容类型（[kindVideo] / [kindBook] / [kindAuto]），决定完成后走视频库还是
  /// 阅读库入库。默认 [kindVideo]（番剧 + 老计划向后兼容）。
  final String contentKind;

  /// 注意：可空字段（[failReason] / [collectionId] 等）无法通过 copyWith
  /// 置回 null（标准模式局限）；状态机只前进赋值，不需要清空。
  AnimeDownloadPlan copyWith({
    String? id,
    int? createdAtMs,
    int? anilistId,
    String? seriesTitle,
    String? coverUrl,
    String? torrentTitle,
    String? magnet,
    String? qbCategory,
    List<PlanSubtitle>? subtitles,
    String? status,
    String? failReason,
    int? collectionId,
    String? contentKind,
  }) {
    return AnimeDownloadPlan(
      id: id ?? this.id,
      createdAtMs: createdAtMs ?? this.createdAtMs,
      anilistId: anilistId ?? this.anilistId,
      seriesTitle: seriesTitle ?? this.seriesTitle,
      coverUrl: coverUrl ?? this.coverUrl,
      torrentTitle: torrentTitle ?? this.torrentTitle,
      magnet: magnet ?? this.magnet,
      qbCategory: qbCategory ?? this.qbCategory,
      subtitles: subtitles ?? this.subtitles,
      status: status ?? this.status,
      failReason: failReason ?? this.failReason,
      collectionId: collectionId ?? this.collectionId,
      contentKind: contentKind ?? this.contentKind,
    );
  }
}

/// 序列化计划为 JSON Map（与 [decodeAnimeDownloadPlan] 互逆）。纯函数。
Map<String, dynamic> encodeAnimeDownloadPlan(AnimeDownloadPlan plan) {
  return <String, dynamic>{
    'id': plan.id,
    'createdAtMs': plan.createdAtMs,
    'anilistId': plan.anilistId,
    'seriesTitle': plan.seriesTitle,
    'coverUrl': plan.coverUrl,
    'torrentTitle': plan.torrentTitle,
    'magnet': plan.magnet,
    'qbCategory': plan.qbCategory,
    'subtitles': <Map<String, dynamic>>[
      for (final PlanSubtitle s in plan.subtitles)
        <String, dynamic>{
          'episode': s.episode,
          'fileName': s.fileName,
          'stagedPath': s.stagedPath,
          'language': s.language,
        },
    ],
    'status': plan.status,
    'failReason': plan.failReason,
    'collectionId': plan.collectionId,
    'contentKind': plan.contentKind,
  };
}

/// 解析 JSON Map 为计划。纯函数，容错：缺 `id` 返回 null；其余字段缺失/类型
/// 不对用安全默认值；`subtitles` 里坏条目逐条跳过。
AnimeDownloadPlan? decodeAnimeDownloadPlan(Map<dynamic, dynamic> raw) {
  try {
    final dynamic id = raw['id'];
    if (id is! String || id.isEmpty) return null;
    final List<PlanSubtitle> subtitles = <PlanSubtitle>[];
    final dynamic rawSubs = raw['subtitles'];
    if (rawSubs is List) {
      for (final dynamic s in rawSubs) {
        if (s is! Map) continue;
        final dynamic fileName = s['fileName'];
        final dynamic stagedPath = s['stagedPath'];
        if (fileName is! String || stagedPath is! String) continue;
        subtitles.add(PlanSubtitle(
          episode: s['episode'] is int ? s['episode'] as int : null,
          fileName: fileName,
          stagedPath: stagedPath,
          language: s['language'] is String ? s['language'] as String : null,
        ));
      }
    }
    return AnimeDownloadPlan(
      id: id,
      createdAtMs: raw['createdAtMs'] is int ? raw['createdAtMs'] as int : 0,
      anilistId: raw['anilistId'] is int ? raw['anilistId'] as int : null,
      seriesTitle:
          raw['seriesTitle'] is String ? raw['seriesTitle'] as String : '',
      coverUrl: raw['coverUrl'] is String ? raw['coverUrl'] as String : null,
      torrentTitle:
          raw['torrentTitle'] is String ? raw['torrentTitle'] as String : '',
      magnet: raw['magnet'] is String ? raw['magnet'] as String : '',
      qbCategory:
          raw['qbCategory'] is String ? raw['qbCategory'] as String : '',
      subtitles: subtitles,
      status: raw['status'] is String && (raw['status'] as String).isNotEmpty
          ? raw['status'] as String
          : AnimeDownloadPlan.statusDownloading,
      failReason:
          raw['failReason'] is String ? raw['failReason'] as String : null,
      collectionId:
          raw['collectionId'] is int ? raw['collectionId'] as int : null,
      // 缺字段（老计划）→ 视频（既有番剧计划行为不变）。
      contentKind: raw['contentKind'] is String &&
              (raw['contentKind'] as String).isNotEmpty
          ? raw['contentKind'] as String
          : AnimeDownloadPlan.kindVideo,
    );
  } catch (_) {
    return null;
  }
}

/// 计划的磁盘存储（每计划一个 JSON 文件 + 每计划一个字幕暂存目录）。
///
/// 目录布局（[baseDir] 由调用方传 `<appDocs>/anime_downloads`）：
/// - 计划：`baseDir/plans/<id>.json`
/// - 字幕暂存：`baseDir/subs/<id>/`（选种时下载的字幕落这里，入库前复制成
///   视频 sidecar；删计划时连同删除）
///
/// 全部方法容错：坏文件跳过、IO 异常不抛。
class AnimeDownloadPlanStore {
  AnimeDownloadPlanStore({required this.baseDir});

  final Directory baseDir;

  Directory get _plansDir => Directory(p.join(baseDir.path, 'plans'));

  /// 计划 [planId] 的字幕暂存目录（约定布局，不保证已创建）。
  Directory subsDirFor(String planId) =>
      Directory(p.join(baseDir.path, 'subs', planId));

  File _planFile(String planId) => File(p.join(_plansDir.path, '$planId.json'));

  /// 读出全部计划（坏 JSON / 解析失败的文件逐个跳过）；按创建时间升序、
  /// 同时间按 id 排序，保证确定性。
  Future<List<AnimeDownloadPlan>> loadAll() async {
    final List<AnimeDownloadPlan> out = <AnimeDownloadPlan>[];
    try {
      final Directory dir = _plansDir;
      if (!await dir.exists()) return out;
      await for (final FileSystemEntity entity in dir.list()) {
        if (entity is! File || !entity.path.endsWith('.json')) continue;
        try {
          final dynamic json = jsonDecode(await entity.readAsString());
          if (json is! Map) continue;
          final AnimeDownloadPlan? plan = decodeAnimeDownloadPlan(json);
          if (plan != null) out.add(plan);
        } catch (_) {
          // 坏文件跳过，不影响其它计划。
        }
      }
    } catch (_) {
      // 目录不可读等：返回目前已读到的。
    }
    out.sort((AnimeDownloadPlan a, AnimeDownloadPlan b) {
      final int byTime = a.createdAtMs.compareTo(b.createdAtMs);
      return byTime != 0 ? byTime : a.id.compareTo(b.id);
    });
    return out;
  }

  /// 原子写入计划（临时文件 + rename，避免中途断电留半个 JSON）。
  Future<void> save(AnimeDownloadPlan plan) async {
    try {
      await _plansDir.create(recursive: true);
      final File target = _planFile(plan.id);
      final File tmp = File('${target.path}.tmp');
      await tmp.writeAsString(jsonEncode(encodeAnimeDownloadPlan(plan)));
      await tmp.rename(target.path);
    } catch (_) {
      // 写失败静默：调用方（周期 tick）下轮会重写。
    }
  }

  /// 删除计划 JSON，连同其字幕暂存目录。
  Future<void> delete(String id) async {
    try {
      final File file = _planFile(id);
      if (await file.exists()) await file.delete();
    } catch (_) {}
    try {
      final Directory subs = subsDirFor(id);
      if (await subs.exists()) await subs.delete(recursive: true);
    } catch (_) {}
  }
}
