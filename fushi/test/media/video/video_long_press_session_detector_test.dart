// 3sDHeyPQ-I：长按倍速徽章卡在画面上。识别器在长按被接受后遇到指针取消 / 自身被销毁
// 时不回调任何东西，页面只接 onLongPressEnd 就会把徽章与临时倍速留在原地。
// [VideoLongPressSessionDetector] 把会话绑到发起它的指针上，本测试用真实手势驱动，
// 逐个钉死「每个已开始的会话恰好收尾一次」的四个出口。
import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/video_long_press_session_detector.dart';

void main() {
  late int starts;
  late int moves;
  late int ends;

  setUp(() {
    starts = 0;
    moves = 0;
    ends = 0;
  });

  Widget harness({bool mounted = true}) {
    return Directionality(
      textDirection: TextDirection.ltr,
      child: mounted
          ? VideoLongPressSessionDetector(
              onLongPressStart: (LongPressStartDetails _) => starts++,
              onLongPressMoveUpdate: (LongPressMoveUpdateDetails _) => moves++,
              onLongPressEnd: () => ends++,
              child: const SizedBox.expand(),
            )
          : const SizedBox.expand(),
    );
  }

  const Offset origin = Offset(200, 200);

  testWidgets('正常松手：恰好收尾一次', (WidgetTester tester) async {
    await tester.pumpWidget(harness());
    final TestGesture g = await tester.startGesture(origin);
    await tester.pump(kLongPressTimeout + const Duration(milliseconds: 50));
    expect(starts, 1);
    await g.moveBy(const Offset(40, 0));
    expect(moves, 1);
    await g.up();
    await tester.pump();
    expect(ends, 1, reason: 'Listener 抬起与识别器 end 两路都到，只能算一次');
  });

  testWidgets('长按已开始后指针被系统取消：仍收尾一次（旧实现卡住的路径）', (WidgetTester tester) async {
    await tester.pumpWidget(harness());
    final TestGesture g = await tester.startGesture(origin);
    await tester.pump(kLongPressTimeout + const Duration(milliseconds: 50));
    expect(starts, 1);
    await g.cancel();
    await tester.pump();
    expect(ends, 1, reason: '识别器接受后收到 cancel 不回调任何东西，会话必须靠指针层收尾');
    // 收尾后的拖动不再转发。
    expect(moves, 0);
  });

  testWidgets('长按途中手势层被卸载：收尾一次（推迟到微任务，避开树锁定）', (WidgetTester tester) async {
    await tester.pumpWidget(harness());
    final TestGesture g = await tester.startGesture(origin);
    await tester.pump(kLongPressTimeout + const Duration(milliseconds: 50));
    expect(starts, 1);
    await tester.pumpWidget(harness(mounted: false));
    await tester.pump();
    expect(ends, 1);
    await g.up();
    await tester.pump();
    expect(ends, 1, reason: '卸载已收过尾，之后的抬起不能再收一次');
  });

  testWidgets('还没到长按阈值就取消：不开始也不收尾', (WidgetTester tester) async {
    await tester.pumpWidget(harness());
    final TestGesture g = await tester.startGesture(origin);
    await tester.pump(const Duration(milliseconds: 100));
    await g.cancel();
    await tester.pump(kLongPressTimeout);
    expect(starts, 0);
    expect(ends, 0);
  });

  testWidgets('多指：第二根手指抬起不收尾，发起长按的那根抬起才收尾', (WidgetTester tester) async {
    await tester.pumpWidget(harness());
    final TestGesture first = await tester.startGesture(origin, pointer: 1);
    await tester.pump(kLongPressTimeout + const Duration(milliseconds: 50));
    expect(starts, 1);
    final TestGesture second = await tester.startGesture(
      origin + const Offset(100, 0),
      pointer: 2,
    );
    await second.up();
    await tester.pump();
    expect(ends, 0);
    await first.up();
    await tester.pump();
    expect(ends, 1);
  });

  testWidgets('连续两次长按各自独立开始 / 收尾', (WidgetTester tester) async {
    await tester.pumpWidget(harness());
    for (int i = 0; i < 2; i++) {
      final TestGesture g = await tester.startGesture(origin);
      await tester.pump(kLongPressTimeout + const Duration(milliseconds: 50));
      await g.cancel();
      await tester.pump();
    }
    expect(starts, 2);
    expect(ends, 2);
  });
}
