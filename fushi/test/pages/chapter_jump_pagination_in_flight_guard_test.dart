import 'package:flutter_test/flutter_test.dart';

import 'reader_fushi_page_source_corpus.dart';

/// BUG-568 / TODO-1229 案A 源码守卫：章界连续输入穿透。
///
/// 滚轮惯性节流(450ms) 远短于换章加载(数百 ms restore)，跨章那一下之后排队的翻页
/// tick 会在新章 restore 未落定时立即再翻——章首插图页/首页整页被越过；更糟
/// fushiReader 未就绪时 evaluateJavascript 返 null → _didScroll(null)=false →
/// 又 _handlePageTurnLimit → 跳两章。两条翻页输入入口（keyboard/gamepad/volume/
/// onSwipe/onWheelPaginate 汇合的 _paginate；跨章手势绕过 _paginate 直接调
/// _handlePageTurnLimit 的 onBoundarySwipe）都必须在导航/恢复在飞窗口拦下输入，
/// 统一走 _paginationInFlight（_restoreInFlight || !_readerContentReady ||
/// _isNavigatingToChapter）。
///
/// BUG-2424：拦下来的输入现在是**入队等重放**，不再是丢弃（丢弃就是用户报的
/// 「按了没反应」）。守卫本身的必要性没变（在飞时 fushiReader 未就绪，就地执行
/// 会因 evaluateJavascript 返 null 被 _didScroll 误读成页边界而跳两章），变的只是
/// 被拦下之后的去向，以及它与节流戳的先后顺序（见下面那条）。
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

  test('BUG-2424：节流戳放在 _paginationInFlight 守卫之前（这条顺序已反转）', () {
    // 这条以前是**反的**：守卫先于节流戳，理由是「被丢弃的输入不该推进
    // _lastPaginateTime，否则误吞恢复后首个真实输入」。那个理由成立的前提是
    // 「在飞输入被**丢弃**」——BUG-2424 把它换成了**排队**，前提没了：
    // 没有输入再被丢弃，所以也不存在「被丢弃的输入不该占配额」这回事。
    //
    // 新语义：`wheelPageTurnInterval` 是用户在设置里配的限速器，**统一管章内翻页
    // 与跨章、两种模式一视同仁**。过了节流 = 这一次输入被接受、占掉一个翻页
    // 配额，所以即使它接着要入队等重放也必须先 stamp。反过来的话，换章加载期
    // 到达的每一个 tick 都会绕过限速直接入队，落定后一次性连翻。
    //
    // 同源守卫（两处入口的完整三段顺序）在
    // `chapter_turn_queue_test.dart` 的「两处闸门顺序一致」。
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
      throttleStampIndex,
      lessThan(guardIndex),
      reason: '节流戳必须先于在飞守卫：输入已经过了限速、被接受，'
          '接下来是就地执行还是入队等重放都不改变它已占掉一个翻页配额',
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
