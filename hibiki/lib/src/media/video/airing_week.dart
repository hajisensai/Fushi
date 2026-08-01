import 'package:hibiki/src/media/video/anilist_client.dart';

/// 放送日历的周窗口/时区纯函数（TODO-2487）。全部无 IO、无状态，单测在
/// `test/media/video/airing_week_test.dart`。

/// AniList airingAt（Unix epoch 秒）→ 本地时刻。
DateTime airingAtToLocal(int airingAtSeconds) =>
    DateTime.fromMillisecondsSinceEpoch(airingAtSeconds * 1000).toLocal();

/// [local] 所在自然周的周一 00:00（本地时区）。日减法走 DateTime 构造器的
/// 组件归一化而不是 `subtract(Duration)`——跨 DST 边界减 Duration 会把
/// 00:00 漂成 23:00/01:00。
DateTime localWeekStart(DateTime local) =>
    DateTime(local.year, local.month, local.day - (local.weekday - 1));

/// 本地日期差（b - a，忽略时分秒）。DST 安全：把两端日期组件搬到 UTC 再取
/// 整天差，避免本地 Duration 差在 23/25 小时的日子上取整错位。
int daysBetweenLocalDates(DateTime a, DateTime b) =>
    DateTime.utc(b.year, b.month, b.day)
        .difference(DateTime.utc(a.year, a.month, a.day))
        .inDays;

/// 把一批放送条目按**本地**星期几分进 7 个桶（0=周一 … 6=周日），桶内按放送
/// 时刻升序；落在 [weekStartLocal] 起 7 天窗口外的条目丢弃（服务端窗口按 UTC
/// 秒裁过，本地换算后仍可能溢出到相邻周）。
List<List<AniListAiringEpisode>> groupEpisodesByLocalWeekday({
  required List<AniListAiringEpisode> episodes,
  required DateTime weekStartLocal,
}) {
  final List<List<AniListAiringEpisode>> buckets =
      List<List<AniListAiringEpisode>>.generate(
    7,
    (_) => <AniListAiringEpisode>[],
  );
  for (final AniListAiringEpisode episode in episodes) {
    final DateTime local = airingAtToLocal(episode.airingAtSeconds);
    final int index = daysBetweenLocalDates(weekStartLocal, local);
    if (index < 0 || index > 6) continue;
    buckets[index].add(episode);
  }
  for (final List<AniListAiringEpisode> bucket in buckets) {
    bucket.sort((AniListAiringEpisode a, AniListAiringEpisode b) =>
        a.airingAtSeconds.compareTo(b.airingAtSeconds));
  }
  return buckets;
}
