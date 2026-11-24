/// 音乐「推荐」（在线）Cupertino 版的公共件（设计稿
/// fushi/build/music_online_cupertino_design/index.html 方案 A，用户 2026-11-24
/// 拍板）：Apple Music「主页」式的段标题、横滑货架（iOS 按条吸附、macOS 悬停两端
/// 玻璃箭头）、平封面卡、来源胶囊、来源组头、分类块、胶囊按钮与首次加载骨架。
///
/// 只在 `isGlassDesign` 为真时由推荐页的 Apple 布局使用；M3E 推荐页不经过这里。
/// 尺寸取 [FushiAppleMetrics]（macOS 档乘 `fushiAppleMacScale`），颜色只取
/// [appleColorsOf] 的系统色令牌；封面一律连续曲率圆角（[ClipRSuperellipse]）。
library;

import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/focus/fushi_focus_controller.dart' show FushiFocusId;
import 'package:fushi/src/pages/implementations/music/apple/apple_music_browse_widgets.dart'
    show appleMusicCategoryGradient;
import 'package:fushi/src/pages/implementations/music/music_cover.dart';
import 'package:fushi/src/utils/components/apple/apple_capsule_button.dart';
import 'package:fushi/src/utils/components/apple/apple_section_header.dart';
import 'package:fushi/src/utils/components/apple/apple_shelf.dart';
import 'package:fushi/src/utils/components/apple/apple_text_style.dart';
import 'package:fushi/src/utils/components/fushi_design_tokens.dart';
import 'package:fushi/src/utils/components/fushi_focusable.dart';
import 'package:fushi/src/utils/components/fushi_header_more_button.dart';
import 'package:fushi/src/utils/components/fushi_hover_lift.dart';
import 'package:fushi/src/utils/components/fushi_motion_tokens.dart';
import 'package:fushi/src/utils/components/fushi_press_scale.dart';
import 'package:fushi/src/utils/components/glass/fushi_apple_palette.dart';
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
/// 在 [AppleMusicContained] 里为 0（外层列表已经留了页边）。
double appleMusicPagePadding(BuildContext context) =>
    context.dependOnInheritedWidgetOfExactType<AppleMusicContained>() != null
    ? 0
    : FushiDesignTokens.of(context).spacing.page;

/// 标记：这一列内容左右不留页边（Apple 段头 / 货架自己带页边、横滑到屏幕边）。
/// 由放 Apple 货架的滚动列表包在外面（见 [appleMusicFitShelf]）。
class AppleMusicFullBleed extends InheritedWidget {
  const AppleMusicFullBleed({super.key, required super.child});

  static bool active(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<AppleMusicFullBleed>() != null;

  @override
  bool updateShouldNotify(AppleMusicFullBleed oldWidget) => false;
}

/// 标记：外层列表已留页边，里面的 Apple 段头 / 货架不再加页边（货架在页边内横滑）。
class AppleMusicContained extends InheritedWidget {
  const AppleMusicContained({super.key, required super.child});

  @override
  bool updateShouldNotify(AppleMusicContained oldWidget) => false;
}

/// 把一段 Apple 段头 / 货架放进当前列表：在 [AppleMusicFullBleed] 列表里原样（自带
/// 页边、横滑到屏幕边），在留了页边的普通列表里套 [AppleMusicContained]。
Widget appleMusicFitShelf(BuildContext context, Widget child) =>
    AppleMusicFullBleed.active(context)
    ? child
    : AppleMusicContained(child: child);

/// 在 [AppleMusicFullBleed] 列表里给非 Apple 段（提示行 / 按钮行）补回左右页边。
Widget appleMusicInset(BuildContext context, Widget child) => Padding(
  padding: EdgeInsets.symmetric(
    horizontal: FushiDesignTokens.of(context).spacing.page,
  ),
  child: child,
);

/// 一段文字的 Apple 字样：共享 [appleTextStyle]。
TextStyle appleMusicText(
  BuildContext context, {
  required double size,
  FontWeight weight = FontWeight.w400,
  Color? color,
  double height = 1.25,
}) => appleTextStyle(
  context,
  size: size,
  weight: weight,
  color: color,
  height: height,
);

/// 一行 [size] 号字在当前 textScaler 下占的高：共享 [appleLineExtent]。
double appleMusicLineExtent(
  BuildContext context,
  double size, {
  double height = 1.25,
}) => appleLineExtent(context, size, height: height);

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

/// 段标题（Apple Music「主页」的 title2 粗体段名）：共享 [AppleSectionHeader]，
/// 页边取 [appleMusicPagePadding]（在 [AppleMusicContained] 里为 0）。
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
  Widget build(BuildContext context) => AppleSectionHeader(
    title: title,
    subtitle: subtitle,
    onOpen: onOpen,
    openKey: openKey,
    trailing: trailing,
    horizontalPadding: appleMusicPagePadding(context),
  );
}

/// 胶囊按钮：共享 [AppleCapsuleButton]（音乐的段头「播放」、取色大卡的主 / 次操作）。
typedef AppleMusicCapsuleButton = AppleCapsuleButton;

/// 推荐页的横滑货架：共享 [AppleShelf]，页边取 [appleMusicPagePadding]（在
/// [AppleMusicContained] 里为 0），箭头 key 前缀 `apple-music-shelf`。
class AppleMusicCarousel extends StatelessWidget {
  const AppleMusicCarousel({
    super.key,
    required this.itemCount,
    required this.itemExtent,
    required this.height,
    required this.itemBuilder,
    this.spacing = 12,
    this.arrowCenter,
  });

