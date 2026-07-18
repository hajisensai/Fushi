import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki_audio/hibiki_audio.dart';

/// BUG-890：开着「跟随音频」+「图片等待」阅读有声书，朗读跨过插图时图片等待自动
/// 暂停几秒。用户在这几秒窗口内手动向前翻页（想预读/跨过 あとがき 的插图章），
/// 图片等待到点自动恢复播放时，旧逻辑无条件 `snapReaderToAudio()` —— 它清掉
/// `_manualReaderOverrideCue` 护栏并 `_maybeEmitCrossChapter(bypassPlayGuard:true)`，
/// 把 reader 强行拽回音频所在章，吃掉用户手动翻到的位置。
///
/// 根因：跨章跟随/强制 reveal 未像章内滚动（`shouldRevealCurrentCue` 有 playing 门控）
/// 那样受控，只靠会被 `snapReaderToAudio` 清空的一次性护栏；图片等待的自动恢复正好
/// 清掉它。
///
/// 修复：图片等待自动恢复尊重手动导航——窗口内手动翻页离开则不强制 snap，让跟随只
/// 在播放推进到下一句时经既有护栏自然接管（正是用户诉求）。
void main() {
  group('BUG-890 图片等待自动恢复的 snap 决策（纯谓词）', () {
    test('窗口内未手动翻页 → 恢复时仍 snap 回音频位（老行为不变）', () {
      expect(
        AudiobookPlayerController.shouldSnapAfterImagePauseResume(
          readerMovedDuringPause: false,
        ),
        isTrue,
      );
    });

    test('窗口内手动翻页离开插图那句 → 恢复时不 snap（保住用户手动位置）', () {
      expect(
        AudiobookPlayerController.shouldSnapAfterImagePauseResume(
          readerMovedDuringPause: true,
        ),
        isFalse,
      );
    });
  });

  group('BUG-890 源码守卫：接线不能被回退', () {
    final String source = File(
            '../packages/hibiki_audio/lib/src/audiobook/audiobook_controller.dart')
        .readAsStringSync();

    test('图片等待窗口内手动翻页会置标志', () {
      expect(
        source,
        contains(
            'if (isImagePaused) {\n      _readerMovedDuringImagePause = true;'),
        reason: 'noteManualReaderNavigation 必须在图片等待在途时记录用户已手动离开。',
      );
    });

    test('图片等待自动恢复经 shouldSnapAfterImagePauseResume 门控 snap', () {
      expect(
        source,
        contains('if (shouldSnapAfterImagePauseResume('),
        reason: 'triggerImagePause 定时器恢复播放后必须用该谓词门控 snapReaderToAudio，'
            '不能无条件 snap。',
      );
    });

    test('标志在生命周期各点复位，杜绝泄漏', () {
      // arm 定时器时复位
      expect(
        source,
        contains(
            '_readerMovedDuringImagePause = false;\n    unawaited(_player.pause());'),
        reason: 'triggerImagePause arm 时必须复位标志。',
      );
      // arm / load / pause 至少三处复位标志（String 实现 Pattern，allMatches 为原生）
      expect(
        '_readerMovedDuringImagePause = false;'.allMatches(source).length >= 3,
        isTrue,
        reason: 'arm / load / pause 至少三处复位标志，防止跨轮泄漏。',
      );
    });
  });
}
