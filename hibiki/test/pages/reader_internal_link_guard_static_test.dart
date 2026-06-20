import 'package:flutter_test/flutter_test.dart';

import 'reader_hibiki_page_source_corpus.dart';

void main() {
  // BUG-117: 书内跳转超链接点击「只加遮罩、不跳转」。根因（设备日志实证）=
  // flutter_inappwebview_windows fork 不触发 shouldOverrideUrlLoading，<a> 点击
  // 在 Windows 上直接原生导航，绕过分页导航 → _currentChapter 不更新 → onLoadStop
  // 把新页判为 stale 丢弃 → 阅读器卡死。根因修=在 JS 层捕获 <a> 点击、preventDefault、
  // 把绝对 href 转发给 Dart 的 onInternalLink，再走既有 resolveInternalLink + 分页
  // 导航（每个平台一致，不依赖平台特定回调）。WebView/JS 真行为真机不可单测，这里用
  // 源码扫描守卫锁住关键接线，防止静默回归。
  final String readerSource = readReaderPageSource();

  test(
      'reader setup script intercepts <a> clicks and forwards to onInternalLink',
      () {
    // 必须有一个 click 监听，命中 <a href> 时 preventDefault 并调 onInternalLink。
    expect(readerSource, contains("addEventListener('click'"),
        reason:
            '必须在 JS 层监听 click 以拦截链接（Windows fork 无 shouldOverrideUrlLoading）');
    expect(readerSource, contains("closest('a[href]')"),
        reason: '只拦截 <a href> 元素上的点击');
    expect(readerSource, contains('e.preventDefault()'),
        reason: '必须 preventDefault 阻止原生导航，改走分页导航');
    expect(readerSource, contains("callHandler('onInternalLink'"),
        reason: '把解析后的绝对 href 转发给 Dart');

    // preventDefault 必须出现在转发之前（先阻止原生导航再交给 Dart）。
    final int clickIdx = readerSource.indexOf("addEventListener('click'");
    final int preventIdx = readerSource.indexOf('e.preventDefault()', clickIdx);
    final int forwardIdx =
        readerSource.indexOf("callHandler('onInternalLink'", clickIdx);
    expect(preventIdx, isNonNegative);
    expect(forwardIdx, isNonNegative);
    expect(preventIdx, lessThan(forwardIdx),
        reason: 'preventDefault 必须在转发 onInternalLink 之前');
  });

  test(
      'onInternalLink handler is registered and routes through shared resolver',
      () {
    expect(readerSource, contains("handlerName: 'onInternalLink'"),
        reason: '必须注册 onInternalLink JS 处理器');

    final String handler = _functionSource(
      readerSource,
      "handlerName: 'onInternalLink'",
      "handlerName: 'onTap'",
    );
    expect(handler, contains('_handleInternalLinkUrl(args[0]'),
        reason: 'onInternalLink 必须调用共享解析方法 _handleInternalLinkUrl');
  });

  test(
      '_handleInternalLinkUrl resolves internal link then jumps / navigates / external',
      () {
    final String fn = _functionSource(
      readerSource,
      '  Future<void> _handleInternalLinkUrl(String url) async {',
      '  Future<void> _navigateToChapterWithFragment(',
    );
    // 同章带 fragment → 原地跳；异章 → 重载并跳；解析不到 → 交外链处理（自家虚拟
    // host 在 _openExternalUrl 内被吞，不弹空白浏览器，见 BUG-097）。
    expect(fn, contains('resolveInternalLink'));
    expect(fn, contains('_jumpToFragmentInPlace'));
    expect(fn, contains('_navigateToChapterWithFragment'));
    expect(fn, contains('_openExternalUrl'));

    final int jumpInPlaceIdx = fn.indexOf('_jumpToFragmentInPlace');
    final int navIdx = fn.indexOf('_navigateToChapterWithFragment');
    final int externalIdx = fn.indexOf('_openExternalUrl');
    expect(jumpInPlaceIdx, isNonNegative);
    expect(navIdx, isNonNegative);
    // 内链分支（跳/导航）必须在外链兜底之前。
    expect(navIdx, lessThan(externalIdx), reason: '内链导航必须先于外链兜底');
  });

  test('shouldOverrideUrlLoading delegates to the same shared resolver', () {
    final String fn = _functionSource(
      readerSource,
      'shouldOverrideUrlLoading: (controller, action) async {',
      'onLoadStop: (controller, url) async {',
    );
    expect(fn, contains('_handleInternalLinkUrl'),
        reason: 'shouldOverrideUrlLoading（移动端 fallback）必须复用同一解析方法，'
            '避免两条路径行为分叉');
  });
}

String _functionSource(String source, String start, String end) {
  final int startIndex = source.indexOf(start);
  expect(startIndex, isNonNegative, reason: 'Missing start marker: $start');
  final int endIndex = source.indexOf(end, startIndex + start.length);
  expect(endIndex, isNonNegative, reason: 'Missing end marker: $end');
  return source.substring(startIndex, endIndex);
}
