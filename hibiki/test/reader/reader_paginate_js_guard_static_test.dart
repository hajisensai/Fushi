import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// BUG-169 源码守卫：JS `paginate()` 的翻页步长必须从「当前页边界」整页步进
/// （forward = floor(currentScroll/pitch)+1，backward = ceil(currentScroll/pitch)-1），
/// 而不是旧的 `Math.round((currentScroll ± pitch)/pitch)`。后者在 currentScroll 未
/// 对齐到整页时会把当前页算成相邻页，导致一次操作翻 2 页。headless WebView 不可用，
/// 数值正确性由 reader_paginate_step_test.dart 的纯函数影子覆盖，这里只锁 JS 公式不回退。
void main() {
  late String paginate;

  setUpAll(() {
    final String source = File(
      'lib/src/reader/reader_pagination_scripts.dart',
    ).readAsStringSync();
    paginate = _functionSource(
      source,
      '  paginate: function(direction) {',
      '\n  getFirstVisibleCharOffset:',
    );
  });

  test('forward steps to floor(currentScroll/pitch)+1, not round(cur+pitch)',
      () {
    expect(
      paginate,
      contains('Math.floor(currentScroll / pitch) + 1'),
      reason: 'forward 必须用 floor+1 整页步进',
    );
  });

  test('backward steps to ceil(currentScroll/pitch)-1', () {
    expect(
      paginate,
      contains('Math.ceil(currentScroll / pitch) - 1'),
      reason: 'backward 必须用 ceil-1 整页步进',
    );
  });

  test('no longer derives step from Math.round of (currentScroll ± pitch)', () {
    expect(
      paginate.contains('Math.round((currentScroll + context.columnPitch)'),
      isFalse,
      reason: '旧的 round((cur+pitch)/pitch) 会在错位时跳 2 页，必须移除',
    );
    expect(
      paginate.contains('Math.round((currentScroll - context.columnPitch)'),
      isFalse,
      reason: '旧的 round((cur-pitch)/pitch) backward 同样会错位，必须移除',
    );
  });
}

String _functionSource(String source, String start, String end) {
  final int startIndex = source.indexOf(start);
  expect(startIndex, isNonNegative, reason: 'Missing start marker: $start');
  final int endIndex = source.indexOf(end, startIndex + start.length);
  expect(endIndex, isNonNegative, reason: 'Missing end marker: $end');
  return source.substring(startIndex, endIndex);
}
