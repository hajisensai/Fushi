import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// BUG-374 源码守卫（vendored media_kit 补丁）：桌面控制条的「点画面播放/暂停」
/// （`playAndPauseOnTap`）必须把 `playOrPause()` 执行在 **`onTap`**（手势竞技场裁决后、
/// 仅当本 GestureDetector 胜出才触发），而非 **`onTapDown`**（指针落下即触发、不等裁决）。
///
/// 根因：原实现把 `playOrPause()` 绑在 `onTapDown`。点叠在画面上的控制按钮**边缘/内边距**
/// 时，按钮 tap recognizer 与这个祖先 GestureDetector 同时进竞技场，祖先 `onTapDown` 抢先
/// 执行 `playOrPause()`（onTapDown 不等竞技场裁决谁最终赢），导致「点按钮边缘」既按了按钮
/// 又误触发播放/暂停。改在 `onTap` 执行：按钮（或任何后代 tap recognizer）认领该 tap 时，
/// 祖先 `onTap` 不会触发，消除穿透；`onTapDown` 退化为只记录该 tap 是否落在播放/暂停可触发
/// 区域（避开底部进度条区），由 `onTap` 消费。
///
/// 真实手势竞技场时序跑不了 headless，故锁 vendored 源码结构不变量。
void main() {
  final File desktop = File(
    '../third_party/media_kit_video/lib/media_kit_video_controls/src/controls/material_desktop.dart',
  );
  // 触屏分流补丁（Surface）后，点击层搬进了 MaterialDesktopTapRouter：
  // onTapDown 只记资格 + 指针类型，onTap 才按 resolveDesktopControlsTap 决定动作。
  final File router = File(
    '../third_party/media_kit_video/lib/media_kit_video_controls/src/controls/widgets/desktop_tap_router.dart',
  );

  late String src;
  late String routerSrc;
  setUpAll(() {
    expect(desktop.existsSync(), isTrue,
        reason: 'vendored media_kit material_desktop.dart 必须存在');
    expect(router.existsSync(), isTrue,
        reason: 'vendored media_kit desktop_tap_router.dart 必须存在');
    src = desktop.readAsStringSync().replaceAll('\r\n', '\n');
    routerSrc = router.readAsStringSync().replaceAll('\r\n', '\n');
  });

  test('动作执行在 onTap（竞技场裁决后），onTapDown 只记录资格', () {
    final int tapDownIdx = routerSrc.indexOf('onTapDown: !tapEnabled');
    expect(tapDownIdx, greaterThanOrEqualTo(0), reason: '路由层需有 onTapDown 记录资格');
    final int onTapIdx = routerSrc.indexOf('onTap: !tapEnabled', tapDownIdx);
    expect(onTapIdx, greaterThan(tapDownIdx),
        reason: 'BUG-374：必须有 onTap 分支承载竞技场裁决后的动作');
    final int tapUpIdx = routerSrc.indexOf('onTapUp: widget.onTapUp', onTapIdx);
    expect(tapUpIdx, greaterThan(onTapIdx), reason: '需有 onTapUp 透传作为段终点');

    // onTapDown 块内**不得**执行动作（抢跑根因），只记录资格与指针类型。
    final String tapDownBlock = routerSrc.substring(tapDownIdx, onTapIdx);
    expect(tapDownBlock.contains('onAction('), isFalse,
        reason: 'BUG-374：onTapDown 不得执行动作（抢跑穿透）');
    expect(tapDownBlock.contains('_playPauseTapEligible ='), isTrue,
        reason: 'onTapDown 应只记录 _playPauseTapEligible 资格');
    expect(tapDownBlock.contains('_tapKind = details.kind'), isTrue,
        reason: 'onTapDown 应记录指针类型供 onTap 分流');

    // onTap 块（onTap..onTapUp）才是裁决后决定并执行动作的地方。
    final String onTapBlock = routerSrc.substring(onTapIdx, tapUpIdx);
    expect(onTapBlock.contains('resolveDesktopControlsTap('), isTrue,
        reason: 'onTap 必须经 resolveDesktopControlsTap 决定动作');
    expect(onTapBlock.contains('_playPauseTapEligible'), isTrue,
        reason: 'onTap 应读 _playPauseTapEligible');
    expect(onTapBlock.contains('widget.onAction(action)'), isTrue,
        reason: 'onTap 才把动作交给控制条 State');
  });

  test('控制条 State 把 playOrPause 动作落到 player.playOrPause()', () {
    final int routerIdx = src.indexOf('child: MaterialDesktopTapRouter(');
    expect(routerIdx, greaterThanOrEqualTo(0),
        reason: '桌面控制条点击层必须经 MaterialDesktopTapRouter');
    final int onActionIdx = src.indexOf('onAction:', routerIdx);
    final int tapUpIdx = src.indexOf('onTapUp:', onActionIdx);
    expect(onActionIdx, greaterThan(routerIdx));
    expect(tapUpIdx, greaterThan(onActionIdx));
    final String onActionBlock = src.substring(onActionIdx, tapUpIdx);
    expect(onActionBlock.contains('player.playOrPause()'), isTrue,
        reason: '鼠标单击播放/暂停行为不得丢失');
    // 底栏带排除（不在进度条附近误暂停）仍由 State 提供几何判据。
    final String routerBlock = src.substring(routerIdx, onActionIdx);
    expect(routerBlock.contains('subtitleVerticalShiftOffset'), isTrue,
        reason: '播放/暂停资格仍需排除底部进度条区域');
  });

  test('路由 State 持有 _playPauseTapEligible 字段', () {
    expect(routerSrc.contains('bool _playPauseTapEligible = false;'), isTrue,
        reason: '需有 onTapDown→onTap 之间传递资格的实例字段');
  });
}
