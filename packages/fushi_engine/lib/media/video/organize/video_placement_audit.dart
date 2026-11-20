/// 视频库「摆放审计」：只读地找出**结构上**放错位置的文件——电影长度的文件被挂在
/// 一部剧集的特别篇（第 0 季）下（所有者 2026-11-20：「很多合集里面的第 0 季，并
/// 不是第 0 季，甚至可能是电影」）。
///
/// 判据只用库里已有的事实，不猜标题：
/// - 作品是剧集（`media_type = 'tv'`），文件只绑在第 0 季；
/// - 文件时长 ≥ [kFeatureMinMinutes]，并且 ≥ 这部作品正片单集时长的
///   [kFeatureBaselineFactor] 倍（正片时长取本机正片文件时长的中位数，没有本机
///   正片就取资料源记的正片单集时长中位数；两者都没有 = 没有基线）。
///
/// 特别篇通常与正片同长或更短（OVA、小剧场、总集篇）；一个 90 分钟的「S00E01」
/// 几乎总是一部被文件名 / 目录带偏的剧场版——它在资料源里是另一部作品。
///
/// 时长来自规格探测缓存 `video_file_specs`，它是库页滚到哪探到哪的懒缓存（所有者
/// 本机库 1247 个视频只探过 700 个，82 个挂在第 0 季的文件里 46 个没有时长——
/// 《君の名は。》与哆啦A梦剧场版都在其中）。所以审计先让宿主把**缺时长的第 0 季
/// 文件**探一遍（[VideoDurationProber]），再下结论；仍然探不出的计入
/// [VideoPlacementAudit.unknownDuration]，不当成「没问题」。
///
/// **时长判据只是兜底**（所有者 2026-11-20：「为什么不直接让 ai 看？」）：审计同时
/// 给出每部作品的「待看清单」[VideoPlacementReview]——作品是什么、正片多长、哪些
/// 本机文件挂在第 0 季或者根本没绑到任何一集、各自的文件名 / 目录 / 时长 / 绑到的
/// 那一集叫什么。「这是不是真的特别篇」由模型看着这些事实判断
/// （`video_placement_ai.dart`），时长判据只在没有指派 AI 时用。
///
/// 纯 Dart（不 import flutter / 插件 / `package:fushi`）。
library;

import 'package:fushi_core/fushi_core.dart';

/// 电影长度的下限（分钟）。
const int kFeatureMinMinutes = 60;

/// 相对正片单集时长的倍数下限。
const int kFeatureBaselineFactor = 2;

/// 一条摆放问题。
enum VideoPlacementKind {
  /// 剧集合集里，个别电影长度的文件挂在特别篇下。修法：把它拆成独立作品，再按
  /// 电影识别。
  featureInSpecials('feature_in_specials'),

  /// 合集里**全部**本机文件都是挂在特别篇下的电影长度文件（一个「剧场版合集」
  /// 被整体认成了某部剧）。拆不出「留下的那部剧」，修法由人 / AI 判断。
  featuresOnlyWork('features_only_work'),

  /// 单个文件自己是一部作品，却被认成剧集并挂在特别篇。修法：按电影重新识别。
  movieAsSeries('movie_as_series');

  const VideoPlacementKind(this.wire);

  final String wire;
}

class VideoPlacementFinding {
  const VideoPlacementFinding({
    required this.kind,
    required this.workId,
    required this.workTitle,
    required this.bookUid,
    required this.fileTitle,
    required this.slot,
    required this.durationMinutes,
    required this.baselineMinutes,
  });

  final VideoPlacementKind kind;

  /// 作品 id（`collection:<id>` / `book:<uid>`）。
  final String workId;
  final String workTitle;
  final String bookUid;
  final String fileTitle;

  /// 现在绑到的集位（`S00E01`）。
  final String slot;
  final int durationMinutes;

  /// 这部作品的正片单集时长（分钟）；null = 没有基线。
  final int? baselineMinutes;

  Map<String, Object?> toJson() => <String, Object?>{
    'kind': kind.wire,
    'work': workId,
    'workTitle': workTitle,
    'uid': bookUid,
    'title': fileTitle,
    'boundTo': slot,
    'durationMinutes': durationMinutes,
    if (baselineMinutes != null) 'episodeMinutes': baselineMinutes,
  };
}

int? _median(List<int> values) {
  if (values.isEmpty) return null;
  final List<int> sorted = List<int>.of(values)..sort();
  return sorted[sorted.length ~/ 2];
}

String _slot(int season, int episode) =>
    'S${season.toString().padLeft(2, '0')}'
    'E${episode.toString().padLeft(2, '0')}';

/// 让宿主把 [paths] 的规格探出来并落进 `video_file_specs`（app：
/// `VideoSpecsService.resolve`，ffprobe 并发有闸门）。探不出的不抛。
typedef VideoDurationProber = Future<void> Function(List<String> paths);

/// 一次审计的结论。
class VideoPlacementAudit {
  const VideoPlacementAudit({
    required this.findings,
    required this.reviews,
    required this.unknownDuration,
  });

