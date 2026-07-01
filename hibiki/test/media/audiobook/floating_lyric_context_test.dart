import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/media/audiobook/floating_lyric_context.dart';
import 'package:hibiki_audio/hibiki_audio.dart';

/// TODO-708 P4：悬浮字幕上下文窗口纯函数测试。
///
/// 这些用例定义了「Dart 端组装多行」（路线 A）的契约：给定完整 cue 列表 +
/// 当前索引 + 上下文行数 N，返回 [index-n, index+n] 夹取后的多行文本块，并算出
/// 当前行在块内的 UTF-16 offset/length。N=0 时逐字节等于今天的单行观感。
void main() {
  AudioCue cueWith(String text) {
    final AudioCue c = AudioCue();
    c.bookKey = 'k';
    c.chapterHref = 'c';
    c.sentenceIndex = 0;
    c.textFragmentId = '#s';
    c.text = text;
    c.startMs = 0;
    c.endMs = 0;
    c.audioFileIndex = 0;
    return c;
  }

  List<AudioCue> cuesFrom(List<String> texts) =>
      texts.map(cueWith).toList(growable: false);

  group('floatingLyricContextWindow', () {
    final List<AudioCue> five =
        cuesFrom(<String>['行0', '行1', '行2', '行3', '行4']);

    test('n=0 只返回当前行（单元素）', () {
      expect(
        floatingLyricContextWindow(cues: five, index: 2, n: 0),
        <String>['行2'],
      );
    });

    test('中段完整前后 N 行', () {
      expect(
        floatingLyricContextWindow(cues: five, index: 2, n: 1),
        <String>['行1', '行2', '行3'],
      );
      expect(
        floatingLyricContextWindow(cues: five, index: 2, n: 2),
        <String>['行0', '行1', '行2', '行3', '行4'],
      );
    });

    test('头部不足只显示可用行（不留空）', () {
      expect(
        floatingLyricContextWindow(cues: five, index: 0, n: 2),
        <String>['行0', '行1', '行2'],
      );
    });

    test('尾部不足只显示可用行（不留空）', () {
      expect(
        floatingLyricContextWindow(cues: five, index: 4, n: 2),
        <String>['行2', '行3', '行4'],
      );
    });

    test('n 超过可用行数=夹取整表', () {
      expect(
        floatingLyricContextWindow(cues: five, index: 2, n: 99),
        <String>['行0', '行1', '行2', '行3', '行4'],
      );
    });

    test('index<0（未匹配）=空列表', () {
      expect(
        floatingLyricContextWindow(cues: five, index: -1, n: 1),
        <String>[],
      );
    });

    test('空 cue 列表=空列表', () {
      expect(
        floatingLyricContextWindow(cues: const <AudioCue>[], index: 0, n: 1),
        <String>[],
      );
    });

    test('index 越界（>=len）=空列表', () {
      expect(
        floatingLyricContextWindow(cues: five, index: 5, n: 1),
        <String>[],
      );
    });

    test('n<0 被夹到 0=只当前行', () {
      expect(
        floatingLyricContextWindow(cues: five, index: 2, n: -3),
        <String>['行2'],
      );
    });
  });

  group('buildFloatingLyricBlock', () {
    final List<AudioCue> five =
        cuesFrom(<String>['行0', '行1', '行2', '行3', '行4']);

    test('n=0：单行块 start=0 length=当前行长度', () {
      final FloatingLyricBlock block =
          buildFloatingLyricBlock(cues: five, index: 2, n: 0);
      expect(block.text, '行2');
      expect(block.start, 0);
      expect(block.length, '行2'.length);
    });

    test('中段：多行 join \n 且当前行 offset 与 join 位置一致（UTF-16）', () {
      final FloatingLyricBlock block =
          buildFloatingLyricBlock(cues: five, index: 2, n: 1);
      expect(block.text, '行1\n行2\n行3');
      // '行1\n' = 3 UTF-16 code units → 当前行从 offset 3 起。
      expect(block.start, 3);
      expect(block.length, '行2'.length);
      // 断言 substring 落在当前行文本上。
      expect(
        block.text.substring(block.start, block.start + block.length),
        '行2',
      );
    });

    test('头部夹取：当前行在块首 start=0', () {
      final FloatingLyricBlock block =
          buildFloatingLyricBlock(cues: five, index: 0, n: 2);
      expect(block.text, '行0\n行1\n行2');
      expect(block.start, 0);
      expect(block.length, '行0'.length);
    });

    test('尾部夹取：当前行在块尾 offset 正确', () {
      final FloatingLyricBlock block =
          buildFloatingLyricBlock(cues: five, index: 4, n: 2);
      expect(block.text, '行2\n行3\n行4');
      // '行2\n行3\n' = 3+3 = 6 UTF-16 units。
      expect(block.start, 6);
      expect(block.length, '行4'.length);
      expect(
        block.text.substring(block.start, block.start + block.length),
        '行4',
      );
    });

    test('surrogate pair（emoji 前缀行）offset 按 UTF-16 计', () {
      final List<AudioCue> cues = cuesFrom(<String>['😀前行', '当前', '后行']);
      final FloatingLyricBlock block =
          buildFloatingLyricBlock(cues: cues, index: 1, n: 1);
      expect(block.text, '😀前行\n当前\n后行');
      // '😀' = 2 UTF-16 units, '前行' = 2, '\n' = 1 → 当前行从 5 起。
      expect(block.start, 5);
      expect(block.length, '当前'.length);
      expect(
        block.text.substring(block.start, block.start + block.length),
        '当前',
      );
    });

    test('index<0：空块 text=空 start=-1 length=0（退化无行标记）', () {
      final FloatingLyricBlock block =
          buildFloatingLyricBlock(cues: five, index: -1, n: 1);
      expect(block.text, '');
      expect(block.start, -1);
      expect(block.length, 0);
    });

    test('空列表：空块 text=空 start=-1 length=0', () {
      final FloatingLyricBlock block =
          buildFloatingLyricBlock(cues: const <AudioCue>[], index: 0, n: 1);
      expect(block.text, '');
      expect(block.start, -1);
      expect(block.length, 0);
    });
  });
}
