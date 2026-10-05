import 'package:drift/native.dart';
import 'package:flutter/material.dart';
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

  Future<void> select(
    WidgetTester tester,
    VideoLibrarySection section,
  ) async {
    final FushiSectionTabBar<VideoLibrarySection> strip = tester.widget(
      find.byType(FushiSectionTabBar<VideoLibrarySection>),
    );
    strip.onChanged!(section);
    await tester.pumpAndSettle();
  }

  // 本地库的各视图（首页 / 系列 / 全部视频）排完才是管理类分区。发现紧跟本地库
  // 视图（2026-10-05 用户要求与媒体服务器对调），随后是媒体服务器（用户自己登录的
  // Jellyfin/Emby，远端的自有库）、来源 / 扩展（与「浏览」模块同一组组件），最后
  // 是导入与设置。测试宿主不是 iOS，合规门与视频源宿主门都开。
  testWidgets('页签顺序固定为首页、系列、全部视频、发现、媒体服务器、来源、扩展、导入、设置',
      (WidgetTester tester) async {
    await tester.pumpWidget(harness());
    await tester.pump();

    final FushiSectionTabBar<VideoLibrarySection> strip = tester.widget(
      find.byType(FushiSectionTabBar<VideoLibrarySection>),
    );
    expect(
      strip.tabs
          .map((LibrarySectionTab<VideoLibrarySection> tab) => tab.value)
          .toList(),
      <VideoLibrarySection>[
        VideoLibrarySection.home,
        VideoLibrarySection.series,
        VideoLibrarySection.allVideos,
        VideoLibrarySection.discover,
        VideoLibrarySection.mediaServers,
        if (isVideoOnlineSourcesAvailable) VideoLibrarySection.onlineSources,
        if (isVideoOnlineSourcesAvailable) VideoLibrarySection.extensions,
        VideoLibrarySection.sources,
        VideoLibrarySection.settings,
      ],
    );
    expect(
      find.byType(FushiAdjustableSegmented<VideoLibrarySection>),
      findsOneWidget,
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
      find.byType(FushiAdjustableSegmented<VideoLibrarySection>),
      findsOneWidget,
      reason: '隐藏叶子只拿空占位，不能重复注册同一分段导航焦点',
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
    expect(lastLocalSection, VideoLibrarySection.home,
        reason: '首页已是首位，向右甩无事发生');
  });

  testWidgets('触屏横滑跨到非本地分区：全部视频向左甩进发现，不顺带构建媒体服务器',
      (WidgetTester tester) async {
    await tester.pumpWidget(harness());
    await tester.pump();
    await select(tester, VideoLibrarySection.allVideos);
    expect(mediaServerInitCount, 0);

    await tester.fling(find.text('local leaf'), const Offset(-260, 0), 1000);
    await tester.pumpAndSettle();

    final FushiSectionTabBar<VideoLibrarySection> strip = tester.widget(
      find.byType(FushiSectionTabBar<VideoLibrarySection>),
    );
    expect(strip.selected, VideoLibrarySection.discover,
        reason: '横滑与页签同一条 _select 路径，全部视频的下一个分区是发现');
    expect(mediaServerInitCount, 0, reason: '媒体服务器排在发现之后，未访问不得构建');
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
      find.ancestor(
        of: find.text('media server leaf', skipOffstage: false),
        matching: find.byType(ExcludeFocus, skipOffstage: false),
      ).first,
    );
    expect(focusGate.excluding, isTrue);
  });

  // 首页 / 系列 / 全部视频共用一个 HomeVideoPage，页签 State 一直活着，指示条会滑；
  // 其余分区此前各挂一份全新页签、以目标下标起步，切过去指示条原地跳变（用户反馈
  // 「只有首页、系列、全部视频下面那个条有动画」）。
  testWidgets('切到非本地分区：同一个页签 State 换位置，指示条从旧分区滑过去',
      (WidgetTester tester) async {
    await tester.pumpWidget(harness());
    await tester.pump();

    final Finder stripFinder =
        find.byType(FushiSectionTabBar<VideoLibrarySection>);
    final State<StatefulWidget> before = tester.state(stripFinder);
    final FushiSectionTabBar<VideoLibrarySection> strip =
        tester.widget(stripFinder);
    strip.onChanged!(VideoLibrarySection.mediaServers);
    await tester.pump();
    // 投影在帧末 animateTo；Ticker 第一帧只记起点，再推一帧才有中途值。
    await tester.pump(const Duration(milliseconds: 60));
    await tester.pump(const Duration(milliseconds: 60));

    expect(find.text('media server leaf'), findsOneWidget);
    expect(tester.state(stripFinder), same(before),
        reason: '页签必须是同一个 State 换父节点，而不是新挂一份');
    final TabController controller =
        tester.widget<TabBar>(glassUnwrap<TabBar>(find.byType(TabBar))).controller!;
    // 发现排在媒体服务器前（2026-10-05 对调），媒体服务器是第 5 个页签。
    expect(controller.index, 4);
    expect(controller.animation!.value, greaterThan(0));
    expect(controller.animation!.value, lessThan(4),
        reason: '指示条应正从「首页」滑向「媒体服务器」，而不是直接落位');

    await tester.pumpAndSettle();
    expect(controller.animation!.value, 4);
  });

  // 反向切换：目标分区在布局序里排在旧分区前面，新位置的 LayoutBuilder 先布局，
  // GlobalKey 要从一个仍 active 的旧父节点上抢过来——正向用例覆盖不到这条路。
  testWidgets('从后排分区切回前排分区：页签 State 仍是同一个、无异常',
      (WidgetTester tester) async {
    await tester.pumpWidget(harness());
    await tester.pump();

    final Finder stripFinder =
        find.byType(FushiSectionTabBar<VideoLibrarySection>);
    final State<StatefulWidget> before = tester.state(stripFinder);

    await select(tester, VideoLibrarySection.mediaServers);
    expect(tester.takeException(), isNull);
    expect(find.text('media server leaf'), findsOneWidget);
    expect(tester.state(stripFinder), same(before));

    await select(tester, VideoLibrarySection.home);
    expect(tester.takeException(), isNull);
    expect(stripFinder, findsOneWidget);
    expect(tester.state(stripFinder), same(before),
        reason: '切回本地库也必须是同一个 State 换父节点');
    final TabController controller =
        tester.widget<TabBar>(glassUnwrap<TabBar>(find.byType(TabBar))).controller!;
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
    final Rect area = tester.getRect(find.byType(FushiFloatingChromeOverlay));
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
      find.descendant(
        of: bar,
        matching: find.byType(FushiSectionTabBar<VideoLibrarySection>),
      ),
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

    await tester.tap(find.text(t.series));
    await tester.pumpAndSettle();
    expect(lastLocalSection, VideoLibrarySection.series);
  });
}
