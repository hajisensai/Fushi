// TODO-1384：ASS 逐字卡拉OK 事件在字幕列表里被合并回整句。
//
// 用户片源真值（[Nekomoe kissaten&VCB-Studio] Tensei Oujo to Tensai Reijou no Mahou
// Kakumei，PlayResX 1280 / PlayResY 720，每集 175 条这样的事件）：
//
//   {\an7\pos(461,672)\fad(250,250)\blur2}手
//   {\an7\pos(491,672)\fad(250,250)\blur2}を
//   {\an7\pos(521,672)\fad(250,250)\blur2}伸
//
// 每字一条独立 Dialogue，靠 \pos 在画面上拼成一行；字幕列表按事件 1:1 列行 → 整屏单字，
// 既读不出句子，逐字行的查词/制卡也只能拿到一个字。
//
// 合并**只作用于列表**：渲染层必须保留逐字事件（各有自己的 \pos 与淡入淡出时刻）。
// 判据刻意收窄——宁可漏合也不错合，故本文件的负向用例（不该合并的形态）与正向同等重要。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/media/video/video_subtitle_jump_panel.dart';
import 'package:hibiki_audio/hibiki_audio.dart';

AudioCue _cue(String raw, {required int startMs, required int endMs}) {
  final SubtitleMarkup m =
      parseSubtitleMarkup(raw, playResX: 1280, playResY: 720);
  return AudioCue()
    ..bookKey = 'b'
    ..chapterHref = 'c'
    ..sentenceIndex = 0
    ..textFragmentId = ''
    ..text = m.plainText
    ..markup = m
    ..startMs = startMs
    ..endMs = endMs
    ..audioFileIndex = 0;
}

/// 片源真值：一句 OP 歌词的前 6 个字（x 递增 30，y 恒 672，逐字入场 ~40ms）。
List<AudioCue> _opLine() {
  const List<String> chars = <String>['手', 'を', '伸', 'ば', 'し', 'て'];
  return <AudioCue>[
    for (int i = 0; i < chars.length; i++)
      _cue(
        '{\\an7\\pos(${461 + i * 30},672)\\fad(250,250)\\blur2}${chars[i]}',
        startMs: 41350 + i * 40,
        endMs: 44480 + i * 40,
      ),
  ];
}

