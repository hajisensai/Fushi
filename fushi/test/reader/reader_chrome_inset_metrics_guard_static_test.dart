import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('paginated chrome inset changes invalidate cached pagination metrics',
      () {
    final String source = File(
      'lib/src/reader/reader_pagination_scripts.dart',
    ).readAsStringSync();
    final int start = source.indexOf(
      '  setChromeInsets: function(topPx, bottomPx) {',
    );
    final int end = source.indexOf('\n  }\n};', start);
    expect(start, greaterThanOrEqualTo(0));
    expect(end, greaterThan(start));
    final String function = source.substring(start, end);

    final int bottomInsetWrite = function.indexOf(
      "document.documentElement.style.setProperty('--chrome-bottom-inset', bottomPx + 'px');",
    );
    final int invalidate = function.indexOf('this.paginationMetrics = null;');
    final int inFlightReturn =
        function.indexOf('if (inFlight || charOffset < 0) return;');

    expect(bottomInsetWrite, greaterThanOrEqualTo(0));
    expect(invalidate, greaterThan(bottomInsetWrite),
        reason: 'metrics must be invalidated after the CSS geometry changes');
    expect(inFlightReturn, greaterThan(invalidate),
        reason: 'rapid/in-flight inset changes must not retain stale metrics');
  });

  test('partial terminal page uses the browser physical endpoint exactly once',
      () {
    final String source = File(
      'lib/src/reader/reader_pagination_scripts.dart',
    ).readAsStringSync();
    final String context = _functionSource(
      source,
      '  getScrollContext: function() {',
      '\n  getPagePosition:',
    );
    final String metrics = _functionSource(
      source,
      '  buildPaginationMetrics: function() {',
      '\n  calculateProgress:',
    );
    final String paginate = _functionSource(
      source,
      '  paginate: function(direction) {',
      '\n  getFirstVisibleCharOffset:',
    );
    final String pageInfo = _functionSource(
      source,
      '  pageInfo: function() {',
      '\n  restoreProgress:',
    );

    expect(
      context,
      contains(
        'var physicalMaxScroll = Math.max(0, totalSize - viewportExtent);',
      ),
      reason: 'terminal clamp 必须来自浏览器真实 scroll extent',
    );
    expect(
      source,
      contains(
        'var clamped = Math.min(Math.max(0, position), context.physicalMaxScroll);',
      ),
      reason: '程序化滚动不得请求物理不可达的位置',
    );
    expect(
      metrics,
      contains(
        'maxScroll = Math.min(lastContentScroll, context.physicalMaxScroll);',
      ),
      reason: '内容越过最后整页网格时只补一张物理章尾页',
    );
    expect(
      paginate,
      contains('if (targetForward > maxAlignedScroll) '
          'targetForward = maxAlignedScroll;'),
      reason: 'forward 必须直接 clamp 到 metrics 终点，下一次调用才能稳定返回 limit',
    );
    expect(
      pageInfo,
      allOf(
        contains(
          'var alignedTurns = Math.floor((span + 1) / context.pageSize);',
        ),
        contains(
          'var hasPartialTerminal = metrics.maxScroll - alignedEnd > 1;',
        ),
        contains(
          'var totalPages = alignedTurns + 1 + '
          '(hasPartialTerminal ? 1 : 0);',
        ),
      ),
      reason: '不足半页的物理终点也必须计作独立末页',
    );
  });
}

String _functionSource(String source, String startMarker, String endMarker) {
  final int start = source.indexOf(startMarker);
  final int end = source.indexOf(endMarker, start + startMarker.length);
  expect(start, greaterThanOrEqualTo(0), reason: 'Missing $startMarker');
  expect(end, greaterThan(start), reason: 'Missing $endMarker');
  return source.substring(start, end);
}
