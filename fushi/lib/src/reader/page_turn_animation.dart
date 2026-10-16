/// 小说阅读器与漫画阅读器共用的翻页动画值域（效果 / 速度 / 降级规则）。
///
/// 两个阅读器各自落盘（漫画沿用 `manga_page_animation`，小说用 reader_settings
/// 里的 `page_turn_animation`），但**值域与降级规则只在这里写一次**：同一个
/// 「覆盖」在两边必须是同一个持久化字符串、同一档速度必须是同一个毫秒数，
/// 墨水屏 / 系统减弱动态效果的降级也不能两边各写一套。
///
/// 时长不另立常量：三档速度直接取 [FushiMotion] token（墨水屏 / 系统「减弱动态
/// 效果」的归零经 [effectivePageTurnAnimation] 降成 [PageTurnAnimation.none]，与
/// [fushiMotionEnabled] 同一判据）。
library;

import 'package:material_ui/material_ui.dart' show BuildContext;

import 'package:fushi/src/utils/components/fushi_motion_tokens.dart';

/// 翻页动画效果。存字符串 [key] 而非 index：重排枚举不得破坏已落盘的偏好。
enum PageTurnAnimation {
  none('none'),
  slide('slide'),
  cover('cover'),
  fade('fade');

  const PageTurnAnimation(this.key);

  /// 持久化 / 传给 JS 的字符串。
  final String key;

  /// 解析落盘值；未知值回落 [fallback]（两个阅读器的默认值不同）。
  static PageTurnAnimation fromKey(
    String? raw, {
    required PageTurnAnimation fallback,
  }) {
    for (final PageTurnAnimation value in PageTurnAnimation.values) {
      if (value.key == raw) return value;
    }
    return fallback;
  }

  /// 是否是有位移的效果（只有这两种能做「拖动跟手」）。
  bool get isDirectional =>
      this == PageTurnAnimation.slide || this == PageTurnAnimation.cover;
}

/// 翻页动画速度三档，时长一律取 [FushiMotion] token（不在阅读器另立毫秒常量）：
///
/// - 快 = [FushiMotion.short]（effects default 弹簧落定时长 ≈ 165ms）；
/// - 正常 = [FushiMotion.longReverse]（effects slow ≈ 235ms）；
/// - 慢 = [FushiMotion.medium]（spatial default ≈ 325ms）。
///
/// 降级（墨水屏 / 减弱动态效果）不在这里归零：那时效果本身降成
/// [PageTurnAnimation.none]，两个阅读器的 JS 在效果为无时完全不读时长。
enum PageTurnAnimationSpeed {
  fast('fast', FushiMotion.short),
  normal('normal', FushiMotion.longReverse),
  slow('slow', FushiMotion.medium);

  const PageTurnAnimationSpeed(this.key, this.duration);

  final String key;

  /// 一次完整翻页动画的时长（[FushiMotion] token）。
  final Duration duration;

  /// 传给 JS 的毫秒数（由 [duration] 派生）。
  int get durationMs => duration.inMilliseconds;

  static PageTurnAnimationSpeed fromKey(String? raw) {
    for (final PageTurnAnimationSpeed value in PageTurnAnimationSpeed.values) {
      if (value.key == raw) return value;
    }
    return PageTurnAnimationSpeed.normal;
  }
}

/// 把用户选的效果按环境降级成实际播放的效果。
///
/// [motionEnabled] 由调用方按 [fushiMotionEnabled]（墨水屏主题 + 系统「减弱动态
/// 效果」）与阅读器自身的墨水屏开关合成。为 false 时**一律**
/// [PageTurnAnimation.none]（动效时长归零，CLAUDE.md 动效硬规则）——淡入同样是动画，
/// 不得作为减弱动态效果下的「替代动效」。
PageTurnAnimation effectivePageTurnAnimation(
  PageTurnAnimation selected, {
  required bool motionEnabled,
}) {
  if (!motionEnabled) return PageTurnAnimation.none;
  return selected;
}

/// 两个阅读器共用的「翻页动效是否可播」判据：阅读器自身的墨水屏开关 [eink] +
/// [fushiMotionEnabled]（墨水屏主题 / 系统「减弱动态效果」）。结果喂给
/// [effectivePageTurnAnimation] 的 `motionEnabled`。
bool pageTurnMotionEnabledOf(BuildContext context, {required bool eink}) =>
    !eink && fushiMotionEnabled(context);

/// 跳过多少页以上不再播动画（目录 / 进度条 / 书签等长距离跳转一律瞬时）。
const int kPageTurnAnimationMaxAnimatedDistance = 1;

/// 「拖动跟手」松手提交翻页的位移阈值（占视口宽度的比例）。
const double kPageTurnFollowCommitFraction = 0.25;

/// 「拖动跟手」松手提交翻页的甩动速度阈值（逻辑像素 / 毫秒）。
const double kPageTurnFollowFlingVelocity = 0.6;
