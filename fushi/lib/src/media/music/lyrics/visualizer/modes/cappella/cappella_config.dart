/// 群唱（folia cappella）的常量与「动画强度」参数表（folia `cappellaConstants.ts` /
/// `cappellaIntensity.ts`）。时间一律毫秒，长度一律逻辑像素（folia 的 CSS px 1:1）。
library;

/// 「短句」字数上限：不超过这么多（去掉空白后）的句子可能沿用上一位发送者。
const int kCappellaShortLineCharLimit = 12;

/// 同屏最多几条消息。
const int kCappellaMaxVisibleMessages = 20;

/// 头像网格（封面切 3×3）。
const int kCappellaAvatarGridSize = 3;

/// 左侧发送者在 3×3 网格里依次取的格子。
const List<int> kCappellaLeftAvatarIndices = <int>[0, 3, 6, 1, 4];

/// 右侧（「我」）固定取右下角那格。
const int kCappellaRightAvatarIndex = 8;

/// 下一句提前多久开始预热气泡测量。
const int kCappellaPreheatMinLeadMs = 180;
const int kCappellaPreheatMaxLeadMs = 1100;

/// 气泡测量缓存上限（行）。
const int kCappellaLayoutCacheLimit = 32;

/// 气泡宽度比字提前这么久开始变（宽度补间约 200ms，避免临界换行时字掉到下一行）。
const int kCappellaWidthLookaheadMs = 200;

/// 气泡宽 / 高补间时长。
const double kCappellaBubbleSizeTweenSeconds = 0.2;

/// 间奏占位文字。
const String kCappellaInterludeText = '......';

/// 逐字淡入的默认 / 最短时长。
const int kCappellaDefaultCharFadeMs = 220;
const int kCappellaMinCharFadeMs = 40;

/// 间奏判定：两句之间空出超过这么久就插一条间奏消息（folia `attachInterludes`）。
const int kCappellaInterludeGapMs = 3000;

/// 头像边长。
const double kCappellaAvatarSize = 40;

/// 行间距 / 头像与气泡间距（Tailwind gap-3）。
const double kCappellaGap = 12;

/// 表情消息上方额外留白（pt-12）。
const double kCappellaEmoTopPadding = 48;

/// 气泡描边宽。
const double kCappellaBubbleBorder = 1;

/// 气泡大圆角（rounded-3xl）与尾巴角（rounded-md）。
const double kCappellaBubbleRadius = 24;
const double kCappellaBubbleTailRadius = 6;

/// 当前行气泡最小宽。
const double kCappellaActiveMinWidth = 72;

/// 行高倍数。
const double kCappellaLineHeight = 1.45;

/// 面板最大宽（max-w-4xl）。
const double kCappellaPanelMaxWidth = 896;

/// 底部给共享字幕 / 播放栏让出的高度与顶部留白的总和（folia `viewportHeight - 240`）。
const double kCappellaReservedHeight = 240;

/// 时间戳字号与不透明度。
const double kCappellaTimestampFontSize = 11;
const double kCappellaTimestampOpacity = 0.62;
const double kCappellaTimestampFadeSeconds = 0.18;

/// 头像出现淡入。
const double kCappellaAvatarFadeSeconds = 0.2;

/// 表情摇摆：±1.6°，1.9s 一个来回。
const double kCappellaEmoWiggleDegrees = 1.6;
const double kCappellaEmoWiggleSeconds = 1.9;

/// 动画强度（folia 主题的 `animationIntensity`；Fushi 没有 AI 主题，改成本样式的参数）。
enum CappellaIntensity {
  calm('calm'),
  normal('normal'),
  chaotic('chaotic');

  const CappellaIntensity(this.value);

  /// 落库值（冻结）。
  final String value;

  static CappellaIntensity fromValue(String value) {
    for (final CappellaIntensity i in values) {
      if (i.value == value) return i;
    }
    return normal;
  }
}

