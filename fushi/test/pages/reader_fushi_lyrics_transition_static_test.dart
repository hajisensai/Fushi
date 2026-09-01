import 'package:flutter_test/flutter_test.dart';
import 'reader_fushi_page_source_corpus.dart';

void main() {
  test('lyrics mode transition does not draw a full-screen scrim', () {
    final String source = readReaderPageSource();
    final String buildSource = _functionSource(
      source,
      '  Widget build(BuildContext context)',
      '  Widget _buildBody()',
    );
    final String contentReadyOverlay = _sectionSource(
      buildSource,
      '                if (!_readerContentReady ||',
      '                if (_readerContentReady)',
    );
    final String toggleSource = _functionSource(
      source,
      '  Future<void> _toggleLyricsMode() async',
      '  Future<void> _loadLyricsPage() async',
    );

    expect(contentReadyOverlay, isNot(contains('AnimatedOpacity(')));
    expect(contentReadyOverlay, isNot(contains('_lyricsModeTransition')));
    expect(toggleSource, isNot(contains('Duration(milliseconds: 200)')));

    // BUG-2015：content-ready 遮罩的实现被挪进了 _buildChapterTransitionOverlay()，
    // 跨章淡出（AnimatedOpacity）住在那个 helper 里。守卫必须跟进去，否则上面三条
    // 从此对「这层遮罩会不会淡出」永久失明（窗口里只剩一个方法调用）。
    //
    // 允许的形状只有一种：无跨章快照时**先**返回纯背景色，淡出只出现在这个早退之后。
    // 歌词模式切换 / 换字号重排走的正是「无快照」分支，因此仍是瞬时纯色遮罩、
    // 不会出现整屏淡入淡出。
    final String transitionOverlay = _functionSource(
      source,
      '  Widget _buildChapterTransitionOverlay(Color backgroundColor)',
      '  String _buildStyleTag()',
    );
    final int plainBackgroundEarlyReturn = transitionOverlay
        .indexOf('if (snapshot == null) return ColoredBox(');
    expect(plainBackgroundEarlyReturn, isNonNegative,
        reason: '无跨章快照时必须直接返回纯背景色，歌词模式/重排版切换不得淡出');
    final int fadeIndex = transitionOverlay.indexOf('AnimatedOpacity(');
    expect(fadeIndex, greaterThan(plainBackgroundEarlyReturn),
        reason: '淡出只能出现在「有跨章快照」的早退之后');
  });
}

String _functionSource(String source, String start, String end) {
  final int startIndex = source.indexOf(start);
  expect(startIndex, isNonNegative, reason: 'Missing start marker: $start');
  final int endIndex = source.indexOf(end, startIndex + start.length);
  expect(endIndex, isNonNegative, reason: 'Missing end marker: $end');
  return source.substring(startIndex, endIndex);
}

String _sectionSource(String source, String start, String end) {
  final int startIndex = source.indexOf(start);
  expect(startIndex, isNonNegative, reason: 'Missing start marker: $start');
  final int endIndex = source.indexOf(end, startIndex + start.length);
  expect(endIndex, isNonNegative, reason: 'Missing end marker: $end');
  return source.substring(startIndex, endIndex);
}
