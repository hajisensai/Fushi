import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/audiobook/audiobook_controller.dart';
import 'package:fushi_audio/fushi_audio.dart';

/// 跨章守卫的释放判据（PR #2544 的症状场景，BUG-3798 的修法）。
///
/// 症状（PR #2544 真机报告）：ch.89 从有声书面板「章节」tab 跳章后，音频已往前走了
/// 9 分钟、高亮仍冻在章首，reader 停在 section 91、cue 不再推进。
///
/// PR #2544 原本的修法是「守卫期间 reader 当前章 == cue 所属章就自愈放守卫」。这个
/// 判据不成立：reader 的 `_beginNavigation`（`reader_fushi/navigation.part.dart`）在
/// 导航**一开始**就同步写 `_currentChapter = chapter`，等式在落地回执到来前就成立，
/// 会把还在飞的导航的守卫提前放掉。BUG-3798 改为找出回执为什么不来并修掉
/// （导航被拒不发信号 / 加载失败不走统一中止 / spread 就绪不带代际 / 显式 seek
/// 无条件清守卫 / 面板跳章回弹），守卫只由**真实的落地回执或明确的中止 / 取消信号**
/// 释放。本文件在同一症状场景下钉住这一点。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('跨章守卫只由落地回执 / 中止信号释放', () {
    test('reader 已在 cue 所属章但回执未到：守卫不放；落地回执到了才放', () {
      final AudiobookPlayerController controller = AudiobookPlayerController();
      addTearDown(controller.dispose);

      final List<AudioCue> cues = <AudioCue>[
        _cue('a', startMs: 0, section: 91),
        _cue('b', startMs: 1000, section: 91),
      ];
      controller.setChapterCues(cues);
      // reader 的 _beginNavigation 已同步把当前章写成 91（导航在飞）。
      controller.getCurrentReaderSection = () => 91;
      expect(controller.currentCue?.text, 'a');

      controller.holdChapterTransition();
      controller.debugUpdateCueForPosition(1500);
      expect(
        controller.chapterTransitionHeldForTesting,
        isTrue,
        reason: '「当前章 == cue 章」在回执之前就成立，不是落地证据',
      );
      expect(controller.currentCue?.text, 'a');

      controller.notifySectionRestoreCompleted(
        currentReaderSection: 91,
        success: true,
      );
      expect(controller.chapterTransitionHeldForTesting, isFalse);
      controller.debugUpdateCueForPosition(1500);
      expect(
        controller.currentCue?.text,
        'b',
        reason: '回执释放守卫后 cue 推进恢复，高亮不再冻结在章首',
      );
    });

    test('reader 还在别的章：守卫保持；导航中止信号释放', () {
      final AudiobookPlayerController controller = AudiobookPlayerController();
      addTearDown(controller.dispose);

      controller.setChapterCues(<AudioCue>[
        _cue('a', startMs: 0, section: 90),
        _cue('b', startMs: 1000, section: 90),
      ]);
      controller.getCurrentReaderSection = () => 89;
      controller.holdChapterTransition();
      controller.debugUpdateCueForPosition(1500);

      expect(controller.chapterTransitionHeldForTesting, isTrue);
      expect(
        controller.currentCue?.text,
        'a',
        reason: '守卫期间不得推进 cue（否则 positionStream 每 tick 重发跨章）',
      );

      // reader 的导航中止（装载失败 / 兜底超时 / 加载错误）→ _failNavigation。
      controller.abortChapterTransition();
      expect(controller.chapterTransitionHeldForTesting, isFalse);
      controller.debugUpdateCueForPosition(1500);
      expect(controller.currentCue?.text, 'b');
    });

    test('换 cue 列表：守卫期间只换列表、当前 cue 冻结（BUG-2529 既有语义）', () {
      final AudiobookPlayerController controller = AudiobookPlayerController();
      addTearDown(controller.dispose);

      controller.setChapterCues(<AudioCue>[
        _cue('old', startMs: 0, section: 90),
      ]);
      controller.getCurrentReaderSection = () => 91;
      controller.holdChapterTransition();

      controller.setChapterCues(<AudioCue>[
        _cue('new', startMs: 5000, section: 91),
      ]);

      expect(
        controller.chapterTransitionHeldForTesting,
        isTrue,
        reason: '新列表属于 reader 当前章也不是落地证据',
      );
      expect(controller.currentCue?.text, 'old');

      // 落地回执到了：按新列表重算，当前句换成新章的那一句。守卫期间换列表时
      // _currentCueIndex 若仍指旧列表的下标，会与新列表同下标的句子「撞号」，
      // 重算被判成「cue 未变」而早退，高亮永远停在旧章那一句。
      controller.notifySectionRestoreCompleted(
        currentReaderSection: 91,
        success: true,
      );
      controller.debugUpdateCueForPosition(5100);
      expect(controller.currentCue?.text, 'new');
    });
  });

  group('装配：面板「章节」tab 跳章与定音频是一次操作', () {
    test('reader_audiobook_panel 先暂挂自动跨章，跳章后由本处 seek', () {
      // 去空白比较：调用点会被 dart format 折行。
      final String panel = File(
        'lib/src/reader/reader_audiobook_panel.dart',
      ).readAsStringSync().replaceAll(RegExp(r'\s+'), '');
      final int hold = panel.indexOf('ctrl.holdCrossChapterUntilCallerSeek();');
      final int jump = panel.indexOf(
        'awaitwidget.onJumpSection(entry.index,entry.fragment);',
        hold,
      );
      final int seek = panel.indexOf(
        'awaitctrl.skipToCue(first,callerPositionsReader:true,);',
        jump,
      );
      expect(hold, isNonNegative, reason: '跳章在飞期间按旧章位置判出的跨章就是回弹');
      expect(jump, greaterThan(hold));
      expect(seek, greaterThan(jump), reason: '面板自己负责跳章，紧随的 seek 不得再当自动跨章发一次');
    });
  });
}

AudioCue _cue(String text, {required int startMs, required int section}) {
  return AudioCue()
    ..id = null
    ..bookKey = 'book'
    ..chapterHref = 'chapter-$section'
    ..sentenceIndex = startMs ~/ 1000
    ..textFragmentId = SubtitleRematchCodec.encodeHit(
      sectionIndex: section,
      normCharStart: 0,
      normCharEnd: text.length,
    )
    ..text = text
    ..startMs = startMs
    ..endMs = startMs + 1000
    ..audioFileIndex = 0;
}
