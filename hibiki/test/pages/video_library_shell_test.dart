import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/media/source_library/source_library_row.dart';
import 'package:hibiki/src/media/video/metadata/video_source_scrape_task.dart';
import 'package:hibiki/src/media/video/video_book_repository.dart';
import 'package:hibiki/src/media/video/video_library_section.dart';
import 'package:hibiki/src/pages/implementations/video_library_shell.dart';
import 'package:hibiki/utils.dart';
import 'package:hibiki_core/hibiki_core.dart';

class _NoopScrapeRunner implements VideoSourceScrapeRunner {
  @override
  Future<SourceScrapeReport> scrapeSource(
    SourceLibraryRow source, {
    required VideoSourceScrapeCancellationToken cancellationToken,
    required VideoSourceScrapeProgressCallback onProgress,
    VideoSourceScrapeConfirmationCallback? onConfirmation,
    VideoSourceScrapeBatchContext? batchContext,
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
  late HibikiDatabase database;
  late VideoSourceScrapeTaskController scrapeController;
  late ChangeNotifier refreshSignal;
  late int localInitCount;
  late int discoveryInitCount;

  setUp(() {
    LocaleSettings.setLocale(AppLocale.zhCn);
    database = HibikiDatabase.forTesting(NativeDatabase.memory());
    scrapeController = VideoSourceScrapeTaskController(_NoopScrapeRunner());
    refreshSignal = ChangeNotifier();
    localInitCount = 0;
    discoveryInitCount = 0;
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
            onScrapeSource: (_) async {},
            onVideoScanCompleted: (_, __) async {},
            onOpenScrapeTasks: () {},
            onLibraryChanged: () {},
            localLibraryPageBuilder: (_, Widget navigation, __) => Column(
              children: <Widget>[
                navigation,
                _StatefulProbeLeaf(
                  label: 'local leaf',
                  onInit: () => localInitCount += 1,
                ),
              ],
            ),
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
          ),
        ),
      ),
    );
  }

  Future<void> select(
    WidgetTester tester,
    VideoLibrarySection section,
  ) async {
    final HibikiSegmentedStrip<VideoLibrarySection> strip = tester.widget(
      find.byType(HibikiSegmentedStrip<VideoLibrarySection>),
    );
    strip.onChanged(section);
    await tester.pumpAndSettle();
  }

  testWidgets('页签顺序固定为首页、发现、系列、全部视频、来源', (WidgetTester tester) async {
    await tester.pumpWidget(harness());
    await tester.pump();

    final HibikiSegmentedStrip<VideoLibrarySection> strip = tester.widget(
      find.byType(HibikiSegmentedStrip<VideoLibrarySection>),
    );
    expect(
      strip.segments.map((segment) => segment.value).toList(),
      <VideoLibrarySection>[
        VideoLibrarySection.home,
        VideoLibrarySection.discover,
        VideoLibrarySection.series,
        VideoLibrarySection.allVideos,
        VideoLibrarySection.sources,
      ],
    );
    expect(
      find.byType(HibikiAdjustableSegmented<VideoLibrarySection>),
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
      find.byType(HibikiAdjustableSegmented<VideoLibrarySection>),
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
}
