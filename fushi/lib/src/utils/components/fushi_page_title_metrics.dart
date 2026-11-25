/// 模块页「页头大字」顶栏的**唯一**尺寸来源（设计稿 11-20 #18）。
///
/// 首页 / 书架 / 漫画 / 视频 / 音乐 / 游戏 / 浏览 / 复习 / 查词 / 设置的大标题行
/// 都画在 `FushiFloatingChromeBar` 的页头大字布局里（`fushi_page_masthead.dart`
/// + `fushi_floating_chrome.dart`）：页名字号 / 字重 / 字距、模块徽标、右侧动作
/// 命中区、右端主按钮、行上内边距与各段下边距全部从这里取，页面里不写死字号。
///
/// 数值以书架（库页）当时的实际代码为准（2026-11-20 用户拍板「以书架为准」）：
/// 手机页名 46（设计稿量的约 50 是截图估值）、字重 900、徽标 22、动作命中区
/// 48、主按钮 48；宽窗 84 / 44 / 56。滚动收缩的终点（收起态）也在这里。
library;

import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/utils/adaptive/shell_style.dart'
    show FushiPageTitleStyle, pageTitleStyleOf;
import 'package:fushi/src/utils/app_ui_scale.dart';
import 'package:fushi/src/utils/misc/platform_utils.dart'
    show WindowSizeClass, windowSizeClassReal;

@immutable
class FushiPageTitleMetrics {
  const FushiPageTitleMetrics._({
    required this.compact,
    required this.titleFontSize,
    required this.collapsedTitleFontSize,
    required this.twoLineMinTitleFontSize,
    required this.twoLineMaxTitleFontSize,
    required this.sectionTitle,
    required this.switchFontSize,
    required this.collapsedSwitchFontSize,
    required this.badgeExtent,
    required this.collapsedBadgeExtent,
    required this.primaryExtent,
    required this.topPad,
    required this.collapsedTopPad,
    required this.badgeLift,
    required this.collapsedBadgeLift,
    required this.switchLift,
    required this.collapsedSwitchLift,
    required this.actionLift,
    required this.collapsedActionLift,
    required this.titleBadgeGap,
    required this.toSwitchGap,
    required this.actionsPrimaryGap,
  });

  /// 手机 / 窄窗（真实窗口宽落在 compact 档）。
  static const FushiPageTitleMetrics phone = FushiPageTitleMetrics._(
    compact: true,
    titleFontSize: 46,
    collapsedTitleFontSize: 28,
    twoLineMinTitleFontSize: 22,
    twoLineMaxTitleFontSize: 34,
    sectionTitle: FushiPageTitleScale(
      fontSize: 34,
      collapsedFontSize: 24,
      twoLineMinFontSize: 20,
      twoLineMaxFontSize: 26,
      weight: FontWeight.w700,
      letterSpacingEm: -0.02,
      lineHeight: 1.05,
    ),
    switchFontSize: 19,
    collapsedSwitchFontSize: 15,
    badgeExtent: 22,
    collapsedBadgeExtent: 22,
    primaryExtent: 48,
    topPad: 8,
    collapsedTopPad: 8,
    badgeLift: 6,
    collapsedBadgeLift: 6,
    switchLift: 6,
    collapsedSwitchLift: 6,
    actionLift: 2,
    collapsedActionLift: 2,
    titleBadgeGap: 8,
    toSwitchGap: 8,
    actionsPrimaryGap: 8,
  );

  /// 平板 / 桌面（medium 及以上）。
  static const FushiPageTitleMetrics wide = FushiPageTitleMetrics._(
    compact: false,
    titleFontSize: 84,
    collapsedTitleFontSize: 36,
    twoLineMinTitleFontSize: 28,
    twoLineMaxTitleFontSize: 56,
    sectionTitle: FushiPageTitleScale(
      fontSize: 52,
      collapsedFontSize: 30,
      twoLineMinFontSize: 24,
      twoLineMaxFontSize: 36,
      weight: FontWeight.w700,
      letterSpacingEm: -0.02,
      lineHeight: 1.05,
    ),
    switchFontSize: 30,
    collapsedSwitchFontSize: 18,
    badgeExtent: 44,
    collapsedBadgeExtent: 28,
    primaryExtent: 56,
    topPad: 26,
    collapsedTopPad: 10,
    badgeLift: 12,
    collapsedBadgeLift: 3,
    switchLift: 11,
    collapsedSwitchLift: 3,
    actionLift: 8,
    collapsedActionLift: 2,
    titleBadgeGap: 12,
    toSwitchGap: 20,
    actionsPrimaryGap: 12,
  );

