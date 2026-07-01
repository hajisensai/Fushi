import 'package:flutter/material.dart';
import 'package:flutter/services.dart' hide ModifierKey;
import 'package:hibiki/src/shortcuts/input_binding.dart';
import 'package:hibiki/src/shortcuts/shortcut_action.dart';
import 'package:hibiki/src/shortcuts/shortcut_registry.dart';
import 'package:hibiki/src/shortcuts/visual/gamepad_button_widget.dart';
import 'package:hibiki/src/shortcuts/visual/gamepad_glyphs.dart';
import 'package:hibiki/src/shortcuts/visual/key_cap_widget.dart';
import 'package:hibiki/src/shortcuts/visual/reverse_binding_index.dart';

/// 键帽分区类型（TODO-942）。决定键帽的视觉分区色与是否可点。
///
/// - [normal]：普通字母/数字/功能键，已绑时可点改绑。
/// - [modifier]：修饰键（Ctrl/Shift/Alt/Win），**只读分区展示**——`ReverseBindingIndex`
///   的 key 不含裸 modifier（modifier 不作为 binding 主键），故修饰键键帽永远不可点、
///   不参与高亮，仅作视觉分区（用 secondaryContainer 区分），与「未绑键不可点」语义一致。
/// - [spacer]：行缩进 / 倒 T 方向键留白占位（`key==null`），不渲染键帽只占宽。
enum KeyCapKind { normal, modifier, spacer }

/// 单个键位的纯数据描述（TODO-942：从 `_KeySpec` 升级）。
///
/// 用 [flex] 占宽倍数（double，支持 1.25 等真键盘宽度）+ [kind] 分区类型 +
/// 可空 [key] 表达真键盘几何。`key==null` 表示留白占位（行缩进 / 倒 T 空位），
/// 渲染时只占宽不画键帽，也不进反向绑定索引。
@immutable
class KeyboardKeySpec {
  const KeyboardKeySpec(
    this.key,
    this.label, {
    this.flex = 1.0,
    this.kind = KeyCapKind.normal,
  });

  /// 留白占位构造：无逻辑键、无标签，只占 [flex] 宽。
  const KeyboardKeySpec.spacer(this.flex)
      : key = null,
        label = '',
        kind = KeyCapKind.spacer;

  /// 本键帽代表的逻辑键；null = 留白占位（不绑定、不可点）。
  final LogicalKeyboardKey? key;

  /// 键面显示文本（如 'A'、'Esc'、'Ctrl'）。
  final String label;

  /// 占宽倍数（1.0 = 一个标准键宽）。
  final double flex;

  /// 分区类型。
  final KeyCapKind kind;

  /// 是否为留白占位（不画键帽）。
  bool get isSpacer => kind == KeyCapKind.spacer || key == null;
}

