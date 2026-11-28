import 'dart:math' as math;
import 'dart:ui' show ImageFilter;

import 'package:cupertino_ui/cupertino_ui.dart' show CupertinoIcons;
import 'package:material_ui/material_ui.dart';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/adaptive/fushi_page_backdrop.dart';
import 'package:fushi/src/utils/adaptive/shell_style.dart';
import 'package:fushi/src/utils/components/fushi_material_components.dart'
    show FushiHeaderCrampScope;
import 'package:fushi/src/utils/components/fushi_page_title_metrics.dart';
import 'package:fushi/src/utils/components/fushi_press_scale.dart';
import 'package:fushi/src/utils/components/fushi_motion_tokens.dart';
import 'package:fushi/src/utils/components/glass/fushi_apple_bar_cluster.dart'
    show FushiAppleBarCluster, fushiAppleBarCapsuleExtent;
import 'package:fushi/src/utils/components/glass/fushi_apple_palette.dart'
    show FushiAppleColors, appleColorsOf;
import 'package:fushi/src/utils/components/glass/fushi_glass_buttons.dart'
    show fushiAppleCompact, fushiAppleMacScale;
import 'package:fushi/src/utils/components/glass/fushi_glass_bars.dart'
    show FushiAppleScrollEdgeBackdrop, FushiAppleSoftScrollEdge;
import 'package:fushi/src/utils/components/glass/fushi_glass_feedback.dart'
    show FushiTooltip;
import 'package:fushi/src/utils/components/glass/fushi_glass_overlays.dart'
    show showFushiMenu;
import 'package:fushi/src/utils/components/glass/fushi_glass_toggles.dart'
    show FushiSegmentedButton;
import 'package:fushi/src/utils/components/library_section_tab.dart';
import 'package:fushi/src/utils/misc/platform_utils.dart'
    show HorizontalDragScrollable;
import 'package:fushi/src/utils/system_transparency.dart'
    show SystemTransparency;
import 'package:fushi/src/utils/components/fushi_typography.dart';

// 库页「页头大字」顶栏（重设计外壳，[shellRedesignActive] 为 true 时才生效）。
//
// 顶栏没有容器：页名是一行大字，一级切换（媒体库 / 在线）也写成大字、紧跟页名
// 基线对齐；二级页签是 M3E 连体按钮组，排在大字行下方。装配仍是库页原来那套
// [FushiFloatingChromeOverlay] + [FushiFloatingChromeBar] + [LibrarySectionTabs]，
// 只由 overlay 的 `masthead` 开关经 [FushiMastheadScope] 告诉里面的组件「换成
// 页头大字的画法」——焦点停靠点、方向键切换、Semantics、动作收进「⋯」的逻辑
// 都不动。

/// 页头大字顶栏里，某个组件所在的那一行。
enum FushiMastheadRole {
  /// 大字行（页名 + 一级切换 + 右侧动作）。
  primary,

  /// 大字行下方的二级页签行（连体按钮组）。
  secondary,
}

/// 由 `FushiFloatingChromeOverlay(masthead: true)` 挂在它的工具行外面。
class FushiMastheadScope extends InheritedWidget {
  const FushiMastheadScope({
    required this.role,
    required super.child,
    super.key,
  });

  final FushiMastheadRole role;

  @override
  bool updateShouldNotify(FushiMastheadScope oldWidget) =>
      role != oldWidget.role;
}

/// 此处生效的页头大字行；不在页头大字顶栏里、或重设计外壳不生效（墨水屏）
/// 时为 null——调用方据此走原来的画法，一字不变。Apple 设计系统同样生效，
/// 只换配色（[fushiMastheadPaletteOf]）。
FushiMastheadRole? fushiMastheadRoleOf(BuildContext context) {
  final FushiMastheadRole? role = context
      .dependOnInheritedWidgetOfExactType<FushiMastheadScope>()
      ?.role;
  if (role == null) return null;
  if (!shellRedesignActive(context)) return null;
  return role;
}

/// 页头大字的配色。MD3：外壳强调色（封面取色或主题 primary 一族）+
/// surfaceContainer 一族；Apple：主题 primary 当强调色 + Apple 系统填充色 /
/// label 色。
@immutable
class FushiMastheadPalette {
  const FushiMastheadPalette({
    required this.strong,
    required this.indicator,
    required this.onIndicator,
    required this.ink,
    required this.segment,
    required this.segmentHover,
  });

  /// 选中的一级切换文字、选中的二级页签底。
  final Color strong;

  /// 主按钮底 / 主按钮图标。
  final Color indicator;
  final Color onIndicator;

  /// 页面底色上的文字（页名、未选中项按比例淡化）。
  final Color ink;

  /// 连体按钮组的底 / 悬停底。
  final Color segment;
  final Color segmentHover;
}

FushiMastheadPalette fushiMastheadPaletteOf(BuildContext context) {
  final ColorScheme scheme = Theme.of(context).colorScheme;
  if (isGlassDesign(context)) {
    final FushiAppleColors apple = appleColorsOf(context);
    return FushiMastheadPalette(
      strong: scheme.primary,
      indicator: scheme.primary,
      onIndicator: scheme.onPrimary,
      ink: apple.label,
      segment: apple.secondaryFill,
      segmentHover: apple.fill,
    );
  }
  final ShellAccentColors accent = shellAccentOf(context);
  return FushiMastheadPalette(
    strong: accent.strong,
    indicator: accent.indicator,
    onIndicator: accent.onIndicator,
    ink: scheme.onSurface,
    segment: scheme.surfaceContainerHigh,
    segmentHover: scheme.surfaceContainerHighest,
  );
}

/// 窄窗下页名让位给一级切换时（见 `FushiFloatingChromeBar`），一级切换顶替
/// 页名当这一行的标题：改用宽窗字号。
class FushiMastheadSwitchHeadline extends InheritedWidget {
  const FushiMastheadSwitchHeadline({
    required this.headline,
    required super.child,
    super.key,
  });

  final bool headline;

  static bool of(BuildContext context) =>
      context
          .dependOnInheritedWidgetOfExactType<FushiMastheadSwitchHeadline>()
          ?.headline ??
      false;

  @override
  bool updateShouldNotify(FushiMastheadSwitchHeadline oldWidget) =>
      oldWidget.headline != headline;
}

/// 手机 / 窄窗（MD3 含横屏手机，见 [FushiPageTitleMetrics.isCompact]）。
bool fushiMastheadCompact(BuildContext context) =>
    FushiPageTitleMetrics.isCompact(context);

/// 页头大字随滚动收缩：内容滚动偏移 0 → 本值映射到收缩进度 0 → 1（设计稿
/// `.cap-B`：桌面 130、手机 90）。
double fushiMastheadCollapseDistance({required bool compact}) =>
    compact ? 90 : 130;

/// 工具区控制器最多记到的滚动偏移（再往下滚进度已经满了，不必逐帧通知）。
const double kFushiMastheadTrackedOffset = 400;

/// 生效的收缩进度：减弱动态效果 / 墨水屏下只取两档（过半即收到底），不做
/// 连续缩放。
double fushiMastheadEffectiveProgress(bool motionEnabled, double raw) {
  final double p = raw.clamp(0.0, 1.0);
  if (motionEnabled) return p;
  return p >= 0.5 ? 1 : 0;
}

/// 滚动偏移 [offset] 下的生效收缩进度。
double fushiMastheadProgressOf({
  required bool compact,
  required bool motionEnabled,
  required double offset,
}) => fushiMastheadEffectiveProgress(
  motionEnabled,
  offset / fushiMastheadCollapseDistance(compact: compact),
);

double _lerp(double a, double b, double t) => a + (b - a) * t;

/// 页名字号（[FushiPageTitleMetrics.titleFontAt]）。
double _titleFontAt({required bool compact, required double p}) =>
    FushiPageTitleMetrics.forCompact(compact).titleFontAt(p);

/// 一级切换字号（[FushiPageTitleMetrics.switchFontAt]）。
double _switchFontAt({required bool compact, required double p}) =>
    FushiPageTitleMetrics.forCompact(compact).switchFontAt(p);

/// 徽标边长（[FushiPageTitleMetrics.badgeExtentAt]）。
double fushiMastheadBadgeExtent({required bool compact, double p = 0}) =>
    FushiPageTitleMetrics.forCompact(compact).badgeExtentAt(p);

/// 页头大字顶栏的几何（全部是设计稿 `.cap-B` 的原值，p = 收缩进度）。
///
/// 第一行底对齐：页名下边距 0；徽标、一级切换、动作组、主按钮底对齐后各自再
/// 抬一个下边距（一级切换改用字面基线与页名对齐，结果与设计稿的下边距一致）。
/// 第二行是二级页签。**版面高度恒为 p = 0 的两行总高**（内容让位不随滚动变，
/// 不会自激）；收缩只在绘制层：各段按 [frameAt] 平移 / 缩放，页头底板按
/// [visibleHeightAt] 收短。
///
/// 所有模块页（含首页手机）都从展开态起收，没有「钉在收起态」的特例：切 tab
/// 时页名字号、主按钮、基线一致（设计稿 11-20 #18，规格见
/// [FushiPageTitleMetrics]）。
@immutable
class FushiMastheadGeometry {
  const FushiMastheadGeometry({
    required this.compact,
    required this.width,
    this.stacked = false,
    required this.leading,
    required this.title,
    required this.titleBaseline,
    required this.titleInkCenter,
    required this.titleLineHeight,
    required this.badge,
    required this.switcher,
    required this.switchBaseline,
    required this.actions,
    required this.primary,
    required this.secondary,
    this.apple = false,
  });

