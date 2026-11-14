import 'dart:math' as math;
import 'dart:ui' show ImageFilter;

import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/adaptive/shell_style.dart';
import 'package:fushi/src/utils/app_ui_scale.dart';
import 'package:fushi/src/utils/components/fushi_material_components.dart'
    show FushiHeaderCrampScope;
import 'package:fushi/src/utils/components/fushi_motion_tokens.dart';
import 'package:fushi/src/utils/components/glass/fushi_apple_palette.dart'
    show FushiAppleColors, appleColorsOf;
import 'package:fushi/src/utils/components/library_section_tab.dart';
import 'package:fushi/src/utils/misc/platform_utils.dart'
    show WindowSizeClass, windowSizeClassReal;
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

/// 手机 / 窄窗（与外壳底栏同一判据：真实窗口宽落在 compact 档）。
bool fushiMastheadCompact(BuildContext context) =>
    windowSizeClassReal(
      MediaQuery.sizeOf(context).width,
      FushiAppUiScale.of(context),
    ) ==
    WindowSizeClass.compact;

/// 页头大字随滚动收缩：内容滚动偏移 0 → 本值映射到收缩进度 0 → 1（设计稿
/// `.cap-B`：桌面 130、手机 90）。
double fushiMastheadCollapseDistance({required bool compact}) =>
    compact ? 90 : 130;

/// 工具区控制器最多记到的滚动偏移（再往下滚进度已经满了，不必逐帧通知）。
const double kFushiMastheadTrackedOffset = 130;

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

/// 页名字号：宽窗 84 → 36，窄窗 46 → 28（设计稿 `.cap-B h2`）。
double _titleFontAt({required bool compact, required double p}) =>
    compact ? _lerp(46, 28, p) : _lerp(84, 36, p);

/// 一级切换字号：宽窗 30 → 18，窄窗 19 → 15。
double _switchFontAt({required bool compact, required double p}) =>
    compact ? _lerp(19, 15, p) : _lerp(30, 18, p);

/// 徽标边长：宽窗 44 → 28，窄窗固定 22。
double fushiMastheadBadgeExtent({required bool compact, double p = 0}) =>
    compact ? 22 : _lerp(44, 28, p);

/// 页头大字顶栏的几何（全部是设计稿 `.cap-B` 的原值，p = 收缩进度）。
///
/// 第一行底对齐：页名下边距 0；徽标、一级切换、动作组、主按钮底对齐后各自再
/// 抬一个下边距（一级切换改用字面基线与页名对齐，结果与设计稿的下边距一致）。
/// 第二行是二级页签。**版面高度恒为 p = 0 的两行总高**（内容让位不随滚动变，
/// 不会自激）；收缩只在绘制层：各段按 [frameAt] 平移 / 缩放，页头底板按
/// [visibleHeightAt] 收短。
@immutable
class FushiMastheadGeometry {
  const FushiMastheadGeometry({
    required this.compact,
    required this.width,
    required this.leading,
    required this.title,
    required this.titleBaseline,
    required this.badge,
    required this.switcher,
    required this.switchBaseline,
    required this.actions,
    required this.primary,
    required this.secondary,
  });

  final bool compact;
  final double width;

  /// 各段在 p = 0 时的版面尺寸（没有的段为 [Size.zero]）。
  final Size leading;
  final Size title;

  /// 页名 / 一级切换的字面基线到各自盒底的距离（p = 0）。
  final double titleBaseline;
  final Size badge;
  final Size switcher;
  final double switchBaseline;
  final Size actions;
  final Size primary;

  /// 二级页签（含上下各 [_kSegmentHitBand] 的透明命中带）。
  final Size secondary;

  bool get hasSecondary => secondary.height > 0;

  double titleScaleAt(double p) =>
      _titleFontAt(compact: compact, p: p) /
      _titleFontAt(compact: compact, p: 0);
  double switchScaleAt(double p) =>
      _switchFontAt(compact: compact, p: p) /
      _switchFontAt(compact: compact, p: 0);
  double badgeScaleAt(double p) =>
      fushiMastheadBadgeExtent(compact: compact, p: p) /
      fushiMastheadBadgeExtent(compact: compact);

  /// 面板上内边距：桌面 26 → 10；手机的状态栏由外壳让开，只留 8。
  double topPadAt(double p) => compact ? 8 : _lerp(26, 10, p);

  /// 徽标 / 一级切换（无页名时）/ 动作组与主按钮的下边距。
  double badgeLiftAt(double p) => compact ? 6 : _lerp(12, 3, p);
  double switchLiftAt(double p) => compact ? 6 : _lerp(11, 3, p);
  double actionLiftAt(double p) => compact ? 2 : _lerp(8, 2, p);

