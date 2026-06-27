import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// TODO-916 源码守卫（vendored media_kit 补丁，移动版 material.dart）：
/// 「显示控制条」必须走 `GestureDetector.onTap`（手势竞技场裁决后才触发），
/// **不得**退回到裸 `Listener(onPointerDown: ... => onTap())` / `_handlePointerDown`
/// （指针落下即触发、不等竞技场裁决）。
///
/// 根因：原实现把 toggle 绑在 `Listener.onPointerDown` 上，任何按下都同步唤起控制条。
/// 长按加速的初始 down 因此先误触发 `onTap()`，控制条闪一下再被长按收起（症状②）；
/// 同一次 down 还把字幕盒 200ms 避让动画推上去，使点字幕命中目标在 tap 中途移动、
/// 播放中点不中（症状④放大器）。改走 `onTap` 后长按/双击胜出时不触发，控制条不再闪。
///
/// 真实竞技场时序 headless 跑不了，故锁 vendored 源码结构不变量。
void main() {
  final File mobile = File(
    '../third_party/media_kit_video/lib/media_kit_video_controls/src/controls/material.dart',
  );

  late String src;
  setUpAll(() {
    expect(mobile.existsSync(), isTrue,
        reason: 'vendored media_kit material.dart 必须存在');
    src = mobile.readAsStringSync().replaceAll('\r\n', '\n');
  });

  test('显示控制条不再走 Listener.onPointerDown / _handlePointerDown', () {
    // 不得再有把 onPointerDown 接到 toggle 的裸 Listener。
    expect(
      RegExp(r'onPointerDown:\s*\(event\)\s*=>\s*_handlePointerDown').hasMatch(src),
      isFalse,
      reason: 'TODO-916：toggle 必须脱离 Listener.onPointerDown（不等竞技场裁决）',
    );
    // 死方法 _handlePointerDown 应已删除（否则 unused_element 且回归风险）。
    expect(src.contains('_handlePointerDown'), isFalse,
        reason: 'TODO-916：_handlePointerDown 应随接线一起删除');
  });

  test('显示控制条改由中央 GestureDetector.onTap 承载', () {
    // 中央手势栈的 GestureDetector 必须有 onTap: onTap。
    expect(src.contains('onTap: onTap'), isTrue,
        reason: 'TODO-916：控制条 toggle 必须迁到竞技场裁决后的 onTap');
    // onTap 实现仍在（toggle visible + publish + shiftSubtitle）。
    expect(RegExp(r'void onTap\(\)\s*\{').hasMatch(src), isTrue,
        reason: 'onTap 实现必须保留');
    // 双击 seek 用的 _tapPosition 仍被赋值（不得误删）。
    expect(src.contains('_tapPosition = details.localPosition;'), isTrue,
        reason: '双击 seek 的 _tapPosition 赋值不得误删');
  });
}
