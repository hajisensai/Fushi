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

  test(
      'chrome inset changes re-derive the image max box in both shells (BUG-2468)',
      () {
    // --fushi-image-max-width/height 是 body content-box 的快照；chrome inset 改的正是
    // body padding。initialize() 按初始 inset（底栏/顶栏尚未占位）取的快照若不在这里
    // 重算，首次就绪补发 inset 后整页插图比列高多出一条 chrome 高，Blink 把整块 <img>
    // 切到相邻三列：前一页底部一条、本页主体、后一页顶部一条。
    final String source = File(
      'lib/src/reader/reader_pagination_scripts.dart',
    ).readAsStringSync();
    const String marker = '  setChromeInsets: function(topPx, bottomPx) {';
    final List<int> starts = <int>[];
    int from = 0;
    while (true) {
      final int i = source.indexOf(marker, from);
      if (i < 0) break;
      starts.add(i);
      from = i + marker.length;
    }
    expect(starts, hasLength(2), reason: '分页 + 连续两个 shell 各一份 setChromeInsets');
    for (final int start in starts) {
      final int end = source.indexOf('\n  },\n', start);
      final String function = source.substring(start, end);
      final int bottomInsetWrite = function.indexOf(
        "document.documentElement.style.setProperty('--chrome-bottom-inset', bottomPx + 'px');",
      );
      final int reset = function.indexOf('this._resetImageMaxVars();');
      final int inFlightReturn =
          function.indexOf('if (inFlight || charOffset < 0) return;');
      expect(bottomInsetWrite, greaterThanOrEqualTo(0));
      expect(reset, greaterThan(bottomInsetWrite),
          reason: '图片 max 盒必须在 inset 写入之后按新 content-box 重算');
      expect(inFlightReturn, greaterThan(reset),
          reason: '重锚在飞 / 无锚点早返回也必须先重算图片 max 盒');
    }
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
