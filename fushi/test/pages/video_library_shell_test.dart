import 'package:drift/native.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/online/video_online_sources_gate.dart';
import 'package:fushi_engine/media/source_library/source_library_row.dart';
import 'package:fushi_engine/media/video/metadata/video_source_scrape_task.dart';
import 'package:fushi_engine/media/video/metadata/video_source_work_planner.dart'
    show VideoSourceScrapeWork;
import 'package:fushi_engine/media/video/video_book_repository.dart';
import 'package:fushi/src/media/video/video_library_section.dart';
import 'package:fushi/src/pages/implementations/video_library_shell.dart';
import 'package:fushi/src/utils/components/fushi_floating_chrome.dart';
import 'package:fushi/utils.dart';
import 'package:fushi_core/fushi_core.dart';
import '../helpers/glass_unwrap.dart';

class _NoopScrapeRunner implements VideoSourceScrapeRunner {
  @override
  Future<SourceScrapeReport> scrapeSource(
    SourceLibraryRow source, {
    required VideoSourceScrapeCancellationToken cancellationToken,
    required VideoSourceScrapeProgressCallback onProgress,
    VideoSourceScrapeConfirmationCallback? onConfirmation,
    VideoSourceScrapeBatchContext? batchContext,
    List<VideoSourceScrapeWork>? plannedWorks,
    String runScope = 'source',
  }) async {
    return SourceScrapeReport(sourceIds: <int>[source.id]);
  }
}

class _StatefulProbeLeaf extends StatefulWidget {
  const _StatefulProbeLeaf({
    required this.label,
    required this.onInit,
    this.withField = false,
  });

  final String label;
  final VoidCallback onInit;
  final bool withField;

  @override
  State<_StatefulProbeLeaf> createState() => _StatefulProbeLeafState();
}

class _StatefulProbeLeafState extends State<_StatefulProbeLeaf> {
  final TextEditingController _controller = TextEditingController();

  @override
  void initState() {
    super.initState();
    widget.onInit();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: <Widget>[
        Text(widget.label),
        if (widget.withField)
          TextField(
            key: const ValueKey<String>('section-probe-search'),
            controller: _controller,
          ),
      ],
    );
  }
}

