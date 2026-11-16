import 'package:flutter/scheduler.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/diagnostics/fushi_binding.dart';
import 'package:fushi/src/utils/scheduling/ambient_ticker.dart';
import 'package:fushi/src/utils/scheduling/frame_paced_task_scheduler.dart';

/// 与生产 binding 同一个 mixin，外加任务循环调用计数。
class _PacedTestBinding extends AutomatedTestWidgetsFlutterBinding
    with FramePacedTaskScheduler {
  int eventLoopCallbacks = 0;

  @override
  bool handleEventLoopCallback() {
    eventLoopCallbacks++;
    // ignore: invalid_use_of_visible_for_testing_member
    return super.handleEventLoopCallback();
  }
}

/// BUG-4387 复发：任何真实常驻动画 + 一个 Priority.idle 任务，框架调度器零延迟
/// `Timer.run` 无限空转，Windows 输入与窗口激活被 posted 消息饿死（任务栏点图标唤不到
/// 前台）。修复后被推迟的任务按帧节拍重查。
///
/// 改前这里第一个用例的 `tester.pump` 就会在 FakeAsync 里无限循环（零延迟定时器永远
/// 冲不完），即测试挂死；改后每帧最多一次重查。
void main() {
  final _PacedTestBinding binding = _PacedTestBinding();

  setUp(() {
    binding.schedulingStrategy = ambientAwareSchedulingStrategy;
  });

  testWidgets('真实动画在跑时 idle 任务不空转：每帧最多重查一次，动画停后执行', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(const _RealSpinner());
    expect(binding.transientCallbackCount, greaterThan(0));

    bool ran = false;
    binding.eventLoopCallbacks = 0;
    binding.scheduleTask<void>(() => ran = true, Priority.idle);

    const int frames = 10;
    for (int i = 0; i < frames; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(ran, isFalse, reason: '真实动画在跑，idle 任务按策略仍应等待');
    expect(
      binding.eventLoopCallbacks,
      lessThanOrEqualTo(frames + 1),
      reason: '推迟期间任务循环必须按帧节拍，而不是零延迟空转',
    );

    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(milliseconds: 16));
    await tester.pump(const Duration(milliseconds: 16));
    expect(ran, isTrue, reason: '动画结束后下一帧重查必须把任务放行');
  });

  testWidgets('推迟中排进的多个任务在放行后全部执行', (WidgetTester tester) async {
    await tester.pumpWidget(const _RealSpinner());
    final List<int> order = <int>[];
    binding.scheduleTask<void>(() => order.add(1), Priority.idle);
    binding.scheduleTask<void>(() => order.add(2), Priority.idle);
    binding.scheduleTask<void>(() => order.add(3), Priority.idle);
    await tester.pump(const Duration(milliseconds: 16));
    expect(order, isEmpty);

    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(milliseconds: 16));
    await tester.pump(const Duration(milliseconds: 16));
    // 框架任务队列按优先级堆排序，同优先级不保证先进先出，只断言全部执行。
    expect(order, unorderedEquals(<int>[1, 2, 3]));
  });

  testWidgets('没有动画时 idle 任务当场执行（不额外等帧）', (WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    expect(binding.transientCallbackCount, 0);
    bool ran = false;
    binding.scheduleTask<void>(() => ran = true, Priority.idle);
    // 不带时长的 pump 不推进 FakeAsync 时钟，零延迟定时器不会跑；给 1 ms。
    await tester.pump(const Duration(milliseconds: 1));
    expect(ran, isTrue);
  });

  testWidgets('读回策略再设回去不会把观察包装套进自己（save / restore 安全）', (
    WidgetTester tester,
  ) async {
    final SchedulingStrategy saved = binding.schedulingStrategy;
    binding.schedulingStrategy = saved;
    expect(
      binding.schedulingStrategy(
        priority: Priority.idle.value,
        scheduler: binding,
      ),
      isTrue,
    );

    await tester.pumpWidget(const _RealSpinner());
    bool ran = false;
    binding.scheduleTask<void>(() => ran = true, Priority.idle);
    await tester.pump(const Duration(milliseconds: 16));
    expect(ran, isFalse);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(milliseconds: 16));
    await tester.pump(const Duration(milliseconds: 16));
    expect(ran, isTrue);
  });

  test('生产 binding 混入了按帧节拍的任务调度', () {
    expect(
      <FushiWidgetsFlutterBinding>[],
      isA<List<FramePacedTaskScheduler>>(),
    );
  });
}

/// 非装饰的常驻动画（普通 TickerProviderStateMixin + repeat），即 BUG-4387 修复没覆盖到的那类。
class _RealSpinner extends StatefulWidget {
  const _RealSpinner();

  @override
  State<_RealSpinner> createState() => _RealSpinnerState();
}

class _RealSpinnerState extends State<_RealSpinner>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 1),
  )..repeat();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => RotationTransition(
    turns: _controller,
    child: const SizedBox(width: 10, height: 10),
  );
}
