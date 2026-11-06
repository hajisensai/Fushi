import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/audiobook/audiobook_controller.dart';
import 'package:fushi/src/media/audiobook/audiobook_play_bar.dart';
import 'package:fushi/src/utils/components/fushi_expressive_progress.dart';
import 'package:material_ui/material_ui.dart';

/// 播放态 / 位置由测试直接给的控制器：迷你条只读这三样。
class _ScriptedController extends AudiobookPlayerController {
  bool playing = true;
  Duration scriptedPosition = const Duration(seconds: 10);

  @override
  bool get isPlaying => playing;

  @override
  Duration get globalPosition => scriptedPosition;

  @override
  Duration get totalDuration => const Duration(seconds: 100);
}

/// BUG-4126：歌词覆盖层在场时，阅读器层被 `TickerMode(enabled: false)` 包住；
/// 被盖住的迷你条播放中也不能再请帧（波浪 ticker 静音、周期刷新计时器停），
/// 退出后恢复的那一帧就要画出控制器现值。
void main() {
  testWidgets('covered mini player stops requesting frames and resumes with '
      'the live position', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(720, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final _ScriptedController controller = _ScriptedController();
    addTearDown(controller.dispose);

    Widget host({required bool covered}) => MaterialApp(
      theme: ThemeData(useMaterial3: true),
      home: Scaffold(
        body: Center(
          child: TickerMode(
            enabled: !covered,
            child: AudiobookMiniPlayer(
              controller: controller,
              showPlayButton: true,
              chapterLabel: 'Chapter',
            ),
          ),
        ),
      ),
    );

    double shownValue() => tester
        .widget<FushiWavyLinearProgress>(
          find.byKey(const ValueKey<String>('audiobook_mini_player_progress')),
        )
        .value!;

    // 只推进假时钟、不画帧：之后 hasScheduledFrame 就是「这段时间里有人请过帧」。
    Future<bool> requestsFrameWithin(Duration d) async {
      await tester.pump();
      expect(tester.binding.hasScheduledFrame, isFalse, reason: '起点没有挂帧');
      await tester.binding.delayed(d);
      return tester.binding.hasScheduledFrame;
    }

    await tester.pumpWidget(host(covered: false));
    expect(shownValue(), closeTo(0.1, 1e-6));
    final bool waveTicking = tester.binding.transientCallbackCount > 0;
    if (!waveTicking) {
      // 测试环境里波浪若不跑 ticker，就单看周期刷新计时器（对照组）。
      expect(
        await requestsFrameWithin(const Duration(milliseconds: 600)),
        isTrue,
        reason: '可见且播放中：周期刷新照常请帧（对照组）',
      );
    }

    // 覆盖层出现：同一棵子树被 TickerMode 关掉。
    await tester.pumpWidget(host(covered: true));
    expect(tester.binding.transientCallbackCount, 0, reason: '波浪 ticker 静音');
    expect(
      await requestsFrameWithin(const Duration(seconds: 3)),
      isFalse,
      reason: '被盖住时跨过 6 个 500 ms tick 也不请帧（计时器已停）',
    );

    // 被盖住期间位置照常前进，但迷你条不重建。
    controller.scriptedPosition = const Duration(seconds: 42);
    expect(await requestsFrameWithin(const Duration(seconds: 1)), isFalse);
    expect(shownValue(), closeTo(0.1, 1e-6), reason: '盖住时不刷新进度');

    // 退出歌词模式：恢复的这一帧就画出现值，波浪恢复。
    await tester.pumpWidget(host(covered: false));
    expect(shownValue(), closeTo(0.42, 1e-6), reason: '恢复帧立即同步进度');
    expect(
      tester
          .widget<FushiWavyLinearProgress>(
            find.byKey(
              const ValueKey<String>('audiobook_mini_player_progress'),
            ),
          )
          .waving,
      isTrue,
    );
    if (waveTicking) {
      expect(tester.binding.transientCallbackCount, greaterThan(0));
    }

    // 恢复后周期刷新计时器也回来了：位置变化在一个 tick 内上屏。
    controller.scriptedPosition = const Duration(seconds: 50);
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump();
    expect(shownValue(), closeTo(0.5, 1e-6), reason: '计时器恢复');

    controller.playing = false;
    controller.notifyListeners();
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
