import 'package:material_ui/material_ui.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/utils/components/library_section_tabs.dart';
import '../helpers/glass_unwrap.dart';

/// 视频库顶栏同一组分区（2026-10-07 用户录屏：手机竖屏切到「导入」后，右侧
/// 动作胶囊出现把页签胶囊挤窄，选中的「导入」被挤出可视区）。
const List<String> _labels = <String>['首页', '系列', '全部视频', '媒体服务器', '导入', '设置'];

/// 只有「导入」分区（下标 4）有页面动作，与视频库壳一致。
const int _sectionWithActions = 4;

/// 动作胶囊出现的时机：与选中变化同一帧，或像真实页面那样晚一帧登记进动作槽。
enum _ActionsTiming { sameFrame, nextFrame, animated }

class _Host extends StatefulWidget {
  const _Host({required this.initial, required this.timing});

  final int initial;
  final _ActionsTiming timing;

  @override
  State<_Host> createState() => _HostState();
}

class _HostState extends State<_Host> {
  late int _selected = widget.initial;
  late bool _actions = widget.initial == _sectionWithActions;

  /// 与选中值、可视宽都无关的一次重建。
  void rebuild() => setState(() {});

  void showActions() => setState(() => _actions = true);

  void _select(int value) {
    setState(() => _selected = value);
    final bool wantActions = value == _sectionWithActions;
    switch (widget.timing) {
      case _ActionsTiming.sameFrame:
      case _ActionsTiming.animated:
        setState(() => _actions = wantActions);
      case _ActionsTiming.nextFrame:
        WidgetsBinding.instance.addPostFrameCallback((Duration _) {
          if (mounted) setState(() => _actions = wantActions);
        });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Row(
      children: <Widget>[
        Expanded(
          child: FushiSectionTabBar<int>(
            tabs: <LibrarySectionTab<int>>[
              for (int i = 0; i < _labels.length; i++)
                LibrarySectionTab<int>(value: i, label: _labels[i]),
            ],
            selected: _selected,
            onChanged: _select,
            floating: true,
          ),
        ),
        // 三枚图标按钮的动作胶囊。
        if (widget.timing == _ActionsTiming.animated)
          AnimatedSize(
            duration: const Duration(milliseconds: 420),
            child: SizedBox(width: _actions ? 160 : 0, height: 56),
          )
        else if (_actions) ...<Widget>[
          const SizedBox(width: 8),
          const SizedBox(width: 152, height: 56),
        ],
      ],
    );
  }
}

Future<void> _pumpHost(
  WidgetTester tester, {
  required int initial,
  required _ActionsTiming timing,
  TextDirection direction = TextDirection.ltr,
  bool disableAnimations = false,
}) async {
  await tester.binding.setSurfaceSize(const Size(392, 200));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    MaterialApp(
      builder: (BuildContext context, Widget? child) => MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(disableAnimations: disableAnimations),
        child: child!,
      ),
      home: Scaffold(
        body: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Align(
            alignment: Alignment.topLeft,
            child: Directionality(
              textDirection: direction,
              child: _Host(initial: initial, timing: timing),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Rect _viewportRect(WidgetTester tester) => tester.getRect(
  find
      .descendant(
        of: glassUnwrap<TabBar>(find.byType(TabBar)),
        matching: find.byType(Scrollable),
      )
      .first,
);

Rect _tabRect(WidgetTester tester, String label) =>
    tester.getRect(find.widgetWithText(Tab, label));

void _expectFullyVisible(WidgetTester tester, String label) {
  final Rect viewport = _viewportRect(tester);
  final Rect tab = _tabRect(tester, label);
  expect(
    tab.left >= viewport.left - 0.5 && tab.right <= viewport.right + 0.5,
    isTrue,
    reason: '选中段「$label」必须完整落在页签可视区内：tab=$tab viewport=$viewport',
  );
}

void main() {
  for (final _ActionsTiming timing in _ActionsTiming.values) {
    testWidgets('切到有动作的分区后选中段仍可见（动作 ${timing.name}）', (
      WidgetTester tester,
    ) async {
      await _pumpHost(tester, initial: 3, timing: timing);
      _expectFullyVisible(tester, '媒体服务器');

      await tester.tap(find.widgetWithText(Tab, '导入'));
      await tester.pumpAndSettle();

      expect(
        find
            .byType(SizedBox)
            .evaluate()
            .any(
              (Element e) =>
                  <double>[152, 160].contains((e.widget as SizedBox).width),
            ),
        isTrue,
        reason: '动作胶囊应已出现、页签可视区被挤窄',
      );
      _expectFullyVisible(tester, '导入');
    });

    testWidgets('动作消失、页签变宽后选中段仍可见（动作 ${timing.name}）', (
      WidgetTester tester,
    ) async {
      await _pumpHost(tester, initial: 4, timing: timing);
      _expectFullyVisible(tester, '导入');

      await tester.tap(find.widgetWithText(Tab, '设置'));
      await tester.pumpAndSettle();
      _expectFullyVisible(tester, '设置');
    });
  }

  testWidgets('首帧就停在有动作的分区：选中段可见', (WidgetTester tester) async {
    await _pumpHost(tester, initial: 4, timing: _ActionsTiming.sameFrame);
    _expectFullyVisible(tester, '导入');
  });

  testWidgets('RTL 连续挤窄和放宽后选中段仍可见', (WidgetTester tester) async {
    await _pumpHost(
      tester,
      initial: 3,
      timing: _ActionsTiming.animated,
      direction: TextDirection.rtl,
    );
    tester.state<_HostState>(find.byType(_Host))._select(4);
    await tester.pumpAndSettle();
    _expectFullyVisible(tester, '导入');
    tester.state<_HostState>(find.byType(_Host))._select(5);
    await tester.pumpAndSettle();
    _expectFullyVisible(tester, '设置');
  });

  testWidgets('选中值不变且滚动已停止时，纯宽度变化仍将选中段滚入', (WidgetTester tester) async {
    await _pumpHost(tester, initial: 3, timing: _ActionsTiming.sameFrame);
    tester.state<_HostState>(find.byType(_Host)).showActions();
    await tester.pumpAndSettle();
    _expectFullyVisible(tester, '媒体服务器');
  });

  testWidgets('减弱动态效果下静止页签变窄，无需后续输入或动画帧即可滚入', (WidgetTester tester) async {
    await _pumpHost(
      tester,
      initial: 3,
      timing: _ActionsTiming.sameFrame,
      disableAnimations: true,
    );
    tester.state<_HostState>(find.byType(_Host)).showActions();
    await tester.pump();
    _expectFullyVisible(tester, '媒体服务器');
    await tester.pumpAndSettle();
  });

  testWidgets('旧动画恰好经过新居中目标时仍须停止旧动画', (WidgetTester tester) async {
    await _pumpHost(tester, initial: 3, timing: _ActionsTiming.sameFrame);
    final Finder selected = find.widgetWithText(Tab, '媒体服务器');
    final RenderObject tab = tester.renderObject(selected);
    final ScrollPosition position = Scrollable.of(
      tester.element(selected),
      axis: Axis.horizontal,
    ).position;
    final double target =
        RenderAbstractViewport.of(
          tab,
        ).getOffsetToReveal(tab, 0.5, axis: Axis.horizontal).offset +
        80;
    position.jumpTo(target);
    // 不推进时钟：宽度变窄后，旧 activity 正好停在新的居中目标上。
    position.animateTo(
      0,
      duration: const Duration(seconds: 1),
      curve: Curves.linear,
    );
    expect(position.isScrollingNotifier.value, isTrue);
    tester.state<_HostState>(find.byType(_Host)).showActions();
    await tester.pump();
    final double newTarget = RenderAbstractViewport.of(tab)
        .getOffsetToReveal(tab, 0.5, axis: Axis.horizontal)
        .offset
        .clamp(position.minScrollExtent, position.maxScrollExtent)
        .toDouble();
    expect(position.pixels, closeTo(newTarget, 0.5));
    expect(position.isScrollingNotifier.value, isFalse);
    await tester.pumpAndSettle();
    _expectFullyVisible(tester, '媒体服务器');
  });

  testWidgets('用户手动横滑离开选中段后，不因无关重建被拉回', (WidgetTester tester) async {
    await _pumpHost(tester, initial: 0, timing: _ActionsTiming.sameFrame);
    final double before = _tabRect(tester, '首页').left;
    await tester.drag(
      glassUnwrap<TabBar>(find.byType(TabBar)),
      const Offset(-300, 0),
    );
    await tester.pumpAndSettle();
    final double dragged = _tabRect(tester, '首页').left;
    expect(dragged, lessThan(before), reason: '拖滚应生效');

    // 宿主无关重建（选中值与可视宽都不变）不得把滚动位置拉回选中段。
    tester.state<_HostState>(find.byType(_Host)).rebuild();
    await tester.pumpAndSettle();
    expect(_tabRect(tester, '首页').left, dragged);
  });
}
