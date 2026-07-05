// TODO-1154：长按倍速控制条跟随指针（B 站/YouTube 长按倍速气泡观感）。
//
// 旧行为：长按 2.0x 倍速提示走 volume_osd 的 _showOsd → 钉死画面左上角，不跟手。
// 修复：长按/拖动把指针 localPosition + 当前速度写入 _longPressSpeedBadge，视频 Stack
// 里挂一枚跟随徽章 [VideoLongPressSpeedBadge]，随指针移动、松手清空。
//
// widget 测试：直接断言徽章随 position 变化而跟随移动（真实手势在 headless 里驱动不了）。
// 源码守卫：锁住手势→notifier 的接线（start/move 写 localPosition、end 清空、Stack 挂层）。
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/media/video/video_long_press_speed_badge.dart';

void main() {
  group('VideoLongPressSpeedBadge（徽章跟随指针）', () {
    Widget wrap(Offset position, double speed) {
      return MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 800,
            height: 600,
            child: Stack(
              children: <Widget>[
                VideoLongPressSpeedBadge(
                  position: position,
                  speed: speed,
                  surfaceColor: Colors.black,
                  textColor: Colors.white,
                ),
              ],
            ),
          ),
        ),
      );
    }

    testWidgets('徽章渲染当前速度文案，随 position 等量跟随，且文字上移避让指针',
        (WidgetTester tester) async {
      await tester.pumpWidget(wrap(const Offset(200, 300), 2.0));
      await tester.pump();

      expect(find.text('2.0x'), findsOneWidget);
      // 锚点盒随 Positioned(left/top) 精确落在 position（跟随的直接证据）。
      final Offset badgeA =
          tester.getCenter(find.byType(VideoLongPressSpeedBadge));
      // 竖直上移避让：绘制出的文字中心在锚点上方（FractionalTranslation(-1.8) 作用到子树）。
      final Offset textA = tester.getCenter(find.text('2.0x'));
      expect(textA.dy, lessThan(300), reason: '徽章必须整体上移，避免被手指/光标遮挡');

      // 指针移动到新位置：徽章必须等量跟随（不再钉死原处）。
      await tester.pumpWidget(wrap(const Offset(520, 260), 2.5));
      await tester.pump();
      expect(find.text('2.5x'), findsOneWidget);
      final Offset badgeB =
          tester.getCenter(find.byType(VideoLongPressSpeedBadge));
      // 中心随锚点等量平移：Δx=520-200=320，Δy=260-300=-40。
      expect(badgeB.dx - badgeA.dx, closeTo(320, 1.0),
          reason: '指针右移多少徽章跟随右移多少（证明跟手，而非固定 topLeft）');
      expect(badgeB.dy - badgeA.dy, closeTo(-40, 1.0));
    });
  });

  group('源码守卫 (TODO-1154)', () {
    File readSource(String rel) {
      final File f = File(rel);
      expect(f.existsSync(), isTrue, reason: 'missing source file: $rel');
      return f;
    }

    test('speed.part：长按 start/move 把 localPosition 写入跟随 notifier，end 清空', () {
      final String src = readSource(
              'lib/src/pages/implementations/video_hibiki/speed.part.dart')
          .readAsStringSync();
      final int startIdx = src.indexOf('_handleVideoLongPressStart(');
      final int moveIdx = src.indexOf('_handleVideoLongPressMoveUpdate(');
      final int endIdx = src.indexOf('_handleVideoLongPressEnd(');
      final int adjustIdx = src.indexOf('Future<void> _adjustSpeed(');
      expect(startIdx, greaterThan(0));
      expect(moveIdx, greaterThan(startIdx));
      expect(endIdx, greaterThan(moveIdx));
      final String startBody = src.substring(startIdx, moveIdx);
      final String moveBody = src.substring(moveIdx, endIdx);
      final String endBody = src.substring(endIdx, adjustIdx);
      // start/move 用指针 localPosition 驱动徽章跟随（非固定 topLeft OSD）。
      expect(
        startBody.contains('_longPressSpeedBadge.value =') &&
            startBody.contains('details.localPosition'),
        isTrue,
        reason: 'long-press start 必须把 localPosition 写入跟随徽章',
      );
      expect(
        moveBody.contains('_longPressSpeedBadge.value =') &&
            moveBody.contains('details.localPosition'),
        isTrue,
        reason: 'long-press move 必须持续更新徽章到当前指针位置（跟手）',
      );
      // end 清空徽章。
      expect(endBody.contains('_longPressSpeedBadge.value = null'), isTrue,
          reason: '松手必须清空跟随徽章');
      // 不再复用钉死左上角的 _showOsd 显示长按速度。
      expect(startBody.contains('_showOsd('), isFalse,
          reason: 'long-press start 不得再用固定左上角 _showOsd');
      expect(moveBody.contains('_showOsd('), isFalse,
          reason: 'long-press move 不得再用固定左上角 _showOsd');
    });

    test('layout.part：视频 Stack 挂载跟随徽章层', () {
      final String src = readSource(
              'lib/src/pages/implementations/video_hibiki/layout.part.dart')
          .readAsStringSync();
      expect(src.contains('_buildLongPressSpeedBadgeOverlay()'), isTrue,
          reason: '视频 Stack 必须挂长按倍速跟随徽章层');
    });
  });
}
