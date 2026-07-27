import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/material.dart';
import 'package:hibiki/src/shortcuts/input_binding.dart';
import 'package:hibiki/src/shortcuts/shortcut_action.dart';
import 'package:hibiki/src/shortcuts/shortcut_registry.dart';
import 'package:hibiki/src/shortcuts/visual/gamepad_button_widget.dart';
import 'package:hibiki/src/shortcuts/visual/gamepad_glyphs.dart';
import 'package:hibiki/src/shortcuts/visual/reverse_binding_index.dart';
import 'package:hibiki/src/utils/misc/platform_utils.dart';

/// 单个手柄按钮在整图上的纯数据描述（TODO-942）。
///
/// 位置用**归一化中心坐标** [center]（0..1，(0,0)=左上、(1,1)=右下，渲染层按
/// 像素中心 `Positioned` 摆放），尺寸用 [size] 倍数（1.0 = 基准直径），形状
/// [shape]（面键/摇杆/系统键圆钮、肩键扳机胶囊）。可选 [symbol] 覆盖显示符号
/// （Start/Select/Mode 图形符），仅在该品牌无现成素材时作为回退绘制。
///
/// 品牌差异（Xbox/Switch 左摇杆左上+十字键左下；PS 十字键左上+双摇杆对称居下）
/// 只体现在 [buildGamepadFigure] 的坐标表里，渲染层零品牌分支。
@immutable
class GamepadPadSpec {
  const GamepadPadSpec(
    this.button,
    this.center, {
    this.size = 1.0,
    this.shape = GamepadPadShape.circle,
    this.symbol,
  });

  /// 本按钮的逻辑身份（enum 顺序/label/serialize 恒定，绝不因品牌改变）。
  final GamepadButton button;

  /// 归一化中心坐标（0..1）。
  final Offset center;

  /// 尺寸倍数（1.0 = 基准直径）。
  final double size;

  /// 形状（圆钮 / 胶囊）。
  final GamepadPadShape shape;

  /// 显示符号覆盖；null 走 [GamepadGlyphs.glyphFor]。
  final String? symbol;
}

