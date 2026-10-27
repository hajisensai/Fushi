import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/components/cover_badge.dart';
import 'package:fushi/src/utils/components/fushi_design_tokens.dart';
import 'package:fushi/src/utils/components/fushi_hover_lift.dart';
import 'package:fushi/src/utils/components/fushi_press_scale.dart';
import 'package:fushi/src/utils/components/fushi_motion_tokens.dart';
import 'package:fushi/src/utils/components/glass/fushi_apple_palette.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_feedback.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/components/shelf_card_widgets.dart';

/// 库页条目材质（2026-10-25 用户定版，设计稿
/// `fushi/build/library_material_design/library_final_landscape.html`）。
///
/// 三个库共用同一套背景与布局，只换条目本身的材质：
/// - [glossyBook]：书架 / 漫画——光面书皮：左缘细书脊阴影 + 很淡的斜向光泽 +
///   0.5px 内描边；
/// - [glossyPoster]：视频库——光面海报：6dp 圆角、没有书脊，光泽同书；
/// - [gameCase]：游戏库——透明卡盒：10dp 圆角、4px 半透明塑料外圈 + 左上盒面
///   反光，封面在 6dp 内窗里居中裁切；
/// - [glossyAlbum]：音乐专辑——方形「唱片」：8dp 圆角、1:1（[kShelfAlbumAspectRatio]），
///   斜向光泽比海报略亮 + 顶边 1px 高光 + 0.5px 内描边，多张同海报的右上叠层
///   （用户 2026-10-26 拍板，专辑网格与专辑详情用）。
///
/// 16:9 剧照型封面（剧集缩略图 / 横版卡）直接用 [glossyPoster]：材质的光泽、
/// 扫光、接触阴影全部按封面实际尺寸画，没有写死 2:3 几何，调用方给
/// [kShelfLandscapeAspectRatio] 的盒子即可。列表行小缩略图（40–60 宽）用
/// `ShelfCoverFrame(density: ShelfCoverDensity.compact)`（[ShelfCoverDensity]）。
///
/// 三者悬停都是同一道柔光慢扫（[ShelfCoverSheen]），底下一团接触阴影
/// （[ShelfContactShadow]）；封面上**不压任何角标**（用户 2026-10-25：「全部
/// 都不用角标设计」）——类型 / 卷数 / 集数 / 远端 / 下载 / 状态一律进封面下的
/// 副行（[ShelfCardMeta]）。墨水屏不走材质（[shelfCoverMaterialOf] 返回 null），
/// 保留描边封面框。
enum ShelfCoverMaterial { glossyBook, glossyPoster, gameCase, glossyAlbum }

/// 封面框的密度（用户 2026-10-26 拍板）。由**调用点**决定、同一调用点恒定，
/// 不随主题 / 尺寸自动切换：
/// - [regular]：库页网格卡——完整材质（投影、接触阴影、悬停扫光、扇形 / 叠层）；
/// - [compact]：列表行里 40–60 宽的小缩略图——只保留材质的圆角、内描边与轻
///   光泽；不画投影 / 接触阴影（小尺寸下糊成一团）、不画悬停扫光、不画扇形 /
///   叠层（`stackedCovers` / `stackedBehind` 被忽略），也不画勾选圈（列表行的
///   多选信号由行本身给，40px 封面放不下勾选圈）；选中罩照常。
enum ShelfCoverDensity { regular, compact }

/// 给子树里的封面框（[ShelfCoverFrame]）指定材质。库页在网格外包一层即可。
class ShelfCoverMaterialScope extends InheritedWidget {
  const ShelfCoverMaterialScope({
    required this.material,
    required super.child,
    super.key,
  });

  final ShelfCoverMaterial material;

  @override
  bool updateShouldNotify(ShelfCoverMaterialScope oldWidget) =>
      oldWidget.material != material;
}

/// 当前生效的条目材质；墨水屏或子树没有 [ShelfCoverMaterialScope] 时为 null。
ShelfCoverMaterial? shelfCoverMaterialOf(BuildContext context) {
  final ShelfCoverMaterialScope? scope = context
      .dependOnInheritedWidgetOfExactType<ShelfCoverMaterialScope>();
  if (scope == null || isEinkTheme(context)) return null;
  return scope.material;
}

/// 材质的外轮廓圆角：书 2/3（书脊侧更方）、海报 6、卡盒 10、专辑 8。
BorderRadius shelfMaterialRadius(ShelfCoverMaterial material) {
  switch (material) {
    case ShelfCoverMaterial.glossyBook:
      return const BorderRadiusDirectional.horizontal(
        start: Radius.circular(2),
        end: Radius.circular(3),
      ).resolve(TextDirection.ltr);
    case ShelfCoverMaterial.glossyPoster:
      return const BorderRadius.all(Radius.circular(6));
    case ShelfCoverMaterial.gameCase:
      return const BorderRadius.all(Radius.circular(10));
    case ShelfCoverMaterial.glossyAlbum:
      return const BorderRadius.all(Radius.circular(8));
  }
}

/// 卡盒外圈宽度（封面内窗四周的塑料边）。
const double kShelfGameCaseRim = 4;

/// 卡盒内窗圆角。
const BorderRadius kShelfGameCaseWindowRadius = BorderRadius.all(
  Radius.circular(6),
);

/// 游戏卡盒的竖长比例（宽 / 高 ≈ 1:1.6）。
const double kShelfGameCaseAspectRatio = 1 / 1.6;

