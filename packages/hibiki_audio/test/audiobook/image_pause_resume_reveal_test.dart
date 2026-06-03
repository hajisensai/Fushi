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
    expect(body, contains('_imagePauseTimer'),
        reason: '手动 play 须取消待恢复的图片暂停计时器（否则计时器到点不 snap）');
    expect(body, contains('snapReaderToAudio'),
        reason: '手动 play 须把视口从插图拉回当前 cue');
  });
}
