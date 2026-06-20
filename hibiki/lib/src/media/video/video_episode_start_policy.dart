enum EpisodeStartIntent {
  initialOpen,
  manualPrevious,
  manualNext,
  listSelect,
  autoAdvance,
  explicitCue,
}

const double kEpisodeStartNearEndProgress = 0.9;
const int kEpisodeStartNearEndRemainingMs = 3000;

int resolveEpisodeStart(
  EpisodeStartIntent intent,
  int savedPositionMs,
  int? durationMs,
) {
  final int savedMs = savedPositionMs < 0 ? 0 : savedPositionMs;

  switch (intent) {
    case EpisodeStartIntent.manualPrevious:
    case EpisodeStartIntent.autoAdvance:
      return 0;
    case EpisodeStartIntent.explicitCue:
      return savedMs;
    case EpisodeStartIntent.initialOpen:
    case EpisodeStartIntent.manualNext:
    case EpisodeStartIntent.listSelect:
      if (_isNearEnd(savedMs: savedMs, durationMs: durationMs)) {
        return 0;
      }
      return savedMs;
  }
}

bool _isNearEnd({required int savedMs, required int? durationMs}) {
  if (savedMs <= 0 || durationMs == null || durationMs <= 0) {
    return false;
  }
  final double progress = savedMs / durationMs;
  final int remainingMs = durationMs - savedMs;
  return progress >= kEpisodeStartNearEndProgress ||
      remainingMs <= kEpisodeStartNearEndRemainingMs;
}

/// 一集播完后的自动连播倒计时秒数（TODO-639）。倒计时期间画面显示「N 秒后播放下一集
/// · 取消」OSD，到时若用户没点取消就进下一集；点了取消就停在本集结束。
const int kAutoPlayNextCountdownSeconds = 5;

/// 一集播完（EOF）时是否应进入自动连播倒计时（TODO-639，纯决策）。
///
/// 三个独立门控全满足才连播：
///   1. [autoPlayNextEnabled]：用户的「自动连播」偏好开着（默认开）；
///   2. [hasNextEpisode]：存在下一集（[nextPlaylistIndexAfterCompletion] 非空，
///      即非单集、非最后一集）；
///   3. [alreadyAdvancing]：没有正在进行的换集（重入保护）。
///
/// 任一不满足都返回 false（停在本集结束、不弹倒计时）。把决策抽成纯函数，让
/// 「开关关→不连播 / 开→连播」的行为可在 headless 环境单测（真实播放器跑不了）。
bool shouldAutoPlayNextOnCompletion({
  required bool autoPlayNextEnabled,
  required bool hasNextEpisode,
  required bool alreadyAdvancing,
}) {
  if (alreadyAdvancing) return false;
  if (!autoPlayNextEnabled) return false;
  return hasNextEpisode;
}
