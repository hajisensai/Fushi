import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_audio/fushi_audio.dart';

/// BUG-2535：有声书章尾——本章最后一句匹配上、播完之后，下一条 cue 没匹配上正文
/// （常是下一章章名 / 无正文的过场），文字要等到下一章第一条**匹配** cue 才跟过去，
/// 期间用户听着下一章、屏幕停在上一章章尾。
///
/// 根因：`AudiobookPlayerController._maybeEmitCrossChapter` 对解不出 section 的 cue
/// 直接 `return`，没有任何「本章已读完」的判断。修法把判据抽成纯函数
/// [AudiobookPlayerController.unmatchedCueCrossChapterTargetForTesting]：按**播放顺序**
/// 看邻居——上一条匹配 cue 属于当前章、之后再无本章匹配 cue → 目标 = 下一章。
///
/// 第二组是源码守卫：reader 侧 `_handleCueCrossChapter` 必须放行未匹配 cue 的跨章
/// （上游要求匹配 cue 解得出学习单元锚才跨，未匹配 cue 没有锚、落章首即可）。
void main() {
  AudioCue cue({
    required int file,
    required int startMs,
    int? section,
  }) {
    return AudioCue()
      ..bookKey = 'book'
      ..chapterHref = 'ch'
      ..sentenceIndex = startMs
      ..textFragmentId = section == null
          ? ''
          : SubtitleRematchCodec.encodeHit(
              sectionIndex: section,
              normCharStart: 0,
              normCharEnd: 10,
            )
      ..text = 't'
      ..startMs = startMs
      ..endMs = startMs + 100
      ..audioFileIndex = file;
  }

  int target(List<AudioCue> cues, AudioCue current, int currentSec) {
    return AudiobookPlayerController.unmatchedCueCrossChapterTargetForTesting(
      playbackOrderedCues: cues,
      cue: current,
      currentSec: currentSec,
    );
  }

  group('unmatched cue at chapter end crosses to the next chapter (BUG-2535)',
      () {
    test('本章最后一句已播完、下一条未匹配 → 进入下一章', () {
      final AudioCue last = cue(file: 0, startMs: 100, section: 3);
      final AudioCue title = cue(file: 0, startMs: 200);
      final AudioCue next = cue(file: 0, startMs: 300, section: 4);
      expect(target(<AudioCue>[last, title, next], title, 3), 4);
    });

    test('本章之后再无任何匹配 cue（全书最后一章的尾巴）→ 仍进入下一章', () {
      final AudioCue last = cue(file: 0, startMs: 100, section: 3);
      final AudioCue tail = cue(file: 0, startMs: 200);
      expect(target(<AudioCue>[last, tail], tail, 3), 4);
    });

    test('章中间一句没匹配上（之后还有本章匹配 cue）→ 保位', () {
      final AudioCue a = cue(file: 0, startMs: 100, section: 3);
      final AudioCue gap = cue(file: 0, startMs: 200);
      final AudioCue b = cue(file: 0, startMs: 300, section: 3);
      expect(target(<AudioCue>[a, gap, b], gap, 3), -1);
    });

    test(
        '连续多条未匹配 cue：每一条都判进入下一章（首条触发后 reader 已换章，'
        '后续按新 currentSec 自然保位）', () {
      final AudioCue last = cue(file: 0, startMs: 100, section: 3);
      final AudioCue u1 = cue(file: 0, startMs: 200);
      final AudioCue u2 = cue(file: 0, startMs: 300);
      final AudioCue next = cue(file: 0, startMs: 400, section: 4);
      final List<AudioCue> cues = <AudioCue>[last, u1, u2, next];
      expect(target(cues, u1, 3), 4);
      expect(target(cues, u2, 3), 4);
      // reader 已落到第 4 章：上一条匹配 cue 属于第 3 章 ≠ 当前章 → 保位，不再乱跳。
      expect(target(cues, u2, 4), -1);
    });

    test('上一条匹配 cue 不属于当前章（用户手动翻到别处）→ 保位', () {
      final AudioCue last = cue(file: 0, startMs: 100, section: 3);
      final AudioCue title = cue(file: 0, startMs: 200);
      expect(target(<AudioCue>[last, title], title, 7), -1);
    });

    test('之前没有任何匹配 cue（开头的未匹配段）→ 保位', () {
      final AudioCue intro = cue(file: 0, startMs: 0);
      final AudioCue first = cue(file: 0, startMs: 100, section: 0);
      expect(target(<AudioCue>[intro, first], intro, 0), -1);
    });

    test('下一条匹配 cue 属于更早的章（乱序数据）→ 保位不猜', () {
      final AudioCue last = cue(file: 0, startMs: 100, section: 3);
      final AudioCue u = cue(file: 0, startMs: 200);
      final AudioCue back = cue(file: 0, startMs: 300, section: 1);
      expect(target(<AudioCue>[last, u, back], u, 3), -1);
    });

    test('reader 未就绪（currentSec < 0）/ cue 不在列表 → 保位', () {
      final AudioCue last = cue(file: 0, startMs: 100, section: 3);
      final AudioCue u = cue(file: 0, startMs: 200);
      expect(target(<AudioCue>[last, u], u, -1), -1);
      expect(target(<AudioCue>[last], u, 3), -1);
    });

    test('全书 cue 都解不出 section（SRT / SMIL 路径）→ 恒保位', () {
      final AudioCue a = cue(file: 0, startMs: 100);
      final AudioCue b = cue(file: 0, startMs: 200);
      expect(target(<AudioCue>[a, b], b, 0), -1);
    });

    test('跨音频文件：播放邻居按 (audioFileIndex, startMs)，不是裸 startMs', () {
      // 文件 0 的最后一句在 900ms，文件 1 开头的未匹配 cue 在 0ms——按裸 startMs
      // 排它会排到最前面、看不到「上一条匹配 cue」；按播放顺序它紧跟文件 0 尾句。
      final AudioCue last = cue(file: 0, startMs: 900, section: 3);
      final AudioCue title = cue(file: 1, startMs: 0);
      final AudioCue next = cue(file: 1, startMs: 100, section: 4);
      expect(target(<AudioCue>[last, title, next], title, 3), 4);
    });
  });

  group('controller / reader wiring guard (BUG-2535)', () {
    final String controller = File(
      '../packages/fushi_audio/lib/src/audiobook/audiobook_controller.dart',
    ).readAsStringSync();
    final String reader = File(
      'lib/src/pages/implementations/reader_fushi/audiobook.part.dart',
    ).readAsStringSync();

    test('setChapterCues 维护按 (audioFileIndex, startMs) 排的播放序视图', () {
      expect(controller, contains('_playbackOrderedCues = List<AudioCue>.from'),
          reason: '未匹配 cue 的邻居判定要的是播放顺序，_chapterCues 只按 startMs 排');
      expect(
          controller, contains('a.audioFileIndex.compareTo(b.audioFileIndex)'),
          reason: '播放序先比 audioFileIndex');
    });

    test('_maybeEmitCrossChapter 对未匹配 cue 走章尾判据而非直接 return', () {
      final int i = controller.indexOf('void _maybeEmitCrossChapter(');
      expect(i, greaterThan(-1));
      final String fn = controller.substring(i, i + 1800);
      expect(fn, isNot(contains('if (frag == null) return;')),
          reason: '未匹配 cue 不能再无条件早退（BUG-2535 根因）');
      expect(fn, contains('unmatchedCueCrossChapterTargetForTesting('),
          reason: '未匹配 cue 须经播放邻居判据决定是否进入下一章');
    });

    test('reader _handleCueCrossChapter 放行未匹配 cue（无学习单元锚时落章首）', () {
      final int i = reader.indexOf('Future<void> _handleCueCrossChapter(');
      expect(i, greaterThan(-1));
      final String fn = reader.substring(i, i + 4000);
      expect(
          fn,
          contains(
              'final bool unmatchedChapterEnd = cue != null && frag == null;'),
          reason: '未匹配 cue 的跨章没有字符锚，不能被 studyOffset == null 拦下');
      expect(fn, contains('if (studyOffset == null && !unmatchedChapterEnd) {'),
          reason: '只有匹配 cue 才要求解得出学习单元锚');
    });
  });
}
