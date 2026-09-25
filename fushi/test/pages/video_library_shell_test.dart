import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_engine/media/source_library/source_library_row.dart';
import 'package:fushi_engine/media/video/metadata/video_source_scrape_task.dart';
import 'package:fushi_engine/media/video/metadata/video_source_work_planner.dart'
    show VideoSourceScrapeWork;
import 'package:fushi_engine/media/video/video_book_repository.dart';
import 'package:fushi/src/media/video/video_library_section.dart';
import 'package:fushi/src/pages/implementations/video_library_shell.dart';
import 'package:fushi/utils.dart';
import 'package:fushi_core/fushi_core.dart';

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
            key: const ValueKey<String>('discovery-probe-search'),
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
  late int discoveryInitCount;
  late int mediaServerInitCount;
  VideoLibrarySection? lastLocalSection;

  setUp(() {
    LocaleSettings.setLocale(AppLocale.zhCn);
    database = FushiDatabase.forTesting(NativeDatabase.memory());
    scrapeController = VideoSourceScrapeTaskController(_NoopScrapeRunner());
    refreshSignal = ChangeNotifier();
    localInitCount = 0;
    discoveryInitCount = 0;
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
            discoveryPageBuilder: (_, Widget navigation) => Column(
              children: <Widget>[
                navigation,
                _StatefulProbeLeaf(
                  label: 'discover leaf',
                  withField: true,
                  onInit: () => discoveryInitCount += 1,
                ),
              ],
            ),
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

  // 本地库的各视图（首页 / 系列 / 全部视频）排完才是在线发现，最后才是管理类分区
  // ——与书 / 漫画 / 游戏同位。发现曾夹在首页与系列之间，一排里「自己的库 → 推荐 →
  // 自己的库」来回跳（2026-08-24 用户反馈），是四个模块里唯一的例外。
  // 媒体服务器（用户自己登录的 Jellyfin/Emby）是自己的库、只是远端的，排在本地库视图
  // 之后、在线发现之前。
  testWidgets('页签顺序固定为首页、系列、全部视频、媒体服务器、发现、来源、设置',
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
        VideoLibrarySection.mediaServers,
        VideoLibrarySection.discover,
        VideoLibrarySection.sources,
        VideoLibrarySection.settings,
      ],
    );
    expect(
      find.byType(FushiAdjustableSegmented<VideoLibrarySection>),
      findsOneWidget,
    );
  });

  testWidgets('发现未访问不构建，访问后切走保持 State 和搜索文字', (WidgetTester tester) async {
    await tester.pumpWidget(harness());
    await tester.pump();

    expect(localInitCount, 1);
    expect(discoveryInitCount, 0, reason: '在线发现不得随视频首页挂载而发起加载');

    await select(tester, VideoLibrarySection.discover);
    expect(discoveryInitCount, 1);
    await tester.enterText(
      find.byKey(const ValueKey<String>('discovery-probe-search')),
      '保留的搜索词',
    );
    await select(tester, VideoLibrarySection.home);
    await select(tester, VideoLibrarySection.discover);

    expect(localInitCount, 1);
    expect(discoveryInitCount, 1, reason: 'Offstage 保活后切回不得重建发现页 State');
    expect(find.text('保留的搜索词'), findsOneWidget);
    expect(
      find.byType(FushiAdjustableSegmented<VideoLibrarySection>),
      findsOneWidget,
      reason: '隐藏叶子只拿空占位，不能重复注册同一分段导航焦点',
    );
  });

  testWidgets('切走后隐藏发现页退出焦点遍历但继续保活', (WidgetTester tester) async {
    await tester.pumpWidget(harness());
    await tester.pump();
    await select(tester, VideoLibrarySection.discover);
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
          const ValueKey<String>('discovery-probe-search'),
          skipOffstage: false,
        ),
        matching: find.byType(ExcludeFocus, skipOffstage: false),
      ),
    );
    expect(focusGate.excluding, isTrue);
    expect(discoveryInitCount, 1, reason: '排除焦点不能销毁发现页状态');
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

  testWidgets('触屏横滑跨到非本地分区：全部视频向左甩进媒体服务器', (WidgetTester tester) async {
    await tester.pumpWidget(harness());
    await tester.pump();
    await select(tester, VideoLibrarySection.allVideos);
    expect(mediaServerInitCount, 0);

    await tester.fling(find.text('local leaf'), const Offset(-260, 0), 1000);
    await tester.pumpAndSettle();

    expect(mediaServerInitCount, 1, reason: '横滑与页签同一条 _select 路径，'
        '首次进入媒体服务器才惰性构建');
    expect(find.text('media server leaf'), findsOneWidget);
    expect(discoveryInitCount, 0, reason: '发现在媒体服务器之后，尚未到达');
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
        tester.widget<TabBar>(find.byType(TabBar)).controller!;
    expect(controller.index, 3);
    expect(controller.animation!.value, greaterThan(0));
    expect(controller.animation!.value, lessThan(3),
        reason: '指示条应正从「首页」滑向「媒体服务器」，而不是直接落位');

    await tester.pumpAndSettle();
    expect(controller.animation!.value, 3);
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

    await select(tester, VideoLibrarySection.discover);
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
        tester.widget<TabBar>(find.byType(TabBar)).controller!;
    expect(controller.index, 0);
    expect(controller.animation!.value, 0);
  });
}
