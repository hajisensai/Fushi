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

/// 审计全库（确定性顺序：按作品 id、文件 uid）。
Future<List<VideoPlacementFinding>> auditVideoPlacement(
  FushiDatabase db,
) async {
  final Map<String, VideoBookRow> books = <String, VideoBookRow>{
    for (final VideoBookRow row in await db.allVideoBooks()) row.bookUid: row,
  };
  final Map<String, VideoFileSpecRow> specs = await db.videoFileSpecsByPath(
    books.values.map((VideoBookRow row) => row.videoPath),
  );
  int? minutesOf(String uid) {
    final VideoBookRow? book = books[uid];
    final int? ms = book == null ? null : specs[book.videoPath]?.durationMs;
    return ms == null ? null : (ms / 60000).round();
  }

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

  final List<VideoPlacementFinding> findings = <VideoPlacementFinding>[];
  final List<VideoMetadataWorkRow> works = await db.getAllVideoMetadataWorks()
    ..sort((VideoMetadataWorkRow a, VideoMetadataWorkRow b) => a.id - b.id);
  for (final VideoMetadataWorkRow work in works) {
    if (work.mediaType != 'tv') continue;
    // uid → 它绑到的第 0 季集位；绑到过正片季的 uid 不算（多集文件）。
    final Map<String, String> specials = <String, String>{};
    final Set<String> regularUids = <String>{};
    final List<int> scrapedRuntimes = <int>[];
    for (final VideoMetadataSeasonRow season
        in seasonsByWork[work.id] ?? const <VideoMetadataSeasonRow>[]) {
      for (final VideoMetadataEpisodeRow e
          in episodesBySeason[season.id] ?? const <VideoMetadataEpisodeRow>[]) {
        if (season.seasonNumber != 0 && e.runtimeMinutes != null) {
          scrapedRuntimes.add(e.runtimeMinutes!);
        }
        final String? uid = e.bookUid;
        if (uid == null || !books.containsKey(uid)) continue;
        if (season.seasonNumber == 0) {
          specials.putIfAbsent(uid, () => _slot(0, e.episodeNumber));
        } else {
          regularUids.add(uid);
        }
      }
    }
    specials.removeWhere((String uid, String _) => regularUids.contains(uid));
    if (specials.isEmpty) continue;
    final int? baseline =
        _median(<int>[for (final String uid in regularUids) ?minutesOf(uid)]) ??
        _median(scrapedRuntimes);
    final List<String> flagged = <String>[
      for (final String uid in specials.keys.toList()..sort())
        if (minutesOf(uid) case final int m
            when m >= kFeatureMinMinutes &&
                (baseline == null || m >= baseline * kFeatureBaselineFactor))
          uid,
    ];
    if (flagged.isEmpty) continue;
    final int? collectionId = work.collectionId;
    final VideoPlacementKind kind;
    final String workId;
    if (collectionId == null) {
      kind = VideoPlacementKind.movieAsSeries;
      workId = 'book:${work.bookUid}';
    } else {
      workId = 'collection:$collectionId';
      // 拆完之后合集里还得剩下「那部剧」：有本机正片文件才算个别错放。
      kind = regularUids.isNotEmpty
          ? VideoPlacementKind.featureInSpecials
          : VideoPlacementKind.featuresOnlyWork;
    }
    for (final String uid in flagged) {
      findings.add(
        VideoPlacementFinding(
          kind: kind,
          workId: workId,
          workTitle: work.title,
          bookUid: uid,
          fileTitle: books[uid]!.title,
          slot: specials[uid]!,
          durationMinutes: minutesOf(uid)!,
          baselineMinutes: baseline,
        ),
      );
    }
  }
  return findings;
}
