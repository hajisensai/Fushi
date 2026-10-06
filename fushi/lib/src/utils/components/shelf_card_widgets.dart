import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:material_ui/material_ui.dart';
import 'package:fushi/src/focus/fushi_focus_controller.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/components/fushi_design_tokens.dart';
import 'package:fushi/src/utils/components/fushi_hover_lift.dart';
import 'package:fushi/src/utils/components/fushi_material_components.dart';
import 'package:fushi/src/utils/components/fushi_motion_tokens.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/cover_image.dart';
import 'package:transparent_image/transparent_image.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_controls.dart';

/// 书架卡片 footer / 勾选圈 / 选中罩的共享实现。
///
/// 巡检（PR-3）发现 `series_shelf_card.dart` 与
/// `reader_history/card_widgets.part.dart` 各持一份逐行相同的 footer 与勾选圈
/// 手抄（两处 40px 标题 footer、三处圆形对勾、两处选中罩），本文件收口为共享
/// 组件；eink 主题的实心色替代（半透明 alpha 在墨水屏合成抖动灰）也只写在这里。

/// 书架卡片封面下方的固定高标题 footer（两行省略、居中、加粗 metadata 字号）。
///
/// 高度由调用方的 SizedBox 固定（书卡用 `kShelfTitleFooterHeight`，系列折叠卡
/// 用 [ShelfCardFooter.height]，二者同值），长书名换行不得撑动网格。
class ShelfCardFooter extends StatelessWidget {
  const ShelfCardFooter({required this.title, super.key});

  /// 与 `kShelfTitleFooterHeight` 同值的 footer 基准高（系列卡无法 import
  /// part-of 常量，挂在组件上共享）。这是**默认字号下的**高度，实际高度请用
  /// [heightFor]。
  static const double height = 40.0;

  /// 按当前文字缩放算出的 footer 高度，下限为基准的 [height]。
  ///
  /// BUG-1184：footer 高度原先是死的 40px，而里面要放两行 metadata 字号的书名。
  /// 默认字号下两行约 31px + 上内边距 4px 勉强塞得下；系统字号一放大（textScale
  /// ≥1.25，小屏用户很常见的设置）两行就要 43px 以上，第二行的下半截被 SizedBox
  /// 直接切掉——书名看起来像被咬了一口。卡片封面区是 [Expanded]，footer 变高只是
  /// 等量压缩封面、不会撑破网格，所以这里让高度跟着文字缩放走。
  static double heightFor(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final double lineHeight = textLineHeight(context, tokens.type.metadata);
    final double topPad = tokens.spacing.gap / 2;
    return math.max(height, topPad + lineHeight * 2 + kTextBlockSlack);
  }

  final String title;

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    // 封面即卡片（2026-10-04）：MD3 titleSmall 字重 w500、Apple semibold 主文字
    // 色。字号不变（footer 高度 [heightFor] 按 metadata 行高算，换字号会撑动
    // 网格）；居中排版是 TODO-455 定下的书架布局，不动。
    final bool apple = isGlassDesign(context) && !isEinkTheme(context);
    final TextStyle style = tokens.type.metadata.copyWith(
      color: apple ? appleColorsOf(context).label : tokens.surfaces.onSurface,
      fontWeight: apple ? FontWeight.w600 : FontWeight.w500,
    );
    return Padding(
      padding: EdgeInsetsDirectional.fromSTEB(
        tokens.spacing.gap * 0.75,
        tokens.spacing.gap / 2,
        tokens.spacing.gap * 0.75,
        0,
      ),
      child: Align(
        alignment: Alignment.topCenter,
        // TODO-2490：两行仍放不下的长书名，桌面悬停显示完整标题；触屏侧的全名
        // 兜底是长按菜单（MediaItemDialogFrame 标题已不限行）。
        child: ShelfTitleOverflowTooltip(
          title: title,
          style: style,
          maxLines: 2,
          child: Text(
            title,
            overflow: TextOverflow.ellipsis,
            maxLines: 2,
            textAlign: TextAlign.center,
            softWrap: true,
            style: style,
          ),
        ),
      ),
    );
  }
}

