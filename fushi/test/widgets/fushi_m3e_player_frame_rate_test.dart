// 歌词模式（MD3）发热 / 掉帧的根因回归：流动 mesh 背景与播放中的波浪进度条以前
// 各挂一个常驻 Ticker——Ticker 只要在跑，每个 vsync 都要一帧，而
// `RendererBinding.drawFrame` 没有脏节点也照样整帧合成 + 栅格化（120Hz 屏每秒
// 120 次整屏重画）。现在两者都按 ≈30fps 档位要帧：一帧画完之后不得立刻再要下
// 一帧，等到档位才要；仍然持续流动（不是停住）。
import 'package:flutter/scheduler.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/utils/components/fushi_m3e_player.dart';
import 'package:material_ui/material_ui.dart';

class _Clock implements FushiPlaybackClock {
  @override
  Duration get position => const Duration(minutes: 1);

  @override
  Duration get duration => const Duration(minutes: 4);
}

Widget _host(Widget child, {bool disableAnimations = false}) => MaterialApp(
  home: Builder(
    builder: (BuildContext context) => MediaQuery(
      data: MediaQuery.of(
        context,
      ).copyWith(disableAnimations: disableAnimations),
      child: Scaffold(
        body: Center(child: SizedBox(width: 320, height: 200, child: child)),
      ),
    ),
  ),
);

/// 测试期间实际画出的帧数（持久帧回调每画一帧 +1；跨用例只登记一次）。
int _drawnFrames = 0;
bool _frameCounterInstalled = false;

/// 连续推 [ms] 毫秒（每次 1ms），数这段时间里实际画了几帧：测试绑定只在有人要帧
/// （hasScheduledFrame）时才画，所以这就是被要求出的帧数。
Future<int> _countFrames(WidgetTester tester, int ms) async {
  if (!_frameCounterInstalled) {
    _frameCounterInstalled = true;
    SchedulerBinding.instance.addPersistentFrameCallback((_) => _drawnFrames++);
  }
  final int start = _drawnFrames;
  for (int i = 0; i < ms; i++) {
    await tester.pump(const Duration(milliseconds: 1));
  }
  return _drawnFrames - start;
}

void main() {
  testWidgets('mesh 背景：一帧画完不立刻要下一帧，按 ≈30fps 档位持续流动', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(_host(const FushiMeshBackdrop()));
    await tester.pump();
    expect(
      tester.binding.hasScheduledFrame,
      isFalse,
      reason: '常驻 Ticker 会在每帧结束时立刻再要一帧（逐 vsync 出帧）',
    );
    final int frames = await _countFrames(tester, 1000);
    // 33ms 一档 ≈ 30 帧 / 秒；Ticker 下这里是每次 pump 都出帧（1000）。
    expect(frames, inInclusiveRange(25, 35));
  });

  testWidgets('波浪进度条（播放中）：稳态按 ≈30fps 流动，不逐 vsync 出帧', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      _host(
        FushiWavySeekBar(
          clock: _Clock(),
          isPlaying: true,
          onSeek: (_) {},
          strokeWidth: 5,
          barHeight: 32,
        ),
      ),
    );
    await tester.pump();
    final int frames = await _countFrames(tester, 1000);
    expect(frames, inInclusiveRange(25, 35));
    // 波浪确实在流：相位在推进（画家拿到的 phase 变了）。
    final CustomPaint before = tester.widget(_seekPaint());
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pump(const Duration(milliseconds: 40));
    final CustomPaint after = tester.widget(_seekPaint());
    expect(
      after.painter!.shouldRepaint(before.painter!),
      isTrue,
      reason: '播放中波浪应持续流动',
    );
  });

  testWidgets('波浪进度条（暂停）：振幅收完后不再要帧（只剩低频位置轮询）', (WidgetTester tester) async {
    await tester.pumpWidget(
      _host(
        FushiWavySeekBar(
          clock: _Clock(),
          isPlaying: false,
          onSeek: (_) {},
          strokeWidth: 5,
          barHeight: 32,
        ),
      ),
    );
    await tester.pump();
    expect(tester.binding.hasScheduledFrame, isFalse);
    expect(
      SchedulerBinding.instance.transientCallbackCount,
      0,
      reason: '暂停时不应挂任何帧回调',
    );
  });

  testWidgets('动效关闭（减弱动态效果）：mesh 与波浪都不要帧', (WidgetTester tester) async {
    await tester.pumpWidget(
      _host(
        Column(
          children: <Widget>[
            const Expanded(child: FushiMeshBackdrop()),
            FushiWavySeekBar(
              clock: _Clock(),
              isPlaying: true,
              onSeek: (_) {},
              strokeWidth: 5,
              barHeight: 32,
            ),
          ],
        ),
        disableAnimations: true,
      ),
    );
    await tester.pump();
    final int frames = await _countFrames(tester, 300);
    expect(frames, 0);
  });
}

Finder _seekPaint() => find.descendant(
  of: find.byType(FushiWavySeekBar),
  matching: find.byWidgetPredicate(
    (Widget w) => w is CustomPaint && w.painter != null,
  ),
);
