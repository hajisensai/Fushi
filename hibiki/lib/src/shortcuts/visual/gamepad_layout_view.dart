import 'package:flutter/material.dart';
import 'package:hibiki/src/shortcuts/input_binding.dart';
import 'package:hibiki/src/shortcuts/shortcut_action.dart';
import 'package:hibiki/src/shortcuts/shortcut_registry.dart';
import 'package:hibiki/src/shortcuts/visual/gamepad_button_widget.dart';
import 'package:hibiki/src/shortcuts/visual/gamepad_glyphs.dart';
import 'package:hibiki/src/shortcuts/visual/reverse_binding_index.dart';
import 'package:hibiki/src/utils/components/hibiki_design_tokens.dart';

/// 单个手柄按钮在整图上的纯数据描述（TODO-942 P1）。
///
/// 位置用**归一化对齐坐标** [center]（0..1，交给 `FractionalOffset`，(0,0)=左上、
/// (1,1)=右下），尺寸用 [size] 倍数（1.0 = 基准直径），形状 [shape]（面键/摇杆圆钮、
/// 肩键扳机胶囊）。可选 [symbol] 覆盖显示符号（方向键箭头、Start/Select/Mode 图形符），
/// null 时走 [GamepadGlyphs.glyphFor]（面键品牌符号 / L3、R3 等 enum label）。
///
/// 品牌差异（Xbox/Switch 左摇杆左上+十字键左下；PS 十字键左上+双摇杆下中）只体现在
/// [buildGamepadFigure] 的坐标表里，渲染层零品牌分支。
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

  /// 归一化对齐坐标（0..1，`FractionalOffset` 语义）。
  final Offset center;

  /// 尺寸倍数（1.0 = 基准直径）。
  final double size;

  /// 形状（圆钮 / 胶囊）。
  final GamepadPadShape shape;

  /// 显示符号覆盖；null 走 [GamepadGlyphs.glyphFor]。
  final String? symbol;
}

