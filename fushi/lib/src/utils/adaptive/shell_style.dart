import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';

/// 宽屏侧栏样式（偏好 `shell_rail_style`，随 Profile 走）。只影响 MD3 侧栏；
/// Apple 设计系统的侧栏是 `AppleSidebarTabsShell`，不读这里。
enum ShellRailStyle {
  /// 镂空脊：侧栏贴边铺满高度，内容区左侧大圆角；当前项是一个与内容区连成
  /// 一体的缺口，换页时缺口带弹簧滑过去。
  notch('notch'),

  /// 色脊：悬浮的大圆角色块，当前项是专属多边形。
  spine('spine');

  const ShellRailStyle(this.prefValue);

  /// 落库的字符串（冻结，改名不改它）。
  final String prefValue;

  static const ShellRailStyle defaultStyle = notch;

  static ShellRailStyle fromPref(String? value) {
    for (final ShellRailStyle style in values) {
      if (style.prefValue == value) return style;
    }
    return defaultStyle;
  }
}

/// 库页内容布局（偏好 `shell_content_layout`，随 Profile 走）。
enum ShellContentLayout {
  /// 拼贴：封面色块 + 大字水印，首块加大，旁边叠两张半高卡。
  collage('collage'),

  /// 封面网格：重设计前的封面 + 标题网格。
  grid('grid');

  // 「规整色块」（落库值 `blocks`）2026-11-12 按用户拍板删掉：库页布局只剩拼贴与
  // 封面网格。已存的 `blocks` 不在 [values] 里，[fromPref] 落到 [defaultLayout]
  // （拼贴），偏好键与其余落库值不改。

  const ShellContentLayout(this.prefValue);

  /// 落库的字符串（冻结，改名不改它）。
  final String prefValue;

  static const ShellContentLayout defaultLayout = collage;

  /// 读偏好：未知值（含已删的 `blocks`）与没选过一律是 [defaultLayout]（拼贴）。
  static ShellContentLayout fromPref(String? value) {
    for (final ShellContentLayout layout in values) {
      if (layout.prefValue == value) return layout;
    }
    return defaultLayout;
  }
}

/// 色块的摆放（偏好 `shell_block_arrangement`，随 Profile 走）：只作用于色块布局
/// （拼贴，以及页面里固定排成等尺寸色块的分区），封面网格不受影响。
enum ShellBlockArrangement {
  /// 规整：行列对齐，不偏不转。
  aligned('aligned'),

  /// 交错：奇偶块一上一下、各转一点。
  staggered('staggered'),

  /// 散落：每块各自偏一点、转一点（按序号定，不随重建变）。
  scattered('scattered');

  const ShellBlockArrangement(this.prefValue);

  /// 落库的字符串（冻结，改名不改它）。
  final String prefValue;

  /// 没选过时跟着布局走：拼贴默认散落，其余默认规整。
  static ShellBlockArrangement defaultFor(ShellContentLayout layout) =>
      layout == ShellContentLayout.collage ? scattered : aligned;

  static ShellBlockArrangement fromPref(
    String? value, {
    required ShellContentLayout layout,
  }) {
    for (final ShellBlockArrangement arrangement in values) {
      if (arrangement.prefValue == value) return arrangement;
    }
    return defaultFor(layout);
  }
}

/// 外壳样式的 ThemeExtension 载体，与 [FushiGlassTheme] 同一写法：挂在
/// `buildFushiThemeData` 的 extensions 里，设置一改随主题重建到达所有消费端。
/// 消费端一律走本文件的 `shell*Of(context)`，不直接读偏好（页面测试不挂
/// ProviderScope 也能拿到默认值）。
@immutable
class FushiShellTheme extends ThemeExtension<FushiShellTheme> {
  const FushiShellTheme({
    this.railStyle = ShellRailStyle.defaultStyle,
    this.contentLayout = ShellContentLayout.defaultLayout,
    this.blockArrangement,
    this.smoothCorners = true,
  });

  final ShellRailStyle railStyle;
  final ShellContentLayout contentLayout;

  /// 色块摆放；null = 没选过，跟着 [contentLayout] 走
  /// （[ShellBlockArrangement.defaultFor]）。
  final ShellBlockArrangement? blockArrangement;

  /// 平滑圆角（连续曲率，superellipse）；false = 普通圆弧圆角。
  final bool smoothCorners;

  @override
  FushiShellTheme copyWith({
    ShellRailStyle? railStyle,
    ShellContentLayout? contentLayout,
    ShellBlockArrangement? blockArrangement,
    bool? smoothCorners,
  }) => FushiShellTheme(
    railStyle: railStyle ?? this.railStyle,
    contentLayout: contentLayout ?? this.contentLayout,
    blockArrangement: blockArrangement ?? this.blockArrangement,
    smoothCorners: smoothCorners ?? this.smoothCorners,
  );

  @override
  FushiShellTheme lerp(
    covariant ThemeExtension<FushiShellTheme>? other,
    double t,
  ) => this;

