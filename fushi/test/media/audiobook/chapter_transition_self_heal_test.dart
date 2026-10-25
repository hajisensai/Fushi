import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/audiobook/audiobook_controller.dart';
import 'package:fushi_audio/fushi_audio.dart';

/// 跨章守卫自愈：真机 ch.89 从有声书面板「章节」tab 跳章后，音频已往前走了
/// 9 分钟、高亮仍冻在章首，`/tmp/fushi.log` 里 reader 停在 section 91、
/// normOffset 反复清零、cue 不再推进。
///
/// 机制：`_chapterTransition` 是「为这一次在飞的跨章导航」竖起的，正常只在
/// reader 的 `notifySectionRestoreCompleted` 里解除。该回执可能被代际判旧丢弃
/// 或根本没送到，而 reader **已经**停在 cue 所属章——守卫继续持着就永久挡住
/// `_updateCurrentCue` / `setChapterCues` / `_maybeEmitCrossChapter`。
///
/// 修复判据：守卫期间若 `getCurrentReaderSection() == cue.sectionIndex`，说明那次
/// 导航已经落地，守卫必须自愈释放，且只在此时释放（reader 还在旧章时保持冻结，
/// 否则跨章途中会重复发 `onCrossChapter`）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('跨章守卫自愈', () {
    test('tick：reader 已在 cue 所属章 → 释放守卫并推进 cue', () {
      final AudiobookPlayerController controller = AudiobookPlayerController();
      addTearDown(controller.dispose);

      final List<AudioCue> cues = <AudioCue>[
        _cue('a', startMs: 0, section: 91),
        _cue('b', startMs: 1000, section: 91),
      ];
      controller.setChapterCues(cues);
      controller.getCurrentReaderSection = () => 91;
      expect(controller.currentCue?.text, 'a');

      controller.holdChapterTransition();
      controller.debugUpdateCueForPosition(1500);

      expect(
        controller.chapterTransitionHeldForTesting,
        isFalse,
        reason: 'reader 已停在 section 91、回执丢了，守卫必须自愈释放',
      );
      expect(
        controller.currentCue?.text,
        'b',
        reason: '释放后 cue 推进恢复，高亮不再冻结在章首',
      );
    });

    test('tick：reader 还在别的章 → 守卫保持，cue 冻结（跨章仍在飞）', () {
      final AudiobookPlayerController controller = AudiobookPlayerController();
      addTearDown(controller.dispose);

      controller.setChapterCues(<AudioCue>[
        _cue('a', startMs: 0, section: 90),
        _cue('b', startMs: 1000, section: 90),
      ]);
      controller.getCurrentReaderSection = () => 89;
      controller.holdChapterTransition();
      controller.debugUpdateCueForPosition(1500);

      expect(
        controller.chapterTransitionHeldForTesting,
        isTrue,
        reason: 'reader 还没落到 cue 所属章，导航确实在飞，守卫不能放',
      );
      expect(
        controller.currentCue?.text,
        'a',
        reason: '守卫期间不得推进 cue（否则 positionStream 每 tick 重发跨章）',
      );
    });

    test('换 cue 列表：新列表属于 reader 当前章 → 释放守卫并装载', () {
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
        isFalse,
        reason: '逐章 cue 已属于 reader 挂载的章，守卫不能继续挡装载',
      );
      controller.debugUpdateCueForPosition(5100);
      expect(controller.currentCue?.text, 'new');
    });

    test('换 cue 列表：新列表属于别的章 → 守卫保持、不重算', () {
      final AudiobookPlayerController controller = AudiobookPlayerController();
      addTearDown(controller.dispose);

      controller.setChapterCues(<AudioCue>[
        _cue('old', startMs: 0, section: 90),
      ]);
      controller.getCurrentReaderSection = () => 89;
      controller.holdChapterTransition();

      controller.setChapterCues(<AudioCue>[
        _cue('new', startMs: 5000, section: 91),
      ]);

      expect(controller.chapterTransitionHeldForTesting, isTrue);
      expect(
        controller.currentCue?.text,
        'old',
        reason: '守卫期间只换列表、当前 cue 冻结（BUG-2529 既有语义）',
      );
    });
  });

  group('装配：章节 tab 跳句走 manualTarget', () {
    test('reader_audiobook_panel 跳章后的 skipToCue 标记为手动目标', () {
      final String panel = File(
        'lib/src/reader/reader_audiobook_panel.dart',
      ).readAsStringSync();
      expect(
        panel.contains('skipToCue(first, manualTarget: true)'),
        isTrue,
        reason:
            '面板已手动导航到目标章，紧随的 seek 不得再当自动跨章发一次；'
            '否则紧跟的 _maybeEmitCrossChapter 会把同一条 cue 当成新跨章目标',
      );
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