/// 弹簧参数（framer-motion 的 stiffness / damping / mass）。
class CappellaSpring {
  const CappellaSpring({
    required this.stiffness,
    required this.damping,
    required this.mass,
  });

  final double stiffness;
  final double damping;
  final double mass;
}

/// 消息编排参数。
class CappellaSequencing {
  const CappellaSequencing({
    required this.forceRightEveryLines,
    required this.shortLineCarryChance,
    required this.sideSequence,
    required this.sideFlipChance,
    required this.randomEmoChance,
    required this.minLinesBetweenRandomEmos,
    required this.maxRandomEmoRatio,
  });

  final int forceRightEveryLines;
  final double shortLineCarryChance;

  /// true = 右侧。
  final List<bool> sideSequence;
  final double sideFlipChance;
  final double randomEmoChance;
  final int minLinesBetweenRandomEmos;
  final double maxRandomEmoRatio;
}

/// 动效参数（秒 / 像素 / 倍数）。
class CappellaMotion {
  const CappellaMotion({
    required this.rowEnterY,
    required this.rowEnterScale,
    required this.rowEnterDuration,
    required this.rowExitY,
    required this.rowExitScale,
    required this.rowExitDuration,
    required this.avatarSpring,
    required this.activeScale,
    required this.passedScale,
    required this.passedOpacity,
    required this.activeFontMultiplier,
    required this.inactiveFontMultiplier,
    required this.activePaddingX,
    required this.activePaddingY,
    required this.inactivePaddingX,
    required this.inactivePaddingY,
    required this.activeMinHeight,
    required this.inactiveMinHeight,
    required this.glowOpacity,
    required this.glowDuration,
    required this.glowRightAlpha,
    required this.glowLeftAlpha,
    required this.activeShadowAlpha,
    required this.emoActiveSize,
    required this.emoInactiveSize,
    required this.emoEnterScale,
    required this.emoSizeTransitionDuration,
  });

  final double rowEnterY;
  final double rowEnterScale;
  final double rowEnterDuration;
  final double rowExitY;
  final double rowExitScale;
  final double rowExitDuration;
  final CappellaSpring avatarSpring;
  final double activeScale;
  final double passedScale;
  final double passedOpacity;
  final double activeFontMultiplier;
  final double inactiveFontMultiplier;
  final double activePaddingX;
  final double activePaddingY;
  final double inactivePaddingX;
  final double inactivePaddingY;
  final double activeMinHeight;
  final double inactiveMinHeight;
  final double glowOpacity;
  final double glowDuration;
  final double glowRightAlpha;
  final double glowLeftAlpha;
  final double activeShadowAlpha;
  final double emoActiveSize;
  final double emoInactiveSize;
  final double emoEnterScale;
  final double emoSizeTransitionDuration;
}

/// 一档强度的全部参数。
class CappellaIntensityConfig {
  const CappellaIntensityConfig({
    required this.sequencing,
    required this.motion,
  });

  final CappellaSequencing sequencing;
  final CappellaMotion motion;
}

const CappellaIntensityConfig _calm = CappellaIntensityConfig(
  sequencing: CappellaSequencing(
    forceRightEveryLines: 7,
    shortLineCarryChance: 0.92,
    sideSequence: <bool>[false, false, true, false, true],
    sideFlipChance: 0.08,
    randomEmoChance: 0,
    minLinesBetweenRandomEmos: 6,
    maxRandomEmoRatio: 0,
  ),
  motion: CappellaMotion(
    rowEnterY: 14,
    rowEnterScale: 0.992,
    rowEnterDuration: 0.28,
    rowExitY: -10,
    rowExitScale: 0.985,
    rowExitDuration: 0.22,
    avatarSpring: CappellaSpring(stiffness: 280, damping: 30, mass: 0.78),
    activeScale: 1.07,
    passedScale: 0.96,
    passedOpacity: 0.88,
    activeFontMultiplier: 1.22,
    inactiveFontMultiplier: 0.96,
    activePaddingX: 18,
    activePaddingY: 14,
    inactivePaddingX: 16,
    inactivePaddingY: 12,
    activeMinHeight: 58,
    inactiveMinHeight: 44,
    glowOpacity: 0.26,
    glowDuration: 2.2,
    glowRightAlpha: 0.26,
    glowLeftAlpha: 0.14,
    activeShadowAlpha: 0.24,
    emoActiveSize: 132,
    emoInactiveSize: 96,
    emoEnterScale: 0.74,
    emoSizeTransitionDuration: 0.22,
  ),
);

