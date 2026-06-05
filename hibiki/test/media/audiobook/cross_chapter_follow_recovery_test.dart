import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki_audio/hibiki_audio.dart';

/// BUG-069：查词「从本句播放」跨多章，文字第一次只跟到一半（停在原章/中间章），
/// 第二次点才到位。根因不在音频（音频秒到位），在 reader 文字跟随：
///
/// `skipToCue` 跨章时会预置 `_currentCueIndex` 到目标 cue，但其内部
/// `_maybeEmitCrossChapter` 可能因 `!_hasPlayedOnce`（本会话首次播放）或
/// restore-in-flight 守卫被挡掉 → 文字不跳。之后 positionStream tick 进
/// `_updateCurrentCue`，因为 cue 没变（`chapterIdx == _currentCueIndex`）
/// 直接 `return`，**永不再做跨章检查** → 文字卡住，要用户再点一次重跑
/// `skipToCue` 才跳。
///
/// 修复：① 把跨章判据抽成纯谓词 [shouldCrossChapterForTesting]（含
/// `hasPlayedOnce` 守卫——正是首次被挡的原因）；② `_updateCurrentCue` 的
/// 「cue 未变」短路在「正在跟随播放」时补一次安静的跨章检查，让文字收敛。
void main() {
  group('cross-chapter follow decision predicate (BUG-069)', () {
    test('首次播放：reader 在原章、cue 在远章，但 !hasPlayedOnce → 不跳（这正是首次被挡）', () {
      expect(
        AudiobookPlayerController.shouldCrossChapterForTesting(
          cueSec: 8,
          currentSec: 1,
          followAudio: true,
          hasPlayedOnce: false,
        ),
        isFalse,
      );
    });

    test('已播过：reader 在原章、cue 在远章、follow 开 → 应跳（恢复路径据此收敛）', () {
      expect(
        AudiobookPlayerController.shouldCrossChapterForTesting(
          cueSec: 8,
          currentSec: 1,
          followAudio: true,
          hasPlayedOnce: true,
        ),
        isTrue,
      );
    });

    test('同章不跳（已同步时补检查为 no-op，避免 per-tick 抖动）', () {
      expect(
        AudiobookPlayerController.shouldCrossChapterForTesting(
          cueSec: 5,
          currentSec: 5,
          followAudio: true,
          hasPlayedOnce: true,
        ),
        isFalse,
      );
    });

    test('follow 关 → 不跳', () {
      expect(
        AudiobookPlayerController.shouldCrossChapterForTesting(
          cueSec: 8,
          currentSec: 1,
          followAudio: false,
          hasPlayedOnce: true,
        ),
        isFalse,
      );
    });

    test('reader 未就绪（currentSec < 0）→ 不跳', () {
      expect(
        AudiobookPlayerController.shouldCrossChapterForTesting(
          cueSec: 8,
          currentSec: -1,
          followAudio: true,
          hasPlayedOnce: true,
        ),
        isFalse,
      );
    });

    test('bypassPlayGuard：OFF→ON 主动回跳时即使 !hasPlayedOnce 也跳', () {
      expect(
        AudiobookPlayerController.shouldCrossChapterForTesting(
          cueSec: 8,
          currentSec: 1,
          followAudio: true,
          hasPlayedOnce: false,
          bypassPlayGuard: true,
        ),
        isTrue,
      );
    });
  });

  // 源码守卫：恢复路径是「_updateCurrentCue 的 cue-未变短路里补一次跨章检查」。
  // 若回归成裸 `return`，跨章跟随就不再收敛、复发「点两次」。
  group('cross-chapter follow recovery wiring guard (BUG-069)', () {
    late String src;

    setUpAll(() {
      src = File(
        '../packages/hibiki_audio/lib/src/audiobook/audiobook_controller.dart',
      ).readAsStringSync();
    });

    test('_updateCurrentCue 的 cue-未变分支在跟随播放时补 _maybeEmitCrossChapter', () {
      // cue 未变短路不能是裸 `if (chapterIdx == _currentCueIndex) return;`，
      // 必须在 playing 且非 playCueOnce 时补一次跨章检查。
      final RegExp recovery = RegExp(
        r'if \(chapterIdx == _currentCueIndex\) \{[\s\S]*?'
        r'_player\.playing[\s\S]*?_maybeEmitCrossChapter\([\s\S]*?\}',
      );
      expect(recovery.hasMatch(src), isTrue,
          reason: 'cue-未变短路必须在 playing 时补跨章检查（quiet），否则点两次复发');
      // 补检查不得带 playCueOnce 单句试听语义（_stopAtPositionMs 守卫）。
      expect(src.contains('_stopAtPositionMs == null'), isTrue,
          reason: '补检查应 gate 在非 playCueOnce（_stopAtPositionMs==null）');
    });

    test('跨章 emit 经纯谓词 shouldCrossChapterForTesting 决策', () {
      expect(src.contains('shouldCrossChapterForTesting('), isTrue,
          reason: '_maybeEmitCrossChapter 与恢复路径共用同一纯判据');
    });
  });
}