/// 纯函数：返回 [brand] 品牌的整张手柄布局（17 个按钮，位置照真实手柄几何）。
///
/// 可单测，零渲染依赖。三品牌共用同一组 [GamepadButton]（序列化恒定），坐标钉在
/// `_GamepadChassisPainter` 描出的手柄本体上（TODO-942 用户拍板：按钮要放在
/// 手柄图的真实位置上，像游戏的键位映射屏）：
/// - 扳机（LT/RT）压在顶缘上方、肩键（LB/RB）在肩脊上；
/// - 面键菱形在右侧隆起（Y 上 / X 左 / B 右 / A 下）；
/// - **Xbox / Switch**：左摇杆左上、十字键簇左下内收、右摇杆下中；
/// - **PlayStation**：十字键簇左上（与面键对称）、双摇杆对称居下、PS 键底部中央；
/// - 十字键四臂坐标聚成一簇，渲染层把它们合成一个整体十字
///   （[GamepadDpadCluster]，四方向仍各自独立绑定/高亮/点击）。
List<GamepadPadSpec> buildGamepadFigure(GamepadBrand brand) {
  final bool isPlayStation = brand == GamepadBrand.playstation;
  final String selectSymbol = brand == GamepadBrand.nintendoSwitch ? '−' : '⧉';
  final String startSymbol = brand == GamepadBrand.nintendoSwitch ? '+' : '≡';

  return <GamepadPadSpec>[
    // 肩部（三品牌同位）：扳机在顶缘探出，肩键贴着肩脊。
    const GamepadPadSpec(
      GamepadButton.lt,
      Offset(0.22, 0.06),
      shape: GamepadPadShape.pill,
    ),
    const GamepadPadSpec(
      GamepadButton.rt,
      Offset(0.78, 0.06),
      shape: GamepadPadShape.pill,
    ),
    const GamepadPadSpec(
      GamepadButton.lb,
      Offset(0.22, 0.19),
      shape: GamepadPadShape.pill,
    ),
    const GamepadPadSpec(
      GamepadButton.rb,
      Offset(0.78, 0.19),
      shape: GamepadPadShape.pill,
    ),
    // 面键菱形（右侧隆起，三品牌物理同位；印字/配色由素材层决定）。
    const GamepadPadSpec(GamepadButton.y, Offset(0.78, 0.33)),
    const GamepadPadSpec(GamepadButton.x, Offset(0.705, 0.46)),
    const GamepadPadSpec(GamepadButton.b, Offset(0.855, 0.46)),
    const GamepadPadSpec(GamepadButton.a, Offset(0.78, 0.59)),
    if (isPlayStation) ...<GamepadPadSpec>[
      // PS：Create/Options 在上缘两侧、PS 键在双摇杆之间的底部中央。
      GamepadPadSpec(
        GamepadButton.select,
        const Offset(0.36, 0.25),
        size: 0.7,
        symbol: selectSymbol,
      ),
      GamepadPadSpec(
        GamepadButton.start,
        const Offset(0.64, 0.25),
        size: 0.7,
        symbol: startSymbol,
      ),
      const GamepadPadSpec(
        GamepadButton.mode,
        Offset(0.50, 0.62),
        size: 0.85,
        symbol: '◉',
      ),
      // 十字键簇左上（与右侧面键菱形对称）。
      const GamepadPadSpec(GamepadButton.dpadUp, Offset(0.22, 0.375)),
      const GamepadPadSpec(GamepadButton.dpadLeft, Offset(0.165, 0.46)),
      const GamepadPadSpec(GamepadButton.dpadRight, Offset(0.275, 0.46)),
      const GamepadPadSpec(GamepadButton.dpadDown, Offset(0.22, 0.545)),
      // 双摇杆对称居下。
      const GamepadPadSpec(
        GamepadButton.thumbLeft,
        Offset(0.38, 0.645),
        size: 1.3,
      ),
      const GamepadPadSpec(
        GamepadButton.thumbRight,
        Offset(0.62, 0.645),
        size: 1.3,
      ),
    ] else ...<GamepadPadSpec>[
      // Xbox / Switch：Guide/Home 顶部中央，View/Menu（−/+）居中两侧。
      GamepadPadSpec(
        GamepadButton.select,
        const Offset(0.415, 0.35),
        size: 0.7,
        symbol: selectSymbol,
      ),
      GamepadPadSpec(
        GamepadButton.start,
        const Offset(0.585, 0.35),
        size: 0.7,
        symbol: startSymbol,
      ),
      const GamepadPadSpec(
        GamepadButton.mode,
        Offset(0.50, 0.20),
        size: 0.85,
        symbol: '◉',
      ),
      // 左摇杆左上、十字键簇左下内收、右摇杆下中。
      const GamepadPadSpec(
        GamepadButton.thumbLeft,
        Offset(0.21, 0.40),
        size: 1.3,
      ),
      const GamepadPadSpec(GamepadButton.dpadUp, Offset(0.37, 0.545)),
      const GamepadPadSpec(GamepadButton.dpadLeft, Offset(0.315, 0.63)),
      const GamepadPadSpec(GamepadButton.dpadRight, Offset(0.425, 0.63)),
      const GamepadPadSpec(GamepadButton.dpadDown, Offset(0.37, 0.715)),
      const GamepadPadSpec(
        GamepadButton.thumbRight,
        Offset(0.615, 0.635),
        size: 1.3,
      ),
    ],
  ];
}

