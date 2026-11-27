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
