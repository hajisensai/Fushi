import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/diagnostics/fushi_binding.dart';
import 'package:fushi/src/utils/adaptive/page_backdrop_style.dart';
import 'package:fushi/src/utils/components/page_backdrop_layer.dart';
import 'package:fushi/src/utils/scheduling/ambient_ticker.dart';

/// BUG-4387：主页背景常驻 repeat 动画让默认调度策略永远判「忙」，WebView 预热的
/// Priority.idle 任务永不执行、调度器零延迟定时器无限空转、Windows 输入被饿死。
void main() {
  final TestWidgetsFlutterBinding binding =
      TestWidgetsFlutterBinding.ensureInitialized();
  late SchedulingStrategy saved;

  setUp(() {
    saved = binding.schedulingStrategy;
    binding.schedulingStrategy = ambientAwareSchedulingStrategy;
  });
  tearDown(() => binding.schedulingStrategy = saved);

  // 注意：「忙」的情形不能真把 idle 任务排进去——调度器会用零延迟 Timer 反复重排，
  // FakeAsync 在一次 pump 里无限循环（正是 BUG-4387 的空转）。忙 / 闲只断言策略判定；
  // 只有判「闲」时才真排任务，验证端到端放行。
  bool idleAllowed(SchedulingStrategy strategy) =>
      strategy(priority: Priority.idle.value, scheduler: binding);

  Future<bool> idleRunsNow(WidgetTester tester) async {
    bool ran = false;
    binding.scheduleTask<void>(() => ran = true, Priority.idle);
    await tester.pump(const Duration(milliseconds: 16));
    return ran;
  }

  testWidgets('复现：默认策略下常驻动画把 idle 判成永远「忙」', (WidgetTester tester) async {
    await tester.pumpWidget(const _Spinner(ambient: true));
    expect(binding.transientCallbackCount, greaterThan(0));
    expect(idleAllowed(defaultSchedulingStrategy), isFalse);
    expect(idleAllowed(ambientAwareSchedulingStrategy), isTrue);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('只有常驻装饰动画在跑时 idle 任务照常执行', (WidgetTester tester) async {
    await tester.pumpWidget(const _Spinner(ambient: true));
    expect(AmbientTickers.scheduledFrameCallbackCount, 1);
    expect(await idleRunsNow(tester), isTrue);
    await tester.pumpWidget(const SizedBox());
    expect(AmbientTickers.liveCount, 0);
  });

  testWidgets('真实动画在跑时 idle 仍判「忙」（与默认策略一致）', (WidgetTester tester) async {
    await tester.pumpWidget(
      const Column(
        children: <Widget>[_Spinner(ambient: true), _Spinner(ambient: false)],
      ),
    );
    expect(idleAllowed(ambientAwareSchedulingStrategy), isFalse);
    expect(
      ambientAwareSchedulingStrategy(
        priority: Priority.animation.value,
        scheduler: binding,
      ),
      isTrue,
    );
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('TickerMode 静音的装饰 ticker 不挂帧回调、不被多扣', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      const TickerMode(enabled: false, child: _Spinner(ambient: true)),
    );
    expect(AmbientTickers.scheduledFrameCallbackCount, 0);
    expect(binding.transientCallbackCount, 0);
    await tester.pumpWidget(const _Spinner(ambient: true));
    expect(AmbientTickers.scheduledFrameCallbackCount, 1);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('页面背景层的漂移动画走 ambient ticker，不挡 idle 任务', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: SizedBox.expand(
          child: PageBackdropLayer(
            settings: PageBackdropSettings(motion: true),
          ),
        ),
      ),
    );
    await tester.pump();
    expect(AmbientTickers.scheduledFrameCallbackCount, 1);
    expect(idleAllowed(ambientAwareSchedulingStrategy), isTrue);
    expect(await idleRunsNow(tester), isTrue);
    await tester.pumpWidget(const SizedBox());
  });

  test('主入口 ensureInitialized 装上 ambient 策略', () {
    binding.schedulingStrategy = defaultSchedulingStrategy;
    FushiWidgetsFlutterBinding.ensureInitialized();
    expect(binding.schedulingStrategy, same(ambientAwareSchedulingStrategy));
  });

  // BUG-4893：「等空闲」本身不能空转。用假调度器数定时器——真 binding 下空转表现为
  // pump 死循环，只能靠超时发现，数不出「一个都没有」。
  group('waitForUiIdle', () {
    test('忙时只挂一个帧后回调，事件循环里一个定时器都没有', () {
      fakeAsync((FakeAsync async) {
        final _FakeScheduler scheduler = _FakeScheduler()..transient = 1;
        bool done = false;
        unawaited(waitForUiIdle(scheduler: scheduler).then((_) => done = true));
        for (int frame = 0; frame < 200; frame++) {
          async.flushMicrotasks();
          expect(async.pendingTimers, isEmpty, reason: '第 $frame 帧前');
          expect(scheduler.postFrame, hasLength(1), reason: '第 $frame 帧前');
          scheduler.drawFrame();
        }
        expect(done, isFalse);

        // 动画停了：这一帧画完才发现空闲，再过一轮事件循环完成。
        scheduler.transient = 0;
        scheduler.drawFrame();
        expect(done, isFalse);
        expect(async.pendingTimers, hasLength(1));
        async.flushTimers();
        expect(done, isTrue);
        expect(scheduler.postFrame, isEmpty);
        expect(async.pendingTimers, isEmpty);
      });
    });

    test('本来就空闲：下一轮事件循环完成，不同步完成、不等帧', () {
      fakeAsync((FakeAsync async) {
        final _FakeScheduler scheduler = _FakeScheduler();
        bool done = false;
        unawaited(waitForUiIdle(scheduler: scheduler).then((_) => done = true));
        async.flushMicrotasks();
        expect(done, isFalse);
        expect(scheduler.postFrame, isEmpty);
        async.flushTimers();
        expect(done, isTrue);
      });
    });

    test('完成前那一轮又起了动画：接着等帧，不完成', () {
      fakeAsync((FakeAsync async) {
        final _FakeScheduler scheduler = _FakeScheduler();
        bool done = false;
        unawaited(waitForUiIdle(scheduler: scheduler).then((_) => done = true));
        scheduler.transient = 1;
        async.flushTimers();
        expect(done, isFalse);
        expect(async.pendingTimers, isEmpty);
        expect(scheduler.postFrame, hasLength(1));

        scheduler.transient = 0;
        scheduler.drawFrame();
        async.flushTimers();
        expect(done, isTrue);
      });
    });

    testWidgets('真实动画在跑时一直等，撤掉后的那一帧之后完成', (WidgetTester tester) async {
      await tester.pumpWidget(const _Spinner(ambient: false));
      bool done = false;
      unawaited(waitForUiIdle().then((_) => done = true));
      for (int i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 16));
        expect(done, isFalse);
      }
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(milliseconds: 1));
      expect(done, isTrue);
    });

    testWidgets('只有常驻装饰动画在跑：照常完成', (WidgetTester tester) async {
      await tester.pumpWidget(const _Spinner(ambient: true));
      expect(binding.transientCallbackCount, greaterThan(0));
      bool done = false;
      unawaited(waitForUiIdle().then((_) => done = true));
      await tester.pump(const Duration(milliseconds: 1));
      expect(done, isTrue);
      await tester.pumpWidget(const SizedBox());
    });
  });
}

