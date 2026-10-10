// 手机底栏布局「左右滑动切换功能模块」（反馈 8XMLWV4brz，2026-10-09）。
//
// 纯函数钉顺序 / 到头 / 反转 / RTL / 阈值；组件层用真的 [HomeModuleSwipeDetector]
// 钉手势边界：没人要的横滑切模块，子组件（横向列表）消费掉的、页内状态（多选，
// 经 [SectionPopScope] 登记）期间的、鼠标拖动、轻蹭、纵向滚动都不切。
import 'dart:ui' show PointerDeviceKind;

import 'package:flutter/rendering.dart' show SemanticsData, SemanticsNode;
import 'package:flutter/semantics.dart' show SemanticsAction;
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/models/home_tab.dart';
import 'package:fushi/src/pages/implementations/home_module_swipe.dart';
import 'package:fushi/src/utils/components/section_swipe_navigator.dart';
import 'package:fushi/src/utils/components/section_visibility.dart';
import 'package:material_ui/material_ui.dart';

const List<HomeTab> _tabs = <HomeTab>[
  HomeTab.home,
  HomeTab.books,
  HomeTab.manga,
  HomeTab.video,
  HomeTab.games,
  HomeTab.browse,
  HomeTab.dictionaries,
  HomeTab.settings,
];

