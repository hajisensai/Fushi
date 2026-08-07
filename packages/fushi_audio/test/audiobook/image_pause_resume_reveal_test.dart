import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// BUG-007 gap2 续播守卫：图片暂停结束恢复播放后，必须把视口从插图拉回当前 cue
/// （插图后那句），否则 reveal 停在插图上、audio-follow 对不上当前句。
void main() {
  final String src = File(
    'lib/src/audiobook/audiobook_controller.dart',
  ).readAsStringSync();

  test('triggerImagePause resume re-reveals current cue via snapReaderToAudio',
      () {
    final int idx = src.indexOf('void triggerImagePause()');
    expect(idx, greaterThan(-1), reason: 'triggerImagePause 必须存在');
    final int end = src.indexOf('\n  /// ', idx);
    final String body = src.substring(idx, end > idx ? end : idx + 800);
    expect(body, contains('snapReaderToAudio'),
        reason: '恢复播放后须 snapReaderToAudio() 把视口拉回当前 cue');
  });

  test('manual play during image-pause cancels the pause timer and snaps back',
      () {
    final int idx = src.indexOf('Future<void> play()');
    expect(idx, greaterThan(-1), reason: 'play() 必须存在');
    final int end = src.indexOf('Future<void> pause()', idx);
    final String body = src.substring(idx, end > idx ? end : idx + 600);
    // TODO-2389：判据从「碰过 _imagePauseTimer」升级为「成对作废」。只 cancel
    // Timer 不 complete Completer 会让 awaitImageChapterPause 永久挂起，所以取消
    // 动作统一收敛到 _invalidateImageChapterPause()。
    expect(body, contains('_invalidateImageChapterPause()'),
        reason: '手动 play 须成对作废待恢复的图片暂停（Timer + Completer），'
            '否则计时器到点不 snap，且跨章停留的 await 永久挂起');
    expect(body, contains('isImagePaused'),
        reason: '在途判据须覆盖「已 pause、定时器尚未武装」的 Completer-only 窗口');
    expect(body, contains('snapReaderToAudio'),
        reason: '手动 play 须把视口从插图拉回当前 cue');
  });
}
