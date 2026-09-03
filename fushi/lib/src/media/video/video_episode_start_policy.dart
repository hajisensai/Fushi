import 'package:meta/meta.dart';

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

/// 本地换集时对路由栈的处置方式（BUG-839 / BUG-2043，纯决策）。
enum EpisodeSwitchMode {
  /// 窗口模式：`pushReplacement` 顶替本页，栈平、行为与历史一致。
  replace,

  /// 全屏模式：`push` 新页压在全屏路由之上，再 `removeRoute` 静默摘掉
  /// 旧全屏路由与本页（不经 pop → 不触发原生退全屏）。
  takeover,
}

/// [resolveEpisodeSwitchPlan] 的结果：栈处置方式 + 是否把原生全屏交给新页。
@immutable
class EpisodeSwitchPlan {
  const EpisodeSwitchPlan({
    required this.mode,
    required this.handOverNativeFullscreen,
  });

  /// 路由栈处置方式。
  final EpisodeSwitchMode mode;

  /// 新页 `initialFullscreen`：换集前处于全屏就必须为真，新页才会认领接管来的
  /// 原生全屏并在就绪后压自己的全屏路由。
  final bool handOverNativeFullscreen;

  @override
  bool operator ==(Object other) =>
      other is EpisodeSwitchPlan &&
      other.mode == mode &&
      other.handOverNativeFullscreen == handOverNativeFullscreen;

  @override
  int get hashCode => Object.hash(mode, handOverNativeFullscreen);

  @override
  String toString() =>
      'EpisodeSwitchPlan(mode: $mode, handOverNativeFullscreen: '
      '$handOverNativeFullscreen)';
}

/// 本地换集的路由决策（BUG-2043，纯函数）。
///
/// 「换集前是否全屏」有两个来源，缺一不可：
///   * [fullscreenRouteActive]：本页自己压的全屏路由还在栈上；
///   * [ownsHandedOverNativeFullscreen]：本页是上一次换集接管来的原生全屏的持有者，
///     但自己的全屏路由还没压上（就绪窗口内连按下一集就落在这个态）。只看路由会把
///     它误判成窗口模式 → 走 `pushReplacement` → 原生全屏没人收口，窗口停在无全屏
///     路由的原生全屏态。
///
/// [hasCurrentRoute] 为假（拿不到本页 `ModalRoute`）时无法 `removeRoute` 摘掉本页，
/// 接管路径会漏栈，只能退回 [EpisodeSwitchMode.replace]；此时仍把全屏态传给新页。
///
/// 决策抽成纯函数是为了让真值表可在 headless 环境单测——行为级复现需要 media_kit +
/// 真 navigator 栈 + 原生全屏，跑不了；纯源码守卫又证明不了语句可达。
EpisodeSwitchPlan resolveEpisodeSwitchPlan({
  required bool fullscreenRouteActive,
  required bool ownsHandedOverNativeFullscreen,
  required bool hasCurrentRoute,
}) {
  final bool wasFullscreen =
      fullscreenRouteActive || ownsHandedOverNativeFullscreen;
  return EpisodeSwitchPlan(
    mode: wasFullscreen && hasCurrentRoute
        ? EpisodeSwitchMode.takeover
        : EpisodeSwitchMode.replace,
    handOverNativeFullscreen: wasFullscreen,
  );
}
