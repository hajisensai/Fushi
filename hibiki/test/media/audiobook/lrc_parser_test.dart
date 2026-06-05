import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki_audio/hibiki_audio.dart';

void main() {
  group('LrcParser.parseString', () {
    test('正常解析三条字幕', () {
      final List<AudioCue> cues = LrcParser.parseString(
        content: '''
[ar:夏目漱石]
[ti:吾輩は猫である]

[00:01.00]吾輩は猫である。
[00:04.50]名前はまだない。
[00:08.20]どこで生れたかとんと見当がつかぬ。
''',
        bookKey: 'test/book.lrc',
      );

      expect(cues.length, 3);

      expect(cues[0].sentenceIndex, 0);
      expect(cues[0].startMs, 1000);
      expect(cues[0].endMs, 4500);
      expect(cues[0].text, '吾輩は猫である。');
      expect(cues[0].textFragmentId, '[data-cue-id="0"]');
      expect(cues[0].chapterHref, LrcParser.defaultChapter);
      expect(cues[0].bookKey, 'test/book.lrc');
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
      final List<AudioCue> cues = LrcParser.parseString(
        content: '''
[ar:Artist]
[ti:Title]
[al:Album]
[by:Creator]
[00:01.00]テキスト行のみ
''',
        bookKey: 'test/book.lrc',
      );

      expect(cues.length, 1);
      expect(cues[0].text, 'テキスト行のみ');
    });

    test('同一行多个时间标签生成独立 cue', () {
      final List<AudioCue> cues = LrcParser.parseString(
        content: '''
[00:01.00][00:10.00]リフレイン歌詞
''',
        bookKey: 'test/book.lrc',
      );

      expect(cues.length, 2);
      // 排序后 startMs 应升序
      expect(cues[0].startMs, 1000);
      expect(cues[1].startMs, 10000);
      expect(cues[0].text, 'リフレイン歌詞');
      expect(cues[1].text, 'リフレイン歌詞');
    });

    test('增强 LRC 词级时间标签被剥离', () {
      final List<AudioCue> cues = LrcParser.parseString(
        content: '''
[00:01.00]<00:01.00>吾輩<00:01.50>は<00:01.80>猫
''',
        bookKey: 'test/book.lrc',
      );

      expect(cues.length, 1);
      expect(cues[0].text, '吾輩は猫');
    });

    test('HH:MM:SS.xx 扩展格式正确解析', () {
      final List<AudioCue> cues = LrcParser.parseString(
        content: '''
[01:02:03.45]長時間ファイル
''',
        bookKey: 'test/book.lrc',
      );

      expect(cues.length, 1);
      // 1h + 2m + 3s + 450ms
      expect(cues[0].startMs, 3600000 + 120000 + 3000 + 450);
    });

    test('带 UTF-8 BOM 的内容正常解析', () {
      final List<AudioCue> cues = LrcParser.parseString(
        content: '\uFEFF[00:01.00]BOM テスト\n',
        bookKey: 'test/book.lrc',
      );

      expect(cues.length, 1);
      expect(cues[0].text, 'BOM テスト');
    });

    test('空文件返回空列表', () {
      final List<AudioCue> cues = LrcParser.parseString(
        content: '',
        bookKey: 'test/book.lrc',
      );

      expect(cues, isEmpty);
    });

    test('defaultChapter 与 SrtParser 共用同一值', () {
      expect(LrcParser.defaultChapter, SrtParser.defaultChapter);
    });

    test('lastCueDurationMs 可自定义', () {
      final List<AudioCue> cues = LrcParser.parseString(
        content: '[00:05.00]テスト\n',
        bookKey: 'test/book.lrc',
        lastCueDurationMs: 3000,
      );

      expect(cues.length, 1);
      expect(cues[0].endMs, 5000 + 3000);
    });

    test('逗号分隔毫秒也能解析', () {
      final List<AudioCue> cues = LrcParser.parseString(
        content: '[00:01,50]コンマ区切り\n',
        bookKey: 'test/book.lrc',
      );

      expect(cues.length, 1);
      expect(cues[0].startMs, 1500);
    });
  });
}
