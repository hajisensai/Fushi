import 'package:flutter_test/flutter_test.dart';

import 'reader_fushi_page_source_corpus.dart';
import 'video_fushi_page_source_corpus.dart';

/// BUG-3417 / 反馈 miuMwosYbx：有声书「歌词模式」里打开高级制卡，「前加一句 /
/// 后加一句」一点就灰掉、句子数不变。
///
/// 根因：阅读器的 `onSetSentenceContextToDraft` 只会去**正文** WebView 跑
/// `getSurroundingSentences`（按 DOM 选区切句），而歌词模式的查词发生在独立的歌词
/// WebView 里，正文没有选区 → 恒返回空 → 控制器判「到边界」禁用按钮。
///
/// 歌词视图一行就是一条 cue；修复让歌词模式取相邻 cue，与视频字幕共用同一个纯函数
/// `cueContextNeighbors`（切法本身由 mining_sentence_draft_test.dart 覆盖）。阅读器页
/// 依赖 WebView + 有声书播放器，无头 widget 测试驱动不了，这里用源码扫描钉死接线。
void main() {
  late String reader;
  late String video;

  setUpAll(() {
    reader = readReaderPageSource();
    video = readVideoFushiSource();
  });

  String region(String src, String startSig, String endSig) {
    final int start = src.indexOf(startSig);
    expect(start, greaterThanOrEqualTo(0), reason: 'missing $startSig');
    final int end = src.indexOf(endSig, start + startSig.length);
    expect(end, greaterThan(start), reason: 'missing $endSig after $startSig');
    return src.substring(start, end);
  }

  test(
    'reader set-context routes lyrics mode before touching the body WebView',
    () {
      final String set = region(
        reader,
        'Future<int> onSetSentenceContextToDraft(int prevCount, int nextCount) async {',
        'surroundingSentencesInvocation(',
      );
      final int lyrics = set.indexOf('if (_lyricsMode) {');
      expect(lyrics, greaterThanOrEqualTo(0));
      expect(
        set.indexOf(
          'return _setLyricsSentenceContextToDraft(prevCount, nextCount);',
        ),
        greaterThan(lyrics),
      );
      // 必须在取正文 controller / 跑 DOM 取句之前分流，否则歌词模式仍走空选区。
      expect(
        lyrics,
        lessThan(set.indexOf('final InAppWebViewController? controller')),
      );
    },
  );

  test(
    'lyrics context takes neighbouring lyric cues via the shared helper',
    () {
      final String full = region(
        reader,
        'int _setLyricsSentenceContextToDraft(int prevCount, int nextCount) {',
        'return _miningDraft.length;',
      );
      expect(full, contains('final AudioCue? anchor = _lookupCue;'));
      expect(full, contains('_lyricsCueList.indexOf(anchor)'));
      expect(full, contains('cueContextNeighbors('));
      expect(full, contains('cues: _lyricsCueList,'));
      // 每句音频区间与当前句 / 写卡同一条求值路径。
      expect(full, contains('_sentenceAudioRangeFor('));
      expect(full, contains('_miningDraft.setContext('));
    },
  );

  test('video subtitle context reuses the same helper (one slicing rule)', () {
    final String set = region(
      video,
      'Future<int> _setSentenceContextToDraft(int prevCount, int nextCount) async {',
      'Future<int> _clearSentenceDraft(',
    );
    expect(set, contains('cueContextNeighbors('));
    // 不再各自手写 clamp 切片。
    expect(set, isNot(contains('.clamp(0, idx)')));
  });
}