/// 多选态的圆形对勾（书卡封面左上角 / 合集行头 / 系列折叠卡共用）。
///
/// 点击穿透由内建 [IgnorePointer] 保证（勾选切换走卡片/行头自身的 onTap）。
/// eink：未选中底色不再用 `page.withValues(alpha: 0.7)`（半透明在墨水屏合成
/// 抖动中间灰），改实心页面色 + 描边。
class ShelfSelectionCheck extends StatelessWidget {
  const ShelfSelectionCheck({required this.selected, super.key});

  final bool selected;

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final ThemeData theme = Theme.of(context);
    final bool eink = isEinkTheme(context);
    // Apple（iOS 照片的多选圈）：未选中 = 白色细环的空心圆（内部透明，封面
    // 直接透出来）+ 一圈淡投影把白环从浅色封面上托出来；选中 = 强调色实心圆
    // + onAccent 勾（环同强调色，实心圆没有第二道白边）。结构与 MD3 相同
    // （同一个 Container + 图标），只换颜色。
    final bool apple = isGlassDesign(context) && !eink;
    final FushiAppleColors palette = appleColorsOf(context);
    final Color selectionColor = apple ? palette.accent : tokens.surfaces.primary;
    final Color idleFill = eink
        ? tokens.surfaces.page
        : apple
            ? Colors.transparent
            : tokens.surfaces.page.withValues(alpha: 0.7);
    final Color ringColor = apple
        ? (selected ? selectionColor : Colors.white)
        : selected
            ? selectionColor
            : tokens.surfaces.outline;
    final Color checkColor = apple ? palette.onAccent : theme.colorScheme.onPrimary;
    return IgnorePointer(
      child: Container(
        decoration: BoxDecoration(
          color: selected ? selectionColor : idleFill,
          shape: BoxShape.circle,
          border: Border.all(color: ringColor, width: 1.5),
          boxShadow: apple
              ? const <BoxShadow>[
                  BoxShadow(color: Color(0x40000000), blurRadius: 4),
                ]
              : null,
        ),
        padding: EdgeInsets.all(tokens.spacing.gap / 4),
        child: FushiIcon(
          Icons.check,
          size: tokens.spacing.gap * 1.75,
          color: selected ? checkColor : Colors.transparent,
        ),
      ),
    );
  }
}

/// 选中态封面覆盖罩（书卡 / 视频卡 / 合集卡共用），配 `Positioned.fill` 压在
/// 封面上使用，圆角与 [ShelfCoverFrame] 一致（[shelfCoverRadius]）。
///
/// - MD3：primary 3px 内描边 + primary 8% 淡罩（选中信号是描边 + 勾选圈，不是
///   整块 tonal 色）；
/// - Apple（iOS 照片多选）：封面轻微压暗（黑 22%），选中信号在强调色勾选圈上
///   ——单色强调色在浅色下是黑，强调色罩读作脏灰；
/// - 墨水屏：半透明罩合成抖动灰且 primary 已塌缩，改 2px 实心描边作唯一选中
///   信号（与 FushiCard eink 选中态同语义）。
class ShelfSelectedOverlay extends StatelessWidget {
  const ShelfSelectedOverlay({super.key});

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final bool eink = isEinkTheme(context);
    final bool apple = isGlassDesign(context) && !eink;
    final BorderRadius radius = shelfCoverRadius(context);
    final BoxDecoration decoration;
    if (eink) {
      decoration = BoxDecoration(
        border: Border.all(color: tokens.surfaces.outline, width: 2),
        borderRadius: radius,
      );
    } else if (apple) {
      decoration = BoxDecoration(
        color: Colors.black.withValues(alpha: 0.22),
        borderRadius: radius,
      );
    } else {
      final Color primary = Theme.of(context).colorScheme.primary;
      decoration = BoxDecoration(
        color: primary.withValues(alpha: 0.08),
        border: Border.all(color: primary, width: 3),
        borderRadius: radius,
      );
    }
    return IgnorePointer(child: DecoratedBox(decoration: decoration));
  }
}

