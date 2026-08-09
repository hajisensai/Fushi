import 'package:fushi/src/media/video/cover_ui/cover_aspect_probe.dart';

/// 视频首页（hayase 式改版，TODO-2486）的布局与筛选纯函数。
///
/// 页面几何真相源：横滚行与媒体库墙的卡片**高度统一、宽度随封面朝向**——
/// 竖版 2:3、横版 16:9。朝向判定与 PortraitCoverImage / LandscapeCoverImage
/// 共用同一阈值 [kCoverLandscapeAspectThreshold]（TODO-2426 真相源），不另造。
/// 全部无副作用，单测在 `test/media/video/video_home_layout_test.dart`。
enum VideoCardOrientation {
  /// 竖版卡（2:3 海报）。朝向未知（无封面 / 首帧未解码 / 远端）默认此值。
  portrait,

  /// 横版卡（16:9 截帧 / backdrop）。
  landscape,
}

/// 竖版卡封面宽高比（主库墙沿用 Kazumi 式 2:3 海报）。
const double kVideoPortraitCardAspect = 2 / 3;

/// 横版卡封面宽高比（16:9 截帧/backdrop）。
const double kVideoLandscapeCardAspect = 16 / 9;

/// 「最近添加」行/角标的入库时间窗。
const Duration kVideoRecentlyAddedWindow = Duration(days: 14);

/// 由封面固有宽高比判定卡片朝向。
///
/// [aspect] 为 null（首帧未解码 / 无封面 / 远端未知）时**默认竖卡**（拍板：
/// 朝向未知时默认竖卡），阈值走 [kCoverLandscapeAspectThreshold]（≥1.2 算横图），
/// 绝不另写一份。
VideoCardOrientation videoCardOrientationForAspect(double? aspect) {
  if (aspect == null) return VideoCardOrientation.portrait;
  return aspect >= kCoverLandscapeAspectThreshold
      ? VideoCardOrientation.landscape
      : VideoCardOrientation.portrait;
}

/// 统一封面高下的卡宽：竖卡 2:3、横卡 16:9，高度同源故底边天然对齐。
double videoCardWidthForOrientation({
  required VideoCardOrientation orientation,
  required double coverHeight,
}) =>
    coverHeight *
    (orientation == VideoCardOrientation.landscape
        ? kVideoLandscapeCardAspect
        : kVideoPortraitCardAspect);

/// 库墙/横滚行的封面高：以「竖卡目标宽」换算（竖卡 2:3 → 高 = 宽 × 3/2），
/// 墙内竖卡与旧网格卡同宽感受、横卡只在宽度上伸展。
double videoCoverHeightForPortraitWidth(double portraitCardWidth) =>
    portraitCardWidth * 3 / 2;

/// 全宽 hero 轮播高度：宽屏压成 21:9 影院比例，夹在 [220, 420] 之间——手机竖屏
/// 不至于占满半屏，桌面超宽不至于无限长高。
double videoHeroHeightForWidth(double width) =>
    (width * 9 / 21).clamp(220.0, 420.0);

/// 刮削 airDate（TMDB `YYYY-MM-DD` 或裸年份 `YYYY`）→ 年份；解析不出返回
/// null（归「未知」桶，条目在年份筛选下不消失）。
int? videoAirYear(String? airDate) {
  if (airDate == null) return null;
  final RegExpMatch? m = RegExp(r'^(\d{4})').firstMatch(airDate.trim());
  if (m == null) return null;
  final int year = int.parse(m.group(1)!);
  // 1900 以前当脏数据，不当有效年份。
  return year >= 1900 ? year : null;
}

/// airDate 月份 → 季度序号（1=冬 1-3 月、2=春 4-6、3=夏 7-9、4=秋 10-12，
/// 对齐番剧季度习惯）；无月份信息返回 null（hero 只显年份）。
int? videoAirSeasonQuarter(String? airDate) {
  if (airDate == null) return null;
  final RegExpMatch? m = RegExp(r'^\d{4}-(\d{2})').firstMatch(airDate.trim());
  if (m == null) return null;
  final int month = int.parse(m.group(1)!);
  if (month < 1 || month > 12) return null;
  return (month - 1) ~/ 3 + 1;
}

/// 年份筛选三态：全部 / 指定年份 / 未知（无刮削资料）。
///
/// 数据结构消掉特例：`year == null && unknownOnly == false` 即「全部」，
/// 不需要独立的 all 标志位。
class VideoYearFilter {
  const VideoYearFilter.all()
      : year = null,
        unknownOnly = false;

  const VideoYearFilter.unknown()
      : year = null,
        unknownOnly = true;

  const VideoYearFilter.year(int this.year) : unknownOnly = false;

  /// 指定年份；null = 全部或未知（看 [unknownOnly]）。
  final int? year;

  /// 只看「无刮削年份」的条目。
  final bool unknownOnly;

  bool get isAll => year == null && !unknownOnly;

  /// [entryYear] = 条目刮削年份（无资料 = null）。
  bool matches(int? entryYear) {
    if (isAll) return true;
    if (unknownOnly) return entryYear == null;
    return entryYear == year;
  }

  @override
  bool operator ==(Object other) =>
      other is VideoYearFilter &&
      other.year == year &&
      other.unknownOnly == unknownOnly;

