import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// BUG-210 / TODO-146 守卫（源码扫描，沿用 reader_init_page_width_guard_static_test.dart
/// 范式）。
///
/// 锁死修复不变式（任一退回 → 红）：
/// 1. `_syncPageSize` 函数体不得再用**零容差精确浮点不等** `w != _lastSyncedWidth`
///    —— 这正是 Windows sub-pixel 宽抖动误触发整章重载、把翻页弹回章节开头的根因。
///    （纯函数 readerViewportNeedsRepaginate 的 docstring 引用旧写法说明根因，合理，
///    故守卫只扫 _syncPageSize 函数体，不扫整文件。）
/// 2. `_syncPageSize` 必须经 `readerViewportNeedsRepaginate`（宽、高共用 1px 容差）
///    判定宽/高变化。
/// 3. readerViewportNeedsRepaginate 宽、高用同一 1px 容差表达式（对称，消除特例）。
void main() {
  final String src = File(
    'lib/src/pages/implementations/reader_hibiki_page.dart',
  ).readAsStringSync();

  String syncPageSizeBody() {
    final int fnStart = src.indexOf('Future<void> _syncPageSize()');
    expect(fnStart, isNonNegative, reason: '找不到 _syncPageSize');
    final int fnEnd = src.indexOf('  @override', fnStart);
    return src.substring(fnStart, fnEnd > fnStart ? fnEnd : src.length);
  }

  test('_syncPageSize body no longer uses zero-tolerance exact inequality', () {
    expect(
      syncPageSizeBody().contains('w != _lastSyncedWidth'),
      isFalse,
      reason: '_syncPageSize 不得用零容差精确不等 `w != _lastSyncedWidth` 判宽变 —— '
          'Windows sub-pixel 宽抖动会误触发整章重载，把翻页弹回章节开头（BUG-210）。',
    );
  });

  test('_syncPageSize routes width/height change through the tolerant helper',
      () {
    expect(
      syncPageSizeBody().contains('readerViewportNeedsRepaginate('),
      isTrue,
      reason: '_syncPageSize 必须用 readerViewportNeedsRepaginate（宽高共用 1px 容差）'
          '判定视口变化。',
    );
  });

  test('the tolerant helper applies the same tolerance to width and height',
      () {
    // 宽、高都必须用 abs() >= tolerancePx，杜绝任一维度退回精确不等。
    // 直接全文匹配（两个表达式在文件里唯一），不再脆弱地按括号切片函数体。
    expect(
      RegExp(r'\(width - lastWidth\)\.abs\(\) >= tolerancePx').hasMatch(src),
      isTrue,
      reason: '宽度必须用 1px 容差。',
    );
    expect(
      RegExp(r'\(height - lastHeight\)\.abs\(\) >= tolerancePx').hasMatch(src),
      isTrue,
      reason: '高度必须用同一 1px 容差（对称，消除特例）。',
    );
  });
}
