/// "Has this episode been watched to the end?" — one rule for the whole app.
///
/// Playback no longer writes `video_books.completed_at` (BUG-3491: the owner
/// decided playback must not tick episodes), so "watched" is now either the
/// manual mark or a saved position in the end zone of a known duration. The
/// player (start from 0 or resume), collection continue / counts, and media
/// tracking catch-up (BUG-4401) all read this one function; they must never
/// disagree about whether an episode is finished.
library;

const double kEpisodeStartNearEndProgress = 0.9;
const int kEpisodeStartNearEndRemainingMs = 3000;

/// 断点是否已到片尾区（≥ [kEpisodeStartNearEndProgress] 或只剩
/// [kEpisodeStartNearEndRemainingMs]）：打开时从头放、合集续播视作「这一集已经
/// 看完了」的同一个判据（BUG-3491：续播三层的「选条目」与「定起点」共用它，
/// 不能一层说「停在这集」另一层却从头放）。时长未知 / 断点为 0 → false。
/// [nearEndProgress]：片尾区比例，视频用缺省值，纯音频传更靠后的比例。
bool isEpisodePositionNearEnd({
  required int savedMs,
  required int? durationMs,
  double nearEndProgress = kEpisodeStartNearEndProgress,
}) {
  if (savedMs <= 0 || durationMs == null || durationMs <= 0) {
    return false;
  }
  final double progress = savedMs / durationMs;
  final int remainingMs = durationMs - savedMs;
  return progress >= nearEndProgress ||
      remainingMs <= kEpisodeStartNearEndRemainingMs;
}
