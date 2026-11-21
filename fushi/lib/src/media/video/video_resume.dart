/// 视频断点续播开关（拍板台 IVRHvZ3pmd，QQ 群反馈「视频总是自动续播、关不掉」）：纯判定。
///
/// 与音乐的 `music_resume.dart` 同一套三档门，只管「打开时用不用断点」：
/// * **存**不受影响：`lastPositionMs` / 远端进度键照常写——进度条、「看到」标签、互联
///   同步都读它（PR #3074）。
/// * **门**只拦按断点定起点的意图（[EpisodeStartIntent.initialOpen] / `manualNext` /
///   `listSelect`）；制卡回看、画质 / 音轨重载、遥控跳转走 `explicitCue`，起点是用户
///   明确要的位置，不受门影响；`manualPrevious` / `autoAdvance` 本来就从头。
/// * 门不过 → 从 0 开始；门过了照旧走 [resolveEpisodeStart]（片尾区从头）。
library;

import 'package:fushi/src/media/video/video_episode_start_policy.dart';

/// 续播模式（偏好 `video_resume_mode`，wire 值冻结）。
enum VideoResumeMode {
  /// 一律从头放。
  off('off'),

  /// 只给长视频（≥ [kVideoResumeMinDuration]，或时长未知）续播。
  longVideos('long_videos'),

  /// 每个视频都续播（默认，与加开关前的行为一致）。
  all('all');

  const VideoResumeMode(this.wire);

  final String wire;

  /// wire 值 → 模式；不认识的回到默认 [all]。
  static VideoResumeMode fromWire(String? wire) {
    for (final VideoResumeMode m in values) {
      if (m.wire == wire) return m;
    }
    return all;
  }
}

/// [VideoResumeMode.longVideos] 的长视频门槛：MV / 预告 / 短片大多在 10 分钟内，
/// 一集动画 / 剧集 / 电影都超过。
const Duration kVideoResumeMinDuration = Duration(minutes: 10);

/// 这个视频在 [mode] 下打开时用不用断点。[durationMs] 未知（打开前、远端流还没报时长）
/// 按长视频算：打开后控制器按真实时长再判一次，短视频会被拉回开头。
bool videoResumeApplies({
  required VideoResumeMode mode,
  required int? durationMs,
}) => switch (mode) {
  VideoResumeMode.off => false,
  VideoResumeMode.all => true,
  VideoResumeMode.longVideos =>
    durationMs == null ||
        durationMs <= 0 ||
        durationMs >= kVideoResumeMinDuration.inMilliseconds,
};

/// [intent] 的起点是不是取自存下的断点（续播门只管这些）。
bool episodeStartIntentUsesSavedPosition(EpisodeStartIntent intent) =>
    switch (intent) {
      EpisodeStartIntent.initialOpen ||
      EpisodeStartIntent.manualNext ||
      EpisodeStartIntent.listSelect => true,
      EpisodeStartIntent.manualPrevious ||
      EpisodeStartIntent.autoAdvance ||
      EpisodeStartIntent.explicitCue => false,
    };

/// 视频打开时的起点（毫秒）：续播门 + [resolveEpisodeStart]。
int resolveVideoStart({
  required EpisodeStartIntent intent,
  required int savedPositionMs,
  required int? durationMs,
  required VideoResumeMode mode,
}) {
  if (episodeStartIntentUsesSavedPosition(intent) &&
      !videoResumeApplies(mode: mode, durationMs: durationMs)) {
    return 0;
  }
  return resolveEpisodeStart(intent, savedPositionMs, durationMs);
}