/// 整张真实布局的手柄预览图（TODO-942）。
///
/// 数据来自 [buildGamepadFigure] 纯函数；渲染 = 手柄本体轮廓
/// （[_GamepadChassisPainter]，含摇杆凹窝/面键盘面/十字键圆盘等安装位）铺底 +
/// `Stack` 里按像素中心 `Positioned` 摆放按钮：十字键四臂合成一个
/// [GamepadDpadCluster] 整体十字，其余按钮各是一个 [GamepadButtonWidget]。
/// 已绑按钮高亮沿用 [ReverseBindingIndex]；点击语义与旧面板一致：已绑走
/// [onGamepadTap]（action-first 编辑），未绑走 [onEmptyGamepadTap]（key-first
/// 分配）。
///
/// 窄屏（可用宽 < [minFigureWidth]）时按理想固定宽绘制并套横向滚动兜底
/// （与 KeyboardLayoutView 的窄屏模式同构），真手柄图不该被压扁。
class GamepadLayoutView extends StatelessWidget {
  const GamepadLayoutView({
    super.key,
    required this.registry,
    required this.scope,
    this.onGamepadTap,
    this.onEmptyGamepadTap,
    this.gamepadBrand = GamepadBrand.xbox,
  });

  final HibikiShortcutRegistry registry;
  final ShortcutScope scope;

  /// 点击一个**已绑**手柄按钮（回传该按钮上的 action 列表）。
  final void Function(GamepadButton button, List<ShortcutAction> boundActions)?
      onGamepadTap;

  /// 点击一个**未绑**手柄按钮（key-first：回传裸按钮，由上层选 action 后分配）。
  final void Function(GamepadButton button)? onEmptyGamepadTap;

  /// 显示品牌（只换符号/配色/坐标表，不改序列化）。
  final GamepadBrand gamepadBrand;

  /// 整图宽高比（真实手柄横长竖短，含两侧握把留出竖向空间）。
  static const double figureAspectRatio = 1.7;

  /// 窄屏阈值：可用宽低于此值时按 [idealFigureWidth] 固定宽 + 横向滚动。
  static const double minFigureWidth = 480;

  /// 窄屏兜底时的理想固定宽。
  static const double idealFigureWidth = 480;

  /// 宽屏上限：避免超大屏手柄图无限撑大。
  static const double maxFigureWidth = 640;

  /// 十字键簇边长 = 基准直径 × 此倍数（布局与守卫测试共用同一真相）。
  static const double dpadClusterSizeFactor = 2.4;

