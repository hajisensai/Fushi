import 'dart:math' as math;

import 'package:flutter/gestures.dart'
    show PointerDeviceKind, PointerEnterEvent, PointerHoverEvent;
import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/adaptive/shell_style.dart';
import 'package:fushi/src/utils/components/fushi_continue_card_row.dart';
import 'package:fushi/src/utils/components/fushi_expressive_progress.dart';
import 'package:fushi/src/utils/components/fushi_fit_title.dart';
import 'package:fushi/src/utils/components/fushi_generated_cover.dart';
import 'package:fushi/src/utils/components/fushi_logo_title.dart';
import 'package:fushi/src/utils/components/fushi_motion_tokens.dart';
import 'package:fushi/src/utils/components/fushi_typography.dart';
import 'package:fushi/src/utils/components/nsfw_cover_blur.dart';
import 'package:fushi/src/utils/components/shelf_card_widgets.dart';
import 'package:fushi/src/utils/components/shelf_cover_material.dart';

// =============================================================================
// 封面色块卡（库页「拼贴 / 规整色块」布局，见 [ShellContentLayout]）。
//
// 一块圆角色块，底色取封面色（[coverColorSchemeCache]，MD3 / Apple 都取），
// 文字区上半垫一层装满盒子的大字水印（[FushiFitTitle]：整段标题取放得下的最大
// 字号、可换行、完整显示，放不下最小字号就不画；只给带封面的媒体块，调用方可用
// [FushiCoverBlock.watermark] 关掉），前景是倾斜的封面（视频 / 书 / 漫画 / 专辑 /
// 游戏各一种摆法；没封面时按标题生成 [FushiGeneratedCover]）+ 标题 + 副行 +
// 进度条。给了 [FushiCoverBlock.disc] 时换成「唱片从封套里滑出半张」摆法（文字区
// 与原摆法同一套）。海报元数据层（设计稿 `.vb` 的背景图 / logo /
// 状态 chip / 概览 / 信息 chip / 波浪进度 + 主按钮，书的署名，游戏 / 漫画的大数字）
// 都是可选参数：调用点只传库里已有的数据，没有的那一项整行不画。
// 鼠标悬停时水印沿 X 轻移、封面各自换到悬停姿态，
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
    this.hue,
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
    if (cover != null) {
      return FushiCoverBlockColors.fromHue(
        theme,
        HSLColor.fromColor(cover.primary).hue,
      );
    }
    final ColorScheme s = theme.colorScheme;
    return FushiCoverBlockColors(
      container: s.surfaceContainerHigh,
      onContainer: s.onSurface,
      accent: dark ? s.primary : s.onSurface,
      watermarkOpacity: watermark,
    );
  }

  /// 按色相 [hue] 派生（[resolve] 的封面分支；没封面的块按标题哈希给色相，与
  /// [FushiGeneratedCover] 同色，见 [fushiGeneratedCoverHue]）。
  ///
  /// [depth] = 同色相的第几档底色（0 = 标准档）：同一个色块里要并排区分几块
  /// 子块（例如从色块弹出的二选一对话框里的两张选项卡）时用，只动底色明度，
  /// 前景 / 强调色不变。档位往远离前景的方向走（深色每档压暗 6%、浅色每档提亮
  /// 6%），与块里弹出的对话框面板（块底叠前景色、朝前景方向）拉开，前景对比度只升
  /// 不降。
  factory FushiCoverBlockColors.fromHue(
    ThemeData theme,
    double hue, {
    int depth = 0,
  }) {
    final bool dark = theme.brightness == Brightness.dark;
    final double watermark = dark ? 0.3 : 0.13;
    Color hsl(double s, double l) => HSLColor.fromAHSL(1, hue, s, l).toColor();
    if (dark) {
      return FushiCoverBlockColors(
        container: hsl(0.32, 0.19 - 0.06 * depth),
        onContainer: hsl(0.45, 0.92),
        accent: hsl(0.60, 0.76),
        watermarkOpacity: watermark,
        hue: hue,
      );
    }
    final Color on = hsl(0.50, 0.20);
    return FushiCoverBlockColors(
      container: hsl(0.45, 0.89 + 0.06 * depth),
      onContainer: on,
      accent: on,
      watermarkOpacity: watermark,
      hue: hue,
    );
  }

  final Color container;
  final Color onContainer;
  final Color accent;
  final double watermarkOpacity;

  /// 派生这套配色的色相；null = 主题中性色（没封面 / 墨水屏，见 [resolve]）。
  /// 色块给子树下发局部配色（`FushiBlockColorScope`）时据此判断是不是有彩块。
  final double? hue;
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

/// 承载色块的**会裁切的视口**（横滑 ListView / GridView / PageView）要向四周
/// 外扩的量：投影越出块边的距离连同悬停放大（1.05 倍）都留在视口里，不被视口
/// 矩形裁成一圈带硬边的直角框（设计稿 11-20 #14「大卡外面有一圈框」）。左右取
/// 页边距 20：再宽就画进侧栏，投影尾巴那 1～2px 的淡影被页边裁掉看不出来。
///
/// 半高卡（[FushiCoverBlockSize.half]）：[kFushiCoverBlockHalfShadowExtent] + 放大。
final EdgeInsets kFushiCoverBlockHalfBleed = EdgeInsets.fromLTRB(
  20,
  kFushiCoverBlockHalfShadowExtent.top + 3,
  20,
  kFushiCoverBlockHalfShadowExtent.bottom + 5,
);

