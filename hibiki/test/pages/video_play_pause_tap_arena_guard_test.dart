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

  late String src;
  setUpAll(() {
    expect(desktop.existsSync(), isTrue,
        reason: 'vendored media_kit material_desktop.dart 必须存在');
    src = desktop.readAsStringSync().replaceAll('\r\n', '\n');
  });

  test('playOrPause 执行在 onTap（竞技场裁决后），不在 onTapDown 抢跑', () {
    // 锚到那个带 playAndPauseOnTap 的 GestureDetector（onTapUp 处理全屏双击紧随其后）。
    final int tapDownIdx =
        src.indexOf('onTapDown: !_theme(context).playAndPauseOnTap');
    expect(tapDownIdx, greaterThanOrEqualTo(0),
        reason: '需有 playAndPauseOnTap 的 onTapDown');
    final int onTapIdx =
        src.indexOf('onTap: !_theme(context).playAndPauseOnTap', tapDownIdx);
    expect(onTapIdx, greaterThan(tapDownIdx),
        reason: 'BUG-374：必须新增 onTap 分支承载竞技场裁决后的播放/暂停');
    final int tapUpIdx = src.indexOf(
        'onTapUp: !_theme(context).toggleFullscreenOnDoublePress', onTapIdx);
    expect(tapUpIdx, greaterThan(onTapIdx), reason: '需有全屏双击 onTapUp 作为段终点');

    // onTapDown 块（onTapDown..onTap）内**不得**执行 playOrPause（抢跑根因），只记录资格。
    final String tapDownBlock = src.substring(tapDownIdx, onTapIdx);
    expect(tapDownBlock.contains('playOrPause()'), isFalse,
        reason: 'BUG-374：onTapDown 不得执行 playOrPause（抢跑穿透）');
    expect(tapDownBlock.contains('_playPauseTapEligible ='), isTrue,
        reason: 'onTapDown 应只记录 _playPauseTapEligible 资格，不执行播放/暂停');

    // onTap 块（onTap..onTapUp）才是裁决后执行 playOrPause 的地方。
    final String onTapBlock = src.substring(onTapIdx, tapUpIdx);
    expect(onTapBlock.contains('player.playOrPause()'), isTrue,
        reason: 'playOrPause 必须在 onTap（竞技场裁决后）执行');
    expect(onTapBlock.contains('_playPauseTapEligible'), isTrue,
        reason: 'onTap 应读 _playPauseTapEligible 决定是否播放/暂停');
  });

  test('State 类持有 _playPauseTapEligible 字段', () {
    expect(src.contains('bool _playPauseTapEligible = false;'), isTrue,
        reason: '需有 onTapDown→onTap 之间传递资格的实例字段');
  });
}