const CappellaIntensityConfig _normal = CappellaIntensityConfig(
  sequencing: CappellaSequencing(
    forceRightEveryLines: 5,
    shortLineCarryChance: 0.68,
    sideSequence: <bool>[false, true, false, true, true],
    sideFlipChance: 0.18,
    randomEmoChance: 0.1,
    minLinesBetweenRandomEmos: 3,
    maxRandomEmoRatio: 1 / 8,
  ),
  motion: CappellaMotion(
    rowEnterY: 22,
    rowEnterScale: 0.98,
    rowEnterDuration: 0.32,
    rowExitY: -18,
    rowExitScale: 0.965,
    rowExitDuration: 0.24,
    avatarSpring: CappellaSpring(stiffness: 340, damping: 28, mass: 0.72),
    activeScale: 1.12,
    passedScale: 0.92,
    passedOpacity: 0.82,
    activeFontMultiplier: 1.34,
    inactiveFontMultiplier: 0.94,
    activePaddingX: 20,
    activePaddingY: 16,
    inactivePaddingX: 16,
    inactivePaddingY: 12,
    activeMinHeight: 64,
    inactiveMinHeight: 44,
    glowOpacity: 0.4,
    glowDuration: 1.8,
    glowRightAlpha: 0.34,
    glowLeftAlpha: 0.18,
    activeShadowAlpha: 0.34,
    emoActiveSize: 160,
    emoInactiveSize: 110,
    emoEnterScale: 0.6,
    emoSizeTransitionDuration: 0.25,
  ),
);

const CappellaIntensityConfig _chaotic = CappellaIntensityConfig(
  sequencing: CappellaSequencing(
    forceRightEveryLines: 3,
    shortLineCarryChance: 0.36,
    sideSequence: <bool>[false, true, true, false, true, false],
    sideFlipChance: 0.42,
    randomEmoChance: 0.22,
    minLinesBetweenRandomEmos: 2,
    maxRandomEmoRatio: 1 / 6,
  ),
  motion: CappellaMotion(
    rowEnterY: 30,
    rowEnterScale: 0.968,
    rowEnterDuration: 0.38,
    rowExitY: -26,
    rowExitScale: 0.94,
    rowExitDuration: 0.28,
    avatarSpring: CappellaSpring(stiffness: 360, damping: 24, mass: 0.68),
    activeScale: 1.18,
    passedScale: 0.88,
    passedOpacity: 0.76,
    activeFontMultiplier: 1.4,
    inactiveFontMultiplier: 0.92,
    activePaddingX: 22,
    activePaddingY: 17,
    inactivePaddingX: 15,
    inactivePaddingY: 11,
    activeMinHeight: 68,
    inactiveMinHeight: 42,
    glowOpacity: 0.52,
    glowDuration: 1.35,
    glowRightAlpha: 0.42,
    glowLeftAlpha: 0.24,
    activeShadowAlpha: 0.42,
    emoActiveSize: 178,
    emoInactiveSize: 122,
    emoEnterScale: 0.54,
    emoSizeTransitionDuration: 0.28,
  ),
);

/// 按强度取参数表（folia `getCappellaIntensityConfig`）。
CappellaIntensityConfig cappellaIntensityConfig(CappellaIntensity intensity) =>
    switch (intensity) {
      CappellaIntensity.calm => _calm,
      CappellaIntensity.normal => _normal,
      CappellaIntensity.chaotic => _chaotic,
    };
