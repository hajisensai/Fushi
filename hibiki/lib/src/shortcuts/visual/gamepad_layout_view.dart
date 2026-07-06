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
  // 顶缘肩键/扳机 + 中央系统键 + 右侧面键菱形：三品牌同位。
  final List<GamepadPadSpec> common = <GamepadPadSpec>[
    const GamepadPadSpec(
      GamepadButton.lt,
      Offset(0.13, 0),
      shape: GamepadPadShape.pill,
    ),
    const GamepadPadSpec(
      GamepadButton.rt,
      Offset(0.87, 0),
      shape: GamepadPadShape.pill,
    ),
    const GamepadPadSpec(
      GamepadButton.lb,
      Offset(0.13, 0.15),
      shape: GamepadPadShape.pill,
    ),
    const GamepadPadSpec(
      GamepadButton.rb,
      Offset(0.87, 0.15),
      shape: GamepadPadShape.pill,
    ),
    // 系统键：Guide/Home 居中偏上，Select（View/Share/−）左、Start（Menu/Options/+）右。
    const GamepadPadSpec(
      GamepadButton.mode,
      Offset(0.5, 0.18),
      size: 0.8,
      symbol: '◉',
    ),
    GamepadPadSpec(
      GamepadButton.select,
      const Offset(0.38, 0.36),
      size: 0.7,
      symbol: brand == GamepadBrand.nintendoSwitch ? '−' : '⧉',
    ),
    GamepadPadSpec(
      GamepadButton.start,
      const Offset(0.62, 0.36),
      size: 0.7,
      symbol: brand == GamepadBrand.nintendoSwitch ? '+' : '≡',
    ),
    // 面键菱形（右侧）：上 y、左 x、右 b、下 a——符号/配色由 GamepadGlyphs 按品牌决定。
    const GamepadPadSpec(GamepadButton.y, Offset(0.86, 0.26)),
    const GamepadPadSpec(GamepadButton.x, Offset(0.77, 0.44)),
    const GamepadPadSpec(GamepadButton.b, Offset(0.95, 0.44)),
    const GamepadPadSpec(GamepadButton.a, Offset(0.86, 0.62)),
  ];

  // 十字键菱形 + 双摇杆：唯一的品牌几何差异。
  final List<GamepadPadSpec> lower;
  if (brand == GamepadBrand.playstation) {
    // PS：十字键左上（与面键对称），双摇杆对称居下。
    lower = const <GamepadPadSpec>[
      GamepadPadSpec(GamepadButton.dpadUp, Offset(0.14, 0.26), symbol: '↑'),
      GamepadPadSpec(GamepadButton.dpadLeft, Offset(0.05, 0.44), symbol: '←'),
      GamepadPadSpec(GamepadButton.dpadRight, Offset(0.23, 0.44), symbol: '→'),
      GamepadPadSpec(GamepadButton.dpadDown, Offset(0.14, 0.62), symbol: '↓'),
      GamepadPadSpec(GamepadButton.thumbLeft, Offset(0.35, 0.85), size: 1.25),
      GamepadPadSpec(GamepadButton.thumbRight, Offset(0.65, 0.85), size: 1.25),
    ];
  } else {
    // Xbox / Switch：左摇杆左上，十字键左下，右摇杆右下内收。
    lower = const <GamepadPadSpec>[
      GamepadPadSpec(GamepadButton.thumbLeft, Offset(0.14, 0.4), size: 1.25),
      GamepadPadSpec(GamepadButton.dpadUp, Offset(0.32, 0.58), symbol: '↑'),
      GamepadPadSpec(GamepadButton.dpadLeft, Offset(0.23, 0.76), symbol: '←'),
      GamepadPadSpec(GamepadButton.dpadRight, Offset(0.41, 0.76), symbol: '→'),
      GamepadPadSpec(GamepadButton.dpadDown, Offset(0.32, 0.94), symbol: '↓'),
      GamepadPadSpec(GamepadButton.thumbRight, Offset(0.68, 0.76), size: 1.25),
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

  /// 整图宽高比（真实手柄横长竖短）。
  static const double figureAspectRatio = 1.9;

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

    return Container(
      width: width,
      height: height,
      padding: EdgeInsets.all(baseDiameter * 0.3),
      decoration: ShapeDecoration(
        shape: RoundedRectangleBorder(
          borderRadius: tokens.radii.dialogRadius,
          side: BorderSide(color: scheme.outlineVariant),
        ),
      ),
      child: Stack(
        children: <Widget>[
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