/// 专辑「唱片」材质的比例（方形）。
const double kShelfAlbumAspectRatio = 1;

/// 16:9 剧照型封面（配 [ShelfCoverMaterial.glossyPoster]）的比例。
const double kShelfLandscapeAspectRatio = 16 / 9;

/// 书皮 / 卡盒材质悬停时封面面在放大之外再整体上抬的距离（逻辑 px）。
const double kShelfMaterialHoverRise = 4;

/// 横滑行为悬停留出的上下余量：[FushiHoverLift] 放大溢出的 (scale-1)/2，再加
/// 材质上抬 [kShelfMaterialHoverRise]（同时兜住加深的投影）。上抬发生在放大
/// 变换**内部**，所以实际位移是 rise × scale。只算放大的行会把书皮顶边截平约
/// 4px（首页「继续」行实测）。各横滑行一律用它，不各自手写。
double shelfHoverLiftHeadroom(double cardHeight) =>
    cardHeight * (kFushiHoverLiftScale - 1) / 2 +
    kShelfMaterialHoverRise * kFushiHoverLiftScale;

/// 材质条目的投影：静止就有（书 / 海报 / 卡盒都是「立在桌面上」的实物），
/// 悬停时抬得更高、更散。
List<BoxShadow> shelfMaterialShadows({
  required bool dark,
  required bool lifted,
}) {
  final double near = dark ? 0.5 : 0.2;
  final double far = dark ? 0.7 : 0.32;
  return <BoxShadow>[
    BoxShadow(
      color: Colors.black.withValues(alpha: near),
      blurRadius: 2,
      offset: const Offset(0, 1),
    ),
    BoxShadow(
      color: Colors.black.withValues(alpha: lifted ? far * 1.1 : far),
      blurRadius: lifted ? 24 : 16,
      spreadRadius: -6,
      offset: Offset(0, lifted ? 14 : 8),
    ),
  ];
}

/// 柔光扫过一次的时长：取动效 token（墨水屏 / 系统减弱动态效果下归零）。
Duration shelfSheenDuration(BuildContext context) =>
    fushiMotionDuration(context, FushiMotion.long * 3);

/// 材质表面：给一张封面图套上外轮廓、投影、光泽、柔光扫过。
///
/// [ShelfCoverFrame] 的单张封面与 [ShelfCoverPile] 叠在后面的那几张共用这一份，
/// 所以扇形 / 叠层里每一本都是同样的实物质感。[overlay] 画在材质之上、扫光之下
/// （选中罩 / 勾选圈 / 加载层），[dim] 是后层压暗（0–1）。
///
/// [compact] = 简化档（[ShelfCoverDensity.compact]）：只留外轮廓、光泽与内描边，
/// 不画投影与扫光，[lifted] 被忽略。
class ShelfMaterialSurface extends StatelessWidget {
  const ShelfMaterialSurface({
    required this.material,
    required this.child,
    this.backgroundColor,
    this.overlay = const <Widget>[],
    this.dim = 0,
    this.lifted = false,
    this.compact = false,
    this.pressGlint = true,
    super.key,
  });

  final ShelfCoverMaterial material;
  final Widget child;
  final Color? backgroundColor;
  final List<Widget> overlay;
  final double dim;
  final bool lifted;
  final bool compact;

  /// 轻触 / 长按时是否扫一遍光（见 [ShelfCoverSheen.glint]）。叠层 / 扇形里
  /// 藏在后面的那几本传 false。
  final bool pressGlint;

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    final bool dark = cs.brightness == Brightness.dark;
    final BorderRadius radius = shelfMaterialRadius(material);
    final Color fill = backgroundColor ?? cs.surfaceContainerHigh;
    final Widget dimmer = dim <= 0
        ? const SizedBox.shrink()
        : ColoredBox(color: Colors.black.withValues(alpha: dim));

    final Widget body;
    if (material == ShelfCoverMaterial.gameCase) {
      // 透明卡盒：塑料外圈（斜向渐变 + 1px 内描边）包着 6dp 内窗。
      body = DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: radius,
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: dark
                ? <Color>[
                    Colors.white.withValues(alpha: 0.22),
                    Colors.white.withValues(alpha: 0.08),
                    Colors.white.withValues(alpha: 0.15),
                  ]
                : <Color>[
                    Colors.white.withValues(alpha: 0.75),
                    Colors.white.withValues(alpha: 0.40),
                    Colors.white.withValues(alpha: 0.60),
                  ],
            stops: const <double>[0, 0.4, 1],
          ),
          border: Border.all(
            color: dark
                ? Colors.white.withValues(alpha: 0.08)
                : Colors.black.withValues(alpha: 0.10),
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.all(kShelfGameCaseRim - 1),
          child: ClipRRect(
            borderRadius: kShelfGameCaseWindowRadius,
            child: Stack(
              fit: StackFit.expand,
              children: <Widget>[
                ColoredBox(color: fill, child: child),
                dimmer,
                IgnorePointer(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      borderRadius: kShelfGameCaseWindowRadius,
                      border: Border.all(
                        color: Colors.black.withValues(alpha: 0.2),
                        width: 0.5,
                      ),
                    ),
                  ),
                ),
                ...overlay,
              ],
            ),
          ),
        ),
      );
    } else {
      body = ClipRRect(
        borderRadius: radius,
        child: Stack(
          fit: StackFit.expand,
          children: <Widget>[
            ColoredBox(color: fill, child: child),
            dimmer,
            IgnorePointer(child: _GlossLayer(material: material)),
            ...overlay,
          ],
        ),
      );
    }

    final bool raised = lifted && !compact;
    return AnimatedContainer(
      duration: fushiMotionDuration(context, FushiMotion.medium),
      curve: FushiMotion.standard,
      decoration: BoxDecoration(
        borderRadius: radius,
        boxShadow: compact
            ? const <BoxShadow>[]
            : shelfMaterialShadows(dark: dark, lifted: raised),
      ),
      child: Stack(
        fit: StackFit.expand,
        children: <Widget>[
          body,
          if (material == ShelfCoverMaterial.gameCase)
            IgnorePointer(child: _GlossLayer(material: material)),
          if (!compact)
            IgnorePointer(
              child: ClipRRect(
                borderRadius: radius,
                child: ShelfCoverSheen(active: raised, glint: pressGlint),
              ),
            ),
        ],
      ),
    );
  }
}