void main() {
  group('homeSwipeTabs / homeModuleSwipeTarget', () {
    test('顺序同底栏，设置与查词（底栏旁的独立搜索钮）不参与', () {
      expect(homeSwipeTabs(tabs: _tabs, reversed: false), <HomeTab>[
        HomeTab.home,
        HomeTab.books,
        HomeTab.manga,
        HomeTab.video,
        HomeTab.games,
        HomeTab.browse,
      ]);
    });

    test('手指左移去右边那一项，右移回左边那一项，到头不循环', () {
      HomeTab? target(HomeTab current, {required bool left}) =>
          homeModuleSwipeTarget(
            tabs: _tabs,
            current: current,
            reversed: false,
            fingerTowardStart: left,
          );
      expect(target(HomeTab.home, left: true), HomeTab.books);
      expect(target(HomeTab.books, left: false), HomeTab.home);
      expect(target(HomeTab.home, left: false), isNull);
      expect(target(HomeTab.browse, left: true), isNull);
      // 不参与横滑的 tab 上不切。
      expect(target(HomeTab.settings, left: true), isNull);
      expect(target(HomeTab.dictionaries, left: false), isNull);
    });

    test('只在已启用的模块之间走：被关掉的模块不在 tabs 里就被跳过', () {
      const List<HomeTab> noHomeNoManga = <HomeTab>[
        HomeTab.books,
        HomeTab.video,
        HomeTab.settings,
      ];
      expect(
        homeModuleSwipeTarget(
          tabs: noHomeNoManga,
          current: HomeTab.books,
          reversed: false,
          fingerTowardStart: true,
        ),
        HomeTab.video,
      );
      expect(
        homeModuleSwipeTarget(
          tabs: noHomeNoManga,
          current: HomeTab.books,
          reversed: false,
          fingerTowardStart: false,
        ),
        isNull,
      );
    });

    test('反转导航栏：屏幕上的顺序整排镜像，手势跟着屏幕走', () {
      expect(
        homeModuleSwipeTarget(
          tabs: _tabs,
          current: HomeTab.books,
          reversed: true,
          fingerTowardStart: true,
        ),
        HomeTab.home,
      );
    });

    test('RTL：底栏整排镜像，手指左移去逻辑上的前一项', () {
      expect(
        homeModuleSwipeTarget(
          tabs: _tabs,
          current: HomeTab.books,
          reversed: false,
          fingerTowardStart: true,
          textDirection: TextDirection.rtl,
        ),
        HomeTab.home,
      );
    });

    test('阈值：拖过三成宽度，或至少 56 且同向甩出 400 以上', () {
      expect(
        homeModuleSwipeCommits(
          dragDistance: -130,
          velocity: 0,
          viewportWidth: 400,
        ),
        isTrue,
      );
      expect(
        homeModuleSwipeCommits(
          dragDistance: -60,
          velocity: -800,
          viewportWidth: 400,
        ),
        isTrue,
      );
      // 轻蹭：距离不够。
      expect(
        homeModuleSwipeCommits(
          dragDistance: -30,
          velocity: -2000,
          viewportWidth: 400,
        ),
        isFalse,
      );
      // 拖出去又往回甩：方向不一致。
      expect(
        homeModuleSwipeCommits(
          dragDistance: -60,
          velocity: 800,
          viewportWidth: 400,
        ),
        isFalse,
      );
    });
  });

  group('HomeModuleSwipeDetector', () {
    Future<_SwipeHostState> pumpHost(
      WidgetTester tester, {
      HomeTab initial = HomeTab.books,
      bool horizontalList = false,
      bool selectionMode = false,
      bool enabled = true,
    }) async {
      tester.view.physicalSize = const Size(400, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          home: _SwipeHost(
            initial: initial,
            horizontalList: horizontalList,
            selectionMode: selectionMode,
            enabled: enabled,
          ),
        ),
      );
      return tester.state<_SwipeHostState>(find.byType(_SwipeHost));
    }

    Finder content() => find.byKey(const ValueKey<String>('content'));

    testWidgets('没人要的横滑：手指左移切到底栏右边的模块，并播进场转场', (WidgetTester tester) async {
      final _SwipeHostState host = await pumpHost(tester);
      final State<_Probe> probe = tester.state(find.byType(_Probe));
      await tester.fling(content(), const Offset(-200, 0), 1000);
      await tester.pump();
      expect(host.current, HomeTab.manga);
      expect(
        tester.state(find.byType(_Probe)),
        same(probe),
        reason: '转场层的结构必须恒定：增删包装层会让保活 tab 的 State 整棵重挂',
      );
      // 进场转场：切换后第一帧新页还没到位（有位移 / 半透明）。
      double opacity() => tester
          .widget<Opacity>(
            find.byKey(const ValueKey<String>('home-module-swipe-transition')),
          )
          .opacity;
      expect(opacity(), lessThan(1), reason: '切换后新页从半透明进场');
      await tester.pumpAndSettle();
      expect(opacity(), 1);
      expect(find.text('manga'), findsOneWidget);

      await tester.fling(content(), const Offset(200, 0), 1000);
      await tester.pumpAndSettle();
      expect(host.current, HomeTab.books);
    });

    testWidgets('到头不循环', (WidgetTester tester) async {
      final _SwipeHostState host = await pumpHost(
        tester,
        initial: HomeTab.home,
      );
      await tester.fling(content(), const Offset(200, 0), 1000);
      await tester.pumpAndSettle();
      expect(host.current, HomeTab.home);
    });

    testWidgets('横向列表消费了手势：在列表上横滑只滚列表，不切模块', (WidgetTester tester) async {
      final _SwipeHostState host = await pumpHost(tester, horizontalList: true);
      final ScrollController list = host.listController;
      await tester.fling(
        find.byKey(const ValueKey<String>('carousel')),
        const Offset(-200, 0),
        1000,
      );
      await tester.pumpAndSettle();
      expect(host.current, HomeTab.books, reason: '子组件消费的横滑不得切模块');
      expect(list.offset, greaterThan(0), reason: '手势确实被横向列表拿去滚动了');

      // 同一页列表以外的空白处照常切。
      await tester.flingFrom(
        const Offset(200, 600),
        const Offset(-200, 0),
        1000,
      );
      await tester.pumpAndSettle();
      expect(host.current, HomeTab.manga);
    });

    testWidgets('页内状态（多选，经 SectionPopScope 拦返回）期间不切模块', (
      WidgetTester tester,
    ) async {
      final _SwipeHostState host = await pumpHost(tester, selectionMode: true);
      await tester.fling(content(), const Offset(-200, 0), 1000);
      await tester.pumpAndSettle();
      expect(host.current, HomeTab.books, reason: '不在模块根时横滑不得切走');

      host.setSelectionMode(false);
      await tester.pump();
      await tester.fling(content(), const Offset(-200, 0), 1000);
      await tester.pumpAndSettle();
      expect(host.current, HomeTab.manga, reason: '退出多选回到模块根后照常切');
    });

    testWidgets('库页自带分区横滑：中间分区只切分区，越过首 / 末分区才接力切模块', (
      WidgetTester tester,
    ) async {
      tester.view.physicalSize = const Size(400, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(const MaterialApp(home: _SectionHost()));
      final _SectionHostState host = tester.state(find.byType(_SectionHost));
      Finder page() => find.byKey(const ValueKey<String>('section-page'));

      // 第一个分区往左：分区横滑这一层更深、先赢，只切到第二个分区。
      await tester.fling(page(), const Offset(-200, 0), 1000);
      await tester.pumpAndSettle();
      expect(host.section, 1);
      expect(host.module, HomeTab.manga);

      // 末分区再往左：越界接力给外壳，切到底栏右边的模块。
      await tester.fling(page(), const Offset(-200, 0), 1000);
      await tester.pumpAndSettle();
      expect(host.section, 1);
      expect(host.module, HomeTab.video);

      // 回到首分区再往右：接力切到左边的模块。
      await tester.fling(page(), const Offset(200, 0), 1000);
      await tester.pumpAndSettle();
      expect(host.section, 0);
      await tester.fling(page(), const Offset(200, 0), 1000);
      await tester.pumpAndSettle();
      expect(host.module, HomeTab.manga);
    });

    testWidgets('只认触摸：鼠标拖动不切', (WidgetTester tester) async {
      final _SwipeHostState host = await pumpHost(tester);
      final TestGesture mouse = await tester.startGesture(
        tester.getCenter(content()),
        kind: PointerDeviceKind.mouse,
      );
      for (int i = 0; i < 10; i++) {
        await mouse.moveBy(const Offset(-30, 0));
        await tester.pump(const Duration(milliseconds: 10));
      }
      await mouse.up();
      await tester.pumpAndSettle();
      expect(host.current, HomeTab.books);
    });

    testWidgets('轻蹭与纵向滑动都不切', (WidgetTester tester) async {
      final _SwipeHostState host = await pumpHost(tester);
      await tester.drag(content(), const Offset(-30, 0));
      await tester.pumpAndSettle();
      expect(host.current, HomeTab.books);
      await tester.fling(content(), const Offset(10, -300), 1000);
      await tester.pumpAndSettle();
      expect(host.current, HomeTab.books);
    });

    testWidgets('enabled=false（桌面布局 / 设置页）不挂识别器', (WidgetTester tester) async {
      final _SwipeHostState host = await pumpHost(tester, enabled: false);
      await tester.fling(content(), const Offset(-200, 0), 1000);
      await tester.pumpAndSettle();
      expect(host.current, HomeTab.books);
    });

    testWidgets('外壳横滑不给正文加无障碍横滚动作（读屏不能误切模块）', (
      WidgetTester tester,
    ) async {
      final SemanticsHandle semantics = tester.ensureSemantics();
      await pumpHost(tester);
      final SemanticsNode root = tester.getSemantics(
        find.byType(HomeModuleSwipeDetector),
      );
      bool hasHorizontalScroll(SemanticsNode node) {
        final SemanticsData data = node.getSemanticsData();
        if (data.hasAction(SemanticsAction.scrollLeft) ||
            data.hasAction(SemanticsAction.scrollRight)) {
          return true;
        }
        bool found = false;
        node.visitChildren((SemanticsNode child) {
          found = found || hasHorizontalScroll(child);
          return !found;
        });
        return found;
      }

      expect(hasHorizontalScroll(root), isFalse);
      semantics.dispose();
    });
  });
}

