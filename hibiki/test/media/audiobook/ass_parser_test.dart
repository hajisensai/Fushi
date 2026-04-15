import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/media/audiobook/ass_parser.dart';
import 'package:hibiki/src/media/audiobook/audiobook_model.dart';
import 'package:hibiki/src/media/audiobook/srt_parser.dart';

void main() {
  late Directory tmpDir;

  setUp(() {
    tmpDir = Directory.systemTemp.createTempSync('ass_parser_test_');
  });

  tearDown(() {
    tmpDir.deleteSync(recursive: true);
  });

  File writeAss(String name, String content) {
    final File f = File('${tmpDir.path}/$name');
    f.writeAsStringSync(content);
    return f;
  }

  const String header = '''
[Script Info]
Title: Test

[V4+ Styles]
Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding
Style: Default,Arial,20,&H00FFFFFF,&H000000FF,&H00000000,&H00000000,0,0,0,0,100,100,0,0,1,2,2,2,10,10,10,1

[Events]
Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
''';

  group('AssParser.parse', () {
    test('正常解析三条字幕', () {
      final File ass = writeAss('normal.ass', '''
${header}Dialogue: 0,0:00:01.00,0:00:04.23,Default,,0,0,0,,吾輩は猫である。
Dialogue: 0,0:00:04.50,0:00:08.10,Default,,0,0,0,,名前はまだない。
Dialogue: 0,0:00:08.20,0:00:12.00,Default,,0,0,0,,どこで生れたかとんと見当がつかぬ。
''');

      final List<AudioCue> cues = AssParser.parse(
        assFile: ass,
        bookUid: 'test/book.ass',
      );

      expect(cues.length, 3);
      expect(cues[0].startMs, 1000);
      expect(cues[0].endMs, 4230);
      expect(cues[0].text, '吾輩は猫である。');
      expect(cues[0].textFragmentId, 'srt://0');
      expect(cues[0].chapterHref, AssParser.defaultChapter);
      expect(cues[1].startMs, 4500);
      expect(cues[2].endMs, 12000);
    });

    test('ASS 覆盖标签被剥离', () {
      final File ass = writeAss('tags.ass', '''
${header}Dialogue: 0,0:00:01.00,0:00:03.00,Default,,0,0,0,,{\\an8}{\\b1}強調テキスト{\\b0}
''');

      final List<AudioCue> cues = AssParser.parse(
        assFile: ass,
        bookUid: 'test/book.ass',
      );

      expect(cues.length, 1);
      expect(cues[0].text, '強調テキスト');
    });

    test('软换行符 \\N 转为空格', () {
      final File ass = writeAss('softbreak.ass', '''
${header}Dialogue: 0,0:00:01.00,0:00:03.00,Default,,0,0,0,,一行目\\N二行目
''');

      final List<AudioCue> cues = AssParser.parse(
        assFile: ass,
        bookUid: 'test/book.ass',
      );

      expect(cues.length, 1);
      expect(cues[0].text, '一行目 二行目');
    });

    test('Text 列中含逗号的内容正确拼合', () {
      final File ass = writeAss('comma_text.ass', '''
${header}Dialogue: 0,0:00:01.00,0:00:03.00,Default,,0,0,0,,はい、そうです。
''');

      final List<AudioCue> cues = AssParser.parse(
        assFile: ass,
        bookUid: 'test/book.ass',
      );

      expect(cues.length, 1);
      expect(cues[0].text, 'はい、そうです。');
    });

    test('按 startMs 排序（Dialogue 顺序不影响结果）', () {
      final File ass = writeAss('unsorted.ass', '''
${header}Dialogue: 0,0:00:05.00,0:00:07.00,Default,,0,0,0,,後の行
Dialogue: 0,0:00:01.00,0:00:03.00,Default,,0,0,0,,前の行
''');

      final List<AudioCue> cues = AssParser.parse(
        assFile: ass,
        bookUid: 'test/book.ass',
      );

      expect(cues.length, 2);
      expect(cues[0].text, '前の行');
      expect(cues[1].text, '後の行');
    });

    test('时间码厘秒精度正确（.67 → 670ms）', () {
      final File ass = writeAss('centisec.ass', '''
${header}Dialogue: 0,0:00:01.67,0:00:03.00,Default,,0,0,0,,厘秒テスト
''');

      final List<AudioCue> cues = AssParser.parse(
        assFile: ass,
        bookUid: 'test/book.ass',
      );

      expect(cues.length, 1);
      expect(cues[0].startMs, 1000 + 670);
    });

    test('带 UTF-8 BOM 的文件正常解析', () {
      final File ass = File('${tmpDir.path}/bom.ass');
      final List<int> bom = [0xEF, 0xBB, 0xBF];
      const String content =
          '${header}Dialogue: 0,0:00:01.00,0:00:02.00,Default,,0,0,0,,BOM テスト\n';
      ass.writeAsBytesSync([...bom, ...utf8.encode(content)]);

      final List<AudioCue> cues = AssParser.parse(
        assFile: ass,
        bookUid: 'test/book.ass',
      );

      expect(cues.length, 1);
      expect(cues[0].text, 'BOM テスト');
    });

    test('空文件（无 Events 段）返回空列表', () {
      final File ass = writeAss('empty.ass', '[Script Info]\nTitle: Empty\n');

      final List<AudioCue> cues = AssParser.parse(
        assFile: ass,
        bookUid: 'test/book.ass',
      );

      expect(cues, isEmpty);
    });

    test('defaultChapter 与 SrtParser 共用同一值', () {
      expect(AssParser.defaultChapter, SrtParser.defaultChapter);
    });
  });
}
