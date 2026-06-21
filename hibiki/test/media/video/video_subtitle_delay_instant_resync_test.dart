import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/media/video/video_player_controller.dart';
import 'package:hibiki_audio/hibiki_audio.dart';

/// BUG-373 行为守卫：调字幕音画延迟（`setDelayMs`）后，当前显示的**文本字幕**必须
/// **立即**按新偏移重算并通知，而不是等下一个 125ms tick。
///
/// 根因（修复前）：`setDelayMs` 只改 `_delayMs` + 下发 libmpv `sub-delay`，既不
/// 重算当前 cue 也不 `notifyListeners`。文本字幕偏移在 Dart 侧靠
/// `effectiveSubtitlePositionMs(pos, delay)` 扣减，当前 cue 只在 125ms 周期 tick
/// 的 `_syncCueForPosition` 里按新 delay 重算——暂停定格微调时连 tick 都不推进位置，
/// 表现为「调了没反馈」。
///
/// 修复：`setDelayMs` 改延迟后立即跑 `_resyncTextSubtitleAfterDelayChange`
/// （= `_syncCueForPosition(pos, persistPosition: false)`）。media_kit 在 headless
/// 跑不起真 `Player`（`positionMs` 读 `_player.state.position`），故经
/// `debugSetDelayMsForTesting(delay, positionMs:)` 喂显式位置走**完全同一条**重算路径。
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
  group('BUG-373 字幕延迟即时重算', () {
    test('暂停定格调延迟，当前文本 cue 立即按新偏移变化（不等 tick）', () {
      final VideoPlayerController c = VideoPlayerController();
      addTearDown(c.dispose);
      c.setCues(<AudioCue>[_cue(0, 0, 1000), _cue(1, 2000, 3000)]);

      // delay=0：位置 2500ms → effectiveMs=2500 落在 cue1（2000..3000）。
      c.debugUpdateCueForPosition(2500);
      expect(c.currentCueIndex, 1);
      expect(c.currentCue!.text, 'line1');

      int notifyCount = 0;
      c.addListener(() => notifyCount++);

      // 位置定格不变（暂停态），把字幕整体推后 2000ms（delay=+2000，正=字幕更晚）：
      // effectiveMs = 2500 - 2000 = 500 → 应**立即**落回 cue0（0..1000）。
      c.debugSetDelayMsForTesting(2000, positionMs: 2500);
      expect(c.currentCueIndex, 0,
          reason: 'BUG-373：调延迟后当前 cue 必须立即按新偏移重算，不等 125ms tick');
      expect(c.currentCue!.text, 'line0');
      expect(notifyCount, greaterThan(0),
          reason: '当前 cue 变化必须 notifyListeners，字幕 overlay 才会同帧重建');
    });

    test('调延迟使 effective 落进 gap，当前字幕立即清空', () {
      final VideoPlayerController c = VideoPlayerController();
      addTearDown(c.dispose);
      c.setCues(<AudioCue>[_cue(0, 0, 1000), _cue(1, 2000, 3000)]);

      // delay=0：位置 2500ms → cue1 显示。
      c.debugUpdateCueForPosition(2500);
      expect(c.currentCueIndex, 1);

      // 把字幕推后 1000ms（delay=+1000）：effectiveMs=1500 落进 cue0/cue1 之间的 gap
      // → 当前字幕应立即消失（findCueIndex 返回 -1 的清空契约，BUG-074）。
      c.debugSetDelayMsForTesting(1000, positionMs: 2500);
      expect(c.currentCueIndex, -1, reason: '调延迟落进 gap 应立即清空当前字幕');
      expect(c.currentCue, isNull);
    });
  });
}
