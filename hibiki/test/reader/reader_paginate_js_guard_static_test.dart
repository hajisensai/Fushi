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

  group('TODO-729: single量纲下 paginate 翻不动即直接 return limit（删 settle 复核）', () {
    test('forward 翻不动时直接 return "limit"，不再走 _stepWithFreshMetrics', () {
      expect(
        paginate
            .contains('if (targetForward <= stepScroll + 1) return "limit"'),
        isTrue,
        reason: 'forward 末页应直接 return "limit"（安卓式），单一量纲下 metrics 与对齐量'
            '同源、永不低估，无需二次 settle 复核',
      );
    });

    test('backward 翻不动时直接 return "limit"', () {
      expect(
        paginate.contains('if (targetBack >= stepScroll - 1) return "limit"'),
        isTrue,
        reason: 'backward 章首应直接 return "limit"',
      );
    });

    test('paginate 不再调用 _stepWithFreshMetrics', () {
      expect(
        paginate.contains('_stepWithFreshMetrics'),
        isFalse,
        reason: '双量纲补救函数已删，paginate 不得再引用它',
      );
    });

    test('源文件已无 _stepWithFreshMetrics 定义', () {
      final String source = File(
        'lib/src/reader/reader_pagination_scripts.dart',
      ).readAsStringSync();
      expect(
        source.contains('_stepWithFreshMetrics: function'),
        isFalse,
        reason: 'TODO-729：单一量纲后 settle 复核函数必须删除，不得复活',
      );
    });

    test('getScrollContext 已收敛单量纲：无 columnPitch、maxScroll 减 pageStep', () {
      final String source = File(
        'lib/src/reader/reader_pagination_scripts.dart',
      ).readAsStringSync();
      final String ctx = _functionSource(
        source,
        '  getScrollContext: function() {',
        '\n  getPagePosition:',
      );
      expect(ctx.contains('columnPitch'), isFalse,
          reason: 'columnPitch 双量纲已废，只保留单一 pageStep');
      expect(ctx.contains('var pageStep = contentBox + gap;'), isTrue,
          reason: 'pageStep = content-box + gap 是唯一步进量纲');
      expect(ctx.contains('totalSize - pageStep'), isTrue,
          reason: 'maxScroll 减项必须是 pageStep（与对齐量同源），不是 clientSize');
      expect(ctx.contains('clientSize'), isFalse, reason: 'clientSize 双量纲减项已删');
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