  /// 按 [compact] 取一档。
  static FushiPageTitleMetrics forCompact(bool compact) =>
      compact ? phone : wide;

  /// 此处生效的一档（与外壳底栏同一判据：真实窗口宽落在 compact 档即手机）。
  static FushiPageTitleMetrics of(BuildContext context) =>
      forCompact(isCompact(context));

  /// 手机 / 窄窗判据。
  static bool isCompact(BuildContext context) =>
      windowSizeClassReal(
        MediaQuery.sizeOf(context).width,
        FushiAppUiScale.of(context),
      ) ==
      WindowSizeClass.compact;

  final bool compact;

  /// 页名字号：展开态 / 收起态（滚动收缩在绘制层按比例缩放）。
  final double titleFontSize;
  final double collapsedTitleFontSize;

  /// 二级页头（`FushiMastheadHeader`）页名缩到收起态字号仍一行放不下时，折成
  /// 两行（词不拆开）的字号范围：在这两档之间取放得下的最大字号，最小档仍放
  /// 不下才第二行末省略（`fushiMastheadTitleFit`，BUG-5062）。
  final double twoLineMinTitleFontSize;
  final double twoLineMaxTitleFontSize;

  /// 页名字重 / 字距（em）/ 行高。
  static const FontWeight titleWeight = FontWeight.w900;
  static const double titleLetterSpacingEm = -0.045;
  static const double titleLineHeight = 0.98;

  /// [FushiPageTitleTier.section] 档的页名字阶（设置分类页这类满屏小字行的
  /// 二级页）。两行字号范围按 [FushiPageTitleTier.page] 档同一比例取：最小档
  /// ≈ 收起态 × 0.8，最大档落在收起态与展开态之间。
  final FushiPageTitleScale sectionTitle;

  /// [tier] 档的页名字阶（字号 / 收起态 / 两行范围 / 字重 / 字距 / 行高）。
  FushiPageTitleScale titleScale(FushiPageTitleTier tier) => switch (tier) {
    FushiPageTitleTier.page => FushiPageTitleScale(
      fontSize: titleFontSize,
      collapsedFontSize: collapsedTitleFontSize,
      twoLineMinFontSize: twoLineMinTitleFontSize,
      twoLineMaxFontSize: twoLineMaxTitleFontSize,
      weight: titleWeight,
      letterSpacingEm: titleLetterSpacingEm,
      lineHeight: titleLineHeight,
    ),
    FushiPageTitleTier.section => sectionTitle,
  };

  /// 此处生效的 [tier] 档页名字阶：出厂字阶叠上用户的页面标题样式（字号比例、
  /// 粗细，[pageTitleStyleOf]）。凡是有 context 的绘制 / 量宽处一律走这里，不直接
  /// 读 [titleScale]——否则用户调了字号，量出来的行高与画出来的字对不上。
  static FushiPageTitleScale titleScaleOf(
    BuildContext context, {
    required bool compact,
    FushiPageTitleTier tier = FushiPageTitleTier.page,
  }) => forCompact(compact).titleScale(tier).styled(pageTitleStyleOf(context));

  /// 一级切换（「媒体库 / 在线」）字号：副段，比页名小一档、未选项变淡；
  /// 页名不跟着缩。
  final double switchFontSize;
  final double collapsedSwitchFontSize;

  /// 窄窗下一级切换顶替页名当标题（「书架 / 在线」）时：选中项就是这一行的
  /// 主标题，直接用页名字阶（[titleStyle]）；其余项是副段，缩小
  /// （[headlineIdleFontSize]）、变淡。主标题不跟着副段缩。
  static const double headlineIdleFontSize = 22;