  @override
  Widget build(BuildContext context) {
    final ReverseBindingIndex index =
        ReverseBindingIndex.fromRegistry(registry, scope);
    final List<GamepadPadSpec> specs = buildGamepadFigure(gamepadBrand);

    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final double available = constraints.maxWidth.isFinite
            ? constraints.maxWidth
            : idealFigureWidth;
        if (available >= minFigureWidth) {
          return _buildFigure(
            context,
            index,
            specs,
            available.clamp(minFigureWidth, maxFigureWidth),
          );
        }
        // 窄屏：固定理想宽 + 横向滚动兜底（照 KeyboardLayoutView 的窄屏模式）。
        return HorizontalDragScrollable(
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: _buildFigure(context, index, specs, idealFigureWidth),
          ),
        );
      },
    );
  }

  Widget _buildFigure(
    BuildContext context,
    ReverseBindingIndex index,
    List<GamepadPadSpec> specs,
    double width,
  ) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    // 基准直径随图宽缩放（480 宽 → 40，与旧面板圆钮同尺度）。
    final double baseDiameter = width / 12;
    final double height = width / figureAspectRatio;

    Offset toPx(Offset norm) => Offset(norm.dx * width, norm.dy * height);
    GamepadPadSpec specOf(GamepadButton button) =>
        specs.firstWhere((GamepadPadSpec s) => s.button == button);

    // 十字键四臂拆出来合成一个整体十字簇；其余按钮按真实位钉在机身上。
    final List<GamepadPadSpec> plainSpecs =
        specs.where((GamepadPadSpec s) => !s.button.isDpad).toList();
    final List<GamepadPadSpec> dpadSpecs =
        specs.where((GamepadPadSpec s) => s.button.isDpad).toList();
    Offset clusterCenter = Offset.zero;
    for (final GamepadPadSpec s in dpadSpecs) {
      clusterCenter += toPx(s.center);
    }
    clusterCenter = clusterCenter / dpadSpecs.length.toDouble();
    final double clusterSize = baseDiameter * dpadClusterSizeFactor;

    // 结构安装位：摇杆凹窝、面键盘面、十字键圆盘——按钮坐在真实的「安装位」上，
    // 而不是漂在空机身上（键位映射屏的通用画法）。
    final double stickWellRadius = baseDiameter * 1.3 * 0.5 * 1.28;
    final Offset faceCenter = (toPx(specOf(GamepadButton.y).center) +
            toPx(specOf(GamepadButton.a).center)) /
        2;
    final double faceRadius =
        (toPx(specOf(GamepadButton.a).center) - faceCenter).distance +
            baseDiameter * 0.62;
    final List<_ChassisMount> mounts = <_ChassisMount>[
      _ChassisMount(
          toPx(specOf(GamepadButton.thumbLeft).center), stickWellRadius),
      _ChassisMount(
          toPx(specOf(GamepadButton.thumbRight).center), stickWellRadius),
      _ChassisMount(faceCenter, faceRadius),
      _ChassisMount(clusterCenter, clusterSize * 0.58),
    ];

    // 外壳必须在任何主题下清晰可见：填充/描边一律从 onSurface 对 surface 的
    // alphaBlend 推导——surfaceContainer 系与设置面板背景明度几乎相同、
    // outlineVariant 专为低对比分隔线设计，米色(ecru)主题下二者都会让整只手柄
    // 融进背景（TODO-942 用户截图的「看不到手柄本体」根因），故弃用。
    final Color shellTop = Color.alphaBlend(
        scheme.onSurface.withValues(alpha: 0.05), scheme.surface);
    final Color shellBottom = Color.alphaBlend(
        scheme.onSurface.withValues(alpha: 0.12), scheme.surface);
    final Color shellLine = scheme.onSurface.withValues(alpha: 0.65);
    final Color mountFill = Color.alphaBlend(
        scheme.onSurface.withValues(alpha: 0.09), scheme.surface);
    final Color mountLine = scheme.onSurface.withValues(alpha: 0.30);

    return SizedBox(
      width: width,
      height: height,
      child: Stack(
        clipBehavior: Clip.none,
        children: <Widget>[
          Positioned.fill(
            child: CustomPaint(
              painter: _GamepadChassisPainter(
                bodyTop: shellTop,
                bodyBottom: shellBottom,
                outline: shellLine,
                shadow: scheme.shadow,
                mountFill: mountFill,
                mountLine: mountLine,
                mounts: mounts,
              ),
            ),
          ),
          for (final GamepadPadSpec spec in plainSpecs)
            _positionPad(index, spec, baseDiameter, toPx(spec.center)),
          Positioned(
            left: clusterCenter.dx - clusterSize / 2,
            top: clusterCenter.dy - clusterSize / 2,
            width: clusterSize,
            height: clusterSize,
            child: GamepadDpadCluster(
              size: clusterSize,
              up: _armFor(index, GamepadButton.dpadUp),
              down: _armFor(index, GamepadButton.dpadDown),
              left: _armFor(index, GamepadButton.dpadLeft),
              right: _armFor(index, GamepadButton.dpadRight),
            ),
          ),
        ],
      ),
    );
  }

  /// 已绑/未绑两条点击路径共用的路由（语义与旧面板一致）。
  VoidCallback? _tapFor(ReverseBindingIndex index, GamepadButton button) {
    final bool bound = index.isGamepadBound(button);
    final List<ShortcutAction> actions = index.actionsForButton(button);
    if (bound && onGamepadTap != null) {
      return () => onGamepadTap!(button, actions);
    }
    if (!bound && onEmptyGamepadTap != null) {
      return () => onEmptyGamepadTap!(button);
    }
    return null;
  }

  GamepadDpadArm _armFor(ReverseBindingIndex index, GamepadButton button) {
    return GamepadDpadArm(
      button: button,
      bound: index.isGamepadBound(button),
      onTap: _tapFor(index, button),
    );
  }

  Widget _positionPad(
    ReverseBindingIndex index,
    GamepadPadSpec spec,
    double baseDiameter,
    Offset centerPx,
  ) {
    final double d = baseDiameter * spec.size;
    final bool isPill = spec.shape == GamepadPadShape.pill;
    final double w = isPill ? d * GamepadButtonWidget.pillWidthFactor : d;
    final double h = isPill ? d * GamepadButtonWidget.pillHeightFactor : d;
    return Positioned(
      left: centerPx.dx - w / 2,
      top: centerPx.dy - h / 2,
      width: w,
      height: h,
      child: GamepadButtonWidget(
        key: Key('gamepad_btn_${spec.button.label}'),
        button: spec.button,
        brand: gamepadBrand,
        bound: index.isGamepadBound(spec.button),
        onTap: _tapFor(index, spec.button),
        diameter: d,
        shape: spec.shape,
        overrideSymbol: spec.symbol,
      ),
    );
  }
}

