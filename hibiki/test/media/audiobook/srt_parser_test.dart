import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/media/audiobook/audiobook_model.dart';
import 'package:hibiki/src/media/audiobook/srt_parser.dart';

void main() {
  late Directory tmpDir;

  setUp(() {
    tmpDir = Directory.systemTemp.createTempSync('srt_parser_test_');
  });

  tearDown(() {
    tmpDir.deleteSync(recursive: true);
  });

  File writeSrt(String name, String content) {
    final File f = File('${tmpDir.path}/$name');
    f.writeAsStringSync(content, encoding: utf8);
    return f;
  }

  group('SrtParser.parse', () {
    test('正常解析三条字幕', () {
      final File srt = writeSrt('normal.srt', '''
1
00:00:01,000 --> 00:00:04,230
吾輩は猫である。

2
00:00:04,500 --> 00:00:08,100
名前はまだない。

3
00:00:08,200 --> 00:00:12,000
どこで生れたかとんと見当がつかぬ。
''');

      final List<AudioCue> cues = SrtParser.parse(
        srtFile: srt,
        bookUid: 'test/book.srt',
      );

      expect(cues.length, 3);

      expect(cues[0].sentenceIndex, 0);
      expect(cues[0].startMs, 1000);
      expect(cues[0].endMs, 4230);
      expect(cues[0].text, '吾輩は猫である。');
      expect(cues[0].textFragmentId, '[data-cue-id="0"]');
      expect(cues[0].chapterHref, SrtParser.defaultChapter);
      expect(cues[0].bookUid, 'test/book.srt');
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
      final File srt = writeSrt('multiline.srt', '''
1
00:00:01,000 --> 00:00:05,000
これは一行目。
これは二行目。
''');

      final List<AudioCue> cues = SrtParser.parse(
        srtFile: srt,
        bookUid: 'test/book.srt',
      );

      expect(cues.length, 1);
      expect(cues[0].text, 'これは一行目。 これは二行目。');
    });

    test('带 UTF-8 BOM 的文件正常解析', () {
      // 手动写入 BOM + 内容
      final File srt = File('${tmpDir.path}/bom.srt');
      final List<int> bom = [0xEF, 0xBB, 0xBF];
      final List<int> body = utf8.encode(
        '1\n00:00:01,000 --> 00:00:02,000\nBOM テスト\n',
      );
      srt.writeAsBytesSync([...bom, ...body]);

      final List<AudioCue> cues = SrtParser.parse(
        srtFile: srt,
        bookUid: 'test/book.srt',
      );

      expect(cues.length, 1);
      expect(cues[0].text, 'BOM テスト');
    });

    test('空文本 block 被跳过', () {
      final File srt = writeSrt('empty_text.srt', '''
1
00:00:01,000 --> 00:00:02,000
正常テキスト

2
00:00:02,000 --> 00:00:03,000

3
00:00:03,500 --> 00:00:04,500
もう一行
''');

      final List<AudioCue> cues = SrtParser.parse(
        srtFile: srt,
        bookUid: 'test/book.srt',
      );

      // block 2 の空テキストはスキップされ sentenceIndex は連続
      expect(cues.length, 2);
      expect(cues[0].text, '正常テキスト');
      expect(cues[0].sentenceIndex, 0);
      expect(cues[1].text, 'もう一行');
      expect(cues[1].sentenceIndex, 1);
    });

    test('chapterHref 自定义值正确写入', () {
      final File srt = writeSrt('custom_chapter.srt', '''
1
00:00:00,500 --> 00:00:02,000
カスタム章節
''');

      final List<AudioCue> cues = SrtParser.parse(
        srtFile: srt,
        bookUid: 'test/book.srt',
        chapterHref: 'srt://chapter1',
      );

      expect(cues.length, 1);
      expect(cues[0].chapterHref, 'srt://chapter1');
    });

    test('时间码点号分隔（HH:MM:SS.mmm）也能解析', () {
      final File srt = writeSrt('dot_separator.srt', '''
1
00:00:01.500 --> 00:00:03.750
ドット区切りテスト
''');

      final List<AudioCue> cues = SrtParser.parse(
        srtFile: srt,
        bookUid: 'test/book.srt',
      );

      expect(cues.length, 1);
      expect(cues[0].startMs, 1500);
      expect(cues[0].endMs, 3750);
    });

    test('空文件返回空列表', () {
      final File srt = writeSrt('empty.srt', '');

      final List<AudioCue> cues = SrtParser.parse(
        srtFile: srt,
        bookUid: 'test/book.srt',
      );

      expect(cues, isEmpty);
    });

    test('时间码毫秒补齐（1位→100ms，2位→120ms）', () {
      final File srt = writeSrt('ms_padding.srt', '''
1
00:00:01,1 --> 00:00:02,12
ミリ秒補完テスト
''');

      final List<AudioCue> cues = SrtParser.parse(
        srtFile: srt,
        bookUid: 'test/book.srt',
      );

      expect(cues.length, 1);
      expect(cues[0].startMs, 1100);   // 1,1  → 00:00:01.100
      expect(cues[0].endMs, 2120);     // 2,12 → 00:00:02.120
    });
  });
}