/// 封面圆角：MD3 Expressive medium（12）、Apple 10（Apple Books / TV 的封面
/// 比分组卡片小一号）。封面框、选中罩、封面卡状态层共用这一份。
///
/// 祖先有 [ShelfCoverRadiusScope] 时以它为准（游戏卡局部改成 20，书 / 视频库
/// 共享的封面组件不受影响）。
BorderRadius shelfCoverRadius(BuildContext context) {
  final BorderRadius? scoped = ShelfCoverRadiusScope.maybeOf(context);
  if (scoped != null) return scoped;
  final bool apple = isGlassDesign(context) && !isEinkTheme(context);
  return BorderRadius.all(Radius.circular(apple ? 10 : 12));
}

/// 局部覆盖 [shelfCoverRadius]：子树里的封面框 / 选中罩 / 无封面占位全部换成
/// [radius]。只给需要不同封面形状的卡族用（如游戏海报卡），不传参改共享组件。
class ShelfCoverRadiusScope extends InheritedWidget {
  const ShelfCoverRadiusScope({
    required this.radius,
    required super.child,
    super.key,
  });

  final BorderRadius radius;

  static BorderRadius? maybeOf(BuildContext context) => context
      .dependOnInheritedWidgetOfExactType<ShelfCoverRadiusScope>()
      ?.radius;

  @override
  bool updateShouldNotify(ShelfCoverRadiusScope oldWidget) =>
      oldWidget.radius != radius;
}

/// 封面卡标题样式（视频墙卡 / 横滚卡 / 远端卡 / 合集卡共用）：字号与行高沿用
/// bodyMedium（文字块高度按它的行高算，换字号会撑动网格），只换字重与颜色——
/// MD3 = titleSmall 口径的 w500 onSurface，Apple = semibold 主文字色。
TextStyle shelfCardTitleStyle(BuildContext context) {
  final ThemeData theme = Theme.of(context);
  final TextStyle base = theme.textTheme.bodyMedium ?? const TextStyle();
  if (isGlassDesign(context) && !isEinkTheme(context)) {
    return base.copyWith(
      color: appleColorsOf(context).label,
      fontWeight: FontWeight.w600,
    );
  }
  return base.copyWith(
    color: theme.colorScheme.onSurface,
    fontWeight: FontWeight.w500,
  );
}

/// 封面即卡片的外壳：返回一张**底色透明、无整卡描边、不裁剪**的 [FushiCard]。
/// 点击 / 长按 / 右键 / 焦点 / ActivateIntent / 按压下沉 / 状态层全部沿用
/// FushiCard，返回类型也仍是 [FushiCard]（调用点与测试按类型找卡不受影响）。
/// 视觉交给卡内的 [ShelfCoverFrame]：封面自带圆角 / 投影 / 内描边，标题直接
/// 落在页面底上（MD3 Expressive 与 Apple Books / TV 的封面卡都没有色块底）。
///
/// 选中态不再上整卡色块 / 描边——选中信号统一画在封面上
/// （[ShelfSelectedOverlay] + [ShelfSelectionCheck]），所以这里恒不选中。
FushiCard shelfCoverCard({
  required Widget child,
  Key? key,
  FushiFocusId? focusId,
  VoidCallback? onTap,
  VoidCallback? onLongPress,
  VoidCallback? onSecondaryTap,
  EdgeInsetsGeometry padding = EdgeInsets.zero,
  BorderRadius borderRadius = const BorderRadius.all(Radius.circular(12)),
}) {
  return FushiCard(
    key: key,
    focusId: focusId,
    padding: padding,
    color: Colors.transparent,
    borderColor: Colors.transparent,
    borderRadius: borderRadius,
    clipBehavior: Clip.none,
    onTap: onTap,
    onLongPress: onLongPress,
    onSecondaryTap: onSecondaryTap,
    child: child,
  );
}

