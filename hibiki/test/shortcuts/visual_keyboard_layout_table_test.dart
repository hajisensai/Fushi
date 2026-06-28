import 'package:flutter/services.dart' hide ModifierKey;
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/shortcuts/visual/keyboard_layout_view.dart';

/// TODO-942：物理键盘布局纯函数单测。
///
/// `buildPhysicalKeyboardRows()` 是渲染无关的纯数据函数，几何全部由数据表表达
/// （逐行缩进 / 修饰键行 / 倒 T 方向键 用留白占位项实现，渲染层零特殊分支）。
/// 本测试钉住行结构、QWERTY 顺序、修饰键存在性、方向键倒 T、留白项不绑定，防回归。
void main() {
  final List<List<KeyboardKeySpec>> rows = buildPhysicalKeyboardRows();

  String labelsOf(List<KeyboardKeySpec> row) => row
      .where((KeyboardKeySpec s) => !s.isSpacer)
      .map((KeyboardKeySpec s) => s.label)
      .join();

  test('row count matches the physical keyboard skin (function..arrows)', () {
    // 功能 / 数字 / QWER / ASDF / ZXCV / 修饰键 / 导航 / 倒T上 / 倒T下 = 9 行。
    expect(rows.length, 9);
  });

  test('letter rows preserve QWERTY physical order, not alphabetical', () {
    expect(labelsOf(rows[2]), 'TabQWERTYUIOP');
    expect(labelsOf(rows[3]), 'ASDFGHJKLEnter');
    expect(labelsOf(rows[4]), 'ZXCVBNMDel');
  });

  test('ASDF and ZXCV rows begin with a non-binding indent spacer', () {
    expect(rows[3].first.isSpacer, isTrue,
        reason: 'ASDF row must start with an indent spacer (no key)');
    expect(rows[3].first.key, isNull);
    expect(rows[4].first.isSpacer, isTrue,
        reason: 'ZXCV row must start with a wider indent spacer');
    expect(rows[4].first.key, isNull);
    // ZXCV 缩进比 ASDF 大（阶梯感）。
    expect(rows[4].first.flex, greaterThan(rows[3].first.flex));
  });

  test(
      'a modifier row exists with Ctrl/Win/Alt/Space all marked modifier '
      'except Space', () {
    final List<KeyboardKeySpec> modRow = rows.firstWhere(
      (List<KeyboardKeySpec> r) =>
          r.any((KeyboardKeySpec s) => s.kind == KeyCapKind.modifier),
    );
    final List<String> modLabels = modRow
        .where((KeyboardKeySpec s) => s.kind == KeyCapKind.modifier)
        .map((KeyboardKeySpec s) => s.label)
        .toList();
    expect(modLabels, containsAll(<String>['Ctrl', 'Win', 'Alt']));
    // Space 在修饰键行但本身不是 modifier 分区（普通可绑键）。
    final KeyboardKeySpec space = modRow.firstWhere(
      (KeyboardKeySpec s) => s.label == 'Space',
    );
    expect(space.kind, KeyCapKind.normal);
  });

  test(
      'arrow keys form an inverted-T: Up alone on a row, Left/Down/Right below',
      () {
    final List<KeyboardKeySpec> upRow = rows[rows.length - 2];
    final List<KeyboardKeySpec> lrdRow = rows[rows.length - 1];

    // 上键行：唯一非留白键是 Up，且左右各有留白居中。
    final List<KeyboardKeySpec> upKeys =
        upRow.where((KeyboardKeySpec s) => !s.isSpacer).toList();
    expect(upKeys.length, 1);
    expect(upKeys.single.key, LogicalKeyboardKey.arrowUp);
    expect(upRow.first.isSpacer, isTrue);
    expect(upRow.last.isSpacer, isTrue);

    // 下键行：Left / Down / Right。
    expect(labelsOf(lrdRow), 'LeftDownRight');
    final List<LogicalKeyboardKey?> lrdKeys = lrdRow
        .where((KeyboardKeySpec s) => !s.isSpacer)
        .map((KeyboardKeySpec s) => s.key)
        .toList();
    expect(lrdKeys, <LogicalKeyboardKey>[
      LogicalKeyboardKey.arrowLeft,
      LogicalKeyboardKey.arrowDown,
      LogicalKeyboardKey.arrowRight,
    ]);
  });

  test('spacer items carry no logical key and never bind', () {
    for (final List<KeyboardKeySpec> row in rows) {
      for (final KeyboardKeySpec spec in row) {
        if (spec.isSpacer) {
          expect(spec.key, isNull,
              reason: 'spacer must not reference a logical key');
        }
      }
    }
  });

  test('presentedKeys excludes spacers and modifier caps, has no duplicates',
      () {
    final Set<LogicalKeyboardKey> presented = KeyboardLayoutView.presentedKeys;

    // 修饰键不进 presentedKeys（只读分区，不参与高亮/绑定索引）。
    expect(presented.contains(LogicalKeyboardKey.controlLeft), isFalse);
    expect(presented.contains(LogicalKeyboardKey.altLeft), isFalse);
    expect(presented.contains(LogicalKeyboardKey.metaLeft), isFalse);

    // 普通可绑键在内。
    expect(presented.contains(LogicalKeyboardKey.keyA), isTrue);
    expect(presented.contains(LogicalKeyboardKey.arrowUp), isTrue);
    expect(presented.contains(LogicalKeyboardKey.space), isTrue);

    // 无重复：手动展开非留白非修饰键计数 == set 大小。
    final List<LogicalKeyboardKey> flat = <LogicalKeyboardKey>[
      for (final List<KeyboardKeySpec> row in rows)
        for (final KeyboardKeySpec spec in row)
          if (!spec.isSpacer && spec.kind != KeyCapKind.modifier) spec.key!,
    ];
    expect(flat.length, presented.length,
        reason: 'no duplicate bindable keys on the figure');
  });
}
