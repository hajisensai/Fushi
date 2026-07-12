import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 保活机制的行为验证（配 home_tab_keepalive_guard_test.dart 的源码守卫）：
///
/// HomePage.buildBody 用「Offstage 保活（books/video）+ KeyedSubtree 按需（其余 tab）」
/// 消除「切回 tab 重新联网加载远端」。HomePage 本身在 headless 测试无法挂载（AppModel
/// 未初始化），故这里用**同构 stub** 复刻 buildBody 的结构，直接断言不变式：
///   - 保活 tab 切走再切回 State 存活、initState **只跑一次**（不会重拉远端）；
///   - 按需 tab 每次切入 State 重建、initState **每次都跑**（保留 TODO-376 re-mount 语义）。
void main() {
  testWidgets('保活 tab initState 只跑一次；按需 tab 每次重建', (WidgetTester tester) async {
    final Map<String, int> initCounts = <String, int>{};
    final _TabShellController controller = _TabShellController();

    await tester.pumpWidget(
      MaterialApp(
        home: _KeepAliveTabShell(
          controller: controller,
          onInit: (String tab) => initCounts[tab] = (initCounts[tab] ?? 0) + 1,
        ),
      ),
    );

    // 初始可见保活 tab A：init 一次。
    expect(initCounts['A'], 1);
    expect(initCounts['B'], isNull, reason: '未访问的保活 tab 惰性构建，不预建');

    // 切到保活 tab B：B init 一次，A 仍存活（不重建）。
    controller.select('B');
    await tester.pump();
    expect(initCounts['B'], 1);
    expect(initCounts['A'], 1, reason: 'A 被 Offstage 保活，切走时 State 不销毁');

    // 切回保活 tab A：A 的 initState **不再跑**——这正是「切回不重新加载远端」的证据。
    controller.select('A');
    await tester.pump();
    expect(initCounts['A'], 1, reason: '保活 tab 切回不 re-mount，故不重拉远端列表/封面');

    // 切到按需 tab C：init 一次。
    controller.select('C');
    await tester.pump();
    expect(initCounts['C'], 1);

    // 离开再回按需 tab C：每次都重建（initState 再跑）——保留挂载语义（TODO-376）。
    controller.select('A');
    await tester.pump();
    controller.select('C');
    await tester.pump();
    expect(initCounts['C'], 2, reason: '按需 tab 切走即销毁、切回重建，故 initState 每次都跑');

    // 全程保活 tab A / B 的 init 计数不因来回切而增长。
    expect(initCounts['A'], 1);
    expect(initCounts['B'], 1);
  });
}

/// 简单的可见 tab 控制器（替代 HomePage 的 _visibleTab / _selectTab）。
class _TabShellController extends ChangeNotifier {
  String visible = 'A';
  void select(String tab) {
    visible = tab;
    notifyListeners();
  }
}

/// 与 HomePage.buildBody 同构：A/B 为保活 tab（Offstage + 惰性），C 为按需 tab
/// （KeyedSubtree，只在可见时构建）。
class _KeepAliveTabShell extends StatefulWidget {
  const _KeepAliveTabShell({required this.controller, required this.onInit});

  final _TabShellController controller;
  final void Function(String tab) onInit;

  @override
  State<_KeepAliveTabShell> createState() => _KeepAliveTabShellState();
}

class _KeepAliveTabShellState extends State<_KeepAliveTabShell> {
  static const Set<String> _keepAliveTabs = <String>{'A', 'B'};
  final Set<String> _visited = <String>{};

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onChange);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onChange);
    super.dispose();
  }

  void _onChange() => setState(() {});

  @override
  Widget build(BuildContext context) {
    final String visible = widget.controller.visible;
    if (_keepAliveTabs.contains(visible)) _visited.add(visible);
    return Stack(
      fit: StackFit.expand,
      children: <Widget>[
        for (final String tab in _keepAliveTabs)
          if (_visited.contains(tab))
            Offstage(
              key: ValueKey<String>(tab),
              offstage: visible != tab,
              child: _CountingPage(tab: tab, onInit: widget.onInit),
            ),
        if (!_keepAliveTabs.contains(visible))
          KeyedSubtree(
            key: ValueKey<String>(visible),
            child: _CountingPage(tab: visible, onInit: widget.onInit),
          ),
      ],
    );
  }
}

/// initState 时上报一次的 stub 页（模拟视频/书架页 initState 里的远端加载触发）。
class _CountingPage extends StatefulWidget {
  const _CountingPage({required this.tab, required this.onInit});

  final String tab;
  final void Function(String tab) onInit;

  @override
  State<_CountingPage> createState() => _CountingPageState();
}

class _CountingPageState extends State<_CountingPage> {
  @override
  void initState() {
    super.initState();
    widget.onInit(widget.tab);
  }

  @override
  Widget build(BuildContext context) => Text('tab-${widget.tab}');
}