/// 封面选中态广播：书架卡壳（`_bookCardShell`）不知道封面在卡里的哪一块，
/// 由它把多选态 / 选中位往下广播，卡内的 [ShelfCoverFrame] 把勾选圈与选中罩
/// 画在**封面上**（而不是连标题一起罩住整个卡槽）。视频卡在封面 Stack 里自己
/// 摆勾选圈与选中罩，不挂这一层。
class ShelfCoverSelection extends InheritedWidget {
  const ShelfCoverSelection({
    required this.selectionMode,
    required this.selected,
    required super.child,
    super.key,
  });

  /// 处于多选态且这张卡可勾选（显示勾选圈）。
  final bool selectionMode;

  /// 已选中（显示选中罩 + 实心勾）。
  final bool selected;

  static ShelfCoverSelection? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<ShelfCoverSelection>();

  @override
  bool updateShouldNotify(ShelfCoverSelection oldWidget) =>
      oldWidget.selectionMode != selectionMode ||
      oldWidget.selected != selected;
}

/// 封面框：「封面即卡片」的那块卡。
///
/// - MD3 Expressive：12 圆角、静止无投影（封面本身就是层次），悬停（祖先
///   [FushiHoverLift] 抬升时）加一档柔和投影；
/// - Apple：10 圆角 + 0.5px 低透明内描边（浅色黑 / 深色白，把浅色封面从页面底
///   上托出来）+ Apple Books / TV 式柔和投影，悬停投影加深；
/// - 墨水屏：无投影、无动效，1px 描边代替。
///
/// [backgroundColor] 是封面图没铺满时的衬底（书封 fitHeight 两侧几像素余量），
/// null = MD3 surfaceContainerHigh / Apple tertiaryFill / 墨水屏页面色。
/// 树结构恒定（投影 / 描边只换值，不按设计系统增删层）。
///
/// [stackedBehind] 非空 = 合集卡的叠层感：封面顶上让出 [kShelfCoverStackLift]，
/// 后面露出两层逐级内缩的「下一本」——MD3 是 surfaceContainerHighest / High 两层
/// 色块，Apple 是两层模糊压暗的同一张封面（Apple Music / Photos 相簿叠放），
/// 墨水屏是描边空层。是否叠层只取决于调用点（同一调用点恒定），不随主题增删。
class ShelfCoverFrame extends StatelessWidget {
  const ShelfCoverFrame({
    required this.child,
    this.backgroundColor,
    this.stackedBehind,
    super.key,
  });

  final Widget child;
  final Color? backgroundColor;

  /// 叠层用的封面图（不含角标），null = 单张封面。
  final Widget? stackedBehind;

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final ColorScheme cs = Theme.of(context).colorScheme;
    final bool eink = isEinkTheme(context);
    final bool apple = isGlassDesign(context) && !eink;
    final bool dark = cs.brightness == Brightness.dark;
    final bool lifted = !eink && FushiHoverLift.liftedOf(context);
    final BorderRadius radius = shelfCoverRadius(context);
    final ShelfCoverSelection? selection = ShelfCoverSelection.maybeOf(context);