  final bool compact;
  final double width;

  /// Apple（Cupertino）设计系统的导航栏形态（2026-11 用户拍板，设计稿
  /// `video_topbar_cupertino_design/v5.html`）：
  /// - 窄窗（[compact]）= iOS 大标题导航栏：第一行只有前导 / 动作组 / 主按钮
  ///   （恒 [stacked]），下面一行是 34pt 大标题 + 右侧一级分段控件；随滚动这一
  ///   行收起，大标题缩成动作行正中的 17pt 小标题，一级分段随行滚走并淡出；
  /// - 宽窗 = 常驻工具栏：标题、一级分段、动作同一行垂直居中，不随滚动收缩
  ///   （调用方把进度钉在 0）。
  final bool apple;

  /// Apple 窄窗收起态小标题字号与展开态大标题字号（iOS 17pt / 34pt）。
  static const double appleInlineTitleFont = 17;
  static const double appleLargeTitleFont = 34;

  /// 主标题（页名 / 标题形态的一级切换）缩到下限仍放不进动作行，换到动作行
  /// 下面单独一行（[FushiPageTitleMetrics.minTitleScale]）。
  final bool stacked;

  /// 主标题单独一行时，与上面动作行之间的空。
  static const double stackGap = 4;

  /// 各段在 p = 0 时的版面尺寸（没有的段为 [Size.zero]）。
  final Size leading;
  final Size title;

  /// 页名 / 一级切换的字面基线到各自盒底的距离（p = 0）。
  final double titleBaseline;

  /// 主标题（页名 / 标题形态的一级切换）按自然字号排一行时，字面中心
  /// （[FushiPageTitleMetrics.inkCenterEm]）到行盒底边的距离与行盒高（p = 0）。
  /// 前导 / 动作组 / 主按钮 / 徽标的中线对到这条线上。
  final double titleInkCenter;
  final double titleLineHeight;
  final Size badge;
  final Size switcher;
  final double switchBaseline;
  final Size actions;
  final Size primary;

  /// 二级页签（含上下各 [_kSegmentHitBand] 的透明命中带）。
  final Size secondary;

  bool get hasSecondary => secondary.height > 0;

  double titleScaleAt(double p) {
    if (apple) {
      return compact
          ? _lerp(1, appleInlineTitleFont / appleLargeTitleFont, p)
          : 1;
    }
    return _titleFontAt(compact: compact, p: p) /
        _titleFontAt(compact: compact, p: 0);
  }

  /// 窄窗下没有页名时，一级切换就是这一行的主标题（标题形态的「书架 / 在线」
  /// 或返回键页的单独页名，都是页名字号）：随滚动与页名同比例收缩。
  bool get _switchIsTitle => compact && title.height <= 0;

  double switchScaleAt(double p) => apple
      ? 1
      : _switchIsTitle
      ? titleScaleAt(p)
      : _switchFontAt(compact: compact, p: p) /
            _switchFontAt(compact: compact, p: 0);
  double badgeScaleAt(double p) =>
      fushiMastheadBadgeExtent(compact: compact, p: p) /
      fushiMastheadBadgeExtent(compact: compact);

  /// 主按钮缩放：收起态页名缩到 28 时主按钮（头像 / 导入）跟着从 48 缩到 40，
  /// 免得一颗大圆压过页名（2026-11-16 用户：顶栏比例不协调）。
  double primaryScaleAt(double p) => primary.height <= 0 || apple
      ? 1
      : _lerp(
          1,
          FushiPageTitleMetrics.collapsedPrimaryExtent / primary.height,
          p,
        ).clamp(0, 1);

  FushiPageTitleMetrics get _metrics =>
      FushiPageTitleMetrics.forCompact(compact);

  /// 这一行有主标题（页名，或窄窗下顶替页名的一级切换），前导 / 动作组 /
  /// 主按钮 / 徽标的中线对到它的字面中心。Apple 导航栏与主标题单独一行时不在
  /// 同一行，各自居中。
  bool get _inkAnchored =>
      !apple &&
      !stacked &&
      titleInkCenter > 0 &&
      (title.height > 0 || _switchIsTitle);

  /// 主标题字面中心离它行盒底边的高度（进度 [p]）。页名放不下原行时由它自己
  /// 等比缩字号（[FushiPageTitleMetrics.fitTitle]），盒高随之按比例变矮。
  double _headlineInkAt(double p) {
    final double fit = title.height > 0 && titleLineHeight > 0
        ? math.min(1.0, title.height / titleLineHeight)
        : 1.0;
    return titleInkCenter * fit * titleScaleAt(p);
  }

  /// 动作行各段（前导 / 动作组 / 主按钮，主按钮按 [primaryScaleAt]）里最高
  /// 一段的半高。手机上恒按主按钮位与一颗动作按钮中较高的那个留
  /// （[FushiPageTitleMetrics.minFirstRowExtentAt] 同一口径）：这一页没有动作 /
  /// 主按钮时，展开与收起各进度下页名基线都与其它模块页同一条线，切 tab 不跳。
  double _actionHalfAt(double p) =>
      math.max(
        math.max(
          math.max(leading.height, actions.height),
          primary.height * primaryScaleAt(p),
        ),
        compact
            ? math.max(
                _metrics.primaryExtentAt(p),
                FushiPageTitleMetrics.actionExtent,
              )
            : 0,
      ) /
      2;

  /// 图标中线离第一行底边的高度。有主标题时就是主标题的字面中心——字面中心
  /// 太低、最高一段图标会压过 [actionLiftAt] 时，改为把主标题整体抬起；没有
  /// 主标题时最高一段贴下边距。展开 / 收起各进度都成立，滚动收缩时图标与
  /// 页名始终同一条中线（2026-11-26 用户截图）。
  double actionCenterLiftAt(double p) {
    final double iconCenter = _actionHalfAt(p) + actionLiftAt(p);
    if (!_inkAnchored) return iconCenter;
    return math.max(iconCenter, _headlineInkAt(p));
  }

  /// 主标题行盒的下边距：字面中心落在 [actionCenterLiftAt] 上。
  double titleLiftAt(double p) {
    if (!_inkAnchored) return 0;
    return math.max(0.0, actionCenterLiftAt(p) - _headlineInkAt(p));
  }

  /// 面板上内边距：桌面 26 → 10；手机的状态栏由外壳让开，只留 8。Apple 导航栏
  /// 紧贴外壳让开的状态栏 / 标题栏行，不另留。
  double topPadAt(double p) => apple ? 0 : _metrics.topPadAt(p);

  /// 徽标 / 一级切换（无页名时）/ 动作组与主按钮的下边距。徽标跟页名同一行
  /// 时中线对到页名字面中心（[actionCenterLiftAt]）。
  double badgeLiftAt(double p) => _inkAnchored && badge.height > 0
      ? math.max(
          0.0,
          actionCenterLiftAt(p) - badge.height * badgeScaleAt(p) / 2,
        )
      : _metrics.badgeLiftAt(p);
  double switchLiftAt(double p) => _metrics.switchLiftAt(p);
  double actionLiftAt(double p) => _metrics.actionLiftAt(p);

  /// 一级切换的底边离第一行底边的距离：有页名、或窄窗下它顶替页名当主标题
  /// 时，字面基线落在页名基线上（各模块页同一条线，11-20 #18；页名随
  /// [titleLiftAt] 抬起时一起抬）；宽窗无页名时按设计稿下边距。
  double switchBottomLiftAt(double p) {
    if (title.height <= 0 && !_switchIsTitle) return switchLiftAt(p);
    return math.max(
      0.0,
      titleLiftAt(p) +
          titleBaseline * titleScaleAt(p) -
          switchBaseline * switchScaleAt(p),
    );
  }

  /// 页名与徽标、徽标（或页名）与一级切换、动作组与主按钮之间的间距。
  double get titleBadgeGap => _metrics.titleBadgeGap;
  double get toSwitchGap => _metrics.toSwitchGap;
  double get actionsPrimaryGap => _metrics.actionsPrimaryGap;
  static const double leadingGap = 8;

  /// Apple 动作行的高度（iOS 导航栏 44 / macOS 工具栏 48）。
  double get appleActionRowExtent => compact ? 44 : 48;

  /// 第一行（动作行）的高度，供 Apple 收起态小标题居中。
  double actionRowHeightAt(double p) => _actionRowHeightAt(p);

  /// 动作行（前导 / 动作组 / 主按钮）的高度。
  double _actionRowHeightAt(double p) {
    if (apple) {
      double h = appleActionRowExtent;
      if (leading.height > 0) h = math.max(h, leading.height);
      if (actions.height > 0) h = math.max(h, actions.height);
      if (primary.height > 0) h = math.max(h, primary.height);
      if (!compact) h = math.max(h, appleTitleRowExtent);
      return h;
    }
    final double h = _metrics.minFirstRowExtentAt(p);
    final double half = _actionHalfAt(p);
    if (half <= 0) return h;
    return math.max(h, actionCenterLiftAt(p) + half);
  }