  /// 一级切换的底边离第一行底边的距离：有页名时按字面基线对齐页名，否则按
  /// 设计稿下边距。
  double switchBottomLiftAt(double p) {
    if (title.height <= 0) return switchLiftAt(p);
    return math.max(
      0.0,
      titleBaseline * titleScaleAt(p) - switchBaseline * switchScaleAt(p),
    );
  }

  /// 页名与徽标、徽标（或页名）与一级切换、动作组与主按钮之间的间距。
  double get titleBadgeGap => compact ? 8 : 12;
  double get toSwitchGap => compact ? 8 : 20;
  double get actionsPrimaryGap => compact ? 8 : 12;
  static const double leadingGap = 8;

  double firstRowHeightAt(double p) {
    double h = 0;
    if (leading.height > 0) h = math.max(h, leading.height + actionLiftAt(p));
    if (title.height > 0) h = math.max(h, title.height * titleScaleAt(p));
    if (badge.height > 0) {
      h = math.max(h, badge.height * badgeScaleAt(p) + badgeLiftAt(p));
    }
    if (switcher.height > 0) {
      h = math.max(
        h,
        switcher.height * switchScaleAt(p) + switchBottomLiftAt(p),
      );
    }
    if (actions.height > 0) h = math.max(h, actions.height + actionLiftAt(p));
    if (primary.height > 0) h = math.max(h, primary.height + actionLiftAt(p));
    return h;
  }

  /// 第一、二行之间：设计稿 14 → 8，减去二级页签自带的上命中带。
  double rowGapAt(double p) =>
      math.max(0.0, _lerp(14, 8, p) - _kSegmentHitBand);

  /// 面板下内边距：桌面 12、手机 8（二级页签的下命中带算在里面）。
  double get bottomPad =>
      (compact ? 8 : 12) - (hasSecondary ? _kSegmentHitBand : 0);

  double secondaryTopAt(double p) =>
      topPadAt(p) + firstRowHeightAt(p) + rowGapAt(p);

  /// 进度 [p] 下页头实际画出来的高度（页头底板画到这里）。
  double visibleHeightAt(double p) =>
      topPadAt(p) +
      firstRowHeightAt(p) +
      (hasSecondary ? rowGapAt(p) + secondary.height : 0) +
      bottomPad;

  /// 版面高度（恒为展开态）。
  double get layoutHeight => visibleHeightAt(0);

  /// 进度 [p] 下页头比展开态少画的那段高度。
  double collapseAt(double p) =>
      math.max(0.0, layoutHeight - visibleHeightAt(p));

  @override
  bool operator ==(Object other) =>
      other is FushiMastheadGeometry &&
      other.compact == compact &&
      other.width == width &&
      other.leading == leading &&
      other.title == title &&
      other.titleBaseline == titleBaseline &&
      other.badge == badge &&
      other.switcher == switcher &&
      other.switchBaseline == switchBaseline &&
      other.actions == actions &&
      other.primary == primary &&
      other.secondary == secondary;

