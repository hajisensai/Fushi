import 'dart:math' as math;

import 'package:flutter/gestures.dart'
    show PointerDeviceKind, PointerEnterEvent, PointerHoverEvent;
import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/adaptive/shell_style.dart';
import 'package:fushi/src/utils/components/fushi_bleed_title.dart';
import 'package:fushi/src/utils/components/fushi_continue_card_row.dart';
import 'package:fushi/src/utils/components/fushi_expressive_progress.dart';
import 'package:fushi/src/utils/components/fushi_motion_tokens.dart';
import 'package:fushi/src/utils/components/fushi_typography.dart';
import 'package:fushi/src/utils/components/shelf_card_widgets.dart';
import 'package:fushi/src/utils/components/shelf_cover_material.dart';
import 'package:fushi/src/utils/fushi_icons.dart';

// =============================================================================
// 封面色块卡（库页「拼贴 / 规整色块」布局，见 [ShellContentLayout]）。
//
// 一块圆角色块，底色取封面色（[coverColorSchemeCache]，MD3 / Apple 都取），
// 左上排出一行被色块裁掉的
// 大字水印（标题），前景是倾斜的封面（视频 / 书 / 漫画 / 专辑 / 游戏各一种
// 摆法）+ 标题 + 副行 + 进度条。海报元数据层（设计稿 `.vb` 的背景图 / logo /
// 状态 chip / 概览 / 信息 chip / 波浪进度 + 主按钮，书的署名，游戏 / 漫画的大数字）
// 都是可选参数：调用点只传库里已有的数据，没有的那一项整行不画。
// 鼠标悬停时水印沿 X 滑动、封面各自换到悬停姿态，
// 离开弹回（弹簧）；触屏没有悬停。
//
// 本组件只管**视觉**：点击 / 长按 / 右键 / 焦点 / 多选 / 拖放等交互一律由调用点
// 原有的卡片外壳（`shelfCoverCard` 等）负责，色块只是外壳的 child。
// =============================================================================

/// 色块在布局里的尺寸档（[SliverFushiCoverBlocks] 给出）。
enum FushiCoverBlockSize {
  /// 规整块（高 204，窄窗 184）。
  regular,

  /// 拼贴首块（高 264，窄窗 250）。
  hero,

  /// 拼贴首块旁边叠放的半高卡。
  half,
}

/// 前景封面的摆法。
enum FushiCoverBlockArt {
  /// 竖版海报斜放在右侧（视频系列 / 合集）。
  portrait,

  /// 横版剧照从右侧渐入（「全部视频」的 16:9 封面）。
  landscape,

  /// 倾斜书封；多本时排成扇形（书架 / 漫画）。
  book,

  /// 方形专辑封面在左（音乐）。
  square,

  /// 游戏盒封在左。
  box,
}

/// 文字区的大数字（设计稿漫画 `.mb .huge` 话数、游戏 `.gb .hrs` 时长）：数值 +
/// 小号单位，强调色，排在底行最前。
@immutable
class FushiCoverBlockFigure {
  const FushiCoverBlockFigure({required this.value, required this.unit});

  final String value;
  final String unit;
}

/// 拼贴首块的主按钮（设计稿 `.btnA`，「继续」/「启动」）。**纯视觉**：不是独立
/// 焦点目标、不接点击——卡片外壳的点按本来就是这个动作，调用点只在两者一致时
/// 才传（卡内嵌套焦点目标违反卡片「无独立按钮」纪律）。
@immutable
class FushiCoverBlockAction {
  const FushiCoverBlockAction({required this.icon, required this.label});

  final IconData icon;
  final String label;
}

/// 色块配色：底色、前景文字色、强调色（进度条 / 水印），以及水印不透明度。
@immutable
class FushiCoverBlockColors {
  const FushiCoverBlockColors({
    required this.container,
    required this.onContainer,
    required this.accent,
    required this.watermarkOpacity,
  });

  /// 由封面配色派生（设计稿 `fixed(h)` 同一套 HSL）：只取封面主色的色相，
  /// 饱和度 / 亮度钉死，保证各张色块明度一致、前景文字在两套主题下都可读：
  /// - 深色：底 hsl(h,32%,19%)、字 hsl(h,45%,92%)、强调 hsl(h,60%,76%)，水印 30%；
  /// - 浅色：底 hsl(h,45%,89%)、字与强调 hsl(h,50%,20%)，水印 13%。
  ///
  /// [cover] 为 null（没封面 / 还没算好 / 墨水屏）时取主题的中性色：
  /// 底 surfaceContainerHigh、字 onSurface、强调深色 primary / 浅色 onSurface。
  factory FushiCoverBlockColors.resolve(ThemeData theme, ColorScheme? cover) {
    final bool dark = theme.brightness == Brightness.dark;
    final double watermark = dark ? 0.3 : 0.13;
    if (cover == null) {
      final ColorScheme s = theme.colorScheme;
      return FushiCoverBlockColors(
        container: s.surfaceContainerHigh,
        onContainer: s.onSurface,
        accent: dark ? s.primary : s.onSurface,
        watermarkOpacity: watermark,
      );
    }
    final double hue = HSLColor.fromColor(cover.primary).hue;
    Color hsl(double s, double l) => HSLColor.fromAHSL(1, hue, s, l).toColor();
    if (dark) {
      return FushiCoverBlockColors(
        container: hsl(0.32, 0.19),
        onContainer: hsl(0.45, 0.92),
        accent: hsl(0.60, 0.76),
        watermarkOpacity: watermark,
      );
    }
    final Color on = hsl(0.50, 0.20);
    return FushiCoverBlockColors(
      container: hsl(0.45, 0.89),
      onContainer: on,
      accent: on,
      watermarkOpacity: watermark,
    );
  }

  final Color container;
  final Color onContainer;
  final Color accent;
  final double watermarkOpacity;
}

/// 色块投影：规整块 / 拼贴首块是偏下的大投影；半高卡（拼贴叠放、「继续」横滑
/// 行）只有一半高，同一个大投影压在下面显得又重又宽（2026-11-12 用户：「继续阅读
/// 底部阴影有点大」），换小一号——同色，偏移与模糊约减半。横滑行的滚动视口按
/// [kFushiCoverBlockHalfShadowExtent] 留余量，投影不被裁出硬边。
List<BoxShadow> fushiCoverBlockShadows(FushiCoverBlockSize size) =>
    size == FushiCoverBlockSize.half
    ? const <BoxShadow>[
        BoxShadow(
          color: Color(0x42000000),
          offset: Offset(0, kFushiCoverBlockHalfShadowOffset),
          blurRadius: kFushiCoverBlockHalfShadowBlur,
        ),
      ]
    : const <BoxShadow>[
        BoxShadow(
          color: Color(0x42000000),
          offset: Offset(0, 10),
          blurRadius: 26,
        ),
      ];

/// 半高卡投影的下移量与模糊半径。
const double kFushiCoverBlockHalfShadowOffset = 5;
const double kFushiCoverBlockHalfShadowBlur = 14;