  /// Apple 标题行（大标题 / 一级分段）展开态的高度。
  double get appleTitleRowExtent => math.max(title.height, switcher.height);

  /// 标题段（页名 / 徽标 / 一级切换）的高度。
  double _titleRowHeightAt(double p) {
    if (apple) {
      return compact ? appleTitleRowExtent * (1 - p) : appleTitleRowExtent;
    }
    double h = 0;
    if (title.height > 0) {
      h = math.max(h, title.height * titleScaleAt(p) + titleLiftAt(p));
    }
    if (badge.height > 0) {
      h = math.max(h, badge.height * badgeScaleAt(p) + badgeLiftAt(p));
    }
    if (switcher.height > 0) {
      h = math.max(
        h,
        switcher.height * switchScaleAt(p) + switchBottomLiftAt(p),
      );
    }
    return h;
  }

  /// 第一行（主标题单独一行时含动作行 + 标题行）的高度。
  double firstRowHeightAt(double p) => apple && compact
      ? _actionRowHeightAt(p) + (stackGap + appleTitleRowExtent) * (1 - p)
      : stacked
      ? _actionRowHeightAt(p) + stackGap + _titleRowHeightAt(p)
      : math.max(_actionRowHeightAt(p), _titleRowHeightAt(p));

  /// 前导 / 动作组 / 主按钮共同的中线（相对面板顶）：各段按自己的高度以它
  /// 垂直居中。Apple 导航栏是动作行的中线（栏内居中，与主标题无关）；主标题
  /// 单独一行时在动作行里；否则见 [actionCenterLiftAt]。
  double actionCenterAt(double p) => apple
      ? topPadAt(p) + _actionRowHeightAt(p) / 2
      : stacked
      ? topPadAt(p) +
            _actionRowHeightAt(p) -
            (_actionHalfAt(p) + actionLiftAt(p))
      : topPadAt(p) + firstRowHeightAt(p) - actionCenterLiftAt(p);

  /// 第一、二行之间：设计稿 14 → 8，减去二级页签自带的上命中带。
  ///
  /// Apple（设计稿 v5）：窄窗大标题行下沿到二级分段 16（`.titlerow` 后 8 +
  /// `.palette` 上内边距 8），收起后分段贴在导航栏下 8；宽窗工具栏下 6
  /// （`.desk .palette`）。Apple 分段控件没有命中带，不扣。
  double rowGapAt(double p) => apple
      ? (compact ? _lerp(16, 8, p) : 6)
      : math.max(0.0, _lerp(14, 8, p) - _kSegmentHitBand);

  /// 面板下内边距：桌面 12、手机 16（二级页签的下命中带算在里面）。手机原为 8，
  /// 比页边距 / 卡片间距都小，首张卡贴着顶栏（2026-11-16 用户反馈）。
  /// Apple：设计稿 v5 `.palette` 下内边距 10（无二级分段时动作 / 标题行下留 8）。
  double get bottomPad => apple
      ? (hasSecondary ? 10 : 8)
      : (compact ? 16 : 12) - (hasSecondary ? _kSegmentHitBand : 0);

  double secondaryTopAt(double p) =>
      topPadAt(p) + firstRowHeightAt(p) + rowGapAt(p);

  /// 进度 [p] 下页头实际画出来的高度（页头底板画到这里）。
  double visibleHeightAt(double p) =>
      topPadAt(p) +
      firstRowHeightAt(p) +
      (hasSecondary ? rowGapAt(p) + secondary.height : 0) +
      bottomPad;

  /// 版面高度：恒为展开态。
  double get layoutHeight => visibleHeightAt(0);

  /// 进度 [p] 下页头比展开态少画的那段高度。
  double collapseAt(double p) =>
      math.max(0.0, layoutHeight - visibleHeightAt(p));

  @override
  bool operator ==(Object other) =>
      other is FushiMastheadGeometry &&
      other.compact == compact &&
      other.stacked == stacked &&
      other.width == width &&
      other.leading == leading &&
      other.title == title &&
      other.titleBaseline == titleBaseline &&
      other.titleInkCenter == titleInkCenter &&
      other.titleLineHeight == titleLineHeight &&
      other.badge == badge &&
      other.switcher == switcher &&
      other.switchBaseline == switchBaseline &&
      other.actions == actions &&
      other.primary == primary &&
      other.secondary == secondary &&
      other.apple == apple;

  @override
  int get hashCode => Object.hash(
    compact,
    stacked,
    width,
    leading,
    title,
    titleBaseline,
    titleInkCenter,
    titleLineHeight,
    badge,
    switcher,
    switchBaseline,
    actions,
    primary,
    secondary,
    apple,
  );
}

/// 二级连体按钮组的视觉高度 / 命中带（上下各一条）/ 相邻间隙。
const double _kSegmentHeight = 40;
const double _kSegmentHitBand = 4;
const double _kSegmentHitHeight = _kSegmentHeight + 2 * _kSegmentHitBand;
const double _kSegmentGap = 3;
const double _kSegmentInnerRadius = 8;
const double _kSegmentOuterRadius = 20;
const double _kSegmentPadding = 16;

/// 换页签 / 换页名时的入场位移（逻辑 px）：小幅位移 + 淡入，不做大幅滑动。
const double _kMastheadEnterTravel = 28;

/// 页名大字（滚动收缩由绘制层缩放，这里是展开态字号）：[tier] 档的字阶，见
/// [FushiPageTitleMetrics.titleScale]（模块页 [FushiPageTitleTier.page] 宽窗
/// 84 / 窄窗 46、w900；设置分类页 [FushiPageTitleTier.section] 52 / 34、w700）。
TextStyle fushiMastheadTitleStyle(
  BuildContext context, {
  required bool compact,
  FushiPageTitleTier tier = FushiPageTitleTier.page,
}) {
  return FushiPageTitleMetrics.forCompact(compact).titleStyle(
    Theme.of(context).textTheme.displayLarge ?? const TextStyle(),
    color: fushiMastheadPaletteOf(context).ink,
    tier: tier,
  );
}

/// 一级切换顶替页名当标题时（[FushiMastheadSwitchHeadline]）未选项的字号：
/// 选中项直接用页名字阶（[fushiMastheadTitleStyle]，与其它模块页的页名一模一样，
/// 主标题不缩，11-20 #18），未选项收小变淡——大小差本身就说明「现在在哪」
/// （2026-11-12 用户）。
const double kFushiMastheadHeadlineIdleFont =
    FushiPageTitleMetrics.headlineIdleFontSize;

/// 一级切换大字：宽窗 30 / 窄窗 19，字重 900、字距 -0.03em（各项同字重，切换
/// 时宽度不跳）。[fontSize] 覆盖字号（标题形态的选中项 / 未选项）。
TextStyle fushiMastheadSwitchStyle(
  BuildContext context, {
  required bool compact,
  double? fontSize,
}) {
  return FushiPageTitleMetrics.forCompact(compact).switchStyle(
    Theme.of(context).textTheme.headlineMedium ?? const TextStyle(),
    color: fushiMastheadPaletteOf(context).ink,
    fontSize: fontSize,
  );
}

/// 一行文字按 [style] 排出来的宽。
double fushiMastheadTextWidth(
  BuildContext context,
  String text,
  TextStyle style,
) {
  final TextPainter painter = TextPainter(
    text: TextSpan(text: text, style: style),
    textDirection: Directionality.of(context),
    textScaler: MediaQuery.textScalerOf(context),
    maxLines: 1,
  )..layout();
  final double width = painter.width;
  painter.dispose();
  return width;
}

/// 页名在给定宽里的排法（[fushiMastheadTitleFit] 的结果）：[scale] 是相对
/// 满字号的缩放，[lines] 是行数（1 或 2），[lineWidth] 是满字号坐标下的折行宽
/// （单行时即自然宽）。
@immutable
class FushiMastheadTitleFit {
  const FushiMastheadTitleFit({
    required this.scale,
    required this.lines,
    required this.lineWidth,
  });

  final double scale;
  final int lines;
  final double lineWidth;
}

