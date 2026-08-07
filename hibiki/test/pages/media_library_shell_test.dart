import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fushi/src/focus/hibiki_focus_controller.dart';
import 'package:fushi/src/pages/implementations/media_library_shell.dart';
import 'package:fushi/utils.dart';

/// [MediaLibraryShell] 的行为守卫（PR#550 审查补）。
///
/// 这三条是壳的**卖点**，此前全靠源码注释声明、零测试：
///  1. 分段条包在 [HibikiAdjustableSegmented] 里——裸 `SegmentedButton` 会被只遍历
///     已注册 target 的方向焦点控制器整个跳过，手柄/键盘用户切不了视图。
///  2. 惰性构建——没访问过的视图**根本不构造**，所以在线目录不会因为壳挂载就发网络
///     请求。这里直接数 builder 调用次数：builder 没跑 ⇒ 它内部的 initState /
///     网络请求不可能跑，比 mock 网络层更强的结构性证明。
///  3. 导航条只交给**当前**视图——同一个 focusIdPrefix 注册两次会互相打架。
///
/// 手柄真机切视图不在本层可证（合成事件与 widget 测试同层），见审查报告。

/// 记录每次 builder 调用收到的 navigation 是不是「真导航条」。
class _Probe {
  final List<int> buildOrder = <int>[];
  final Map<int, int> buildCount = <int, int>{};
  final Map<int, bool> gotRealNavigation = <int, bool>{};
}

/// 视图内容：`initState` 只在**首次构造**时跑，用来验保活（切走再切回不重建）。
class _StatefulLeaf extends StatefulWidget {
  const _StatefulLeaf({required this.onInit, required this.label});
  final VoidCallback onInit;
  final String label;
  @override
  State<_StatefulLeaf> createState() => _StatefulLeafState();
}

class _StatefulLeafState extends State<_StatefulLeaf> {
  @override
  void initState() {
    super.initState();
    widget.onInit();
  }

  @override
  Widget build(BuildContext context) => Text(widget.label);
}