/// 纯函数：返回物理键盘几何（行 → 键位列表，含逐行递进缩进 + 修饰键行 +
/// 倒 T 方向键）。可单测，零渲染依赖（Linus 式：用数据表里的留白占位项消除
/// 「为什么不像真键盘」的特殊布局分支，渲染层不写任何 if）。
///
/// 行结构：
/// 1. 功能键行：Esc / F1..F12。
/// 2. 数字行：1..0 + Bksp(flex2)。
/// 3. Tab(flex1.5) + QWERTYUIOP。
/// 4. ASDF 行：行首 0.75 缩进留白 + ASDFGHJKL + Enter(flex1.75)。
/// 5. ZXCV 行：行首 1.25 缩进留白 + ZXCVBNM + Del。
/// 6. 修饰键行：Ctrl/Win/Alt + Space(flex5) + Alt/Ctrl（modifier 分区，只读）。
/// 7. 导航行：Home/PgUp/PgDn/End。
/// 8. 倒 T 上键行：留白 + Up + 留白。
/// 9. 倒 T 下键行：Left/Down/Right。
List<List<KeyboardKeySpec>> buildPhysicalKeyboardRows() {
  return <List<KeyboardKeySpec>>[
    <KeyboardKeySpec>[
      const KeyboardKeySpec(LogicalKeyboardKey.escape, 'Esc'),
      const KeyboardKeySpec(LogicalKeyboardKey.f1, 'F1'),
      const KeyboardKeySpec(LogicalKeyboardKey.f2, 'F2'),
      const KeyboardKeySpec(LogicalKeyboardKey.f3, 'F3'),
      const KeyboardKeySpec(LogicalKeyboardKey.f4, 'F4'),
      const KeyboardKeySpec(LogicalKeyboardKey.f5, 'F5'),
      const KeyboardKeySpec(LogicalKeyboardKey.f6, 'F6'),
      const KeyboardKeySpec(LogicalKeyboardKey.f7, 'F7'),
      const KeyboardKeySpec(LogicalKeyboardKey.f8, 'F8'),
      const KeyboardKeySpec(LogicalKeyboardKey.f9, 'F9'),
      const KeyboardKeySpec(LogicalKeyboardKey.f10, 'F10'),
      const KeyboardKeySpec(LogicalKeyboardKey.f11, 'F11'),
      const KeyboardKeySpec(LogicalKeyboardKey.f12, 'F12'),
    ],
    <KeyboardKeySpec>[
      const KeyboardKeySpec(LogicalKeyboardKey.digit1, '1'),
      const KeyboardKeySpec(LogicalKeyboardKey.digit2, '2'),
      const KeyboardKeySpec(LogicalKeyboardKey.digit3, '3'),
      const KeyboardKeySpec(LogicalKeyboardKey.digit4, '4'),
      const KeyboardKeySpec(LogicalKeyboardKey.digit5, '5'),
      const KeyboardKeySpec(LogicalKeyboardKey.digit6, '6'),
      const KeyboardKeySpec(LogicalKeyboardKey.digit7, '7'),
      const KeyboardKeySpec(LogicalKeyboardKey.digit8, '8'),
      const KeyboardKeySpec(LogicalKeyboardKey.digit9, '9'),
      const KeyboardKeySpec(LogicalKeyboardKey.digit0, '0'),
      const KeyboardKeySpec(LogicalKeyboardKey.backspace, 'Bksp', flex: 2),
    ],
    <KeyboardKeySpec>[
      const KeyboardKeySpec(LogicalKeyboardKey.tab, 'Tab', flex: 1.5),
      const KeyboardKeySpec(LogicalKeyboardKey.keyQ, 'Q'),
      const KeyboardKeySpec(LogicalKeyboardKey.keyW, 'W'),
      const KeyboardKeySpec(LogicalKeyboardKey.keyE, 'E'),
      const KeyboardKeySpec(LogicalKeyboardKey.keyR, 'R'),
      const KeyboardKeySpec(LogicalKeyboardKey.keyT, 'T'),
      const KeyboardKeySpec(LogicalKeyboardKey.keyY, 'Y'),
      const KeyboardKeySpec(LogicalKeyboardKey.keyU, 'U'),
      const KeyboardKeySpec(LogicalKeyboardKey.keyI, 'I'),
      const KeyboardKeySpec(LogicalKeyboardKey.keyO, 'O'),
      const KeyboardKeySpec(LogicalKeyboardKey.keyP, 'P'),
    ],
    <KeyboardKeySpec>[
      const KeyboardKeySpec.spacer(0.75),
      const KeyboardKeySpec(LogicalKeyboardKey.keyA, 'A'),
      const KeyboardKeySpec(LogicalKeyboardKey.keyS, 'S'),
      const KeyboardKeySpec(LogicalKeyboardKey.keyD, 'D'),
      const KeyboardKeySpec(LogicalKeyboardKey.keyF, 'F'),
      const KeyboardKeySpec(LogicalKeyboardKey.keyG, 'G'),
      const KeyboardKeySpec(LogicalKeyboardKey.keyH, 'H'),
      const KeyboardKeySpec(LogicalKeyboardKey.keyJ, 'J'),
      const KeyboardKeySpec(LogicalKeyboardKey.keyK, 'K'),
      const KeyboardKeySpec(LogicalKeyboardKey.keyL, 'L'),
      const KeyboardKeySpec(LogicalKeyboardKey.enter, 'Enter', flex: 1.75),
    ],
    <KeyboardKeySpec>[
      const KeyboardKeySpec.spacer(1.25),
      const KeyboardKeySpec(LogicalKeyboardKey.keyZ, 'Z'),
      const KeyboardKeySpec(LogicalKeyboardKey.keyX, 'X'),
      const KeyboardKeySpec(LogicalKeyboardKey.keyC, 'C'),
      const KeyboardKeySpec(LogicalKeyboardKey.keyV, 'V'),
      const KeyboardKeySpec(LogicalKeyboardKey.keyB, 'B'),
      const KeyboardKeySpec(LogicalKeyboardKey.keyN, 'N'),
      const KeyboardKeySpec(LogicalKeyboardKey.keyM, 'M'),
      const KeyboardKeySpec(LogicalKeyboardKey.delete, 'Del', flex: 1.75),
    ],
    <KeyboardKeySpec>[
      const KeyboardKeySpec(
        LogicalKeyboardKey.controlLeft,
        'Ctrl',
        flex: 1.5,
        kind: KeyCapKind.modifier,
      ),
      const KeyboardKeySpec(
        LogicalKeyboardKey.metaLeft,
        'Win',
        kind: KeyCapKind.modifier,
      ),
      const KeyboardKeySpec(
        LogicalKeyboardKey.altLeft,
        'Alt',
        kind: KeyCapKind.modifier,
      ),
      const KeyboardKeySpec(LogicalKeyboardKey.space, 'Space', flex: 5),
      const KeyboardKeySpec(
        LogicalKeyboardKey.altRight,
        'Alt',
        kind: KeyCapKind.modifier,
      ),
      const KeyboardKeySpec(
        LogicalKeyboardKey.controlRight,
        'Ctrl',
        flex: 1.5,
        kind: KeyCapKind.modifier,
      ),
    ],
    <KeyboardKeySpec>[
      const KeyboardKeySpec(LogicalKeyboardKey.home, 'Home'),
      const KeyboardKeySpec(LogicalKeyboardKey.pageUp, 'PgUp'),
      const KeyboardKeySpec(LogicalKeyboardKey.pageDown, 'PgDn'),
      const KeyboardKeySpec(LogicalKeyboardKey.end, 'End'),
    ],
    // 倒 T 方向键：上键独占一行居中（左右各 1 宽留白）。
    <KeyboardKeySpec>[
      const KeyboardKeySpec.spacer(1),
      const KeyboardKeySpec(LogicalKeyboardKey.arrowUp, 'Up'),
      const KeyboardKeySpec.spacer(1),
    ],
    // 倒 T 方向键：左/下/右一行。
    <KeyboardKeySpec>[
      const KeyboardKeySpec(LogicalKeyboardKey.arrowLeft, 'Left'),
      const KeyboardKeySpec(LogicalKeyboardKey.arrowDown, 'Down'),
      const KeyboardKeySpec(LogicalKeyboardKey.arrowRight, 'Right'),
    ],
  ];
}