  /// 时长判据的结论（兜底）。
  final List<VideoPlacementFinding> findings;

  /// 给模型看的清单：每部「有本机文件挂在第 0 季 / 没绑到任何一集」的剧集作品。
  final List<VideoPlacementReview> reviews;

  /// 只绑在第 0 季、但拿不到时长（没探过 / 文件不在 / 探不出）的文件数。
  final int unknownDuration;
}

/// 待看清单里的一个文件。
class VideoPlacementReviewFile {
  const VideoPlacementReviewFile({
    required this.bookUid,
    required this.title,
    required this.videoPath,
    this.slot,
    this.minutes,
    this.episodeTitle,
    this.episodeMinutes,
  });

  final String bookUid;
  final String title;

  /// 绝对路径（宿主发给模型前换成相对来源库根的）。
  final String videoPath;

  /// 现在绑到的第 0 季集位；null = 在这部作品的合集里但没绑到任何一集。
  final String? slot;
  final int? minutes;

  /// 资料源里那一集的标题与时长。
  final String? episodeTitle;
  final int? episodeMinutes;
}

/// 一部要看的作品。
class VideoPlacementReview {
  const VideoPlacementReview({
    required this.workId,
    required this.title,
    required this.originalTitle,
    required this.year,
    required this.regularLocalFiles,
    required this.regularSeasons,
    required this.baselineMinutes,
    required this.files,
  });

  /// `collection:<id>` / `book:<uid>`。
  final String workId;
  final String title;
  final String? originalTitle;
  final int? year;

  /// 绑在正片季上的本机文件数。
  final int regularLocalFiles;

  /// 资料源里的正片各季：季号 → 集数。
  final Map<int, int> regularSeasons;
  final int? baselineMinutes;
  final List<VideoPlacementReviewFile> files;
}

class _WorkSpecials {
  _WorkSpecials(this.work);

  final VideoMetadataWorkRow work;

  /// uid → 它绑到的第 0 季分集行。
  final Map<String, VideoMetadataEpisodeRow> specials =
      <String, VideoMetadataEpisodeRow>{};
  final Set<String> regularUids = <String>{};
  final List<int> scrapedRuntimes = <int>[];
  final Map<int, int> regularSeasons = <int, int>{};

  /// 在这部作品的合集里、但没绑到任何一集的成员。
  final List<String> unbound = <String>[];
}

