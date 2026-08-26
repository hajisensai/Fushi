import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fushi/src/focus/fushi_focus_controller.dart';
import 'package:fushi/src/pages/implementations/media_library_shell.dart';
import 'package:fushi/utils.dart';

/// [MediaLibraryShell] 的行为守卫（PR#550 审查补）。
///
/// 这三条是壳的**卖点**，此前全靠源码注释声明、零测试：
///  1. 分段条包在 [FushiAdjustableSegmented] 里——裸 `SegmentedButton` 会被只遍历
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
    final FushiSectionTabBar<MediaLibraryViewKind> strip = tester.widget(
      find.byType(FushiSectionTabBar<MediaLibraryViewKind>),
    );
    strip.onChanged!(kind);
    await tester.pumpAndSettle();
  }

  testWidgets('分区导航包在 FushiAdjustableSegmented 里（裸 TabBar 即转红）',
      (WidgetTester tester) async {
    await tester.pumpWidget(harness(<MediaLibraryViewSpec>[
      spec(0, MediaLibraryViewKind.library, '书架'),
      spec(1, MediaLibraryViewKind.browse, '浏览'),
      spec(2, MediaLibraryViewKind.sources, '来源'),
    ]));

    expect(
      find.byType(FushiAdjustableSegmented<MediaLibraryViewKind>),
      findsOneWidget,
      reason: '方向焦点控制器只遍历已注册 target；裸 TabBar 会被整个跳过，'
          '手柄/键盘用户切不了视图',
    );
    // 且它必须真的包着本壳的分区导航（不是树里别处碰巧有一个）。
    expect(
      find.descendant(
        of: find.byType(FushiAdjustableSegmented<MediaLibraryViewKind>),
        matching: find.byType(FushiSectionTabBar<MediaLibraryViewKind>),
      ),
      findsOneWidget,
    );
    // focusIdPrefix 必须透传：多域同时挂载时靠它区分停靠点。
    final FushiAdjustableSegmented<MediaLibraryViewKind> seg = tester
        .widget(find.byType(FushiAdjustableSegmented<MediaLibraryViewKind>));
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
    expect(find.byType(FushiAdjustableSegmented<MediaLibraryViewKind>),
        findsOneWidget);
  });

  testWidgets('分段导航注册可由 controller.requestById 定位的稳定 ID',
      (WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: FushiFocusRoot(
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

    final FushiFocusController controller = FushiFocusRoot.controllerOf(
      tester.element(find.byType(MediaLibraryShell)),
    );
    const FushiFocusId sectionsId =
        FushiFocusId('test-library-view-sections');
    expect(controller.requestById(sectionsId), isTrue);
    await tester.pump();
    expect(controller.activeId, sectionsId);
    expect(controller.primaryFocusIsManagedTarget, isTrue);
  });

  testWidgets('只有一个视图时不显示导航条（不放空壳 tab）', (WidgetTester tester) async {
    await tester.pumpWidget(harness(<MediaLibraryViewSpec>[
      spec(0, MediaLibraryViewKind.library, '书架'),
    ]));
    expect(find.byType(FushiAdjustableSegmented<MediaLibraryViewKind>),
        findsNothing);
    expect(probe.gotRealNavigation[0], isFalse);
  });

  // -------------------------------------------------------------------------
  // 导航所有权（BUG-1871 复审）
  // -------------------------------------------------------------------------
  //
  // 空态引导按钮要把用户从「压在壳上面的页面」带回壳里的某个视图。此前这一步的
  // 正确性被硬编码成「调用页正好是壳上面唯一一层路由」：调用页先 pop 自己再调
  // select。第二个调用点（发现详情页 → 全源搜索页）就是两层，pop 一层后详情页
  // 仍盖在壳上面，用户看不到切过去的视图。现在 pop 收进 [MediaLibraryShellScope
  // .select]，以壳自己的路由为界一次弹到底，调用方压了几层都对。

  MediaLibraryViewSpec pushingSpec(MediaLibraryViewKind kind, String label) {
    return MediaLibraryViewSpec(
      kind: kind,
      label: label,
      builder: (BuildContext context, Widget navigation) => Column(
        children: <Widget>[
          navigation,
          Builder(
            builder: (BuildContext inner) => TextButton(
              onPressed: () => Navigator.of(inner).push(
                MaterialPageRoute<void>(
                  builder: (_) => _PushedPage(
                    label: '第一层',
                    onOpenSources: MediaLibraryShellScope.maybeOf(inner)
                        ?.actionFor(MediaLibraryViewKind.sources),
                  ),
                ),
              ),
              child: const Text('push'),
            ),
          ),
        ],
      ),
    );
  }

  testWidgets('压一层路由：切视图时壳自己把它弹掉', (WidgetTester tester) async {
    await tester.pumpWidget(harness(<MediaLibraryViewSpec>[
      pushingSpec(MediaLibraryViewKind.library, '书架'),
      spec(1, MediaLibraryViewKind.sources, '导入'),
    ]));
    await tester.tap(find.text('push'));
    await tester.pumpAndSettle();
    expect(find.text('第一层'), findsOneWidget);

    await tester.tap(find.text('去来源'));
    await tester.pumpAndSettle();

    expect(find.text('第一层'), findsNothing, reason: '壳上面的路由必须被弹掉');
    expect(probe.gotRealNavigation[1], isTrue, reason: '壳切到了「导入」视图');
  });

  testWidgets('压两层路由：同一个调用点照样一次弹干净（第二个入口不需要另写一套）',
      (WidgetTester tester) async {
    await tester.pumpWidget(harness(<MediaLibraryViewSpec>[
      pushingSpec(MediaLibraryViewKind.library, '书架'),
      spec(1, MediaLibraryViewKind.sources, '导入'),
    ]));
    await tester.tap(find.text('push'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('再推一层'));
    await tester.pumpAndSettle();
    expect(find.text('第一层+'), findsOneWidget);

    // 最上面那一层的按钮（下面的路由仍在树里）。
    await tester.tap(find.text('去来源').last);
    await tester.pumpAndSettle();

    expect(find.text('第一层'), findsNothing);
    expect(find.text('第一层+'), findsNothing);
    expect(probe.gotRealNavigation[1], isTrue);
  });

  testWidgets('actionFor：壳没有声明该视图时返回 null（判据是「视图在」不是「壳在」）',
      (WidgetTester tester) async {
    late MediaLibraryShellScope scope;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: MediaLibraryShell(
          focusIdPrefix: 'test-library-view',
          views: <MediaLibraryViewSpec>[
            MediaLibraryViewSpec(
              kind: MediaLibraryViewKind.library,
              label: '书架',
              builder: (BuildContext context, Widget navigation) => Builder(
                builder: (BuildContext inner) {
                  scope = MediaLibraryShellScope.maybeOf(inner)!;
                  return const SizedBox.shrink();
                },
              ),
            ),
          ],
        ),
      ),
    ));
    await tester.pump();

    expect(scope.actionFor(MediaLibraryViewKind.sources), isNull,
        reason: '没有「导入」视图时必须给 null——select 对它是静默忽略，'
            '照「壳在」渲染出来的按钮点了什么都不会发生');
    expect(scope.actionFor(MediaLibraryViewKind.library), isNotNull);
  });
}

/// 压在壳上面的页面：可以再推一层，也可以按引导按钮切壳视图。
class _PushedPage extends StatelessWidget {
  const _PushedPage({required this.label, required this.onOpenSources});

  final String label;
  final VoidCallback? onOpenSources;

  @override
  Widget build(BuildContext context) => Scaffold(
        body: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Text(label),
            if (onOpenSources != null)
              TextButton(onPressed: onOpenSources, child: const Text('去来源')),
            TextButton(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => _PushedPage(
                    label: '$label+',
                    onOpenSources: onOpenSources,
                  ),
                ),
              ),
              child: const Text('再推一层'),
            ),
          ],
        ),
      );
}
