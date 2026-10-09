import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart' hide ModifierKey;
import 'package:fushi/src/shortcuts/input_binding.dart';
import 'package:fushi/src/shortcuts/shortcut_action.dart';
import 'package:fushi/src/shortcuts/shortcut_registry.dart';
import 'package:fushi/src/shortcuts/visual/key_cap_widget.dart';
import 'package:fushi/src/shortcuts/visual/reverse_binding_index.dart';
import 'package:fushi/src/utils/misc/platform_utils.dart';

/// 键帽分区类型（TODO-942）。决定键帽的视觉分区色与是否可点。
///
/// - [normal]：普通字母/数字/功能键，已绑时可点改绑。
/// - [modifier]：修饰键（Ctrl/Shift/Alt/Win），只读分区展示——ReverseBindingIndex
///   的 key 不含裸 modifier（modifier 不作为 binding 主键），故修饰键键帽永远不可点、
///   不参与高亮，仅作视觉分区（用 secondaryContainer 区分），与「未绑键不可点」语义一致。
/// - [spacer]：行缩进 / 倒 T 方向键留白占位（key==null），不渲染键帽只占宽。
enum KeyCapKind { normal, modifier, spacer }

/// 单个键位的纯数据描述（TODO-942：从 _KeySpec 升级）。
///
/// 用 [flex] 占宽倍数（double，支持 1.25 等真键盘宽度）+ [kind] 分区类型 +
/// 可空 [key] 表达真键盘几何。key==null 表示留白占位（行缩进 / 倒 T 空位），
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

  /// 键面显示文本（如 A、Esc、Ctrl）。
  final String label;

  /// 占宽倍数（1.0 = 一个标准键宽）。
  final double flex;

  /// 分区类型。
  final KeyCapKind kind;

  /// 是否为留白占位（不画键帽）。
  bool get isSpacer => kind == KeyCapKind.spacer || key == null;
}

/// 真实 ANSI 主区每行的标准键位总宽（单位 = 一个标准键宽）。主区每一行的 flex 之和
/// （含留白 / 修饰键）都恰好等于该常量，键盘才是矩形而非阶梯错位——
/// buildPhysicalKeyboardRows 返回的每一行都被此守恒约束（表测试断言）。
const double kAnsiMainRowFlex = 15;

