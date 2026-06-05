import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki_audio/hibiki_audio.dart';

/// BUG-061：「从本句播放」三段跳。`preload:false` 跨文件 seek 的加载期
/// positionStream 会先吐瞬态位置（0 / 旧文件章首），逐 tick 触发跨章/reveal。
/// 抑制窗的放行判据由纯谓词 [reachedExplicitSeekTargetForTesting] 决定：
/// 只有当 player 已切到目标音频文件、且位置到达目标(减容差)时才算「落定」，
/// 此前的瞬态 tick 一律抑制。
void main() {
  group('explicit-seek transient suppression predicate (BUG-061)', () {
    const int tol = 300;

    test('player 仍停在旧音频文件(index 未切) → 未落定(抑制)', () {
      expect(
        AudiobookPlayerController.reachedExplicitSeekTargetForTesting(
          currentFileIndex: 0,
          posMs: 999999,
          targetFileIndex: 1,
          targetMs: 5000,
          toleranceMs: tol,
        ),
        isFalse,
      );
    });

    test('已切到目标文件但位置仍在加载期(0) → 未落定(抑制)', () {
      expect(
        AudiobookPlayerController.reachedExplicitSeekTargetForTesting(
          currentFileIndex: 1,
          posMs: 0,
          targetFileIndex: 1,
          targetMs: 5000,
          toleranceMs: tol,
        ),
        isFalse,
      );
    });

    test('目标文件 + 位置到达 target-容差 → 落定(放行)', () {
      expect(
        AudiobookPlayerController.reachedExplicitSeekTargetForTesting(
          currentFileIndex: 1,
          posMs: 5000 - tol,
          targetFileIndex: 1,
          targetMs: 5000,
          toleranceMs: tol,
        ),
        isTrue,
      );
    });

    test('目标文件 + 位置已越过 target → 落定(放行)', () {
      expect(
        AudiobookPlayerController.reachedExplicitSeekTargetForTesting(
          currentFileIndex: 1,
          posMs: 5200,
          targetFileIndex: 1,
          targetMs: 5000,
          toleranceMs: tol,
        ),
        isTrue,
      );
    });
  });

  // 源码守卫：抑制窗是「立旗(skipToCue/playCueOnce) + 顶部 guard(_updateCurrentCue)」
  // 两段接线，任一段被回归删掉就会让三段跳复发。
  group('explicit-seek suppression wiring guard (BUG-061)', () {
    test('skipToCue / playCueOnce 起 seek 前都立旗，_updateCurrentCue 顶部按谓词放行',
        () {
      final String src = File(
        '../packages/hibiki_audio/lib/src/audiobook/audiobook_controller.dart',
      ).readAsStringSync();

      // 两条显式 seek 路径都要立旗（至少 2 次）。
      expect(
        RegExp(r'_beginExplicitSeek\(').allMatches(src).length,
        greaterThanOrEqualTo(2),
        reason: 'skipToCue 与 playCueOnce 都要在 seek 前 _beginExplicitSeek',
      );
      // _updateCurrentCue 顶部据 _explicitSeekInFlight 抑制瞬态 tick。
      expect(src.contains('if (_explicitSeekInFlight)'), isTrue,
          reason: '_updateCurrentCue 顶部要有显式 seek 抑制 guard');
      // guard 调谓词决定落定放行。
      expect(src.contains('reachedExplicitSeekTargetForTesting('), isTrue,
          reason: '放行判据必须走纯谓词');
    });
  });
}
