import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/pages/implementations/history_reader_page.dart';

import '../helpers/source_guard.dart';

void main() {
  test('history reader page library compiles', () {
    expect(const HistoryReaderPage(), isA<HistoryReaderPage>());
  });

  test('history reader shelf uses shared MD3 card and token chrome', () {
    final String source =
        File('lib/src/pages/implementations/history_reader_page.dart')
            .readAsStringSync();

    expect(source, contains('FushiDesignTokens.of(context)'));
    expect(source, contains('tokens.spacing'));
    expect(source, contains('tokens.type.metadata'));
    // 判据必须带标识符边界，裸子串在两个方向上都错：
    // - 假阳：`Card(` 是 `FushiCard(` 的子串，而本测试第一条正向断言要的正是
    //   「共享 MD3 卡片」——书架一旦真用上 FushiCard，这条守卫立刻假红；
    //   `ListTile(` 同理被 `FushiListTile(` 命中。
    // - 假阴：`SwitchListTile(` 匹配不到本仓真实在用的 `SwitchListTile.adaptive(`
    //   （`SwitchListTile` 后面是 `.` 不是 `(`），旧写法以命名构造器形式回归就完全绕过。
    // 原裸子串 `ListTile(` 顺带盖住的 Radio/Cupertino 变体在下面显式补回，
    // 避免换匹配器时静默削弱守卫强度。
    expect(containsIdentifierCall(source, 'Card'), isFalse,
        reason: '书架卡片必须走共享 MD3 卡片，不得裸构造 Card');
    expect(containsIdentifierCall(source, 'ListTile'), isFalse,
        reason: '书架行不得裸构造 Material ListTile');
    expect(containsIdentifierCall(source, 'SwitchListTile'), isFalse,
        reason: '含 SwitchListTile.adaptive');
    expect(containsIdentifierCall(source, 'CheckboxListTile'), isFalse,
        reason: '含 CheckboxListTile.adaptive');
    expect(containsIdentifierCall(source, 'RadioListTile'), isFalse);
    expect(containsIdentifierCall(source, 'CupertinoListTile'), isFalse);
    expect(source, isNot(contains('BorderRadius.circular(')));
    expect(source, isNot(contains('fontSize:')));
  });
}