/// 纯函数：返回真实 ANSI 主区几何（行 → 键位列表）。可单测，零渲染依赖
/// （Linus 式：用数据表里的留白占位项表达真键盘的错位 / 分组间隙，渲染层不写
/// 任何布局 if）。每行总 flex 恒等于 [kAnsiMainRowFlex]（=15），故整块是矩形。
///
/// 导航簇（Ins/Del/Home/End/PgUp/PgDn + 倒 T 方向键）拆到 [buildNavClusterRows]，
/// 作为右侧独立块渲染（真键盘上它们本就在主区右侧，不在主区内）。
///
/// 修饰键行按平台选两套（BUG-3203，用户 10-09 拍板）：macOS / 外接键盘的 iPad
/// 画 Mac 键盘——左下 fn、⌃ control、⌥ option、⌘ command，右侧 ⌘ ⌥；其它平台
/// 画 PC 的 Ctrl / Win / Alt。Mac 上键名也按 Mac 键盘印（esc / tab / caps lock /
/// delete / return，用户 10-10 拍板）。只是示意图的布局数据与显示，逻辑键与
/// 存储键名不变。
/// [platform] 缺省取快捷键显示平台 [shortcutDisplayPlatform]。
List<List<KeyboardKeySpec>> buildPhysicalKeyboardRows({
  TargetPlatform? platform,
}) {
  final bool mac = shortcutUsesAppleSymbols(
    platform ?? shortcutDisplayPlatform,
  );
  final String shiftLabel = mac ? '⇧\nshift' : 'Shift';
  return <List<KeyboardKeySpec>>[
    <KeyboardKeySpec>[
      KeyboardKeySpec(LogicalKeyboardKey.escape, mac ? 'esc' : 'Esc'),
      const KeyboardKeySpec.spacer(0.5),
      const KeyboardKeySpec(LogicalKeyboardKey.f1, 'F1'),
      const KeyboardKeySpec(LogicalKeyboardKey.f2, 'F2'),
      const KeyboardKeySpec(LogicalKeyboardKey.f3, 'F3'),
      const KeyboardKeySpec(LogicalKeyboardKey.f4, 'F4'),
      const KeyboardKeySpec.spacer(0.5),
      const KeyboardKeySpec(LogicalKeyboardKey.f5, 'F5'),
      const KeyboardKeySpec(LogicalKeyboardKey.f6, 'F6'),
      const KeyboardKeySpec(LogicalKeyboardKey.f7, 'F7'),
      const KeyboardKeySpec(LogicalKeyboardKey.f8, 'F8'),
      const KeyboardKeySpec.spacer(0.5),
      const KeyboardKeySpec(LogicalKeyboardKey.f9, 'F9'),
      const KeyboardKeySpec(LogicalKeyboardKey.f10, 'F10'),
      const KeyboardKeySpec(LogicalKeyboardKey.f11, 'F11'),
      const KeyboardKeySpec(LogicalKeyboardKey.f12, 'F12'),
      const KeyboardKeySpec.spacer(0.5),
    ],
    <KeyboardKeySpec>[
      const KeyboardKeySpec(LogicalKeyboardKey.backquote, '`'),
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
      const KeyboardKeySpec(LogicalKeyboardKey.minus, '-'),
      const KeyboardKeySpec(LogicalKeyboardKey.equal, '='),
      KeyboardKeySpec(
        LogicalKeyboardKey.backspace,
        mac ? 'delete' : 'Bksp',
        flex: 2,
      ),
    ],
    <KeyboardKeySpec>[
      KeyboardKeySpec(LogicalKeyboardKey.tab, mac ? 'tab' : 'Tab', flex: 1.5),
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
      const KeyboardKeySpec(LogicalKeyboardKey.bracketLeft, '['),
      const KeyboardKeySpec(LogicalKeyboardKey.bracketRight, ']'),
      const KeyboardKeySpec(LogicalKeyboardKey.backslash, '\\', flex: 1.5),
    ],
    <KeyboardKeySpec>[
      KeyboardKeySpec(
        LogicalKeyboardKey.capsLock,
        mac ? 'caps lock' : 'Caps',
        flex: 1.75,
      ),
      const KeyboardKeySpec(LogicalKeyboardKey.keyA, 'A'),
      const KeyboardKeySpec(LogicalKeyboardKey.keyS, 'S'),
      const KeyboardKeySpec(LogicalKeyboardKey.keyD, 'D'),
      const KeyboardKeySpec(LogicalKeyboardKey.keyF, 'F'),
      const KeyboardKeySpec(LogicalKeyboardKey.keyG, 'G'),
      const KeyboardKeySpec(LogicalKeyboardKey.keyH, 'H'),
      const KeyboardKeySpec(LogicalKeyboardKey.keyJ, 'J'),
      const KeyboardKeySpec(LogicalKeyboardKey.keyK, 'K'),
      const KeyboardKeySpec(LogicalKeyboardKey.keyL, 'L'),
      const KeyboardKeySpec(LogicalKeyboardKey.semicolon, ';'),
      const KeyboardKeySpec(LogicalKeyboardKey.quote, '\''),
      KeyboardKeySpec(
        LogicalKeyboardKey.enter,
        mac ? 'return' : 'Enter',
        flex: 2.25,
      ),
    ],
    <KeyboardKeySpec>[
      KeyboardKeySpec(
        LogicalKeyboardKey.shiftLeft,
        shiftLabel,
        flex: 2.25,
        kind: KeyCapKind.modifier,
      ),
      const KeyboardKeySpec(LogicalKeyboardKey.keyZ, 'Z'),
      const KeyboardKeySpec(LogicalKeyboardKey.keyX, 'X'),
      const KeyboardKeySpec(LogicalKeyboardKey.keyC, 'C'),
      const KeyboardKeySpec(LogicalKeyboardKey.keyV, 'V'),
      const KeyboardKeySpec(LogicalKeyboardKey.keyB, 'B'),
      const KeyboardKeySpec(LogicalKeyboardKey.keyN, 'N'),
      const KeyboardKeySpec(LogicalKeyboardKey.keyM, 'M'),
      const KeyboardKeySpec(LogicalKeyboardKey.comma, ','),
      const KeyboardKeySpec(LogicalKeyboardKey.period, '.'),
      const KeyboardKeySpec(LogicalKeyboardKey.slash, '/'),
      KeyboardKeySpec(
        LogicalKeyboardKey.shiftRight,
        shiftLabel,
        flex: 2.75,
        kind: KeyCapKind.modifier,
      ),
    ],
    if (mac) _macModifierRow else _pcModifierRow,
  ];
}