  /// 页名（或标题形态的一级切换）放不下时最多缩到规格字号的这个比例。
  ///
  /// 放不下时的让位顺序（所有模块页同一份，见 `_RenderMastheadLayout`）：
  /// 1. 右侧动作按优先级逐个收进「⋯」（`adaptiveOverflow`），右端主按钮不动；
  /// 2. 页名在原行等比缩字号，最多缩到 [minTitleScale]；
  /// 3. 还放不下：页名换到动作行下面单独一行（整行宽），仍放不下再按词换行。
  /// 任何一步都不截断、不出省略号。
  static const double minTitleScale = 0.85;

  /// [natural] 宽的标题放进 [room] 宽时的字号缩放与是否换行。
  static FushiTitleFit fitTitle({
    required double natural,
    required double room,
  }) {
    if (!room.isFinite || natural <= room + _kFitEpsilon) {
      return FushiTitleFit.natural;
    }
    if (natural * minTitleScale <= room + _kFitEpsilon) {
      return FushiTitleFit._(scale: room / natural, wrap: false);
    }
    return const FushiTitleFit._(scale: minTitleScale, wrap: true);
  }

  /// 缩到下限后能否留在 [room] 宽的原行里（否则换到单独一行）。
  static bool fitsInline({required double natural, required double room}) =>
      natural * minTitleScale <= room + _kFitEpsilon;

  /// 一级切换字重 / 字距（em）。
  static const FontWeight switchWeight = FontWeight.w900;
  static const double switchLetterSpacingEm = -0.03;

  /// 页名后模块徽标的边长：展开态 / 收起态。
  final double badgeExtent;
  final double collapsedBadgeExtent;

  /// 右侧动作：每颗按钮的最小命中区、相邻间隙、图标字号。
  static const double actionExtent = 48;
  static const double actionGap = 3;
  static const double actionIconSize = 24;

  /// 右端主按钮（导入 / 头像 / 开始复习）的边长；收起态缩到
  /// [collapsedPrimaryExtent]，免得一颗大圆压过收小的页名。
  final double primaryExtent;
  static const double collapsedPrimaryExtent = 40;

  /// 大字行的上内边距：展开态 / 收起态。
  final double topPad;
  final double collapsedTopPad;

  /// 徽标 / 一级切换（无页名时）/ 动作组与主按钮相对行底的下边距。
  final double badgeLift;
  final double collapsedBadgeLift;
  final double switchLift;
  final double collapsedSwitchLift;
  final double actionLift;
  final double collapsedActionLift;

  /// 页名与徽标、徽标（或页名）与一级切换、动作组与主按钮之间的间距。
  final double titleBadgeGap;
  final double toSwitchGap;
  final double actionsPrimaryGap;

  static double _lerp(double a, double b, double t) => a + (b - a) * t;

  /// 收缩进度 [p]（0 展开 → 1 收起）下的页名字号。
  double titleFontAt(double p) =>
      _lerp(titleFontSize, collapsedTitleFontSize, p);

  /// 收缩进度 [p] 下的一级切换字号。
  double switchFontAt(double p) =>
      _lerp(switchFontSize, collapsedSwitchFontSize, p);

  /// 收缩进度 [p] 下的徽标边长。
  double badgeExtentAt(double p) => _lerp(badgeExtent, collapsedBadgeExtent, p);

  double topPadAt(double p) => _lerp(topPad, collapsedTopPad, p);

  /// 收缩进度 [p] 下主按钮的边长（展开 [primaryExtent] → 收起
  /// [collapsedPrimaryExtent]）。
  double primaryExtentAt(double p) =>
      _lerp(primaryExtent, collapsedPrimaryExtent, p);

  /// 大字行第一行的最小高度（对齐线）：手机上恒按「主按钮位 + 下边距」留高，
  /// 不论这一页有没有主按钮 / 动作——页名基线、徽标、动作图标中线在各模块页
  /// 落在同一条线上，切 tab 不跳。宽窗不设下限（平板 / 桌面不在 11-20 #18 范围）。
  double minFirstRowExtentAt(double p) =>
      compact ? primaryExtentAt(p) + actionLiftAt(p) : 0;
  double badgeLiftAt(double p) => _lerp(badgeLift, collapsedBadgeLift, p);
  double switchLiftAt(double p) => _lerp(switchLift, collapsedSwitchLift, p);
  double actionLiftAt(double p) => _lerp(actionLift, collapsedActionLift, p);

