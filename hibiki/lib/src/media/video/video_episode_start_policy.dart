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