    final List<BoxShadow> shadows;
    if (eink) {
      shadows = const <BoxShadow>[];
    } else if (apple) {
      shadows = <BoxShadow>[
        BoxShadow(
          color: Colors.black.withValues(
            alpha: lifted ? (dark ? 0.55 : 0.22) : (dark ? 0.40 : 0.12),
          ),
          blurRadius: lifted ? 22 : 10,
          offset: Offset(0, lifted ? 10 : 3),
        ),
      ];
    } else {
      shadows = <BoxShadow>[
        BoxShadow(
          color: cs.shadow.withValues(alpha: lifted ? 0.20 : 0),
          blurRadius: lifted ? 10 : 0,
          offset: Offset(0, lifted ? 4 : 0),
        ),
      ];
    }
    final BorderSide stroke = eink
        ? BorderSide(color: tokens.surfaces.outline)
        : apple
            ? BorderSide(
                color: dark
                    ? Colors.white.withValues(alpha: 0.14)
                    : Colors.black.withValues(alpha: 0.10),
                width: 0.5,
              )
            : BorderSide.none;
    final Color fill = backgroundColor ??
        (eink
            ? tokens.surfaces.page
            : apple
                ? appleColorsOf(context).tertiaryFill
                : cs.surfaceContainerHigh);
    final double checkInset = tokens.spacing.gap / 2;
    final Widget cover = AnimatedContainer(
      duration: fushiMotionDuration(context, FushiMotion.short),
      curve: FushiMotion.standard,
      decoration: BoxDecoration(borderRadius: radius, boxShadow: shadows),
      child: ClipRRect(
        borderRadius: radius,
        child: Stack(
          fit: StackFit.expand,
          children: <Widget>[
            ColoredBox(color: fill, child: child),
            IgnorePointer(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  borderRadius: radius,
                  border: Border.fromBorderSide(stroke),
                ),
              ),
            ),
            if (selection != null && selection.selected)
              const Positioned.fill(child: ShelfSelectedOverlay()),
            if (selection != null && selection.selectionMode)
              PositionedDirectional(
                top: checkInset,
                start: checkInset,
                child: ShelfSelectionCheck(selected: selection.selected),
              ),
          ],
        ),
      ),
    );
    final Widget? behind = stackedBehind;
    if (behind == null) return cover;
    const double step = kShelfCoverStackLift / 2;
    Widget layer(int depth) {
      final Color layerFill = eink
          ? tokens.surfaces.page
          : depth == 2
              ? cs.surfaceContainerHigh
              : cs.surfaceContainerHighest;
      return Positioned(
        top: kShelfCoverStackLift - step * depth,
        left: 8.0 * depth,
        right: 8.0 * depth,
        bottom: kShelfCoverStackLift,
        child: ClipRRect(
          borderRadius: radius,
          child: DecoratedBox(
            position: DecorationPosition.foreground,
            decoration: BoxDecoration(
              borderRadius: radius,
              border: Border.fromBorderSide(stroke),
              // Apple：模糊封面再压暗一档，越靠后越暗，读作「后面还有」。
              color: apple
                  ? Colors.black.withValues(alpha: depth == 2 ? 0.34 : 0.2)
                  : null,
            ),
            child: apple
                ? ImageFiltered(
                    imageFilter: ui.ImageFilter.blur(sigmaX: 6, sigmaY: 6),
                    child: behind,
                  )
                : ColoredBox(color: layerFill),
          ),
        ),
      );
    }

    return Stack(
      fit: StackFit.expand,
      clipBehavior: Clip.none,
      children: <Widget>[
        layer(2),
        layer(1),
        Positioned.fill(top: kShelfCoverStackLift, child: cover),
      ],
    );
  }
}

/// 合集叠层封面顶上让出的高度（两层各露 [kShelfCoverStackLift] / 2）。
const double kShelfCoverStackLift = 8;

/// 封面底边的观看 / 阅读进度条（配 `Positioned(left: 0, right: 0, bottom: 0)`
/// 使用）。书架书卡、视频库横排卡 / 墙卡、媒体服务器卡、首页继续观看卡共用，
/// 进度色与轨道只在这里写一次：
///
/// - MD3：贴封面底边的细线（YouTube 式），primary 进度 + 黑 35% 半透明轨道
///   （压在封面上任何颜色都看得见）；
/// - Apple：Apple TV「继续观看」式**内缩胶囊**——左右下各内缩 8、4px 高全圆角，
///   白色半透明轨道 + 强调色填充（单色强调色是黑时改白：黑条压在封面上不可读）；
/// - 墨水屏：半透明黑轨道压在封面上是抖动灰，改实心页面底色轨道 + 前景色
///   进度，黑白各一段、无灰阶。
///
/// [color] 覆写进度色（书架「已读完」的完成色）。树结构恒定：内缩与圆角只换
/// 数值（MD3 为 0），不按设计系统增删包装层。点击穿透（[IgnorePointer]）内建。
class CoverProgressStrip extends StatelessWidget {
  const CoverProgressStrip({
    required this.value,
    super.key,
    this.minHeight = 3,
    this.trackOpacity = 0.35,
    this.progressKey,
    this.color,
  });