void main() {
  group('正向：逐字卡拉OK 合并成整句', () {
    test('片源真值一行 6 条 → 合成 1 句，文本按 x 顺序拼接', () {
      final List<AudioCue> cues = _opLine();
      final r = mergePerCharacterCueGroups(cues);
      expect(r.byRep.keys, <int>[0], reason: '代表行是组首');
      expect(r.byRep[0]!.text, '手を伸ばして');
    });

    test('合成句时间跨度 = 组内最早开始到最晚结束', () {
      final r = mergePerCharacterCueGroups(_opLine());
      expect(r.byRep[0]!.startMs, 41350);
      expect(r.byRep[0]!.endMs, 44480 + 5 * 40);
    });

    test('组内每个成员都映射到代表行（当前播放句落在任一单字都能定位回整句行）', () {
      final r = mergePerCharacterCueGroups(_opLine());
      for (int i = 0; i < 6; i++) {
        expect(r.repByRaw[i], 0, reason: '第 $i 个单字应映射到代表行 0');
      }
    });

    test('文件顺序与画面顺序不一致时按 x 排序（复现 libass 横向顺序）', () {
      final List<AudioCue> cues = <AudioCue>[
        _cue(r'{\pos(600,672)}B', startMs: 1000, endMs: 3000),
        _cue(r'{\pos(500,672)}A', startMs: 1040, endMs: 3040),
      ];
      final r = mergePerCharacterCueGroups(cues);
      expect(r.byRep[0]!.text, 'AB', reason: '按 \\pos 的 x 升序，不是文件序');
    });

    test('同屏上下两行（y 不同）各自成句，不并成一行', () {
      final List<AudioCue> cues = <AudioCue>[
        _cue(r'{\pos(500,600)}上', startMs: 1000, endMs: 3000),
        _cue(r'{\pos(530,600)}行', startMs: 1040, endMs: 3040),
        _cue(r'{\pos(500,672)}下', startMs: 1000, endMs: 3000),
        _cue(r'{\pos(530,672)}行', startMs: 1040, endMs: 3040),
      ];
      final r = mergePerCharacterCueGroups(cues);
      expect(r.byRep.length, 2);
      expect(r.byRep[0]!.text, '上行');
      expect(r.byRep[2]!.text, '下行');
    });

    test('时间不重叠的下一句断组（同一行连唱两句不会被粘起来）', () {
      final List<AudioCue> cues = <AudioCue>[
        _cue(r'{\pos(500,672)}前', startMs: 1000, endMs: 2000),
        _cue(r'{\pos(530,672)}句', startMs: 1040, endMs: 2040),
        _cue(r'{\pos(500,672)}後', startMs: 5000, endMs: 6000),
        _cue(r'{\pos(530,672)}句', startMs: 5040, endMs: 6040),
      ];
      final r = mergePerCharacterCueGroups(cues);
      expect(r.byRep.length, 2);
      expect(r.byRep[0]!.text, '前句');
      expect(r.byRep[2]!.text, '後句');
    });
  });

  group('负向：不该合并的形态（错合比漏合更糟）', () {
    test('无 \\pos 的常规对白永不参与合并', () {
      final List<AudioCue> cues = <AudioCue>[
        _cue('あ', startMs: 1000, endMs: 3000),
        _cue('い', startMs: 1040, endMs: 3040),
      ];
      expect(mergePerCharacterCueGroups(cues).byRep, isEmpty);
    });

    test('多字事件（已是完整句）不被合并', () {
      // 刻意让**除「单字」外的所有条件全部满足**：同 y、同 layer、都带 \pos、时间重叠。
      // 唯一阻止合并的就是「文本是单个 grapheme」这一条，否则本用例会自洽成假绿——
      // 首版把两条放在不同 y 上，去掉单字判据也照样绿（变异实测抓到）。
      final List<AudioCue> cues = <AudioCue>[
        _cue(r'{\pos(500,672)}こんにちは', startMs: 1000, endMs: 3000),
        _cue(r'{\pos(700,672)}さようなら', startMs: 1040, endMs: 3040),
      ];
      expect(mergePerCharacterCueGroups(cues).byRep, isEmpty);
    });

    test('孤立单字（组内只有 1 条）不合并', () {
      final List<AudioCue> cues = <AudioCue>[
        _cue(r'{\pos(500,672)}あ', startMs: 1000, endMs: 3000),
        _cue(r'{\pos(500,300)}い', startMs: 9000, endMs: 9500),
      ];
      expect(mergePerCharacterCueGroups(cues).byRep, isEmpty);
    });

    test('不同 ASS Layer 不合并（多层特效各按自己的层）', () {
      final SubtitleMarkup m0 = parseSubtitleMarkup(r'{\pos(500,672)}影',
          playResX: 1280, playResY: 720);
      final SubtitleMarkup m1 = parseSubtitleMarkup(r'{\pos(530,672)}字',
          playResX: 1280, playResY: 720, layer: 3);
      final List<AudioCue> cues = <AudioCue>[
        AudioCue()
          ..bookKey = 'b'
          ..chapterHref = 'c'
          ..sentenceIndex = 0
          ..textFragmentId = ''
          ..text = m0.plainText
          ..markup = m0
          ..startMs = 1000
          ..endMs = 3000
          ..audioFileIndex = 0,
        AudioCue()
          ..bookKey = 'b'
          ..chapterHref = 'c'
          ..sentenceIndex = 0
          ..textFragmentId = ''
          ..text = m1.plainText
          ..markup = m1
          ..startMs = 1040
          ..endMs = 3040
          ..audioFileIndex = 0,
      ];
      expect(mergePerCharacterCueGroups(cues).byRep, isEmpty);
    });

    test('纯 SRT（无 markup）列表零影响', () {
      final List<AudioCue> cues = <AudioCue>[
        AudioCue()
          ..bookKey = 'b'
          ..chapterHref = 'c'
          ..sentenceIndex = 0
          ..textFragmentId = ''
          ..text = 'A'
          ..startMs = 1000
          ..endMs = 2000
          ..audioFileIndex = 0,
      ];
      expect(mergePerCharacterCueGroups(cues).byRep, isEmpty);
    });

    test('空列表安全', () {
      expect(mergePerCharacterCueGroups(<AudioCue>[]).byRep, isEmpty);
    });
  });

  group('合成 cue 的下游契约', () {
    test('是真 AudioCue：查词/收藏/制卡按 (text, startMs) 值语义作用于整句', () {
      final AudioCue m = mergePerCharacterCueGroups(_opLine()).byRep[0]!;
      expect(m.text, '手を伸ばして');
      expect(m.startMs, 41350);
      expect(m.bookKey, 'b', reason: '身份字段沿用代表行，收藏键才算得出来');
      expect(m.audioFileIndex, 0);
    });

    test('合成句不继承 markup（它没有单一的 \\pos/\\fad，渲染层也不消费本结果）', () {
      expect(mergePerCharacterCueGroups(_opLine()).byRep[0]!.markup, isNull);
    });
  });

  group('源码守卫', () {
    final String src =
        File('lib/src/media/video/video_subtitle_jump_panel.dart')
            .readAsStringSync();

    test('列表取行 cue 必须走 _rowCue 单一入口', () {
      // 割裂风险：任何一处漏改都会变成「列表显示整句、制卡/收藏只拿到一个字」。
      expect(src, contains('AudioCue _rowCue('));
      // 行渲染 / 行高测量 / 计数 / 筛选全部经此入口取 cue。
      expect('_rowCue(cues'.allMatches(src).length, greaterThanOrEqualTo(8),
          reason: '漏改任何一处就会出现「列表整句、制卡单字」的割裂');
    });

    test('合并结果的缓存与 dedup 表同生命周期（换轨不得残留上一份字幕）', () {
      final int fn = src.indexOf('void _clearCueCaches()');
      expect(fn, greaterThanOrEqualTo(0));
      final int fnEnd = src.indexOf('\n  }', fn);
      expect(src.substring(fn, fnEnd), contains('_cachedMergedByRep'));
    });
  });
}