/// 只实现 [waitForUiIdle] 用到的两个成员；`drawFrame` 模拟一帧收尾时跑帧后回调。
class _FakeScheduler extends Fake implements SchedulerBinding {
  int transient = 0;
  final List<FrameCallback> postFrame = <FrameCallback>[];

  @override
  int get transientCallbackCount => transient;

  @override
  void addPostFrameCallback(
    FrameCallback callback, {
    String debugLabel = 'callback',
  }) => postFrame.add(callback);

  void drawFrame() {
    final List<FrameCallback> callbacks = List<FrameCallback>.of(postFrame);
    postFrame.clear();
    for (final FrameCallback callback in callbacks) {
      callback(Duration.zero);
    }
  }
}

/// 测试用的常驻 repeat 动画；[ambient] 决定走 ambient ticker 还是普通 ticker。
class _Spinner extends StatelessWidget {
  const _Spinner({required this.ambient});
  final bool ambient;

  @override
  Widget build(BuildContext context) =>
      ambient ? const _AmbientSpinner() : const _PlainSpinner();
}

class _AmbientSpinner extends StatefulWidget {
  const _AmbientSpinner();

  @override
  State<_AmbientSpinner> createState() => _AmbientSpinnerState();
}

class _PlainSpinner extends StatefulWidget {
  const _PlainSpinner();

  @override
  State<_PlainSpinner> createState() => _PlainSpinnerState();
}

class _AmbientSpinnerState extends State<_AmbientSpinner>
    with AmbientTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 1),
  );

  @override
  void initState() {
    super.initState();
    _c.repeat();
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => const SizedBox(width: 1, height: 1);
}

class _PlainSpinnerState extends State<_PlainSpinner>
    with TickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 1),
  );

  @override
  void initState() {
    super.initState();
    _c.repeat();
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => const SizedBox(width: 1, height: 1);
}