/// 纯函数：返回 [brand] 品牌的整张手柄布局（17 个按钮，位置照真实手柄）。
///
/// 可单测，零渲染依赖。三品牌共用同一组 [GamepadButton]（序列化恒定），差异只有：
/// - **Xbox / Switch**：左摇杆左上、十字键左下（不对称双摇杆布局）。
/// - **PlayStation**：十字键左上、双摇杆对称居下。
/// - Start/Select 符号：Xbox/PS 用 ≡/⧉，Switch 用实机的 +/−。
List<GamepadPadSpec> buildGamepadFigure(GamepadBrand brand) {
  // 顶缘肩键/扳机 + 中央系统键 + 右侧面键菱形：三品牌同位。坐标钉在 [_chassisRightHalf]
  // 描出的手柄本体上（面键菱形落右侧握把上方隆起、系统键居中、肩键/扳机压在顶缘），
  // 让每个按钮都坐在「后面的手柄图案」上而非漂在空矩形里。
  final List<GamepadPadSpec> common = <GamepadPadSpec>[
    const GamepadPadSpec(
      GamepadButton.lt,
      Offset(0.30, 0.045),
      shape: GamepadPadShape.pill,
    ),
    const GamepadPadSpec(
      GamepadButton.rt,
      Offset(0.70, 0.045),
      shape: GamepadPadShape.pill,
    ),
    const GamepadPadSpec(
      GamepadButton.lb,
      Offset(0.30, 0.15),
      shape: GamepadPadShape.pill,
    ),
    const GamepadPadSpec(
      GamepadButton.rb,
      Offset(0.70, 0.15),
      shape: GamepadPadShape.pill,
    ),
    // 系统键：Guide/Home 居中，Select（View/Share/−）左、Start（Menu/Options/+）右。
    const GamepadPadSpec(
      GamepadButton.mode,
      Offset(0.5, 0.30),
      size: 0.8,
      symbol: '◉',
    ),
    GamepadPadSpec(
      GamepadButton.select,
      const Offset(0.42, 0.32),
      size: 0.7,
      symbol: brand == GamepadBrand.nintendoSwitch ? '−' : '⧉',
    ),
    GamepadPadSpec(
      GamepadButton.start,
      const Offset(0.58, 0.32),
      size: 0.7,
      symbol: brand == GamepadBrand.nintendoSwitch ? '+' : '≡',
    ),
    // 面键菱形（右侧握把隆起）：上 y、左 x、右 b、下 a——符号/配色由 GamepadGlyphs 决定。
    const GamepadPadSpec(GamepadButton.y, Offset(0.75, 0.30)),
    const GamepadPadSpec(GamepadButton.x, Offset(0.66, 0.42)),
    const GamepadPadSpec(GamepadButton.b, Offset(0.84, 0.42)),
    const GamepadPadSpec(GamepadButton.a, Offset(0.75, 0.54)),
  ];

  // 十字键菱形 + 双摇杆：唯一的品牌几何差异。
  final List<GamepadPadSpec> lower;
  if (brand == GamepadBrand.playstation) {
    // PS：十字键左上（与面键对称落左侧隆起），双摇杆对称居下、靠近握把内侧腰线。
    lower = const <GamepadPadSpec>[
      GamepadPadSpec(GamepadButton.dpadUp, Offset(0.25, 0.30), symbol: '↑'),
      GamepadPadSpec(GamepadButton.dpadLeft, Offset(0.17, 0.42), symbol: '←'),
      GamepadPadSpec(GamepadButton.dpadRight, Offset(0.33, 0.42), symbol: '→'),
      GamepadPadSpec(GamepadButton.dpadDown, Offset(0.25, 0.54), symbol: '↓'),
      GamepadPadSpec(GamepadButton.thumbLeft, Offset(0.38, 0.62), size: 1.25),
      GamepadPadSpec(GamepadButton.thumbRight, Offset(0.62, 0.62), size: 1.25),
    ];
  } else {
    // Xbox / Switch：左摇杆左上隆起，十字键左下，右摇杆下中内收。
    lower = const <GamepadPadSpec>[
      GamepadPadSpec(GamepadButton.thumbLeft, Offset(0.25, 0.42), size: 1.25),
      GamepadPadSpec(GamepadButton.dpadUp, Offset(0.36, 0.54), symbol: '↑'),
      GamepadPadSpec(GamepadButton.dpadLeft, Offset(0.28, 0.62), symbol: '←'),
      GamepadPadSpec(GamepadButton.dpadRight, Offset(0.44, 0.62), symbol: '→'),
      GamepadPadSpec(GamepadButton.dpadDown, Offset(0.36, 0.70), symbol: '↓'),
      GamepadPadSpec(GamepadButton.thumbRight, Offset(0.60, 0.60), size: 1.25),
    ];
  }

  return <GamepadPadSpec>[...common, ...lower];
}