  /// 进度 0–1。
  final double value;

  /// 条高（封面卡 3，大号继续观看卡 4）；Apple 胶囊至少 4。
  final double minHeight;

  /// 暗轨的黑色不透明度（MD3；墨水屏 / Apple 不用）。
  final double trackOpacity;

  /// 挂在内部进度指示器上的 key（测试按 key 读 value / minHeight）。
  final Key? progressKey;

  /// 进度色覆写（null = 设计系统默认）。
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final bool eink = isEinkTheme(context);
    final bool apple = isGlassDesign(context) && !eink;
    final Color appleAccent = appleColorsOf(context).accent;
    final Color appleFill =
        appleAccent.computeLuminance() < 0.05 ? Colors.white : appleAccent;
    final double height = apple ? math.max(minHeight, 4) : minHeight;
    return IgnorePointer(
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          apple ? 8 : 0,
          0,
          apple ? 8 : 0,
          apple ? 8 : 0,
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(apple ? height / 2 : 0),
          child: FushiLinearProgressIndicator(
            key: progressKey,
            value: value,
            minHeight: height,
            // MD3 封面上要的是一条贴底细线：Expressive 的波浪 + 轨道断口在
            // 3px 高的封面条上读作噪点（还会常驻动画），走平直的 2023 形态。
            year2023: apple ? null : true,
            backgroundColor: eink
                ? tokens.surfaces.page
                : apple
                    ? Colors.white.withValues(alpha: 0.38)
                    : Colors.black.withValues(alpha: trackOpacity),
            color: color ??
                (eink
                    ? tokens.surfaces.onSurface
                    : apple
                        ? appleFill
                        : Theme.of(context).colorScheme.primary),
          ),
        ),
      ),
    );
  }
}

/// 无封面占位（书架 / 视频库 / 游戏库共用）。
///
/// 柔和填充块（无描边）+ 居中单色图标，圆角与封面卡一致：MD3 = surfaceContainerHigh
/// 填充、onSurfaceVariant 图标；Apple = tertiaryFill 填充、tertiaryLabel 图标。
/// 巡检 B11 的「深色下占位与背景零对比」由填充色解决（比卡面高一阶），不再靠
/// 1px 描边。墨水屏保留描边、不填充（灰阶下填充会塌成和页面同色的灰块）。
/// [backgroundColor] 供调用方显式指定 MD3 / 墨水屏底色（Apple 下恒为
/// tertiaryFill）；[title] 非空时在图标下方显示两行标题（卡片自身没有标题
/// footer 的场景用）。
class ShelfCoverPlaceholder extends StatelessWidget {
  const ShelfCoverPlaceholder({
    required this.icon,
    this.iconSize = 40,
    this.backgroundColor,
    this.title,
    super.key,
  });

  final IconData icon;
  final double iconSize;
  final Color? backgroundColor;
  final String? title;

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final bool eink = isEinkTheme(context);
    final bool glass = isGlassDesign(context);
    final FushiAppleColors apple = appleColorsOf(context);
    // Apple 下恒为系统灰填充（内容层的占位就是 tertiaryFill，不随调用方的
    // MD3 容器色阶走）；MD3 / 墨水屏尊重调用方显式底色。
    final Color? fill = glass
        ? apple.tertiaryFill
        : backgroundColor ??
            (eink ? null : Theme.of(context).colorScheme.surfaceContainerHigh);
    final Color foreground =
        glass ? apple.tertiaryLabel : tokens.surfaces.onVariant;
    final String? label = title;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: fill,
        border: eink ? Border.all(color: tokens.surfaces.outline) : null,
        // 与封面框同形（MD3 12 / Apple 10），占位换成真封面时轮廓不跳。
        borderRadius: shelfCoverRadius(context),
      ),
      child: Center(
        child: label == null || label.isEmpty
            ? FushiIcon(icon, size: iconSize, color: foreground)
            : Padding(
                padding: EdgeInsets.all(tokens.spacing.gap),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    FushiIcon(icon, size: iconSize * 0.8, color: foreground),
                    SizedBox(height: tokens.spacing.gap / 2),
                    Text(
                      label,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.center,
                      style: tokens.type.metadata.copyWith(
                        color: glass
                            ? apple.secondaryLabel
                            : tokens.surfaces.onVariant,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
      ),
    );
  }
}