/// 手柄本体轮廓的一段三次贝塞尔（归一化 0..1；[end] 为段终点，起点隐含为上一段终点）。
@immutable
class _ChassisCubic {
  const _ChassisCubic(this.c1, this.c2, this.end);

  final Offset c1;
  final Offset c2;
  final Offset end;
}

/// 机身上的一个圆形安装位（摇杆凹窝 / 面键盘面 / 十字键圆盘），像素坐标。
@immutable
class _ChassisMount {
  const _ChassisMount(this.center, this.radius);

  final Offset center;
  final double radius;

  @override
  bool operator ==(Object other) =>
      other is _ChassisMount &&
      other.center == center &&
      other.radius == radius;

  @override
  int get hashCode => Object.hash(center, radius);
}

/// 「后面的手柄图案」——手柄本体轮廓（居中机身 + 两侧握把 + 顶缘肩部隆起）+
/// 圆形安装位，画在按钮层背后（TODO-942 用户拍板：按钮要钉在真实手柄图上）。
///
/// 轮廓用一组对称三次贝塞尔描出：右半段从顶部中点顺时针走到底部中点，左半段由右半段
/// **镜像 + 逆序**得到（保证严格左右对称，改一处几何即整机同步）。着色由调用方从
/// [ColorScheme] 的 onSurface/surface 对比对儿推导（机身顶浅底深竖向渐变、描边高
/// 对比、投影 shadow），浅/深色主题都保证可见——**这是结构外壳，不是重绘按钮**；
/// 面键/摇杆等仍是现成的 Kenney CC0 图标叠在其上并按绑定高亮。
class _GamepadChassisPainter extends CustomPainter {
  const _GamepadChassisPainter({
    required this.bodyTop,
    required this.bodyBottom,
    required this.outline,
    required this.shadow,
    required this.mountFill,
    required this.mountLine,
    required this.mounts,
  });

  final Color bodyTop;
  final Color bodyBottom;
  final Color outline;
  final Color shadow;
  final Color mountFill;
  final Color mountLine;
  final List<_ChassisMount> mounts;

  /// 手柄本体右半轮廓（归一化 0..1），起点隐含 [_apexTop]。左半由镜像得到。
  /// 顶部中点 → 右肩顶 → 右上外缘 → 右握把外缘下探 → 右握把尖 → 握把内侧收回
  /// 腰线（真实手柄两握把间的底部 V 口较深，留住左下十字键簇/下中摇杆的落点）→
  /// 底部中点。
  static const Offset _apexTop = Offset(0.50, 0.135);
  static const List<_ChassisCubic> _rightHalf = <_ChassisCubic>[
    _ChassisCubic(
        Offset(0.60, 0.085), Offset(0.68, 0.08), Offset(0.755, 0.095)),
    _ChassisCubic(
        Offset(0.85, 0.115), Offset(0.915, 0.17), Offset(0.935, 0.30)),
    _ChassisCubic(Offset(0.958, 0.48), Offset(0.95, 0.70), Offset(0.90, 0.85)),
    _ChassisCubic(
        Offset(0.878, 0.94), Offset(0.828, 0.975), Offset(0.755, 0.955)),
    _ChassisCubic(Offset(0.70, 0.935), Offset(0.645, 0.87), Offset(0.60, 0.80)),
    _ChassisCubic(
        Offset(0.565, 0.765), Offset(0.535, 0.75), Offset(0.50, 0.745)),
  ];

