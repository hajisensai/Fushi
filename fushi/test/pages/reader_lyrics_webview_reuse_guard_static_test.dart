import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// BUG-3913 源码守卫：阅读器整页存活期间复用同一个歌词 WebView。
///
/// Windows 上每新建一个 WebView，共享纹理与 WGC 帧池那一份显存在实例销毁后不全数
/// 归还；旧实现每进出一轮歌词模式就卸载 / 新建一次歌词 WebView（实测每轮约 +60 MB）。
/// 修法：退出时按 `_lyricsWebViewKey` 把它停进 [ParkedWebViewSlot]，再进入时搬回覆盖层、
/// 重装文档。搬家本身的「同一个 State、停放不绘制 / 不吃输入」由
/// `test/webview/parked_webview_slot_test.dart` 按真实结构验证；阅读器整页依赖 WebView /
/// DB，pumpWidget 过重，这里沿用本目录 `reader_lyrics_*_static_test` 的源码切片范式钉住
/// 接线。
void main() {
  const String pagePath =
      'lib/src/pages/implementations/reader_fushi_page.dart';
  const String lyricsPath =
      'lib/src/pages/implementations/reader_fushi/lyrics.part.dart';

  String read(String path) =>
      File(path).readAsStringSync().replaceAll('\r\n', '\n');

  /// 从 [signature] 起按花括号配平切出方法体。
  String methodBody(String source, String signature) {
    final int start = source.indexOf(signature);
    expect(start, greaterThanOrEqualTo(0), reason: '锚不到 `$signature`');
    final int open = source.indexOf('{', start);
    int depth = 0;
    for (int i = open; i < source.length; i++) {
      if (source[i] == '{') depth++;
      if (source[i] == '}') {
        depth--;
        if (depth == 0) return source.substring(open, i + 1);
      }
    }
    fail('unbalanced braces in $signature');
  }

  final String page = read(pagePath);
  final String lyrics = read(lyricsPath);
  final String allSources = <String>[
    page,
    for (final FileSystemEntity f in Directory(
      'lib/src/pages/implementations/reader_fushi',
    ).listSync())
      if (f is File && f.path.endsWith('.dart')) read(f.path),
  ].join('\n');

  test('_lyricsController 只在歌词模式里非 null（停放中的实例不算）', () {
    expect(
      page,
      contains(
        'InAppWebViewController? get _lyricsController =>\n'
        '      _lyricsMode ? _lyricsWebViewController : null;',
      ),
      reason: '推 cue / 主题 / caret 的路径都经 _lyricsController，停放期间必须全部短路',
    );
    expect(
      RegExp(r'\b_lyricsController\s*=[^=>]').hasMatch(allSources),
      isFalse,
      reason: '_lyricsController 是派生 getter，实例写到 _lyricsWebViewController',
    );
  });

  test('不在歌词模式时，挂上过的歌词 WebView 停进 ParkedWebViewSlot', () {
    final String overlay = methodBody(lyrics, '  Widget _buildLyricsOverlay()');
    final int notLyrics = overlay.indexOf(
      'if (!_lyricsMode || ctrl == null) {',
    );
    expect(notLyrics, greaterThanOrEqualTo(0));
    final String parkedBranch = methodBody(
      overlay.substring(notLyrics),
      'if (!_lyricsMode || ctrl == null)',
    );
    expect(parkedBranch, contains('if (!_lyricsWebViewRetained)'));
    expect(parkedBranch, contains('ParkedWebViewSlot('));
    expect(
      parkedBranch,
      contains('child: _buildLyricsWebView(),'),
      reason: '停放位与覆盖层必须是同一个 _buildLyricsWebView（同一个 GlobalKey）',
    );
    expect(overlay, contains('lyricsView: _buildLyricsWebView(),'));
    final String webView = methodBody(lyrics, '  Widget _buildLyricsWebView()');
    expect(
      webView,
      contains('key: _lyricsWebViewKey,'),
      reason: 'GlobalKey 是覆盖层 ↔ 停放位搬家的身份，丢了就变成卸载重建',
    );
  });

  test('退出不丢实例；进入时复用实例并重装文档', () {
    final String exit = methodBody(lyrics, '  Future<void> _exitLyricsMode()');
    expect(
      RegExp(r'_lyricsWebViewController\s*=\s*null').hasMatch(exit),
      isFalse,
      reason: '退出时丢掉控制器 = 下次进入只能新建实例',
    );
    final String toggle = methodBody(
      lyrics,
      '  Future<void> _toggleLyricsMode()',
    );
    final int enterAt = toggle.indexOf('_rebuild(() => _lyricsMode = true);');
    expect(enterAt, greaterThanOrEqualTo(0));
    final String afterEnter = toggle.substring(enterAt);
    expect(
      afterEnter,
      contains(
        'if (_lyricsWebViewController != null) unawaited(_loadLyricsPage());',
      ),
      reason: '复用的实例不会再触发 onWebViewCreated，文档要在进入时装',
    );
    final String beforeEnter = toggle.substring(0, enterAt);
    expect(beforeEnter, contains('_lyricsWebViewRetained = true;'));
    expect(
      beforeEnter,
      contains('_lyricsPageReady = false;'),
      reason: '就绪前透明，上一轮的旧文档不许露出来',
    );
    final int exitAt = toggle.indexOf('_rebuild(() => _lyricsMode = false);');
    expect(exitAt, greaterThan(enterAt));
    final int measure = toggle.lastIndexOf(
      '_lyricsWebViewParkedSize =',
      exitAt,
    );
    expect(measure, greaterThan(enterAt), reason: '离开覆盖层之前量尺寸，停放时尺寸不变');
  });

  test('onWebViewCreated 记下实例；停放中创建完成也不装文档', () {
    final String webView = methodBody(lyrics, '  Widget _buildLyricsWebView()');
    expect(webView, contains('_lyricsWebViewController = controller;'));
    expect(
      webView,
      contains('unawaited(_loadLyricsPage());'),
      reason: '_loadLyricsPage 经 _lyricsController（停放时为 null）早返回',
    );
    final String load = methodBody(lyrics, '  Future<void> _loadLyricsPage()');
    expect(
      load,
      contains(
        'final InAppWebViewController? lyricsController = _lyricsController;',
      ),
    );
  });
}
