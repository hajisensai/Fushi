import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/reader/reader_content_styles.dart';

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

  // TODO-734：竖排列高几何「成对」守卫——CSS column-width 与 JS getScrollContext
  // 的 contentBox 必须同时用「纯视口高 V」（CSS=--reader-viewport-height，
  // JS=viewportHeight）。只钉一半（只 setProperty 或只 contentBox）会让另一半仍含
  // +bottomOverlap → pageStep≠realPitch 复活「翻一半跳章」。两个半边都钉死。
  group('TODO-734: 竖排列高用纯视口高 V（CSS+JS 成对，不得只改一半）', () {
    late String source;
    setUpAll(() {
      source = File(
        'lib/src/reader/reader_pagination_scripts.dart',
      ).readAsStringSync();
    });

    test('CSS 半边：竖排 column-width 引用 --reader-viewport-height', () {
      final String css = File(
        'lib/src/reader/reader_content_styles.dart',
      ).readAsStringSync();
      expect(
        css.contains('var(--reader-viewport-height, 100vh)'),
        isTrue,
        reason: '竖排 column-width 必须建在纯视口高 --reader-viewport-height 上',
      );
      // 竖排列高基准不得再用含 +bottomOverlap 的 --page-height（那是图片虚高专用）。
      // 用 verticalColumnWidthCss 真相源核对：它必产纯视口高基准、绝不产 page-height 基准。
      final String vcw = ReaderContentStyles.verticalColumnWidthCss(
        marginTopVh: 0,
        marginBottomVh: 0,
        fontSizePx: 22,
      );
      expect(
        vcw.contains('var(--reader-viewport-height, 100vh)'),
        isTrue,
        reason: 'verticalColumnWidthCss 必须建在 --reader-viewport-height 上',
      );
      expect(
        vcw.contains('--page-height'),
        isFalse,
        reason: '竖排 column-width 不得引用含 +O 的 --page-height（复活漏字）',
      );
    });

    test('JS 半边：getScrollContext 竖排 contentBox 用 this.viewportHeight', () {
      final String ctx = _functionSource(
        source,
        '  getScrollContext: function() {',
        '\n  getPagePosition:',
      );
      expect(
        ctx.contains('this.viewportHeight'),
        isTrue,
        reason: '竖排 contentBox 基准必须是纯视口高 this.viewportHeight',
      );
      // 不得用含 +O 的 this.pageHeight 当竖排 contentBox 基准。
      expect(
        ctx.contains('(this.pageHeight ||'),
        isFalse,
        reason: '竖排 contentBox 不得回退 this.pageHeight（与 CSS 失配复活跳章）',
      );
    });

    test('注入半边：initialize/updatePageSize setProperty(--reader-viewport-height)',
        () {
      final int count = '--reader-viewport-height'.allMatches(source).length;
      // setProperty 至少出现在 initialize 与 updatePageSize 两处（注释引用不计精确数，
      // 用 setProperty 调用形态确认确实写穿到 DOM）。
      expect(
        source.contains(
            "document.documentElement.style.setProperty('--reader-viewport-height'"),
        isTrue,
        reason: 'V 必须经 setProperty 注入 DOM，CSS 变量才非空（否则回退 100vh 失配）',
      );
      expect(count >= 2, isTrue,
          reason:
              'initialize 与 updatePageSize 两处都要注入 --reader-viewport-height');
    });

    test('viewportHeight 属性两 hoshiReader 实例都声明（防 stale NaN）', () {
      final int decls = 'viewportHeight: 0,'.allMatches(source).length;
      expect(decls >= 2, isTrue,
          reason: '翻页 + 连续两个 hoshiReader 实例都要声明 viewportHeight: 0，'
              '否则首帧读 undefined→NaN→pageStep 退化成 1');
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