/// 半高卡投影在四个方向上越出块边的距离（模糊半径 ± 下移量）：上方
/// [blur - offset]，下方 [blur + offset]，左右 [blur]。
const EdgeInsets kFushiCoverBlockHalfShadowExtent = EdgeInsets.fromLTRB(
  kFushiCoverBlockHalfShadowBlur,
  kFushiCoverBlockHalfShadowBlur - kFushiCoverBlockHalfShadowOffset,
  kFushiCoverBlockHalfShadowBlur,
  kFushiCoverBlockHalfShadowBlur + kFushiCoverBlockHalfShadowOffset,
);

/// 水印横滑弹簧（设计稿 k120 / c18：ζ ≈ 0.82，偏软）。
const FushiSpringSpec kFushiCoverBlockWatermarkSpring = FushiSpringSpec(
  dampingRatio: 0.82,
  stiffness: 120,
);

/// 封面进入悬停姿态（设计稿 k220 / c14）。
const FushiSpringSpec kFushiCoverBlockHoverSpring = FushiSpringSpec(
  dampingRatio: 0.47,
  stiffness: 220,
);

/// 封面回到静止姿态（设计稿 k300 / c20）。
const FushiSpringSpec kFushiCoverBlockRestSpring = FushiSpringSpec(
  dampingRatio: 0.58,
  stiffness: 300,
);

/// 向卡片子树广播「这一格按色块卡渲染、尺寸档是 [size]」。
///
/// 给视觉在共享卡壳深处构造、调用点拿不到格子尺寸的卡用（书架的
/// `_bookCardLayout`）：布局格子包这一层，卡片视觉用 [maybeOf] 判断走色块还是
/// 原封面网格。没有这一层 = 原网格。
class FushiCoverBlockScope extends InheritedWidget {
  const FushiCoverBlockScope({
    required this.size,
    required super.child,
    super.key,
  });

  final FushiCoverBlockSize size;

  static FushiCoverBlockSize? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<FushiCoverBlockScope>()?.size;

  @override
  bool updateShouldNotify(FushiCoverBlockScope oldWidget) =>
      oldWidget.size != size;
}

/// 从封面 widget 里取图源（`Image` / `FadeInImage`），给色块取色用；取不到为 null。
ImageProvider? fushiCoverImageOf(Widget cover) => switch (cover) {
  Image(:final ImageProvider image) => image,
  FadeInImage(:final ImageProvider image) => image,
  _ => null,
};

/// 色块圆角：规整 / 拼贴首块 30，半高卡与窄窗（高 < 200）26。
double fushiCoverBlockRadius(FushiCoverBlockSize size, double height) =>
    size == FushiCoverBlockSize.half || height < 200 ? 26 : 30;

/// 色块的外形：与色块本身同一套外壳形状（`shellShape`：平滑外壳下是半径 ×
/// [kShellSmoothRadiusScale] 的超椭圆，否则圆弧角），半径按**实际绘制高度**取
/// [fushiCoverBlockRadius]。卡壳（`shelfCoverCard(shape: ...)` → `FushiCard`）的
/// 卡面 / 水波 / 按压 / 焦点层用它，与里面的色块严丝合缝；构建时不必知道高度。
@immutable
class FushiCoverBlockBorder extends OutlinedBorder {
  const FushiCoverBlockBorder({
    required this.size,
    required this.smooth,
    super.side,
  });

  final FushiCoverBlockSize size;

  /// 平滑外壳（`ShellThemeData.smoothCorners`）。
  final bool smooth;

  OutlinedBorder _resolve(Rect rect) {
    final BorderRadius radius = BorderRadius.circular(
      fushiCoverBlockRadius(size, rect.height),
    );
    return smooth
        ? RoundedSuperellipseBorder(
            borderRadius: radius * kShellSmoothRadiusScale,
            side: side,
          )
        : RoundedRectangleBorder(borderRadius: radius, side: side);
  }

  @override
  FushiCoverBlockBorder copyWith({BorderSide? side}) => FushiCoverBlockBorder(
    size: size,
    smooth: smooth,
    side: side ?? this.side,
  );

  @override
  ShapeBorder scale(double t) =>
      FushiCoverBlockBorder(size: size, smooth: smooth, side: side.scale(t));

  @override
  Path getInnerPath(Rect rect, {TextDirection? textDirection}) =>
      _resolve(rect).getInnerPath(rect, textDirection: textDirection);

  @override
  Path getOuterPath(Rect rect, {TextDirection? textDirection}) =>
      _resolve(rect).getOuterPath(rect, textDirection: textDirection);

  @override
  void paint(Canvas canvas, Rect rect, {TextDirection? textDirection}) =>
      _resolve(rect).paint(canvas, rect, textDirection: textDirection);

  @override
  bool operator ==(Object other) =>
      other is FushiCoverBlockBorder &&
      other.size == size &&
      other.smooth == smooth &&
      other.side == side;

  @override
  int get hashCode => Object.hash(size, smooth, side);
}

/// 当前外壳下 [size] 档色块的外形（见 [FushiCoverBlockBorder]）。
OutlinedBorder fushiCoverBlockShape(
  BuildContext context,
  FushiCoverBlockSize size,
) => FushiCoverBlockBorder(
  size: size,
  smooth: shellThemeOf(context).smoothCorners,
);

/// 封面色块卡。见文件头。
class FushiCoverBlock extends StatefulWidget {
  const FushiCoverBlock({
    required this.title,
    required this.covers,
    required this.art,
    this.tintImage,
    this.size = FushiCoverBlockSize.regular,
    this.subtitle,
    this.leadingIcon,
    this.tone = ShelfMetaTone.normal,
    this.progress,
    this.completed = false,
    this.trailing,
    this.coverOverlay,
    this.metaKey,
    this.selectionMode,
    this.selected,
    this.hoverEnabled = true,
    this.backdrop,
    this.logo,
    this.eyebrow,
    this.byline,
    this.overview,
    this.chip,
    this.figure,
    this.action,
    super.key,
  });

  /// 标题：前景标题与大字水印同一份。
  final String title;

  /// 背景图（设计稿 `.vb .bd`：无字横版背景 / 剧照）：铺在右侧 64% 宽、左缘渐隐
  /// 进色块，底部再压一层封面色渐变（`.shade`）。只在
  /// [FushiCoverBlockArt.portrait] 下生效——此时封面改为 2:3 斜放在左
  /// （`.vb .ps`，只画 [covers] 首个），文字排在封面右侧、压在背景图上。null =
  /// 原摆法（封面斜放在右）。
  final Widget? backdrop;

  /// 标题 logo（透明底 PNG，`.vb .lg`）：有就代替标题文字放在标题位，左下对齐、
  /// 按尺寸档限高；解码失败回落标题文字。语义标签仍是 [title]。
  final ImageProvider? logo;

  /// 文字区顶上的状态 chip（`.meta .chip` 的「继续观看 · 第 N 集」、游戏品牌、
  /// 书的「继续阅读」）。半高卡不画。
  final String? eyebrow;

