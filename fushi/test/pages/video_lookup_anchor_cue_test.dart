import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/pages/implementations/video_fushi_page.dart';
import 'package:fushi_audio/fushi_audio.dart';

/// BUG-966：字幕跳转列表点词查词制卡，卡片音频截错句（截到播放位置那句，而非被点条目）。
///
/// 根因：字幕列表查词入口 `_handleSubtitleListLookup(cue, ...)` 手里有被点的字幕 cue，
/// 但调 `_lookupAt` 时未透传，`_lookupAt` 只能回落到 `currentCue`／按播放位置解析，制卡区间
/// 遂锚到播放头停留处那句。点列表只暂停不 seek，播放头远离被点条目 → 文本对、音频错。
///
/// 修复：`_lookupAt` 加 `overrideCue`，字幕列表查词透传被点 cue；两条查词入口共用
/// [resolveVideoLookupAnchorCue] 统一优先级 `overrideCue > currentCue > 按位置解析`。
/// 本组测试直接覆盖该纯函数：撤掉 `overrideCue ??` 首选会让首个用例转红 = 守卫成立。
AudioCue _cue(int i, int s, int e) => AudioCue()
  ..bookKey = 'video/1'
  ..chapterHref = 'video://default'
  ..sentenceIndex = i
  ..textFragmentId = ''
  ..text = 'line$i'
  ..startMs = s
  ..endMs = e
  ..audioFileIndex = 0;

void main() {
  group('resolveVideoLookupAnchorCue (BUG-966)', () {
    final List<AudioCue> cues = <AudioCue>[
      _cue(0, 0, 1000),
      _cue(1, 2000, 3000),
      _cue(2, 5000, 6000),
    ];

    test('字幕列表查词：overrideCue 优先，即使播放头在别处也锚定被点条目', () {
      // 用户暂停在 5500（落在 cue2 时间窗内），却在列表里点了远处的 cue0。
      // 撤掉 `overrideCue ??` 首选此处会返回 cue2（播放位置那句）= 转红，守卫成立。
      final AudioCue anchor = resolveVideoLookupAnchorCue(
        overrideCue: cues[0],
        currentCue: cues[2],
        cues: cues,
        positionMs: 5500,
        delayMs: 0,
      )!;
      expect(anchor.text, 'line0', reason: '列表点词必须锚定被点条目，而非播放位置那句');
    });

    test('overrideCue 优先级高于 currentCue（两者都非 null 时取 override）', () {
      final AudioCue anchor = resolveVideoLookupAnchorCue(
        overrideCue: cues[1],
        currentCue: cues[2],
        cues: cues,
        positionMs: 5500,
        delayMs: 0,
      )!;
      expect(anchor.text, 'line1');
    });

    test('主画面 overlay 查词：无 overrideCue 时回落 currentCue（正显示的句）', () {
      final AudioCue anchor = resolveVideoLookupAnchorCue(
        overrideCue: null,
        currentCue: cues[1],
        cues: cues,
        positionMs: 2500,
        delayMs: 0,
      )!;
      expect(anchor.text, 'line1');
    });

    test('gap / 末句后：override 与 currentCue 皆 null 时按播放位置解析', () {
      // 1500 落在 cue0..cue1 的静音 gap：currentCue 此刻为 null（BUG-074），
      // 回落 resolveMiningCueForPosition floor 到「最后看到的」cue0（TODO-104b / BUG-188）。
      final AudioCue anchor = resolveVideoLookupAnchorCue(
        overrideCue: null,
        currentCue: null,
        cues: cues,
        positionMs: 1500,
        delayMs: 0,
      )!;
      expect(anchor.text, 'line0');
    });

    test('三者皆无（位置早于全部 cue）诚实返回 null', () {
      final List<AudioCue> later = <AudioCue>[_cue(0, 1000, 2000)];
      expect(
        resolveVideoLookupAnchorCue(
          overrideCue: null,
          currentCue: null,
          cues: later,
          positionMs: 500,
          delayMs: 0,
        ),
        isNull,
      );
    });

    test('空 cue 列表：即便 override 给定为 null 也返回 null（无字幕视频）', () {
      expect(
        resolveVideoLookupAnchorCue(
          overrideCue: null,
          currentCue: null,
          cues: const <AudioCue>[],
          positionMs: 1234,
          delayMs: 0,
        ),
        isNull,
      );
    });

    test('override 给定时跳过位置解析（空 cue 列表也能锚定被点条目）', () {
      // 极端：cues 已被清空，但用户明确点了列表条目 → 仍锚定它，不因空列表退化为 null。
      final AudioCue anchor = resolveVideoLookupAnchorCue(
        overrideCue: _cue(7, 7000, 8000),
        currentCue: null,
        cues: const <AudioCue>[],
        positionMs: 0,
        delayMs: 0,
      )!;
      expect(anchor.text, 'line7');
    });
  });
}
