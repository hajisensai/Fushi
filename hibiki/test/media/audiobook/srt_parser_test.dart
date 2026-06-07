import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki_audio/hibiki_audio.dart';

void main() {
  group('SrtParser.parseString', () {
    test('正常解析三条字幕', () {
      final List<AudioCue> cues = SrtParser.parseString(
        content: '''
1
00:00:01,000 --> 00:00:04,230
吾輩は猫である。

2
00:00:04,500 --> 00:00:08,100
名前はまだない。

3
00:00:08,200 --> 00:00:12,000
どこで生れたかとんと見当がつかぬ。
''',
        bookKey: 'test/book.srt',
      );

      expect(cues.length, 3);

      expect(cues[0].sentenceIndex, 0);
      expect(cues[0].startMs, 1000);
      expect(cues[0].endMs, 4230);
      expect(cues[0].text, '吾輩は猫である。');
      expect(cues[0].textFragmentId, '[data-cue-id="0"]');
      expect(cues[0].chapterHref, SrtParser.defaultChapter);
      expect(cues[0].bookKey, 'test/book.srt');
      expect(cues[0].audioFileIndex, 0);

      expect(cues[1].sentenceIndex, 1);
      expect(cues[1].startMs, 4500);
      expect(cues[1].endMs, 8100);
      expect(cues[1].text, '名前はまだない。');
      expect(cues[1].textFragmentId, '[data-cue-id="1"]');

      expect(cues[2].sentenceIndex, 2);
      expect(cues[2].startMs, 8200);
      expect(cues[2].endMs, 12000);
    });

    test('多行文本合并为空格连接', () {
      final List<AudioCue> cues = SrtParser.parseString(
        content: '''
1
00:00:01,000 --> 00:00:05,000
これは一行目。
これは二行目。
''',
        bookKey: 'test/book.srt',
      );

      expect(cues.length, 1);
      expect(cues[0].text, 'これは一行目。 これは二行目。');
    });

    test('带 UTF-8 BOM 的内容正常解析', () {
      final List<AudioCue> cues = SrtParser.parseString(
        content: '\uFEFF1\n00:00:01,000 --> 00:00:02,000\nBOM テスト\n',
        bookKey: 'test/book.srt',
      );

      expect(cues.length, 1);
      expect(cues[0].text, 'BOM テスト');
    });

    test('空文本 block 被跳过', () {
      final List<AudioCue> cues = SrtParser.parseString(
        content: '''
1
00:00:01,000 --> 00:00:02,000
正常テキスト

2
00:00:02,000 --> 00:00:03,000

3
00:00:03,500 --> 00:00:04,500
もう一行
''',
        bookKey: 'test/book.srt',
      );

      // block 2 の空テキストはスキップされ sentenceIndex は連続
      expect(cues.length, 2);
      expect(cues[0].text, '正常テキスト');
      expect(cues[0].sentenceIndex, 0);
      expect(cues[1].text, 'もう一行');
      expect(cues[1].sentenceIndex, 1);
    });

    test('chapterHref 自定义值正确写入', () {
      final List<AudioCue> cues = SrtParser.parseString(
        content: '''
1
00:00:00,500 --> 00:00:02,000
カスタム章節
''',
        bookKey: 'test/book.srt',
        chapterHref: 'srt://chapter1',
      );

      expect(cues.length, 1);
      expect(cues[0].chapterHref, 'srt://chapter1');
    });

    test('时间码点号分隔（HH:MM:SS.mmm）也能解析', () {
      final List<AudioCue> cues = SrtParser.parseString(
        content: '''
1
00:00:01.500 --> 00:00:03.750
ドット区切りテスト
''',
        bookKey: 'test/book.srt',
      );

      expect(cues.length, 1);
      expect(cues[0].startMs, 1500);
      expect(cues[0].endMs, 3750);
    });

    test('空文件返回空列表', () {
      final List<AudioCue> cues = SrtParser.parseString(
        content: '',
        bookKey: 'test/book.srt',
      );

      expect(cues, isEmpty);
    });

    test('时间码毫秒补齐（1位→100ms，2位→120ms）', () {
      final List<AudioCue> cues = SrtParser.parseString(
        content: '''
1
00:00:01,1 --> 00:00:02,12
ミリ秒補完テスト
''',
        bookKey: 'test/book.srt',
      );

      expect(cues.length, 1);
      expect(cues[0].startMs, 1100); // 1,1  → 00:00:01.100
      expect(cues[0].endMs, 2120); // 2,12 → 00:00:02.120
    });

    test('strips ASS override tags leaked into SRT (BUG-105)', () {
      const String srt = '1\n'
          '00:00:01,000 --> 00:00:04,000\n'
          r'{\an8}（カンナ）ふわぁ~'
          '\n';
      final List<AudioCue> cues =
          SrtParser.parseString(content: srt, bookKey: 'b');
      expect(cues.single.text, '（カンナ）ふわぁ~');
      expect(cues.single.markup?.anchor?.vertical, SubtitleVAlign.top);
    });
  });
}