/// 整块 / 拼贴首块（模糊 26、下移 10）：上 16、下 36、左右 26 再加放大余量。
const EdgeInsets kFushiCoverBlockRegularBleed = EdgeInsets.fromLTRB(
  20,
  22,
  20,
  42,
);

/// [size] 色块所需的视口外扩量。
EdgeInsets fushiCoverBlockBleed(FushiCoverBlockSize size) =>
    size == FushiCoverBlockSize.half
    ? kFushiCoverBlockHalfBleed
    : kFushiCoverBlockRegularBleed;

/// 让会裁切的滚动视口给投影留出空间：视口（[builder] 建的滚动件）向四周外扩
/// [bleed]、再把同样的量作为内边距交回给滚动件，内容起点与布局占位都不变，
/// 投影整段画在视口里。外扩区不参与命中测试（在本件尺寸之外）。
///
/// 带投影的色块放进横滑行 / 轮播时一律经它包，不要直接把 [ListView] /
/// [PageView] 卡在色块外框上（视口按自身矩形硬裁，柔和投影会被切成直角框）。
class FushiShadowBleedViewport extends StatelessWidget {
  const FushiShadowBleedViewport({
    required this.bleed,
    required this.builder,
    super.key,
  });

  final EdgeInsets bleed;

  /// 拿到内边距（= [bleed]）建滚动件：ListView 等直接给 `padding`，PageView 给
  /// 每页包一层 [Padding]。
  final Widget Function(BuildContext context, EdgeInsets padding) builder;

  @override
  Widget build(BuildContext context) => Stack(
    clipBehavior: Clip.none,
    children: <Widget>[
      Positioned(
        left: -bleed.left,
        top: -bleed.top,
        right: -bleed.right,
        bottom: -bleed.bottom,
        child: builder(context, bleed),
      ),
    ],
  );
}

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

