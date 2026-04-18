import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/media/audiobook/audiobook_model.dart';
import 'package:hibiki/src/media/audiobook/srt_parser.dart';
import 'package:hibiki/src/media/audiobook/vtt_parser.dart';

void main() {
  group('VttParser.parseString', () {
    test('正常解析三条字幕', () {
      final List<AudioCue> cues = VttParser.parseString(
        content: '''
WEBVTT

1
00:00:01.000 --> 00:00:04.230
吾輩は猫である。

2
00:00:04.500 --> 00:00:08.100
名前はまだない。

3
00:00:08.200 --> 00:00:12.000
どこで生れたかとんと見当がつかぬ。
''',
        bookUid: 'test/book.vtt',
      );

      expect(cues.length, 3);
      expect(cues[0].startMs, 1000);
      expect(cues[0].endMs, 4230);
      expect(cues[0].text, '吾輩は猫である。');
      expect(cues[0].textFragmentId, '[data-cue-id="0"]');
      expect(cues[0].chapterHref, VttParser.defaultChapter);
      expect(cues[1].startMs, 4500);
      expect(cues[2].endMs, 12000);
    });

    test('无小时时间码（MM:SS.mmm）正常解析', () {
      final List<AudioCue> cues = VttParser.parseString(
        content: '''
WEBVTT

01:30.500 --> 02:15.000
短尺度タイムコード
''',
        bookUid: 'test/book.vtt',
      );

      expect(cues.length, 1);
      expect(cues[0].startMs, 90500);  // 1m30.5s
      expect(cues[0].endMs, 135000);   // 2m15s
    });

    test('时间行后位置指令被忽略', () {
      final List<AudioCue> cues = VttParser.parseString(
        content: '''
WEBVTT

00:00:01.000 --> 00:00:04.000 align:left position:20%
位置指令テスト
''',
        bookUid: 'test/book.vtt',
      );

      expect(cues.length, 1);
      expect(cues[0].startMs, 1000);
      expect(cues[0].endMs, 4000);
    });

    test('NOTE、STYLE 块被跳过', () {
      final List<AudioCue> cues = VttParser.parseString(
        content: '''
WEBVTT

NOTE これはコメント

STYLE
::cue { color: white; }

00:00:01.000 --> 00:00:03.000
本文
''',
        bookUid: 'test/book.vtt',
      );

      expect(cues.length, 1);
      expect(cues[0].text, '本文');
    });

    test('VTT 行内标签被剥离', () {
      final List<AudioCue> cues = VttParser.parseString(
        content: '''
WEBVTT

00:00:01.000 --> 00:00:03.000
<b>太字</b>と<i>斜体</i>と<c.color>カラー</c.color>
''',
        bookUid: 'test/book.vtt',
      );

      expect(cues.length, 1);
      expect(cues[0].text, '太字と斜体とカラー');
    });

    test('带 UTF-8 BOM 的内容正常解析', () {
      final List<AudioCue> cues = VttParser.parseString(
        content:
            '\uFEFFWEBVTT\n\n00:00:01.000 --> 00:00:02.000\nBOM テスト\n',
        bookUid: 'test/book.vtt',
      );

      expect(cues.length, 1);
      expect(cues[0].text, 'BOM テスト');
    });

    test('空文件返回空列表', () {
      final List<AudioCue> cues = VttParser.parseString(
        content: 'WEBVTT\n',
        bookUid: 'test/book.vtt',
      );

      expect(cues, isEmpty);
    });

    test('defaultChapter 与 SrtParser 共用同一值', () {
      expect(VttParser.defaultChapter, SrtParser.defaultChapter);
    });
  });
}
