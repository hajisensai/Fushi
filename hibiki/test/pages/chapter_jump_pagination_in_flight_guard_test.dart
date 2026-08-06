import 'package:flutter_test/flutter_test.dart';

import 'reader_hibiki_page_source_corpus.dart';

/// BUG-568 / TODO-1229 案A 源码守卫：章界连续输入穿透。
///
/// 滚轮惯性节流(450ms) 远短于换章加载(数百 ms restore)，跨章那一下之后排队的翻页
/// tick 会在新章 restore 未落定时立即再翻——章首插图页/首页整页被越过；更糟
/// fushiReader 未就绪时 evaluateJavascript 返 null → _didScroll(null)=false →
/// 又 _handlePageTurnLimit → 跳两章。两条翻页输入入口（keyboard/gamepad/volume/
/// onSwipe/onWheelPaginate 汇合的 _paginate；跨章手势绕过 _paginate 直接调
/// _handlePageTurnLimit 的 onBoundarySwipe）都必须在导航/恢复在飞窗口丢弃输入，
/// 统一走 _paginationInFlight（_restoreInFlight || !_readerContentReady ||
/// _isNavigatingToChapter）。
void main() {
  late String source;

  setUpAll(() {
    source = readReaderPageSource();
  });

  test('_paginationInFlight 由三态瞬态窗口构成', () {
    final String getter = _slice(
      source,
      'bool get _paginationInFlight =>',
      ';',
    );
    expect(getter, contains('_restoreInFlight'));
    expect(getter, contains('!_readerContentReady'));
    expect(getter, contains('_isNavigatingToChapter'));
  });

  test('_paginate 在调用 paginator 之前用 _paginationInFlight 丢弃在飞输入', () {
    final String paginate = _slice(
      source,
      '  Future<void> _paginate(',
      '  // ── Image Viewer',
    );
    final int guardIndex = paginate.indexOf('if (_paginationInFlight)');
    final int paginateCallIndex = paginate.indexOf('paginateInvocation');
    expect(guardIndex, isNonNegative,
        reason: '_paginate 必须含 _paginationInFlight 守卫');
    expect(paginateCallIndex, isNonNegative);
    expect(
      guardIndex,
      lessThan(paginateCallIndex),
      reason: '守卫必须先于 paginator 调用',
    );
  });

  test('_paginationInFlight 守卫放在节流戳之前（被丢弃输入不推进 _lastPaginateTime）', () {
    final String paginate = _slice(
      source,
      '  Future<void> _paginate(',
      '  // ── Image Viewer',
    );
    final int guardIndex = paginate.indexOf('if (_paginationInFlight)');
    final int throttleStampIndex =
        paginate.indexOf('_lastPaginateTime = DateTime.now()');
    expect(throttleStampIndex, isNonNegative);
    expect(
      guardIndex,
      lessThan(throttleStampIndex),
      reason: '守卫必须先于节流戳更新，否则被丢弃输入会误吞恢复后首个真实输入',
    );
  });

  test('onBoundarySwipe（跨章手势绕行路径）在调 _handlePageTurnLimit 之前也守卫', () {
    final String handler = _slice(
      source,
      "handlerName: 'onBoundarySwipe'",
      "handlerName: 'onImageDetected'",
    );
    final int guardIndex = handler.indexOf('if (_paginationInFlight)');
    // 匹配真实调用 _handlePageTurnLimit('forward') 而非注释里的字样提及。
    final int limitCallIndex = handler.indexOf("_handlePageTurnLimit('");
    expect(guardIndex, isNonNegative,
        reason: 'onBoundarySwipe 绕过 _paginate 入口，必须单独收口 _paginationInFlight');
    expect(limitCallIndex, isNonNegative);
    expect(
      guardIndex,
      lessThan(limitCallIndex),
      reason: '守卫必须先于 _handlePageTurnLimit 跨章调用',
    );
  });
}

String _slice(String source, String start, String end) {
  final int startIndex = source.indexOf(start);
  expect(startIndex, isNonNegative, reason: 'Missing start marker: $start');
  final int endIndex = source.indexOf(end, startIndex + start.length);
  expect(endIndex, isNonNegative, reason: 'Missing end marker: $end');
  return source.substring(startIndex, endIndex);
}
