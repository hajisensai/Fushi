// 特效字幕标志（拍板台 H7r4mf_z2n）：判据在 Rust 解析层（markup.rs `Markup::effect` +
// formats.rs `parse_ass` 的 Effect 列 / 样式旋转），经 markup 掩码第 16 位解码成
// [SubtitleMarkup.isEffect] / [AudioCue.isEffect]。这里走真 FFI 往返，钉住「歌词特效 /
// 屏幕字算特效、普通台词（含淡入淡出 / 顶部锚点 / 颜色）不算」。
//
// 原生库是硬依赖：找不到库直接失败，不 skip。
@TestOn('vm')
library;

import 'package:fushi_audio/fushi_audio.dart';
import 'package:test/test.dart';

const String _ass =
    '[Script Info]\nPlayResX: 1920\nPlayResY: 1080\n\n'
    '[V4+ Styles]\nFormat: Name, Fontname, Fontsize, Angle\n'
    'Style: Default,Arial,60,0\nStyle: Tilted,Arial,60,8\n\n'
    '[Events]\nFormat: Layer, Start, End, Style, Effect, Text\n'
    'Dialogue: 0,0:00:01.00,0:00:02.00,Default,,{\\fad(150,150)}台词一\n'
    'Dialogue: 0,0:00:01.01,0:00:02.00,Default,,{\\an8\\c&H00FFFF&}台词二\n'
    'Dialogue: 0,0:00:01.02,0:00:02.00,Default,,{\\k20}そ{\\k30}よぐ\n'
    'Dialogue: 0,0:00:01.03,0:00:02.00,Default,,{\\pos(960,120)\\frz6}招牌\n'
    'Dialogue: 0,0:00:01.031,0:00:02.00,Default,,{\\pos(580,900)}定位台词\n'
    'Dialogue: 0,0:00:01.04,0:00:02.00,Default,,{\\t(0,500,\\alpha&HFF&)}渐隐\n'
    'Dialogue: 0,0:00:01.05,0:00:02.00,Default,Banner;12,横幅\n'
    'Dialogue: 0,0:00:01.06,0:00:02.00,Tilted,,斜字\n';

void main() {
  test('ASS: effect events are flagged at the parser, dialogue is not', () {
    final List<AudioCue> cues = AssParser.parseString(
      content: _ass,
      bookKey: 'b',
    );
    expect(
      <String, bool>{for (final AudioCue c in cues) c.text: c.isEffect},
      <String, bool>{
        '台词一': false,
        '台词二': false,
        'そよぐ': true,
        '招牌': true,
        // 只带 \pos 的定位对白不是特效（不少字幕组每句都带 \pos）。
        '定位台词': false,
        '渐隐': true,
        '横幅': true,
        '斜字': true,
      },
    );
    // 标志是 markup 的一部分（AudioCue.isEffect 只是转读）。
    expect(cues.first.markup!.isEffect, isFalse);
    expect(cues[2].markup!.isEffect, isTrue);
  });

  test(
    'cues without markup (DB round-trip / transcripts) are never effects',
    () {
      final AudioCue c = AudioCue()
        ..bookKey = 'b'
        ..chapterHref = 'c'
        ..sentenceIndex = 0
        ..textFragmentId = ''
        ..text = 'x'
        ..startMs = 0
        ..endMs = 1
        ..audioFileIndex = 0;
      expect(c.isEffect, isFalse);
    },
  );

  test('SRT plain lines are not effects', () {
    final List<AudioCue> cues = SrtParser.parseString(
      content: '1\n00:00:01,000 --> 00:00:02,000\n<i>台词</i>\n',
      bookKey: 'b',
    );
    expect(cues.single.isEffect, isFalse);
  });
}