/// 页名 [text]（满字号 [style]）在 [maxWidth] 里的排法，依次取第一个放得下的：
///
/// 1. 满字号一行；
/// 2. 一行，整体缩小到放得下（不小于 [singleLineMinScale]，即收起态字号）；
/// 3. 两行、词不拆开，在 [twoLineMinScale]～[twoLineMaxScale] 间二分取最大缩放
///    （「Reading controls」这类长页名与长译名）；
/// 4. 都放不下：两行、[twoLineMinScale]，第二行末省略。
///
/// [maxLines] 为 1 时（行高固定、装不下两行的裸图标行页头）跳过第 3 步：缩到
/// [singleLineMinScale] 仍放不下就按这个缩放一行、末尾省略。
FushiMastheadTitleFit fushiMastheadTitleFit({
  required String text,
  required TextStyle style,
  required double maxWidth,
  required double singleLineMinScale,
  required double twoLineMinScale,
  required double twoLineMaxScale,
  required TextDirection direction,
  required TextScaler textScaler,
  int maxLines = 2,
}) {
  assert(maxLines == 1 || maxLines == 2, 'maxLines must be 1 or 2');
  TextPainter layout(double wrapWidth, int maxLines) => TextPainter(
    text: TextSpan(text: text, style: style),
    textDirection: direction,
    textScaler: textScaler,
    maxLines: maxLines,
    textWidthBasis: TextWidthBasis.longestLine,
  )..layout(maxWidth: wrapWidth);

  final TextPainter single = layout(double.infinity, 1);
  final double natural = single.width + 1;
  single.dispose();
  if (!maxWidth.isFinite || natural <= maxWidth) {
    return FushiMastheadTitleFit(scale: 1, lines: 1, lineWidth: natural);
  }
  final double singleScale = maxWidth / natural;
  if (singleScale >= singleLineMinScale) {
    return FushiMastheadTitleFit(
      scale: singleScale,
      lines: 1,
      lineWidth: natural,
    );
  }
  if (maxLines == 1) {
    return FushiMastheadTitleFit(
      scale: singleLineMinScale,
      lines: 1,
      lineWidth: maxWidth / singleLineMinScale,
    );
  }
  // 两行：按满字号排进 maxWidth / s 宽（等价于 s 倍字号排进 maxWidth）。
  bool fits(double s) {
    final double wrap = maxWidth / s;
    final TextPainter painter = layout(wrap, 2);
    final bool ok =
        !painter.didExceedMaxLines && painter.minIntrinsicWidth <= wrap + 0.5;
    painter.dispose();
    return ok;
  }

  final double hiBound = math.max(twoLineMinScale, twoLineMaxScale);
  double s = twoLineMinScale;
  if (fits(hiBound)) {
    s = hiBound;
  } else if (fits(twoLineMinScale)) {
    double lo = twoLineMinScale;
    double hi = hiBound;
    for (int k = 0; k < 10; k++) {
      final double mid = (lo + hi) / 2;
      if (fits(mid)) {
        lo = mid;
      } else {
        hi = mid;
      }
    }
    s = lo;
  }
  final TextPainter wrapped = layout(maxWidth / s, 2);
  final double lineWidth = math.min(maxWidth / s, wrapped.width + 1);
  wrapped.dispose();
  return FushiMastheadTitleFit(scale: s, lines: 2, lineWidth: lineWidth);
}

/// 一行大字的竖向度量（都从行盒底边量起）：[baseline] 字母基线、[inkCenter]
/// 字面中心（[FushiPageTitleMetrics.inkCenterEm]，图标中线对齐的参照）、
/// [height] 行盒高。
typedef FushiMastheadLineMetrics = ({
  double baseline,
  double inkCenter,
  double height,
});

/// [text] 按 [style] 排一行的竖向度量（见 [FushiMastheadLineMetrics]）。
FushiMastheadLineMetrics fushiMastheadLineMetrics(
  BuildContext context,
  String text,
  TextStyle style,
) {
  final TextScaler textScaler = MediaQuery.textScalerOf(context);
  final TextPainter painter = TextPainter(
    text: TextSpan(text: text.isEmpty ? 'A' : text, style: style),
    textDirection: Directionality.of(context),
    textScaler: textScaler,
    maxLines: 1,
  )..layout();
  final double baseline = painter.computeDistanceToActualBaseline(
    TextBaseline.alphabetic,
  );
  final double height = painter.height;
  painter.dispose();
  final double fromBottom = height - baseline;
  final double font = textScaler.scale(style.fontSize ?? 14);
  return (
    baseline: fromBottom,
    inkCenter: fromBottom + FushiPageTitleMetrics.inkCenterEm * font,
    height: height,
  );
}

/// 一行文字的基线到行盒底边的距离（让两种字号的大字按基线对齐）。
double fushiMastheadBaselineFromBottom(
  BuildContext context,
  String text,
  TextStyle style,
) => fushiMastheadLineMetrics(context, text, style).baseline;

/// 连体按钮组（二级页签）的文字：labelMedium 字阶、w800。
TextStyle fushiMastheadSegmentLabelStyle(BuildContext context) =>
    (Theme.of(context).textTheme.labelLarge ?? const TextStyle()).copyWith(
      fontSize: context.fushiType.labelMedium.fontSize,
      fontWeight: FontWeight.w800,
    );

/// 动作组每颗按钮的最小宽 / 高（命中区 48）与相邻间隙。
const double kFushiMastheadActionExtent = FushiPageTitleMetrics.actionExtent;
const double kFushiMastheadActionGap = FushiPageTitleMetrics.actionGap;

/// 页头大字顶栏右侧的动作组：按钮平铺、不垫胶囊底（用户 2026-11-12「去掉
/// 胶囊」），悬停 / 按压 / 焦点反馈由按钮本体自己画。这里只给每颗 48 的最小
/// 命中区与间隙。[items] 是已经按宽度收过「⋯」的结果（见
/// `FushiShellHeaderActions`）。
class FushiMastheadActionGroup extends StatelessWidget {
  const FushiMastheadActionGroup({required this.items, super.key});

  final List<Widget> items;

  @override
  Widget build(BuildContext context) {
    // 图标字号走共用规格（[FushiPageTitleMetrics.actionIconSize]）：各模块页
    // 的动作图标同一大小、同一条中线。
    return IconTheme.merge(
      data: const IconThemeData(size: FushiPageTitleMetrics.actionIconSize),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          for (int i = 0; i < items.length; i++) ...<Widget>[
            if (i > 0) const SizedBox(width: kFushiMastheadActionGap),
            ConstrainedBox(
              constraints: const BoxConstraints(
                minWidth: kFushiMastheadActionExtent,
                minHeight: kFushiMastheadActionExtent,
                maxHeight: kFushiMastheadActionExtent,
              ),
              child: Center(widthFactor: 1, child: items[i]),
            ),
          ],
        ],
      ),
    );
  }
}

// 页面底色（选中二级页签上的文字色）：脚手架底色不透明时用它，否则 surface。
Color fushiMastheadPageColor(BuildContext context) {
  final ThemeData theme = Theme.of(context);
  final Color scaffold = theme.scaffoldBackgroundColor;
  return scaffold.a >= 1 ? scaffold : theme.colorScheme.surface;
}

/// 小幅位移 + 淡入的入场过渡（标题换字、二级页签换组共用）：位移走 spatial
/// slow 弹簧（ζ 0.8 / k 200，最接近设计稿的 210 / 22），透明度走 effects 弹簧。
Widget _mastheadEnter(
  BuildContext context,
  Animation<double> animation,
  Widget child,
) {
  final FushiMotionScheme motion = context.fushiMotion;
  final Animation<double> travel = animation.drive(
    CurveTween(curve: motion.spatialSlow.curve),
  );
  final Animation<double> fade = animation.drive(
    CurveTween(curve: motion.effectsDefault.curve),
  );
  return FadeTransition(
    opacity: fade,
    child: AnimatedBuilder(
      animation: travel,
      child: child,
      builder: (BuildContext context, Widget? child) => Transform.translate(
        offset: Offset(0, (1 - travel.value) * _kMastheadEnterTravel),
        child: child,
      ),
    ),
  );
}

/// 页名大字。换页名时旧字淡出、新字小幅上移淡入。
/// Apple（Cupertino）库页导航栏标题字阶：窄窗 iOS 大标题 34pt / w700，宽窗
/// macOS 工具栏标题 15pt / w700（设计稿 `video_topbar_cupertino_design/v5.html`）。
TextStyle fushiAppleNavTitleStyle(
  BuildContext context, {
  required bool compact,
}) {
  final TextStyle base =
      Theme.of(context).textTheme.displayLarge ?? const TextStyle();
  return base.copyWith(
    fontSize: compact ? FushiMastheadGeometry.appleLargeTitleFont : 15,
    fontWeight: FontWeight.w700,
    letterSpacing: compact ? 0.37 : 0,
    height: compact ? 41 / 34 : 1.25,
    color: appleColorsOf(context).label,
  );
}

///
/// @design dual
/// M3E：页头大字（[fushiMastheadTitleStyle]）。Apple（[isGlassDesign]）：导航栏
/// 标题字阶 [fushiAppleNavTitleStyle]（窄窗 iOS 大标题 34pt bold、宽窗 macOS
/// 工具栏标题）。调用方显式给 [style] 时两套都用它。
class FushiMastheadTitle extends StatelessWidget {
  const FushiMastheadTitle({
    required this.title,
    required this.compact,
    this.maxLines,
    this.tier = FushiPageTitleTier.page,
    this.style,
    super.key,
  });

  final String title;
  final bool compact;

  /// 覆盖字阶（Apple 库页导航栏用 [fushiAppleNavTitleStyle]）；null = 按
  /// [tier] 取页头大字。
  final TextStyle? style;

  /// 页名字阶档位（设置分类页用 [FushiPageTitleTier.section]）。
  final FushiPageTitleTier tier;

  /// null（默认，模块页）：自己按 [FushiPageTitleMetrics.fitTitle] 缩字号 / 换行。
  /// 非 null（二级页头）：调用方已按 [fushiMastheadTitleFit] 定好缩放与折行宽，
  /// 这里按满字号排、最多这么多行，仍放不下才末尾省略。
  final int? maxLines;

