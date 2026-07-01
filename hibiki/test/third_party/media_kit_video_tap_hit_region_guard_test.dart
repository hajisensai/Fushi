import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// TODO-1073 / BUG-498 源码守卫（vendored media_kit 补丁，移动版 material.dart）：
/// 「单击唤控制栏」的 tap 命中区必须覆盖**整个画面**，与防边缘误触竖滑的
/// 16px + [subtitleVerticalShiftOffset] 拖动 buffer **解耦**。
///
/// 根因（修前）：单一手势层 `Positioned.fill(bottom: 16.0 + subtitleVerticalShiftOffset)`
/// 把 `onTap`（toggle 控制栏）与拖动识别器揂在同一层。该底部内缩（屏底 80–130+px）
/// 本只为不劫持边缘竖滑，却把 `onTap` 命中区也从底部缩上去 → 控制栏隐藏时点画面
/// 底部/右下角落在死区、唤不出控制栏（Hibiki 外层 Listener 移动端不自做 toggle，
/// 靠 translucent 下探到本 fork，因此死区无人兜底）。
///
/// 修法：拆成两层——① 全画面 tap/long-press/double-tap 层（无 bottom 内缩，承载
/// `onTap: onTap`）；② 仅拖动识别器的 inset 层（保留 `bottom: 16.0 + ...` 边缘
/// buffer）；inset 拖动层在上并标 `HitTestBehavior.translucent`，让指针继续命中
/// 下方 tap 层，两层同进竞技场（边缘拖动归拖动、平单击归 onTap）。
///
/// 真实竞技场时序 / 命中几何 headless 跑不了，故锁 vendored 源码结构不变量。
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

  test('承载 onTap 的手势层不再对 tap 命中区施 bottom 内缩（全画面命中）', () {
    final int onTapIdx = src.indexOf('onTap: onTap');
    expect(onTapIdx, greaterThanOrEqualTo(0),
        reason: 'toggle 控制栏必须仍走 onTap: onTap');

    // 锚定承载 onTap 的那个 Positioned.fill 的起点（onTap 之前最近的 Positioned.fill）。
    final int tapLayerStart = src.lastIndexOf('Positioned.fill(', onTapIdx);
    expect(tapLayerStart, greaterThanOrEqualTo(0),
        reason: 'onTap 必须挂在一个 Positioned.fill 手势层里');

    // 该 tap 层从起点到 onTap 之间**不得**再出现 bottom 内缩
    // （尤其不得含 subtitleVerticalShiftOffset）——命中区必须是全画面。
    final String tapLayerHead = src.substring(tapLayerStart, onTapIdx);
    expect(tapLayerHead.contains('subtitleVerticalShiftOffset'), isFalse,
        reason: 'TODO-1073：tap 命中层不得再对底部施 subtitleVerticalShiftOffset 内缩');
    expect(RegExp(r'bottom:\s*16\.0').hasMatch(tapLayerHead), isFalse,
        reason: 'TODO-1073：tap 命中层不得再施 16px 底部内缩（那是拖动层的边缘 buffer）');
  });

  test('边缘拖动 buffer 迁到独立 inset 拖动层（保留 16px + shift 内缩且 translucent）', () {
    // 仍须存在一个带底部 buffer 的 inset 层承载竖滑/横滑（不回退边缘误触初衷）。
    final int dragBottomIdx =
        src.indexOf('bottom: 16.0 + subtitleVerticalShiftOffset,');
    expect(dragBottomIdx, greaterThanOrEqualTo(0),
        reason: '拖动层必须保留 16px + subtitleVerticalShiftOffset 边缘 buffer');

    final int dragLayerStart =
        src.lastIndexOf('Positioned.fill(', dragBottomIdx);
    expect(dragLayerStart, greaterThanOrEqualTo(0),
        reason: 'inset 拖动层应为一个 Positioned.fill');

    // 该 inset 层里应有拖动识别器，且**不得**承载 onTap（tap 已迁走）。
    final int nextPositioned = src.indexOf('Positioned.fill(', dragBottomIdx);
    final int dragLayerEnd = nextPositioned >= 0
        ? nextPositioned
        : src.indexOf('if (mount)', dragBottomIdx);
    expect(dragLayerEnd, greaterThan(dragBottomIdx), reason: 'inset 拖动层应有明确终点');
    final String dragLayer = src.substring(dragLayerStart, dragLayerEnd);

    expect(dragLayer.contains('onHorizontalDragUpdate'), isTrue,
        reason: 'inset 层必须承载横向拖动识别器');
    expect(dragLayer.contains('onVerticalDragUpdate'), isTrue,
        reason: 'inset 层必须承载竖向拖动识别器');
    expect(dragLayer.contains('onTap: onTap'), isFalse,
        reason: 'TODO-1073：tap 已迁到全画面层，inset 拖动层不得再承载 onTap');

    // inset 拖动层在上、必须 translucent，才能让指针继续命中下方全画面 tap 层。
    expect(dragLayer.contains('behavior: HitTestBehavior.translucent'), isTrue,
        reason: 'TODO-1073：inset 拖动层须 translucent，否则不透明子会吞掉落到 tap 层的单击');
  });
}
