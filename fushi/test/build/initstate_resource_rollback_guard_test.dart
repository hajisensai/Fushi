import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'initstate_resource_scan.dart';

/// State 生命周期里挂外部资源必须经 `StateResourceScope` 登记（BUG-5604）。
///
/// initState（或首次 didChangeDependencies）半途抛错时 Flutter 只停用元素、永不调
/// dispose，`mounted` 也一直是 true；didUpdateWidget 抛错时父级把整棵旧子树停用后直接
/// 丢掉，同样永不 dispose。抛错点之前直接挂上的流订阅 / 监听 / Timer / 观察者 /
/// 赋出去的回调于是成了孤儿：回调之后在停用的元素上读 `ref` / `context` 即断言，并且
/// 泄漏（BUG-5602、BUG-5604）。登记过的资源由 `StateResourceScope` 在这些路径与
/// dispose 共用一份清单撤销。
///
/// 扫描器（`initstate_resource_scan.dart`）用 package:analyzer 解析语法树：从
/// `initState` / `didChangeDependencies` / `didUpdateWidget` 出发，顺着调用的本类
/// 私有方法展开，按执行顺序判断每处挂资源之前（或紧跟其后）有没有匹配的撤销登记。
/// 规则细节见扫描器文件头。
///
/// 零容忍：`lib/` 下出现一处裸挂即红。
void main() {
  test('生命周期方法挂的外部资源一律经 StateResourceScope 登记（零容忍）', () {
    final List<RawAttachment> actual = scanLifecycleRawAttachments(
      Directory('lib'),
    );
    expect(
      actual.map((RawAttachment a) => a.toString()).toList(),
      isEmpty,
      reason:
          '生命周期方法（含经私有 helper 展开的部分）里有裸挂的订阅 / 监听 / Timer / '
          '观察者 / post-frame 回调 / 赋给别的对象的回调。改成 StateResourceScope 的 '
          'ownSubscription / listenTo / ownTimer / schedulePostFrame，或在挂之前'
          '（或紧跟其后）用 onTeardown 登记撤销（State 需 `with StateResourceScope<W>`，'
          'BasePageState 家族已自带）。',
    );
  });

  test('扫描器自检：已登记 / 自建对象 / 先登记的撤销不计，裸挂逐条报出', () {
    const String source = '''
class _AState extends State<A> with StateResourceScope<A> {
  final ScrollController _controller = ScrollController();
  FocusNode? _focus = FocusNode();
  late AnimationController _anim;
  StreamSubscription<int>? _sub;
  Timer? _timer;
  Task? _task;

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
    globalSignal.addListener(_on); // 1
    _sub = repo.raw().listen(_on); // 2
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {}); // 3
    WidgetsBinding.instance.addObserver(this); // 4
    schedulePostFrame((_) => _on());
    WidgetsBinding.instance.addPostFrameCallback((_) => _on()); // 5
    onTeardown(() => _task?.removeListener(_onTask));
    _attach(widget.task);
    _hook(); // 6（经 helper 展开）
    service.onEvent = _on; // 7（赋出去的回调）
    service.onOther = _on;
    onTeardown(() => service.onOther = null);
    later(() => other.addListener(_on));
  }

  @override
  void didUpdateWidget(A old) {
    super.didUpdateWidget(old);
    old.port.addListener(_on); // 8
  }

  void _attach(Task? task) {
    _task?.removeListener(_onTask);
    _task = task;
    task?.addListener(_onTask);
  }

  void _hook() {
    hub.addHandler(_onKey);
  }

  void _on() {}
  void _onTask() {}
  bool _onKey(KeyEvent e) => false;
}
''';
    final List<RawAttachment> found = rawAttachmentsInSource(source);
    expect(
      found.map((RawAttachment a) => '${a.root}: ${a.code}').toList(),
      <String>[
        'initState: globalSignal.addListener(_on)',
        'initState: repo.raw().listen(_on)',
        'initState: Timer.periodic(const Duration(seconds: 1), (_) {})',
        'initState: WidgetsBinding.instance.addObserver(this)',
        'initState: WidgetsBinding.instance.addPostFrameCallback((_) => _on())',
        'initState: hub.addHandler(_onKey)',
        'initState: service.onEvent = _on',
        'didUpdateWidget: old.port.addListener(_on)',
      ],
    );
  });
}