  @override
  int get hashCode => Object.hash(year, unknownOnly);
}

/// 看完状态筛选档位。
enum VideoWatchStatusFilter { all, unwatched, watching, completed }

/// A series member's playback facts in the collection's stable episode order.
class VideoSeriesPlaybackState {
  const VideoSeriesPlaybackState({
    required this.lastWatchedAtMs,
    required this.positionMs,
    required this.completed,
  });

  final int lastWatchedAtMs;
  final int positionMs;
  final bool completed;

  bool get hasTrace => lastWatchedAtMs > 0 || positionMs > 0 || completed;
}

/// Returns the episode the user actually played most recently.
///
/// This deliberately does not mean "the furthest episode". A user may go back
/// to episode 3 after reaching episode 12; Continue Watching must resume 3.
/// Legacy rows without a watch timestamp fall back to the last traced member in
/// stable episode order.
int? latestPlayedSeriesIndex(List<VideoSeriesPlaybackState> members) {
  int? bestIndex;
  int bestWatchedAt = 0;
  for (int index = 0; index < members.length; index++) {
    final VideoSeriesPlaybackState member = members[index];
    if (!member.hasTrace) continue;
    if (member.lastWatchedAtMs >= bestWatchedAt) {
      bestWatchedAt = member.lastWatchedAtMs;
      bestIndex = index;
    }
  }
  return bestIndex;
}

/// The Next Episode target is always the member immediately after the episode
/// returned by [latestPlayedSeriesIndex].
int? nextEpisodeAfterLatestPlayed(
  List<VideoSeriesPlaybackState> members,
) {
  final int? current = latestPlayedSeriesIndex(members);
  if (current == null || current + 1 >= members.length) return null;
  return current + 1;
}

/// 条目级看完状态判定（本地即筛）：
/// * completed —— `completedAt` 非空；
/// * watching —— 未完成但有播放痕迹（`lastPositionMs > 0`）；
/// * unwatched —— 两者皆无。
bool matchesVideoWatchStatus({
  required VideoWatchStatusFilter filter,
  required bool completed,
  required int lastPositionMs,
}) {
  switch (filter) {
    case VideoWatchStatusFilter.all:
      return true;
    case VideoWatchStatusFilter.completed:
      return completed;
    case VideoWatchStatusFilter.watching:
      return !completed && lastPositionMs > 0;
    case VideoWatchStatusFilter.unwatched:
      return !completed && lastPositionMs <= 0;
  }
}

/// 「最近添加」窗口判定：入库时刻在 [now] 往前 [kVideoRecentlyAddedWindow] 内。
/// [importedAt] 毫秒时刻；null / 非正值（远端占位无入库时刻）不算。
bool isVideoRecentlyAdded({required int? importedAt, required DateTime now}) {
  if (importedAt == null || importedAt <= 0) return false;
  final DateTime at = DateTime.fromMillisecondsSinceEpoch(importedAt);
  return !at.isAfter(now) && now.difference(at) <= kVideoRecentlyAddedWindow;
}

/// hero 轮播候选单元的选取输入。
///
/// [unit] 是调用方的单元载荷——合集**或**散装单视频（v68 起：hero 不再是
/// 合集专属粒度。用户最后看的是散装条目时，合集门槛会让置顶不是它，见
/// PR#712 跟进）。本函数只看三个排序事实，对单元种类无感知。
class VideoHeroCandidate<T> {
  const VideoHeroCandidate({
    required this.unit,
    this.lastWatchedAt,
    this.latestImportedAt = 0,
    this.hasUnfinishedTrace = false,
  });

  final T unit;

  /// 单元最近观看时刻（合集取成员 max；无痕迹 = null）。
  final DateTime? lastWatchedAt;

  /// 单元最近入库时刻毫秒（合集取成员 max；回落排序用）。
  final int latestImportedAt;

  /// 有观看痕迹且未看完（=「在看」；合集 = 有痕迹且未整套看完）。
  final bool hasUnfinishedTrace;
}

/// hero 轮播内容选取：最近在看的前 [limit] 个单元（合集与散装混排，同一
/// 「最近观看倒序」——置顶恒为用户最后在看的那个东西）；一个在看的都没有时
/// 回落「最近添加」（按最近入库时刻倒序）。返回单元有序列表。
List<T> selectVideoHeroUnits<T>(
  List<VideoHeroCandidate<T>> candidates, {
  int limit = 5,
}) {
  final List<VideoHeroCandidate<T>> watching = <VideoHeroCandidate<T>>[
    for (final VideoHeroCandidate<T> c in candidates)
      if (c.hasUnfinishedTrace && c.lastWatchedAt != null) c,
  ]..sort((VideoHeroCandidate<T> a, VideoHeroCandidate<T> b) =>
      b.lastWatchedAt!.compareTo(a.lastWatchedAt!));
  final List<VideoHeroCandidate<T>> pool = watching.isNotEmpty
      ? watching
      : (List<VideoHeroCandidate<T>>.of(candidates)
        ..sort((VideoHeroCandidate<T> a, VideoHeroCandidate<T> b) =>
            b.latestImportedAt.compareTo(a.latestImportedAt)));
  return <T>[
    for (final VideoHeroCandidate<T> c in pool.take(limit)) c.unit,
  ];
}
