import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'initstate_resource_scan.dart';

/// initState 里挂外部资源必须经 `StateResourceScope` 登记（BUG-5604）。
///
/// initState 半途抛错时 Flutter 只停用元素、永不调 dispose，`mounted` 也一直是
/// true：抛错点之前直接挂上的流订阅 / 监听 / Timer / 观察者成了孤儿，回调之后在
/// 停用的元素上读 `ref` / `context` 即断言，并且泄漏（BUG-5602、BUG-5604）。登记过
/// 的资源由 `StateResourceScope` 在失败路径与 dispose 共用一份清单撤销。
///
/// 本守卫扫 `lib/` 每个 `initState` 方法体里「裸挂」的资源：
/// - `.listen(`、`.add…Listener(`、`.addObserver(`、`.addHandler(`、
///   `Timer(` / `Timer.periodic(`、`AppLifecycleListener(`、`addPostFrameCallback(`、
///   `scheduleMicrotask(`（挂载失败后照样回调，要经 `schedulePostFrame`）；
/// - 同一条语句里出现 `ownSubscription(` / `listenTo(` / `ownTimer(`，或紧跟的下一条
///   语句是 `onTeardown(`，算已登记；
/// - 直接挂在本 State 私有字段上的 `_x.add…Listener(`、或
///   `_x = SomeController(...)..add…Listener(`（自己创建、随自己 dispose 的
///   controller / focus node）不算：它们与 State 同生共死，孤儿化不泄漏外部引用。
///
/// 零容忍（存量已于 2026-11-28 全部迁完）：`lib/` 下任何 initState 出现一处裸挂即红。
void main() {
  test('initState 外部资源一律经 StateResourceScope 登记（零容忍）', () {
    final Map<String, int> actual = scanInitStateRawAttachments(
      Directory('lib'),
    );
    expect(
      actual.entries
          .map((MapEntry<String, int> e) => '${e.key}: ${e.value}')
          .toList(),
      isEmpty,
      reason:
          'initState 里有裸挂的订阅 / 监听 / Timer / 观察者 / post-frame 回调。改成 '
          'StateResourceScope 的 ownSubscription / listenTo / ownTimer / '
          'onTeardown / schedulePostFrame（State 需 `with StateResourceScope<W>`，'
          'BasePageState 家族已自带）。',
    );
  });

  test('扫描器自检：已登记 / 私有字段 / 紧跟 onTeardown 不计，裸挂计数', () {
    const String source = '''
class _AState extends State<A> with StateResourceScope<A> {
  @override
  void initState() {
    super.initState();
    ownSubscription(repo.watch().listen(_on));
    ownSubscription(
      repo.watchOther().listen(_on),
    );
    listenTo(widget.signal, _on);
    ownTimer(Timer(const Duration(seconds: 1), _on));
    widget.port?.addListener(_on);
    onTeardown(() => widget.port?.removeListener(_on));
    _controller.addListener(_on);
    _focus?.addListener(_on);
    _anim = AnimationController(vsync: this)..addStatusListener(_on);
    // repo.commented().listen(_on);
    globalSignal.addListener(_on);
    _sub = repo.raw().listen(_on);
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {});
    WidgetsBinding.instance.addObserver(this);
    schedulePostFrame((_) => _on());
    WidgetsBinding.instance.addPostFrameCallback((_) => _on());
  }
}
''';
    expect(rawAttachmentsByClass(source), <String, int>{'_AState': 5});
  });
}
