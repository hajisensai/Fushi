import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 源码守卫（BUG-032）：退到后台时必须**连同音频播放位置一起 flush**。
///
/// dispose 经 `_audiobookController.dispose()` 会 force-save 音频位置，但硬杀
/// 场景 dispose 不执行。后台生命周期共享的 `_syncAndFlushPosition` 必须调用
/// 控制器的 `flushPosition()`，否则歌词模式被杀后音频进度归零。同时钉住两条
/// 控制器初始化路径的 `onPositionWrite` 仍把写库 Future 交回去（用 `=>` 转发，
/// 不是 `{ ... }` 吞掉返回值），否则 flushPosition 的 await 等不到真正落库。
void main() {
  final String src = File(
    'lib/src/pages/implementations/reader_hibiki_page.dart',
  ).readAsStringSync();

  test('background sync-flush also flushes the audiobook playback position',
      () {
    final RegExpMatch? body = RegExp(
      r'Future<void> _syncAndFlushPosition\(\) async \{(.*?)\n  \}',
      dotAll: true,
    ).firstMatch(src);
    expect(body, isNotNull, reason: '找不到 _syncAndFlushPosition 方法体');
    expect(
      body!.group(1),
      contains('_audiobookController?.flushPosition()'),
      reason: '后台 flush 必须把音频位置一并写穿（BUG-032）',
    );
  });

  test('both audio init paths forward onPositionWrite to the repo future', () {
    // `=> repo.updatePositionMs(...)` / `=> abRepo.updatePositionMs(...)`：
    // 用箭头转发返回 Future<void>，flushPosition 才能 await 到落库。
    expect(
      RegExp(r'onPositionWrite = \([^)]*\) =>\s*\w+\.updatePositionMs\(')
          .allMatches(src)
          .length,
      greaterThanOrEqualTo(2),
      reason: '两条路径都要用箭头把 updatePositionMs 的 Future 交回给控制器',
    );
  });
}