class KeyboardLayoutView extends StatelessWidget {
  const KeyboardLayoutView({
    super.key,
    required this.registry,
    required this.scope,
    this.onKeyTap,
    this.onEmptyKeyTap,
    this.onGamepadTap,
    this.onEmptyGamepadTap,
    this.gamepadBrand = GamepadBrand.xbox,
  });

  final HibikiShortcutRegistry registry;
  final ShortcutScope scope;

  /// 点击一个**已绑**键位（回传该键上的 action 列表，走 action-first 编辑）。
  final void Function(
      LogicalKeyboardKey key, List<ShortcutAction> boundActions)? onKeyTap;

  /// 点击一个**未绑**键位（key-first：回传裸逻辑键，由上层选 action 后分配）。
  /// null 时空键位恒不可点（旧「空键不可点」行为，TODO-1060② 前）。
  final void Function(LogicalKeyboardKey key)? onEmptyKeyTap;

  /// 点击一个**已绑**手柄按钮（回传该按钮上的 action 列表）。
  final void Function(GamepadButton button, List<ShortcutAction> boundActions)?
      onGamepadTap;

  /// 点击一个**未绑**手柄按钮（key-first：回传裸按钮，由上层选 action 后分配）。
  final void Function(GamepadButton button)? onEmptyGamepadTap;