  /// 页名大字的字阶（颜色由调用方给）。
  TextStyle titleStyle(
    TextStyle base, {
    required Color color,
    FushiPageTitleTier tier = FushiPageTitleTier.page,
  }) => titleScale(tier).style(base, color: color);

  /// 一级切换大字的字阶；[fontSize] 覆盖字号（标题形态的选中 / 未选项）。
  TextStyle switchStyle(
    TextStyle base, {
    required Color color,
    double? fontSize,
  }) {
    final double size = fontSize ?? switchFontSize;
    return base.copyWith(
      fontSize: size,
      fontWeight: switchWeight,
      letterSpacing: switchLetterSpacingEm * size,
      height: 1,
      leadingDistribution: TextLeadingDistribution.even,
      color: color,
    );
  }
}

const double _kFitEpsilon = 0.5;

/// 页名字阶档位。
enum FushiPageTitleTier {
  /// 库页 / 模块页的页名（书架规格，11-20 #18）。
  page,

  /// 设置分类页这类「一页里很多行小字」的二级页：书架规格的页名比正文大四倍、
  /// 字重跳三档，像另一个 app 贴在上面（2026-11-20 用户截图「设置的字看着
  /// 怪」）。降一档、字重 700，仍是页面里最大的字，但与行文字同一家族。
  section,
}

/// 一档页名字阶（[FushiPageTitleMetrics.titleScale]）。
@immutable
class FushiPageTitleScale {
  const FushiPageTitleScale({
    required this.fontSize,
    required this.collapsedFontSize,
    required this.twoLineMinFontSize,
    required this.twoLineMaxFontSize,
    required this.weight,
    required this.letterSpacingEm,
    required this.lineHeight,
  });

  /// 展开态 / 收起态字号（滚动收缩在绘制层按比例缩放）。
  final double fontSize;
  final double collapsedFontSize;

  /// 二级页头页名折两行时的字号范围（见
  /// [FushiPageTitleMetrics.twoLineMinTitleFontSize]）。
  final double twoLineMinFontSize;
  final double twoLineMaxFontSize;

  final FontWeight weight;

  /// 字距（em）与行高。
  final double letterSpacingEm;
  final double lineHeight;

  /// 叠上用户的页面标题样式：字号（展开 / 收起 / 两行范围）一起乘比例，收缩
  /// 比例不变；选过粗细时换字重。
  FushiPageTitleScale styled(FushiPageTitleStyle user) {
    if (user.fontScale == 1 && user.weight == null) return this;
    return FushiPageTitleScale(
      fontSize: user.scaleFont(fontSize),
      collapsedFontSize: user.scaleFont(collapsedFontSize),
      twoLineMinFontSize: user.scaleFont(twoLineMinFontSize),
      twoLineMaxFontSize: user.scaleFont(twoLineMaxFontSize),
      weight: user.weightOr(weight),
      letterSpacingEm: letterSpacingEm,
      lineHeight: lineHeight,
    );
  }

  /// 这一档的页名字样（颜色由调用方给）。
  TextStyle style(TextStyle base, {required Color color}) => base.copyWith(
    fontSize: fontSize,
    fontWeight: weight,
    letterSpacing: letterSpacingEm * fontSize,
    height: lineHeight,
    leadingDistribution: TextLeadingDistribution.even,
    color: color,
  );
}

/// 标题在给定宽里的排法：字号缩放（≥ [FushiPageTitleMetrics.minTitleScale]）与
/// 是否允许按词换行。
@immutable
class FushiTitleFit {
  const FushiTitleFit._({required this.scale, required this.wrap});

  static const FushiTitleFit natural = FushiTitleFit._(scale: 1, wrap: false);

  final double scale;
  final bool wrap;

  /// 把字号与字距按 [scale] 缩放。
  TextStyle apply(TextStyle style) => scale == 1
      ? style
      : style.copyWith(
          fontSize: style.fontSize == null ? null : style.fontSize! * scale,
          letterSpacing: style.letterSpacing == null
              ? null
              : style.letterSpacing! * scale,
        );
}