  static Offset _mirror(Offset o) => Offset(1.0 - o.dx, o.dy);

  /// 构建整机对称闭合轮廓（缩放到 [size]）。
  Path _buildChassisPath(Size size) {
    Offset s(Offset o) => Offset(o.dx * size.width, o.dy * size.height);

    final Path path = Path()..moveTo(s(_apexTop).dx, s(_apexTop).dy);

    // 右半：顶点 → 底部中点。
    for (final _ChassisCubic seg in _rightHalf) {
      path.cubicTo(
        s(seg.c1).dx,
        s(seg.c1).dy,
        s(seg.c2).dx,
        s(seg.c2).dy,
        s(seg.end).dx,
        s(seg.end).dy,
      );
    }

    // 左半：右半段镜像 + 逆序，从底部中点走回顶点。每段起点是上一段（原方向）的起点。
    final List<Offset> starts = <Offset>[
      _apexTop,
      for (int i = 0; i < _rightHalf.length - 1; i++) _rightHalf[i].end,
    ];
    for (int i = _rightHalf.length - 1; i >= 0; i--) {
      final _ChassisCubic seg = _rightHalf[i];
      final Offset c1 = _mirror(seg.c2);
      final Offset c2 = _mirror(seg.c1);
      final Offset end = _mirror(starts[i]);
      path.cubicTo(
        s(c1).dx,
        s(c1).dy,
        s(c2).dx,
        s(c2).dy,
        s(end).dx,
        s(end).dy,
      );
    }

    return path..close();
  }

  @override
  void paint(Canvas canvas, Size size) {
    final Path path = _buildChassisPath(size);

    // 柔和投影：轮廓下移一点点 + 模糊，把手柄从设置背景上抬起。
    final Paint shadowPaint = Paint()
      ..color = shadow.withValues(alpha: 0.28)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 6);
    canvas.drawPath(path.shift(Offset(0, size.height * 0.025)), shadowPaint);

    // 机身：顶浅底深的竖向渐变，制造塑料外壳的立体感。
    final Paint bodyPaint = Paint()
      ..shader = LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: <Color>[bodyTop, bodyBottom],
      ).createShader(Offset.zero & size);
    canvas.drawPath(path, bodyPaint);

    // 描边：随图缩放的高对比细边，勾出手柄外形（任何主题下可见）。
    final double stroke =
        (size.shortestSide * 0.008).clamp(1.2, 3.0).toDouble();
    final Paint outlinePaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..color = outline;
    canvas.drawPath(path, outlinePaint);

    // 结构安装位：摇杆凹窝、面键盘面、十字键圆盘。
    final Paint mountFillPaint = Paint()..color = mountFill;
    final Paint mountLinePaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke * 0.8
      ..color = mountLine;
    for (final _ChassisMount m in mounts) {
      canvas.drawCircle(m.center, m.radius, mountFillPaint);
      canvas.drawCircle(m.center, m.radius, mountLinePaint);
    }
  }

  @override
  bool shouldRepaint(_GamepadChassisPainter old) =>
      old.bodyTop != bodyTop ||
      old.bodyBottom != bodyBottom ||
      old.outline != outline ||
      old.shadow != shadow ||
      old.mountFill != mountFill ||
      old.mountLine != mountLine ||
      !listEquals(old.mounts, mounts);
}
