import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_audio/fushi_audio.dart';

/// BUG-1161 端到端护栏：注音（振假名）读音不得进入 cue 正文。
///
/// `AudioCue.text` 是查词 / 制卡 sentence / 字数统计的唯一坐标系，`<rt>` 里的读音混进去
/// 会让 `震ふる` 这种拼接串成为「用户看到并被制卡」的句子。三个走 `stripHtmlTags` 的
/// 解析器入口（srt / vtt / lrc）各测一遍真实路径，而不是只测底层函数。
void main() {
  group('注音不进 cue 正文（真实解析路径）', () {
    test('VttParser：<ruby>/<rt> 只留基准', () {
      final List<AudioCue> cues = VttParser.parseString(
        content: '''
WEBVTT

1
00:00:01.000 --> 00:00:04.000
<ruby>吾輩<rt>わがはい</rt></ruby>は<ruby>猫<rt>ねこ</rt></ruby>である。

2
00:00:04.500 --> 00:00:08.000
<ruby>震<rp>（</rp><rt>ふる</rt><rp>）</rp></ruby>える。
''',
        bookKey: 'test/ruby.vtt',
      );

      expect(cues.length, 2);
      expect(cues[0].text, '吾輩は猫である。');
      expect(cues[1].text, '震える。');
    });

    test('SrtParser：<ruby>/<rt> 只留基准，省略 </rt> 也不漏', () {
      final List<AudioCue> cues = SrtParser.parseString(
        content: '''
1
00:00:01,000 --> 00:00:04,000
<ruby>漢<rt>かん</rt>字<rt>じ</rt></ruby>を<i>読</i>む。

2
00:00:04,500 --> 00:00:08,000
<ruby>震<rt>ふる</ruby>える。
''',
        bookKey: 'test/ruby.srt',
      );

      expect(cues.length, 2);
      expect(cues[0].text, '漢字を読む。');
      expect(cues[1].text, '震える。');
    });

    test('LrcParser：注音剥离与词级时间标签剥离互不干扰', () {
      final List<AudioCue> cues = LrcParser.parseString(
        content: '''
[00:01.00]<ruby>春<rt>はる</rt></ruby>と<ruby>夏<rt>なつ</rt></ruby>
[00:05.00]<00:05.20>こん<00:05.80>にちは
''',
        bookKey: 'test/ruby.lrc',
      );

      expect(cues.length, 2);
      expect(cues[0].text, '春と夏');
      expect(cues[1].text, 'こんにちは');
    });

    test('注音剥离后，markup.plainText 与 text 仍是同一坐标系', () {
      final List<AudioCue> cues = VttParser.parseString(
        content: '''
WEBVTT

1
00:00:01.000 --> 00:00:04.000
<ruby>震<rt>ふる</rt></ruby>える。
''',
        bookKey: 'test/ruby-markup.vtt',
      );

      expect(cues.length, 1);
      expect(cues[0].text, '震える。');
      expect(cues[0].markup?.plainText, '震える。');
    });
  });
}
