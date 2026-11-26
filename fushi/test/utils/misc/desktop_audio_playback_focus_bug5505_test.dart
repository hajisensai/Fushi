import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/utils/misc/desktop_audio_playback.dart';

/// BUG-5505（反馈 E--G5mP95S）：Android 上复习卡发音 / 自动播放走共用 just_audio 播放器，
/// 缺省每次 play() 激活 audio_session = 申请 AUDIOFOCUS_GAIN，后台别家 app 的音乐每读一个词
/// 就被暂停再恢复。读一个词不申请焦点（BUG-3311 的意图）。
void main() {
  test('Android 上共用预览播放器不激活音频会话；其余平台照旧', () {
    expect(previewPlayerHandlesAudioSession(isAndroid: true), isFalse);
    expect(previewPlayerHandlesAudioSession(isAndroid: false), isTrue);
  });

  test('共用播放器按上面的判据构造（不回退成 just_audio 缺省）', () {
    final String src = File(
      'lib/src/utils/misc/desktop_audio_playback.dart',
    ).readAsStringSync();
    final Iterable<RegExpMatch> ctors = RegExp(
      r'AudioPlayer\(([^)]*)\)',
    ).allMatches(src);
    expect(ctors, isNotEmpty);
    for (final RegExpMatch m in ctors) {
      expect(
        m.group(1),
        contains(
          'handleAudioSessionActivation: previewPlayerHandlesAudioSession',
        ),
        reason: m.group(0),
      );
    }
  });
}