/// 本地文件封面的统一加载（书架 / 视频库 / 游戏库共用）。
///
/// BUG-959：一律经 [resizedFileImage] 降采样解码，避免原始封面（EPUB 常
/// 1600×2400、游戏包装图更大）整帧解码撑爆 ImageCache；FadeInImage 提供淡入与
/// 解码失败回退 [placeholder]。文件是否存在由调用方判定（各页对缺失文件的
/// 短路语义不同，不在此处吞）。
class ShelfFileCover extends StatelessWidget {
  const ShelfFileCover({
    required this.path,
    required this.placeholder,
    this.fit = BoxFit.cover,
    this.alignment = Alignment.center,
    super.key,
  });

  final String path;
  final Widget placeholder;
  final BoxFit fit;
  final Alignment alignment;

  @override
  Widget build(BuildContext context) {
    return FadeInImage(
      imageErrorBuilder: (_, __, ___) => placeholder,
      placeholder: MemoryImage(kTransparentImage),
      image: resizedFileImage(File(path)),
      alignment: alignment,
      fit: fit,
    );
  }
}

/// 卡片标题溢出提示（TODO-2490）：三库页卡片标题统一「最多两行 + 省略号」
/// （BUG-1184），但两行仍放不下的长名此前没有任何看全名的途径。本组件用与
/// 内部 [Text] 相同的 [style] / [maxLines] 先测量
/// （[TextPainter.didExceedMaxLines]，与 `fushi_marquee.dart` 的溢出探测同
/// 范式），**仅溢出时**才包 [Tooltip]：
///
/// - 桌面：鼠标悬停气泡显示完整标题；
/// - 触屏：不新造交互——`triggerMode: manual` 不注册点按/长按识别器，不与
///   卡片自身的长按菜单抢手势竞技场；长按菜单（`MediaItemDialogFrame`）标题
///   不限行，是触屏侧的看全名路径；
/// - 读屏：[Text] 语义本就携带完整字符串，`excludeFromSemantics` 避免重复播报。
class ShelfTitleOverflowTooltip extends StatelessWidget {
  const ShelfTitleOverflowTooltip({
    required this.title,
    required this.style,
    required this.maxLines,
    required this.child,
    super.key,
  });

  /// 完整标题（Tooltip 消息），与 [child] 里 Text 的 data 同源。
  final String title;

  /// 与 [child] 里 Text 相同的样式——测量必须同参，否则溢出判定失真。
  final TextStyle? style;

  /// 与 [child] 里 Text 相同的行数上限。
  final int maxLines;

  /// 实际渲染的标题 [Text]（省略号截断的那份）。
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        if (!constraints.hasBoundedWidth) return child;
        // 与 [Text] 相同的样式合成路径（inherit 时并入 DefaultTextStyle）。
        final TextStyle effective =
            DefaultTextStyle.of(context).style.merge(style);
        final TextPainter painter = TextPainter(
          text: TextSpan(text: title, style: effective),
          maxLines: maxLines,
          textDirection: Directionality.of(context),
          textScaler: MediaQuery.textScalerOf(context),
        )..layout(maxWidth: constraints.maxWidth);
        final bool overflowed = painter.didExceedMaxLines;
        painter.dispose();
        if (!overflowed) return child;
        return FushiTooltip(
          message: title,
          triggerMode: TooltipTriggerMode.manual,
          excludeFromSemantics: true,
          child: child,
        );
      },
    );
  }
}