  /// 标题下的一行署名（书的作者 · 卷数，设计稿 `.bk .vol`）。
  final String? byline;

  /// 概览行（`.vb.hero .ov`：类型 / 评分）。只在拼贴首块画。
  final String? overview;

  /// 底行信息 chip（「TV · 2026 · 12 集」、音频规格等），与进度条同排。
  final String? chip;

  /// 底行的大数字（话数 / 游玩时长）。
  final FushiCoverBlockFigure? figure;

  /// 拼贴首块的主按钮，排在底行末尾。只在拼贴首块画。
  final FushiCoverBlockAction? action;

  /// 前景封面（首个 = 最前那本 / 那张；[FushiCoverBlockArt.book] 最多画 3 本，
  /// [FushiCoverBlockArt.portrait] 首个之后的画成后面的叠层）。为空时画占位。
  final List<Widget> covers;
  final FushiCoverBlockArt art;

  /// 取色用的封面图源（与 [covers] 首个同源）；null = 中性色。
  final ImageProvider? tintImage;
  final FushiCoverBlockSize size;

  /// 副行（集数 / 读到哪 / 歌手 · 年份 / 游玩状态…）。
  final String? subtitle;

  /// 副行前导图标（远端 ☁、有声书、错误等）。
  final IconData? leadingIcon;

  /// 副行语气：警示 / 错误时前导图标换语气色。
  final ShelfMetaTone tone;

  /// 进度 0–1；null = 不画进度条。
  final double? progress;
  final bool completed;

  /// 副行之后的附加件（原盘 / 规格 / 标签 / 光盘角标等），排在文字区底部。
  final Widget? trailing;

  /// 盖在最前那张封面上的居中件（下载 / 导入进行中的进度环等）。
  final Widget? coverOverlay;

  /// 文字区的 key（测试按原卡片的 meta key 找文字块时用）。
  final Key? metaKey;

  /// 多选态 / 已选中；null = 读祖先 [ShelfCoverSelection]（书架卡壳往下广播）。
  final bool? selectionMode;
  final bool? selected;

  /// false = 不响应悬停（多选态：卡片是勾选目标，跟着指针动只会干扰框选）。
  final bool hoverEnabled;

  @override
  State<FushiCoverBlock> createState() => _FushiCoverBlockState();
}

