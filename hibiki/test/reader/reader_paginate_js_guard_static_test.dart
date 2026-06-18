import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// BUG-169 源码守卫：JS `paginate()` 的翻页步长必须从「当前页边界」整页步进
/// （forward = floor(currentScroll/pitch)+1，backward = ceil(currentScroll/pitch)-1），
/// 而不是旧的 `Math.round((currentScroll ± pitch)/pitch)`。后者在 currentScroll 未
/// 对齐到整页时会把当前页算成相邻页，导致一次操作翻 2 页。headless WebView 不可用，
/// 数值正确性由 reader_paginate_step_test.dart 的纯函数影子覆盖，这里只锁 JS 公式不回退。
void main() {
  late String paginate;
  late String stepWithFreshMetrics;

  setUpAll(() {
    final String source = File(
      'lib/src/reader/reader_pagination_scripts.dart',
    ).readAsStringSync();
    paginate = _functionSource(
      source,
      '  paginate: function(direction) {',
      '\n  getFirstVisibleCharOffset:',
    );
    // BUG-240：跨章 limit 的 settle 复核函数。
    stepWithFreshMetrics = _functionSource(
      source,
      '  _stepWithFreshMetrics: function(context, direction) {',
      '\n  paginate: function(direction) {',
    );
  });

  test('forward steps to floor(stepScroll/pitch)+1, not round(cur+pitch)', () {
    expect(
      paginate,
      contains('Math.floor(stepScroll / pitch) + 1'),
      reason: 'forward 必须用 floor+1 整页步进',
    );
  });

  test('backward steps to ceil(stepScroll/pitch)-1', () {
    expect(
      paginate,
      contains('Math.ceil(stepScroll / pitch) - 1'),
      reason: 'backward 必须用 ceil-1 整页步进',
    );
  });

  test('sub-pixel drift is normalized before stepping', () {
    expect(
      paginate.contains('this.pageStepPosition(currentScroll, pitch)'),
      isTrue,
      reason: '1px 内页边界漂移必须先归一化，避免连续 backward 误判 limit',
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

  group('BUG-240: cross-chapter limit must be settle-rechecked', () {
    test('paginate forward limit defers to _stepWithFreshMetrics', () {
      expect(
        paginate
            .contains('return this._stepWithFreshMetrics(context, "forward")'),
        isTrue,
        reason: 'forward 翻不动时必须先重建 metrics 复核，不能直接返回 limit 跨章',
      );
    });

    test('paginate backward limit defers to _stepWithFreshMetrics', () {
      expect(
        paginate
            .contains('return this._stepWithFreshMetrics(context, "backward")'),
        isTrue,
        reason: 'backward 翻不动时同样必须 settle 复核',
      );
    });

    test('_stepWithFreshMetrics rebuilds metrics fresh', () {
      expect(
        stepWithFreshMetrics.contains('this.buildPaginationMetrics()'),
        isTrue,
        reason: 'limit 复核必须重建 metrics，消除陈旧 max/min/pitch 误判',
      );
    });

    test('_stepWithFreshMetrics rechecks against the live context.maxScroll',
        () {
      expect(
        stepWithFreshMetrics.contains('context.maxScroll'),
        isTrue,
        reason: '末页复核必须锚到 DOM 实时滚动上限（永不陈旧），给测量噪声留容差',
      );
    });
  });
}

String _functionSource(String source, String start, String end) {
  final int startIndex = source.indexOf(start);
  expect(startIndex, isNonNegative, reason: 'Missing start marker: $start');
  final int endIndex = source.indexOf(end, startIndex + start.length);
  expect(endIndex, isNonNegative, reason: 'Missing end marker: $end');
  return source.substring(startIndex, endIndex);
}
