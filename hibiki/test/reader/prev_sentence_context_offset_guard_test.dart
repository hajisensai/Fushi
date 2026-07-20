import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// BUG-934 源码守卫：制卡「前加一句」走 JS `getSurroundingSentences` 往前逐句采集，
/// 必须以 `before.offset`（当前句首前一个字符，即前一句末尾分隔符）直接取前一句。
///
/// 历史缺陷：取句时给该偏移多加了 1，把起点推回当前句首，`getSentenceContext` 立刻撞
/// 分隔符 → 往后取回当前句自身，导致「前加一句」把当前句重复采集两遍。此守卫锁定正确
/// 调用形，并反向禁止把偏移 `+ 1` 的回归。JS 逻辑内嵌在 Dart 字符串、无 JS 测试运行时，
/// 源码扫描是最强可落地层。
void main() {
  final String src =
      File('lib/src/reader/reader_selection_scripts.dart').readAsStringSync();

  test('前加一句：往前取句用 before.offset 直接落在前一句上', () {
    expect(
      src.contains('getSentenceContext(before.node, before.offset)'),
      isTrue,
      reason: '往前取句必须用 before.offset（前一句末尾分隔符），否则会取回当前句自身',
    );
  });

  test('前加一句：偏移不得再 +1（否则起点被推回当前句首 → 重复采句）', () {
    // 拼接构造禁用字面量，避免本注释/断言字符串误伤同文件被扫描的其它守卫。
    const String forbidden = 'before.offset' ' + 1';
    expect(
      src.contains(forbidden),
      isFalse,
      reason: 'before.offset + 1 会把取句起点推回当前句首，BUG-934 复现',
    );
  });

  test('后加一句仍用 after.offset（对称正确调用未被破坏）', () {
    expect(
      src.contains('getSentenceContext(after.node, after.offset)'),
      isTrue,
    );
  });
}