  @override
  bool operator ==(Object other) =>
      other is FushiShellTheme &&
      other.railStyle == railStyle &&
      other.contentLayout == contentLayout &&
      other.blockArrangement == blockArrangement &&
      other.smoothCorners == smoothCorners;

  @override
  int get hashCode =>
      Object.hash(railStyle, contentLayout, blockArrangement, smoothCorners);
}

/// 当前主题上的外壳样式；读不到扩展（测试裸 ThemeData）给默认值。
FushiShellTheme shellThemeOf(BuildContext context) =>
    Theme.of(context).extension<FushiShellTheme>() ?? const FushiShellTheme();

/// 重设计外壳（色块大字卡、页头大字）是否生效：MD3 与 Apple 设计系统都生效，
/// 只有墨水屏保持原有外壳（大面积色块 + 弹簧动效在墨水屏上只剩残影）。
/// 侧栏样式（镂空脊 / 色脊）另由侧栏自己限定在 MD3：Apple 设计系统的侧栏是
/// 系统风格的 `AppleSidebarTabsShell`。
bool shellRedesignActive(BuildContext context) => !isEinkTheme(context);

/// 生效的库页布局：重设计不生效时恒为 [ShellContentLayout.grid]。
ShellContentLayout shellContentLayoutOf(BuildContext context) =>
    shellRedesignActive(context)
    ? shellThemeOf(context).contentLayout
    : ShellContentLayout.grid;

/// 生效的色块摆放：没选过时跟着生效的布局走。
ShellBlockArrangement shellBlockArrangementOf(BuildContext context) =>
    shellThemeOf(context).blockArrangement ??
    ShellBlockArrangement.defaultFor(shellContentLayoutOf(context));

/// 平滑圆角下半径的放大系数：同半径的 superellipse 视觉上比圆弧「更方」，
/// 放大后与原圆角观感对齐。
const double kShellSmoothRadiusScale = 1.25;

/// 外壳组件的圆角形状：开了平滑圆角给 [RoundedSuperellipseBorder]（半径按
/// [kShellSmoothRadiusScale] 放大），否则 [RoundedRectangleBorder]。
OutlinedBorder shellShape(
  BuildContext context,
  BorderRadiusGeometry radius, {
  BorderSide side = BorderSide.none,
}) {
  if (shellThemeOf(context).smoothCorners) {
    return RoundedSuperellipseBorder(
      borderRadius: radius * kShellSmoothRadiusScale,
      side: side,
    );
  }
  return RoundedRectangleBorder(borderRadius: radius, side: side);
}

/// 按 [shellShape] 裁剪子树。
class ShellClip extends StatelessWidget {
  const ShellClip({required this.radius, required this.child, super.key});

  final BorderRadiusGeometry radius;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (shellThemeOf(context).smoothCorners) {
      return ClipRSuperellipse(
        borderRadius: radius * kShellSmoothRadiusScale,
        child: child,
      );
    }
    return ClipRRect(borderRadius: radius, child: child);
  }
}

/// 内容区上沿到窗口上沿之间、被外壳吃掉的那段顶部安全区（桌面自绘标题行、
/// 手机状态栏）的高度。内容区本身从这段之下开始布局，滚动内容也在那里被裁掉；
/// 页头的底板要一直铺到窗口上沿才不会在这条线上露出一道硬边，所以把高度下发
/// 给页头，由它向上多画这一段。
class ShellStageTopBleed extends InheritedWidget {
  const ShellStageTopBleed({
    required this.top,
    required super.child,
    super.key,
  });

  final double top;

  @override
  bool updateShouldNotify(ShellStageTopBleed oldWidget) => oldWidget.top != top;
}

/// 页头底板要向上多画的高度；外壳没装 [ShellStageTopBleed]（二级页、测试）为 0。
double shellStageTopBleedOf(BuildContext context) =>
    context.dependOnInheritedWidgetOfExactType<ShellStageTopBleed>()?.top ?? 0;

/// 外壳强调色（侧栏、页头共用）。
@immutable
class ShellAccentColors {
  const ShellAccentColors({
    required this.indicator,
    required this.onIndicator,
    required this.strong,
    required this.container,
    required this.onContainer,
  });

  /// 取 [scheme] 的 primary 一族。
  ShellAccentColors.fromScheme(ColorScheme scheme)
    : indicator = scheme.primary,
      onIndicator = scheme.onPrimary,
      strong = scheme.primary,
      container = scheme.primaryContainer,
      onContainer = scheme.onPrimaryContainer;

  /// 当前项指示器（多边形）的填充色。
  final Color indicator;

  /// 指示器上的图标色。
  final Color onIndicator;

  /// 页面底色上的强调文字色（选中的一级切换、选中的二级页签）。
  final Color strong;

  /// 侧栏色块底色。
  final Color container;

  /// 侧栏色块上的图标 / 文字色。
  final Color onContainer;
}

/// 外壳强调色（侧栏、页头）：恒取应用主题色，不随内容变色（2026-11-12 用户
/// 拍板砍掉「封面取色」）。
ShellAccentColors shellAccentOf(BuildContext context) =>
    ShellAccentColors.fromScheme(Theme.of(context).colorScheme);