class _FushiCoverBlockState extends State<FushiCoverBlock>
    with TickerProviderStateMixin {
  /// 封面姿态：0 静止、1 悬停（弹簧可过冲）。
  late final AnimationController _pose = AnimationController.unbounded(
    vsync: this,
  );

  /// 水印 X 偏移（逻辑像素）。
  late final AnimationController _watermark = AnimationController.unbounded(
    vsync: this,
  );

  bool _hovered = false;

  @override
  void dispose() {
    _pose.dispose();
    _watermark.dispose();
    super.dispose();
  }

  /// 背景图 + 左侧斜放封面并存（设计稿 `.vb` 有 `bd` 又有 `ps` 的形态）。墨水屏
  /// 不画照片背景（色块本身已是中性色）。
  bool get _hasBackdrop =>
      widget.backdrop != null &&
      widget.art == FushiCoverBlockArt.portrait &&
      !isEinkTheme(context);

  FushiSpringSpec _spec(FushiSpringSpec spec) =>
      fushiMotionEnabled(context) ? spec : spec.reduced;

  void _setHover(bool hovered, {double fraction = 0.5}) {
    if (!widget.hoverEnabled && hovered) return;
    if (hovered != _hovered) {
      _hovered = hovered;
      _pose.fushiSpringTo(
        hovered ? 1 : 0,
        _spec(
          hovered ? kFushiCoverBlockHoverSpring : kFushiCoverBlockRestSpring,
        ),
      );
    }
    _watermark.fushiSpringTo(
      hovered ? -40 - (fraction - 0.5) * 60 : 0,
      _spec(kFushiCoverBlockWatermarkSpring),
    );
  }

  @override
  void didUpdateWidget(FushiCoverBlock oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!widget.hoverEnabled && _hovered) _setHover(false);
    _resolveTint();
  }

  /// [fraction] 按阅读方向量：0 = 起始边（LTR 左 / RTL 右）、1 = 结束边，
  /// 水印偏移因此也是「朝起始边」的量，画的时候再按方向翻符号。
  void _onHover(PointerEvent event, double width) {
    if (event.kind != PointerDeviceKind.mouse) return;
    final double f = width <= 0
        ? 0.5
        : (event.localPosition.dx / width).clamp(0.0, 1.0);
    final bool rtl = Directionality.of(context) == TextDirection.rtl;
    _setHover(true, fraction: rtl ? 1 - f : f);
  }

  /// 封面取色（[coverColorSchemeCache]，与「继续」取色卡同一份缓存）。不经
  /// [FushiCoverTint]：它在 Apple 设计系统下恒给 null，而色块在两套设计系统下都
  /// 要取封面色；只有墨水屏不取色（中性色）。
  ColorScheme? _scheme;
  ImageProvider? _tintFor;
  Brightness? _tintBrightness;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _resolveTint();
  }

  void _resolveTint() {
    final ImageProvider? image = isEinkTheme(context) ? null : widget.tintImage;
    final Brightness brightness = Theme.of(context).brightness;
    if (image == _tintFor && brightness == _tintBrightness) return;
    _tintFor = image;
    _tintBrightness = brightness;
    if (image == null) {
      _scheme = null;
      return;
    }
    // 换了封面：先取缓存里的（没有就 null = 中性色），不留上一张的配色。
    _scheme = coverColorSchemeCache.peek(image, brightness);
    if (_scheme != null) return;
    coverColorSchemeCache.resolve(image, brightness).then((ColorScheme? s) {
      if (!mounted || _tintFor != image || _tintBrightness != brightness) {
        return;
      }
      setState(() => _scheme = s);
    });
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final FushiCoverBlockColors colors = FushiCoverBlockColors.resolve(
      theme,
      _scheme,
    );
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final Size size = constraints.biggest;
        return MouseRegion(
          opaque: false,
          onEnter: (PointerEnterEvent e) => _onHover(e, size.width),
          onHover: (PointerHoverEvent e) => _onHover(e, size.width),
          onExit: (_) => _setHover(false),
          child: _buildBlock(context, theme, colors, size),
        );
      },
    );
  }

  Widget _buildBlock(
    BuildContext context,
    ThemeData theme,
    FushiCoverBlockColors colors,
    Size size,
  ) {
    final double radius = fushiCoverBlockRadius(widget.size, size.height);
    final BorderRadius borderRadius = BorderRadius.circular(radius);
    final ShelfCoverSelection? scoped = ShelfCoverSelection.maybeOf(context);
    final bool selectionMode =
        widget.selectionMode ?? scoped?.selectionMode ?? false;
    final bool selected = widget.selected ?? scoped?.selected ?? false;
    final TextDirection direction = Directionality.of(context);
    // 几何一律按 LTR（封面在左 / 在右与设计稿一致）算，RTL 整体水平镜像。
    final _BlockGeometry ltrGeo = _hasBackdrop
        ? _BlockGeometry.backdropPoster(widget.size, size)
        : _BlockGeometry.of(
            widget.art,
            widget.size,
            size,
            coverCount: widget.covers.length,
          );
    final _BlockGeometry geo = direction == TextDirection.rtl
        ? ltrGeo.mirrored(size.width)
        : ltrGeo;
    return DecoratedBox(
      decoration: ShapeDecoration(
        shape: shellShape(context, borderRadius),
        color: colors.container,
        shadows: fushiCoverBlockShadows(widget.size),
      ),
      child: ShellClip(
        radius: borderRadius,
        child: Stack(
          clipBehavior: Clip.hardEdge,
          children: <Widget>[
            _buildWatermark(colors, size, ltrGeo, direction),
            ..._buildArt(context, colors, geo, size, direction),
            Positioned.fromRect(
              rect: geo.text,
              child: KeyedSubtree(
                key: widget.metaKey,
                child: _BlockText(
                  title: widget.title,
                  subtitle: widget.subtitle,
                  leadingIcon: widget.leadingIcon,
                  tone: widget.tone,
                  progress: widget.progress,
                  completed: widget.completed,
                  trailing: widget.trailing,
                  colors: colors,
                  size: widget.size,
                  titleLines: geo.titleLines,
                  // 半高卡（125 高）放不下作品 logo：logo 会压到副行 / 进度上
                  // （2026-11-12 用户截图 BLEACH 那块），改用两行标题文字。
                  logo:
                      isEinkTheme(context) ||
                          widget.size == FushiCoverBlockSize.half
                      ? null
                      : widget.logo,
                  eyebrow: widget.eyebrow,
                  byline: widget.byline,
                  overview: widget.overview,
                  chip: widget.chip,
                  figure: widget.figure,
                  action: widget.action,
                  // 窄窗：规整块 184、拼贴首块 250（宽窗 204 / 264），按钮与
                  // logo 换小一号（设计稿 `.phone` 那组规则）。
                  compact:
                      size.height < 200 ||
                      (widget.size == FushiCoverBlockSize.hero &&
                          size.height < 260),
                ),
              ),
            ),
            if (selected)
              Positioned.fill(
                child: IgnorePointer(
                  child: DecoratedBox(
                    decoration: ShapeDecoration(
                      color: theme.colorScheme.primary.withValues(alpha: 0.18),
                      shape: shellShape(
                        context,
                        borderRadius,
                        side: BorderSide(
                          color: theme.colorScheme.primary,
                          width: 3,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            if (selectionMode)
              PositionedDirectional(
                top: 12,
                end: 12,
                child: ShelfSelectionCheck(selected: selected),
              ),
          ],
        ),
      ),
    );
  }

  /// 大字水印：纯装饰，不进语义、不参与命中。[geo] 是未镜像的几何：水印
  /// 起点按 LTR 量出来，RTL 下贴到右边、悬停横移方向翻转。
  Widget _buildWatermark(
    FushiCoverBlockColors colors,
    Size size,
    _BlockGeometry geo,
    TextDirection direction,
  ) {
    final double fontSize = size.height * 0.62;
    // 封面在左的摆法（书 / 专辑 / 盒封 / 背景图 + 海报）从文字区左缘起：照旧从
    // 色块左缘起，标题开头那几个字整个压在封面底下，露出来的是半截。
    final bool coverOnLeft = geo.text.left > size.width * 0.2;
    final double start = coverOnLeft ? geo.text.left - 10 : -8;
    // 画出来的装饰大字（不是 Text）：不进语义、不进文字查找，标题只读一遍。
    return Positioned.fill(
      child: FushiBleedTitle(
        text: widget.title,
        textSize: fontSize,
        color: colors.accent.withValues(alpha: colors.watermarkOpacity),
        start: start,
        top: size.height * 0.02,
        shift: _watermark,
        direction: direction,
      ),
    );
  }

  List<Widget> _buildArt(
    BuildContext context,
    FushiCoverBlockColors colors,
    _BlockGeometry geo,
    Size size,
    TextDirection direction,
  ) {
    final List<Widget> covers = widget.covers.isEmpty
        ? <Widget>[const _CoverPlaceholder()]
        : widget.covers;
    if (_hasBackdrop) {
      // 背景图在右（slots[0]），2:3 封面斜放在左（slots[1]）压在背景图与大字上。
      return <Widget>[
        _posed(geo.slots.first, _fadedBackdrop(widget.backdrop!, direction)),
        _shade(colors),
        _posed(
          geo.slots[1],
          _CoverCard(radius: geo.coverRadius, child: covers.first),
        ),
        if (widget.coverOverlay != null)
          Positioned.fromRect(
            rect: geo.slots[1].rect,
            child: Center(child: widget.coverOverlay),
          ),
      ];
    }
    if (widget.art == FushiCoverBlockArt.landscape) {
      return <Widget>[
        _posed(geo.slots.first, _fadedBackdrop(covers.first, direction)),
        _shade(colors),
        if (widget.coverOverlay != null)
          Positioned.fromRect(
            rect: geo.slots.first.rect,
            child: Center(child: widget.coverOverlay),
          ),
      ];
    }
    // 摆放序：后面的先画、最前那张最后画（压在最上面）。
    final int count = math.min(covers.length, geo.slots.length);
    final List<Widget> out = <Widget>[];
    for (int i = count - 1; i >= 0; i--) {
      final _CoverSlot slot = geo.slots[i];
      out.add(
        _posed(slot, _CoverCard(radius: geo.coverRadius, child: covers[i])),
      );
    }
    if (widget.coverOverlay != null) {
      out.add(
        Positioned.fromRect(
          rect: geo.slots.first.rect,
          child: Center(child: widget.coverOverlay),
        ),
      );
    }
    return out;
  }

  /// 横版背景图：起始缘（LTR 左 / RTL 右）渐隐进色块（设计稿 `.vb .bd` 的
  /// mask，0 → 52% 全显）。
  Widget _fadedBackdrop(Widget image, TextDirection direction) => ShaderMask(
    blendMode: BlendMode.dstIn,
    shaderCallback: (Rect r) => const LinearGradient(
      begin: AlignmentDirectional.centerStart,
      end: AlignmentDirectional.centerEnd,
      colors: <Color>[Color(0x00000000), Color(0xFF000000)],
      stops: <double>[0, 0.52],
    ).createShader(r, textDirection: direction),
    child: SizedBox.expand(child: image),
  );

  /// 自下而上的封面色渐变（`.vb .shade`），让压在背景图上的文字可读。
  Widget _shade(FushiCoverBlockColors colors) => Positioned.fill(
    child: IgnorePointer(
      child: DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.bottomCenter,
            end: Alignment.topCenter,
            // 设计稿是 94% → 56% 处全透明的直线；真实剧照比稿子里的图杂，两行
            // 标题那一带（自下 30%～45%）只剩三成遮罩、字压在画面上读不清，
            // 中段垫一个停靠点把它托住。
            colors: <Color>[
              colors.container.withValues(alpha: 0.94),
              colors.container.withValues(alpha: 0.74),
              colors.container.withValues(alpha: 0),
            ],
            stops: const <double>[0, 0.34, 0.68],
          ),
        ),
      ),
    ),
  );

  /// 按 [_pose] 在静止 / 悬停两个姿态间插值（弹簧过冲照样外推）。
  Widget _posed(_CoverSlot slot, Widget child) {
    return Positioned.fromRect(
      rect: slot.rect,
      child: IgnorePointer(
        child: AnimatedBuilder(
          animation: _pose,
          builder: (BuildContext context, Widget? child) {
            final double t = _pose.value;
            double lerp(double a, double b) => a + (b - a) * t;
            final double rotation = lerp(
              slot.rest.rotation,
              slot.hover.rotation,
            );
            final double scale = lerp(slot.rest.scale, slot.hover.scale);
            return Transform(
              alignment: slot.origin,
              transform: Matrix4.identity()
                ..translateByDouble(
                  lerp(slot.rest.dx, slot.hover.dx),
                  lerp(slot.rest.dy, slot.hover.dy),
                  0,
                  1,
                )
                ..rotateZ(rotation * math.pi / 180)
                ..scaleByDouble(scale, scale, 1, 1),
              child: child,
            );
          },
          child: child,
        ),
      ),
    );
  }
}

/// 一张封面的姿态：位移（逻辑像素）、旋转（度）、缩放。
@immutable
class _Pose {
  const _Pose({this.dx = 0, this.dy = 0, this.rotation = 0, this.scale = 1});

  final double dx;
  final double dy;
  final double rotation;
  final double scale;

  /// 水平镜像：横移与旋转都翻符号。
  _Pose mirrored() => _Pose(dx: -dx, dy: dy, rotation: -rotation, scale: scale);
}

@immutable
class _CoverSlot {
  const _CoverSlot({
    required this.rect,
    required this.rest,
    required this.hover,
    this.origin = Alignment.center,
  });

  final Rect rect;
  final _Pose rest;
  final _Pose hover;
  final Alignment origin;

  /// 在宽 [width] 的色块里水平镜像。
  _CoverSlot mirrored(double width) => _CoverSlot(
    rect: _mirrorRect(rect, width),
    rest: rest.mirrored(),
    hover: hover.mirrored(),
    origin: Alignment(-origin.x, origin.y),
  );
}

/// [rect] 在宽 [width] 的容器里水平镜像。
Rect _mirrorRect(Rect rect, double width) =>
    Rect.fromLTRB(width - rect.right, rect.top, width - rect.left, rect.bottom);

/// 各摆法的几何（设计稿 `.vb` / `.bk` / `.mb` / `.ab` / `.gb` 换算）。
@immutable
class _BlockGeometry {
  const _BlockGeometry({
    required this.slots,
    required this.text,
    required this.coverRadius,
    required this.titleLines,
  });

  factory _BlockGeometry.of(
    FushiCoverBlockArt art,
    FushiCoverBlockSize size,
    Size box, {
    required int coverCount,
  }) {
    final double w = box.width;
    final double h = box.height;
    final bool half = size == FushiCoverBlockSize.half;
    final bool hero = size == FushiCoverBlockSize.hero;
    final double pad = half ? 12 : 20;
    // 半高卡标题也给两行（2026-11-12 用户：「标题显示不全」——一行只放得下
    // 七八个字，常见书名 / 片名都被截断），放不下再省略。
    const int lines = 2;
    switch (art) {
      case FushiCoverBlockArt.portrait:
        // 竖版海报：右侧斜放、略出血（设计稿 `.mb .cv`）；后面的成员叠在左后方。
        final double ch = h * 1.08;
        final double cw = math.min(ch * 2 / 3, w * 0.42);
        final Rect front = Rect.fromLTWH(w - cw + 10, h * 0.04, cw, ch);
        // 文字让开实际画出来的每一张封面：叠层往左后方错开、封面又是斜放的
        // （绕中心转 θ 后左缘外扩 (ch/2)·sin θ − (cw/2)·(1 − cos θ)）。
        const List<double> stackShift = <double>[0, 0.22, 0.42];
        const List<double> stackRotation = <double>[8, 1, -6];
        double artLeft = front.left;
        for (int i = 0; i < coverCount.clamp(1, 3); i++) {
          final double theta = stackRotation[i].abs() * math.pi / 180;
          artLeft = math.min(
            artLeft,
            front.left -
                cw * stackShift[i] -
                (ch / 2 * math.sin(theta) - cw / 2 * (1 - math.cos(theta))),
          );
        }
        return _BlockGeometry(
          slots: <_CoverSlot>[
            _CoverSlot(
              rect: front,
              rest: _Pose(rotation: stackRotation[0]),
              hover: const _Pose(rotation: 3, dx: -6, dy: -8, scale: 1.04),
            ),
            _CoverSlot(
              rect: front.translate(-cw * stackShift[1], 4),
              rest: _Pose(rotation: stackRotation[1]),
              hover: const _Pose(rotation: -6, dx: -16, dy: -4),
            ),
            _CoverSlot(
              rect: front.translate(-cw * stackShift[2], 8),
              rest: _Pose(rotation: stackRotation[2]),
              hover: const _Pose(rotation: -14, dx: -26),
            ),
          ],
          text: Rect.fromLTRB(
            pad,
            pad,
            math.max(pad + 40, artLeft - 10),
            h - pad,
          ),
          coverRadius: half ? 10 : 16,
          titleLines: lines,
        );
      case FushiCoverBlockArt.landscape:
        // 横版剧照：占右侧 64%，左缘渐隐；文字压在底部压暗上。
        return _BlockGeometry(
          slots: <_CoverSlot>[
            _CoverSlot(
              rect: Rect.fromLTWH(w * 0.36, 0, w * 0.64, h),
              rest: const _Pose(),
              hover: const _Pose(dx: -14, scale: 1.06),
              origin: Alignment.centerRight,
            ),
          ],
          text: Rect.fromLTRB(pad + 2, pad, w - pad, h - (half ? 10 : 16)),
          coverRadius: 0,
          titleLines: lines,
        );
      case FushiCoverBlockArt.book:
        // 书：左侧扇形（设计稿 `.bk .fan`），右侧文字。
        final double top = half ? 12 : 20;
        final double fanLeft = half ? 18 : (hero ? 34 : 26);
        final double fanW = w * (hero ? 0.38 : 0.44);
        final double ch = h - top * 2;
        final double cw = math.min(ch * kShelfBookCoverAspectRatio, fanW);
        final int n = coverCount.clamp(1, 3);
        const List<(_Pose, _Pose)> fan = <(_Pose, _Pose)>[
          (_Pose(rotation: 6), _Pose(rotation: 15, dx: 14)),
          (_Pose(rotation: -2), _Pose(rotation: -3, dy: -10)),
          (_Pose(rotation: -9), _Pose(rotation: -18, dx: -12)),
        ];
        final List<_CoverSlot> slots = <_CoverSlot>[];
        if (n == 1) {
          slots.add(
            _CoverSlot(
              rect: Rect.fromLTWH(fanLeft + fanW * 0.08, top, cw, ch),
              rest: const _Pose(rotation: -5),
              hover: const _Pose(rotation: -10, dy: -6, scale: 1.03),
              origin: Alignment.bottomCenter,
            ),
          );
        } else {
          // 首个（最前）放在最右、最后画；其余依次往左后方。
          for (int i = 0; i < n; i++) {
            final int pos = n - 1 - i;
            final (_Pose rest, _Pose hover) = fan[i + (3 - n)];
            slots.add(
              _CoverSlot(
                rect: Rect.fromLTWH(fanLeft + fanW * 0.17 * pos, top, cw, ch),
                rest: rest,
                hover: hover,
                origin: Alignment.bottomCenter,
              ),
            );
          }
        }
        final double fanRight = slots
            .map((_CoverSlot s) => s.rect.right)
            .reduce(math.max);
        // 半高卡的书封受块高限制很窄，按行宽比例定文字起点会在封面与书名之间
        // 空出一大块（2026-11-13 用户：「不要留白太多」）：文字紧跟封面。
        final double textLeft = half
            ? fanRight + 16
            : math.max(w * (hero ? 0.44 : 0.53), fanRight + 14);
        return _BlockGeometry(
          slots: slots,
          text: Rect.fromLTRB(
            math.min(textLeft, w - 80),
            half ? 10 : 18,
            w - pad,
            h - (half ? 12 : 16),
          ),
          coverRadius: 10,
          titleLines: half ? 2 : 3,
        );
      case FushiCoverBlockArt.square:
        // 专辑：左上方形封面（设计稿 `.ab .cv`），右侧文字。
        final double s = h - (half ? 24 : 40);
        final double left = half ? 12 : 20;
        return _BlockGeometry(
          slots: <_CoverSlot>[
            _CoverSlot(
              rect: Rect.fromLTWH(left, half ? 12 : 18, s, s),
              rest: const _Pose(rotation: -5),
              hover: const _Pose(rotation: -9, scale: 1.04),
            ),
          ],
          text: Rect.fromLTRB(
            math.min(left + s + 24, w - 80),
            half ? 12 : 22,
            w - (half ? 12 : 18),
            h - (half ? 10 : 14),
          ),
          coverRadius: 14,
          titleLines: half ? 2 : 3,
        );
      case FushiCoverBlockArt.box:
        // 游戏盒封：左侧（设计稿 `.gb .art`，竖版 3:4 以免裁掉立绘）。
        final double ah = h - pad * 2;
        final double aw = ah * 0.75;
        return _BlockGeometry(
          slots: <_CoverSlot>[
            _CoverSlot(
              rect: Rect.fromLTWH(pad, pad, aw, ah),
              rest: const _Pose(rotation: -5),
              hover: const _Pose(rotation: -10, dy: -2, scale: 1.05),
            ),
          ],
          text: Rect.fromLTRB(
            math.min(pad + aw + 22, w - 80),
            pad,
            w - pad,
            h - (half ? 10 : 16),
          ),
          coverRadius: half ? 14 : 18,
          titleLines: 2,
        );
    }
  }

  /// 背景图 + 左侧封面（设计稿 `.vb` 有 `bd` 又有 `ps`）：slots[0] = 右侧 64%
  /// 背景图（静止 / 悬停 = `x:0;s:1` / `x:-14;s:1.06`，以右缘为轴），slots[1] =
  /// 左侧 2:3 封面（`r:-5` / `r:-10;x:-3;y:-3;s:1.04`）；文字从封面右侧起
  /// （`left: 16 + (bh-32)/1.5 + 22`），压在背景图上。
  factory _BlockGeometry.backdropPoster(FushiCoverBlockSize size, Size box) {
    final double w = box.width;
    final double h = box.height;
    final bool half = size == FushiCoverBlockSize.half;
    final bool compact = !half && h < 200;
    final double inset = half ? 10 : (compact ? 12 : 16);
    final double left = half ? 12 : inset;
    final double ph = h - inset * 2;
    final double pw = ph * 2 / 3;
    final Rect poster = Rect.fromLTWH(left, inset, pw, ph);
    return _BlockGeometry(
      slots: <_CoverSlot>[
        _CoverSlot(
          rect: Rect.fromLTWH(w * 0.36, 0, w * 0.64, h),
          rest: const _Pose(),
          hover: const _Pose(dx: -14, scale: 1.06),
          origin: Alignment.centerRight,
        ),
        _CoverSlot(
          rect: poster,
          rest: const _Pose(rotation: -5),
          hover: const _Pose(rotation: -10, dx: -3, dy: -3, scale: 1.04),
        ),
      ],
      text: Rect.fromLTRB(
        math.min(poster.right + 22, w - 80),
        half ? 10 : 16,
        w - (half ? 12 : 18),
        h - (half ? 12 : 16),
      ),
      coverRadius: half ? 10 : (compact ? 13 : 16),
      titleLines: 2,
    );
  }

  /// RTL 用：整块在宽 [width] 里水平镜像（封面换到另一侧、姿态反向）。
  _BlockGeometry mirrored(double width) => _BlockGeometry(
    slots: <_CoverSlot>[
      for (final _CoverSlot slot in slots) slot.mirrored(width),
    ],
    text: _mirrorRect(text, width),
    coverRadius: coverRadius,
    titleLines: titleLines,
  );

  /// 封面槽，按 [slots] 序：首个 = 最前那张。
  final List<_CoverSlot> slots;
  final Rect text;
  final double coverRadius;
  final int titleLines;
}

/// 带投影、裁圆角的一张封面。
class _CoverCard extends StatelessWidget {
  const _CoverCard({required this.radius, required this.child});

  final double radius;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final BorderRadius r = BorderRadius.circular(radius);
    return DecoratedBox(
      decoration: ShapeDecoration(
        shape: shellShape(context, r),
        shadows: const <BoxShadow>[
          BoxShadow(
            color: Color(0x80000000),
            offset: Offset(0, 12),
            blurRadius: 28,
          ),
        ],
      ),
      child: ShellClip(
        radius: r,
        child: SizedBox.expand(
          child: ColoredBox(
            color: Theme.of(context).colorScheme.surfaceContainerHighest,
            child: child,
          ),
        ),
      ),
    );
  }
}

class _CoverPlaceholder extends StatelessWidget {
  const _CoverPlaceholder();

  @override
  Widget build(BuildContext context) =>
      const ShelfCoverPlaceholder(icon: FushiIcons.image);
}

/// 前景文字区（设计稿 `.vb .meta` / `.bk .txt` / `.gb .txt`），底对齐，自上而下：
/// 状态 chip → logo 或标题 → 署名 → 副行 → 概览 → 底行（大数字 · 信息 chip ·
/// 进度条 · 主按钮）→ 附加件。
///
/// 放不下时按优先级整行丢（概览 → 状态 chip → 署名 → 附加件 → 副行），标题至少
/// 留一行、底行恒在；剩下的高度全给标题（多行 / logo 放大到上限）。按尺寸档：
/// 状态 chip 半高卡不画，概览与主按钮只在拼贴首块画（设计稿 `.desk .stack` 与
/// `.vb.hero` 两组规则）。
class _BlockText extends StatelessWidget {
  const _BlockText({
    required this.title,
    required this.subtitle,
    required this.leadingIcon,
    required this.tone,
    required this.progress,
    required this.completed,
    required this.trailing,
    required this.colors,
    required this.size,
    required this.titleLines,
    required this.logo,
    required this.eyebrow,
    required this.byline,
    required this.overview,
    required this.chip,
    required this.figure,
    required this.action,
    required this.compact,
  });

  final String title;
  final String? subtitle;
  final IconData? leadingIcon;
  final ShelfMetaTone tone;
  final double? progress;
  final bool completed;
  final Widget? trailing;
  final FushiCoverBlockColors colors;
  final FushiCoverBlockSize size;
  final int titleLines;
  final ImageProvider? logo;
  final String? eyebrow;
  final String? byline;
  final String? overview;
  final String? chip;
  final FushiCoverBlockFigure? figure;
  final FushiCoverBlockAction? action;

  /// 窄窗档：按钮、logo、大数字换小一号。
  final bool compact;

  static bool _has(String? s) => s != null && s.isNotEmpty;

  @override
  Widget build(BuildContext context) {
    final TextScaler scaler = MediaQuery.textScalerOf(context);
    final bool half = size == FushiCoverBlockSize.half;
    final bool hero = size == FushiCoverBlockSize.hero;
    final double titleSize = switch (size) {
      FushiCoverBlockSize.hero => compact ? 24 : 28,
      FushiCoverBlockSize.regular => compact ? 17 : 20,
      FushiCoverBlockSize.half => 16,
    };
    final double logoMaxHeight = switch (size) {
      FushiCoverBlockSize.hero => compact ? 70 : 92,
      FushiCoverBlockSize.regular => compact ? 54 : 78,
      FushiCoverBlockSize.half => 40,
    };
    final double figureSize = switch (size) {
      FushiCoverBlockSize.hero => compact ? 48 : 64,
      FushiCoverBlockSize.regular => compact ? 38 : 54,
      FushiCoverBlockSize.half => 34,
    };
    final double subSize = half ? 11.5 : 12.5;
    final double gap = half ? 4 : (hero ? 10 : 7);
    final double? value = completed ? 1 : progress?.clamp(0.0, 1.0);
    final bool wavy = hero && !isGlassDesign(context) && !isEinkTheme(context);
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final bool showAction =
            hero && action != null && constraints.maxWidth >= 200;
        // 各行的估计高度（随文字缩放）。
        double textLine(double fontSize, double height) =>
            scaler.scale(fontSize) * height;
        final double chipHeight = textLine(11, 1.25) + 10;
        final double bottomHeight = <double>[
          if (figure != null) figureSize * 0.85,
          if (_has(chip)) chipHeight,
          if (value != null) wavy ? 10 : 6,
          if (showAction) compact ? 44 : 52,
        ].fold<double>(0, math.max);
        // 半高卡按标题行数留高（两行标题时先丢次要行，标题不被压成一行）。
        final double titleMin = logo != null
            ? 24
            : textLine(titleSize, 1.15) * (half ? titleLines : 1);
        // 可丢的行，按丢弃顺序（先丢的在前）。
        final List<(String, double)> optional = <(String, double)>[
          if (hero && _has(overview)) ('overview', textLine(13, 1.4)),
          if (!half && _has(eyebrow)) ('eyebrow', chipHeight),
          if (_has(byline)) ('byline', textLine(12, 1.3)),
          if (trailing != null) ('trailing', 20),
          if (_has(subtitle))
            ('subtitle', math.max(textLine(subSize, 1.25), 14)),
        ];
        double total(int dropped) {
          final int rows =
              1 + (bottomHeight > 0 ? 1 : 0) + optional.length - dropped;
          double sum = titleMin + bottomHeight;
          for (int i = dropped; i < optional.length; i++) {
            sum += optional[i].$2;
          }
          return sum + gap * (rows - 1);
        }

        int dropped = 0;
        while (dropped < optional.length &&
            total(dropped) > constraints.maxHeight) {
          dropped++;
        }
        final Set<String> shown = <String>{
          for (int i = dropped; i < optional.length; i++) optional[i].$1,
        };
        final bool eyebrowShown = shown.contains('eyebrow');
        final Color toneColor = switch (tone) {
          ShelfMetaTone.normal => colors.onContainer,
          ShelfMetaTone.warning => colors.accent,
          ShelfMetaTone.error => Theme.of(context).colorScheme.error,
        };
        final TextStyle subStyle = TextStyle(
          fontSize: subSize,
          fontWeight: FontWeight.w700,
          height: 1.25,
          color: colors.onContainer.withValues(alpha: 0.85),
        );
        final TextStyle titleStyle = TextStyle(
          fontSize: titleSize,
          fontWeight: hero ? FontWeight.w900 : FontWeight.w800,
          height: 1.15,
          letterSpacing: hero ? -0.5 : 0,
          color: colors.onContainer,
        );
        final List<Widget> bottom = <Widget>[
          if (figure != null)
            ConstrainedBox(
              constraints: BoxConstraints(maxWidth: constraints.maxWidth * 0.6),
              child: _BlockFigure(
                figure: figure!,
                fontSize: figureSize,
                colors: colors,
              ),
            ),
          if (_has(chip))
            // 有进度条同排时 chip 最多占六成宽，进度条至少留一截。
            ConstrainedBox(
              constraints: BoxConstraints(
                maxWidth:
                    constraints.maxWidth *
                    (figure != null ? 0.35 : (value == null ? 1 : 0.6)),
              ),
              child: _BlockChip(
                label: chip!,
                colors: colors,
                ghost: eyebrowShown,
              ),
            ),
          if (value != null)
            Expanded(
              child: Padding(
                // 有大数字时进度条贴着数字的基线（`.gb .pg` margin-bottom:6px）。
                padding: EdgeInsets.only(bottom: figure != null ? 6 : 0),
                child: wavy
                    ? SizedBox(
                        height: 10,
                        child: FushiWavyLinearProgress(
                          value: value,
                          color: colors.accent,
                          trackColor: colors.onContainer.withValues(
                            alpha: 0.24,
                          ),
                        ),
                      )
                    : _BlockProgress(value: value, colors: colors),
              ),
            ),
          if (showAction)
            _BlockActionPill(action: action!, colors: colors, compact: compact),
        ];
        return DefaultTextStyle.merge(
          style: TextStyle(color: colors.onContainer),
          child: IconTheme.merge(
            data: IconThemeData(color: colors.onContainer, size: 14),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.end,
              crossAxisAlignment: CrossAxisAlignment.start,
              spacing: gap,
              children: <Widget>[
                if (eyebrowShown)
                  _BlockChip(label: eyebrow!, colors: colors, ghost: false),
                Flexible(
                  child: _BlockTitle(
                    title: title,
                    logo: logo,
                    style: titleStyle,
                    maxLines: titleLines,
                    logoMaxHeight: logoMaxHeight,
                  ),
                ),
                if (shown.contains('byline'))
                  Text(
                    byline!,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: context.fushiType.bodySmall.fontSize,
                      fontWeight: FontWeight.w700,
                      height: 1.3,
                      color: colors.onContainer.withValues(alpha: 0.85),
                    ),
                  ),
                if (shown.contains('subtitle'))
                  Row(
                    spacing: 4,
                    children: <Widget>[
                      if (leadingIcon != null)
                        Icon(leadingIcon, size: 14, color: toneColor),
                      Flexible(
                        child: Text(
                          subtitle!,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: tone == ShelfMetaTone.normal
                              ? subStyle
                              : subStyle.copyWith(color: toneColor),
                        ),
                      ),
                    ],
                  ),
                if (shown.contains('overview'))
                  Text(
                    overview!,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: context.fushiType.bodySmall.fontSize,
                      fontWeight: FontWeight.w600,
                      height: 1.4,
                      color: colors.onContainer.withValues(alpha: 0.85),
                    ),
                  ),
                if (bottom.isNotEmpty)
                  Row(
                    crossAxisAlignment: figure != null
                        ? CrossAxisAlignment.end
                        : CrossAxisAlignment.center,
                    spacing: figure != null ? 14 : 10,
                    children: bottom,
                  ),
                if (shown.contains('trailing'))
                  SizedBox(
                    height: 20,
                    child: Align(
                      alignment: AlignmentDirectional.centerStart,
                      child: trailing,
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// 标题位：有 logo 画 logo（左下对齐、限高，解码失败回落文字），否则是按剩余
/// 高度定行数的标题文字（最多 [maxLines] 行）。
class _BlockTitle extends StatelessWidget {
  const _BlockTitle({
    required this.title,
    required this.logo,
    required this.style,
    required this.maxLines,
    required this.logoMaxHeight,
  });

  final String title;
  final ImageProvider? logo;
  final TextStyle style;
  final int maxLines;
  final double logoMaxHeight;

  @override
  Widget build(BuildContext context) {
    final TextScaler scaler = MediaQuery.textScalerOf(context);
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final double lineHeight =
            scaler.scale(style.fontSize ?? 14) * (style.height ?? 1.15);
        final int lines = constraints.maxHeight.isFinite
            ? (constraints.maxHeight / lineHeight).floor().clamp(1, maxLines)
            : maxLines;
        final Widget text = Text(
          title,
          maxLines: lines,
          overflow: TextOverflow.ellipsis,
          style: style,
        );
        final ImageProvider? image = logo;
        if (image == null) return text;
        return Semantics(
          label: title,
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: constraints.maxHeight.isFinite
                  ? math.min(logoMaxHeight, constraints.maxHeight)
                  : logoMaxHeight,
            ),
            child: Image(
              image: image,
              fit: BoxFit.contain,
              alignment: AlignmentDirectional.bottomStart,
              excludeFromSemantics: true,
              errorBuilder: (BuildContext _, Object __, StackTrace? ___) =>
                  ExcludeSemantics(child: text),
            ),
          ),
        );
      },
    );
  }
}

/// 色块里的 chip（设计稿 `.chip`）：实心 = 强调色底、色块色字；[ghost]（`.chip.g`）
/// = 前景色 14% 底、前景色字。
class _BlockChip extends StatelessWidget {
  const _BlockChip({
    required this.label,
    required this.colors,
    required this.ghost,
  });

  final String label;
  final FushiCoverBlockColors colors;
  final bool ghost;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: ShapeDecoration(
        shape: const StadiumBorder(),
        color: ghost
            ? colors.onContainer.withValues(alpha: 0.14)
            : colors.accent,
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 5),
        child: Text(
          label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: context.fushiType.labelSmall.fontSize,
            fontWeight: FontWeight.w800,
            height: 1.25,
            color: ghost ? colors.onContainer : colors.container,
          ),
        ),
      ),
    );
  }
}