/// 静态光泽：书 = 左缘书脊阴影 + 一线高光 + 斜向淡光；海报 = 斜向淡光 + 顶边
/// 1px 高光；专辑 = 同海报但光泽略亮；卡盒 = 左上盒面反光。都有 0.5px 内描边。
/// 渐变全部按 [Alignment] / 比例取值，任意宽高比（含 16:9）都按实际尺寸铺满。
class _GlossLayer extends StatelessWidget {
  const _GlossLayer({required this.material});

  final ShelfCoverMaterial material;

  @override
  Widget build(BuildContext context) {
    final BorderRadius radius = shelfMaterialRadius(material);
    switch (material) {
      case ShelfCoverMaterial.glossyBook:
        return Stack(
          fit: StackFit.expand,
          children: <Widget>[
            DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: AlignmentDirectional.centerStart,
                  end: AlignmentDirectional.centerEnd,
                  colors: <Color>[
                    Colors.black.withValues(alpha: 0.12),
                    Colors.white.withValues(alpha: 0.14),
                    Colors.white.withValues(alpha: 0),
                  ],
                  stops: const <double>[0, 0.015, 0.04],
                ),
              ),
            ),
            _diagonalGloss(0.07),
            DecoratedBox(
              decoration: BoxDecoration(
                borderRadius: radius,
                border: Border.all(
                  color: Colors.black.withValues(alpha: 0.12),
                  width: 0.5,
                ),
              ),
            ),
          ],
        );
      case ShelfCoverMaterial.glossyPoster:
        return _sheetGloss(radius, gloss: 0.08, topHighlight: 0.18);
      case ShelfCoverMaterial.glossyAlbum:
        return _sheetGloss(radius, gloss: 0.11, topHighlight: 0.22);
      case ShelfCoverMaterial.gameCase:
        return DecoratedBox(
          decoration: BoxDecoration(
            borderRadius: radius,
            gradient: LinearGradient(
              begin: const Alignment(-1, -0.8),
              end: const Alignment(1, 0.8),
              colors: <Color>[
                Colors.white.withValues(alpha: 0.25),
                Colors.white.withValues(alpha: 0.25),
                Colors.white.withValues(alpha: 0),
              ],
              stops: const <double>[0, 0.10, 0.22],
            ),
          ),
        );
    }
  }

  /// 海报 / 专辑共用的「一张光面纸」：斜向淡光 + 顶边 1px 高光 + 0.5px 内描边。
  static Widget _sheetGloss(
    BorderRadius radius, {
    required double gloss,
    required double topHighlight,
  }) => Stack(
    fit: StackFit.expand,
    children: <Widget>[
      _diagonalGloss(gloss),
      DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: radius,
          border: Border(
            top: BorderSide(
              color: Colors.white.withValues(alpha: topHighlight),
            ),
          ),
        ),
      ),
      DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: radius,
          border: Border.all(
            color: Colors.black.withValues(alpha: 0.14),
            width: 0.5,
          ),
        ),
      ),
    ],
  );

  static Widget _diagonalGloss(double alpha) => DecoratedBox(
    decoration: BoxDecoration(
      gradient: LinearGradient(
        begin: const Alignment(-1, -0.7),
        end: const Alignment(1, 0.7),
        colors: <Color>[
          Colors.white.withValues(alpha: alpha),
          Colors.white.withValues(alpha: 0),
        ],
        stops: const <double>[0, 0.45],
      ),
    ),
  );
}

/// 从右往左慢慢扫过的一道柔光（最亮约 16%，深色 11%）。两种触发：
///
/// - **悬停**：[active] 由 false→true 时扫入、true→false 时扫回；
/// - **轻触 / 长按**（[glint] 为真时）：最近的 `FushiPressScale` 每确认一次按下
///   （[FushiPressScale.pulseOf] 变化）就从右到左完整扫一遍，扫完光带停在封面
///   外、悄悄归位。触屏没有悬停，此前点 / 长按封面只有缩放，看不到这层光面。
///
/// 时长取 [shelfSheenDuration]，减弱动态效果 / 墨水屏下直接跳到终点（光带停在
/// 封面外，不可见）。光带在进度 0 与 1 时都在封面之外，所以「跳回 0」不可见。
class ShelfCoverSheen extends StatefulWidget {
  const ShelfCoverSheen({required this.active, this.glint = true, super.key});

  final bool active;

  /// 是否响应按压脉冲（叠层 / 扇形里藏在后面的那几本传 false，只让最前那本闪）。
  final bool glint;