/// PC 键盘的修饰键行：Ctrl / Win / Alt / Space / Alt / Win / Ctrl（总 flex 15）。
const List<KeyboardKeySpec> _pcModifierRow = <KeyboardKeySpec>[
  KeyboardKeySpec(
    LogicalKeyboardKey.controlLeft,
    'Ctrl',
    flex: 1.5,
    kind: KeyCapKind.modifier,
  ),
  KeyboardKeySpec(
    LogicalKeyboardKey.metaLeft,
    'Win',
    flex: 1.25,
    kind: KeyCapKind.modifier,
  ),
  KeyboardKeySpec(
    LogicalKeyboardKey.altLeft,
    'Alt',
    flex: 1.25,
    kind: KeyCapKind.modifier,
  ),
  KeyboardKeySpec(LogicalKeyboardKey.space, 'Space', flex: 7),
  KeyboardKeySpec(
    LogicalKeyboardKey.altRight,
    'Alt',
    flex: 1.25,
    kind: KeyCapKind.modifier,
  ),
  KeyboardKeySpec(
    LogicalKeyboardKey.metaRight,
    'Win',
    flex: 1.25,
    kind: KeyCapKind.modifier,
  ),
  KeyboardKeySpec(
    LogicalKeyboardKey.controlRight,
    'Ctrl',
    flex: 1.5,
    kind: KeyCapKind.modifier,
  ),
];

/// Mac 键盘的修饰键行：fn / ⌃ control / ⌥ option / ⌘ command / Space /
/// ⌘ command / ⌥ option（总 flex 15，与 PC 行同宽，键盘仍是矩形）。
const List<KeyboardKeySpec> _macModifierRow = <KeyboardKeySpec>[
  KeyboardKeySpec(
    LogicalKeyboardKey.fn,
    'fn',
    flex: 1.25,
    kind: KeyCapKind.modifier,
  ),
  KeyboardKeySpec(
    LogicalKeyboardKey.controlLeft,
    '⌃\ncontrol',
    flex: 1.25,
    kind: KeyCapKind.modifier,
  ),
  KeyboardKeySpec(
    LogicalKeyboardKey.altLeft,
    '⌥\noption',
    flex: 1.25,
    kind: KeyCapKind.modifier,
  ),
  KeyboardKeySpec(
    LogicalKeyboardKey.metaLeft,
    '⌘\ncommand',
    flex: 1.5,
    kind: KeyCapKind.modifier,
  ),
  KeyboardKeySpec(LogicalKeyboardKey.space, 'Space', flex: 7),
  KeyboardKeySpec(
    LogicalKeyboardKey.metaRight,
    '⌘\ncommand',
    flex: 1.5,
    kind: KeyCapKind.modifier,
  ),
  KeyboardKeySpec(
    LogicalKeyboardKey.altRight,
    '⌥\noption',
    flex: 1.25,
    kind: KeyCapKind.modifier,
  ),
];

/// 纯函数：返回导航簇几何（真键盘主区右侧的独立 3 宽块）。可单测，零渲染依赖。
///
/// 行结构（5 行）：Ins/Home/PgUp、Del/End/PgDn、空行间隙、倒 T 上键、倒 T 下键。
/// 导航键与方向键都进 [KeyboardLayoutView.presentedKeys]（与主区键取并集），故不会
/// 从反向绑定索引 / 高亮里消失、可点可绑。
///
/// macOS / iPad 按 Mac 全尺寸键盘画（用户 10-10 拍板）：Mac 没有 Insert，那个位置
/// 是 fn（只读修饰键）；其余是 home / page up、⌦ delete（向前删除，逻辑键仍是
/// [LogicalKeyboardKey.delete]）/ end / page down，方向键印 ← ↑ → ↓。Insert 因此
/// 不在 Mac 示意图上（Mac 键盘按不出来）；默认绑定没有用到它，用户自己或从 PC
/// 同步来的 Insert 绑定照常在快捷键列表里显示与改绑。
List<List<KeyboardKeySpec>> buildNavClusterRows({TargetPlatform? platform}) {
  final bool mac = shortcutUsesAppleSymbols(
    platform ?? shortcutDisplayPlatform,
  );
  return mac ? _macNavClusterRows : _pcNavClusterRows;
}