  @override
  Widget build(BuildContext context) {
    final FushiMotionScheme motion = context.fushiMotion;
    // container：页名自己成一个语义节点。不成节点的话「书架」这个 label 会一路
    // 向上并进外壳的手势 / 焦点节点（与侧栏、页签争成兄弟合并组），换页或
    // 重排时框架复用这些共享节点就会断言 `!child.attached`。
    final TextStyle base =
        style ??
        (isGlassDesign(context)
            ? fushiAppleNavTitleStyle(context, compact: compact)
            : fushiMastheadTitleStyle(context, compact: compact, tier: tier));
    return Semantics(
      container: true,
      header: true,
      child: maxLines != null
          ? _switcher(
              context,
              motion,
              Text(
                title,
                key: ValueKey<String>('fushi-masthead-title-$title'),
                maxLines: maxLines,
                softWrap: maxLines! > 1,
                overflow: TextOverflow.ellipsis,
                style: base,
                // 末行下沿按字体自然下伸量排：页名行高紧（0.98 / 1.05），按行高
                // 压缩后的下沿比 g / p / y 的字形高，两行都放不下而出省略号时
                // 段落按自身边界裁切，会把末行下伸部切掉（BUG-5611）。
                textHeightBehavior: const TextHeightBehavior(
                  applyHeightToLastDescent: false,
                  leadingDistribution: TextLeadingDistribution.even,
                ),
              ),
            )
          // 放不下时先缩字号（≤ 15%）再按词换行，不截断、不出省略号
          // （[FushiPageTitleMetrics.fitTitle]）。
          : LayoutBuilder(
              builder: (BuildContext context, BoxConstraints constraints) {
                final FushiTitleFit fit = FushiPageTitleMetrics.fitTitle(
                  natural: fushiMastheadTextWidth(context, title, base),
                  room: constraints.maxWidth,
                );
                return _switcher(
                  context,
                  motion,
                  Text(
                    title,
                    key: ValueKey<String>('fushi-masthead-title-$title'),
                    maxLines: fit.wrap ? null : 1,
                    softWrap: fit.wrap,
                    style: fit.apply(base),
                  ),
                );
              },
            ),
    );
  }

  Widget _switcher(
    BuildContext context,
    FushiMotionScheme motion,
    Widget text,
  ) => AnimatedSwitcher(
    duration: motion.spatialSlow.duration,
    reverseDuration: motion.effectsFast.duration,
    layoutBuilder: (Widget? current, List<Widget> previous) => Stack(
      alignment: AlignmentDirectional.bottomStart,
      children: <Widget>[...previous, if (current != null) current],
    ),
    transitionBuilder: (Widget child, Animation<double> animation) =>
        _mastheadEnter(context, animation, child),
    child: text,
  );
}

/// 一级切换写成大字：当前项 [FushiMastheadPalette.strong]、其余 onSurface 26%
/// （悬停 60%），项间「/」分隔。只接指针；键盘 / 手柄由外层
/// `FushiAdjustableSegmented` 的单个停靠点左右切换。
///
/// @design dual
/// Apple（[isGlassDesign]）：Cupertino 分段控件（[FushiAppleSectionSegments]，
/// 按内容取宽），与库页 Apple 导航栏的一级切换同一组件。
class FushiMastheadSwitch<T extends Object> extends StatelessWidget {
  const FushiMastheadSwitch({
    required this.tabs,
    required this.selected,
    required this.onChanged,
    this.selectedIsCurrent = true,
    super.key,
  });

  final List<LibrarySectionTab<T>> tabs;
  final T selected;
  final ValueChanged<T> onChanged;

  /// false = [selected] 只是视觉锚点，宿主此刻停在不属于任何一项的视图上
  /// （库页停在导入页时高亮「我的」组）：点中它也要照常回调 [onChanged]，否则
  /// 那一项看着是选中的、却点不回去（BUG-4706）。默认 true：点当前项不回调。
  final bool selectedIsCurrent;

  @override
  Widget build(BuildContext context) {
    if (isGlassDesign(context)) {
      return FushiAppleSectionSegments<T>(
        tabs: tabs,
        selected: selected,
        onChanged: onChanged,
        fill: false,
        selectedIsCurrent: selectedIsCurrent,
      );
    }
    final bool headline = FushiMastheadSwitchHeadline.of(context);
    final bool compact = fushiMastheadCompact(context) && !headline;
    final TextStyle style = fushiMastheadSwitchStyle(context, compact: compact);
    // 标题形态：选中项大、未选项小，按字面基线对齐；其余形态各项同字号。
    final TextStyle selectedStyle = headline
        ? fushiMastheadTitleStyle(context, compact: true)
        : style;
    final TextStyle idleStyle = headline
        ? fushiMastheadSwitchStyle(
            context,
            compact: false,
            fontSize: kFushiMastheadHeadlineIdleFont,
          )
        : style;
    final double separatorPad = 0.4 * (idleStyle.fontSize ?? 28);
    final TextStyle separatorStyle = idleStyle.copyWith(
      fontWeight: FontWeight.w500,
      letterSpacing: 0,
      color: fushiMastheadPaletteOf(context).ink.withValues(alpha: 0.22),
    );
    // 自然宽上报给顶栏（[FushiHeaderCrampScope]）：动作组按「大字行剩下的宽」
    // 决定要不要收进「⋯」。
    double natural = 0;
    for (int i = 0; i < tabs.length; i++) {
      natural += fushiMastheadTextWidth(
        context,
        tabs[i].label,
        tabs[i].value == selected ? selectedStyle : idleStyle,
      );
      if (i > 0) {
        natural +=
            fushiMastheadTextWidth(context, '/', separatorStyle) +
            separatorPad * 2;
      }
    }
    FushiHeaderCrampScope.maybeOf(context)?.reportTitleNaturalWidth(natural);
    Widget item(int i, double scale, {bool wrap = false}) {
      final bool isSelected = tabs[i].value == selected;
      final TextStyle itemStyle = isSelected ? selectedStyle : idleStyle;
      return _MastheadSwitchItem(
        label: tabs[i].label,
        labelKey: tabs[i].labelKey,
        selected: isSelected,
        wrap: wrap,
        fitScale: scale,
        style: itemStyle,
        onTap: () {
          if (!selectedIsCurrent || tabs[i].value != selected) {
            onChanged(tabs[i].value);
          }
        },
      );
    }

    Widget separator(double scale) => ExcludeSemantics(
      child: Padding(
        padding: EdgeInsets.symmetric(horizontal: separatorPad * scale),
        child: Text(
          '/',
          style: separatorStyle.copyWith(
            fontSize: (separatorStyle.fontSize ?? 14) * scale,
          ),
        ),
      ),
    );

    Widget row(double scale) => Row(
      mainAxisSize: MainAxisSize.min,
      // 标题形态各项字号不同：按字面基线对齐（同字号时与底对齐等价）。
      crossAxisAlignment: headline
          ? CrossAxisAlignment.baseline
          : CrossAxisAlignment.end,
      textBaseline: TextBaseline.alphabetic,
      children: <Widget>[
        for (int i = 0; i < tabs.length; i++) ...<Widget>[
          if (i > 0) separator(scale),
          item(i, scale),
        ],
      ],
    );

    if (headline) {
      // 标题形态：选中项就是页名，与 [FushiMastheadTitle] 同一套让位
      // （[FushiPageTitleMetrics.fitTitle]）：先整段缩字号（≤ 15%），还放不下
      // 就把其余项折到下一行，不截断、不出省略号、不横滑。
      return LayoutBuilder(
        builder: (BuildContext context, BoxConstraints constraints) {
          final FushiTitleFit fit = FushiPageTitleMetrics.fitTitle(
            natural: natural,
            room: constraints.maxWidth,
          );
          if (!fit.wrap) return row(fit.scale);
          return Wrap(
            crossAxisAlignment: WrapCrossAlignment.end,
            children: <Widget>[
              for (int i = 0; i < tabs.length; i++)
                if (i == 0)
                  item(i, fit.scale, wrap: true)
                else
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.baseline,
                    textBaseline: TextBaseline.alphabetic,
                    children: <Widget>[
                      separator(fit.scale),
                      // 单项比整行还宽时按词换行，不越出。
                      Flexible(child: item(i, fit.scale, wrap: true)),
                    ],
                  ),
            ],
          );
        },
      );
    }
    // 其余形态（宽窗副段）：整段等比缩小到放得下，不横滑——两三个字的切换
    // 还要拖着看另一半很反直觉，也不能任它画到右边的动作按钮底下。
    return FittedBox(
      fit: BoxFit.scaleDown,
      alignment: AlignmentDirectional.bottomStart,
      child: row(1),
    );
  }
}

class _MastheadSwitchItem extends StatefulWidget {
  const _MastheadSwitchItem({
    required this.label,
    required this.labelKey,
    required this.selected,
    required this.style,
    required this.onTap,
    this.wrap = false,
    this.fitScale = 1,
  });

  final String label;
  final Key? labelKey;
  final bool selected;
  final TextStyle style;
  final VoidCallback onTap;

  /// 单项比整行还宽（标题形态折行后的选中项）时按词换行，不截断。
  final bool wrap;

  /// 放不下时的字号缩放（[FushiTitleFit.scale]）。走 textScaler、不改
  /// [style]：样式的补间只用于选中 / 未选切换，缩放要当帧生效，否则补间中途
  /// 的字号比算好的宽更大，会越出。
  final double fitScale;

  @override
  State<_MastheadSwitchItem> createState() => _MastheadSwitchItemState();
}

