/// 音乐逐曲断点续播（反馈 QAondMh4M5：广播剧 CD 迁进音乐库后不能丢续播）：纯判定。
///
/// 三层，各管一件事：
/// * **存**：`music_resume_points`（fushi_core Drift，与播放流 `music_play_events` 同一
///   身份 trackUid）。写入时机由 `MusicSession` 管（节流 / 换曲结算 / 暂停 / 退出写穿）。
/// * **定起点**：直接复用视频的续播意图分类 [EpisodeStartIntent] 与
///   [resolveEpisodeStart]（BUG-3491：「选条目」与「定起点」共用一套判据）——列表点开 /
///   「下一首」续播，「上一首」/ 自动连播从头；片尾区比例用纯音频的
///   [kAudioStartNearEndProgress]。
/// * **门**：[MusicResumeMode]——默认只给长曲目续播（歌曲每次从头放才是常识）。
///
/// 不支持续播的来源：Apple Music（MusicKit 不能从曲内某处起播，能力表 `startAt: false`）、
/// Apple Music 电台 / 自管队列。服务器转码流如果不可 seek，mpv 的 `start` 落不了地，
/// 引擎的恢复守护在实际播放推进后放弃守护、照实记新位置（见 `MusicPlayerEngine`）。
library;

import 'package:fushi/src/media/video/video_episode_start_policy.dart';

/// 续播模式（偏好 `music_resume_mode`，wire 值冻结）。
enum MusicResumeMode {
  /// 一律从头放。
  off('off'),

  /// 只给长曲目（≥ [kMusicResumeMinTrack]，或时长未知）续播。
  longTracks('long_tracks'),

  /// 每首都续播。
  all('all');

  const MusicResumeMode(this.wire);

  final String wire;

  /// wire 值 → 模式；不认识的回到默认 [longTracks]。
  static MusicResumeMode fromWire(String? wire) {
    for (final MusicResumeMode m in values) {
      if (m.wire == wire) return m;
    }
    return longTracks;
  }
}

/// [MusicResumeMode.longTracks] 的长曲目门槛：歌曲很少到 8 分钟，广播剧 / 有声 CD 的轨
/// 大多超过。
const Duration kMusicResumeMinTrack = Duration(minutes: 8);

/// 这首曲目在 [mode] 下记不记、用不用断点。[durationMs] 未知（服务器流还没报时长）按长
/// 曲目算：宁可多记一行，不让一集广播剧丢进度。
bool musicResumeApplies({
  required MusicResumeMode mode,
  required int? durationMs,
}) => switch (mode) {
  MusicResumeMode.off => false,
  MusicResumeMode.all => true,
  MusicResumeMode.longTracks =>
    durationMs == null ||
        durationMs <= 0 ||
        durationMs >= kMusicResumeMinTrack.inMilliseconds,
};

/// 打开一首曲目从哪儿开始放。[savedPositionMs] 为 null = 没有断点。门不过、没断点、
/// 意图要求从头、或断点已在片尾区 → [Duration.zero]。
Duration resolveMusicResumeStart({
  required MusicResumeMode mode,
  required EpisodeStartIntent intent,
  required int? savedPositionMs,
  required int? durationMs,
}) {
  if (savedPositionMs == null) return Duration.zero;
  if (!musicResumeApplies(mode: mode, durationMs: durationMs)) {
    return Duration.zero;
  }
  return Duration(
    milliseconds: resolveEpisodeStart(
      intent,
      savedPositionMs,
      durationMs,
      nearEndProgress: kAudioStartNearEndProgress,
    ),
  );
}

/// 写入侧：这个位置该删行而不是写行——回到了开头（≤ 0），或已在片尾区（与读取侧
/// [resolveMusicResumeStart] 同一个 [isEpisodePositionNearEnd] 判据：读的时候会从头放
/// 的位置，存着也没用）。
bool musicResumePointIsFinished({
  required int positionMs,
  required int? durationMs,
}) =>
    positionMs <= 0 ||
    isEpisodePositionNearEnd(
      savedMs: positionMs,
      durationMs: durationMs,
      nearEndProgress: kAudioStartNearEndProgress,
    );

/// 列表 / 详情显示用：这首有没有「没听完」的断点（与读取侧同一判据：会被续播的才算）。
bool musicResumePointShown({
  required int positionMs,
  required int? durationMs,
}) =>
    !musicResumePointIsFinished(positionMs: positionMs, durationMs: durationMs);
