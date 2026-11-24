/// 音乐「推荐」（在线）Cupertino 版的公共件（设计稿
/// fushi/build/music_online_cupertino_design/index.html 方案 A，用户 2026-11-24
/// 拍板）：Apple Music「主页」式的段标题、横滑货架（iOS 按条吸附、macOS 悬停两端
/// 玻璃箭头）、平封面卡、来源胶囊、来源组头、分类块、胶囊按钮与首次加载骨架。
///
/// 只在 `isGlassDesign` 为真时由推荐页的 Apple 布局使用；M3E 推荐页不经过这里。
/// 尺寸取 [FushiAppleMetrics]（macOS 档乘 `fushiAppleMacScale`），颜色只取
/// [appleColorsOf] 的系统色令牌；封面一律连续曲率圆角（[ClipRSuperellipse]）。
library;

import 'dart:async';
import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/focus/fushi_focus_controller.dart' show FushiFocusId;
import 'package:fushi/src/pages/implementations/music/music_cover.dart';
import 'package:fushi/src/utils/components/fushi_design_tokens.dart';
import 'package:fushi/src/utils/components/fushi_focusable.dart';
import 'package:fushi/src/utils/components/fushi_header_more_button.dart';
import 'package:fushi/src/utils/components/fushi_hover_lift.dart';
import 'package:fushi/src/utils/components/fushi_motion_tokens.dart';
import 'package:fushi/src/utils/components/fushi_press_scale.dart';
import 'package:fushi/src/utils/components/glass/fushi_apple_palette.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_buttons.dart'
    show FushiIconButtonControl;
import 'package:fushi/src/utils/components/glass/fushi_glass_chips.dart'
    show fushiAppleChip;
import 'package:fushi/src/utils/components/glass/fushi_glass_lists.dart'
    show FushiAppleMetrics;
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/components/settings_shared.dart'
    show FushiAdjustableSegmented;
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/src/utils/misc/platform_utils.dart'
    show HorizontalDragScrollable;

/// 推荐页 Apple 版的页边距（左右）：货架贴着这条线起排、横滑时滑出到屏幕边。
double appleMusicPagePadding(BuildContext context) =>
    FushiDesignTokens.of(context).spacing.page;

/// 一段文字的 Apple 字样：去掉 MD3 字距，字号 / 字重 / 颜色由调用方给。
TextStyle appleMusicText(
  BuildContext context, {
  required double size,
  FontWeight weight = FontWeight.w400,
  Color? color,
  double height = 1.25,
}) => (Theme.of(context).textTheme.bodyMedium ?? const TextStyle()).copyWith(
  fontSize: size,
  fontWeight: weight,
  letterSpacing: 0,
  height: height,
  color: color ?? appleColorsOf(context).label,
);

/// 连续曲率圆角裁切（iOS / macOS 的 squircle 圆角）。
Widget appleMusicSquircle({
  required double radius,
  required Widget child,
  bool circular = false,
}) => circular
    ? ClipOval(child: child)
    : ClipRSuperellipse(
        borderRadius: BorderRadius.circular(radius),
        child: child,
      );

/// 一张方形封面：按显示尺寸解码（[MusicCover.size]），连续曲率圆角。
Widget appleMusicCover({
  required String? cover,
  required double size,
  required double radius,
  String? title,
  bool circular = false,
}) => SizedBox.square(
  dimension: size,
  child: appleMusicSquircle(
    radius: radius,
    circular: circular,
    child: MusicCover(
      coverPath: cover,
      size: size,
      title: title,
      borderRadius: BorderRadius.zero,
    ),
  ),
);

/// 段标题（Apple Music「主页」的 title2 粗体段名）：可选副标题；[onOpen] 非 null
/// 时标题后带一枚 tertiaryLabel 的 ›，整个标题是去「查看全部」的按钮。[trailing]
/// 是段头右侧的动作（如「播放」胶囊）。
class AppleMusicSectionHeader extends StatelessWidget {
  const AppleMusicSectionHeader({
    super.key,
    required this.title,
    this.subtitle,
    this.onOpen,
    this.openKey,
    this.trailing,
  });

  final String title;
  final String? subtitle;
  final VoidCallback? onOpen;