  @override
  State<ShelfCoverSheen> createState() => _ShelfCoverSheenState();
}

class _ShelfCoverSheenState extends State<ShelfCoverSheen>
    with SingleTickerProviderStateMixin {
  late final AnimationController _sweep;

  /// 上一次看到的按压脉冲；null = 还没读过（首次读取不算一次按压）。
  int? _pulse;

  /// 正在播一遍按压扫光：播完若没悬停就悄悄归 0，而不是像悬停离开那样扫回去。
  bool _glinting = false;

  @override
  void initState() {
    super.initState();
    _sweep = AnimationController(vsync: this, value: widget.active ? 1 : 0)
      ..addStatusListener(_onStatus);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _sweep.duration = shelfSheenDuration(context);
    if (!widget.glint) return;
    final int pulse = FushiPressScale.pulseOf(context);
    final int? previous = _pulse;
    _pulse = pulse;
    if (previous != null && previous != pulse) _playGlint();
  }

  @override
  void didUpdateWidget(covariant ShelfCoverSheen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.active == widget.active) return;
    // 按压扫光进行中：让它扫完（扫完由 [_onStatus] 按当前悬停态收尾）。
    if (_glinting) return;
    _sweep.animateTo(widget.active ? 1 : 0, curve: FushiMotion.enter);
  }

  void _playGlint() {
    _glinting = true;
    // 已停在终点（悬停中 / 上一遍刚扫完）就从头再扫一遍；扫到一半则接着扫完。
    if (_sweep.value >= 0.999) _sweep.value = 0;
    _sweep.animateTo(1, curve: FushiMotion.enter);
  }

  void _onStatus(AnimationStatus status) {
    if (status != AnimationStatus.completed || !_glinting) return;
    _glinting = false;
    // 悬停中停在终点（与悬停扫入的终态一致）；否则归 0，下次悬停照常扫入。
    if (!widget.active) _sweep.value = 0;
  }

  @override
  void dispose() {
    _sweep.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final bool dark =
        Theme.of(context).colorScheme.brightness == Brightness.dark;
    return AnimatedBuilder(
      animation: _sweep,
      builder: (BuildContext context, Widget? _) {
        final double t = _sweep.value;
        // t=0 / t=1 光带都在封面之外：不画，省一层 shader。
        if (t <= 0.001 || t >= 0.999) return const SizedBox.expand();
        return CustomPaint(
          painter: _SheenPainter(progress: t, peak: dark ? 0.11 : 0.16),
          child: const SizedBox.expand(),
        );
      },
    );
  }
}

class _SheenPainter extends CustomPainter {
  const _SheenPainter({required this.progress, required this.peak});

  final double progress;
  final double peak;

  @override
  void paint(Canvas canvas, Size size) {
    // 光带中心从封面右外侧（1.3 宽）扫到左外侧（-0.3 宽），带宽约 0.5 宽，
    // 向左倾斜（115°）。
    final double cx = size.width * (1.3 - 1.6 * progress);
    final double band = size.width * 0.5;
    final double slant = size.height * 0.42;
    final Rect rect = Rect.fromLTRB(
      cx - band - slant,
      0,
      cx + band + slant,
      size.height,
    );
    final Paint paint = Paint()
      ..shader = LinearGradient(
        begin: Alignment.centerLeft,
        end: Alignment.centerRight,
        transform: _SkewGradient(slant / rect.width),
        colors: <Color>[
          Colors.white.withValues(alpha: 0),
          Colors.white.withValues(alpha: peak * 0.3),
          Colors.white.withValues(alpha: peak),
          Colors.white.withValues(alpha: peak * 0.3),
          Colors.white.withValues(alpha: 0),
        ],
        stops: const <double>[0.2, 0.35, 0.5, 0.65, 0.8],
      ).createShader(rect);
    canvas.drawRect(Offset.zero & size, paint);
  }

  @override
  bool shouldRepaint(_SheenPainter oldDelegate) =>
      oldDelegate.progress != progress || oldDelegate.peak != peak;
}

/// 把横向渐变按高度错切，让光带斜着走。
class _SkewGradient extends GradientTransform {
  const _SkewGradient(this.amount);

  final double amount;

  @override
  Matrix4? transform(Rect bounds, {TextDirection? textDirection}) {
    final double k = amount * bounds.width / math.max(bounds.height, 1);
    return Matrix4.identity()
      ..setEntry(0, 1, -k)
      ..setEntry(0, 3, k * bounds.center.dy);
  }
}

/// 条目底下的一团柔和接触阴影（代替托盘）。悬停时收窄变淡，读作「抬起来了」。
///
/// 放在封面框的 Stack 里、`bottom` 为负值地探出封面底边；[widthFactor] 是相对
/// 封面宽度的倍数（单本约 1.07、扇形 / 叠层约 1.4）。
class ShelfContactShadow extends StatelessWidget {
  const ShelfContactShadow({
    required this.lifted,
    this.widthFactor = 1.07,
    super.key,
  });

  final bool lifted;
  final double widthFactor;