/// 大数字（`.gb .hrs` / `.mb .huge`）：强调色粗体数值 + 小号单位，放不下时整体
/// 等比缩小。
class _BlockFigure extends StatelessWidget {
  const _BlockFigure({
    required this.figure,
    required this.fontSize,
    required this.colors,
  });

  final FushiCoverBlockFigure figure;
  final double fontSize;
  final FushiCoverBlockColors colors;

  @override
  Widget build(BuildContext context) {
    return FittedBox(
      fit: BoxFit.scaleDown,
      alignment: AlignmentDirectional.bottomStart,
      child: Text.rich(
        TextSpan(
          children: <InlineSpan>[
            TextSpan(text: figure.value),
            TextSpan(
              text: ' ${figure.unit}',
              style: TextStyle(
                fontSize: math.max(12, fontSize * 0.26),
                letterSpacing: 0,
                fontWeight: FontWeight.w800,
              ),
            ),
          ],
        ),
        maxLines: 1,
        softWrap: false,
        style: TextStyle(
          fontSize: fontSize,
          fontWeight: FontWeight.w900,
          height: 0.85,
          letterSpacing: -0.05 * fontSize,
          color: colors.accent,
        ),
      ),
    );
  }
}

/// 拼贴首块的主按钮外观（`.btnA`）。纯视觉，见 [FushiCoverBlockAction]。
class _BlockActionPill extends StatelessWidget {
  const _BlockActionPill({
    required this.action,
    required this.colors,
    required this.compact,
  });

