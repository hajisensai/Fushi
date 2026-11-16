import 'package:material_ui/material_ui.dart';
import 'package:flutter/rendering.dart' show RenderParagraph;
import 'package:flutter/services.dart' show LogicalKeyboardKey;
import 'package:flutter_test/flutter_test.dart';

import 'package:fushi/src/focus/fushi_focus_controller.dart';
import 'package:fushi/src/pages/implementations/media_library_shell.dart';
import 'package:fushi/src/utils/components/fushi_floating_chrome.dart'
    show FushiFloatingChromeBar, FushiFloatingChromeSoloTitle;
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/utils/components/fushi_icon_button.dart';
import 'package:fushi/src/utils/components/section_swipe_navigator.dart';
import 'package:fushi/src/utils/components/settings_shared.dart';
import 'package:fushi/src/utils/components/fushi_page_masthead.dart'
    show FushiMastheadTitle;
import '../helpers/masthead_tabs.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_bars.dart'
    show FushiShellTitleScope;

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
    int index,
    MediaLibraryViewKind kind,
    String label,
  ) {
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
      body: MediaLibraryShell(focusIdPrefix: 'test-library-view', views: views),
    ),
  );

  setUp(() {
    probe = _Probe();
    initCount = <int, int>{};
  });

  MastheadTabsView<MediaLibraryViewKind> read(
    WidgetTester tester,
    Finder finder,
  ) => readMastheadTabs<MediaLibraryViewKind>(tester, finder);

  /// 当前组的二级页签（大字行里的连体按钮组）；当前组只有一个视图或停在导入页
  /// 时没有。
  Finder subStrip() => mastheadSecondaryTabs<MediaLibraryViewKind>();

  /// 驱动壳切换视图：走分段条自己的 onChanged（证明壳与分段条真的接上了），
  /// 而不是绕过 UI 直接调 State 的私有方法。
  Future<void> selectVia(WidgetTester tester, MediaLibraryViewKind kind) async {
    // 组内有多个视图时大字行里还有一排二级页签；两排的 onChanged 都是壳的同一个
    // 切换入口，优先取一级切换（一级只剩一组时不画，取二级）。
    final Finder primary = mastheadPrimaryTabs<MediaLibraryViewKind>();
    final MastheadTabsView<MediaLibraryViewKind> strip = read(
      tester,
      primary.evaluate().isNotEmpty ? primary : subStrip(),
    );
    strip.onChanged(kind);
    await tester.pumpAndSettle();
  }

  /// 浮动工具栏（页头大字顶栏）里的一级切换。
  Finder topStrip() => find.descendant(
    of: find.byType(FushiFloatingChromeBar),
    matching: mastheadPrimaryTabs<MediaLibraryViewKind>(),
  );

  List<MediaLibraryViewKind> valuesOf(
    MastheadTabsView<MediaLibraryViewKind> strip,
  ) => strip.values;

  /// 树上一级切换 + 二级页签的总排数。
  int stripCount() =>
      mastheadPrimaryTabs<MediaLibraryViewKind>().evaluate().length +
      subStrip().evaluate().length;

  /// 工具栏右端的「导入」圆钮（切换型）。
  FushiIconButton importButton(WidgetTester tester) => tester.widget(
    find.byKey(const ValueKey<String>('test-library-view-import')),
  );

  Future<void> tapImport(WidgetTester tester) async {
    importButton(tester).onTap!();
    await tester.pumpAndSettle();
  }

  /// 树上全部分段导航的焦点前缀（一级 + 二级）。
  List<String> segmentedPrefixes(WidgetTester tester) => <String>[
    for (final FushiAdjustableSegmented<MediaLibraryViewKind> seg
        in tester.widgetList<FushiAdjustableSegmented<MediaLibraryViewKind>>(
          find.byType(FushiAdjustableSegmented<MediaLibraryViewKind>),
        ))
      seg.focusIdPrefix,
  ];

  // 2026-10-30 用户拍板方案 D：顶栏一级只剩「我的」/「在线」两组，组内多视图由
  // 顶栏下方的二级胶囊切换；导入不再是页签，是工具栏右端的切换型圆钮。
  testWidgets('一级只放两组：书架 / 在线；在线组内二级胶囊是来源 / 扩展，点组页签回到上次停留处', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      harness(<MediaLibraryViewSpec>[
        spec(0, MediaLibraryViewKind.library, '书架'),
        spec(1, MediaLibraryViewKind.onlineSources, '来源'),
        spec(2, MediaLibraryViewKind.extensions, '扩展'),
        spec(3, MediaLibraryViewKind.sources, '导入'),
      ]),
    );
    await tester.pumpAndSettle();

    MastheadTabsView<MediaLibraryViewKind> top = read(tester, topStrip());
    expect(top.labels, <String>[
      '书架',
      t.library_view_online,
    ], reason: '「我的」组只有书架时用它自己的名字；导入不占页签');
    expect(
      valuesOf(top),
      isNot(contains(MediaLibraryViewKind.sources)),
      reason: '导入由工具栏右端的圆钮进入，不是页签',
    );
    expect(importButton(tester).selected, isFalse);
    expect(stripCount(), 1, reason: '「我的」组只有一个视图时不画二级胶囊');

    await selectVia(tester, MediaLibraryViewKind.onlineSources);
    expect(stripCount(), 2);
    final MastheadTabsView<MediaLibraryViewKind> sub = read(tester, subStrip());
    expect(valuesOf(sub), <MediaLibraryViewKind>[
      MediaLibraryViewKind.onlineSources,
      MediaLibraryViewKind.extensions,
    ]);
    expect(
      segmentedPrefixes(tester),
      unorderedEquals(<String>[
        'test-library-view',
        'test-library-view-online',
      ]),
      reason: '二级胶囊的焦点前缀 = 壳前缀 + 组名，与一级互不冲突',
    );

    sub.onChanged(MediaLibraryViewKind.extensions);
    await tester.pumpAndSettle();
    expect(find.text('扩展'), findsWidgets);
    await selectVia(tester, MediaLibraryViewKind.library);
    top = read(tester, topStrip());
    expect(valuesOf(top), <MediaLibraryViewKind>[
      MediaLibraryViewKind.library,
      MediaLibraryViewKind.extensions,
    ], reason: '在线组页签的值是组内上次停留的「扩展」，点它直接回到那里');
  });

  testWidgets('在线组只有来源：一级照旧用「来源」自己的名字，不画二级胶囊', (WidgetTester tester) async {
    await tester.pumpWidget(
      harness(<MediaLibraryViewSpec>[
        spec(0, MediaLibraryViewKind.library, '书架'),
        spec(1, MediaLibraryViewKind.onlineSources, '来源'),
        spec(2, MediaLibraryViewKind.sources, '导入'),
      ]),
    );
    await tester.pumpAndSettle();
    await selectVia(tester, MediaLibraryViewKind.onlineSources);

    expect(stripCount(), 1);
    final MastheadTabsView<MediaLibraryViewKind> top = read(tester, topStrip());
    expect(top.labels, <String>['书架', '来源']);
  });

  testWidgets('我的组 = 书架 + 媒体服务器：二级胶囊切换，一级用书架命名', (WidgetTester tester) async {
    await tester.pumpWidget(
      harness(<MediaLibraryViewSpec>[
        spec(0, MediaLibraryViewKind.library, '书架'),
        spec(1, MediaLibraryViewKind.mediaServers, '媒体服务器'),
        spec(2, MediaLibraryViewKind.browse, '浏览'),
        spec(3, MediaLibraryViewKind.sources, '导入'),
      ]),
    );
    await tester.pumpAndSettle();

    final MastheadTabsView<MediaLibraryViewKind> top = read(tester, topStrip());
    expect(top.labels, <String>['书架', '浏览']);
    final MastheadTabsView<MediaLibraryViewKind> sub = read(tester, subStrip());
    expect(valuesOf(sub), <MediaLibraryViewKind>[
      MediaLibraryViewKind.library,
      MediaLibraryViewKind.mediaServers,
    ]);
    expect(
      segmentedPrefixes(tester),
      containsAll(<String>['test-library-view', 'test-library-view-library']),
    );
  });

  testWidgets('一级只剩一组（没有在线视图）：不画一级页签，组内仍有二级胶囊', (WidgetTester tester) async {
    await tester.pumpWidget(
      harness(<MediaLibraryViewSpec>[
        spec(0, MediaLibraryViewKind.library, '书架'),
        spec(1, MediaLibraryViewKind.mediaServers, '媒体服务器'),
        spec(2, MediaLibraryViewKind.sources, '导入'),
      ]),
    );
    await tester.pumpAndSettle();

    expect(topStrip(), findsNothing, reason: '一级只有一段时不放空壳胶囊');
    final MastheadTabsView<MediaLibraryViewKind> sub = read(tester, subStrip());
    expect(valuesOf(sub), <MediaLibraryViewKind>[
      MediaLibraryViewKind.library,
      MediaLibraryViewKind.mediaServers,
    ]);
    expect(
      find.byKey(const ValueKey<String>('test-library-view-import')),
      findsOneWidget,
      reason: '没有一级页签时导入钮照样在工具栏右端',
    );
    expect(
      find.widgetWithText(FushiFloatingChromeSoloTitle, '书架'),
      findsOneWidget,
      reason: '一级页签的位置改放组名标题，左上角不空着',
    );
  });

  testWidgets('iOS 形态（只有书架 + 导入）：左上角放「书架」标题胶囊', (WidgetTester tester) async {
    await tester.pumpWidget(
      harness(<MediaLibraryViewSpec>[
        spec(0, MediaLibraryViewKind.library, '书架'),
        spec(1, MediaLibraryViewKind.sources, '导入'),
      ]),
    );
    await tester.pumpAndSettle();

    expect(topStrip(), findsNothing);
    expect(subStrip(), findsNothing);
    expect(
      find.widgetWithText(FushiFloatingChromeSoloTitle, '书架'),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('test-library-view-import')),
      findsOneWidget,
    );
  });

  testWidgets('iOS 形态的漫画库：左上角标题用外壳页面名「漫画」，不用组名「书架」', (
    WidgetTester tester,
  ) async {
    // 漫画库的库视图与书籍库同名（书架），只剩一组时若拿组名当标题，漫画页
    // 左上角就成了「书架」（用户 iOS 截图 2026-11-06）。
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: FushiShellTitleScope(
            title: '漫画',
            child: MediaLibraryShell(
              focusIdPrefix: 'test-library-view',
              views: <MediaLibraryViewSpec>[
                spec(0, MediaLibraryViewKind.library, '书架'),
                spec(1, MediaLibraryViewKind.sources, '导入'),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // 页头大字顶栏（PR #3397）里页名由大字行画（[FushiMastheadTitle]），一级
    // 只剩一组时页签位（[FushiFloatingChromeSoloTitle]）让给它、不再重复。
    expect(find.widgetWithText(FushiMastheadTitle, '漫画'), findsOneWidget);
    expect(find.widgetWithText(FushiMastheadTitle, '书架'), findsNothing);
  });

  testWidgets('导入钮是切换型：点进导入页呈选中、高亮「我的」组，再点回到之前的视图', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      harness(<MediaLibraryViewSpec>[
        spec(0, MediaLibraryViewKind.library, '书架'),
        spec(1, MediaLibraryViewKind.onlineSources, '来源'),
        spec(2, MediaLibraryViewKind.extensions, '扩展'),
        spec(3, MediaLibraryViewKind.sources, '导入'),
      ]),
    );
    await tester.pumpAndSettle();
    await selectVia(tester, MediaLibraryViewKind.extensions);
    expect(initCount[3], isNull, reason: '导入页未进过不构造');

    await tapImport(tester);
    expect(importButton(tester).selected, isTrue);
    expect(initCount[3], 1);
    expect(
      find.byWidgetPredicate(
        (Widget w) => w is _StatefulLeaf && w.label == '导入',
      ),
      findsOneWidget,
    );
    final MastheadTabsView<MediaLibraryViewKind> top = read(tester, topStrip());
    expect(top.selected, MediaLibraryViewKind.library, reason: '导入管理的是本地库');
    expect(subStrip(), findsNothing, reason: '导入页不属于任何组，不画二级胶囊');

    await tapImport(tester);
    expect(importButton(tester).selected, isFalse);
    expect(
      find.byWidgetPredicate(
        (Widget w) => w is _StatefulLeaf && w.label == '扩展',
      ),
      findsOneWidget,
      reason: '再点一次回到进导入页之前的「扩展」',
    );
    expect(initCount[3], 1, reason: '导入页保活，切走不销毁');
  });

  // BUG-4706（反馈 3cmGrH7EoA）：导入页高亮「我的」组只是视觉锚点，不是当前视图；
  // 以前它被当成「点当前项」直接丢掉，导入页点左上角「书架」回不去。这里走真实
  // 指针点击（不是直接调 onChanged），才过得了页签组件里的「重复点击」判断。
  List<MediaLibraryViewSpec> importViews() => <MediaLibraryViewSpec>[
    spec(0, MediaLibraryViewKind.library, '书架'),
    spec(1, MediaLibraryViewKind.onlineSources, '来源'),
    spec(2, MediaLibraryViewKind.extensions, '扩展'),
    spec(3, MediaLibraryViewKind.sources, '导入'),
  ];

  /// 视图 [label] 是否是壳此刻显示的那一个（保活视图都在树上，只看 Offstage）。
  bool onstage(WidgetTester tester, String label) => tester
      .widgetList<Offstage>(
        find.ancestor(
          of: find.byWidgetPredicate(
            (Widget w) => w is _StatefulLeaf && w.label == label,
            skipOffstage: false,
          ),
          matching: find.byType(Offstage, skipOffstage: false),
        ),
      )
      .every((Offstage o) => !o.offstage);

  testWidgets('导入页点一级页签「书架」（高亮锚点）回到书架', (WidgetTester tester) async {
    await tester.pumpWidget(harness(importViews()));
    await tester.pumpAndSettle();
    await tapImport(tester);
    expect(onstage(tester, '导入'), isTrue);
    expect(read(tester, topStrip()).selected, MediaLibraryViewKind.library);

    await tester.tap(
      find.descendant(of: topStrip(), matching: find.text('书架')),
    );
    await tester.pumpAndSettle();

    expect(importButton(tester).selected, isFalse, reason: '已离开导入页');
    expect(onstage(tester, '书架'), isTrue);
    expect(onstage(tester, '导入'), isFalse);
  });

  testWidgets('导入页按键盘左方向键回到书架（首段往回不被夹在原地）', (WidgetTester tester) async {
    await tester.pumpWidget(harness(importViews()));
    await tester.pumpAndSettle();
    await tapImport(tester);
    expect(onstage(tester, '导入'), isTrue);

    final Finder shell = find.byType(
      FushiAdjustableSegmented<MediaLibraryViewKind>,
    );
    final Element inner = tester.element(
      find.descendant(of: shell, matching: find.byType(ExcludeFocus)).first,
    );
    Focus.of(inner).requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pumpAndSettle();

    expect(importButton(tester).selected, isFalse, reason: '已离开导入页');
    expect(onstage(tester, '书架'), isTrue);
  });

  testWidgets('横滑顺序 = 两级页签视觉序：书架 → 媒体服务器 → 发现 → 来源 → 扩展，跨组接着滑', (
    WidgetTester tester,
  ) async {
    // 声明序故意把媒体服务器放在发现后面：横滑序按组排，不按声明序。
    await tester.pumpWidget(
      harness(<MediaLibraryViewSpec>[
        spec(0, MediaLibraryViewKind.library, '书架'),
        spec(1, MediaLibraryViewKind.discover, '发现'),
        spec(2, MediaLibraryViewKind.mediaServers, '媒体服务器'),
        spec(3, MediaLibraryViewKind.onlineSources, '来源'),
        spec(4, MediaLibraryViewKind.extensions, '扩展'),
        spec(5, MediaLibraryViewKind.sources, '导入'),
      ]),
    );
    await tester.pumpAndSettle();

    SectionSwipeNavigator<MediaLibraryViewKind> swipe() =>
        tester.widget(find.byType(SectionSwipeNavigator<MediaLibraryViewKind>));
    const List<MediaLibraryViewKind> order = <MediaLibraryViewKind>[
      MediaLibraryViewKind.library,
      MediaLibraryViewKind.mediaServers,
      MediaLibraryViewKind.discover,
      MediaLibraryViewKind.onlineSources,
      MediaLibraryViewKind.extensions,
    ];
    expect(swipe().sections, order, reason: '导入不是页签，不在横滑序里');

    // 逐个走「下一个」：跨组（媒体服务器 → 发现）照样接着滑。
    for (int i = 1; i < order.length; i++) {
      final SectionSwipeNavigator<MediaLibraryViewKind> nav = swipe();
      final int at = nav.sections.indexOf(nav.selected);
      nav.onSelect(nav.sections[at + 1]);
      await tester.pumpAndSettle();
      expect(swipe().selected, order[i]);
    }
    final MastheadTabsView<MediaLibraryViewKind> top = read(tester, topStrip());
    expect(top.selected, MediaLibraryViewKind.extensions);

    await tapImport(tester);
    expect(swipe().sections, <MediaLibraryViewKind>[
      ...order,
      MediaLibraryViewKind.sources,
    ], reason: '停在导入页时它排在最后，从它能滑回相邻视图');
    swipe().onSelect(MediaLibraryViewKind.extensions);
    await tester.pumpAndSettle();
    expect(swipe().sections, order, reason: '离开导入页后它又退出横滑序');
  });

  testWidgets('分区导航包在 FushiAdjustableSegmented 里（裸 TabBar 即转红）', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      harness(<MediaLibraryViewSpec>[
        spec(0, MediaLibraryViewKind.library, '书架'),
        spec(1, MediaLibraryViewKind.browse, '浏览'),
        spec(2, MediaLibraryViewKind.sources, '来源'),
      ]),
    );

    expect(
      find.byType(FushiAdjustableSegmented<MediaLibraryViewKind>),
      findsOneWidget,
      reason:
          '方向焦点控制器只遍历已注册 target；裸 TabBar 会被整个跳过，'
          '手柄/键盘用户切不了视图',
    );
    // 且它必须真的包着本壳的分区导航（不是树里别处碰巧有一个）。
    expect(
      find.descendant(
        of: find.byType(FushiAdjustableSegmented<MediaLibraryViewKind>),
        matching: mastheadPrimaryTabs<MediaLibraryViewKind>(),
      ),
      findsOneWidget,
    );
    // focusIdPrefix 必须透传：多域同时挂载时靠它区分停靠点。
    final FushiAdjustableSegmented<MediaLibraryViewKind> seg = tester.widget(
      find.byType(FushiAdjustableSegmented<MediaLibraryViewKind>),
    );
    expect(seg.focusIdPrefix, 'test-library-view');
  });

  testWidgets('惰性构建：未访问的视图 builder 从不被调用（在线目录不会因挂载就发请求）', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      harness(<MediaLibraryViewSpec>[
        spec(0, MediaLibraryViewKind.library, '书架'),
        spec(1, MediaLibraryViewKind.browse, '浏览'),
        spec(2, MediaLibraryViewKind.sources, '来源'),
      ]),
    );

    expect(probe.buildOrder.toSet(), <int>{
      0,
    }, reason: '只有落点视图被构造；builder 没跑 ⇒ 其 initState / 网络请求不可能跑');
    expect(probe.buildCount[1], isNull, reason: '「浏览」（在线目录）绝不能因为壳挂载就构造');
    expect(initCount[1], isNull);
    expect(initCount[2], isNull);

    await selectVia(tester, MediaLibraryViewKind.browse);
    expect(initCount[1], 1, reason: '访问后才构造');
    expect(initCount[2], isNull, reason: '仍未访问的「来源」依然不构造');
  });

  testWidgets('保活：切走再切回不重建 State（滚动位置/搜索词得以保留）', (WidgetTester tester) async {
    await tester.pumpWidget(
      harness(<MediaLibraryViewSpec>[
        spec(0, MediaLibraryViewKind.library, '书架'),
        spec(1, MediaLibraryViewKind.browse, '浏览'),
      ]),
    );
    expect(initCount[0], 1);

    await selectVia(tester, MediaLibraryViewKind.browse);
    expect(initCount[1], 1);
    await selectVia(tester, MediaLibraryViewKind.library);
    await selectVia(tester, MediaLibraryViewKind.browse);

    expect(initCount[0], 1, reason: '切走的视图 State 必须留着（Offstage 而非卸载）');
    expect(initCount[1], 1, reason: '切回不得重建——重建就丢滚动位置与搜索词');
  });

  testWidgets('导航条由壳的浮动工具栏画一份（同一 focusIdPrefix 注册两次会互相打架）', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      harness(<MediaLibraryViewSpec>[
        spec(0, MediaLibraryViewKind.library, '书架'),
        spec(1, MediaLibraryViewKind.browse, '浏览'),
      ]),
    );
    // 2026-10-06 库页顶部与视频库统一：页签画在壳的 [FushiFloatingChromeBar]
    // 里，视图页头主位一律空占位。
    expect(probe.gotRealNavigation[0], isFalse);

    await selectVia(tester, MediaLibraryViewKind.browse);
    expect(probe.gotRealNavigation[1], isFalse, reason: '视图拿空占位，页签由壳画出');
    expect(
      probe.gotRealNavigation[0],
      isFalse,
      reason: '隐藏视图必须拿空占位，否则同一 focusIdPrefix 被注册两次',
    );
    // 全树自始至终只有一个分段条。
    expect(
      find.byType(FushiAdjustableSegmented<MediaLibraryViewKind>),
      findsOneWidget,
    );
  });

  testWidgets('切视图：同一个分段条 State 换位置，指示条从旧视图滑过去（不是原地跳变）', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      harness(<MediaLibraryViewSpec>[
        spec(0, MediaLibraryViewKind.library, '书架'),
        spec(1, MediaLibraryViewKind.browse, '浏览'),
        spec(2, MediaLibraryViewKind.sources, '来源'),
      ]),
    );

    // 页头大字顶栏（PR #3397）里一级切换是大字「书架 / 浏览」，选中态只换字色、
    // 没有滑动指示条；这里守的仍是「壳画的同一份导航条，切视图不重新挂一份」。
    final Finder stripFinder = topStrip();
    final Element before = tester.element(stripFinder);
    final MastheadTabsView<MediaLibraryViewKind> strip = read(
      tester,
      stripFinder,
    );
    // 导入不再是页签（工具栏右端圆钮），一级页签是「书架 / 浏览」两组。
    expect(valuesOf(strip), <MediaLibraryViewKind>[
      MediaLibraryViewKind.library,
      MediaLibraryViewKind.browse,
    ]);
    // 选中态是字色（选中 strong、其余淡墨）：守「切视图时页签有过渡、不是原地
    // 跳变」——目标段字色从未选中渐变到选中。
    Color labelColor(String label) => tester
        .renderObject<RenderParagraph>(
          find.descendant(of: stripFinder, matching: find.text(label)),
        )
        .text
        .style!
        .color!;
    final Color fromSelected = labelColor('书架');
    final Color fromIdle = labelColor('浏览');
    expect(fromSelected, isNot(fromIdle));

    strip.onChanged(MediaLibraryViewKind.browse);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 40));

    expect(
      tester.element(stripFinder),
      same(before),
      reason: '壳画的同一份导航条，切视图不重建',
    );
    expect(read(tester, stripFinder).selected, MediaLibraryViewKind.browse);
    final Color midTarget = labelColor('浏览');
    expect(midTarget, isNot(fromIdle), reason: '「浏览」应已开始变成选中色');
    expect(midTarget, isNot(fromSelected), reason: '切出来的那一刻应正在过渡，不是直接落位');

    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(tester.element(stripFinder), same(before));
    expect(labelColor('浏览'), fromSelected);
    expect(labelColor('书架'), fromIdle);
  });

  testWidgets('分段导航注册可由 controller.requestById 定位的稳定 ID', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: FushiFocusRoot(
            child: MediaLibraryShell(
              focusIdPrefix: 'test-library-view',
              views: <MediaLibraryViewSpec>[
                // 一级要有两组才画页签（只剩一组时不画）。
                spec(0, MediaLibraryViewKind.library, '书架'),
                spec(1, MediaLibraryViewKind.browse, '浏览'),
                spec(2, MediaLibraryViewKind.sources, '来源'),
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
    const FushiFocusId sectionsId = FushiFocusId('test-library-view-sections');
    expect(controller.requestById(sectionsId), isTrue);
    await tester.pump();
    expect(controller.activeId, sectionsId);
    expect(controller.primaryFocusIsManagedTarget, isTrue);
  });

  testWidgets('只有一个视图时不显示导航条（不放空壳 tab）', (WidgetTester tester) async {
    await tester.pumpWidget(
      harness(<MediaLibraryViewSpec>[
        spec(0, MediaLibraryViewKind.library, '书架'),
      ]),
    );
    expect(
      find.byType(FushiAdjustableSegmented<MediaLibraryViewKind>),
      findsNothing,
    );
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
                    onOpenSources: MediaLibraryShellScope.maybeOf(
                      inner,
                    )?.actionFor(MediaLibraryViewKind.sources),
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

  /// 壳此刻真正切到了 [kind]：导入页 = 工具栏右端的导入钮呈选中态，其它视图 =
  /// 页签选中它；且该视图的叶子已构建并在台上（非 offstage）。2026-10-06 起
  /// 视图一律拿空占位导航（886df531704），不能再用「拿到真导航条」判当前视图。
  void expectShellOn(
    WidgetTester tester,
    MediaLibraryViewKind kind,
    String leafLabel, {
    String? reason,
  }) {
    if (kind == MediaLibraryViewKind.sources) {
      expect(importButton(tester).selected, isTrue, reason: reason);
    } else {
      final Finder primary = mastheadPrimaryTabs<MediaLibraryViewKind>();
      final MastheadTabsView<MediaLibraryViewKind> strip = read(
        tester,
        primary.evaluate().isNotEmpty ? primary : subStrip(),
      );
      expect(strip.selected, kind, reason: reason);
    }
    expect(
      find.byWidgetPredicate(
        (Widget w) => w is _StatefulLeaf && w.label == leafLabel,
      ),
      findsOneWidget,
      reason: reason,
    );
  }

  testWidgets('压一层路由：切视图时壳自己把它弹掉', (WidgetTester tester) async {
    await tester.pumpWidget(
      harness(<MediaLibraryViewSpec>[
        pushingSpec(MediaLibraryViewKind.library, '书架'),
        spec(1, MediaLibraryViewKind.sources, '导入'),
      ]),
    );
    // 壳的浮动工具栏叠在视图上（BUG-2975，94e818193fa），视图靠
    // [FushiFloatingChromeInsetPadding] 让位；工具栏高度在首帧版面后才回报，
    // 首帧让位为 0、视图顶端的按钮被页签压着。等回报生效那一帧再点，
    // 并钉死按钮确实不在工具栏底下（点得中它本身）。
    await tester.pump();
    expect(
      find.text('push').hitTestable(),
      findsOneWidget,
      reason: '视图必须让出浮动工具栏，顶端按钮不能被页签盖住',
    );
    await tester.tap(find.text('push'));
    await tester.pumpAndSettle();
    expect(find.text('第一层'), findsOneWidget);

    await tester.tap(find.text('去来源'));
    await tester.pumpAndSettle();

    expect(find.text('第一层'), findsNothing, reason: '壳上面的路由必须被弹掉');
    expectShellOn(
      tester,
      MediaLibraryViewKind.sources,
      '导入',
      reason: '壳切到了「导入」视图',
    );
  });

  testWidgets('压两层路由：同一个调用点照样一次弹干净（第二个入口不需要另写一套）', (WidgetTester tester) async {
    await tester.pumpWidget(
      harness(<MediaLibraryViewSpec>[
        pushingSpec(MediaLibraryViewKind.library, '书架'),
        spec(1, MediaLibraryViewKind.sources, '导入'),
      ]),
    );
    // 壳的浮动工具栏叠在视图上（BUG-2975，94e818193fa），视图靠
    // [FushiFloatingChromeInsetPadding] 让位；工具栏高度在首帧版面后才回报，
    // 首帧让位为 0、视图顶端的按钮被页签压着。等回报生效那一帧再点，
    // 并钉死按钮确实不在工具栏底下（点得中它本身）。
    await tester.pump();
    expect(
      find.text('push').hitTestable(),
      findsOneWidget,
      reason: '视图必须让出浮动工具栏，顶端按钮不能被页签盖住',
    );
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
    expectShellOn(tester, MediaLibraryViewKind.sources, '导入');
  });

  testWidgets('actionFor：壳没有声明该视图时返回 null（判据是「视图在」不是「壳在」）', (
    WidgetTester tester,
  ) async {
    late MediaLibraryShellScope scope;
    await tester.pumpWidget(
      MaterialApp(
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
      ),
    );
    await tester.pump();

    expect(
      scope.actionFor(MediaLibraryViewKind.sources),
      isNull,
      reason:
          '没有「导入」视图时必须给 null——select 对它是静默忽略，'
          '照「壳在」渲染出来的按钮点了什么都不会发生',
    );
    expect(scope.actionFor(MediaLibraryViewKind.library), isNotNull);
  });

  testWidgets('触屏横滑按声明序切相邻视图，端头不越界', (WidgetTester tester) async {
    // 叶子文案与页签文案错开：页签条上也有一份 label 文本，撞名会让 finder 歧义。
    MediaLibraryViewSpec leafSpec(
      MediaLibraryViewKind kind,
      String tabLabel,
      String leafLabel,
    ) {
      return MediaLibraryViewSpec(
        kind: kind,
        label: tabLabel,
        builder: (BuildContext context, Widget navigation) =>
            Column(children: <Widget>[navigation, Text(leafLabel)]),
      );
    }

    await tester.pumpWidget(
      harness(<MediaLibraryViewSpec>[
        leafSpec(MediaLibraryViewKind.library, '书架', 'leaf-library'),
        leafSpec(MediaLibraryViewKind.browse, '浏览', 'leaf-browse'),
      ]),
    );
    await tester.pump();

    await tester.fling(find.text('leaf-library'), const Offset(-260, 0), 1000);
    await tester.pumpAndSettle();
    expect(find.text('leaf-browse'), findsOneWidget);
    expect(find.text('leaf-library'), findsNothing);

    await tester.fling(find.text('leaf-browse'), const Offset(-260, 0), 1000);
    await tester.pumpAndSettle();
    expect(find.text('leaf-browse'), findsOneWidget, reason: '末位继续向左甩不越界');

    await tester.fling(find.text('leaf-browse'), const Offset(260, 0), 1000);
    await tester.pumpAndSettle();
    expect(find.text('leaf-library'), findsOneWidget);
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
              builder: (_) =>
                  _PushedPage(label: '$label+', onOpenSources: onOpenSources),
            ),
          ),
          child: const Text('再推一层'),
        ),
      ],
    ),
  );
}