  @override
  Widget build(BuildContext context) {
    final bool dark =
        Theme.of(context).colorScheme.brightness == Brightness.dark;
    final Duration duration = fushiMotionDuration(context, FushiMotion.medium);
    return IgnorePointer(
      child: AnimatedOpacity(
        opacity: lifted ? 0.7 : 1,
        duration: duration,
        curve: FushiMotion.standard,
        child: AnimatedScale(
          scale: lifted ? 0.86 : 1,
          duration: duration,
          curve: FushiMotion.standard,
          child: FractionallySizedBox(
            widthFactor: widthFactor,
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: RadialGradient(
                  colors: <Color>[
                    Colors.black.withValues(alpha: dark ? 0.7 : 0.26),
                    Colors.black.withValues(alpha: 0),
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

/// 接触阴影的高度，以及它探出封面底边的距离。
const double kShelfContactShadowHeight = 16;
const double kShelfContactShadowDrop = 6;

/// 扇形最远那本悬停时外角最多探出格子半宽的比例（相对格子宽度）。封面与
/// 单本同大、铺满整格，这点探出落在卡片内边距里。
const double kShelfFanOverhang = 0.08;

/// 扇形角度上限（度），宽格子里也不转得更开。
const double kShelfFanMaxDegrees = 8;

/// 悬停时扇形相对静止角度的放大倍数。
const double kShelfFanHoverScale = 1.25;

/// 宽 [itemW]、高 [itemH] 的封面绕底边中点转 θ 后，外角离中线
/// `itemW/2·cosθ + itemH·sinθ`；返回让它不超过 [halfLimit] 的最大 θ（度），
/// 夹在 [0, [kShelfFanMaxDegrees]]。
double shelfFanMaxDegrees({
  required double itemW,
  required double itemH,
  required double halfLimit,
}) {
  final double a = itemW / 2;
  final double b = itemH;
  if (a <= 0 || b <= 0 || halfLimit <= a) return 0;
  // a·cosθ + b·sinθ = r·sin(θ + φ)，φ = atan2(a, b)。
  final double r = math.sqrt(a * a + b * b);
  if (halfLimit >= r) return kShelfFanMaxDegrees;
  final double phi = math.atan2(a, b);
  final double theta = (math.asin(halfLimit / r) - phi) * 180 / math.pi;
  return theta.clamp(0.0, kShelfFanMaxDegrees).toDouble();
}

/// 多本排列（系列 / 多季 / 多作）：[covers] 首个是最前面那本，其后依次往后。
///
/// - 书 / 卡盒 = 扇形：最多 4 本，绕底边中点转开，悬停时再转开一点并整体抬
///   4px。角度不写死：按封面几何反推（[shelfFanMaxDegrees]），最远那本悬停时
///   外角最多探出格子 [kShelfFanOverhang]（落在卡片内边距里），不压旁边的
///   卡、不出屏幕（2026-10-25 用户「克制一点，别出界、别和侧边重叠太多」）；
/// - 海报 / 专辑 = 碟盒式叠层：最多 3 季往右上各错开 4px、越往后越暗，悬停时散开到
///   7px / 6px。
///
/// [front] 是最前面那本的完整内容（含选中罩 / 勾选圈等 overlay），其余只画封面。
class ShelfCoverPile extends StatelessWidget {
  const ShelfCoverPile({
    required this.material,
    required this.front,
    required this.behind,
    this.frontOverlay = const <Widget>[],
    this.backgroundColor,
    super.key,
  });

  final ShelfCoverMaterial material;
  final Widget front;

  /// 后面几本的封面（近 → 远）。为空时退化成单张。
  final List<Widget> behind;
  final List<Widget> frontOverlay;
  final Color? backgroundColor;

  @override
  Widget build(BuildContext context) {
    final bool lifted = FushiHoverLift.liftedOf(context);
    final Duration duration = fushiMotionDuration(context, FushiMotion.long);
    final bool stack =
        material == ShelfCoverMaterial.glossyPoster ||
        material == ShelfCoverMaterial.glossyAlbum;
    final List<Widget> back = behind
        .take(stack ? 2 : 3)
        .toList(growable: false);
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints c) {
        final double w = c.maxWidth;
        final double h = c.maxHeight;
        // 扇形的每一本都与单本同大、铺满整格（2026-10-25 用户「单本书和合集
        // 大小不协调」：此前合集整体缩到 88–92%，比旁边的单本小一圈）；后面
        // 几本藏在最前那本身后，只靠转开露出边角。海报叠层仍按错开步长让位。
        final double step = stack ? 4 : 0;
        final double itemW = stack ? w - step * back.length : w;
        final double itemH = stack ? h - step * back.length : h;
        Widget surface(Widget child, {double dim = 0, List<Widget>? overlay}) =>
            SizedBox(
              width: itemW,
              height: itemH,
              child: ShelfMaterialSurface(
                material: material,
                backgroundColor: backgroundColor,
                dim: dim,
                lifted: lifted && overlay != null,
                pressGlint: overlay != null,
                overlay: overlay ?? const <Widget>[],
                child: child,
              ),
            );

        final List<Widget> layers = <Widget>[];
        if (stack) {
          for (int d = back.length; d >= 1; d--) {
            final Offset rest = Offset(d * step, -d * step);
            final Offset spread = Offset(d * 7.0, -d * 6.0);
            layers.add(
              Positioned(
                left: 0,
                bottom: 0,
                child: AnimatedSlide(
                  offset: Offset(
                    (lifted ? spread.dx : rest.dx) / itemW,
                    (lifted ? spread.dy : rest.dy) / itemH,
                  ),
                  duration: duration,
                  curve: FushiMotion.standard,
                  child: surface(back[d - 1], dim: d * 0.1),
                ),
              ),
            );
          }
          layers.add(
            Positioned(
              left: 0,
              bottom: 0,
              child: surface(front, overlay: frontOverlay),
            ),
          );
        } else {
          // 由近到远的相对角度（最远那本转得最开）；悬停时整体放大到几何上限。
          const List<double> fractions = <double>[0.35, -0.5, -1];
          final double hoverMax = shelfFanMaxDegrees(
            itemW: itemW,
            itemH: itemH,
            halfLimit: w / 2 + w * kShelfFanOverhang,
          );
          final double restMax = hoverMax / kShelfFanHoverScale;
          for (int d = back.length; d >= 1; d--) {
            final double deg = fractions[d - 1] * (lifted ? hoverMax : restMax);
            layers.add(
              Positioned(
                left: (w - itemW) / 2,
                bottom: 0,
                child: AnimatedSlide(
                  offset: Offset(
                    0,
                    lifted ? -kShelfMaterialHoverRise / itemH : 0,
                  ),
                  duration: duration,
                  curve: FushiMotion.standard,
                  child: AnimatedRotation(
                    turns: deg / 360,
                    alignment: Alignment.bottomCenter,
                    duration: duration,
                    curve: FushiMotion.standard,
                    child: surface(back[d - 1]),
                  ),
                ),
              ),
            );
          }
          layers.add(
            Positioned(
              left: (w - itemW) / 2,
              bottom: 0,
              child: AnimatedSlide(
                offset: Offset(
                  0,
                  lifted ? -kShelfMaterialHoverRise / itemH : 0,
                ),
                duration: duration,
                curve: FushiMotion.standard,
                child: surface(front, overlay: frontOverlay),
              ),
            ),
          );
        }
        return Stack(
          clipBehavior: Clip.none,
          children: <Widget>[
            Positioned(
              left: 0,
              right: 0,
              bottom: -kShelfContactShadowDrop,
              height: kShelfContactShadowHeight,
              child: ShelfContactShadow(
                lifted: lifted,
                widthFactor: back.isEmpty ? 1.07 : 1.15,
              ),
            ),
            ...layers,
          ],
        );
      },
    );
  }
}

/// 卡片标题的默认行数（书架 / 视频 / 游戏 / 媒体服务器统一两行）。
const int kShelfCardMetaTitleLines = 2;

/// 副行的语气：普通 / 警示（部分完成）/ 错误（失败 / 缺文件）。
enum ShelfMetaTone { normal, warning, error }

/// 封面下的文字块（材质库页统一形态）：标题两行（[titleMaxLines]）、副行一行（可带前导图标与
/// 语气色）、可选进度条。原先压在封面上的角标信息全部进副行：
/// 「🎧 有声书 · 46%」「☁ 未下载」「7 卷 · 读到第 24 卷」「共 3 集 · 继续看第 2 集」。
class ShelfCardMeta extends StatelessWidget {
  const ShelfCardMeta({
    required this.title,
    this.subtitle,
    this.leadingIcon,
    this.tone = ShelfMetaTone.normal,
    this.progress,
    this.completed = false,
    this.trailing,
    this.titleMaxLines = kShelfCardMetaTitleLines,
    super.key,
  });

  final String title;

  /// 标题行数上限（用户 2026-10-25：卡片标题显示两行）。网格行高按同一行数算
  /// （[heightFor] 的 `titleLines`），两边必须一致。
  final int titleMaxLines;
  final String? subtitle;
  final IconData? leadingIcon;
  final ShelfMetaTone tone;

  /// 0–1；null = 不画进度条（仍占位，保证同一网格行高一致）。
  final double? progress;

  /// 已完成：进度条换完成色（tertiary / Apple 系统绿）。
  final bool completed;

  /// 副行尾部的附加小部件（原盘 / 规格角标、用户标签 [ShelfMetaTags] 等）。
  ///
  /// 最宽占副行的 [_kTrailingMaxFraction]，副行文字永远留得出地方；尾部自己要能
  /// 在这个宽度内收住（标签名 ellipsis、规格角标放不下的整枚不显示）。
  final Widget? trailing;

  static const double _kTrailingMaxFraction = 0.6;

  /// 文字块总高（随文字缩放）：标题 [titleLines] 行 + 副行 + 进度条 + 间距。
  static double heightFor(
    BuildContext context, {
    int titleLines = kShelfCardMetaTitleLines,
  }) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final ThemeData theme = Theme.of(context);
    final double titleLine = textLineHeight(
      context,
      _titleStyle(theme, tokens, apple: false),
    );
    return tokens.spacing.gap * 1.25 +
        titleLine * titleLines +
        _subRowHeight(context, theme) +
        _kProgressGap +
        _kProgressHeight +
        kTextBlockSlack;
  }

  static const double _kProgressHeight = 4;
  static const double _kProgressGap = 5;

  /// 副行高度：副行文字一行，与尾部角标（原盘 / 规格 [CoverBadge]：角标字行高 + 内边距，比副行文字高）取大。
  /// 布局与 [heightFor] 共用这一个值：以前只按文字算，带角标的卡片溢出几像素——单行标题时被标题下面空着的
  /// 那一行吞掉，标题区恒占满 [kShelfCardMetaTitleLines] 行后就露了出来。
  static double _subRowHeight(BuildContext context, ThemeData theme) =>
      math.max(
        textLineHeight(context, _subStyle(theme)),
        coverBadgeLabelHeight(context),
      );

  static TextStyle _titleStyle(
    ThemeData theme,
    FushiDesignTokens tokens, {
    required bool apple,
  }) => tokens.type.metadata.copyWith(
    fontWeight: apple ? FontWeight.w600 : FontWeight.w500,
  );

  static TextStyle _subStyle(ThemeData theme) =>
      (theme.textTheme.labelSmall ?? const TextStyle()).copyWith(
        fontWeight: FontWeight.w400,
        letterSpacing: 0.1,
      );

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final ThemeData theme = Theme.of(context);
    final ColorScheme cs = theme.colorScheme;
    final bool eink = isEinkTheme(context);
    final bool apple = isGlassDesign(context) && !eink;
    final FushiAppleColors appleColors = appleColorsOf(context);
    final Color onSurface = apple ? appleColors.label : cs.onSurface;
    final Color muted = apple
        ? appleColors.secondaryLabel
        : cs.onSurfaceVariant;
    final Color toneColor = switch (tone) {
      ShelfMetaTone.normal => muted,
      ShelfMetaTone.warning =>
        eink ? cs.onSurface : (apple ? appleColors.warning : cs.tertiary),
      ShelfMetaTone.error =>
        eink ? cs.onSurface : (apple ? appleColors.destructive : cs.error),
    };
    final TextStyle titleStyle = _titleStyle(
      theme,
      tokens,
      apple: apple,
    ).copyWith(color: onSurface);
    final TextStyle subStyle = _subStyle(theme).copyWith(color: toneColor);
    final double? value = progress;
    final Color fill = eink
        ? cs.onSurface
        : completed
        ? (apple ? appleColors.success : cs.tertiary)
        : (apple ? appleColors.accent : cs.primary);
    final Color track = eink
        ? cs.surface
        : apple
        ? appleColors.tertiaryFill
        : cs.surfaceContainerHighest;

    return Padding(
      padding: EdgeInsetsDirectional.fromSTEB(
        2,
        tokens.spacing.gap * 1.25,
        2,
        0,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          ShelfTitleLine(
            title: title,
            style: titleStyle,
            maxLines: titleMaxLines,
          ),
          SizedBox(
            height: _subRowHeight(context, theme),
            child: LayoutBuilder(
              builder: (BuildContext context, BoxConstraints constraints) =>
                  Row(
                    children: <Widget>[
                      if (leadingIcon != null) ...<Widget>[
                        FushiIcon(
                          leadingIcon!,
                          size: (subStyle.fontSize ?? 11) + 1,
                          color: tone == ShelfMetaTone.normal
                              ? onSurface
                              : toneColor,
                        ),
                        const SizedBox(width: 4),
                      ],
                      Expanded(
                        child: Text(
                          subtitle ?? '',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: subStyle,
                        ),
                      ),
                      if (trailing != null)
                        ConstrainedBox(
                          constraints: BoxConstraints(
                            maxWidth:
                                constraints.maxWidth * _kTrailingMaxFraction,
                          ),
                          child: trailing,
                        ),
                    ],
                  ),
            ),
          ),
          const SizedBox(height: _kProgressGap),
          SizedBox(
            height: _kProgressHeight,
            child: value == null
                ? null
                : ClipRRect(
                    borderRadius: BorderRadius.circular(_kProgressHeight / 2),
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: track,
                        border: eink ? Border.all(color: cs.onSurface) : null,
                        borderRadius: BorderRadius.circular(
                          _kProgressHeight / 2,
                        ),
                      ),
                      child: Align(
                        alignment: AlignmentDirectional.centerStart,
                        child: FractionallySizedBox(
                          widthFactor: value.clamp(0.0, 1.0),
                          heightFactor: 1,
                          child: ColoredBox(color: fill),
                        ),
                      ),
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}

/// 副行里的一枚用户标签：名字 + 标签色（null = 走中性色）。
typedef ShelfMetaTag = ({String label, Color? color});

/// 副行尾部的用户标签：标签色小圆点 + 标签名（与库页标签筛选条的 chip 同一读法，
/// 不加 `#` 前缀——用户 2026-10-26：「#4⭐」太抽象）。最多显示 [maxVisible] 枚，
/// 其余收成「+N」；名字放不下时 ellipsis，悬停 / 长按看全部标签名。
class ShelfMetaTags extends StatelessWidget {
  const ShelfMetaTags({required this.tags, this.maxVisible = 2, super.key});

  final List<ShelfMetaTag> tags;
  final int maxVisible;

  @override
  Widget build(BuildContext context) {
    if (tags.isEmpty) return const SizedBox.shrink();
    final ThemeData theme = Theme.of(context);
    final ColorScheme cs = theme.colorScheme;
    final bool eink = isEinkTheme(context);
    final bool apple = isGlassDesign(context) && !eink;
    final Color muted = apple
        ? appleColorsOf(context).secondaryLabel
        : cs.onSurfaceVariant;
    final TextStyle style = ShelfCardMeta._subStyle(
      theme,
    ).copyWith(color: muted);
    final List<ShelfMetaTag> visible = tags.take(maxVisible).toList();
    final int overflow = tags.length - visible.length;
    final String names = tags.map((ShelfMetaTag tag) => tag.label).join(' · ');
    return FushiTooltip(
      message: names,
      child: Semantics(
        label: names,
        child: ExcludeSemantics(
          child: Padding(
            padding: const EdgeInsetsDirectional.only(start: 6),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                for (final (int i, ShelfMetaTag tag) in visible.indexed) ...[
                  if (i > 0) const SizedBox(width: 6),
                  SizedBox.square(
                    dimension: 7,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: eink ? cs.onSurface : (tag.color ?? muted),
                      ),
                    ),
                  ),
                  const SizedBox(width: 3),
                  Flexible(
                    child: Text(
                      tag.label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: style,
                    ),
                  ),
                ],
                if (overflow > 0) ...[
                  const SizedBox(width: 4),
                  Text('+$overflow', style: style),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 卡片标题：最多 [maxLines] 行，放不下时桌面悬停显示全名（与 [ShelfCardFooter]
/// 同一套溢出提示）。
///
/// 恒占满 [maxLines] 行高：短标题只排一行时也留出其余行，同一网格行里副行与
/// 进度条才落在同一条基线上（否则单行标题的卡片底部整体上移、与两行标题的卡片
/// 错位）。占位用同字体的空行撑高，行高与真实排版一致，不靠估算值。
class ShelfTitleLine extends StatelessWidget {
  const ShelfTitleLine({
    required this.title,
    required this.style,
    this.maxLines = kShelfCardMetaTitleLines,
    super.key,
  });

  final String title;
  final TextStyle style;
  final int maxLines;

  @override
  Widget build(BuildContext context) {
    final Widget text = ShelfTitleOverflowTooltip(
      title: title,
      style: style,
      maxLines: maxLines,
      child: Text(
        title,
        maxLines: maxLines,
        overflow: TextOverflow.ellipsis,
        style: style,
      ),
    );
    if (maxLines <= 1) return text;
    return Stack(
      children: <Widget>[
        ExcludeSemantics(
          child: Text(
            '\n' * (maxLines - 1),
            maxLines: maxLines,
            style: style.copyWith(color: const Color(0x00000000)),
          ),
        ),
        text,
      ],
    );
  }
}

/// 应用背景：角落三块低饱和 M3E 形状（9 瓣饼干 / 四叶 / 6 瓣饼干），颜色取动态
/// 主题的 container 色阶，深浅色都跟着走。2026-10-25 先定在库页，同日用户拍板
/// 「整个应用都加」，由路由层 `FushiPageBackdrop` 给每一页垫上。只在 Material
/// 设计系统下画（Apple / 墨水屏不画）。形状是纯装饰：不参与命中、不进无障碍树。
///
/// 子树结构恒定（不画时形状层换成空盒，[child] 位置不变）：切换设计系统 / 墨水
/// 屏时页面 State 不重建。
class LibraryShapeBackdrop extends StatelessWidget {
  const LibraryShapeBackdrop({
    required this.child,
    this.show = true,
    super.key,
  });

  final Widget child;

  /// false = 本页不画形状（整页要透明的底层合成页，见 `FushiPageBackdrop`）。
  final bool show;

  /// 当前主题下是否画形状（Material 设计系统且不是墨水屏）。
  static bool enabledOf(BuildContext context) =>
      !isEinkTheme(context) && !isGlassDesign(context);

  @override
  Widget build(BuildContext context) {
    // passthrough：[child] 拿到的约束与本组件收到的完全一致。它被路由层
    // （FushiPageBackdrop）垫在每一页下面，路由给页面的是**紧约束**（整屏）；
    // Stack 默认的 loose 会把紧约束放松，根组件不是 Scaffold 的页面（按钮、
    // 按内容定尺寸的 Material 等）就缩到左上角、不再铺满路由。
    return Stack(
      fit: StackFit.passthrough,
      children: <Widget>[
        Positioned.fill(
          child: show && enabledOf(context)
              ? const _LibraryShapeLayer()
              : const SizedBox.shrink(),
        ),
        child,
      ],
    );
  }
}

class _LibraryShapeLayer extends StatelessWidget {
  const _LibraryShapeLayer();

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    final bool dark = cs.brightness == Brightness.dark;
    Widget blob(RoundedPolygon shape, Color color, double alpha) =>
        DecoratedBox(
          decoration: ShapeDecoration(
            color: color.withValues(alpha: alpha),
            shape: MaterialShapeBorder(shape: shape),
          ),
        );
    return IgnorePointer(
      child: ExcludeSemantics(
        child: LayoutBuilder(
          builder: (BuildContext context, BoxConstraints c) {
            final double unit = math.min(c.maxWidth, c.maxHeight);
            final double big = unit * 0.52;
            final double mid = unit * 0.38;
            final double small = unit * 0.25;
            return Stack(
              clipBehavior: Clip.hardEdge,
              children: <Widget>[
                Positioned(
                  right: -big * 0.15,
                  top: -big * 0.28,
                  width: big,
                  height: big,
                  child: blob(
                    MaterialShapes.cookie9Sided,
                    cs.primaryContainer,
                    dark ? 0.35 : 0.8,
                  ),
                ),
                Positioned(
                  left: unit * 0.05,
                  bottom: -mid * 0.2,
                  width: mid,
                  height: mid,
                  child: blob(
                    MaterialShapes.clover4Leaf,
                    cs.tertiaryContainer,
                    dark ? 0.32 : 0.65,
                  ),
                ),
                Positioned(
                  right: c.maxWidth * 0.24,
                  bottom: -small * 0.2,
                  width: small,
                  height: small,
                  child: blob(
                    MaterialShapes.cookie6Sided,
                    cs.secondaryContainer,
                    dark ? 0.32 : 0.6,
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}