class _MastheadSwitchItemState extends State<_MastheadSwitchItem> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final FushiMotionScheme motion = context.fushiMotion;
    final Color onSurface = fushiMastheadPaletteOf(context).ink;
    final Color color = widget.selected
        ? fushiMastheadPaletteOf(context).strong
        : onSurface.withValues(alpha: _hovered ? 0.6 : 0.26);
    // 一个按钮一个语义节点：名称、选中、点按都挂在这一层，子树（文字、手势）
    // 不再各出节点，不靠 MergeSemantics 合并。
    return Semantics(
      container: true,
      button: true,
      selected: widget.selected,
      inMutuallyExclusiveGroup: true,
      label: widget.label,
      onTap: widget.onTap,
      excludeSemantics: true,
      child: Semantics(
        button: true,
        selected: widget.selected,
        inMutuallyExclusiveGroup: true,
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          onEnter: (_) => setState(() => _hovered = true),
          onExit: (_) => setState(() => _hovered = false),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: widget.onTap,
            child: AnimatedDefaultTextStyle(
              duration: motion.effectsDefault.duration,
              curve: motion.effectsDefault.curve,
              style: widget.style.copyWith(color: color),
              child: Text(
                widget.label,
                key: widget.labelKey,
                maxLines: widget.wrap ? null : 1,
                softWrap: widget.wrap,
                textScaler: widget.fitScale == 1
                    ? null
                    : _FitTextScaler(
                        MediaQuery.textScalerOf(context),
                        widget.fitScale,
                      ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 二级页签：M3E 连体按钮组（高 40、相邻间隙 3、内侧圆角 8、组首尾外侧圆角
/// 20；选中项四角全圆 20、底 [FushiMastheadPalette.strong]、字为页面底色）。
/// 命中区上下外扩到 48。放不下时横向滚动、不换行。挂载时（换组即换一份）
/// 小幅位移 + 淡入。只接指针；键盘 / 手柄由外层单个停靠点左右切换。
///
/// @design dual
/// Apple（[isGlassDesign]）：Cupertino 分段控件（[FushiAppleSectionSegments]），
/// 窄窗铺满整行，与库页 Apple 导航栏的二级视图同一组件。
class FushiMastheadSegmentedTabs<T extends Object> extends StatefulWidget {
  const FushiMastheadSegmentedTabs({
    required this.tabs,
    required this.selected,
    required this.onChanged,
    this.selectedIsCurrent = true,
    super.key,
  });

  final List<LibrarySectionTab<T>> tabs;
  final T selected;
  final ValueChanged<T> onChanged;

  /// 同 [FushiMastheadSwitch.selectedIsCurrent]。
  final bool selectedIsCurrent;

  @override
  State<FushiMastheadSegmentedTabs<T>> createState() =>
      _FushiMastheadSegmentedTabsState<T>();
}

class _FushiMastheadSegmentedTabsState<T extends Object>
    extends State<FushiMastheadSegmentedTabs<T>>
    with SingleTickerProviderStateMixin {
  /// 线性进度；弹簧形状由 [_mastheadEnter] 分属性施加（位移 spatial、透明度
  /// effects），时长取 spatial slow 弹簧的落定时长（降级时为零，直接到位）。
  late final AnimationController _enter = AnimationController(vsync: this);
  bool _started = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    _enter
      ..duration = context.fushiMotion.spatialSlow.duration
      ..forward();
  }

  @override
  void dispose() {
    _enter.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (isGlassDesign(context)) {
      return FushiAppleSectionSegments<T>(
        tabs: widget.tabs,
        selected: widget.selected,
        onChanged: widget.onChanged,
        fill: fushiMastheadCompact(context),
        selectedIsCurrent: widget.selectedIsCurrent,
      );
    }
    final List<LibrarySectionTab<T>> tabs = widget.tabs;
    final int count = tabs.length;
    final Widget group = Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        for (int i = 0; i < count; i++) ...<Widget>[
          if (i > 0) const SizedBox(width: _kSegmentGap),
          _MastheadSegment(
            label: tabs[i].label,
            labelKey: tabs[i].labelKey,
            selected: tabs[i].value == widget.selected,
            first: i == 0,
            last: i == count - 1,
            onTap: () {
              if (!widget.selectedIsCurrent ||
                  tabs[i].value != widget.selected) {
                widget.onChanged(tabs[i].value);
              }
            },
          ),
        ],
      ],
    );
    return _mastheadEnter(
      context,
      _enter,
      ScrollConfiguration(
        behavior: ScrollConfiguration.of(context).copyWith(scrollbars: false),
        // 横向滚动区一律经 [HorizontalDragScrollable] 放开鼠标 / 触控板拖动
        // （守卫 horizontal_drag_scroll_guard_test）。
        child: HorizontalDragScrollable(
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: group,
          ),
        ),
      ),
    );
  }
}

class _MastheadSegment extends StatefulWidget {
  const _MastheadSegment({
    required this.label,
    required this.labelKey,
    required this.selected,
    required this.first,
    required this.last,
    required this.onTap,
  });

  final String label;
  final Key? labelKey;
  final bool selected;
  final bool first;
  final bool last;
  final VoidCallback onTap;

  @override
  State<_MastheadSegment> createState() => _MastheadSegmentState();
}

class _MastheadSegmentState extends State<_MastheadSegment> {
  bool _hovered = false;

  /// 首 / 中 / 尾按位置定圆角（外侧 20、内侧 8），选中与否不改外形——四项同形
  /// 同高、只靠填充色 / 前景色区分选中（设计稿 V4）。
  BorderRadiusDirectional _radius() {
    if (widget.first && widget.last) {
      return BorderRadiusDirectional.circular(_kSegmentOuterRadius);
    }
    const Radius inner = Radius.circular(_kSegmentInnerRadius);
    const Radius outer = Radius.circular(_kSegmentOuterRadius);
    return BorderRadiusDirectional.horizontal(
      start: widget.first ? outer : inner,
      end: widget.last ? outer : inner,
    );
  }

  @override
  Widget build(BuildContext context) {
    final FushiMotionScheme motion = context.fushiMotion;
    final FushiMastheadPalette palette = fushiMastheadPaletteOf(context);
    final Color fill = widget.selected
        ? palette.strong
        : _hovered
        ? palette.segmentHover
        : palette.segment;
    final Color ink = widget.selected
        ? fushiMastheadPageColor(context)
        : palette.ink;
    final TextStyle style = fushiMastheadSegmentLabelStyle(
      context,
    ).copyWith(color: ink);
    // 一个按钮一个语义节点：名称、选中、点按都挂在这一层，子树（文字、手势）
    // 不再各出节点，不靠 MergeSemantics 合并。
    return Semantics(
      container: true,
      button: true,
      selected: widget.selected,
      inMutuallyExclusiveGroup: true,
      label: widget.label,
      onTap: widget.onTap,
      excludeSemantics: true,
      child: Semantics(
        button: true,
        selected: widget.selected,
        inMutuallyExclusiveGroup: true,
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          onEnter: (_) => setState(() => _hovered = true),
          onExit: (_) => setState(() => _hovered = false),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: widget.onTap,
            // 视觉 40、命中 48：上下各补 [_kSegmentHitBand] 的透明命中带。
            child: SizedBox(
              height: _kSegmentHitHeight,
              // 按压只做不占布局的缩放（[FushiPressScale]），不再加宽内边距——
              // 四项的宽高在按压时也不变（设计稿 V4）。
              child: Center(
                child: FushiPressScale(
                  child: AnimatedContainer(
                    duration: motion.effectsDefault.duration,
                    curve: motion.effectsDefault.curve,
                    height: _kSegmentHeight,
                    decoration: ShapeDecoration(
                      color: fill,
                      shape: shellShape(context, _radius()),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: _kSegmentPadding,
                      ),
                      child: Center(
                        widthFactor: 1,
                        child: AnimatedDefaultTextStyle(
                          duration: motion.effectsDefault.duration,
                          curve: motion.effectsDefault.curve,
                          style: style,
                          child: Text(
                            widget.label,
                            key: widget.labelKey,
                            maxLines: 1,
                            softWrap: false,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 页头大字顶栏右端的主按钮（库页「导入」）：高 56（窄窗 48）、圆角 20、底
/// [FushiMastheadPalette.indicator]、图标 onIndicator；悬停 / 选中时圆角弹到 28。
/// 按钮本体由调用方给的 [builder] 按传入的形状 / 颜色 / 尺寸画（沿用原按钮的
/// 焦点、tooltip 与 Semantics）。
///
/// @design dual
/// Apple（[isGlassDesign]）：与顶栏其余动作同一枚中性玻璃圆钮
/// （[FushiAppleBarCluster]，`GlassBarItemBackground.separate`，不着强调色，
/// 窄窗 44 / 宽窗 36，随玻璃画质档位）。[builder] 收到圆形、透明底
/// （[FushiMastheadPalette.indicator] 透明、onIndicator = label 色）与圆钮
/// 边长，底由玻璃圆钮画；没有悬停弹角与投影。
class FushiMastheadPrimaryButton extends StatefulWidget {
  const FushiMastheadPrimaryButton({
    required this.selected,
    required this.builder,
    super.key,
  });

  final bool selected;
  final Widget Function(
    BuildContext context,
    OutlinedBorder shape,
    FushiMastheadPalette palette,
    double extent,
  )
  builder;

  @override
  State<FushiMastheadPrimaryButton> createState() =>
      _FushiMastheadPrimaryButtonState();
}

class _FushiMastheadPrimaryButtonState
    extends State<FushiMastheadPrimaryButton> {
  bool _hovered = false;

  Widget _buildApple(BuildContext context) {
    final FushiMastheadPalette base = fushiMastheadPaletteOf(context);
    final bool compact = fushiMastheadCompact(context);
    final double extent = fushiAppleBarCapsuleExtent(context, compact: compact);
    final FushiMastheadPalette palette = FushiMastheadPalette(
      strong: base.strong,
      indicator: const Color(0x00000000),
      onIndicator: appleColorsOf(context).label,
      ink: base.ink,
      segment: base.segment,
      segmentHover: base.segmentHover,
    );
    return FushiAppleBarCluster(
      compact: compact,
      items: <Widget>[
        widget.builder(context, const CircleBorder(), palette, extent),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    if (isGlassDesign(context)) return _buildApple(context);
    final FushiMotionScheme motion = context.fushiMotion;
    final double extent = FushiPageTitleMetrics.of(context).primaryExtent;
    final double target = _hovered || widget.selected ? 28 : 20;
    final FushiMastheadPalette palette = fushiMastheadPaletteOf(context);
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: TweenAnimationBuilder<double>(
        tween: Tween<double>(end: target),
        duration: motion.spatialFast.duration,
        curve: motion.spatialFast.curve,
        builder: (BuildContext context, double radius, Widget? _) {
          final OutlinedBorder shape = shellShape(
            context,
            BorderRadius.circular(math.min(math.max(radius, 0), extent / 2)),
          );
          // 设计稿 `.cta`：投影 0 8 20、indicator 30%。
          return DecoratedBox(
            decoration: ShapeDecoration(
              shape: shape,
              shadows: <BoxShadow>[
                BoxShadow(
                  offset: const Offset(0, 8),
                  blurRadius: 20,
                  color: palette.indicator.withValues(alpha: 0.3),
                ),
              ],
            ),
            child: widget.builder(context, shape, palette, extent),
          );
        },
      ),
    );
  }
}

/// 当前模块的专属多边形（与侧栏选中形状同一个，由首页外壳按 tab 挂）；页头
/// 大字的徽标读它，拿不到就不画。
class FushiMastheadBadgeScope extends InheritedWidget {
  const FushiMastheadBadgeScope({
    required this.shape,
    required super.child,
    super.key,
  });

  final RoundedPolygon? shape;

  static RoundedPolygon? maybeOf(BuildContext context) => context
      .dependOnInheritedWidgetOfExactType<FushiMastheadBadgeScope>()
      ?.shape;

  @override
  bool updateShouldNotify(FushiMastheadBadgeScope oldWidget) =>
      shape != oldWidget.shape;
}

/// 页名右侧的徽标：一枚 indicator 色的模块多边形，纯装饰（不进语义）。边长取
/// 展开态（宽窗 44 / 窄窗 22），收缩由绘制层缩放。
///
/// @design dual
/// Apple（[isGlassDesign]）：不画。Apple 导航栏没有 M3E 模块多边形这种装饰
/// （库页 Apple 导航栏同样不挂徽标，见 `FushiFloatingChromeBar`）；
/// `FushiBadgeControl` 是计数 / 红点徽标，语义不同，不拿来顶替。
class FushiMastheadBadge extends StatelessWidget {
  const FushiMastheadBadge({
    required this.shape,
    required this.compact,
    super.key,
  });

  final RoundedPolygon shape;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    if (isGlassDesign(context)) return const SizedBox.shrink();
    final FushiMastheadPalette palette = fushiMastheadPaletteOf(context);
    return ExcludeSemantics(
      child: SizedBox.square(
        dimension: fushiMastheadBadgeExtent(compact: compact),
        child: DecoratedBox(
          decoration: ShapeDecoration(
            color: palette.indicator,
            shape: MaterialShapeBorder(shape: shape),
          ),
        ),
      ),
    );
  }
}

/// 自定义背景图下页头底板的进度下限：未滚动时就是一层 ~54% 页面底色 + sigma ~11
/// 的毛玻璃。
const double kFushiMastheadImageProgressFloor = 0.6;

/// 页头底板（设计稿 `.cap-B .mast`）：内容滚到页头下面时，页面底色按进度
/// 铺到 90% 不透明 + 背后高斯模糊（sigma 按进度到 18），裁在底板矩形内；未
/// 滚动（p = 0）时不画底、不开模糊。系统「降低透明度」/「增强对比度」下不
/// 开模糊，退成不透明底色（按进度淡入）。
///
/// 页底是用户的**自定义背景图**时（[FushiPageBackdrop.imageOf]），未滚动也常驻
/// 一层毛玻璃（进度下限 [kFushiMastheadImageProgressFloor]）：页名大字、一级切换
/// 直接压在图上看不清（2026-11-24 用户：「自定义了背景，文字后面没有描边或毛玻璃」）。
/// 滚动后照旧加浓到 90%。
class FushiMastheadPanel extends StatelessWidget {
  const FushiMastheadPanel({
    required this.height,
    required this.progress,
    this.backdropBlur = true,
    super.key,
  });

  /// 底板高度（含向上铺进外壳顶部安全区的那段）。
  final double height;

  /// 生效的收缩进度（已按动效开关取过档）。
  final double progress;

  /// 是否自己开一层背景模糊。嵌套工具层（库页标签条等）传 false：页头与标签条
  /// 是同一块吸顶面（设计稿 V3），两层各开一块 `ClipRect + BackdropFilter`，两块
  /// 磨砂的模糊边界在接缝处叠出一条线，标签条那块像另一层底。嵌套层只画不透明
  /// 的同色填充，接在根层模糊底板的下沿（接缝由调用方按物理像素对齐）。
  final bool backdropBlur;

  @override
  Widget build(BuildContext context) {
    final double progress =
        FushiPageBackdrop.imageOf(context) && !isEinkTheme(context)
        ? math.max(this.progress, kFushiMastheadImageProgressFloor)
        : this.progress;
    if (progress <= 0 || height <= 0) return const SizedBox.shrink();
    if (backdropBlur && isGlassDesign(context)) return _buildApple(context);
    if (!backdropBlur) {
      return SizedBox(
        height: height,
        child: ColoredBox(
          color: fushiMastheadPageColor(context).withValues(alpha: progress),
        ),
      );
    }
    return ValueListenableBuilder<bool>(
      valueListenable: SystemTransparency.reduceTransparency,
      builder: (BuildContext context, bool reduce, Widget? _) {
        final bool blur =
            !reduce && !(MediaQuery.maybeHighContrastOf(context) ?? false);
        final Color page = fushiMastheadPageColor(context);
        final Widget fill = ColoredBox(
          color: page.withValues(alpha: (blur ? 0.9 : 1) * progress),
        );
        return SizedBox(
          height: height,
          child: blur
              ? ClipRect(
                  child: BackdropFilter(
                    filter: ImageFilter.blur(
                      sigmaX: 18 * progress,
                      sigmaY: 18 * progress,
                    ),
                    child: fill,
                  ),
                )
              : fill,
        );
      },
    );
  }
}

extension on FushiMastheadPanel {
  /// Apple（Cupertino）scroll edge：iOS 27 导航栏的整块底
  /// （[FushiAppleScrollEdgeBackdrop]：模糊 + 压暗、下沿发丝线，实色档不透明
  /// 页面底色），从窗口顶一直铺到最深一行吸顶工具（一级 / 二级分段）的下沿
  /// （[height]，调用方给），按 [progress] 淡入，停在顶部不出现。与二级页
  /// 顶栏（[FushiAppleSoftScrollEdge]）同一个组件。
  Widget _buildApple(BuildContext context) => FushiAppleScrollEdgeBackdrop(
    height: height,
    progress: progress,
    color: fushiMastheadPageColor(context),
  );
}

/// 库 `GlassScrollEdgeEffect` soft 档的渐隐曲线（`_kFadeCurves[soft]`，库未导出，
/// 照抄数值）：边缘不透明，先缓后急，长尾在 92% 处归零，没有接缝。
const List<double> kFushiAppleSoftEdgeAlphas = <double>[
  1.0,
  0.70,
  0.30,
  0.04,
  0.0,
];
const List<double> kFushiAppleSoftEdgeStops = <double>[
  0.0,
  0.15,
  0.45,
  0.75,
  0.92,
];

/// Apple scroll edge 从透明到满所需的滚动距离（逻辑 px）。
const double kFushiAppleScrollEdgeDistance = 24;

/// Apple scroll edge 在最后一行吸顶工具（分段 / 标签行）下沿之外再延伸的缓冲
/// （逻辑 px）：soft 曲线的尾巴落在这里，工具行背后仍有一层可读的底色。
const double kFushiAppleScrollEdgeFade = 24;

/// `LibrarySectionTabs` 与页头大字一级 / 二级切换（[FushiMastheadSwitch] /
/// [FushiMastheadSegmentedTabs]）在 Apple 设计系统下的呈现层：原生 Cupertino 分段控件
/// （用户 2026-10-12「顶部的标签页改回为 Cupertino 的分段选择器」，取代 10-04
/// 的 iOS 文字页签 + 下划线）。
///
/// 段宽首选等分（`UISegmentedControl` 形态）：[fill] 且摆得下时铺满整行，
/// 否则按内容取宽贴左。等宽摆不下时先按内容分宽（`apportionsSegmentWidthsByContent`，
/// 由控件内的 [fushiSegmentWidths] 逐级退让：短段让出留白、再收内边距），只要
/// 每段文字在最小内边距下都放得下，就全部排在一行里（用户 2026-11-26：阅读
/// 设置面板五个分区被收起两个）。连这样都摆不下才不横滑（横滑会把首尾段切掉
/// 一截，2026-10-12 用户截图「视频这块没贴合」），与 MD3 页签同一套溢出：只排
/// 得下的前几段进控件，其余收进末尾的「更多」下拉；选中段在溢出区时替换到可见
/// 末位，永远看得到自己在哪。焦点契约在外层 [FushiAdjustableSegmented]（与
/// MD3 的 TabBar 同一外壳）。
///
/// @design dual（Apple 专用分支：M3E 侧是 `FushiSectionTabBar` /
/// [FushiMastheadSegmentedTabs] / [FushiMastheadSwitch]）
class FushiAppleSectionSegments<T extends Object> extends StatelessWidget {
  const FushiAppleSectionSegments({
    required this.tabs,
    required this.selected,
    required this.onChanged,
    required this.fill,
    required this.selectedIsCurrent,
    super.key,
  });

  final List<LibrarySectionTab<T>> tabs;
  final T selected;
  final ValueChanged<T> onChanged;
  final bool fill;

  /// 见 [LibrarySectionTabs.selectedIsCurrent]。
  final bool selectedIsCurrent;

  /// 各段文案宽（与控件同一字样：Apple 分段的选中字样）。
  List<double> _labelWidths(BuildContext context) {
    final bool compact = fushiAppleCompact(context);
    final double macScale = fushiAppleMacScale(context);
    final TextStyle style =
        (Theme.of(context).textTheme.labelLarge ?? const TextStyle()).copyWith(
          fontSize: compact ? 13 * macScale : 15,
          fontWeight: FontWeight.w600,
        );
    final TextScaler scaler = MediaQuery.textScalerOf(context);
    return <double>[
      for (final LibrarySectionTab<T> tab in tabs)
        () {
          final TextPainter painter = TextPainter(
            text: TextSpan(text: tab.label, style: style),
            textDirection: TextDirection.ltr,
            textScaler: scaler,
            maxLines: 1,
          )..layout();
          final double width = painter.width;
          painter.dispose();
          return width;
        }(),
    ];
  }

  /// 首选段内边距（两侧共 28，同 [FushiSegmentedButton] 的口径）与最小段内
  /// 边距（两侧共 12，= [FushiAppleSegmentedControl] 段内固定内边距
  /// `_cellPadding` × 2，再收文字就要被省略）。
  static const double _preferredCellPadding = 28;
  static const double _minCellPadding = 12;

  /// [count] 段的控件宽（轨道两端各 3）。
  static double _controlWidth(double cell, int count) => count * cell + 6;

  Future<void> _showOverflow(
    BuildContext anchorContext,
    List<int> hidden,
  ) async {
    final RenderBox button = anchorContext.findRenderObject()! as RenderBox;
    final RenderBox overlay =
        Navigator.of(anchorContext).overlay!.context.findRenderObject()!
            as RenderBox;
    final RelativeRect position = RelativeRect.fromRect(
      Rect.fromPoints(
        button.localToGlobal(Offset.zero, ancestor: overlay),
        button.localToGlobal(
          button.size.bottomRight(Offset.zero),
          ancestor: overlay,
        ),
      ),
      Offset.zero & overlay.size,
    );
    final int? picked = await showFushiMenu<int>(
      context: anchorContext,
      position: position,
      items: <PopupMenuEntry<int>>[
        for (final int i in hidden)
          PopupMenuItem<int>(value: i, child: Text(tabs[i].label)),
      ],
    );
    if (picked != null) onChanged(tabs[picked].value);
  }

  Widget _control(List<int> visible, {required bool expand}) {
    return FushiSegmentedButton<T>(
      segments: <ButtonSegment<T>>[
        for (final int i in visible)
          ButtonSegment<T>(
            value: tabs[i].value,
            label: Text(tabs[i].label, key: tabs[i].labelKey),
          ),
      ],
      selected: <T>{selected},
      showSelectedIcon: false,
      onSelectionChanged: (Set<T> values) {
        if (values.isNotEmpty) onChanged(values.first);
      },
      notifyReselect: !selectedIsCurrent,
      expandedInsets: expand ? EdgeInsets.zero : null,
    );
  }

  @override
  Widget build(BuildContext context) {
    final List<double> labels = _labelWidths(context);
    final double cell = labels.reduce(math.max) + _preferredCellPadding;
    final double natural = _controlWidth(cell, tabs.length);
    final double labelSum = labels.fold(0, (double a, double b) => a + b);
    // 按内容分宽：自然宽（每段首选内边距）与下限（每段最小内边距）。
    final double contentNatural =
        labelSum + tabs.length * _preferredCellPadding + 6;
    final double contentMin = labelSum + tabs.length * _minCellPadding + 6;
    FushiHeaderCrampScope.maybeOf(context)?.reportTitleNaturalWidth(natural);
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final double max = constraints.maxWidth;
        final List<int> all = <int>[for (int i = 0; i < tabs.length; i++) i];
        if (!max.isFinite || natural <= max) {
          return Align(
            alignment: AlignmentDirectional.centerStart,
            widthFactor: fill ? null : 1,
            child: SizedBox(
              width: fill && max.isFinite ? max : natural,
              child: _control(all, expand: true),
            ),
          );
        }
        // 等宽摆不下、按内容分宽摆得下：全部段排一行，段宽交给控件分配。
        if (contentMin <= max) {
          return Align(
            alignment: AlignmentDirectional.centerStart,
            widthFactor: fill ? null : 1,
            child: SizedBox(
              width: fill ? max : math.min(contentNatural, max),
              child: _control(all, expand: true),
            ),
          );
        }
        // 溢出：留出「更多」钮的位置，算排得下几段（至少 1 段）。
        final int count = math.max(
          1,
          ((max - _kAppleSegmentsMoreWidth - 6) / cell).floor(),
        );
        final int selectedIndex = math.max(
          0,
          tabs.indexWhere((LibrarySectionTab<T> tab) => tab.value == selected),
        );
        final List<int> visible = <int>[
          for (int i = 0; i < count - 1; i++) i,
          selectedIndex >= count - 1 ? selectedIndex : count - 1,
        ];
        final List<int> hidden = <int>[
          for (final int i in all)
            if (!visible.contains(i)) i,
        ];
        // 铺满档溢出时同样占满整行（2026-10-30「二级菜单要做成全宽的」）：
        // 可见段吃掉「更多」钮以外的全部宽度。
        final Widget control = _control(visible, expand: true);
        return Row(
          mainAxisSize: fill ? MainAxisSize.max : MainAxisSize.min,
          children: <Widget>[
            if (fill)
              Expanded(child: control)
            else
              SizedBox(
                width: _controlWidth(cell, visible.length),
                child: control,
              ),
            Builder(
              builder: (BuildContext anchorContext) => _AppleSegmentsMoreButton(
                onTap: () => _showOverflow(anchorContext, hidden),
              ),
            ),
          ],
        );
      },
    );
  }
}

/// [FushiAppleSectionSegments] 溢出档末尾「更多」的宽（也是它的高与点按区）。
const double _kAppleSegmentsMoreWidth = 40.0;

/// [FushiAppleSectionSegments] 溢出档末尾的「更多」：与分段同高的 SF chevron，
/// 点开列出未显示的分区（与 `LibrarySectionTabs` 的「更多」Apple 形态同一画法）。
///
/// 它在外层 `FushiAdjustableSegmented` 的 ExcludeFocus 里，不是单独的焦点停靠
/// 点——键盘 / 手柄在整排这一个停靠点上用左右方向键走遍全部分区，菜单只服务指针。
class _AppleSegmentsMoreButton extends StatelessWidget {
  const _AppleSegmentsMoreButton({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return FushiTooltip(
      message: t.common_more_actions,
      child: Semantics(
        button: true,
        label: t.common_more_actions,
        child: InkResponse(
          onTap: onTap,
          radius: _kAppleSegmentsMoreWidth / 2,
          splashFactory: NoSplash.splashFactory,
          highlightColor: const Color(0x00000000),
          child: SizedBox(
            width: _kAppleSegmentsMoreWidth,
            height: _kAppleSegmentsMoreWidth,
            child: Icon(
              CupertinoIcons.chevron_down,
              size: 17,
              color: appleColorsOf(context).secondaryLabel,
            ),
          ),
        ),
      ),
    );
  }
}

/// 在系统字号缩放之上再乘一个放不下时的缩放（[FushiTitleFit.scale]）。
@immutable
class _FitTextScaler extends TextScaler {
  const _FitTextScaler(this.base, this.factor);

  final TextScaler base;
  final double factor;

  @override
  double scale(double fontSize) => base.scale(fontSize) * factor;

  @override
  // ignore: deprecated_member_use
  double get textScaleFactor => base.textScaleFactor * factor;

  @override
  bool operator ==(Object other) =>
      other is _FitTextScaler && other.base == base && other.factor == factor;

  @override
  int get hashCode => Object.hash(base, factor);
}