const List<List<KeyboardKeySpec>> _pcNavClusterRows = <List<KeyboardKeySpec>>[
  <KeyboardKeySpec>[
    KeyboardKeySpec(LogicalKeyboardKey.insert, 'Ins'),
    KeyboardKeySpec(LogicalKeyboardKey.home, 'Home'),
    KeyboardKeySpec(LogicalKeyboardKey.pageUp, 'PgUp'),
  ],
  <KeyboardKeySpec>[
    KeyboardKeySpec(LogicalKeyboardKey.delete, 'Del'),
    KeyboardKeySpec(LogicalKeyboardKey.end, 'End'),
    KeyboardKeySpec(LogicalKeyboardKey.pageDown, 'PgDn'),
  ],
  <KeyboardKeySpec>[
    KeyboardKeySpec.spacer(3),
  ],
  <KeyboardKeySpec>[
    KeyboardKeySpec.spacer(1),
    KeyboardKeySpec(LogicalKeyboardKey.arrowUp, 'Up'),
    KeyboardKeySpec.spacer(1),
  ],
  <KeyboardKeySpec>[
    KeyboardKeySpec(LogicalKeyboardKey.arrowLeft, 'Left'),
    KeyboardKeySpec(LogicalKeyboardKey.arrowDown, 'Down'),
    KeyboardKeySpec(LogicalKeyboardKey.arrowRight, 'Right'),
  ],
];

const List<List<KeyboardKeySpec>> _macNavClusterRows = <List<KeyboardKeySpec>>[
  <KeyboardKeySpec>[
    KeyboardKeySpec(LogicalKeyboardKey.fn, 'fn', kind: KeyCapKind.modifier),
    KeyboardKeySpec(LogicalKeyboardKey.home, 'home'),
    KeyboardKeySpec(LogicalKeyboardKey.pageUp, 'page\nup'),
  ],
  <KeyboardKeySpec>[
    KeyboardKeySpec(LogicalKeyboardKey.delete, '⌦\ndelete'),
    KeyboardKeySpec(LogicalKeyboardKey.end, 'end'),
    KeyboardKeySpec(LogicalKeyboardKey.pageDown, 'page\ndown'),
  ],
  <KeyboardKeySpec>[
    KeyboardKeySpec.spacer(3),
  ],
  <KeyboardKeySpec>[
    KeyboardKeySpec.spacer(1),
    KeyboardKeySpec(LogicalKeyboardKey.arrowUp, '↑'),
    KeyboardKeySpec.spacer(1),
  ],
  <KeyboardKeySpec>[
    KeyboardKeySpec(LogicalKeyboardKey.arrowLeft, '←'),
    KeyboardKeySpec(LogicalKeyboardKey.arrowDown, '↓'),
    KeyboardKeySpec(LogicalKeyboardKey.arrowRight, '→'),
  ],
];

/// 键盘布局预览图（TODO-942 P1 起只画键盘；P2 起补全真实 ANSI 主区 + 右侧导航簇）。
///
/// 手柄整图拆到独立的 GamepadLayoutView（gamepad_layout_view.dart），两块在快捷键
/// 设置页各带标题分开展示——本 widget 不再接任何 gamepad 参数。渲染为左右双块：主区
/// （[buildPhysicalKeyboardRows]，15 宽矩形）+ 右侧导航簇（[buildNavClusterRows]，3 宽）。
/// 窄屏放不下时整体横向滚动（真键盘不该被压扁）。
class KeyboardLayoutView extends StatelessWidget {
  const KeyboardLayoutView({
    super.key,
    required this.registry,
    required this.scope,
    this.onKeyTap,
    this.onEmptyKeyTap,
  });

  final FushiShortcutRegistry registry;
  final ShortcutScope scope;