void main() {
  late FushiDatabase database;
  late VideoSourceScrapeTaskController scrapeController;
  late ChangeNotifier refreshSignal;
  late int localInitCount;
  late int mediaServerInitCount;
  VideoLibrarySection? lastLocalSection;

  setUp(() {
    LocaleSettings.setLocale(AppLocale.zhCn);
    database = FushiDatabase.forTesting(NativeDatabase.memory());
    scrapeController = VideoSourceScrapeTaskController(_NoopScrapeRunner());
    refreshSignal = ChangeNotifier();
    localInitCount = 0;
    mediaServerInitCount = 0;
    lastLocalSection = null;
  });

  tearDown(() async {
    scrapeController.dispose();
    refreshSignal.dispose();
    await database.close();
  });

  Widget harness() {
    return TranslationProvider(
      child: MaterialApp(
        home: Scaffold(
          body: VideoLibraryShell(
            repository: VideoBookRepository(database),
            libraryRefreshSignal: refreshSignal,
            scrapeTaskController: scrapeController,
            onScrapeAll: () async {},
            onClearAllScrapeRecords: () async {},
            onScrapeSource: (_) async {},
            onVideoScanCompleted: (_, __) async {},
            onOpenScrapeTasks: () {},
            onLibraryChanged: () {},
            localLibraryPageBuilder:
                (_, Widget navigation, VideoLibrarySection section) {
                  lastLocalSection = section;
                  return Column(
                    children: <Widget>[
                      navigation,
                      _StatefulProbeLeaf(
                        label: 'local leaf',
                        onInit: () => localInitCount += 1,
                      ),
                    ],
                  );
                },
            mediaServerPageBuilder: (_, Widget navigation) => Column(
              children: <Widget>[
                navigation,
                _StatefulProbeLeaf(
                  label: 'media server leaf',
                  withField: true,
                  onInit: () => mediaServerInitCount += 1,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 顶栏分组页签（住在浮动工具栏里）；组内有多个分区时下方另有一条二级
  /// 胶囊，两者同类型，测试按位置区分。
  Finder topStrip() => find.descendant(
    of: find.byType(FushiFloatingChromeBar),
    matching: find.byType(FushiSectionTabBar<VideoLibrarySection>),
  );

  Future<void> select(WidgetTester tester, VideoLibrarySection section) async {
    final FushiSectionTabBar<VideoLibrarySection> strip = tester.widget(
      topStrip(),
    );
    strip.onChanged!(section);
    await tester.pumpAndSettle();
  }

  /// 顶栏下方当前组的二级胶囊。
  Finder subStrip() => find.byWidgetPredicate(
    (Widget w) => w is FushiSectionTabBar<VideoLibrarySection> && w.secondary,
  );

  /// 工具栏右端的「导入」圆钮（切换型）。
  FushiIconButton importButton(WidgetTester tester) => tester.widget(
    find.byKey(const ValueKey<String>('video-library-view-import')),
  );

  // 顶栏一级只放两组（2026-10-30 用户拍板方案 D）：媒体库 = 首页 / 系列 / 全部视频
  // / 媒体服务器，在线 = 发现 / 来源 / 扩展，组内由顶栏下方的二级胶囊切换；导入
  // 是工具栏右端的切换型圆钮。设置页签已移除（2026-10-09 用户拍板）。测试宿主
  // 不是 iOS，合规门与视频源宿主门都开。
  testWidgets('顶栏一级固定为媒体库、在线两组，媒体库组内是首页 / 系列 / 全部视频 / 媒体服务器', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(harness());
    await tester.pump();

    final FushiSectionTabBar<VideoLibrarySection> strip = tester.widget(
      topStrip(),
    );
    expect(
      strip.tabs
          .map((LibrarySectionTab<VideoLibrarySection> tab) => tab.label)
          .toList(),
      <String>[
        t.library_view_media,
        // 在线组只有发现一段时用它自己的名字。
        if (isVideoOnlineSourcesAvailable)
          t.library_view_online
        else
          t.library_view_discover,
      ],
    );
    expect(
      strip.tabs.map((LibrarySectionTab<VideoLibrarySection> tab) => tab.value),
      isNot(contains(VideoLibrarySection.sources)),
      reason: '导入不再是页签',
    );
    expect(importButton(tester).selected, isFalse);
    final List<FushiSectionTabBar<VideoLibrarySection>> strips = tester
        .widgetList<FushiSectionTabBar<VideoLibrarySection>>(
          find.byType(FushiSectionTabBar<VideoLibrarySection>),
        )
        .toList();
    expect(strips, hasLength(2), reason: '停在媒体库组：顶栏 + 二级胶囊');
    final FushiSectionTabBar<VideoLibrarySection> sub = tester.widget(
      subStrip(),
    );
    expect(
      sub.tabs
          .map((LibrarySectionTab<VideoLibrarySection> tab) => tab.value)
          .toList(),
      <VideoLibrarySection>[
        VideoLibrarySection.home,
        VideoLibrarySection.series,
        VideoLibrarySection.allVideos,
        VideoLibrarySection.mediaServers,
      ],
    );
  });

  testWidgets('媒体服务器归媒体库组；在线组一级只占一段，值默认指向组内第一个「发现」', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(harness());
    await tester.pump();

    await select(tester, VideoLibrarySection.mediaServers);
    final FushiSectionTabBar<VideoLibrarySection> sub = tester.widget(
      subStrip(),
    );
    expect(sub.selected, VideoLibrarySection.mediaServers);
    // 不切进在线组：发现 / 在线源页要 ProviderScope，本宿主没挂。
    final FushiSectionTabBar<VideoLibrarySection> top = tester.widget(
      topStrip(),
    );
    expect(
      top.tabs
          .map((LibrarySectionTab<VideoLibrarySection> tab) => tab.value)
          .toList(),
      <VideoLibrarySection>[
        VideoLibrarySection.mediaServers,
        VideoLibrarySection.discover,
      ],
      reason: '媒体库组页签的值是当前分区；在线组还没进过，取组内第一个',
    );
  });

  testWidgets('非本地分区访问后切走保持 State 和输入文字', (WidgetTester tester) async {
    await tester.pumpWidget(harness());
    await tester.pump();

    expect(localInitCount, 1);
    expect(mediaServerInitCount, 0, reason: '媒体服务器分区不得随视频首页挂载而发起加载');

    await select(tester, VideoLibrarySection.mediaServers);
    expect(mediaServerInitCount, 1);
    await tester.enterText(
      find.byKey(const ValueKey<String>('section-probe-search')),
      '保留的搜索词',
    );
    await select(tester, VideoLibrarySection.home);
    await select(tester, VideoLibrarySection.mediaServers);

    expect(localInitCount, 1);
    expect(mediaServerInitCount, 1, reason: 'Offstage 保活后切回不得重建 State');
    expect(find.text('保留的搜索词'), findsOneWidget);
    expect(
      tester
          .widgetList<FushiAdjustableSegmented<VideoLibrarySection>>(
            find.byType(FushiAdjustableSegmented<VideoLibrarySection>),
          )
          .map(
            (FushiAdjustableSegmented<VideoLibrarySection> seg) =>
                seg.focusIdPrefix,
          )
          .toList(),
      unorderedEquals(<String>['video-library-view', 'video-library-subview']),
      reason: '一级 + 二级各一份；隐藏叶子只拿空占位，不能重复注册同一分段导航焦点',
    );
  });

  testWidgets('切走后隐藏的非本地分区退出焦点遍历但继续保活', (WidgetTester tester) async {
    await tester.pumpWidget(harness());
    await tester.pump();
    await select(tester, VideoLibrarySection.mediaServers);
    final EditableText field = tester.widget<EditableText>(
      find.byType(EditableText),
    );
    field.focusNode.requestFocus();
    await tester.pump();
    expect(field.focusNode.hasFocus, isTrue);

    await select(tester, VideoLibrarySection.home);

    expect(field.focusNode.hasFocus, isFalse);
    final ExcludeFocus focusGate = tester.widget<ExcludeFocus>(
      find.ancestor(
        of: find.byKey(
          const ValueKey<String>('section-probe-search'),
          skipOffstage: false,
        ),
        matching: find.byType(ExcludeFocus, skipOffstage: false),
      ),
    );
    expect(focusGate.excluding, isTrue);
    expect(mediaServerInitCount, 1, reason: '排除焦点不能销毁分区状态');
  });

  // 触屏横滑切分区（与页签同一份视觉序）。用户反馈的原始诉求：视频首页从右往左
  // 划进右边的「系列」。
  testWidgets('触屏横滑：首页向左甩切到系列，端头向右甩不越界', (WidgetTester tester) async {
    await tester.pumpWidget(harness());
    await tester.pump();
    expect(lastLocalSection, VideoLibrarySection.home);

    await tester.fling(find.text('local leaf'), const Offset(-260, 0), 1000);
    await tester.pumpAndSettle();
    expect(lastLocalSection, VideoLibrarySection.series);

    await select(tester, VideoLibrarySection.home);
    await tester.fling(find.text('local leaf'), const Offset(260, 0), 1000);
    await tester.pumpAndSettle();
    expect(
      lastLocalSection,
      VideoLibrarySection.home,
      reason: '首页已是首位，向右甩无事发生',
    );
  });

  testWidgets('触屏横滑跨到非本地分区：全部视频向左甩进媒体服务器；横滑序跨组接到在线组', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(harness());
    await tester.pump();
    await select(tester, VideoLibrarySection.allVideos);
    expect(mediaServerInitCount, 0);

    final SectionSwipeNavigator<VideoLibrarySection> nav = tester.widget(
      find.byType(SectionSwipeNavigator<VideoLibrarySection>),
    );
    // 横滑序 = 两级页签视觉序：先媒体库组、再在线组，导入不在序里。
    expect(nav.sections, <VideoLibrarySection>[
      VideoLibrarySection.home,
      VideoLibrarySection.series,
      VideoLibrarySection.allVideos,
      VideoLibrarySection.mediaServers,
      VideoLibrarySection.discover,
      if (isVideoOnlineSourcesAvailable) ...<VideoLibrarySection>[
        VideoLibrarySection.onlineSources,
        VideoLibrarySection.extensions,
      ],
    ]);

    await tester.fling(find.text('local leaf'), const Offset(-260, 0), 1000);
    await tester.pumpAndSettle();

    final FushiSectionTabBar<VideoLibrarySection> sub = tester.widget(
      subStrip(),
    );
    expect(
      sub.selected,
      VideoLibrarySection.mediaServers,
      reason: '横滑与页签同一条 _select 路径，全部视频的下一个分区是媒体服务器',
    );
    expect(mediaServerInitCount, 1);
  });

  testWidgets('媒体服务器未访问不构建，访问后切走保活、退出焦点遍历', (WidgetTester tester) async {
    await tester.pumpWidget(harness());
    await tester.pump();
    expect(mediaServerInitCount, 0, reason: '媒体服务器分区不得随视频首页挂载而向服务器发请求');

    await select(tester, VideoLibrarySection.mediaServers);
    expect(mediaServerInitCount, 1);
    expect(find.text('media server leaf'), findsOneWidget);

    await select(tester, VideoLibrarySection.home);
    await select(tester, VideoLibrarySection.mediaServers);
    expect(mediaServerInitCount, 1, reason: 'Offstage 保活后切回不得重建 State');

    await select(tester, VideoLibrarySection.home);
    final ExcludeFocus focusGate = tester.widget<ExcludeFocus>(
      find
          .ancestor(
            of: find.text('media server leaf', skipOffstage: false),
            matching: find.byType(ExcludeFocus, skipOffstage: false),
          )
          .first,
    );
    expect(focusGate.excluding, isTrue);
  });

  // 首页 / 系列 / 全部视频共用一个 HomeVideoPage，页签 State 一直活着，指示条会滑；
  // 其余分区此前各挂一份全新页签、以目标下标起步，切过去指示条原地跳变（用户反馈
  // 「只有首页、系列、全部视频下面那个条有动画」）。
  testWidgets('切到非本地分区：同一个页签 State 换位置，指示条从旧分区滑过去', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(harness());
    await tester.pump();

    // 媒体服务器在媒体库组的二级胶囊里（首页 / 系列 / 全部视频 / 媒体服务器）：
    // 二级胶囊在壳里只画一份，指示条在它上面滑。
    final Finder stripFinder = subStrip();
    final State<StatefulWidget> before = tester.state(stripFinder);
    final State<StatefulWidget> topBefore = tester.state(topStrip());
    final FushiSectionTabBar<VideoLibrarySection> strip = tester.widget(
      stripFinder,
    );
    strip.onChanged!(VideoLibrarySection.mediaServers);
    await tester.pump();
    // 投影在帧末 animateTo；Ticker 第一帧只记起点，再推一帧才有中途值。
    await tester.pump(const Duration(milliseconds: 60));
    await tester.pump(const Duration(milliseconds: 60));

    expect(find.text('media server leaf'), findsOneWidget);
    expect(
      tester.state(stripFinder),
      same(before),
      reason: '页签必须是同一个 State 换父节点，而不是新挂一份',
    );
    expect(tester.state(topStrip()), same(topBefore));
    final TabController controller = tester
        .widget<TabBar>(
          find.descendant(of: stripFinder, matching: find.byType(TabBar)),
        )
        .controller!;
    // 二级胶囊：首页 / 系列 / 全部视频 / 媒体服务器，媒体服务器是第 4 段。
    expect(controller.index, 3);
    expect(controller.animation!.value, greaterThan(0));
    expect(
      controller.animation!.value,
      lessThan(3),
      reason: '指示条应正从「首页」滑向「媒体服务器」，而不是直接落位',
    );

    await tester.pumpAndSettle();
    expect(controller.animation!.value, 3);
  });

  // 反向切换：目标分区在布局序里排在旧分区前面，新位置的 LayoutBuilder 先布局，
  // GlobalKey 要从一个仍 active 的旧父节点上抢过来——正向用例覆盖不到这条路。
  testWidgets('从后排分区切回前排分区：页签 State 仍是同一个、无异常', (WidgetTester tester) async {
    await tester.pumpWidget(harness());
    await tester.pump();

    final Finder stripFinder = topStrip();
    final State<StatefulWidget> before = tester.state(stripFinder);

    await select(tester, VideoLibrarySection.mediaServers);
    expect(tester.takeException(), isNull);
    expect(find.text('media server leaf'), findsOneWidget);
    expect(tester.state(stripFinder), same(before));

    await select(tester, VideoLibrarySection.home);
    expect(tester.takeException(), isNull);
    expect(stripFinder, findsOneWidget);
    expect(
      tester.state(stripFinder),
      same(before),
      reason: '切回本地库也必须是同一个 State 换父节点',
    );
    final TabController controller = tester
        .widget<TabBar>(glassUnwrap<TabBar>(find.byType(TabBar)))
        .controller!;
    expect(controller.index, 0);
    expect(controller.animation!.value, 0);
  });

  // ── 2026-10-05 M3E 浮动工具栏 ──────────────────────────────────────────
  // 页签进壳顶部的浮动胶囊，分区页面页头的动作登记进壳的槽、由悬浮动作组画出；
  // 往下滚收起、往上滚弹回，切分区时弹回。
  Widget floatingHarness() {
    return TranslationProvider(
      child: MaterialApp(
        home: Scaffold(
          body: VideoLibraryShell(
            repository: VideoBookRepository(database),
            libraryRefreshSignal: refreshSignal,
            scrapeTaskController: scrapeController,
            onScrapeAll: () async {},
            onClearAllScrapeRecords: () async {},
            onScrapeSource: (_) async {},
            onVideoScanCompleted: (_, __) async {},
            onOpenScrapeTasks: () {},
            onLibraryChanged: () {},
            localLibraryPageBuilder:
                (_, Widget navigation, VideoLibrarySection section) {
                  lastLocalSection = section;
                  return Column(
                    children: <Widget>[
                      FushiPageHeader.customTitle(
                        title: navigation,
                        actions: <Widget>[
                          FushiIconButton(
                            key: const ValueKey<String>('probe-header-action'),
                            tooltip: 'probe',
                            icon: Icons.refresh,
                            onTap: () {},
                          ),
                        ],
                      ),
                      Expanded(
                        child: ListView.builder(
                          key: const ValueKey<String>('probe-list'),
                          itemCount: 80,
                          itemBuilder: (_, int i) =>
                              SizedBox(height: 60, child: Text('row $i')),
                        ),
                      ),
                    ],
                  );
                },
            mediaServerPageBuilder: (_, Widget navigation) => Column(
              children: <Widget>[
                navigation,
                _StatefulProbeLeaf(
                  label: 'media server leaf',
                  onInit: () => mediaServerInitCount += 1,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 工具栏露出在叠放区里的高度：收起时整条滑出画面（底边退到叠放区顶边）。
  double chromeHeight(WidgetTester tester) {
    final Rect bar = tester.getRect(find.byType(FushiFloatingChromeBar));
    // 外层叠放区（顶栏那一层）；组内二级胶囊行是嵌套在里面的第二层。
    final Rect area = tester.getRect(
      find.byType(FushiFloatingChromeOverlay).first,
    );
    return (bar.bottom - area.top).clamp(0.0, double.infinity);
  }

  /// 内容滚动视口高度：工具栏显隐不得改变它（改了就会夹紧滚动位置、自激回弹）。
  double listViewport(WidgetTester tester) =>
      tester.getSize(find.byKey(const ValueKey<String>('probe-list'))).height;

  testWidgets('浮动工具栏：页签在顶部浮动胶囊里，页头动作进悬浮动作组', (WidgetTester tester) async {
    await tester.pumpWidget(floatingHarness());
    await tester.pumpAndSettle();

    final Finder bar = find.byType(FushiFloatingChromeBar);
    expect(bar, findsOneWidget);
    expect(
      find.descendant(of: bar, matching: topStrip()),
      findsOneWidget,
      reason: '分区页签整个壳只有一份，住在浮动工具栏里',
    );
    expect(
      find.descendant(
        of: find.byType(FushiFloatingActionsPill),
        matching: find.byKey(const ValueKey<String>('probe-header-action')),
      ),
      findsOneWidget,
      reason: '分区页头声明的动作由悬浮动作组画出',
    );
    expect(
      find.byKey(const ValueKey<String>('probe-header-action')),
      findsOneWidget,
      reason: '页头自己那一行不再重复画一份',
    );
  });

  testWidgets('浮动工具栏：下滚收起、上滚弹回、切分区弹回', (WidgetTester tester) async {
    await tester.pumpWidget(floatingHarness());
    await tester.pumpAndSettle();
    final double shown = chromeHeight(tester);
    expect(shown, greaterThan(40));
    final double viewport = listViewport(tester);

    await tester.drag(
      find.byKey(const ValueKey<String>('probe-list')),
      const Offset(0, -600),
    );
    await tester.pumpAndSettle();
    expect(chromeHeight(tester), 0, reason: '往下读：工具栏滑出画面');
    expect(listViewport(tester), viewport, reason: '收起不改内容视口高度');

    await tester.drag(
      find.byKey(const ValueKey<String>('probe-list')),
      const Offset(0, 120),
    );
    await tester.pumpAndSettle();
    expect(chromeHeight(tester), shown, reason: '往回拉：工具栏弹回');
    expect(listViewport(tester), viewport, reason: '弹回不改内容视口高度');

    await tester.drag(
      find.byKey(const ValueKey<String>('probe-list')),
      const Offset(0, -600),
    );
    await tester.pumpAndSettle();
    expect(chromeHeight(tester), 0);
    await select(tester, VideoLibrarySection.mediaServers);
    expect(chromeHeight(tester), shown, reason: '切到新分区从顶部开始，工具栏回来');
  });

  testWidgets('浮动工具栏：点胶囊里的页签文字切分区', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1600, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(floatingHarness());
    await tester.pumpAndSettle();
    expect(mediaServerInitCount, 0);

    await tester.tap(find.text(t.video_library_media_servers));
    await tester.pumpAndSettle();
    expect(mediaServerInitCount, 1);
    expect(find.text('media server leaf'), findsOneWidget);

    // 系列在媒体库组的二级胶囊里：先点组页签回到媒体库，再点系列。
    await tester.tap(find.text(t.library_view_media));
    await tester.pumpAndSettle();
    await tester.tap(find.text(t.series));
    await tester.pumpAndSettle();
    expect(lastLocalSection, VideoLibrarySection.series);
  });
}
