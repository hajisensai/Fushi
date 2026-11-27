// StateResourceScope：initState 半途抛错时回滚已登记的订阅 / 监听 / Timer（BUG-5604）。
//
// Flutter 在 initState 抛错时只停用元素、永不 dispose；没有本 mixin 时抛错点之前
// 挂上的资源就成了孤儿。这里用一个最小 State 同时验证两条退场路径共用同一份清单。
import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/utils/state_resource_scope.dart';

void main() {
  testWidgets('initState 半途抛错：已登记的订阅、监听、Timer、自定义撤销全部回滚', (
    WidgetTester tester,
  ) async {
    final _Resources r = _Resources();
    await tester.pumpWidget(_Probe(resources: r, failAfterAttach: true));
    expect(
      tester.takeException().toString(),
      contains(_Probe.failure),
      reason: '前置：initState 确实半途抛错',
    );

    expect(r.controller.hasListener, isFalse, reason: '流订阅已取消');
    expect(r.notifier.listenerCount, 0, reason: '监听已摘');
    expect(r.customTeardowns, 1, reason: '自定义撤销只跑一次');
    expect(r.failingListenable.removeCalls, 0, reason: '没挂上的监听不登记、不撤');
    await tester.pump();
    expect(r.lateController.hasListener, isFalse, reason: '撤销之后才登记的订阅当场取消');

    // 回滚之后的事件不再触达孤儿 State；Timer 已取消，不会在 30 秒后回调。
    r.controller.add(1);
    r.notifier.value++;
    await tester.pump(const Duration(seconds: 31));
    expect(r.callbacks, 0);
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox());
    expect(r.customTeardowns, 1, reason: '孤儿 State 永不 dispose，不会二次撤销');
    expect(tester.takeException(), isNull);
  });

  testWidgets('正常挂载：dispose 时由同一份清单撤销，挂载期间资源照常工作', (WidgetTester tester) async {
    final _Resources r = _Resources();
    final GlobalKey key = GlobalKey();
    await tester.pumpWidget(
      Row(
        textDirection: TextDirection.ltr,
        children: <Widget>[
          _Probe(key: key, resources: r, failAfterAttach: false),
        ],
      ),
    );
    expect(tester.takeException(), isNull);

    r.controller.add(1);
    r.notifier.value++;
    await tester.pump();
    expect(r.callbacks, 2, reason: '挂载成功时登记不影响资源本身');
    expect(r.lateController.hasListener, isTrue);
    expect(r.customTeardowns, 0, reason: '正常挂载不触发回滚');

    // 被 GlobalKey 挪位置是一次 deactivate → activate，不得误判为挂载失败。
    await tester.pumpWidget(
      Column(
        children: <Widget>[
          _Probe(key: key, resources: r, failAfterAttach: false),
        ],
      ),
    );
    expect(r.customTeardowns, 0, reason: '移位不撤销');

    await tester.pumpWidget(const SizedBox());
    expect(r.controller.hasListener, isFalse);
    expect(r.lateController.hasListener, isFalse);
    expect(r.notifier.listenerCount, 0);
    expect(r.customTeardowns, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('一条撤销抛错不影响其余撤销，错误照常上报', (WidgetTester tester) async {
    final _Resources r = _Resources()..teardownThrows = true;
    await tester.pumpWidget(_Probe(resources: r, failAfterAttach: false));
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox());
    expect(tester.takeException().toString(), contains('teardown failure'));
    expect(r.controller.hasListener, isFalse, reason: '先登记的照样撤掉');
    expect(r.notifier.listenerCount, 0);
  });

  testWidgets('子类 deactivate 覆写在调 super 前抛错：微任务兜底照样回滚', (
    WidgetTester tester,
  ) async {
    final StreamController<int> controller = StreamController<int>.broadcast();
    final ValueNotifier<int> notifier = ValueNotifier<int>(0);
    await tester.pumpWidget(
      _ThrowingDeactivate(stream: controller.stream, notifier: notifier),
    );
    // 框架吞掉 deactivate 的异常，只上报 initState 的原始错误。
    expect(tester.takeException().toString(), contains(_Probe.failure));
    await tester.pump();
    expect(controller.hasListener, isFalse);
    // ignore: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member
    expect(notifier.hasListeners, isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('releaseResources：撤销在 dispose 的指定位置跑完，super.dispose 不重复', (
    WidgetTester tester,
  ) async {
    final List<String> log = <String>[];
    await tester.pumpWidget(_OrderedRelease(log: log));
    await tester.pumpWidget(const SizedBox());
    expect(log, <String>['detach', 'own dispose']);
  });

  testWidgets('ScopedRelease：dispose 里提前撤一条，其余仍在 super.dispose 撤', (
    WidgetTester tester,
  ) async {
    final List<String> log = <String>[];
    await tester.pumpWidget(_EarlyRelease(log: log));
    await tester.pumpWidget(const SizedBox());
    expect(log, <String>['a', 'mid', 'b']);
  });

  testWidgets('schedulePostFrame：挂载失败后不回调，正常挂载照常回调', (
    WidgetTester tester,
  ) async {
    final List<String> log = <String>[];
    await tester.pumpWidget(_PostFrame(log: log, fail: true));
    expect(tester.takeException(), isA<StateError>());
    await tester.pump();
    expect(log, isEmpty);
    await tester.pumpWidget(_PostFrame(log: log, fail: false));
    expect(log, <String>['frame']);
  });

  testWidgets('首次 didChangeDependencies 抛错：已登记的资源在帧后按孤儿撤销', (
    WidgetTester tester,
  ) async {
    final ValueNotifier<int> notifier = ValueNotifier<int>(0);
    await tester.pumpWidget(_ThrowingDeps(notifier: notifier));
    expect(tester.takeException().toString(), contains(_Probe.failure));
    await tester.pump();
    // ignore: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member
    expect(notifier.hasListeners, isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('didUpdateWidget 抛错：父级丢掉的旧子树（含子孙）在帧后撤销', (
    WidgetTester tester,
  ) async {
    final ValueNotifier<int> own = ValueNotifier<int>(0);
    final ValueNotifier<int> child = ValueNotifier<int>(0);
    await tester.pumpWidget(
      _ThrowingUpdate(generation: 0, own: own, child: child),
    );
    // ignore: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member
    expect(own.hasListeners && child.hasListeners, isTrue);
    await tester.pumpWidget(
      _ThrowingUpdate(generation: 1, own: own, child: child),
    );
    expect(tester.takeException().toString(), contains(_Probe.failure));
    await tester.pump();
    // ignore: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member
    expect(own.hasListeners, isFalse, reason: '抛错的 State 自己的登记');
    // ignore: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member
    expect(child.hasListeners, isFalse, reason: '子树没被停用，也一并撤');
    expect(tester.takeException(), isNull);
  });

  testWidgets('slot：同一槽位再登记先撤上一条；dispose 只撤当下那条', (WidgetTester tester) async {
    final ValueNotifier<int> a = ValueNotifier<int>(0);
    final ValueNotifier<int> b = ValueNotifier<int>(0);
    final List<String> log = <String>[];
    await tester.pumpWidget(_Slotted(listenable: a, log: log));
    await tester.pumpWidget(_Slotted(listenable: b, log: log));
    // ignore: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member
    expect(a.hasListeners, isFalse, reason: '换了 listenable：旧的已摘');
    // ignore: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member
    expect(b.hasListeners, isTrue);
    expect(log, <String>['tick 0']);
    await tester.pumpWidget(const SizedBox());
    // ignore: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member
    expect(b.hasListeners, isFalse);
    expect(log, <String>['tick 0', 'tick 1']);
  });

  testWidgets('正常停用后 dispose：帧后检查不误撤、不重复撤', (WidgetTester tester) async {
    final List<String> log = <String>[];
    await tester.pumpWidget(_EarlyRelease(log: log));
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
    expect(log, <String>['a', 'mid', 'b']);
  });
}

class _Resources {
  final StreamController<int> controller = StreamController<int>.broadcast();
  final StreamController<int> lateController =
      StreamController<int>.broadcast();
  final _CountingNotifier notifier = _CountingNotifier();
  final _FailingListenable failingListenable = _FailingListenable();
  int callbacks = 0;
  int customTeardowns = 0;
  bool teardownThrows = false;
}

class _Probe extends StatefulWidget {
  const _Probe({
    super.key,
    required this.resources,
    required this.failAfterAttach,
  });

  static const String failure = 'simulated initState failure';

  final _Resources resources;
  final bool failAfterAttach;

  @override
  State<_Probe> createState() => _ProbeState();
}

class _ProbeState extends State<_Probe> with StateResourceScope<_Probe> {
  @override
  void initState() {
    super.initState();
    final _Resources r = widget.resources;
    ownSubscription(r.controller.stream.listen((_) => _touch()));
    listenTo(r.notifier, _touch);
    ownTimer(Timer(const Duration(seconds: 30), _touch));
    onTeardown(() {
      r.customTeardowns++;
      if (r.teardownThrows) throw StateError('teardown failure');
    });
    // 首帧后才挂的订阅：挂载失败时这个回调照样会跑，登记时清单已经撤过。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ownSubscription(r.lateController.stream.listen((_) => _touch()));
    });
    if (widget.failAfterAttach) {
      try {
        listenTo(r.failingListenable, _touch);
      } on StateError {
        throw StateError(_Probe.failure);
      }
    }
  }

  void _touch() {
    widget.resources.callbacks++;
    // 孤儿 State 上碰 context 就是 BUG-5602 的那条断言。
    context.findAncestorWidgetOfExactType<Directionality>();
  }

  @override
  Widget build(BuildContext context) => const SizedBox();
}

class _CountingNotifier extends ValueNotifier<int> {
  _CountingNotifier() : super(0);

  int listenerCount = 0;

  @override
  void addListener(VoidCallback listener) {
    listenerCount++;
    super.addListener(listener);
  }

  @override
  void removeListener(VoidCallback listener) {
    listenerCount--;
    super.removeListener(listener);
  }
}

class _FailingListenable implements Listenable {
  int removeCalls = 0;

  @override
  void addListener(VoidCallback listener) => throw StateError('cannot attach');

  @override
  void removeListener(VoidCallback listener) => removeCalls++;
}

class _ThrowingDeactivate extends StatefulWidget {
  const _ThrowingDeactivate({required this.stream, required this.notifier});

  final Stream<int> stream;
  final ValueNotifier<int> notifier;

  @override
  State<_ThrowingDeactivate> createState() => _ThrowingDeactivateState();
}

class _ThrowingDeactivateState extends State<_ThrowingDeactivate>
    with StateResourceScope<_ThrowingDeactivate> {
  @override
  void initState() {
    super.initState();
    ownSubscription(widget.stream.listen((_) {}));
    listenTo(widget.notifier, () {});
    throw StateError(_Probe.failure);
  }

  // initState 抛错点之后才赋值：失败挂载时还没初始化。
  late final List<int> _halfInitialised;

  @override
  void deactivate() {
    // 读 initState 没来得及初始化的状态 → 在调 super 之前抛 LateInitializationError。
    _halfInitialised.clear();
    super.deactivate();
  }

  @override
  Widget build(BuildContext context) => const SizedBox();
}

class _OrderedRelease extends StatefulWidget {
  const _OrderedRelease({required this.log});

  final List<String> log;

  @override
  State<_OrderedRelease> createState() => _OrderedReleaseState();
}

class _OrderedReleaseState extends State<_OrderedRelease>
    with StateResourceScope<_OrderedRelease> {
  @override
  void initState() {
    super.initState();
    onTeardown(() => widget.log.add('detach'));
  }

  @override
  void dispose() {
    releaseResources();
    widget.log.add('own dispose');
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => const SizedBox();
}

class _EarlyRelease extends StatefulWidget {
  const _EarlyRelease({required this.log});

  final List<String> log;

  @override
  State<_EarlyRelease> createState() => _EarlyReleaseState();
}

class _EarlyReleaseState extends State<_EarlyRelease>
    with StateResourceScope<_EarlyRelease> {
  late final ScopedRelease _a;

  @override
  void initState() {
    super.initState();
    _a = onTeardown(() => widget.log.add('a'));
    onTeardown(() => widget.log.add('b'));
  }

  @override
  void dispose() {
    _a.release();
    _a.release(); // 幂等：不会再跑一次。
    widget.log.add('mid');
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => const SizedBox();
}

class _PostFrame extends StatefulWidget {
  const _PostFrame({required this.log, required this.fail});

  final List<String> log;
  final bool fail;

  @override
  State<_PostFrame> createState() => _PostFrameState();
}

class _PostFrameState extends State<_PostFrame>
    with StateResourceScope<_PostFrame> {
  @override
  void initState() {
    super.initState();
    schedulePostFrame((_) => widget.log.add('frame'));
    if (widget.fail) throw StateError('initState failed');
  }

  @override
  Widget build(BuildContext context) => const SizedBox();
}

class _ThrowingDeps extends StatefulWidget {
  const _ThrowingDeps({required this.notifier});

  final ValueNotifier<int> notifier;

  @override
  State<_ThrowingDeps> createState() => _ThrowingDepsState();
}

class _ThrowingDepsState extends State<_ThrowingDeps>
    with StateResourceScope<_ThrowingDeps> {
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    listenTo(widget.notifier, _on);
    throw StateError(_Probe.failure);
  }

  void _on() {}

  @override
  Widget build(BuildContext context) => const SizedBox();
}

class _ThrowingUpdate extends StatefulWidget {
  const _ThrowingUpdate({
    required this.generation,
    required this.own,
    required this.child,
  });

  final int generation;
  final ValueNotifier<int> own;
  final ValueNotifier<int> child;

  @override
  State<_ThrowingUpdate> createState() => _ThrowingUpdateState();
}

class _ThrowingUpdateState extends State<_ThrowingUpdate>
    with StateResourceScope<_ThrowingUpdate> {
  @override
  void initState() {
    super.initState();
    listenTo(widget.own, _on);
  }

  @override
  void didUpdateWidget(_ThrowingUpdate oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.generation != oldWidget.generation) {
      throw StateError(_Probe.failure);
    }
  }

  void _on() {}

  @override
  Widget build(BuildContext context) => _Listening(notifier: widget.child);
}

class _Listening extends StatefulWidget {
  const _Listening({required this.notifier});

  final ValueNotifier<int> notifier;

  @override
  State<_Listening> createState() => _ListeningState();
}

class _ListeningState extends State<_Listening>
    with StateResourceScope<_Listening> {
  @override
  void initState() {
    super.initState();
    listenTo(widget.notifier, _on);
  }

  void _on() {}

  @override
  Widget build(BuildContext context) => const SizedBox();
}

class _Slotted extends StatefulWidget {
  const _Slotted({required this.listenable, required this.log});

  final ValueNotifier<int> listenable;
  final List<String> log;

  @override
  State<_Slotted> createState() => _SlottedState();
}

class _SlottedState extends State<_Slotted> with StateResourceScope<_Slotted> {
  int _ticks = 0;

  @override
  void initState() {
    super.initState();
    _bind();
  }

  @override
  void didUpdateWidget(_Slotted oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.listenable != widget.listenable) _bind();
  }

  void _bind() {
    listenTo(widget.listenable, _on, slot: #listenable);
    final int n = _ticks++;
    onTeardown(() => widget.log.add('tick $n'), slot: #tick);
  }

  void _on() {}

  @override
  Widget build(BuildContext context) => const SizedBox();
}