  final FushiCoverBlockAction action;
  final FushiCoverBlockColors colors;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    return ExcludeSemantics(
      child: SizedBox(
        height: compact ? 44 : 52,
        child: DecoratedBox(
          decoration: ShapeDecoration(
            shape: shellShape(
              context,
              BorderRadius.circular(compact ? 15 : 18),
            ),
            color: colors.accent,
          ),
          child: Padding(
            padding: EdgeInsetsDirectional.fromSTEB(
              compact ? 12 : 18,
              0,
              compact ? 16 : 22,
              0,
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              spacing: 8,
              children: <Widget>[
                Icon(action.icon, size: 22, color: colors.container),
                Text(
                  action.label,
                  maxLines: 1,
                  style: TextStyle(
                    fontSize: compact ? 14 : 15,
                    fontWeight: FontWeight.w900,
                    color: colors.container,
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

/// 6px 圆头进度条：轨道 = 前景色 20%，填充 = 强调色。
class _BlockProgress extends StatelessWidget {
  const _BlockProgress({required this.value, required this.colors});

  final double value;
  final FushiCoverBlockColors colors;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(3),
      child: SizedBox(
        height: 6,
        child: Stack(
          fit: StackFit.expand,
          children: <Widget>[
            ColoredBox(color: colors.onContainer.withValues(alpha: 0.2)),
            FractionallySizedBox(
              alignment: AlignmentDirectional.centerStart,
              widthFactor: value,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: colors.accent,
                  borderRadius: BorderRadius.circular(3),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