  /// 手柄按钮图显示品牌（TODO-1050a）。当前无品牌检测/设置，默认 Xbox；
  /// TODO-612 后续接入品牌检测或设置项后由上层传入。只换显示符号/配色，不改序列化。
  final GamepadBrand gamepadBrand;

  /// 图上呈现的全部可绑逻辑键（排除留白占位与修饰键——修饰键只读分区不进绑定索引）。
  static Set<LogicalKeyboardKey> get presentedKeys => <LogicalKeyboardKey>{
        for (final List<KeyboardKeySpec> row in buildPhysicalKeyboardRows())
          for (final KeyboardKeySpec spec in row)
            if (!spec.isSpacer && spec.kind != KeyCapKind.modifier) spec.key!,
      };

  @override
  Widget build(BuildContext context) {
    final ReverseBindingIndex index =
        ReverseBindingIndex.fromRegistry(registry, scope);
    final List<List<KeyboardKeySpec>> rows = buildPhysicalKeyboardRows();

    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        // 最宽行的总 flex（含留白）决定一个标准键宽 unit。
        final double maxFlex = rows.fold<double>(
          1,
          (double acc, List<KeyboardKeySpec> row) {
            final double rowFlex = row.fold<double>(
                0, (double a, KeyboardKeySpec s) => a + s.flex);
            return rowFlex > acc ? rowFlex : acc;
          },
        );
        const double gap = 4;
        // 可读下限：窄屏 unit 低于该值时切横向滚动按理想宽度绘制（真键盘不该被压扁）。
        const double minReadableUnit = 30;
        const double idealUnit = 44;

        final double available =
            constraints.maxWidth.isFinite ? constraints.maxWidth : 640;
        final double fitUnit = (available - gap * (maxFlex - 1)) / maxFlex;

        final Widget keyboard;
        if (fitUnit >= minReadableUnit) {
          // 宽屏：自适应填满（保留旧 clamp 上界，避免超大屏键帽过宽）。
          final double unit = fitUnit.clamp(minReadableUnit, 56.0);
          keyboard = _buildKeyboard(index, rows, unit, gap);
        } else {
          // 窄屏：按理想固定 unit 绘制，外层横向滚动兜底。
          keyboard = SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: _buildKeyboard(index, rows, idealUnit, gap),
          );
        }