/// 前景封面槽按封面真实比例定宽时的夹取范围（宽 / 高）：超出的极端比例
/// （横幅图、超长条）仍按边界比例定槽，fitHeight 从两侧裁或露衬底，不让
/// 封面挤掉文字区。与合集详情页头部封面同一范围。
const double kFushiCoverBlockCoverAspectMin = 0.55;
const double kFushiCoverBlockCoverAspectMax = 0.85;

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
    this.watermark = true,
    this.disc,
    this.backdropAspectRatio,
    super.key,
  });

  /// 标题：前景标题与大字水印同一份。
  final String title;

  /// 背景图（设计稿 `.vb .bd`：无字横版背景 / 剧照）：按图片原比例铺在右侧
  /// （槽宽 = 块高 × [backdropAspectRatio]，靠右对齐，不从两侧裁），左缘渐隐进
  /// 色块，底部再压一层封面色渐变（`.shade`）。只在
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

  /// 底行信息 chip（「TV · 2026 · 12 集」、音频规格、唱片摆法的「CD」等），与
  /// 进度条同排。
  final String? chip;

  /// 底行的大数字（话数 / 游玩时长）。
  final FushiCoverBlockFigure? figure;

  /// 拼贴首块的主按钮，排在底行末尾。只在拼贴首块画。
  final FushiCoverBlockAction? action;

  /// 大字水印开关。水印只给**带封面的媒体块**（设计稿 G2）：[covers] 为空（画
  /// 生成封面）时不画；统计 / 列表 / 空状态这类块调用方传 false。
  final bool watermark;

  /// 唱片盘面图（专辑目录里真实的盘面扫描图）。给了就换成「唱片从封套里滑出半张」
  /// 摆法：方形封面立在起始侧，唱片垫在封面后面、从结束侧露出约四成；悬停时
  /// 唱片再滑出一截并转动、封面再斜一点。文字区（水印 / 标题 / 副行 / chip）与
  /// 原摆法同一套，只是从唱片之后起排（2026-11-21 用户：音乐页参照别的模块重做，
  /// 原 W 原型的整块标题大字版式退役）。圆形、中心孔与投影由传入的 widget 自己画
  /// （音乐页传 `musicDiscArtImage`），这里只给方形槽；不做假唱片——没有盘面图就
  /// 别传。null = 原摆法。
  final Widget? disc;

  /// 背景图的宽高比；null = 从 [backdrop]（横版摆法是 [covers] 首个）取图源
  /// 解码后的真实比例，取不到时按 16:9。
  final double? backdropAspectRatio;

  /// 前景封面（首个 = 最前那本 / 那张；[FushiCoverBlockArt.book] 最多画 3 本，
  /// [FushiCoverBlockArt.portrait] 首个之后的画成后面的叠层）。为空时画按标题
  /// 生成的封面（[FushiGeneratedCover]），色块底色也取同一色相。
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

  /// 水印 / 唱片标题沿阅读方向的横移（逻辑像素，正 = 往末端）。
  late final AnimationController _watermark = AnimationController.unbounded(
    vsync: this,
  );

  /// 唱片摆法里封面的姿态（W 原型封面进出都是 `k 300, c 20`，与唱片悬停那条
  /// 更软的弹簧分开走）。
  late final AnimationController _coverPose = AnimationController.unbounded(
    vsync: this,
  );

  bool _hovered = false;

  @override
  void dispose() {
    _backdropProbe.stop();
    _coverProbe.stop();
    _pose.dispose();
    _coverPose.dispose();
    _watermark.dispose();
    super.dispose();
  }

  /// 背景图 + 左侧斜放封面并存（设计稿 `.vb` 有 `bd` 又有 `ps` 的形态）。墨水屏
  /// 不画照片背景（色块本身已是中性色）；唱片摆法不画背景图。
  bool get _hasBackdrop =>
      widget.backdrop != null &&
      widget.disc == null &&
      widget.art == FushiCoverBlockArt.portrait &&
      !isEinkTheme(context);

  /// 唱片摆法（[FushiCoverBlock.disc]）。
  bool get _hasDisc => widget.disc != null;

  /// 单张竖海报（没有叠层）走「海报完整立在起始侧」的几何，有没有背景图都一样：
  /// 旧的「尾侧斜放、上下出血」摆法在没有剧照时把海报上下裁掉一截（用户
  /// 2026-11-16「组件有点问题」截图：今日放送 / 无剧照条目）。多成员叠层仍走
  /// 原摆法。
  bool get _posterLead =>
      _hasBackdrop ||
      (widget.art == FushiCoverBlockArt.portrait &&
          !_hasDisc &&
          widget.covers.length <= 1);

  /// 画大字水印：开关打开、有真封面（生成封面不算）。
  bool get _showWatermark => widget.watermark && widget.covers.isNotEmpty;

  FushiSpringSpec _spec(FushiSpringSpec spec) =>
      fushiMotionEnabled(context) ? spec : spec.reduced;

  void _setHover(bool hovered) {
    if (!widget.hoverEnabled && hovered) return;
    if (hovered == _hovered) return;
    _hovered = hovered;
    _pose.fushiSpringTo(
      hovered ? 1 : 0,
      _spec(hovered ? kFushiCoverBlockHoverSpring : kFushiCoverBlockRestSpring),
    );
    _coverPose.fushiSpringTo(
      hovered ? 1 : 0,
      _spec(kFushiCoverBlockRestSpring),
    );
    // 水印装在盒子里，只轻移一点，不滑出盒子被色块裁成半个字。
    _watermark.fushiSpringTo(
      hovered ? 6 : 0,
      _spec(kFushiCoverBlockWatermarkSpring),
    );
  }

  @override
  void didUpdateWidget(FushiCoverBlock oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!widget.hoverEnabled && _hovered) _setHover(false);
    _resolveTint();
    _resolveImageAspect();
  }

  void _onHover(PointerEvent event) {
    if (event.kind != PointerDeviceKind.mouse) return;
    _setHover(true);
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
    _resolveImageAspect();
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

  // ---- 图片的真实宽高比：横版背景图（V1：槽宽按原比例，不从两侧裁）与前景
  // 封面（封面槽按封面原比例定宽，fitHeight 铺满不裁、不露衬底） ----

  late final FushiImageAspectProbe _backdropProbe = FushiImageAspectProbe(
    _onAspect,
  );
  late final FushiImageAspectProbe _coverProbe = FushiImageAspectProbe(
    _onAspect,
  );

  void _onAspect() {
    if (mounted) setState(() {});
  }

  /// 背景槽里那张图的图源：背景图 + 海报摆法取 [FushiCoverBlock.backdrop]，
  /// 横版摆法取首个封面；只认 `Image` / `FadeInImage`（[fushiCoverImageOf]）。
  ImageProvider? _aspectSource() {
    if (widget.backdropAspectRatio != null || _hasDisc) return null;
    final Widget? source = _hasBackdrop
        ? widget.backdrop
        : (widget.art == FushiCoverBlockArt.landscape &&
                  widget.covers.isNotEmpty
              ? widget.covers.first
              : null);
    return source == null ? null : fushiCoverImageOf(source);
  }

  /// 前景封面槽（海报 / 书封）按比例定宽用的图源：首个封面（最前那本）。
  /// 横版摆法的首个封面是背景剧照、唱片摆法另有几何，不探。
  ImageProvider? _coverAspectSource() {
    if (_hasDisc ||
        widget.covers.isEmpty ||
        widget.art == FushiCoverBlockArt.landscape) {
      return null;
    }
    return fushiCoverImageOf(widget.covers.first);
  }

  void _resolveImageAspect() {
    final ImageConfiguration config = createLocalImageConfiguration(context);
    _backdropProbe.track(_aspectSource(), config);
    _coverProbe.track(_coverAspectSource(), config);
  }

  /// 背景槽用的宽高比：调用方显式给的 → 解码出的 → 16:9。
  double get _backdropAspect =>
      widget.backdropAspectRatio ?? _backdropProbe.aspect ?? 16 / 9;

  /// 前景封面的真实宽高比（夹在 [kFushiCoverBlockCoverAspectMin] /
  /// [kFushiCoverBlockCoverAspectMax] 内）；null = 还没解出 / 取不到图源，
  /// 几何用各摆法的默认比例。
  double? get _coverAspect => _coverProbe.aspect
      ?.clamp(kFushiCoverBlockCoverAspectMin, kFushiCoverBlockCoverAspectMax)
      .toDouble();

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    // 没封面也没取色图：底色取生成封面同一色相（墨水屏仍是中性色）。
    final FushiCoverBlockColors colors =
        _scheme == null && widget.covers.isEmpty && !isEinkTheme(context)
        ? FushiCoverBlockColors.fromHue(
            theme,
            fushiGeneratedCoverHue(widget.title),
          )
        : FushiCoverBlockColors.resolve(theme, _scheme);
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final Size size = constraints.biggest;
        return MouseRegion(
          opaque: false,
          onEnter: (PointerEnterEvent e) => _onHover(e),
          onHover: (PointerHoverEvent e) => _onHover(e),
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
            if (_hasDisc)
              ..._buildDiscBlock(context, colors, size, direction)
            else
              ..._buildCoverBlock(context, colors, size, direction),
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

  /// 原摆法：水印 → 封面 / 背景图 → 文字区。
  List<Widget> _buildCoverBlock(
    BuildContext context,
    FushiCoverBlockColors colors,
    Size size,
    TextDirection direction,
  ) {
    // 几何一律按 LTR（封面在左 / 在右与设计稿一致）算，RTL 整体水平镜像。
    final _BlockGeometry ltrGeo = _posterLead
        ? _BlockGeometry.backdropPoster(
            widget.size,
            size,
            _backdropAspect,
            coverAspect: _coverAspect,
          )
        : _BlockGeometry.of(
            widget.art,
            widget.size,
            size,
            coverCount: widget.covers.length,
            backdropAspect: _backdropAspect,
            coverAspect: _coverAspect,
          );
    final _BlockGeometry geo = direction == TextDirection.rtl
        ? ltrGeo.mirrored(size.width)
        : ltrGeo;
    return <Widget>[
      if (_showWatermark) _buildWatermark(colors, size, ltrGeo.text, direction),
      ..._buildArt(context, colors, geo, direction),
      _buildText(context, colors, size, geo.text, geo.titleLines),
    ];
  }

  /// 文字区（标题 / 副行 / 进度 / chip 等，[_BlockText]），原摆法与唱片摆法共用。
  Widget _buildText(
    BuildContext context,
    FushiCoverBlockColors colors,
    Size size,
    Rect rect,
    int titleLines,
  ) => Positioned.fromRect(
    rect: rect,
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
        titleLines: titleLines,
        // 半高卡也画 logo（BUG-5252：首页「最近添加」/「继续」的小块对刮削过的
        // 作品只剩标题文字 + 大字水印，与库页同一张系列卡对不上）。logo 一律
        // 进固定标题槽（半高档 40 高，与两行标题文字同高），放不下时先丢次要行，
        // 不会再压到副行 / 进度上（2026-11-12 BLEACH 截图是固定槽之前的问题）。
        logo: isEinkTheme(context) ? null : widget.logo,
        // 海报元数据层（有 logo 或背景图）的标题走固定标题槽：有没有 logo、
        // logo 横长还是偏方，标题区都一样大（2026-11-21 用户拍板）。半高卡没有
        // logo 时仍按剩余高度排两行标题文字。
        titleSlot: widget.size == FushiCoverBlockSize.half
            ? widget.logo != null && !isEinkTheme(context)
            : widget.logo != null || widget.backdrop != null,
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
            (widget.size == FushiCoverBlockSize.hero && size.height < 260),
      ),
    ),
  );

  /// 唱片摆法：水印 → 唱片（垫在后面、从封套结束侧滑出）→ 封面 → 文字区。
  List<Widget> _buildDiscBlock(
    BuildContext context,
    FushiCoverBlockColors colors,
    Size size,
    TextDirection direction,
  ) {
    final _DiscGeometry ltrGeo = _DiscGeometry.of(widget.size, size);
    final _DiscGeometry geo = direction == TextDirection.rtl
        ? ltrGeo.mirrored(size.width)
        : ltrGeo;
    final Widget cover = widget.covers.isEmpty
        ? FushiGeneratedCover(title: widget.title)
        : widget.covers.first;
    return <Widget>[
      if (_showWatermark) _buildWatermark(colors, size, ltrGeo.text, direction),
      _posed(geo.disc, _DiscFace(child: widget.disc!)),
      _posed(
        geo.cover,
        _CoverCard(radius: 12, overlay: widget.coverOverlay, child: cover),
        animation: _coverPose,
      ),
      _buildText(context, colors, size, geo.text, geo.titleLines),
    ];
  }

  /// 大字水印：纯装饰，不进语义、不参与命中。装在文字区上半的盒子里
  /// （[FushiFitTitle]：整段标题取放得下的最大字号、可换行、完整显示），连最小
  /// 字号都放不下就不画——不再出血裁成半个字（设计稿 G2）。[ltrText] 是未镜像的
  /// 文字区，盒子按 LTR 量出来再镜像。
  Widget _buildWatermark(
    FushiCoverBlockColors colors,
    Size size,
    Rect ltrText,
    TextDirection direction,
  ) {
    final double h = size.height;
    final Rect ltrBox = Rect.fromLTRB(
      ltrText.left,
      h * 0.05,
      ltrText.right,
      h * 0.62,
    );
    final Rect box = direction == TextDirection.rtl
        ? _mirrorRect(ltrBox, size.width)
        : ltrBox;
    return Positioned.fromRect(
      rect: box,
      child: FushiFitTitle(
        text: widget.title,
        color: colors.accent.withValues(alpha: colors.watermarkOpacity),
        maxSize: h * 0.5,
        minSize: math.max(22, h * 0.12),
        align: FushiFitTitleAlign.top,
        shift: _watermark,
        direction: direction,
      ),
    );
  }

  List<Widget> _buildArt(
    BuildContext context,
    FushiCoverBlockColors colors,
    _BlockGeometry geo,
    TextDirection direction,
  ) {
    final List<Widget> covers = widget.covers.isEmpty
        ? <Widget>[FushiGeneratedCover(title: widget.title)]
        : widget.covers;
    if (_posterLead) {
      // 背景图在右（slots[0]），2:3 封面斜放在左（slots[1]）压在背景图与大字上；
      // 没有背景图时右侧只留色块底。
      return <Widget>[
        if (_hasBackdrop) ...<Widget>[
          _posed(
            geo.slots.first,
            _fadedBackdrop(widget.backdrop!, direction, geo.backdropFadeStart),
          ),
          _shade(colors),
        ],
        _posed(
          geo.slots[1],
          _CoverCard(
            radius: geo.coverRadius,
            overlay: widget.coverOverlay,
            child: covers.first,
          ),
        ),
      ];
    }
    if (widget.art == FushiCoverBlockArt.landscape) {
      return <Widget>[
        _posed(
          geo.slots.first,
          _withCoverOverlay(
            _fadedBackdrop(covers.first, direction, geo.backdropFadeStart),
          ),
        ),
        _shade(colors),
      ];
    }
    // 摆放序：后面的先画、最前那张最后画（压在最上面）。
    final int count = math.min(covers.length, geo.slots.length);
    final List<Widget> out = <Widget>[];
    for (int i = count - 1; i >= 0; i--) {
      final _CoverSlot slot = geo.slots[i];
      out.add(
        _posed(
          slot,
          _CoverCard(
            radius: geo.coverRadius,
            // 盖层只压最前那张（i == 0），与它同一个姿态变换 / 圆角裁切。
            overlay: i == 0 ? widget.coverOverlay : null,
            child: covers[i],
          ),
        ),
      );
    }
    return out;
  }

  /// 横版剧照槽没有 [_CoverCard]：盖层同样叠进剧照所在的那个 [_posed] 里，
  /// 不另起一个不随姿态变换走的兄弟层。
  Widget _withCoverOverlay(Widget art) {
    final Widget? overlay = widget.coverOverlay;
    if (overlay == null) return art;
    return Stack(
      fit: StackFit.expand,
      children: <Widget>[
        art,
        Positioned.fill(child: overlay),
      ],
    );
  }

  /// 横版背景图：起始缘（LTR 左 / RTL 右）渐隐进色块。图按原比例铺满槽、不裁，
  /// 渐隐从槽在色块里**露出来的**起始缘（[fadeStart]，槽比色块宽时左段在块外）
  /// 起，走余下的 45% 到全显。
  Widget _fadedBackdrop(
    Widget image,
    TextDirection direction,
    double fadeStart,
  ) => ShaderMask(
    blendMode: BlendMode.dstIn,
    shaderCallback: (Rect r) => LinearGradient(
      begin: AlignmentDirectional.centerStart,
      end: AlignmentDirectional.centerEnd,
      colors: const <Color>[Color(0x00000000), Color(0xFF000000)],
      stops: <double>[fadeStart, fadeStart + (1 - fadeStart) * 0.45],
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
  /// [animation] 缺省走 [_pose]。
  Widget _posed(_CoverSlot slot, Widget child, {Animation<double>? animation}) {
    final Animation<double> driver = animation ?? _pose;
    return Positioned.fromRect(
      rect: slot.rect,
      child: IgnorePointer(
        child: AnimatedBuilder(
          animation: driver,
          builder: (BuildContext context, Widget? child) {
            final double t = driver.value;
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

/// 背景图 + 海报摆法里，斜放海报（静止 / 悬停姿态）的外接框离色块边缘的最小距离。
const double _kPosterEdgeMargin = 4;

/// [slot] 按姿态 [pose] 变换（绕 [_CoverSlot.origin] 旋转 / 缩放、再平移，与
/// `_posed` 的 [Transform] 同一算式）后四个角的外接框。
Rect _poseBounds(_CoverSlot slot, _Pose pose) {
  final Rect r = slot.rect;
  final Offset o = slot.origin.withinRect(r);
  final double theta = pose.rotation * math.pi / 180;
  final double c = math.cos(theta);
  final double sn = math.sin(theta);
  double l = double.infinity;
  double t = double.infinity;
  double rt = -double.infinity;
  double b = -double.infinity;
  for (final Offset p in <Offset>[
    r.topLeft,
    r.topRight,
    r.bottomLeft,
    r.bottomRight,
  ]) {
    final double x = (p.dx - o.dx) * pose.scale;
    final double y = (p.dy - o.dy) * pose.scale;
    final double px = o.dx + pose.dx + x * c - y * sn;
    final double py = o.dy + pose.dy + x * sn + y * c;
    l = math.min(l, px);
    t = math.min(t, py);
    rt = math.max(rt, px);
    b = math.max(b, py);
  }
  return Rect.fromLTRB(l, t, rt, b);
}

/// 一组槽在静止与悬停两个姿态下的总外接框。
Rect _slotsBounds(List<_CoverSlot> slots) {
  Rect? out;
  for (final _CoverSlot slot in slots) {
    for (final _Pose pose in <_Pose>[slot.rest, slot.hover]) {
      final Rect b = _poseBounds(slot, pose);
      out = out == null ? b : out.expandToInclude(b);
    }
  }
  return out ?? Rect.zero;
}

/// 各摆法的几何（设计稿 `.vb` / `.bk` / `.mb` / `.ab` / `.gb` 换算）。
@immutable
class _BlockGeometry {
  const _BlockGeometry({
    required this.slots,
    required this.text,
    required this.coverRadius,
    required this.titleLines,
    this.backdropFadeStart = 0,
  });

  /// 横版背景图槽（V1）：图按原比例铺满整高，槽宽 = 块高 × [aspect]，靠右对齐
  /// （槽比色块宽时左段落在块外、被色块裁掉，再沉进渐隐）。悬停只以右缘为轴
  /// 放大，不横移——横移会把右缘拉进来、露出槽外的色块底。
  static (_CoverSlot, double) _backdropSlot(double w, double h, double aspect) {
    final double sw = h * (aspect > 0 ? aspect : 16 / 9);
    return (
      _CoverSlot(
        rect: Rect.fromLTWH(w - sw, 0, sw, h),
        rest: const _Pose(),
        hover: const _Pose(scale: 1.06),
        origin: Alignment.centerRight,
      ),
      // 渐隐从露出来的起始缘起（槽在块外那段的占比）。
      sw > w ? (sw - w) / sw : 0,
    );
  }

  factory _BlockGeometry.of(
    FushiCoverBlockArt art,
    FushiCoverBlockSize size,
    Size box, {
    required int coverCount,
    double backdropAspect = 16 / 9,
    double? coverAspect,
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
        final double cw = math.min(ch * (coverAspect ?? 2 / 3), w * 0.42);
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
        // 横版剧照：按原比例靠右铺满整高，左缘渐隐；文字压在底部压暗上。
        final (_CoverSlot slot, double fade) = _backdropSlot(
          w,
          h,
          backdropAspect,
        );
        return _BlockGeometry(
          slots: <_CoverSlot>[slot],
          text: Rect.fromLTRB(pad + 2, pad, w - pad, h - (half ? 10 : 16)),
          coverRadius: 0,
          titleLines: lines,
          backdropFadeStart: fade,
        );
      case FushiCoverBlockArt.book:
        // 书：左侧扇形（设计稿 `.bk .fan`），右侧文字。
        final double top0 = half ? 12 : 20;
        final double fanLeft0 = half ? 18 : (hero ? 34 : 26);
        final double fanW = w * (hero ? 0.38 : 0.44);
        final int n = coverCount.clamp(1, 3);
        const List<(_Pose, _Pose)> fan = <(_Pose, _Pose)>[
          (_Pose(rotation: 6), _Pose(rotation: 15, dx: 14)),
          (_Pose(rotation: -2), _Pose(rotation: -3, dy: -10)),
          (_Pose(rotation: -9), _Pose(rotation: -18, dx: -12)),
        ];
        // 书封槽按最前那本的真实比例定宽（fitHeight 铺满、不裁不露衬底）；
        // 解出前按书封默认比例。
        List<_CoverSlot> fanSlots(double left, double top, double ch) {
          final double cw = math.min(
            ch * (coverAspect ?? kShelfBookCoverAspectRatio),
            fanW,
          );
          if (n == 1) {
            return <_CoverSlot>[
              _CoverSlot(
                rect: Rect.fromLTWH(left + fanW * 0.08, top, cw, ch),
                rest: const _Pose(rotation: -5),
                hover: const _Pose(rotation: -10, dy: -6, scale: 1.03),
                origin: Alignment.bottomCenter,
              ),
            ];
          }
          // 首个（最前）放在最右、最后画；其余依次往左后方。
          return <_CoverSlot>[
            for (int i = 0; i < n; i++)
              _CoverSlot(
                rect: Rect.fromLTWH(
                  left + fanW * 0.17 * (n - 1 - i),
                  top,
                  cw,
                  ch,
                ),
                rest: fan[i + (3 - n)].$1,
                hover: fan[i + (3 - n)].$2,
                origin: Alignment.bottomCenter,
              ),
          ];
        }

        // 扇形绕底边中点斜放，转角让封面的角探出槽外：块越高、书封越高，探出
        // 越多——「最近添加」这种高格子里最左那本的左上角与下角被色块圆角裁掉
        // （反馈 ONOhm9EOY3）。静止与悬停两个姿态的外接框都要落在色块里（离边
        // [_kPosterEdgeMargin]，同背景图 + 海报摆法）：高或宽放不下就按比例缩
        // 书封，再整体平移进来。
        double ch = h - top0 * 2;
        double top = top0;
        double left = fanLeft0;
        final double roomH = h - _kPosterEdgeMargin * 2;
        final double roomW = w - _kPosterEdgeMargin * 2;
        for (int pass = 0; pass < 8; pass++) {
          final Rect span = _slotsBounds(fanSlots(left, top, ch));
          final double k = math.min(roomH / span.height, roomW / span.width);
          if (k >= 1 - 1e-4) break;
          ch *= k;
        }
        final Rect bounds = _slotsBounds(fanSlots(left, top, ch));
        if (bounds.top < _kPosterEdgeMargin) {
          top += _kPosterEdgeMargin - bounds.top;
        } else if (bounds.bottom > h - _kPosterEdgeMargin) {
          top -= bounds.bottom - (h - _kPosterEdgeMargin);
        }
        if (bounds.left < _kPosterEdgeMargin) {
          left += _kPosterEdgeMargin - bounds.left;
        } else if (bounds.right > w - _kPosterEdgeMargin) {
          left -= bounds.right - (w - _kPosterEdgeMargin);
        }
        final List<_CoverSlot> slots = fanSlots(left, top, ch);
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
        // 专辑：起始侧方形封面（设计稿 `.ab .cv`），右侧文字。封面边长另限在块宽
        // 的 0.42 以内并垂直居中：规整块（约 470 × 280）按块高给封面会占掉近一半
        // 宽度，长专辑名只剩两三个词就被截断（2026-11-21 音乐页重做实测）。
        final double s = math.min(h - (half ? 24 : 40), w * 0.42);
        final double left = half ? 12 : 20;
        return _BlockGeometry(
          slots: <_CoverSlot>[
            _CoverSlot(
              rect: Rect.fromLTWH(left, (h - s) / 2, s, s),
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

  /// 背景图 + 左侧封面（设计稿 `.vb` 有 `bd` 又有 `ps`）：slots[0] = 右侧按原
  /// 比例铺的背景图（[_backdropSlot]：槽宽 = 块高 × [aspect]，悬停以右缘为轴只
  /// 放大 1.06），slots[1] =
  /// 左侧封面（`r:-5` / `r:-10;x:-3;y:-3;s:1.04`）：槽宽 = 槽高 × 封面真实
  /// 比例 [coverAspect]（解出前 2:3）。封面图按 fitHeight 铺，槽比图窄就从两侧
  /// 裁、比图宽就露衬底，所以槽必须跟图同比例——漫画 / 轻小说封面多在
  /// 0.64～0.70，固定 2:3 会把竖排书名所在的左右边裁掉。文字从封面右侧起
  /// （`left: 16 + 封面宽 + 22`），压在背景图上。
  factory _BlockGeometry.backdropPoster(
    FushiCoverBlockSize size,
    Size box,
    double aspect, {
    double? coverAspect,
  }) {
    final double w = box.width;
    final double h = box.height;
    final bool half = size == FushiCoverBlockSize.half;
    final bool compact = !half && h < 200;
    final double inset = half ? 10 : (compact ? 12 : 16);
    final double a = coverAspect ?? 2 / 3;
    const _Pose rest = _Pose(rotation: -5);
    const _Pose hover = _Pose(rotation: -10, dx: -3, dy: -3, scale: 1.04);
    // 斜放的海报绕中心转 θ、放大 s、再平移 (dx, dy) 后，外接框半高 =
    // s·(pw·|sinθ| + ph·|cosθ|)/2、半宽 = s·(pw·|cosθ| + ph·|sinθ|)/2。静止与
    // 悬停两个姿态都要整张落在色块里（离边 [_kPosterEdgeMargin]）：色块有大圆角
    // 并裁切，越界的那角 / 那条边会被裁掉（2026-11-16 用户截图：悬停时海报左上
    // 角探出色块、被圆角吃掉）。海报高取设计高（上下各让 inset）与两个姿态
    // 放得下的高里较小者，垂直居中；左缘取设计位与两个姿态不越左缘的位里较大者。
    double halfH(_Pose pose, double ph) {
      final double t = pose.rotation.abs() * math.pi / 180;
      return pose.scale * ph * (a * math.sin(t) + math.cos(t)) / 2;
    }

    double halfW(_Pose pose, double ph) {
      final double t = pose.rotation.abs() * math.pi / 180;
      return pose.scale * ph * (a * math.cos(t) + math.sin(t)) / 2;
    }

    double ph = h - inset * 2;
    for (final _Pose pose in const <_Pose>[rest, hover]) {
      // halfH 对 ph 线性：halfH(pose, ph) + |dy| ≤ h/2 − margin。
      final double room = h / 2 - _kPosterEdgeMargin - pose.dy.abs();
      ph = math.min(ph, room / halfH(pose, 1));
    }
    final double pw = ph * a;
    double left = half ? 12 : inset;
    for (final _Pose pose in const <_Pose>[rest, hover]) {
      // 中心 x = left + pw/2；外接框左缘 = 中心 + dx − halfW ≥ margin。
      left = math.max(
        left,
        _kPosterEdgeMargin - pose.dx + halfW(pose, ph) - pw / 2,
      );
    }
    final Rect poster = Rect.fromLTWH(left, (h - ph) / 2, pw, ph);
    final (_CoverSlot backdrop, double fade) = _backdropSlot(w, h, aspect);
    return _BlockGeometry(
      backdropFadeStart: fade,
      slots: <_CoverSlot>[
        backdrop,
        _CoverSlot(rect: poster, rest: rest, hover: hover),
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
    backdropFadeStart: backdropFadeStart,
  );

  /// 封面槽，按 [slots] 序：首个 = 最前那张。
  final List<_CoverSlot> slots;
  final Rect text;
  final double coverRadius;
  final int titleLines;

  /// 横版背景图渐隐的起点（占槽宽的比例，见 [_backdropSlot]）。
  final double backdropFadeStart;
}

/// 唱片摆法的几何：方形封面（边长 S）在起始侧垂直居中，唱片（0.94 S）垫在封面
/// 后面、圆心比封面中心往结束侧偏 0.42 S（露出约四成）；文字区从唱片右缘之后起排。
/// S 取「块高减上下边距」与「块宽的 0.34（半高卡 0.3）」里较小者——宽色块里唱片 +
/// 封面不会挤掉文字区。悬停：封面再斜 3° 并放大一点，唱片再滑出 0.14 S、转 70°。
@immutable
class _DiscGeometry {
  const _DiscGeometry({
    required this.cover,
    required this.disc,
    required this.text,
    required this.titleLines,
  });

  factory _DiscGeometry.of(FushiCoverBlockSize size, Size box) {
    final double w = box.width;
    final double h = box.height;
    final bool half = size == FushiCoverBlockSize.half;
    final double p = half ? 12 : 20;
    final double s = math.max(0, math.min(h - p * 2, w * (half ? 0.3 : 0.34)));
    final double top = (h - s) / 2;
    final Rect coverRect = Rect.fromLTWH(p, top, s, s);
    final double d = s * 0.94;
    final Rect discRect = Rect.fromCenter(
      center: coverRect.center.translate(s * 0.42, 0),
      width: d,
      height: d,
    );
    final double textLeft = math.min(discRect.right + (half ? 14 : 20), w - 80);
    return _DiscGeometry(
      cover: _CoverSlot(
        rect: coverRect,
        rest: const _Pose(rotation: -4),
        hover: const _Pose(rotation: -7, scale: 1.03),
      ),
      disc: _CoverSlot(
        rect: discRect,
        rest: const _Pose(),
        hover: _Pose(dx: s * 0.14, rotation: 70),
      ),
      text: Rect.fromLTRB(
        textLeft,
        half ? 12 : 22,
        math.max(textLeft, w - (half ? 12 : 18)),
        h - (half ? 10 : 14),
      ),
      titleLines: half ? 2 : 3,
    );
  }

  final _CoverSlot cover;
  final _CoverSlot disc;
  final Rect text;
  final int titleLines;

  /// RTL 用：整块水平镜像。
  _DiscGeometry mirrored(double width) => _DiscGeometry(
    cover: cover.mirrored(width),
    disc: disc.mirrored(width),
    text: _mirrorRect(text, width),
    titleLines: titleLines,
  );
}

/// 唱片盘面：[FushiCoverBlock.disc] 自己画圆形与投影（真盘面中心是透明轮毂，
/// 投影要在轮毂处裁掉、扫描图要按量出的盘心对正，这里套整圆裁切 / 整圆投影会把
/// 孔填成一团阴影），这里只铺满唱片槽。
class _DiscFace extends StatelessWidget {
  const _DiscFace({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => SizedBox.expand(child: child);
}

/// 带投影、裁圆角的一张封面。[overlay]（下载进度压暗等）叠在封面之上、同在
/// 圆角裁切里——整张卡由 [_FushiCoverBlockState._posed] 变换，盖层随封面一起
/// 旋转 / 缩放 / 位移并按同一圆角裁切（盖层曾是姿态变换外的兄弟层，画成一块
/// 不旋转的直角暗块）。
/// 卡壳挂了要模糊的 [ShelfCoverNsfw] 时封面图打模糊（盖层不模糊）。
class _CoverCard extends StatelessWidget {
  const _CoverCard({required this.radius, required this.child, this.overlay});

  final double radius;
  final Widget child;
  final Widget? overlay;

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
        child: Stack(
          fit: StackFit.expand,
          children: <Widget>[
            ColoredBox(
              color: Theme.of(context).colorScheme.surfaceContainerHighest,
              child: NsfwCoverBlur(
                blur: ShelfCoverNsfw.blurOf(context),
                child: child,
              ),
            ),
            if (overlay != null) Positioned.fill(child: overlay!),
          ],
        ),
      ),
    );
  }
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
    required this.titleSlot,
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

  /// 标题占固定标题槽（[FushiTitleSlot] / [FushiLogoTitle] 同高）。
  final bool titleSlot;
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
    final double logoMaxHeight = fushiCoverBlockLogoMaxHeight(
      size,
      compact: compact,
    );
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
        // 固定标题槽（有 logo 必走槽）：按槽高预算，空间不够先丢次要行——不然
        // 次要行按更小的估计留下来，Flexible 的标题被压得比槽矮，一排卡的槽高
        // 又错开。半高卡按标题行数留高（两行标题时先丢次要行，标题不被压成一行）。
        final double titleMin = titleSlot
            ? logoMaxHeight
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
                    slotted: titleSlot,
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

/// 色块标题槽的档位高度（[fushiLogoSlotSize] / [FushiTitleSlot] 的槽高）：拼贴
/// 首块 84（窄窗 66）、规整块 64（窄窗 52）、半高卡 40。两行标题文字在各档都
/// 放得下。
double fushiCoverBlockLogoMaxHeight(
  FushiCoverBlockSize size, {
  required bool compact,
}) => switch (size) {
  FushiCoverBlockSize.hero => compact ? 66 : 84,
  FushiCoverBlockSize.regular => compact ? 52 : 64,
  FushiCoverBlockSize.half => 40,
};

/// 标题位：有 logo 画 logo（[FushiLogoTitle]：固定标题槽，解码失败回落文字），
/// 否则是标题文字——[slotted] 时占同一个槽（[FushiTitleSlot]，最多两行），不然按
/// 剩余高度定行数（最多 [maxLines] 行）。
class _BlockTitle extends StatelessWidget {
  const _BlockTitle({
    required this.title,
    required this.logo,
    required this.style,
    required this.maxLines,
    required this.logoMaxHeight,
    required this.slotted,
  });

  final String title;
  final ImageProvider? logo;
  final TextStyle style;
  final int maxLines;
  final double logoMaxHeight;
  final bool slotted;

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
        final Widget text = slotted
            ? FushiTitleSlot(
                title: title,
                style: style,
                height: logoMaxHeight,
                maxLines: math.min(maxLines, 2),
              )
            : Text(
                title,
                maxLines: lines,
                overflow: TextOverflow.ellipsis,
                style: style,
              );
        final ImageProvider? image = logo;
        if (image == null) return text;
        return FushiLogoTitle(
          logo: image,
          title: title,
          maxHeight: logoMaxHeight,
          fallback: text,
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