  @override
  int get hashCode => Object.hash(
    compact,
    width,
    leading,
    title,
    titleBaseline,
    badge,
    switcher,
    switchBaseline,
    actions,
    primary,
    secondary,
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
const double _kSegmentPressedPadding = 22;

/// 换页签 / 换页名时的入场位移（逻辑 px）：小幅位移 + 淡入，不做大幅滑动。
const double _kMastheadEnterTravel = 28;

/// 页名大字：字重 900、字距 -0.045em、行高 0.98；宽窗 84 / 窄窗 46（滚动收缩
/// 由绘制层缩放，这里是展开态字号）。
TextStyle fushiMastheadTitleStyle(
  BuildContext context, {
  required bool compact,
}) {
  final ThemeData theme = Theme.of(context);
  final double size = _titleFontAt(compact: compact, p: 0);
  return (theme.textTheme.displayLarge ?? const TextStyle()).copyWith(
    fontSize: size,
    fontWeight: FontWeight.w900,
    letterSpacing: -0.045 * size,
    height: 0.98,
    leadingDistribution: TextLeadingDistribution.even,
    color: fushiMastheadPaletteOf(context).ink,
  );
}

/// 一级切换顶替页名当标题时（[FushiMastheadSwitchHeadline]）选中项 / 未选项的
/// 字号：选中项放大到接近窄窗页名，未选项收小——大小差本身就说明「现在在哪」
/// （2026-11-12 用户）。
const double kFushiMastheadHeadlineSelectedFont = 38;
const double kFushiMastheadHeadlineIdleFont = 22;

/// 一级切换大字：宽窗 30 / 窄窗 19，字重 900、字距 -0.03em（各项同字重，切换
/// 时宽度不跳）。[fontSize] 覆盖字号（标题形态的选中项 / 未选项）。
TextStyle fushiMastheadSwitchStyle(
  BuildContext context, {
  required bool compact,
  double? fontSize,
}) {
  final ThemeData theme = Theme.of(context);
  final double size = fontSize ?? _switchFontAt(compact: compact, p: 0);
  return (theme.textTheme.headlineMedium ?? const TextStyle()).copyWith(
    fontSize: size,
    fontWeight: FontWeight.w900,
    letterSpacing: -0.03 * size,
    height: 1,
    leadingDistribution: TextLeadingDistribution.even,
    color: fushiMastheadPaletteOf(context).ink,
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

/// 一行文字的基线到行盒底边的距离（让两种字号的大字按基线对齐）。
double fushiMastheadBaselineFromBottom(
  BuildContext context,
  String text,
  TextStyle style,
) {
  final TextPainter painter = TextPainter(
    text: TextSpan(text: text.isEmpty ? 'A' : text, style: style),
    textDirection: Directionality.of(context),
    textScaler: MediaQuery.textScalerOf(context),
    maxLines: 1,
  )..layout();
  final double baseline = painter.computeDistanceToActualBaseline(
    TextBaseline.alphabetic,
  );
  final double fromBottom = painter.height - baseline;
  painter.dispose();
  return fromBottom;
}

/// 连体按钮组（二级页签）的文字：labelMedium 字阶、w800。
TextStyle fushiMastheadSegmentLabelStyle(BuildContext context) =>
    (Theme.of(context).textTheme.labelLarge ?? const TextStyle()).copyWith(
      fontSize: context.fushiType.labelMedium.fontSize,
      fontWeight: FontWeight.w800,
    );

/// 动作组每颗按钮的最小宽 / 高（命中区 48）与相邻间隙。
const double kFushiMastheadActionExtent = 48;
const double kFushiMastheadActionGap = 3;

/// 页头大字顶栏右侧的动作组：按钮平铺、不垫胶囊底（用户 2026-11-12「去掉
/// 胶囊」），悬停 / 按压 / 焦点反馈由按钮本体自己画。这里只给每颗 48 的最小
/// 命中区与间隙。[items] 是已经按宽度收过「⋯」的结果（见
/// `FushiShellHeaderActions`）。
class FushiMastheadActionGroup extends StatelessWidget {
  const FushiMastheadActionGroup({required this.items, super.key});

  final List<Widget> items;

  @override
  Widget build(BuildContext context) {
    return Row(
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
class FushiMastheadTitle extends StatelessWidget {
  const FushiMastheadTitle({
    required this.title,
    required this.compact,
    super.key,
  });

  final String title;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final FushiMotionScheme motion = context.fushiMotion;
    // container：页名自己成一个语义节点。不成节点的话「书架」这个 label 会一路
    // 向上并进外壳的手势 / 焦点节点（与侧栏、页签争成兄弟合并组），换页或
    // 重排时框架复用这些共享节点就会断言 `!child.attached`。
    return Semantics(
      container: true,
      header: true,
      child: AnimatedSwitcher(
        duration: motion.spatialSlow.duration,
        reverseDuration: motion.effectsFast.duration,
        layoutBuilder: (Widget? current, List<Widget> previous) => Stack(
          alignment: AlignmentDirectional.bottomStart,
          children: <Widget>[...previous, if (current != null) current],
        ),
        transitionBuilder: (Widget child, Animation<double> animation) =>
            _mastheadEnter(context, animation, child),
        child: Text(
          title,
          key: ValueKey<String>('fushi-masthead-title-$title'),
          maxLines: 1,
          softWrap: false,
          overflow: TextOverflow.ellipsis,
          style: fushiMastheadTitleStyle(context, compact: compact),
        ),
      ),
    );
  }
}

/// 一级切换写成大字：当前项 [FushiMastheadPalette.strong]、其余 onSurface 26%
/// （悬停 60%），项间「/」分隔。只接指针；键盘 / 手柄由外层
/// `FushiAdjustableSegmented` 的单个停靠点左右切换。
class FushiMastheadSwitch<T extends Object> extends StatelessWidget {
  const FushiMastheadSwitch({
    required this.tabs,
    required this.selected,
    required this.onChanged,
    super.key,
  });

  final List<LibrarySectionTab<T>> tabs;
  final T selected;
  final ValueChanged<T> onChanged;

  @override
  Widget build(BuildContext context) {
    final bool headline = FushiMastheadSwitchHeadline.of(context);
    final bool compact = fushiMastheadCompact(context) && !headline;
    final TextStyle style = fushiMastheadSwitchStyle(context, compact: compact);
    // 标题形态：选中项大、未选项小，按字面基线对齐；其余形态各项同字号。
    final TextStyle selectedStyle = headline
        ? fushiMastheadSwitchStyle(
            context,
            compact: false,
            fontSize: kFushiMastheadHeadlineSelectedFont,
          )
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
    // 窄窗下本段会被压到比自然宽窄（见 `_RenderMastheadLayout.performLayout`）：
    // 整段等比缩小到放得下，不横滑——两三个字的切换还要拖着看另一半很反直觉，
    // 也不能任它画到右边的动作按钮底下。放得下时原样大小。
    return FittedBox(
      fit: BoxFit.scaleDown,
      alignment: AlignmentDirectional.bottomStart,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        // 标题形态各项字号不同：按字面基线对齐（同字号时与底对齐等价）。
        crossAxisAlignment: headline
            ? CrossAxisAlignment.baseline
            : CrossAxisAlignment.end,
        textBaseline: TextBaseline.alphabetic,
        children: <Widget>[
          for (int i = 0; i < tabs.length; i++) ...<Widget>[
            if (i > 0)
              ExcludeSemantics(
                child: Padding(
                  padding: EdgeInsets.symmetric(horizontal: separatorPad),
                  child: Text('/', style: separatorStyle),
                ),
              ),
            _MastheadSwitchItem(
              label: tabs[i].label,
              labelKey: tabs[i].labelKey,
              selected: tabs[i].value == selected,
              style: tabs[i].value == selected ? selectedStyle : idleStyle,
              onTap: () {
                if (tabs[i].value != selected) onChanged(tabs[i].value);
              },
            ),
          ],
        ],
      ),
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
  });

  final String label;
  final Key? labelKey;
  final bool selected;
  final TextStyle style;
  final VoidCallback onTap;

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
                maxLines: 1,
                softWrap: false,
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
class FushiMastheadSegmentedTabs<T extends Object> extends StatefulWidget {
  const FushiMastheadSegmentedTabs({
    required this.tabs,
    required this.selected,
    required this.onChanged,
    super.key,
  });

  final List<LibrarySectionTab<T>> tabs;
  final T selected;
  final ValueChanged<T> onChanged;

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
              if (tabs[i].value != widget.selected) {
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
        behavior: ScrollConfiguration.of(context).copyWith(
          scrollbars: false,
          dragDevices: <PointerDeviceKind>{...PointerDeviceKind.values},
        ),
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: group,
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
  bool _pressed = false;

  void _setPressed(bool value) {
    if (_pressed == value) return;
    setState(() => _pressed = value);
  }

  BorderRadiusDirectional _radius() {
    if (widget.selected || (widget.first && widget.last)) {
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
    final double padding = _pressed
        ? _kSegmentPressedPadding
        : _kSegmentPadding;
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
          onExit: (_) => setState(() {
            _hovered = false;
            _pressed = false;
          }),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapDown: (_) => _setPressed(true),
            onTapUp: (_) => _setPressed(false),
            onTapCancel: () => _setPressed(false),
            onTap: widget.onTap,
            // 视觉 40、命中 48：上下各补 [_kSegmentHitBand] 的透明命中带。
            child: SizedBox(
              height: _kSegmentHitHeight,
              child: Center(
                child: AnimatedContainer(
                  duration: motion.effectsDefault.duration,
                  curve: motion.effectsDefault.curve,
                  height: _kSegmentHeight,
                  decoration: ShapeDecoration(
                    color: fill,
                    shape: shellShape(context, _radius()),
                  ),
                  child: AnimatedPadding(
                    duration: motion.spatialFast.duration,
                    curve: motion.spatialFast.curve,
                    padding: EdgeInsets.symmetric(horizontal: padding),
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
    );
  }
}

/// 页头大字顶栏右端的主按钮（库页「导入」）：高 56（窄窗 48）、圆角 20、底
/// [FushiMastheadPalette.indicator]、图标 onIndicator；悬停 / 选中时圆角弹到 28。
/// 按钮本体由调用方给的 [builder] 按传入的形状 / 颜色 / 尺寸画（沿用原按钮的
/// 焦点、tooltip 与 Semantics）。
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

  @override
  Widget build(BuildContext context) {
    final FushiMotionScheme motion = context.fushiMotion;
    final double extent = fushiMastheadCompact(context) ? 48 : 56;
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

/// 页头底板（设计稿 `.cap-B .mast`）：内容滚到页头下面时，页面底色按进度
/// 铺到 90% 不透明 + 背后高斯模糊（sigma 按进度到 18），裁在底板矩形内；未
/// 滚动（p = 0）时不画底、不开模糊。系统「降低透明度」/「增强对比度」下不
/// 开模糊，退成不透明底色（按进度淡入）。
class FushiMastheadPanel extends StatelessWidget {
  const FushiMastheadPanel({
    required this.height,
    required this.progress,
    super.key,
  });

  /// 底板高度（含向上铺进外壳顶部安全区的那段）。
  final double height;

  /// 生效的收缩进度（已按动效开关取过档）。
  final double progress;

  @override
  Widget build(BuildContext context) {
    if (progress <= 0 || height <= 0) return const SizedBox.shrink();
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
