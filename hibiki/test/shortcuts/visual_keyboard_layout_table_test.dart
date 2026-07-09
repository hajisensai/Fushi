import 'package:flutter/services.dart' hide ModifierKey;
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/shortcuts/visual/keyboard_layout_view.dart';

/// TODO-942 P2：真实 ANSI 键盘布局纯函数单测。
///
/// `buildPhysicalKeyboardRows()` 是渲染无关的纯数据函数：真实 ANSI 主区 6 行，
/// 每行 flex 之和恒等于 [kAnsiMainRowFlex]（=15，矩形守恒）。导航簇拆到
/// `buildNavClusterRows()`（Ins/Del/Home/End/PgUp/PgDn + 倒 T 方向键）。
/// 本测试钉住行结构、ANSI 顺序、每行宽度守恒、Shift 修饰只读、导航簇倒 T、
/// presentedKeys 为主区∪导航簇、留白不绑定，防回归。
void main() {
  final List<List<KeyboardKeySpec>> rows = buildPhysicalKeyboardRows();
  final List<List<KeyboardKeySpec>> nav = buildNavClusterRows();

  String labelsOf(List<KeyboardKeySpec> row) => row
      .where((KeyboardKeySpec s) => !s.isSpacer)
      .map((KeyboardKeySpec s) => s.label)
      .join();

  double flexOf(List<KeyboardKeySpec> row) =>
      row.fold<double>(0, (double a, KeyboardKeySpec s) => a + s.flex);

  test('main area has the 6 ANSI rows (function..modifier), no nav/arrow rows',
      () {
    // 功能 / 数字 / QWER / ASDF / ZXCV / 修饰键 = 6 行。导航簇与方向键不在主区。
    expect(rows.length, 6);
    final Set<LogicalKeyboardKey?> mainKeys = <LogicalKeyboardKey?>{
      for (final List<KeyboardKeySpec> row in rows)
        for (final KeyboardKeySpec s in row) s.key,
    };
    expect(mainKeys.contains(LogicalKeyboardKey.arrowUp), isFalse,
        reason: 'arrow keys moved to the nav cluster block');
    expect(mainKeys.contains(LogicalKeyboardKey.home), isFalse,
        reason: 'Home moved to the nav cluster block');
  });

  test('every main row conserves flex == kAnsiMainRowFlex (rectangular)', () {
    for (final List<KeyboardKeySpec> row in rows) {
      expect(flexOf(row), kAnsiMainRowFlex,
          reason: 'each ANSI row must span exactly 15 units');
    }
    expect(kAnsiMainRowFlex, 15);
  });

  test('rows preserve real ANSI physical order with punctuation', () {
    expect(labelsOf(rows[1]), '`1234567890-=Bksp');
    expect(labelsOf(rows[2]), 'TabQWERTYUIOP[]\\');
    expect(labelsOf(rows[3]), 'CapsASDFGHJKL;\u0027Enter');
    expect(labelsOf(rows[4]), 'ShiftZXCVBNM,./Shift');
  });

  test('function row starts with Esc and carries all F1..F12', () {
    final List<String> fLabels = labelsOf(rows[0]).split('');
    expect(rows[0].first.key, LogicalKeyboardKey.escape);
    for (int n = 1; n <= 12; n++) {
      expect(labelsOf(rows[0]).contains('F$n'), isTrue,
          reason: 'function row must contain F$n');
    }
    expect(fLabels.isNotEmpty, isTrue);
  });

  test('CapsLock is a bindable normal cap (not a modifier partition)', () {
    final KeyboardKeySpec caps = rows[3].first;
    expect(caps.key, LogicalKeyboardKey.capsLock);
    expect(caps.kind, KeyCapKind.normal);
    expect(caps.flex, 1.75);
  });

  test('left/right Shift are read-only modifier caps (2.25 / 2.75)', () {
    final KeyboardKeySpec lShift = rows[4].first;
    final KeyboardKeySpec rShift = rows[4].last;
    expect(lShift.key, LogicalKeyboardKey.shiftLeft);
    expect(lShift.kind, KeyCapKind.modifier);
    expect(lShift.flex, 2.25);
    expect(rShift.key, LogicalKeyboardKey.shiftRight);
    expect(rShift.kind, KeyCapKind.modifier);
    expect(rShift.flex, 2.75);
  });

  test('modifier row has Ctrl/Win/Alt as modifiers and Space as normal', () {
    final List<KeyboardKeySpec> modRow = rows[5];
    final List<String> modLabels = modRow
        .where((KeyboardKeySpec s) => s.kind == KeyCapKind.modifier)
        .map((KeyboardKeySpec s) => s.label)
        .toList();
    expect(modLabels, containsAll(<String>['Ctrl', 'Win', 'Alt']));
    final KeyboardKeySpec space =
        modRow.firstWhere((KeyboardKeySpec s) => s.label == 'Space');
    expect(space.kind, KeyCapKind.normal);
    expect(space.key, LogicalKeyboardKey.space);
  });

  test('nav cluster carries Ins/Del/Home/End/PgUp/PgDn', () {
    final Set<LogicalKeyboardKey?> navKeys = <LogicalKeyboardKey?>{
      for (final List<KeyboardKeySpec> row in nav)
        for (final KeyboardKeySpec s in row) s.key,
    };
    expect(
      navKeys,
      containsAll(<LogicalKeyboardKey>[
        LogicalKeyboardKey.insert,
        LogicalKeyboardKey.delete,
        LogicalKeyboardKey.home,
        LogicalKeyboardKey.end,
        LogicalKeyboardKey.pageUp,
        LogicalKeyboardKey.pageDown,
      ]),
    );
  });

  test('nav cluster arrows form an inverted-T (Up alone, then Left/Down/Right)',
      () {
    final List<KeyboardKeySpec> upRow = nav[nav.length - 2];
    final List<KeyboardKeySpec> lrdRow = nav[nav.length - 1];
    final List<KeyboardKeySpec> upKeys =
        upRow.where((KeyboardKeySpec s) => !s.isSpacer).toList();
    expect(upKeys.length, 1);
    expect(upKeys.single.key, LogicalKeyboardKey.arrowUp);
    expect(upRow.first.isSpacer, isTrue);
    expect(upRow.last.isSpacer, isTrue);
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
    for (final List<KeyboardKeySpec> row in <List<KeyboardKeySpec>>[
      ...rows,
      ...nav,
    ]) {
      for (final KeyboardKeySpec spec in row) {
        if (spec.isSpacer) {
          expect(spec.key, isNull);
        }
      }
    }
  });

  test('presentedKeys is the union of main + nav bindable keys, no dups', () {
    final Set<LogicalKeyboardKey> presented = KeyboardLayoutView.presentedKeys;
    // Modifiers (incl. Shift) never enter presentedKeys.
    expect(presented.contains(LogicalKeyboardKey.controlLeft), isFalse);
    expect(presented.contains(LogicalKeyboardKey.shiftLeft), isFalse);
    expect(presented.contains(LogicalKeyboardKey.shiftRight), isFalse);
    expect(presented.contains(LogicalKeyboardKey.metaLeft), isFalse);
    // Main-area bindable keys.
    expect(presented.contains(LogicalKeyboardKey.keyA), isTrue);
    expect(presented.contains(LogicalKeyboardKey.space), isTrue);
    expect(presented.contains(LogicalKeyboardKey.capsLock), isTrue);
    expect(presented.contains(LogicalKeyboardKey.backslash), isTrue);
    expect(presented.contains(LogicalKeyboardKey.quote), isTrue);
    // Nav-cluster keys are in the union (else they vanish from the index).
    expect(presented.contains(LogicalKeyboardKey.arrowUp), isTrue);
    expect(presented.contains(LogicalKeyboardKey.home), isTrue);
    expect(presented.contains(LogicalKeyboardKey.insert), isTrue);
    // No duplicates: manual union count == set size.
    final List<LogicalKeyboardKey> flat = <LogicalKeyboardKey>[
      for (final List<KeyboardKeySpec> row in <List<KeyboardKeySpec>>[
        ...rows,
        ...nav,
      ])
        for (final KeyboardKeySpec spec in row)
          if (!spec.isSpacer && spec.kind != KeyCapKind.modifier) spec.key!,
    ];
    expect(flat.length, presented.length);
  });
}