        // TODO-1050a: 键盘图下方渲染手柄按钮图（数据层 GamepadGlyphs 已就绪，此处接线）。
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            keyboard,
            SizedBox(height: gap * 3),
            _buildGamepadPanel(index, gap),
          ],
        );
      },
    );
  }

  Widget _buildKeyboard(
    ReverseBindingIndex index,
    List<List<KeyboardKeySpec>> rows,
    double unit,
    double gap,
  ) {
    // 行内键间隙用每键之间的 SizedBox(width: gap) 表达（不给末键加尾随 padding，避免
    // 整行多出一个 gap 溢出）。所有行共享同一 unit + 行首缩进留白，自然形成阶梯对齐，
    // 导航行/方向键行天然更窄（与真键盘一致），无需强行撑到统一总宽。
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        for (final List<KeyboardKeySpec> row in rows)
          Padding(
            padding: EdgeInsets.only(bottom: gap),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                for (int i = 0; i < row.length; i++) ...<Widget>[
                  if (i > 0) SizedBox(width: gap),
                  _buildCap(index, row[i], unit, gap),
                ],
              ],
            ),
          ),
      ],
    );
  }

  Widget _buildCap(
    ReverseBindingIndex index,
    KeyboardKeySpec spec,
    double unit,
    double gap,
  ) {
    final double width = unit * spec.flex + gap * (spec.flex - 1);

    // 留白占位：只占宽不画键帽。
    if (spec.isSpacer) {
      return SizedBox(width: width);
    }

    // 修饰键：只读分区展示，恒不可点、不参与高亮（key 不进反向索引）。
    if (spec.kind == KeyCapKind.modifier) {
      return KeyCapWidget(
        key: Key('keycap_${spec.key!.keyId}'),
        logicalKey: spec.key!,
        label: spec.label,
        bound: false,
        isModifier: true,
        onTap: null,
        width: width,
      );
    }

    final bool bound = index.isKeyboardBound(spec.key!);
    final List<ShortcutAction> actions = index.actionsForKey(spec.key!);
    // TODO-1060②: un-defer 「空键不可点」。已绑键位走 action-first onKeyTap（编辑其
    // 首个 action）；未绑键位走 key-first onEmptyKeyTap（上层选 action 后分配到本键）。
    // 两路都复用页面既有 _editBinding 写穿路径，不造第二套分配逻辑。
    final VoidCallback? tap;
    if (bound && onKeyTap != null) {
      tap = () => onKeyTap!(spec.key!, actions);
    } else if (!bound && onEmptyKeyTap != null) {
      tap = () => onEmptyKeyTap!(spec.key!);
    } else {
      tap = null;
    }

    return KeyCapWidget(
      key: Key('keycap_${spec.key!.keyId}'),
      logicalKey: spec.key!,
      label: spec.label,
      bound: bound,
      onTap: tap,
      width: width,
    );
  }

  /// 手柄按钮图行组（TODO-1050a）。分面键 / 肩键扳机 / 方向键 / 系统键四段，每段一 Wrap。
  /// 已绑按钮高亮 + 走 [onGamepadTap]；未绑按钮走 [onEmptyGamepadTap]（key-first 分配）。
  /// 品牌显示走 [gamepadBrand]（默认 Xbox），只换符号/配色不改序列化。
  Widget _buildGamepadPanel(ReverseBindingIndex index, double gap) {
    const List<List<GamepadButton>> groups = <List<GamepadButton>>[
      <GamepadButton>[
        GamepadButton.a,
        GamepadButton.b,
        GamepadButton.x,
        GamepadButton.y,
      ],
      <GamepadButton>[
        GamepadButton.lb,
        GamepadButton.rb,
        GamepadButton.lt,
        GamepadButton.rt,
      ],
      <GamepadButton>[
        GamepadButton.dpadUp,
        GamepadButton.dpadDown,
        GamepadButton.dpadLeft,
        GamepadButton.dpadRight,
      ],
      <GamepadButton>[
        GamepadButton.thumbLeft,
        GamepadButton.thumbRight,
        GamepadButton.start,
        GamepadButton.select,
        GamepadButton.mode,
      ],
    ];

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        for (final List<GamepadButton> group in groups)
          Padding(
            padding: EdgeInsets.only(bottom: gap),
            child: Wrap(
              spacing: gap,
              runSpacing: gap,
              children: <Widget>[
                for (final GamepadButton button in group)
                  _buildGamepadButton(index, button),
              ],
            ),
          ),
      ],
    );
  }

  Widget _buildGamepadButton(ReverseBindingIndex index, GamepadButton button) {
    final bool bound = index.isGamepadBound(button);
    final List<ShortcutAction> actions = index.actionsForButton(button);
    final VoidCallback? tap;
    if (bound && onGamepadTap != null) {
      tap = () => onGamepadTap!(button, actions);
    } else if (!bound && onEmptyGamepadTap != null) {
      tap = () => onEmptyGamepadTap!(button);
    } else {
      tap = null;
    }

    return GamepadButtonWidget(
      key: Key('gamepad_btn_${button.label}'),
      button: button,
      brand: gamepadBrand,
      bound: bound,
      onTap: tap,
    );
  }
}