  /// 点击一个已绑键位（回传该键上的 action 列表，走 action-first 编辑）。
  final void Function(
      LogicalKeyboardKey key, List<ShortcutAction> boundActions)? onKeyTap;

  /// 点击一个未绑键位（key-first：回传裸逻辑键，由上层选 action 后分配）。
  /// null 时空键位恒不可点（旧「空键不可点」行为，TODO-1060② 前）。
  final void Function(LogicalKeyboardKey key)? onEmptyKeyTap;

  /// 图上呈现的全部可绑逻辑键（主区 + 导航簇的并集，排除留白占位与修饰键——修饰键
  /// 只读分区不进绑定索引）。导航簇的键也必须在内，否则导航键从绑定索引消失。
  static Set<LogicalKeyboardKey> get presentedKeys => <LogicalKeyboardKey>{
        for (final List<KeyboardKeySpec> row in buildPhysicalKeyboardRows())
          for (final KeyboardKeySpec spec in row)
            if (!spec.isSpacer && spec.kind != KeyCapKind.modifier) spec.key!,
        for (final List<KeyboardKeySpec> row in buildNavClusterRows())
          for (final KeyboardKeySpec spec in row)
            if (!spec.isSpacer && spec.kind != KeyCapKind.modifier) spec.key!,
      };

  /// 一组行里最宽行的总 flex（含留白）。
  static double _maxRowFlex(List<List<KeyboardKeySpec>> rows) =>
      rows.fold<double>(
        1,
        (double acc, List<KeyboardKeySpec> row) {
          final double rowFlex =
              row.fold<double>(0, (double a, KeyboardKeySpec s) => a + s.flex);
          return rowFlex > acc ? rowFlex : acc;
        },
      );

  @override
  Widget build(BuildContext context) {
    final ReverseBindingIndex index =
        ReverseBindingIndex.fromRegistry(registry, scope);
    final List<List<KeyboardKeySpec>> mainRows = buildPhysicalKeyboardRows();
    final List<List<KeyboardKeySpec>> navRows = buildNavClusterRows();

    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final double mainFlex = _maxRowFlex(mainRows);
        final double navFlex = _maxRowFlex(navRows);
        const double gap = 4;
        // 主区与导航簇之间的块间距（真键盘上导航簇在主区右侧的留白）。
        const double blockGap = 24;
        // 可读下限：窄屏 unit 低于该值时切横向滚动按理想宽度绘制（真键盘不该被压扁）。
        const double minReadableUnit = 30;
        const double idealUnit = 44;

        final double available =
            constraints.maxWidth.isFinite ? constraints.maxWidth : 640;
        final double totalFlex = mainFlex + navFlex;
        final double fixed = gap * ((mainFlex - 1) + (navFlex - 1)) + blockGap;
        final double fitUnit = (available - fixed) / totalFlex;

        if (fitUnit >= minReadableUnit) {
          final double unit = fitUnit.clamp(minReadableUnit, 56.0);
          return _buildBoard(index, mainRows, navRows, unit, gap, blockGap);
        }
        return HorizontalDragScrollable(
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child:
                _buildBoard(index, mainRows, navRows, idealUnit, gap, blockGap),
          ),
        );
      },
    );
  }

  /// 左右双块：主区键盘 + blockGap + 导航簇，顶端对齐。
  Widget _buildBoard(
    ReverseBindingIndex index,
    List<List<KeyboardKeySpec>> mainRows,
    List<List<KeyboardKeySpec>> navRows,
    double unit,
    double gap,
    double blockGap,
  ) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        _buildBlock(index, mainRows, unit, gap),
        SizedBox(width: blockGap),
        _buildBlock(index, navRows, unit, gap),
      ],
    );
  }

  Widget _buildBlock(
    ReverseBindingIndex index,
    List<List<KeyboardKeySpec>> rows,
    double unit,
    double gap,
  ) {
    // 行内键间隙用每键之间的 SizedBox(width: gap) 表达（不给末键加尾随 padding，避免
    // 整行多出一个 gap 溢出）。所有行共享同一 unit + 行首缩进留白，自然形成阶梯对齐。
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
      // 修饰键的字与排列都来自布局数据（macOS 是 Mac 键盘那一套，见
      // [buildPhysicalKeyboardRows]），这里不再按平台改字。
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
}
