import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki_audio/hibiki_audio.dart';

void main() {
  const String header = '''
[Script Info]
Title: Test

[V4+ Styles]
Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding
Style: Default,Arial,20,&H00FFFFFF,&H000000FF,&H00000000,&H00000000,0,0,0,0,100,100,0,0,1,2,2,2,10,10,10,1

[Events]
Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
''';

  group('AssParser.parseString', () {
    test('正常解析三条字幕', () {
      final List<AudioCue> cues = AssParser.parseString(
        content: '''
${header}Dialogue: 0,0:00:01.00,0:00:04.23,Default,,0,0,0,,吾輩は猫である。
Dialogue: 0,0:00:04.50,0:00:08.10,Default,,0,0,0,,名前はまだない。
Dialogue: 0,0:00:08.20,0:00:12.00,Default,,0,0,0,,どこで生れたかとんと見当がつかぬ。
''',
        bookKey: 'test/book.ass',
      );

      expect(cues.length, 3);
      expect(cues[0].startMs, 1000);
      expect(cues[0].endMs, 4230);
      expect(cues[0].text, '吾輩は猫である。');
      expect(cues[0].textFragmentId, '[data-cue-id="0"]');
      expect(cues[0].chapterHref, AssParser.defaultChapter);
      expect(cues[1].startMs, 4500);
      expect(cues[2].endMs, 12000);
    });

    test('ASS 覆盖标签被剥离', () {
      final List<AudioCue> cues = AssParser.parseString(
        content: '''
${header}Dialogue: 0,0:00:01.00,0:00:03.00,Default,,0,0,0,,{\\an8}{\\b1}強調テキスト{\\b0}
''',
        bookKey: 'test/book.ass',
      );

      expect(cues.length, 1);
      expect(cues[0].text, '強調テキスト');
    });

    test('软换行符 \\N 转为空格', () {
      final List<AudioCue> cues = AssParser.parseString(
        content: '''
${header}Dialogue: 0,0:00:01.00,0:00:03.00,Default,,0,0,0,,一行目\\N二行目
''',
        bookKey: 'test/book.ass',
      );

      expect(cues.length, 1);
      expect(cues[0].text, '一行目 二行目');
    });

    test('Text 列中含逗号的内容正确拼合', () {
      final List<AudioCue> cues = AssParser.parseString(
        content: '''
${header}Dialogue: 0,0:00:01.00,0:00:03.00,Default,,0,0,0,,はい、そうです。
''',
        bookKey: 'test/book.ass',
      );

      expect(cues.length, 1);
      expect(cues[0].text, 'はい、そうです。');
    });

    test('按 startMs 排序（Dialogue 顺序不影响结果）', () {
      final List<AudioCue> cues = AssParser.parseString(
        content: '''
${header}Dialogue: 0,0:00:05.00,0:00:07.00,Default,,0,0,0,,後の行
Dialogue: 0,0:00:01.00,0:00:03.00,Default,,0,0,0,,前の行
''',
        bookKey: 'test/book.ass',
      );

      expect(cues.length, 2);
      expect(cues[0].text, '前の行');
      expect(cues[1].text, '後の行');
    });

    test('时间码厘秒精度正确（.67 → 670ms）', () {
      final List<AudioCue> cues = AssParser.parseString(
        content: '''
${header}Dialogue: 0,0:00:01.67,0:00:03.00,Default,,0,0,0,,厘秒テスト
''',
        bookKey: 'test/book.ass',
      );

      expect(cues.length, 1);
      expect(cues[0].startMs, 1000 + 670);
    });

    test('时间码 3 位毫秒精度正确（.000 → 0ms，外挂 .ass，TODO-870）', () {
      // SRT→ASS 转换工具常产出 3 位毫秒时间码（0:00:01.000）；旧正则只认
      // 2 位厘秒 → startMs=null → cue 被跳过 → 0 cue → 上层误报「不支持」。
      final List<AudioCue> cues = AssParser.parseString(
        content: '''
${header}Dialogue: 0,0:00:01.000,0:00:04.500,Default,,0,0,0,,毫秒テスト
''',
        bookKey: 'test/book.ass',
      );

      expect(cues.length, 1);
      expect(cues[0].startMs, 1000);
      expect(cues[0].endMs, 4500);
    });

    test('时间码 1 位十分之一秒精度正确（.1 → 100ms，TODO-870）', () {
      final List<AudioCue> cues = AssParser.parseString(
        content: '''
${header}Dialogue: 0,0:00:01.1,0:00:03.0,Default,,0,0,0,,十分の一秒テスト
''',
        bookKey: 'test/book.ass',
      );

      expect(cues.length, 1);
      expect(cues[0].startMs, 1000 + 100);
    });

    test('带 UTF-8 BOM 的内容正常解析', () {
      final List<AudioCue> cues = AssParser.parseString(
        content:
            '\uFEFF${header}Dialogue: 0,0:00:01.00,0:00:02.00,Default,,0,0,0,,BOM テスト\n',
        bookKey: 'test/book.ass',
      );

      expect(cues.length, 1);
      expect(cues[0].text, 'BOM テスト');
    });

    test('空文件（无 Events 段）返回空列表', () {
      final List<AudioCue> cues = AssParser.parseString(
        content: '[Script Info]\nTitle: Empty\n',
        bookKey: 'test/book.ass',
      );

      expect(cues, isEmpty);
    });

    test('defaultChapter 与 SrtParser 共用同一值', () {
      expect(AssParser.defaultChapter, SrtParser.defaultChapter);
    });

    test('reads PlayRes and normalizes \\pos; fills markup (BUG-105)', () {
      const String ass = '[Script Info]\n'
          'PlayResX: 1920\n'
          'PlayResY: 1080\n'
          '\n'
          '[Events]\n'
          'Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text\n'
          r'Dialogue: 0,0:00:01.00,0:00:04.00,Default,,0,0,0,,{\pos(960,540)}やあ'
          '\n';
      final List<AudioCue> cues =
          AssParser.parseString(content: ass, bookKey: 'b');
      expect(cues.single.text, 'やあ');
      expect(cues.single.markup?.posFraction?.xFraction, closeTo(0.5, 1e-9));
      expect(cues.single.markup?.posFraction?.yFraction, closeTo(0.5, 1e-9));
    });

    test('strips {\\an8} override into plain text + anchor (BUG-105)', () {
      const String ass = '[Events]\n'
          'Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text\n'
          r'Dialogue: 0,0:00:01.00,0:00:04.00,Default,,0,0,0,,{\an8}（カンナ）ふわぁ~'
          '\n';
      final List<AudioCue> cues =
          AssParser.parseString(content: ass, bookKey: 'b');
      expect(cues.single.text, '（カンナ）ふわぁ~');
      expect(cues.single.markup?.anchor?.vertical, SubtitleVAlign.top);
      expect(cues.single.markup?.anchor?.horizontal, SubtitleHAlign.center);
    });
  });
}
