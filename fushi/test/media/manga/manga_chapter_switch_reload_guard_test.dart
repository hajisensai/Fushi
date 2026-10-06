import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// BUG-2884：换章时 WebView 一直挂在树上（onWebViewCreated 不会再来），
/// 只有 [_presentPayload] 能把新章正文装进去；它漏掉重装，屏上就停在旧章文档，
/// 只有页码跟着变。真 WebView 行为由
/// `integration_test/manga_cross_chapter_itest.dart` 覆盖，这里钉住接线。
void main() {
  final String source = File(
    'lib/src/media/manga/reader/manga_fushi_page.dart',
  ).readAsStringSync();

  String body(String signature, String nextSignature) {
    final int start = source.indexOf(signature);
    expect(start, greaterThanOrEqualTo(0), reason: signature);
    final int end = source.indexOf(nextSignature, start);
    expect(end, greaterThan(start), reason: nextSignature);
    return source.substring(start, end);
  }

  test(
    'presenting a payload on a live WebView reloads the window document',
    () {
      final String present = body(
        'Future<void> _presentPayload({',
        'Future<void> _loadOnlineBookFromShelf(',
      );
      final int installed = present.indexOf('_payload = payload;');
      final int reload = present.indexOf(
        'if (_controller != null) await _loadInitialWindow();',
      );
      final int streamingReturn = present.indexOf('if (streaming) {');
      expect(installed, greaterThanOrEqualTo(0));
      expect(reload, greaterThan(installed));
      // 直读章提前 return 之前就要重装，否则在线直读换章照样停在旧文档。
      expect(streamingReturn, greaterThan(reload));
    },
  );

  test(
    'a reload requested while a window load is in flight is not dropped',
    () {
      final String load = body(
        'Future<void> _loadInitialWindow() async {',
        '// ── 翻页导航',
      );
      expect(load, isNot(contains('|| _navigating) return;')));
      expect(load, contains('while (_navigating) {'));
      expect(load, contains('await inFlight.future;'));
      expect(load, contains('done.complete();'));
    },
  );

  test('every state that unmounts the WebView releases its controller first', () {
    // 「本章未下载」/ 加载失败分支把 WebView 移出树；controller 不交还，之后
    // 换回正文时 _presentPayload 会拿已销毁的 controller 去 loadData。
    final RegExp unmount = RegExp(
      r'_loadFailed = true|_chapterNotDownloaded = true',
    );
    final List<RegExpMatch> sites = unmount.allMatches(source).toList();
    expect(sites, isNotEmpty);
    for (final RegExpMatch site in sites) {
      final int setStateAt = source.lastIndexOf('setState(', site.start);
      final String before = source.substring(
        source.lastIndexOf('\n', source.lastIndexOf('\n', setStateAt) - 1),
        setStateAt,
      );
      expect(
        before,
        contains('_releaseWebView();'),
        reason:
            'line ${'\n'.allMatches(source.substring(0, site.start)).length + 1}',
      );
    }
  });

  test(
    'the turn drain after a window load drops steps during a chapter switch',
    () {
      final String load = body(
        'Future<void> _loadInitialWindow() async {',
        '// ── 翻页导航',
      );
      expect(
        load,
        contains(
          'canApply: () => mounted && !_navigating && !_switchingChapter',
        ),
      );
    },
  );

  test('page image URLs carry the page session generation', () {
    final String build = body(
      'String _buildWindowDocument(',
      'Color get _backgroundColor',
    );
    expect(build, contains('version: _pageSessionGeneration,'));
    expect(
      '_pageSessionGeneration++;'.allMatches(source).length,
      1,
      reason: 'bumped exactly where a new page session is installed',
    );
  });
}
