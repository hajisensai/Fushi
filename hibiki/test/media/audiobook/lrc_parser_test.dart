import 'dart:convert'; // utf8 用于 BOM 测试
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/media/audiobook/audiobook_model.dart';
import 'package:hibiki/src/media/audiobook/lrc_parser.dart';
import 'package:hibiki/src/media/audiobook/srt_parser.dart';

void main() {
  late Directory tmpDir;

  setUp(() {
    tmpDir = Directory.systemTemp.createTempSync('lrc_parser_test_');
  });

  tearDown(() {
    tmpDir.deleteSync(recursive: true);
  });

  File writeLrc(String name, String content) {
    final File f = File('${tmpDir.path}/$name');
    f.writeAsStringSync(content);
    return f;
  }

  group('LrcParser.parse', () {
    test('正常解析三条字幕', () {
      final File lrc = writeLrc('normal.lrc', '''
[ar:夏目漱石]
[ti:吾輩は猫である]

[00:01.00]吾輩は猫である。
[00:04.50]名前はまだない。
[00:08.20]どこで生れたかとんと見当がつかぬ。
''');

      final List<AudioCue> cues = LrcParser.parse(
        lrcFile: lrc,
        bookUid: 'test/book.lrc',
      );

      expect(cues.length, 3);

      expect(cues[0].sentenceIndex, 0);
      expect(cues[0].startMs, 1000);
      expect(cues[0].endMs, 4500);
      expect(cues[0].text, '吾輩は猫である。');
      expect(cues[0].textFragmentId, '[data-cue-id="0"]');
      expect(cues[0].chapterHref, LrcParser.defaultChapter);
      expect(cues[0].bookUid, 'test/book.lrc');
      expect(cues[0].audioFileIndex, 0);

      expect(cues[1].sentenceIndex, 1);
      expect(cues[1].startMs, 4500);
      expect(cues[1].endMs, 8200);
      expect(cues[1].text, '名前はまだない。');
      expect(cues[1].textFragmentId, '[data-cue-id="1"]');

      expect(cues[2].sentenceIndex, 2);
      expect(cues[2].startMs, 8200);
      // 最後の cue: startMs + lastCueDurationMs(5000)
      expect(cues[2].endMs, 8200 + 5000);
    });

    test('元数据行被跳过', () {
      final File lrc = writeLrc('meta.lrc', '''
[ar:Artist]
[ti:Title]
[al:Album]
[by:Creator]
[00:01.00]テキスト行のみ
''');

      final List<AudioCue> cues = LrcParser.parse(
        lrcFile: lrc,
        bookUid: 'test/book.lrc',
      );

      expect(cues.length, 1);
      expect(cues[0].text, 'テキスト行のみ');
    });

    test('同一行多个时间标签生成独立 cue', () {
      final File lrc = writeLrc('multi_tag.lrc', '''
[00:01.00][00:10.00]リフレイン歌詞
''');

      final List<AudioCue> cues = LrcParser.parse(
        lrcFile: lrc,
        bookUid: 'test/book.lrc',
      );

      expect(cues.length, 2);
      // 排序后 startMs 应升序
      expect(cues[0].startMs, 1000);
      expect(cues[1].startMs, 10000);
      expect(cues[0].text, 'リフレイン歌詞');
      expect(cues[1].text, 'リフレイン歌詞');
    });

    test('增强 LRC 词级时间标签被剥离', () {
      final File lrc = writeLrc('word_tags.lrc', '''
[00:01.00]<00:01.00>吾輩<00:01.50>は<00:01.80>猫
''');

      final List<AudioCue> cues = LrcParser.parse(
        lrcFile: lrc,
        bookUid: 'test/book.lrc',
      );

      expect(cues.length, 1);
      expect(cues[0].text, '吾輩は猫');
    });

    test('HH:MM:SS.xx 扩展格式正确解析', () {
      final File lrc = writeLrc('extended.lrc', '''
[01:02:03.45]長時間ファイル
''');

      final List<AudioCue> cues = LrcParser.parse(
        lrcFile: lrc,
        bookUid: 'test/book.lrc',
      );

      expect(cues.length, 1);
      // 1h + 2m + 3s + 450ms
      expect(cues[0].startMs, 3600000 + 120000 + 3000 + 450);
    });

    test('带 UTF-8 BOM 的文件正常解析', () {
      final File lrc = File('${tmpDir.path}/bom.lrc');
      final List<int> bom = [0xEF, 0xBB, 0xBF];
      final List<int> body = utf8.encode('[00:01.00]BOM テスト\n');
      lrc.writeAsBytesSync([...bom, ...body]);

      final List<AudioCue> cues = LrcParser.parse(
        lrcFile: lrc,
        bookUid: 'test/book.lrc',
      );

      expect(cues.length, 1);
      expect(cues[0].text, 'BOM テスト');
    });

    test('空文件返回空列表', () {
      final File lrc = writeLrc('empty.lrc', '');

      final List<AudioCue> cues = LrcParser.parse(
        lrcFile: lrc,
        bookUid: 'test/book.lrc',
      );

      expect(cues, isEmpty);
    });

    test('defaultChapter 与 SrtParser 共用同一值', () {
      expect(LrcParser.defaultChapter, SrtParser.defaultChapter);
    });

    test('lastCueDurationMs 可自定义', () {
      final File lrc = writeLrc('last_dur.lrc', '[00:05.00]テスト\n');

      final List<AudioCue> cues = LrcParser.parse(
        lrcFile: lrc,
        bookUid: 'test/book.lrc',
        lastCueDurationMs: 3000,
      );

      expect(cues.length, 1);
      expect(cues[0].endMs, 5000 + 3000);
    });

    test('逗号分隔毫秒也能解析', () {
      final File lrc = writeLrc('comma.lrc', '[00:01,50]コンマ区切り\n');

      final List<AudioCue> cues = LrcParser.parse(
        lrcFile: lrc,
        bookUid: 'test/book.lrc',
      );

      expect(cues.length, 1);
      expect(cues[0].startMs, 1500);
    });
  });
}
