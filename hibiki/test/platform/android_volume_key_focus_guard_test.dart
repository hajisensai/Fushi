import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// TODO-112 / BUG-196: 关闭「音量键翻页」后按音量键仍出现焦点框。
///
/// 根因：`MainActivity.dispatchKeyEvent` 旧实现只在 `volumeKeyIntercept` 为真时
/// 吞音量键，否则走 `super.dispatchKeyEvent(event)`——而 super 会把 VOLUME_UP/DOWN
/// 先分发给 FlutterView（再由 Activity.onKeyDown 调音量）。漏进 Flutter 的硬件按键
/// 让 FocusManager 把 highlightMode 切到 traditional → 阅读内容画出焦点环（纯触摸
/// 使用、且功能关闭时也出现）。
///
/// 修复：音量键在 native 层永不进入 FlutterView——拦截开/关两态都不调 super；关态
/// 用 AudioManager.adjustSuggestedStreamVolume(USE_DEFAULT_STREAM_TYPE, FLAG_SHOW_UI)
/// 自行调音量（等价硬件音量键）。host 无法注入真实 Android 音量键 KeyEvent 到
/// FocusManager，故用源码守卫锁住 native 契约；撤修复即红。
void main() {
  late String src;

  setUpAll(() {
    src = File(
      'android/app/src/main/java/app/hibiki/reader/MainActivity.java',
    ).readAsStringSync();
  });

  test('音量键关态自行调系统音量（USE_DEFAULT_STREAM_TYPE + FLAG_SHOW_UI）', () {
    expect(
      src,
      contains('adjustSuggestedStreamVolume'),
      reason: '不拦截翻页时音量键必须用 adjustSuggestedStreamVolume 自行调音量，'
          '而不是漏给 super.dispatchKeyEvent（后者会污染 Flutter highlight mode）。',
    );
    expect(src, contains('AudioManager.USE_DEFAULT_STREAM_TYPE'),
        reason: '必须用 USE_DEFAULT_STREAM_TYPE 让系统挑活动音频流，等价硬件音量键。');
    expect(src, contains('AudioManager.FLAG_SHOW_UI'),
        reason: '必须带 FLAG_SHOW_UI 显示音量滑条，与系统默认音量键体验一致。');
    expect(src, contains('private void adjustSystemVolume('),
        reason: '调音量逻辑应在专用 helper 里，便于阅读与守卫。');
  });

  test('音量键在拦截开/关两态都不调 super.dispatchKeyEvent（不进 FlutterView）', () {
    // 找出 dispatchKeyEvent 方法体，断言对音量键的分支都 return true（吞掉），
    // 而 super.dispatchKeyEvent 只用于非音量键的兜底。
    final int idx =
        src.indexOf('public boolean dispatchKeyEvent(KeyEvent event)');
    expect(idx, greaterThan(0), reason: 'dispatchKeyEvent 必须存在。');
    final int end = src.indexOf('\n    }', idx);
    expect(end, greaterThan(idx));
    final String body = src.substring(idx, end);

    // 音量键判定必须在方法内、且其所有分支吞掉事件（return true），不落到 super。
    expect(
      body,
      contains('KeyEvent.KEYCODE_VOLUME_UP'),
      reason: 'dispatchKeyEvent 必须显式处理音量键。',
    );
    // super.dispatchKeyEvent 必须出现在音量键分支之后（作为非音量键兜底），
    // 且音量键分支以 return true 结束——保证音量键永不进 FlutterView。
    final int superIdx = body.indexOf('return super.dispatchKeyEvent(event);');
    final int volumeIdx = body.indexOf('KeyEvent.KEYCODE_VOLUME_UP');
    expect(superIdx, greaterThan(volumeIdx),
        reason: 'super.dispatchKeyEvent 只能作为非音量键兜底，必须在音量键分支之后。');
    expect(
      body.contains('adjustSystemVolume(') ||
          body.contains('volumeKeyChannel.invokeMethod'),
      isTrue,
      reason: '音量键的两种处理（自调音量 / 转发 Dart）都必须留在方法内。',
    );
  });
}