/// 最小宿主：持有当前 tab，像 HomePage 一样把 [HomeModuleSwipeDetector] 包在 tab
/// 内容外面；内容可带一条横向列表（子组件消费手势）与多选的 [SectionPopScope]。
class _SwipeHost extends StatefulWidget {
  const _SwipeHost({
    required this.initial,
    required this.horizontalList,
    required this.selectionMode,
    required this.enabled,
  });

  final HomeTab initial;
  final bool horizontalList;
  final bool selectionMode;
  final bool enabled;

  @override
  State<_SwipeHost> createState() => _SwipeHostState();
}

class _SwipeHostState extends State<_SwipeHost> {
  late HomeTab current = widget.initial;
  late bool _selectionMode = widget.selectionMode;
  final ModuleRootTracker _tracker = ModuleRootTracker();
  final ScrollController listController = ScrollController();

  void setSelectionMode(bool value) => setState(() => _selectionMode = value);

  @override
  void dispose() {
    listController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: HomeModuleSwipeDetector(
        enabled: widget.enabled,
        tracker: _tracker,
        targetFor: ({required bool fingerTowardStart}) => homeModuleSwipeTarget(
          tabs: _tabs,
          current: current,
          reversed: false,
          fingerTowardStart: fingerTowardStart,
        ),
        onSwipe: (HomeTab tab) => setState(() => current = tab),
        child: SectionPopScope(
          intercepting: _selectionMode,
          onIntercept: () => setSelectionMode(false),
          child: Column(
            key: const ValueKey<String>('content'),
            children: <Widget>[
              if (widget.horizontalList)
                SizedBox(
                  key: const ValueKey<String>('carousel'),
                  height: 160,
                  child: ListView.builder(
                    controller: listController,
                    scrollDirection: Axis.horizontal,
                    itemCount: 30,
                    itemBuilder: (BuildContext context, int i) =>
                        SizedBox(width: 120, child: Text('cover $i')),
                  ),
                ),
              const _Probe(),
              Expanded(
                child: ListView(
                  children: <Widget>[
                    Text(current.name),
                    for (int i = 0; i < 60; i++)
                      SizedBox(height: 40, child: Text('row $i')),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 状态探针：转场前后必须是同一个 State（保活 tab 不得因转场重挂）。
class _Probe extends StatefulWidget {
  const _Probe();

  @override
  State<_Probe> createState() => _ProbeState();
}

class _ProbeState extends State<_Probe> {
  @override
  Widget build(BuildContext context) => const SizedBox(height: 1);
}

/// 模拟库页：外壳的 [HomeModuleSwipeDetector] 里套一层两分区的
/// [SectionSwipeNavigator]（书架页 / 视频页的真实结构）。
class _SectionHost extends StatefulWidget {
  const _SectionHost();

  @override
  State<_SectionHost> createState() => _SectionHostState();
}

class _SectionHostState extends State<_SectionHost> {
  HomeTab module = HomeTab.manga;
  int section = 0;
  final ModuleRootTracker _tracker = ModuleRootTracker();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: HomeModuleSwipeDetector(
        enabled: true,
        tracker: _tracker,
        targetFor: ({required bool fingerTowardStart}) => homeModuleSwipeTarget(
          tabs: _tabs,
          current: module,
          reversed: false,
          fingerTowardStart: fingerTowardStart,
        ),
        onSwipe: (HomeTab tab) => setState(() => module = tab),
        child: SectionSwipeNavigator<int>(
          sections: const <int>[0, 1],
          selected: section,
          onSelect: (int value) => setState(() => section = value),
          child: SizedBox.expand(
            key: const ValueKey<String>('section-page'),
            child: Text('${module.name} / $section'),
          ),
        ),
      ),
    );
  }
}