  /// 标题按钮的 key（测试与焦点驱动用）。
  final Key? openKey;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final FushiAppleMetrics m = FushiAppleMetrics.of(context);
    final FushiAppleColors c = appleColorsOf(context);
    final double k = m.scale;
    final double pad = appleMusicPagePadding(context);
    final TextStyle titleStyle = appleMusicText(
      context,
      size: (m.desktop ? 18 : 21) * k,
      weight: FontWeight.w700,
    );
    Widget titleRow = Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Flexible(
          child: Text(
            title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: titleStyle,
          ),
        ),
        if (onOpen != null)
          FushiIcon(
            FushiIcons.chevronRight,
            size: (m.desktop ? 15 : 18) * k,
            color: c.tertiaryLabel,
          ),
      ],
    );
    if (onOpen case final VoidCallback open) {
      titleRow = FushiPressScale(
        child: FushiFocusable(
          key: openKey,
          onTap: open,
          borderRadius: BorderRadius.circular(8),
          child: titleRow,
        ),
      );
    }
    return Padding(
      padding: EdgeInsets.fromLTRB(pad, 24 * k, pad, 8 * k),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: <Widget>[
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                titleRow,
                if (subtitle case final String s when s.isNotEmpty)
                  Padding(
                    padding: EdgeInsets.only(top: 2 * k),
                    child: Text(
                      s,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: appleMusicText(
                        context,
                        size: (m.desktop ? 12 : 13.5) * k,
                        color: c.secondaryLabel,
                      ),
                    ),
                  ),
              ],
            ),
          ),
          if (trailing case final Widget t) ...<Widget>[
            SizedBox(width: 8 * k),
            t,
          ],
        ],
      ),
    );
  }
}

