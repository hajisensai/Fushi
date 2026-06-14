import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// TODO-354 ③ 源码守卫：书架底栏「正在听书」迷你条上必须有一个**真启停 app 外悬浮
/// 字幕窗口**的「悬浮字幕」开关（不是只翻 bool）。
///
/// 迷你条需要活动 [AudiobookSession] + 真 AppModel 才能渲染，host 上不便起完整
/// 实例；这里钉住载重接线：①开关存在且走 [AppModel.toggleFloatingLyricFromControls]
/// （拉起/隐藏悬浮窗 + 偏好读写的单一收口）；②按 native 后端可用性平台门控（仅
/// Android/Windows，其余桌面优雅降级隐藏）。任何静默移除/降级成纯 bool 的重构都会被
/// 这里逮住。
void main() {
  late String source;

  setUpAll(() {
    source = File('lib/src/media/audiobook/now_listening_mini_bar.dart')
        .readAsStringSync();
  });

  test(
      'mini bar wires the floating-lyric toggle to toggleFloatingLyricFromControls',
      () {
    expect(
      source.contains('toggleFloatingLyricFromControls'),
      isTrue,
      reason: '开关必须走真正拉起/隐藏悬浮窗的收口，而非只翻偏好 bool',
    );
    expect(
      source.contains('floating_lyric_toggle_action'),
      isTrue,
      reason: '开关用「悬浮字幕」标签',
    );
  });

  test('floating-lyric toggle is gated to platforms with a native back-end',
      () {
    // native 悬浮窗后端只在 Android / Windows（floating_lyric_channel.isSupported），
    // 其余桌面必须隐藏开关而不是给一个点了无效的按钮。
    expect(
      source.contains('Platform.isAndroid || Platform.isWindows'),
      isTrue,
      reason: '开关须按 native 后端可用性平台门控（仅 Android/Windows）',
    );
  });
}