/// 整张真实布局的手柄预览图（TODO-942 P1，替代旧的四段 Wrap 圆钮堆叠）。
///
/// 数据来自 [buildGamepadFigure] 纯函数；渲染 = 外壳淡描边容器 + `Stack` +
/// `Align(FractionalOffset)` 摆 17 个 [GamepadButtonWidget]，零布局特殊分支。
/// 已绑按钮高亮沿用 [ReverseBindingIndex]；点击语义与旧面板一致：已绑走
/// [onGamepadTap]（action-first 编辑），未绑走 [onEmptyGamepadTap]（key-first 分配）。
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
        return SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: _buildFigure(context, index, specs, idealFigureWidth),
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
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);
    // 基准直径随图宽缩放（480 宽 → 40，与旧面板圆钮同尺度）。
    final double baseDiameter = width / 12;
    final double height = width / figureAspectRatio;

    return SizedBox(
      width: width,
      height: height,
      // 「后面的手柄图案」：手柄本体轮廓（两侧握把 + 顶缘肩部隆起）铺底，17 个现成
      // Kenney 按钮图标坐在其上、当前绑定的键高亮。轮廓是随主题着色的结构外壳（非重绘
      // 按钮），本体着色取自 ColorScheme，浅/深色主题自动适配。
      child: Stack(
        clipBehavior: Clip.none,
        children: <Widget>[
          Positioned.fill(
            child: CustomPaint(
              painter: _GamepadChassisPainter(
                bodyTop: tokens.surfaces.overlay,
                bodyBottom: tokens.surfaces.search,
                outline: scheme.outlineVariant,
                shadow: scheme.shadow,
              ),
            ),
          ),
          for (final GamepadPadSpec spec in specs)
            Align(
              alignment: FractionalOffset(spec.center.dx, spec.center.dy),
              child: _buildPad(index, spec, baseDiameter),
            ),
        ],
      ),
    );
  }

  Widget _buildPad(
    ReverseBindingIndex index,
    GamepadPadSpec spec,
    double baseDiameter,
  ) {
    final bool bound = index.isGamepadBound(spec.button);
    final List<ShortcutAction> actions = index.actionsForButton(spec.button);
    final VoidCallback? tap;
    if (bound && onGamepadTap != null) {
      tap = () => onGamepadTap!(spec.button, actions);
    } else if (!bound && onEmptyGamepadTap != null) {
      tap = () => onEmptyGamepadTap!(spec.button);
    } else {
      tap = null;
    }

    return GamepadButtonWidget(
      key: Key('gamepad_btn_${spec.button.label}'),
      button: spec.button,
      brand: gamepadBrand,
      bound: bound,
      onTap: tap,
      diameter: baseDiameter * spec.size,
      shape: spec.shape,
      overrideSymbol: spec.symbol,
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

/// 「后面的手柄图案」——把手柄本体轮廓（居中机身 + 两侧握把 + 顶缘肩部隆起）作为
/// 结构外壳画在按钮层背后（TODO-942 用户复诉：散装按钮漂在空矩形上、没有手柄样式）。
///
/// 轮廓用一组对称三次贝塞尔描出：右半段从顶部中点顺时针走到底部中点，左半段由右半段
/// **镜像 + 逆序**得到（保证严格左右对称，改一处几何即整机同步）。着色全部取自主题
/// [ColorScheme]（机身用 surfaceContainer 双档做竖向渐变、描边 outlineVariant、投影
/// shadow），浅/深色主题自动适配——**这是结构外壳，不是重绘按钮**；面键/摇杆/方向键仍是
/// 现成的 Kenney CC0 图标叠在其上并按绑定高亮。
class _GamepadChassisPainter extends CustomPainter {
  const _GamepadChassisPainter({
    required this.bodyTop,
    required this.bodyBottom,
    required this.outline,
    required this.shadow,
  });

  final Color bodyTop;
  final Color bodyBottom;
  final Color outline;
  final Color shadow;

  /// 手柄本体右半轮廓（归一化 0..1），起点隐含 [_apexTop]。左半由镜像得到。
  /// 顶部中点 → 右肩顶 → 右上外缘 → 右握把外缘下探 → 右握把尖 → 握把内侧收回腰线 →
  /// 底部中点。
  static const Offset _apexTop = Offset(0.50, 0.10);
  static const List<_ChassisCubic> _rightHalf = <_ChassisCubic>[
    _ChassisCubic(Offset(0.61, 0.05), Offset(0.69, 0.05), Offset(0.76, 0.07)),
    _ChassisCubic(Offset(0.85, 0.09), Offset(0.92, 0.14), Offset(0.94, 0.26)),
    _ChassisCubic(Offset(0.965, 0.44), Offset(0.95, 0.66), Offset(0.90, 0.82)),
    _ChassisCubic(Offset(0.88, 0.92), Offset(0.83, 0.965), Offset(0.76, 0.95)),
    _ChassisCubic(Offset(0.70, 0.93), Offset(0.64, 0.82), Offset(0.60, 0.66)),
    _ChassisCubic(
        Offset(0.565, 0.615), Offset(0.535, 0.60), Offset(0.50, 0.595)),
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

    // 描边：随图缩放的细边，勾出手柄外形。
    final double stroke =
        (size.shortestSide * 0.006).clamp(1.0, 3.0).toDouble();
    final Paint outlinePaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..color = outline;
    canvas.drawPath(path, outlinePaint);
  }

  @override
  bool shouldRepaint(_GamepadChassisPainter old) =>
      old.bodyTop != bodyTop ||
      old.bodyBottom != bodyBottom ||
      old.outline != outline ||
      old.shadow != shadow;
}