/// 胶囊按钮：默认 fill 底、强调色字（段头「播放」）；压在取色大卡上时由调用方
/// 给 [background] / [foreground]（大卡的主操作反白、次要操作半透明）。
class AppleMusicCapsuleButton extends StatelessWidget {
  const AppleMusicCapsuleButton({
    super.key,
    required this.icon,
    required this.label,
    required this.onTap,
    this.background,
    this.foreground,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final Color? background;
  final Color? foreground;

  @override
  Widget build(BuildContext context) {
    final FushiAppleColors c = appleColorsOf(context);
    final double k = FushiAppleMetrics.of(context).scale;
    final Color bg = background ?? c.fill;
    final Color fg = foreground ?? c.accent;
    final BorderRadius radius = BorderRadius.circular(15 * k);
    return FushiPressScale(
      child: FushiFocusable(
        onTap: onTap,
        borderRadius: radius,
        ringPosition: DecorationPosition.foreground,
        child: Semantics(
          button: true,
          label: label,
          excludeSemantics: true,
          child: Container(
            height: 30 * k,
            padding: EdgeInsets.symmetric(horizontal: 12 * k),
            decoration: BoxDecoration(color: bg, borderRadius: radius),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                FushiIcon(icon, size: 13 * k, color: fg, fill: 1),
                SizedBox(width: 5 * k),
                Text(
                  label,
                  style: appleMusicText(
                    context,
                    size: 13.5 * k,
                    weight: FontWeight.w600,
                    color: fg,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 横滑货架：懒构建（[ListView.builder] + 定宽 [itemExtent]），左右贴页边起排、
/// 滑出到屏幕边。iOS 档弹性滚动 + 按条吸附（[stride] = 单条宽 + 间距，歌曲分页列
/// 按整列）；macOS 档触控板横扫走原生惯性，鼠标悬停时两端淡入玻璃圆形箭头，点一下
/// 滚一屏、到头淡出。整排随段进场，内部不逐张错峰（Apple Music 不做）。
class AppleMusicShelf extends StatefulWidget {
  const AppleMusicShelf({
    super.key,
    required this.itemCount,
    required this.itemExtent,
    required this.height,
    required this.itemBuilder,
    this.spacing = 12,
    this.arrowCenter,
  });

  final int itemCount;

  /// 单条的宽（不含间距）。
  final double itemExtent;

  /// 货架高（条目的高）。
  final double height;
  final IndexedWidgetBuilder itemBuilder;
  final double spacing;

  /// macOS 箭头的竖直中心（默认货架正中；封面卡给封面中心）。
  final double? arrowCenter;

  @override
  State<AppleMusicShelf> createState() => _AppleMusicShelfState();
}

class _AppleMusicShelfState extends State<AppleMusicShelf> {
  final ScrollController _controller = ScrollController();
  bool _hovering = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _page(int direction) {
    if (!_controller.hasClients) return;
    final ScrollPosition p = _controller.position;
    final double stride = widget.itemExtent + widget.spacing;
    final double screen = math.max(
      stride,
      (p.viewportDimension / stride).floor() * stride,
    );
    final double target =
        (((p.pixels + direction * screen) / stride).roundToDouble() * stride)
            .clamp(p.minScrollExtent, p.maxScrollExtent);
    final Duration d = fushiMotionDuration(context, FushiMotion.medium);
    if (d == Duration.zero) {
      _controller.jumpTo(target);
    } else {
      unawaited(
        _controller.animateTo(target, duration: d, curve: FushiMotion.standard),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final FushiAppleMetrics m = FushiAppleMetrics.of(context);
    final double pad = appleMusicPagePadding(context);
    final double stride = widget.itemExtent + widget.spacing;
    final Widget list = HorizontalDragScrollable(
      child: ListView.builder(
        controller: _controller,
        scrollDirection: Axis.horizontal,
        clipBehavior: Clip.none,
        padding: EdgeInsets.symmetric(horizontal: pad),
        physics: m.desktop
            ? null
            : _AppleShelfSnapPhysics(
                stride: stride,
                parent: const BouncingScrollPhysics(),
              ),
        itemExtent: stride,
        itemCount: widget.itemCount,
        itemBuilder: (BuildContext context, int i) => Padding(
          padding: EdgeInsetsDirectional.only(end: widget.spacing),
          child: widget.itemBuilder(context, i),
        ),
      ),
    );
    Widget shelf = SizedBox(height: widget.height, child: list);
    if (!m.desktop) return shelf;
    final double center = widget.arrowCenter ?? widget.height / 2;
    final double size = 32 * m.scale;
    Widget arrow(int direction) => ListenableBuilder(
      listenable: _controller,
      builder: (BuildContext context, Widget? _) {
        final bool can =
            _controller.hasClients &&
            _controller.position.hasContentDimensions &&
            (direction < 0
                ? _controller.position.pixels >
                      _controller.position.minScrollExtent + 1
                : _controller.position.pixels <
                      _controller.position.maxScrollExtent - 1);
        final bool shown = _hovering && can;
        return IgnorePointer(
          ignoring: !shown,
          child: AnimatedOpacity(
            opacity: shown ? 1 : 0,
            duration: fushiMotionDuration(context, FushiMotion.short),
            curve: FushiMotion.standard,
            child: SizedBox.square(
              dimension: size,
              child: FushiIconButtonControl.filledTonal(
                key: ValueKey<String>(
                  'apple-music-shelf-${direction < 0 ? 'prev' : 'next'}',
                ),
                padding: EdgeInsets.zero,
                iconSize: 16 * m.scale,
                onPressed: () => _page(direction),
                icon: FushiIcon(
                  direction < 0
                      ? FushiIcons.chevronLeft
                      : FushiIcons.chevronRight,
                ),
              ),
            ),
          ),
        );
      },
    );
    shelf = MouseRegion(
      onEnter: (_) => setState(() => _hovering = true),
      onExit: (_) => setState(() => _hovering = false),
      child: Stack(
        clipBehavior: Clip.none,
        children: <Widget>[
          shelf,
          // 箭头只给鼠标用：键盘 / 手柄在条目间移焦时列表自己滚到焦点处。
          PositionedDirectional(
            start: pad / 2,
            top: center - size / 2,
            child: ExcludeFocus(child: ExcludeSemantics(child: arrow(-1))),
          ),
          PositionedDirectional(
            end: pad / 2,
            top: center - size / 2,
            child: ExcludeFocus(child: ExcludeSemantics(child: arrow(1))),
          ),
        ],
      ),
    );
    return shelf;
  }
}

/// iOS 档货架的按条吸附：松手后按速度外推一段，再落到最近的整条边界
/// （[stride]）。到两端交给父物理（弹性回弹）。
class _AppleShelfSnapPhysics extends ScrollPhysics {
  const _AppleShelfSnapPhysics({required this.stride, super.parent});

  final double stride;

  @override
  _AppleShelfSnapPhysics applyTo(ScrollPhysics? ancestor) =>
      _AppleShelfSnapPhysics(stride: stride, parent: buildParent(ancestor));

  @override
  Simulation? createBallisticSimulation(
    ScrollMetrics position,
    double velocity,
  ) {
    if ((velocity <= 0 && position.pixels <= position.minScrollExtent) ||
        (velocity >= 0 && position.pixels >= position.maxScrollExtent)) {
      return super.createBallisticSimulation(position, velocity);
    }
    final Tolerance tolerance = toleranceFor(position);
    // 惯性外推约 0.3 秒的位移（与系统减速的手感相近），再取最近的整条。
    final double projected = position.pixels + velocity * 0.3;
    final double target = ((projected / stride).roundToDouble() * stride).clamp(
      position.minScrollExtent,
      position.maxScrollExtent,
    );
    if ((target - position.pixels).abs() < tolerance.distance) return null;
    return ScrollSpringSimulation(
      spring,
      position.pixels,
      target,
      velocity,
      tolerance: tolerance,
    );
  }

  @override
  bool get allowImplicitScrolling => false;
}

/// 货架里的一张平封面卡：封面 + 标题 + 副行（Apple Music「最近播放 / 推荐歌单」）。
/// 按压缩放（[FushiPressScale]）、悬停抬升（[FushiHoverLift]，macOS 投影加深），
/// 键盘 / 手柄可聚焦、Enter 激活（[FushiFocusable]）。
class AppleMusicCoverTile extends StatelessWidget {
  const AppleMusicCoverTile({
    super.key,
    required this.title,
    required this.cover,
    required this.width,
    required this.onTap,
    this.subtitle,
    this.circular = false,
    this.subtitleTrailing,
  });

  final String title;
  final String? subtitle;
  final String? cover;
  final double width;
  final VoidCallback? onTap;

  /// 艺人：圆形头像、文字居中。
  final bool circular;

  /// 副行尾部的小件（如服务器试听角标）。
  final Widget? subtitleTrailing;

  /// [width] 宽的卡总高（封面 + 两行文字）。
  static double heightFor(BuildContext context, double width) {
    final double k = FushiAppleMetrics.of(context).scale;
    return width + 7 * k + 17 * k + 2 * k + 16 * k;
  }

  @override
  Widget build(BuildContext context) {
    final FushiAppleColors c = appleColorsOf(context);
    final double k = FushiAppleMetrics.of(context).scale;
    final double radius = 8 * k;
    final TextAlign align = circular ? TextAlign.center : TextAlign.start;
    final CrossAxisAlignment cross = circular
        ? CrossAxisAlignment.center
        : CrossAxisAlignment.start;
    return FushiHoverLift(
      builder: (BuildContext context, bool hovering) => FushiPressScale(
        child: FushiFocusable(
          onTap: onTap,
          borderRadius: BorderRadius.circular(radius),
          child: Column(
            crossAxisAlignment: cross,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              DecoratedBox(
                decoration: BoxDecoration(
                  shape: circular ? BoxShape.circle : BoxShape.rectangle,
                  borderRadius: circular ? null : BorderRadius.circular(radius),
                  boxShadow: <BoxShadow>[
                    BoxShadow(
                      color: Colors.black.withValues(
                        alpha: hovering ? 0.22 : 0.08,
                      ),
                      blurRadius: hovering ? 16 : 6,
                      offset: Offset(0, hovering ? 6 : 2),
                    ),
                  ],
                ),
                child: appleMusicCover(
                  cover: cover,
                  size: width,
                  radius: radius,
                  title: title,
                  circular: circular,
                ),
              ),
              SizedBox(height: 7 * k),
              Text(
                title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: align,
                style: appleMusicText(
                  context,
                  size: 13 * k,
                  weight: FontWeight.w500,
                ),
              ),
              if (subtitle case final String s when s.isNotEmpty)
                Padding(
                  padding: EdgeInsets.only(top: 2 * k),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      Flexible(
                        child: Text(
                          s,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          textAlign: align,
                          style: appleMusicText(
                            context,
                            size: 12 * k,
                            color: c.secondaryLabel,
                          ),
                        ),
                      ),
                      if (subtitleTrailing case final Widget tr) ...<Widget>[
                        SizedBox(width: 4 * k),
                        tr,
                      ],
                    ],
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 一枚来源胶囊的要素。[relayed] = 经互联中继的插件（胶囊尾带一枚「电脑」小标）。
typedef AppleMusicSourcePill = ({
  String value,
  String label,
  Key labelKey,
  bool relayed,
});

/// 推荐页大标题下的来源胶囊行（全部 / 各插件 / 各服务器）：与库页分区胶囊
/// （`AppleLibraryScopeBar`）同一套外观——选中反白（label 实底 + 背景色字）、其余
/// tertiaryFill 灰胶囊，放不下整行横滑。焦点契约与 M3E 来源页签相同：整排一个
/// 焦点停靠点（[FushiAdjustableSegmented]），左右方向键 / 手柄原地切来源。
class AppleMusicSourcePills extends StatelessWidget {
  const AppleMusicSourcePills({
    super.key,
    required this.pills,
    required this.selected,
    required this.onSelect,
    required this.focusIdPrefix,
  });

  final List<AppleMusicSourcePill> pills;
  final String selected;
  final ValueChanged<String> onSelect;
  final String focusIdPrefix;

  @override
  Widget build(BuildContext context) {
    final FushiAppleColors apple = appleColorsOf(context);
    final FushiAppleMetrics m = FushiAppleMetrics.of(context);
    final double gap = (m.desktop ? 6 : 8) * m.scale;
    final List<String> values = <String>[
      for (final AppleMusicSourcePill p in pills) p.value,
    ];
    final String current = values.contains(selected) ? selected : values.first;
    final Widget row = SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      clipBehavior: Clip.none,
      child: Row(
        children: <Widget>[
          for (int i = 0; i < pills.length; i++) ...<Widget>[
            if (i > 0) SizedBox(width: gap),
            FushiPressScale(
              child: KeyedSubtree(
                key: pills[i].labelKey,
                child: AnimatedSwitcher(
                  duration: fushiMotionDuration(context, FushiMotion.short),
                  switchInCurve: FushiMotion.standard,
                  switchOutCurve: FushiMotion.standard,
                  child: KeyedSubtree(
                    key: ValueKey<bool>(pills[i].value == current),
                    child: _pill(context, pills[i], current, apple),
                  ),
                ),
              ),
            ),
          ],
        ],
      ),
    );
    return FushiAdjustableSegmented<String>(
      values: values,
      selected: current,
      onChanged: onSelect,
      focusIdPrefix: focusIdPrefix,
      focusId: FushiFocusId('$focusIdPrefix-sources'),
      child: row,
    );
  }

  Widget _pill(
    BuildContext context,
    AppleMusicSourcePill p,
    String current,
    FushiAppleColors apple,
  ) {
    final bool selected = p.value == current;
    return fushiAppleChip(
      context,
      label: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Text(p.label),
          if (p.relayed) ...<Widget>[
            const SizedBox(width: 5),
            FushiIcon(
              FushiIcons.laptop,
              size: 13,
              color: selected
                  ? apple.groupedBackground.withValues(alpha: 0.7)
                  : apple.secondaryLabel,
            ),
          ],
        ],
      ),
      onTap: () {
        if (!selected) onSelect(p.value);
      },
      selected: selected,
      selectedColor: apple.label,
      focusable: false,
    );
  }
}

/// 「全部」里一个来源组的组头（Apple Music 的 eyebrow）：小号大写来源名、经中继的
/// 灰字「经 <设备>」，尾部「⋯」（私人电台 / 刷新 / 来源设置）。
class AppleMusicSourceGroupHeader extends StatelessWidget {
  const AppleMusicSourceGroupHeader({
    super.key,
    required this.name,
    required this.menuKey,
    required this.entries,
    this.via,
  });

  final String name;

  /// 经中继时的那一行灰字（已本地化，如「经 我的电脑」）；本机插件为 null。
  final String? via;
  final Key menuKey;
  final List<FushiHeaderMoreEntry> entries;

  @override
  Widget build(BuildContext context) {
    final FushiAppleColors c = appleColorsOf(context);
    final FushiAppleMetrics m = FushiAppleMetrics.of(context);
    final double k = m.scale;
    final double pad = appleMusicPagePadding(context);
    return Padding(
      padding: EdgeInsetsDirectional.fromSTEB(pad, 30 * k, pad / 2, 0),
      child: Row(
        children: <Widget>[
          Flexible(
            child: Text(
              name.toUpperCase(),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: appleMusicText(
                context,
                size: 12.5 * k,
                weight: FontWeight.w600,
                color: c.secondaryLabel,
              ).copyWith(letterSpacing: 0.4),
            ),
          ),
          if (via case final String v) ...<Widget>[
            SizedBox(width: 6 * k),
            Text(
              '· $v',
              maxLines: 1,
              style: appleMusicText(
                context,
                size: 11 * k,
                weight: FontWeight.w500,
                color: c.tertiaryLabel,
              ),
            ),
          ],
          const Spacer(),
          if (entries.isNotEmpty)
            FushiHeaderMoreButton(buttonKey: menuKey, entries: entries),
        ],
      ),
    );
  }
}

/// 「浏览分类」横滑里的一块（Apple「按类别浏览」）：连续曲率圆角块，左下角粗体
/// 类名、右上一枚斜放的图标。[emphasized]（「全部作品」）是强调色实底，其余是
/// tertiaryFill 中性底——只用系统色令牌。
class AppleMusicCategoryTile extends StatelessWidget {
  const AppleMusicCategoryTile({
    super.key,
    required this.label,
    required this.icon,
    required this.onTap,
    this.emphasized = false,
  });

  final String label;
  final IconData icon;
  final VoidCallback onTap;
  final bool emphasized;

  @override
  Widget build(BuildContext context) {
    final FushiAppleColors c = appleColorsOf(context);
    final double k = FushiAppleMetrics.of(context).scale;
    final Color bg = emphasized ? c.accent : c.tertiaryFill;
    final Color fg = emphasized ? c.onAccent : c.label;
    final double radius = 14 * k;
    return FushiHoverLift(
      builder: (BuildContext context, bool hovering) => FushiPressScale(
        child: FushiFocusable(
          onTap: onTap,
          borderRadius: BorderRadius.circular(radius),
          ringPosition: DecorationPosition.foreground,
          child: Semantics(
            button: true,
            label: label,
            excludeSemantics: true,
            child: appleMusicSquircle(
              radius: radius,
              child: ColoredBox(
                color: bg,
                child: Stack(
                  children: <Widget>[
                    PositionedDirectional(
                      end: 10 * k,
                      top: 10 * k,
                      child: Transform.rotate(
                        angle: 18 * math.pi / 180,
                        child: FushiIcon(
                          icon,
                          size: 34 * k,
                          color: (emphasized ? fg : c.accent).withValues(
                            alpha: 0.85,
                          ),
                        ),
                      ),
                    ),
                    PositionedDirectional(
                      start: 12 * k,
                      end: 12 * k,
                      bottom: 10 * k,
                      child: Text(
                        label,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: appleMusicText(
                          context,
                          size: 16 * k,
                          weight: FontWeight.w700,
                          color: fg,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 首次加载的骨架（不转圈）：继续收听条、两张精选高卡、一排封面。刷新时旧内容
/// 留着，不出骨架。
class AppleMusicRecommendSkeleton extends StatelessWidget {
  const AppleMusicRecommendSkeleton({super.key});

  @override
  Widget build(BuildContext context) {
    final FushiAppleColors c = appleColorsOf(context);
    final FushiAppleMetrics m = FushiAppleMetrics.of(context);
    final double k = m.scale;
    final double pad = appleMusicPagePadding(context);
    final double top = MediaQuery.paddingOf(context).top;
    Widget box(double w, double h, {double r = 12}) => Container(
      width: w,
      height: h,
      decoration: ShapeDecoration(
        color: c.fill,
        shape: RoundedSuperellipseBorder(
          borderRadius: BorderRadius.circular(r * k),
        ),
      ),
    );
    Widget title() => Padding(
      padding: EdgeInsets.fromLTRB(pad, 24 * k, pad, 10 * k),
      child: Align(
        alignment: AlignmentDirectional.centerStart,
        child: box(120 * k, 20 * k, r: 6),
      ),
    );
    final double pick = (m.desktop ? 186 : 250) * k;
    return ExcludeSemantics(
      child: SingleChildScrollView(
        key: const ValueKey<String>('music-plugin-recommend-skeleton'),
        physics: const NeverScrollableScrollPhysics(),
        padding: EdgeInsets.only(top: top + 8 * k),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            title(),
            SizedBox(
              height: pick * 1.36,
              child: ListView(
                scrollDirection: Axis.horizontal,
                physics: const NeverScrollableScrollPhysics(),
                padding: EdgeInsets.symmetric(horizontal: pad),
                children: <Widget>[
                  for (int i = 0; i < 4; i++) ...<Widget>[
                    box(pick, pick * 1.36, r: 16),
                    SizedBox(width: 12 * k),
                  ],
                ],
              ),
            ),
            title(),
            SizedBox(
              height: 150 * k + 34 * k,
              child: ListView(
                scrollDirection: Axis.horizontal,
                physics: const NeverScrollableScrollPhysics(),
                padding: EdgeInsets.symmetric(horizontal: pad),
                children: <Widget>[
                  for (int i = 0; i < 6; i++) ...<Widget>[
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        box(150 * k, 150 * k, r: 8),
                        SizedBox(height: 8 * k),
                        box(110 * k, 12 * k, r: 4),
                        SizedBox(height: 6 * k),
                        box(70 * k, 10 * k, r: 4),
                      ],
                    ),
                    SizedBox(width: 12 * k),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