  final int itemCount;
  final double itemExtent;
  final double height;
  final IndexedWidgetBuilder itemBuilder;
  final double spacing;
  final double? arrowCenter;

  @override
  Widget build(BuildContext context) => AppleShelf(
    itemCount: itemCount,
    itemExtent: itemExtent,
    height: height,
    itemBuilder: itemBuilder,
    spacing: spacing,
    arrowCenter: arrowCenter,
    horizontalPadding: appleMusicPagePadding(context),
    arrowKeyPrefix: 'apple-music-shelf',
  );
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

  static const double _titleSize = 13;
  static const double _subtitleSize = 12;
  static const double _lineHeight = 1.25;
  static const double _titleGap = 7;
  static const double _subtitleGap = 2;

  /// 一行 [size] 号字（已乘 macOS 档缩放）在当前 textScaler 下的行高：文字行
  /// 按这个高度定死（[SizedBox]），卡高与布局出自同一份度量。
  static double _lineExtent(BuildContext context, double size) =>
      appleMusicLineExtent(context, size, height: _lineHeight);

  /// [width] 宽的卡总高（封面 + 标题行 + 副行，按 textScaler 与 macOS 档缩放）。
  static double heightFor(BuildContext context, double width) {
    final double k = FushiAppleMetrics.of(context).scale;
    return width +
        _titleGap * k +
        _lineExtent(context, _titleSize * k) +
        _subtitleGap * k +
        _lineExtent(context, _subtitleSize * k);
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
              SizedBox(height: _titleGap * k),
              SizedBox(
                height: _lineExtent(context, _titleSize * k),
                child: Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: align,
                  style: appleMusicText(
                    context,
                    size: _titleSize * k,
                    weight: FontWeight.w500,
                    height: _lineHeight,
                  ),
                ),
              ),
              if (subtitle case final String s when s.isNotEmpty)
                Container(
                  height:
                      _subtitleGap * k +
                      _lineExtent(context, _subtitleSize * k),
                  padding: EdgeInsets.only(top: _subtitleGap * k),
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
                            size: _subtitleSize * k,
                            color: c.secondaryLabel,
                            height: _lineHeight,
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
    // 窄窗横滑：桌面端鼠标也能拖（胶囊本身只认点按，不抢横拖手势）。
    final Widget row = HorizontalDragScrollable(
      child: SingleChildScrollView(
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

/// 「浏览分类」/ 流派的一块（Apple Music「按类别浏览」）：连续曲率圆角块，底是按
/// [seed]（分类 id / 名）稳定映射到一组系统色对的彩色渐变（深浅色各取系统色的
/// 对应值，[appleMusicCategoryGradient]），左下白色粗体类名（可选一行副文字），
/// 右上一枚斜放的半透明白底图标片。「全部作品」同样是渐变块。
class AppleMusicCategoryTile extends StatelessWidget {
  const AppleMusicCategoryTile({
    super.key,
    required this.label,
    required this.seed,
    required this.icon,
    required this.onTap,
    this.subtitle,
  });

  final String label;

  /// 定颜色用的稳定键（分类 id；没有 id 时用类名）。
  final String seed;
  final IconData icon;
  final VoidCallback onTap;
  final String? subtitle;

  @override
  Widget build(BuildContext context) {
    final double k = FushiAppleMetrics.of(context).scale;
    final double radius = 14 * k;
    const Color onTile = Colors.white;
    const List<Shadow> legibility = <Shadow>[
      Shadow(color: Color(0x40000000), blurRadius: 4, offset: Offset(0, 1)),
    ];
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
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: appleMusicCategoryGradient(context, seed),
                ),
                child: Stack(
                  children: <Widget>[
                    PositionedDirectional(
                      end: -8 * k,
                      top: 10 * k,
                      child: Transform.rotate(
                        angle: 18 * math.pi / 180,
                        child: Container(
                          width: 52 * k,
                          height: 52 * k,
                          decoration: ShapeDecoration(
                            color: onTile.withValues(alpha: 0.22),
                            shape: RoundedSuperellipseBorder(
                              borderRadius: BorderRadius.circular(10 * k),
                            ),
                            shadows: const <BoxShadow>[
                              BoxShadow(
                                color: Color(0x33000000),
                                blurRadius: 14,
                                offset: Offset(0, 6),
                              ),
                            ],
                          ),
                          child: Center(
                            child: FushiIcon(icon, size: 26 * k, color: onTile),
                          ),
                        ),
                      ),
                    ),
                    PositionedDirectional(
                      start: 12 * k,
                      end: 12 * k,
                      bottom: 10 * k,
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          Text(
                            label,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: appleMusicText(
                              context,
                              size: 16 * k,
                              weight: FontWeight.w700,
                              color: onTile,
                            ).copyWith(shadows: legibility),
                          ),
                          if (subtitle case final String sub
                              when sub.isNotEmpty)
                            Text(
                              sub,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: appleMusicText(
                                context,
                                size: 12 * k,
                                weight: FontWeight.w500,
                                color: onTile.withValues(alpha: 0.85),
                              ).copyWith(shadows: legibility),
                            ),
                        ],
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
              // 与下面一格的各段同一份数：封面 + 间距 + 标题条 + 间距 + 副行条。
              height: (150 + 8 + 12 + 6 + 10) * k,
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