/// 审计全库（确定性顺序：按作品 id、文件 uid）。[probe] 为 null 时只用已有的时长
/// 缓存。
Future<VideoPlacementAudit> auditVideoPlacement(
  FushiDatabase db, {
  VideoDurationProber? probe,
}) async {
  final Map<String, VideoBookRow> books = <String, VideoBookRow>{
    for (final VideoBookRow row in await db.allVideoBooks()) row.bookUid: row,
  };
  final Map<int, List<VideoMetadataSeasonRow>> seasonsByWork =
      <int, List<VideoMetadataSeasonRow>>{};
  for (final VideoMetadataSeasonRow s
      in await db.getAllVideoMetadataSeasons()) {
    seasonsByWork
        .putIfAbsent(s.workId, () => <VideoMetadataSeasonRow>[])
        .add(s);
  }
  final Map<int, List<VideoMetadataEpisodeRow>> episodesBySeason =
      <int, List<VideoMetadataEpisodeRow>>{};
  for (final VideoMetadataEpisodeRow e
      in await db.getAllVideoMetadataEpisodes()) {
    episodesBySeason
        .putIfAbsent(e.seasonId, () => <VideoMetadataEpisodeRow>[])
        .add(e);
  }
  final Map<int, List<String>> videoMembers = <int, List<String>>{};
  for (final MediaCollectionItemRow item in await db.getAllCollectionItems()) {
    if (item.mediaType != MediaKind.video.dbValue) continue;
    if (!books.containsKey(item.entryKey)) continue;
    videoMembers
        .putIfAbsent(item.collectionId, () => <String>[])
        .add(item.entryKey);
  }

  final List<_WorkSpecials> candidates = <_WorkSpecials>[];
  final List<VideoMetadataWorkRow> works = await db.getAllVideoMetadataWorks()
    ..sort((VideoMetadataWorkRow a, VideoMetadataWorkRow b) => a.id - b.id);
  for (final VideoMetadataWorkRow work in works) {
    if (work.mediaType != 'tv') continue;
    final _WorkSpecials w = _WorkSpecials(work);
    final Set<String> bound = <String>{};
    for (final VideoMetadataSeasonRow season
        in seasonsByWork[work.id] ?? const <VideoMetadataSeasonRow>[]) {
      final List<VideoMetadataEpisodeRow> episodes =
          episodesBySeason[season.id] ?? const <VideoMetadataEpisodeRow>[];
      if (season.seasonNumber != 0) {
        w.regularSeasons[season.seasonNumber] = episodes.length;
      }
      for (final VideoMetadataEpisodeRow e in episodes) {
        if (season.seasonNumber != 0 && e.runtimeMinutes != null) {
          w.scrapedRuntimes.add(e.runtimeMinutes!);
        }
        final String? uid = e.bookUid;
        if (uid == null || !books.containsKey(uid)) continue;
        bound.add(uid);
        if (season.seasonNumber == 0) {
          w.specials.putIfAbsent(uid, () => e);
        } else {
          w.regularUids.add(uid);
        }
      }
    }
    // 绑到过正片季的 uid 不算（多集文件）。
    w.specials.removeWhere(
      (String uid, VideoMetadataEpisodeRow _) => w.regularUids.contains(uid),
    );
    final int? collectionId = work.collectionId;
    if (collectionId != null) {
      w.unbound.addAll(
        <String>[
          for (final String uid
              in videoMembers[collectionId] ?? const <String>[])
            if (!bound.contains(uid)) uid,
        ]..sort(),
      );
    }
    if (w.specials.isNotEmpty || w.unbound.isNotEmpty) candidates.add(w);
  }

  // 只读要判断的那些文件的时长：第 0 季 / 没绑的文件，加上给基线用的正片文件。
  final Set<String> reviewPaths = <String>{
    for (final _WorkSpecials w in candidates)
      for (final String uid in <String>[...w.specials.keys, ...w.unbound])
        books[uid]!.videoPath,
  };
  final Set<String> wanted = <String>{
    ...reviewPaths,
    for (final _WorkSpecials w in candidates)
      for (final String uid in w.regularUids) books[uid]!.videoPath,
  };
  Map<String, VideoFileSpecRow> specs = await db.videoFileSpecsByPath(wanted);
  if (probe != null) {
    final List<String> missing = <String>[
      for (final String path in reviewPaths)
        if (specs[path]?.durationMs == null) path,
    ]..sort();
    if (missing.isNotEmpty) {
      await probe(missing);
      specs = await db.videoFileSpecsByPath(wanted);
    }
  }
  int? minutesOf(String uid) {
    final int? ms = specs[books[uid]!.videoPath]?.durationMs;
    return ms == null ? null : (ms / 60000).round();
  }

  final List<VideoPlacementFinding> findings = <VideoPlacementFinding>[];
  final List<VideoPlacementReview> reviews = <VideoPlacementReview>[];
  int unknown = 0;
  for (final _WorkSpecials w in candidates) {
    final int? baseline =
        _median(<int>[
          for (final String uid in w.regularUids) ?minutesOf(uid),
        ]) ??
        _median(w.scrapedRuntimes);
    final int? collectionId = w.work.collectionId;
    final String workId = collectionId == null
        ? 'book:${w.work.bookUid}'
        : 'collection:$collectionId';
    final List<String> specialUids = w.specials.keys.toList()..sort();
    reviews.add(
      VideoPlacementReview(
        workId: workId,
        title: w.work.title,
        originalTitle: w.work.originalTitle,
        year: w.work.year,
        regularLocalFiles: w.regularUids.length,
        regularSeasons: w.regularSeasons,
        baselineMinutes: baseline,
        files: <VideoPlacementReviewFile>[
          for (final String uid in specialUids)
            VideoPlacementReviewFile(
              bookUid: uid,
              title: books[uid]!.title,
              videoPath: books[uid]!.videoPath,
              slot: _slot(0, w.specials[uid]!.episodeNumber),
              minutes: minutesOf(uid),
              episodeTitle: w.specials[uid]!.title,
              episodeMinutes: w.specials[uid]!.runtimeMinutes,
            ),
          for (final String uid in w.unbound)
            VideoPlacementReviewFile(
              bookUid: uid,
              title: books[uid]!.title,
              videoPath: books[uid]!.videoPath,
              minutes: minutesOf(uid),
            ),
        ],
      ),
    );

    final List<String> flagged = <String>[];
    for (final String uid in specialUids) {
      final int? m = minutesOf(uid);
      if (m == null) {
        unknown++;
      } else if (m >= kFeatureMinMinutes &&
          (baseline == null || m >= baseline * kFeatureBaselineFactor)) {
        flagged.add(uid);
      }
    }
    if (flagged.isEmpty) continue;
    final VideoPlacementKind kind = collectionId == null
        ? VideoPlacementKind.movieAsSeries
        // 拆完之后合集里还得剩下「那部剧」：有本机正片文件才算个别错放。
        : w.regularUids.isNotEmpty
        ? VideoPlacementKind.featureInSpecials
        : VideoPlacementKind.featuresOnlyWork;
    for (final String uid in flagged) {
      findings.add(
        VideoPlacementFinding(
          kind: kind,
          workId: workId,
          workTitle: w.work.title,
          bookUid: uid,
          fileTitle: books[uid]!.title,
          slot: _slot(0, w.specials[uid]!.episodeNumber),
          durationMinutes: minutesOf(uid)!,
          baselineMinutes: baseline,
        ),
      );
    }
  }
  return VideoPlacementAudit(
    findings: findings,
    reviews: reviews,
    unknownDuration: unknown,
  );
}
