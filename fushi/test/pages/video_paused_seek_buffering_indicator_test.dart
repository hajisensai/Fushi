import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/video_player_controller.dart';
import 'package:fushi/src/pages/implementations/video_loading_overlay.dart';

/// BUG-3195：暂停状态下拖进度条跳转后，画面正中一直挂着加载圈和「0 B/s」，按播放
/// 才消失。media_kit 把 mpv 的 `core-idle` 当缓冲，暂停时 `core-idle` 恒真；seek 让
/// 它落下再升起，升起那一下就被记成「缓冲中」且暂停期间再也不落下。缓冲圈只在
/// 正在播放时才算数。
void main() {
  test('判据：暂停时 media_kit 报的「缓冲」不点亮缓冲圈，播放中照常点亮', () {
    expect(
      VideoPlayerController.shouldShowBufferingIndicator(
        buffering: true,
        playing: false,
      ),
      isFalse,
      reason: '暂停跳转后 core-idle 卡在真',
    );
    expect(
      VideoPlayerController.shouldShowBufferingIndicator(
        buffering: true,
        playing: true,
      ),
      isTrue,
    );
    expect(
      VideoPlayerController.shouldShowBufferingIndicator(
        buffering: false,
        playing: true,
      ),
      isFalse,
    );
  });

  testWidgets('缓冲圈组件按播放器判据显隐（含速度行）', (WidgetTester tester) async {
    final ValueNotifier<bool> visible = ValueNotifier<bool>(true);
    addTearDown(visible.dispose);
    final ValueNotifier<double?> speed = ValueNotifier<double?>(0);
    addTearDown(speed.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: VideoBufferingIndicator(readSpeed: speed, visible: visible),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.byType(VideoReadSpeedLabel), findsOneWidget);

    visible.value = false;
    await tester.pump();
    expect(find.byType(VideoReadSpeedLabel), findsNothing);
  });

  test('两套控制条主题都把播放器判据接进缓冲圈', () {
    final String source = File(
      'lib/src/pages/implementations/video_fushi/controls_theme.part.dart',
    ).readAsStringSync();
    expect(
      'visible: controller.bufferingIndicatorVisible'.allMatches(source).length,
      2,
    );
  });
}
