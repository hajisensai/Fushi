import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// TODO-700 T3 源码守卫：WebView 内容就绪时确定性把 Flutter 焦点落到正文 _focusNode，
/// 使首开书第一次按 B/上下句/播放就作用在书内（消解「点两下播放」「首开 B 退书」）。
/// 必须门控：光标态 / 词典弹窗态 / 歌词态都不抢焦点（否则覆盖光标焦点）。整页
/// autofocus 仍保留作冷启动兜底。
void main() {
  String read(String rel) {
    final File f = File(rel);
    expect(f.existsSync(), isTrue, reason: '文件不存在：$rel');
    return f.readAsStringSync();
  }

  test('reader_hibiki_page 定义 _settleFocusOnContentReady 且正确门控', () {
    final String src =
        read('lib/src/pages/implementations/reader_hibiki_page.dart');
    expect(src.contains('void _settleFocusOnContentReady('), isTrue,
        reason: '缺确定性落焦 helper');
    // 门控：光标态 / 弹窗 / 歌词态不抢。
    final int start = src.indexOf('void _settleFocusOnContentReady(');
    final int end = src.indexOf('\n  }', start);
    final String body = src.substring(start, end);
    expect(
        body.contains('_caretActive') || body.contains('_caretSurface'), isTrue,
        reason: 'helper 必须门控光标态');
    expect(body.contains('_lyricsMode'), isTrue, reason: 'helper 必须门控歌词态');
    expect(
        body.contains('isDictionaryShown') || body.contains('_hasVisiblePopup'),
        isTrue,
        reason: 'helper 必须门控弹窗态');
    expect(body.contains('_focusNode.requestFocus()'), isTrue);
    expect(body.contains('_readerContentReady'), isTrue);
  });

  test('内容就绪三落点调用 _settleFocusOnContentReady（不含歌词路径）', () {
    final String nav = read(
        'lib/src/pages/implementations/reader_hibiki/navigation.part.dart');
    final String web =
        read('lib/src/pages/implementations/reader_hibiki/webview.part.dart');
    expect(nav.contains('_settleFocusOnContentReady()'), isTrue,
        reason: 'navigation.part 内容就绪点应落焦');
    expect(web.contains('_settleFocusOnContentReady()'), isTrue,
        reason: 'webview.part spreadReady 应落焦');
  });
}