void main() {
  late _Probe probe;
  late Map<int, int> initCount;

  MediaLibraryViewSpec spec(
      int index, MediaLibraryViewKind kind, String label) {
    return MediaLibraryViewSpec(
      kind: kind,
      label: label,
      builder: (BuildContext context, Widget navigation) {
        probe.buildOrder.add(index);
        probe.buildCount[index] = (probe.buildCount[index] ?? 0) + 1;
        // 壳给非当前视图的是 `SizedBox.shrink()`；真导航条是别的类型。
        probe.gotRealNavigation[index] =
            navigation is! SizedBox || navigation.width != 0;
        return Column(
          children: <Widget>[
            navigation,
            _StatefulLeaf(
              label: label,
              onInit: () => initCount[index] = (initCount[index] ?? 0) + 1,
            ),
          ],
        );
      },
    );
  }

  Widget harness(List<MediaLibraryViewSpec> views) => MaterialApp(
        home: Scaffold(
          body: MediaLibraryShell(
            focusIdPrefix: 'test-library-view',
            views: views,
          ),
        ),
      );

  setUp(() {
    probe = _Probe();
    initCount = <int, int>{};
  });

  /// 驱动壳切换视图：走分段条自己的 onChanged（证明壳与分段条真的接上了），
  /// 而不是绕过 UI 直接调 State 的私有方法。
  Future<void> selectVia(
    WidgetTester tester,
    MediaLibraryViewKind kind,
  ) async {
    final HibikiSegmentedStrip<MediaLibraryViewKind> strip = tester.widget(
      find.byType(HibikiSegmentedStrip<MediaLibraryViewKind>),
    );
    strip.onChanged(kind);
    await tester.pumpAndSettle();
  }

  testWidgets('分段条包在 HibikiAdjustableSegmented 里（裸 SegmentedButton 即转红）',
      (WidgetTester tester) async {
    await tester.pumpWidget(harness(<MediaLibraryViewSpec>[
      spec(0, MediaLibraryViewKind.library, '书架'),
      spec(1, MediaLibraryViewKind.browse, '浏览'),
      spec(2, MediaLibraryViewKind.sources, '来源'),
    ]));

    expect(
      find.byType(HibikiAdjustableSegmented<MediaLibraryViewKind>),
      findsOneWidget,
      reason: '方向焦点控制器只遍历已注册 target；裸 SegmentedButton 会被整个跳过，'
          '手柄/键盘用户切不了视图',
    );
    // 且它必须真的包着本壳的分段条（不是树里别处碰巧有一个）。
    expect(
      find.descendant(
        of: find.byType(HibikiAdjustableSegmented<MediaLibraryViewKind>),
        matching: find.byType(HibikiSegmentedStrip<MediaLibraryViewKind>),
      ),
      findsOneWidget,
    );
    // focusIdPrefix 必须透传：多域同时挂载时靠它区分停靠点。
    final HibikiAdjustableSegmented<MediaLibraryViewKind> seg = tester
        .widget(find.byType(HibikiAdjustableSegmented<MediaLibraryViewKind>));
    expect(seg.focusIdPrefix, 'test-library-view');
  });

  testWidgets('惰性构建：未访问的视图 builder 从不被调用（在线目录不会因挂载就发请求）',
      (WidgetTester tester) async {
    await tester.pumpWidget(harness(<MediaLibraryViewSpec>[
      spec(0, MediaLibraryViewKind.library, '书架'),
      spec(1, MediaLibraryViewKind.browse, '浏览'),
      spec(2, MediaLibraryViewKind.sources, '来源'),
    ]));

    expect(probe.buildOrder.toSet(), <int>{0},
        reason: '只有落点视图被构造；builder 没跑 ⇒ 其 initState / 网络请求不可能跑');
    expect(probe.buildCount[1], isNull, reason: '「浏览」（在线目录）绝不能因为壳挂载就构造');
    expect(initCount[1], isNull);
    expect(initCount[2], isNull);

    await selectVia(tester, MediaLibraryViewKind.browse);
    expect(initCount[1], 1, reason: '访问后才构造');
    expect(initCount[2], isNull, reason: '仍未访问的「来源」依然不构造');
  });

  testWidgets('保活：切走再切回不重建 State（滚动位置/搜索词得以保留）', (WidgetTester tester) async {
    await tester.pumpWidget(harness(<MediaLibraryViewSpec>[
      spec(0, MediaLibraryViewKind.library, '书架'),
      spec(1, MediaLibraryViewKind.browse, '浏览'),
    ]));
    expect(initCount[0], 1);

    await selectVia(tester, MediaLibraryViewKind.browse);
    expect(initCount[1], 1);
    await selectVia(tester, MediaLibraryViewKind.library);
    await selectVia(tester, MediaLibraryViewKind.browse);

    expect(initCount[0], 1, reason: '切走的视图 State 必须留着（Offstage 而非卸载）');
    expect(initCount[1], 1, reason: '切回不得重建——重建就丢滚动位置与搜索词');
  });

  testWidgets('导航条只交给当前视图（同一 focusIdPrefix 注册两次会互相打架）',
      (WidgetTester tester) async {
    await tester.pumpWidget(harness(<MediaLibraryViewSpec>[
      spec(0, MediaLibraryViewKind.library, '书架'),
      spec(1, MediaLibraryViewKind.browse, '浏览'),
    ]));
    expect(probe.gotRealNavigation[0], isTrue);

    await selectVia(tester, MediaLibraryViewKind.browse);
    expect(probe.gotRealNavigation[1], isTrue, reason: '当前视图拿真导航条');
    expect(probe.gotRealNavigation[0], isFalse,
        reason: '隐藏视图必须拿空占位，否则同一 focusIdPrefix 被注册两次');
    // 全树自始至终只有一个分段条。
    expect(find.byType(HibikiAdjustableSegmented<MediaLibraryViewKind>),
        findsOneWidget);
  });

  testWidgets('分段导航注册可由 controller.requestById 定位的稳定 ID',
      (WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: HibikiFocusRoot(
            child: MediaLibraryShell(
              focusIdPrefix: 'test-library-view',
              views: <MediaLibraryViewSpec>[
                spec(0, MediaLibraryViewKind.library, '书架'),
                spec(1, MediaLibraryViewKind.sources, '来源'),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    final HibikiFocusController controller = HibikiFocusRoot.controllerOf(
      tester.element(find.byType(MediaLibraryShell)),
    );
    const HibikiFocusId sectionsId =
        HibikiFocusId('test-library-view-sections');
    expect(controller.requestById(sectionsId), isTrue);
    await tester.pump();
    expect(controller.activeId, sectionsId);
    expect(controller.primaryFocusIsManagedTarget, isTrue);
  });

  testWidgets('只有一个视图时不显示导航条（不放空壳 tab）', (WidgetTester tester) async {
    await tester.pumpWidget(harness(<MediaLibraryViewSpec>[
      spec(0, MediaLibraryViewKind.library, '书架'),
    ]));
    expect(find.byType(HibikiAdjustableSegmented<MediaLibraryViewKind>),
        findsNothing);
    expect(probe.gotRealNavigation[0], isFalse);
  });
}
