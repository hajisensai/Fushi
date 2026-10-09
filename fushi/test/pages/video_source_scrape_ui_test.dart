import 'dart:async';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart' show t;
import 'package:fushi/models.dart';
import 'package:fushi_engine/media/source_library/source_library_row.dart';
import 'package:fushi/src/media/source_library/source_library_scanner.dart';
import 'package:fushi_engine/media/video/metadata/video_library_scrape_sweep.dart'
    show VideoPendingScrapeWork;
import 'package:fushi_engine/media/video/metadata/video_metadata_models.dart';
import 'package:fushi_engine/media/video/metadata/video_metadata_provider.dart';
import 'package:fushi_engine/media/video/metadata/video_scrape_ai_identity.dart';
import 'package:fushi/src/media/video/metadata/video_source_scrape_dialog.dart';
import 'package:fushi_engine/media/video/metadata/video_source_scrape_task.dart';
import 'package:fushi_engine/media/video/metadata/video_source_work_planner.dart'
    show VideoSourceScrapeWork;
import 'package:fushi/src/pages/implementations/media_sources_view.dart';
import 'package:fushi_core/fushi_core.dart';

import '../helpers/test_platform_services.dart';
import '../helpers/glass_unwrap.dart';

FushiDatabase _memDb() => FushiDatabase.forTesting(
      NativeDatabase.memory(
        setup: (rawDb) => rawDb.execute('PRAGMA foreign_keys = ON'),
      ),
    );

Future<int> _seedSource(
  FushiDatabase db, {
  required String mediaKind,
  String label = 'Anime',
}) =>
    db.insertMediaSource(
      MediaSourcesCompanion(
        label: Value<String>(label),
        mediaKind: Value<String>(mediaKind),
        transport: const Value<String>('local'),
        rootPath: Value<String>('/nonexistent/$mediaKind'),
        createdAt: Value<int>(DateTime.now().millisecondsSinceEpoch),
      ),
    );

Future<void> _pumpView(
  WidgetTester tester,
  FushiDatabase db, {
  required String mediaKind,
  Future<void> Function(SourceLibraryRow source)? onScrapeSource,
  Future<void> Function(
    SourceLibraryRow source,
    SourceScanSummary summary,
  )? onVideoScanCompleted,
  VideoSourceScrapeTaskController? scrapeTaskController,
}) async {
  final AppModel appModel = AppModel(testPlatformServices())
    ..wireDatabaseForTesting(db);
  await tester.pumpWidget(
    ProviderScope(
      overrides: <Override>[
        appProvider.overrideWith((ref) => appModel),
      ],
      child: MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(size: Size(900, 900)),
          child: Scaffold(
            body: MediaSourcesView(
              mediaKind: mediaKind,
              onScrapeSource: onScrapeSource,
              onVideoScanCompleted: onVideoScanCompleted,
              scrapeTaskController: scrapeTaskController,
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

class _HoldingScrapeRunner implements VideoSourceScrapeRunner {
  final Completer<void> release = Completer<void>();
  int calls = 0;

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
    calls++;
    onProgress(
      VideoSourceScrapeProgress(
        phase: VideoSourceScrapePhase.recognizing,
        sourceId: source.id,
        sourceLabel: source.label,
        currentWorkTitle: 'Example Show',
        current: 1,
        total: 3,
      ),
    );
    await release.future;
    return SourceScrapeReport(
      sourceIds: <int>[source.id],
      totalWorks: 3,
      succeededWorks: 3,
    );
  }
}

/// 立即完成，报告里带 [warnings] 条说明（`Issue #n`）。
class _ReportRunner implements VideoSourceScrapeRunner {
  _ReportRunner({required this.warnings});
  final int warnings;

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
    return SourceScrapeReport(
      sourceIds: <int>[source.id],
      totalWorks: warnings,
      succeededWorks: warnings,
      warnings: <SourceScrapeIssue>[
        for (int index = 1; index <= warnings; index++)
          SourceScrapeIssue(workTitle: 'Show $index', message: 'Issue #$index'),
      ],
    );
  }
}

class _ManualBindingRunner
    implements VideoSourceScrapeRunner, VideoSourceScrapeManualBinding {
  final List<String> boundTitles = <String>[];
  final List<VideoMetadataLookup> boundLookups = <VideoMetadataLookup>[];
  final List<String> queries = <String>[];
  List<VideoSourceScrapeConfirmationCandidate> results =
      const <VideoSourceScrapeConfirmationCandidate>[];

  @override
  Future<SourceScrapeReport> scrapeSource(
    SourceLibraryRow source, {
    required VideoSourceScrapeCancellationToken cancellationToken,
    required VideoSourceScrapeProgressCallback onProgress,
    VideoSourceScrapeConfirmationCallback? onConfirmation,
    VideoSourceScrapeBatchContext? batchContext,
    List<VideoSourceScrapeWork>? plannedWorks,
    String runScope = 'source',
  }) async =>
      SourceScrapeReport(sourceIds: <int>[source.id]);

  @override
  Future<List<VideoSourceScrapeConfirmationCandidate>> searchManualCandidates({
    SourceLibraryRow? source,
    required String workTitle,
    String? workStableKey,
    required String query,
  }) async {
    queries.add(query);
    return results;
  }

  @override
  Future<VideoMetadataWork?> fetchWorkForLookup(VideoMetadataLookup lookup) =>
      Future<VideoMetadataWork?>.value(null);

  @override
  Future<SourceScrapeReport> rescrapeWorkWithLookup({
    required SourceLibraryRow source,
    required String workTitle,
    String? workStableKey,
    required VideoMetadataLookup lookup,
    required VideoSourceScrapeCancellationToken cancellationToken,
    required VideoSourceScrapeProgressCallback onProgress,
  }) async {
    boundTitles.add(workTitle);
    boundLookups.add(lookup);
    return SourceScrapeReport(
      sourceIds: <int>[source.id],
      totalWorks: 1,
      succeededWorks: 1,
    );
  }
}

VideoSourceScrapeConfirmationCandidate _candidate({
  required String id,
  required String title,
  int? year,
}) =>
    VideoSourceScrapeConfirmationCandidate(
      lookup: VideoMetadataLookup(
        provider: VideoMetadataProviderKind.anidb,
        externalId: id,
        mediaKind: VideoMetadataMediaKind.tv,
      ),
      work: VideoMetadataWork(
        provider: VideoMetadataProviderKind.anidb,
        kind: VideoMetadataMediaKind.tv,
        title: title,
        year: year,
      ),
    );

/// 用户那次的真实形状：run 已完成，但留下待确认与失败的作品。
Future<int> _seedUnresolvedRun(FushiDatabase db, int sourceId) =>
    db.insertVideoSourceScrapeRun(
      VideoSourceScrapeRunsCompanion.insert(
        sourceId: Value<int?>(sourceId),
        scope: 'source',
        status: 'completed',
        provider: const Value<String?>('anidb'),
        succeededWorks: const Value<int>(22),
        pendingConfirmations: const Value<int>(2),
        failedWorks: const Value<int>(4),
        summaryJson: Value<String?>(encodeSourceScrapeReport(SourceScrapeReport(
          sourceIds: <int>[sourceId],
          totalWorks: 28,
          succeededWorks: 22,
          pendingConfirmations: 2,
          failedWorks: 4,
          warnings: const <SourceScrapeIssue>[
            SourceScrapeIssue(
              workTitle: 'Doraemon Movies',
              message: 'Multiple exact matches',
            ),
          ],
          errors: const <SourceScrapeIssue>[
            SourceScrapeIssue(
              workTitle: 'Unknown Show',
              message: 'No match found',
            ),
          ],
        ))),
        startedAt: 1,
        updatedAt: 2,
        finishedAt: const Value<int?>(2),
      ),
    );

/// 支持「AI 识别」的 runner：[available] 模拟「设置 › AI」有没有指派提供商。
class _AiIdentifyRunner
    implements VideoSourceScrapeRunner, VideoSourceScrapeAiIdentify {
  _AiIdentifyRunner({
    required this.available,
    this.reason = 'same year and studio',
  });

  bool available;
  final String reason;
  final List<String> identifiedKeys = <String>[];

  @override
  bool get aiIdentityAvailable => available;

  @override
  Future<SourceScrapeReport> scrapeSource(
    SourceLibraryRow source, {
    required VideoSourceScrapeCancellationToken cancellationToken,
    required VideoSourceScrapeProgressCallback onProgress,
    VideoSourceScrapeConfirmationCallback? onConfirmation,
    VideoSourceScrapeBatchContext? batchContext,
    List<VideoSourceScrapeWork>? plannedWorks,
    String runScope = 'source',
  }) async =>
      SourceScrapeReport(sourceIds: <int>[source.id]);

  @override
  Future<SourceScrapeReport> identifyWorkWithAi({
    required SourceLibraryRow source,
    required String workTitle,
    String? workStableKey,
    required VideoSourceScrapeCancellationToken cancellationToken,
    required VideoSourceScrapeProgressCallback onProgress,
  }) async {
    identifiedKeys.add(workStableKey ?? workTitle);
    return SourceScrapeReport(
      sourceIds: <int>[source.id],
      totalWorks: 1,
      succeededWorks: 1,
      warnings: <SourceScrapeIssue>[
        SourceScrapeIssue(
          workTitle: workTitle,
          message: encodeVideoScrapeAiIdentityNote(
            AiVideoIdentityDecision(
              key: 'anidb:65733',
              confidence: 0.93,
              reason: reason,
            ),
          ),
          workKey: workStableKey,
        ),
      ],
    );
  }
}

/// 交互式批次里把一个带 AI 建议的确认请求交给面板，等用户选。
class _AiSuggestionConfirmationRunner implements VideoSourceScrapeRunner {
  _AiSuggestionConfirmationRunner(this.candidates);

  final List<VideoSourceScrapeConfirmationCandidate> candidates;
  VideoSourceScrapeConfirmationCandidate? chosen;

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
    chosen = await onConfirmation!(
      VideoSourceScrapeConfirmation(
        sourceId: source.id,
        sourceLabel: source.label,
        localWorkTitle: 'Doraemon Movies',
        candidates: candidates,
        aiSuggestion: const VideoSourceScrapeAiSuggestion(
          candidateIndex: 1,
          confidencePercent: 72,
          reason: 'theatrical release matches the folder',
        ),
      ),
    );
    return SourceScrapeReport(
      sourceIds: <int>[source.id],
      totalWorks: 1,
      succeededWorks: chosen == null ? 0 : 1,
    );
  }
}

/// 一条待确认作品：真实来源行 + 真实视频行组成的 book 单元。
Future<VideoPendingScrapeWork> _seedPendingWork(FushiDatabase db) async {
  final int sourceId = await _seedSource(db, mediaKind: 'video');
  final SourceLibraryRow source = (await db.getMediaSourceById(sourceId))!;
  await db.upsertVideoBook(VideoBooksCompanion(
    bookUid: const Value<String>('movie-a'),
    title: const Value<String>('Unscraped Movie'),
    videoPath: const Value<String>('/nonexistent/video/Unscraped Movie.mkv'),
    sourceId: Value<int?>(sourceId),
  ));
  final VideoBookRow book = (await db.getVideoBookByBookUid('movie-a'))!;
  return VideoPendingScrapeWork(
    source: source,
    work: VideoSourceScrapeWork(
      source: source,
      title: 'Unscraped Movie',
      members: <VideoBookRow>[book],
    ),
  );
}

/// 打开任务面板并切到「待确认」tab。
Future<void> _openPendingTab(
  WidgetTester tester,
  FushiDatabase db,
  VideoSourceScrapeTaskController controller,
  VideoPendingScrapeWork entry, {
  Future<List<VideoPendingScrapeWork>> Function()? loadPendingWorks,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Builder(
        builder: (BuildContext context) => Scaffold(
          body: TextButton(
            onPressed: () => unawaited(
              showVideoSourceScrapeTaskPanel(
                context: context,
                controller: controller,
                loadRuns: () => db.getVideoSourceScrapeRuns(limit: 20),
                loadPendingWorks: loadPendingWorks ??
                    () async => <VideoPendingScrapeWork>[entry],
              ),
            ),
            child: const Text('Open tasks'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('Open tasks'));
  await tester.pumpAndSettle();
  await tester.tap(
    find.byKey(const ValueKey<String>('video-source-tab-pending')),
  );
  await tester.pumpAndSettle();
  expect(
    find.byKey(
      const ValueKey<String>('video-source-pending-work-book:movie-a'),
    ),
    findsOneWidget,
  );
}

const ValueKey<String> _aiButtonKey =
    ValueKey<String>('video-source-pending-ai-book:movie-a');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('video row exposes scrape/settings and shows live task progress',
      (WidgetTester tester) async {
    final FushiDatabase db = _memDb();
    addTearDown(db.close);
    final int sourceId = await _seedSource(db, mediaKind: 'video');
    final _HoldingScrapeRunner runner = _HoldingScrapeRunner();
    final VideoSourceScrapeTaskController controller =
        VideoSourceScrapeTaskController(runner);
    addTearDown(controller.dispose);

    await _pumpView(
      tester,
      db,
      mediaKind: 'video',
      scrapeTaskController: controller,
      onScrapeSource: (SourceLibraryRow source) async {
        await controller.scrapeSource(source);
      },
    );

    expect(find.byTooltip('Scrape this source'), findsOneWidget);
    expect(find.byTooltip('Source scrape settings'), findsOneWidget);
    await tester.tap(find.byTooltip('Scrape this source'));
    await tester.pump();

    expect(runner.calls, 1);
    expect(find.textContaining('Matching · 1/3'), findsOneWidget);
    expect(find.textContaining('Example Show'), findsOneWidget);

    // 刮削期间重新扫描按钮不可用，不会改写 scan 记录。
    await tester.tap(find.byTooltip('Rescan'), warnIfMissed: false);
    await tester.pump();
    final SourceLibraryRow source = (await db.getMediaSourceById(sourceId))!;
    expect(source.lastScannedAt, isNull);

    runner.release.complete();
    await tester.pumpAndSettle();
  });

  testWidgets('background task panel can close and reopen without cancelling',
      (WidgetTester tester) async {
    final FushiDatabase db = _memDb();
    addTearDown(db.close);
    final int sourceId = await _seedSource(db, mediaKind: 'video');
    final SourceLibraryRow source = (await db.getMediaSourceById(sourceId))!;
    await db.insertVideoSourceScrapeRun(
      VideoSourceScrapeRunsCompanion.insert(
        sourceId: Value<int?>(sourceId),
        scope: 'source',
        status: 'completed',
        provider: const Value<String?>('tmdb'),
        succeededWorks: const Value<int>(2),
        startedAt: 1,
        updatedAt: 2,
        finishedAt: const Value<int?>(2),
      ),
    );
    final _HoldingScrapeRunner runner = _HoldingScrapeRunner();
    final VideoSourceScrapeTaskController controller =
        VideoSourceScrapeTaskController(runner);
    addTearDown(controller.dispose);

    Future<void> openPanel(BuildContext context) =>
        showVideoSourceScrapeTaskPanel(
          context: context,
          controller: controller,
          loadRuns: () => db.getVideoSourceScrapeRuns(limit: 20),
        );

    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (BuildContext context) => Scaffold(
            body: Column(
              children: <Widget>[
                TextButton(
                  onPressed: () {
                    unawaited(controller.scrapeSource(source));
                    unawaited(openPanel(context));
                  },
                  child: const Text('Start in background'),
                ),
                TextButton(
                  onPressed: () => unawaited(openPanel(context)),
                  child: const Text('Open tasks'),
                ),
              ],
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Start in background'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Background tasks'), findsOneWidget);
    expect(find.textContaining('Example Show'), findsOneWidget);
    expect(find.text('Recent tasks'), findsOneWidget);
    await tester
        .tap(find.byKey(const ValueKey<String>('video-source-tab-history')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey<String>('video-source-scrape-run-1')),
        findsOneWidget);

    await tester.tap(find.widgetWithText(TextButton, 'CLOSE'));
    await tester.pumpAndSettle();
    expect(find.text('Background tasks'), findsNothing);
    expect(controller.isRunning, isTrue);

    await tester.tap(find.text('Open tasks'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.textContaining('Example Show'), findsOneWidget);
    expect(controller.isRunning, isTrue);

    runner.release.complete();
    await tester.pumpAndSettle();
    expect(controller.isRunning, isFalse);
  });

  // BUG-2594：已完成报告的说明列表以前硬截在 260px 里，弹窗下半截一直空着。
  // 现在整个「当前任务」tab 是一个列表，说明行一直铺到 tab 底部。
  testWidgets('finished report issues fill the whole activity tab',
      (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final FushiDatabase db = _memDb();
    addTearDown(db.close);
    final int sourceId = await _seedSource(db, mediaKind: 'video');
    final SourceLibraryRow source = (await db.getMediaSourceById(sourceId))!;
    final _ReportRunner runner = _ReportRunner(warnings: 60);
    final VideoSourceScrapeTaskController controller =
        VideoSourceScrapeTaskController(runner);
    addTearDown(controller.dispose);
    await controller.scrapeSource(source);

    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (BuildContext context) => Scaffold(
            body: TextButton(
              onPressed: () => unawaited(showVideoSourceScrapeTaskPanel(
                context: context,
                controller: controller,
                loadRuns: () => db.getVideoSourceScrapeRuns(limit: 20),
              )),
              child: const Text('Open tasks'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open tasks'));
    await tester.pumpAndSettle();

    final Finder list =
        find.byKey(const PageStorageKey<String>('video-source-activity-list'));
    expect(list, findsOneWidget);
    final Finder issues =
        find.descendant(of: list, matching: find.textContaining('Issue #'));
    // 弹窗内容高 640（屏高 1000 × .65），扣掉提示 / tab 栏后列表约 520px；
    // 每行两行文字 ≈ 56px → 至少 8 行**真正落在列表可视区内**；旧的 260px
    // 硬截只能露出 4 行（懒加载的 cacheExtent 会多建几行，所以按矩形数）。
    final Rect listRect = tester.getRect(list);
    final int visible = issues
        .evaluate()
        .where((Element element) => listRect
            .contains(tester.getRect(find.byWidget(element.widget)).center))
        .length;
    // M3E 分段卡片行（2026-10-06：卡内边距 + 行间 2px + 顶部状态卡）每行约
    // 76px，同样高度能露出 5 行以上；判据仍是「多于旧 260px 硬截的 4 行」且
    // 可视行一直排到列表底部。
    expect(visible, greaterThanOrEqualTo(5), reason: '说明行没有铺满 tab');
    final List<Rect> visibleRows = issues
        .evaluate()
        .map((Element element) => tester.getRect(find.byWidget(element.widget)))
        .where((Rect r) => listRect.contains(r.center))
        .toList();
    final double rowPitch = visibleRows[1].top - visibleRows[0].top;
    expect(visibleRows.last.bottom, greaterThan(listRect.bottom - 2 * rowPitch),
        reason: '说明行要一直铺到 tab 底部，不能停在半截');
    final RenderBox listBox = tester.renderObject(list);
    final RenderBox tabView = tester.renderObject(find.byType(TabBarView));
    expect(listBox.size.height, tabView.size.height,
        reason: '列表要占满 TabBarView 的整个高度');
    // 列表可以滚到最后一条说明（说明文字是 SelectableText，拖拽会变成选字，
    // 直接驱动滚动位置）。
    final ScrollableState scrollable = tester.state<ScrollableState>(
        find.descendant(of: list, matching: find.byType(Scrollable)).first);
    // 懒列表的 maxScrollExtent 是逐步估出来的，跳到底要循环几次。
    for (int round = 0; round < 20; round++) {
      scrollable.position.jumpTo(scrollable.position.maxScrollExtent);
      await tester.pumpAndSettle();
      if (scrollable.position.pixels >= scrollable.position.maxScrollExtent) {
        break;
      }
    }
    expect(find.textContaining('Issue #60'), findsOneWidget);
  });

  testWidgets('book and manga rows never expose video scrape controls',
      (WidgetTester tester) async {
    for (final String kind in <String>['book', 'manga']) {
      final FushiDatabase db = _memDb();
      await _seedSource(db, mediaKind: kind, label: kind);
      await _pumpView(
        tester,
        db,
        mediaKind: kind,
        onScrapeSource: (_) async {},
      );
      expect(find.byTooltip('Scrape this source'), findsNothing);
      expect(find.byTooltip('Source scrape settings'), findsNothing);
      await db.close();
    }
  });

  testWidgets(
      'source settings offer a primary-source picker and persist safe output toggles',
      (WidgetTester tester) async {
    final FushiDatabase db = _memDb();
    addTearDown(db.close);
    final int sourceId = await _seedSource(db, mediaKind: 'video');
    await _pumpView(tester, db, mediaKind: 'video');

    await tester.tap(find.byTooltip('Source scrape settings'));
    await tester.pumpAndSettle();
    // 主资料源选择器默认「跟随全局」；退役的 AniDB / Bangumi / Douban / AniList
    // 与 Fanart 开关不再出现在来源设置里。
    expect(find.text('Follow global default'), findsOneWidget);
    expect(find.text('AniDB'), findsNothing);
    expect(find.text('Use Fanart images'), findsNothing);
    expect(find.text('Bangumi'), findsNothing);
    expect(find.text('Douban'), findsNothing);
    expect(find.text('AniList'), findsNothing);
    // 选 TMDB 为此来源主源：第二个下拉是主资料源（第一个是分组模式）。
    await tester.tap(find.byType(DropdownMenu<int>).at(1));
    await tester.pumpAndSettle();
    await tester.tap(find.text('TMDB').last);
    await tester.pumpAndSettle();
    // BUG-1999：enabled 是此来源刮削的总闸，UI 必须可改且真写穿 DB（旧实现
    // 根本没画这个开关、保存时硬编码回写旧值）。
    await tester.ensureVisible(find.text('Enable scraping for this source'));
    await tester.tap(find.text('Enable scraping for this source'));
    await tester.ensureVisible(find.text('Scrape after scanning'));
    await tester.tap(find.text('Scrape after scanning'));
    await tester.ensureVisible(find.text('Write image files'));
    await tester.tap(find.text('Write image files'));
    await tester.tap(find.text('SAVE'));
    await tester.pumpAndSettle();

    final VideoSourceScrapeSettingRow settings =
        (await db.getVideoSourceScrapeSettings(sourceId))!;
    expect(settings.enabled, isFalse);
    expect(settings.providerOverride, 'tmdb');
    expect(settings.autoAfterScan, isTrue);
    expect(settings.writeNfo, isTrue);
    expect(settings.writeImages, isFalse);
    expect(
      settings.fanartEnabled,
      isTrue,
      reason: 'legacy column stays compatible even though the UI ignores it',
    );
    expect(settings.allowExternalOverwrite, isFalse);
    expect(settings.metadataLocale, isNull,
        reason: 'v99 资料语言留空 = 跟随全局，不写死一个字符串');
  });

  testWidgets('source settings persist a per-source metadata language (v99)',
      (WidgetTester tester) async {
    final FushiDatabase db = _memDb();
    addTearDown(db.close);
    final int sourceId = await _seedSource(db, mediaKind: 'video');
    await _pumpView(tester, db, mediaKind: 'video');

    Finder localeField() => find.ancestor(
          of: find.text('Metadata language'),
          matching: find.byType(TextField),
        );

    await tester.tap(find.byTooltip('Source scrape settings'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(localeField());
    await tester.enterText(localeField(), '  ja  ');
    await tester.tap(find.text('SAVE'));
    await tester.pumpAndSettle();

    expect(
      (await db.getVideoSourceScrapeSettings(sourceId))!.metadataLocale,
      'ja',
      reason: '首尾空白裁掉后写穿 metadata_locale',
    );

    // 再开一次：输入框回显已存的值，清空后保存回到「跟随全局」= NULL。
    await tester.tap(find.byTooltip('Source scrape settings'));
    await tester.pumpAndSettle();
    expect(
      tester.widget<TextField>(glassUnwrap<TextField>(localeField())).controller!.text,
      'ja',
    );
    await tester.enterText(localeField(), '   ');
    await tester.tap(find.text('SAVE'));
    await tester.pumpAndSettle();
    expect(
      (await db.getVideoSourceScrapeSettings(sourceId))!.metadataLocale,
      isNull,
      reason: '空白 = 跟随全局，必须落回 NULL 而不是空串',
    );
  });

  testWidgets('latest persisted run replaces the scan-count subtitle',
      (WidgetTester tester) async {
    final FushiDatabase db = _memDb();
    addTearDown(db.close);
    final int sourceId = await _seedSource(db, mediaKind: 'video');
    await db.insertVideoSourceScrapeRun(
      VideoSourceScrapeRunsCompanion.insert(
        sourceId: Value<int?>(sourceId),
        scope: 'source',
        status: 'completed',
        succeededWorks: const Value<int>(2),
        failedWorks: const Value<int>(1),
        pendingConfirmations: const Value<int>(1),
        startedAt: 1,
        updatedAt: 2,
        finishedAt: const Value<int?>(2),
      ),
    );

    await _pumpView(tester, db, mediaKind: 'video');
    expect(
      find.textContaining(
        'Last scrape (Completed): 2 succeeded, 1 pending, 1 failed',
      ),
      findsOneWidget,
    );
  });

  test('unresolved-run predicate looks at works, not run status (BUG-1721)',
      () {
    VideoSourceScrapeRunRow run({
      String status = 'completed',
      int pending = 0,
      int failed = 0,
    }) =>
        VideoSourceScrapeRunRow(
          id: 1,
          scope: 'source',
          status: status,
          totalWorks: 0,
          processedWorks: 0,
          succeededWorks: 0,
          failedWorks: failed,
          pendingConfirmations: pending,
          startedAt: 1,
          updatedAt: 1,
        );

    // 回归锚点：这三条以前全被 status 白名单挡在重刮入口之外。
    expect(scrapeRunHasUnresolvedWorks(run(pending: 2)), isTrue);
    expect(scrapeRunHasUnresolvedWorks(run(failed: 4)), isTrue);
    expect(scrapeRunHasUnresolvedWorks(run(pending: 2, failed: 4)), isTrue);
    expect(scrapeRunHasUnresolvedWorks(run()), isFalse);
    expect(scrapeRunHasUnresolvedWorks(run(status: 'failed')), isTrue);
    expect(scrapeRunHasUnresolvedWorks(run(status: 'interrupted')), isTrue);
    expect(scrapeRunHasUnresolvedWorks(run(status: 'cancelled')), isTrue);
    expect(scrapeRunHasUnresolvedWorks(run(status: 'running')), isFalse);
  });

  test('run summary json round-trips the per-work issues', () {
    const SourceScrapeReport report = SourceScrapeReport(
      sourceIds: <int>[7],
      totalWorks: 3,
      succeededWorks: 1,
      failedWorks: 1,
      pendingConfirmations: 1,
      warnings: <SourceScrapeIssue>[
        SourceScrapeIssue(workTitle: 'A', message: 'ambiguous'),
      ],
      errors: <SourceScrapeIssue>[
        SourceScrapeIssue(workTitle: 'B', message: 'boom', path: '/x/y.nfo'),
      ],
    );
    final SourceScrapeReport decoded =
        decodeSourceScrapeReport(encodeSourceScrapeReport(report))!;
    expect(decoded.sourceIds, <int>[7]);
    expect(decoded.pendingConfirmations, 1);
    expect(decoded.warnings.single.workTitle, 'A');
    expect(decoded.errors.single.message, 'boom');
    expect(decoded.errors.single.path, '/x/y.nfo');
    // 陈旧或损坏的记录不能把历史面板炸掉。
    expect(decodeSourceScrapeReport(null), isNull);
    expect(decodeSourceScrapeReport('not json'), isNull);
  });

  testWidgets(
      'import row summary opens the run detail with its issues '
      '(BUG-1720)', (WidgetTester tester) async {
    final FushiDatabase db = _memDb();
    addTearDown(db.close);
    final int sourceId = await _seedSource(db, mediaKind: 'video');
    await _seedUnresolvedRun(db, sourceId);
    final _ManualBindingRunner runner = _ManualBindingRunner();
    final VideoSourceScrapeTaskController controller =
        VideoSourceScrapeTaskController(runner);
    addTearDown(controller.dispose);

    await _pumpView(
      tester,
      db,
      mediaKind: 'video',
      scrapeTaskController: controller,
      onScrapeSource: (SourceLibraryRow source) async {},
    );

    expect(
      find.textContaining('22 succeeded, 2 pending, 4 failed'),
      findsOneWidget,
    );
    await tester.tap(find.byKey(
      ValueKey<String>('media-source-scrape-summary-$sourceId'),
    ));
    await tester.pumpAndSettle();

    expect(find.text('Scrape result'), findsOneWidget);
    expect(find.text('Doraemon Movies'), findsOneWidget);
    expect(find.text('Unknown Show'), findsOneWidget);
    expect(
      find.widgetWithText(TextButton, 'Rescrape this source'),
      findsOneWidget,
    );
  });

  testWidgets('manual binding searches and rebinds through the shared path',
      (WidgetTester tester) async {
    final FushiDatabase db = _memDb();
    addTearDown(db.close);
    final int sourceId = await _seedSource(db, mediaKind: 'video');
    await _seedUnresolvedRun(db, sourceId);
    final _ManualBindingRunner runner = _ManualBindingRunner()
      ..results = <VideoSourceScrapeConfirmationCandidate>[
        _candidate(id: '65733', title: 'Doraemon', year: 2005),
      ];
    final VideoSourceScrapeTaskController controller =
        VideoSourceScrapeTaskController(runner);
    addTearDown(controller.dispose);

    await _pumpView(
      tester,
      db,
      mediaKind: 'video',
      scrapeTaskController: controller,
      onScrapeSource: (SourceLibraryRow source) async {},
    );
    await tester.tap(find.byKey(
      ValueKey<String>('media-source-scrape-summary-$sourceId'),
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Specify the work manually').first);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey<String>('video-source-manual-query')),
        findsOneWidget);

    await tester.tap(
      find.byKey(const ValueKey<String>('video-source-manual-search')),
    );
    await tester.pumpAndSettle();
    // 搜索框预填的是那条待确认作品名，用户可直接搜。
    expect(runner.queries, <String>['Doraemon Movies']);

    // M3E 手动指定弹窗（页眉图标 + 说明 + 搜索框 + 分段候选卡）在 800×600 下
    // 正文要滚：结果卡落在正文滚动区下沿、被动作行盖住。先滚进来再点。
    final Finder candidate = find.byKey(
      const ValueKey<String>('video-source-candidate-anidb-tv-65733'),
    );
    await tester.ensureVisible(candidate);
    await tester.pumpAndSettle();
    await tester.tap(candidate);
    await tester.pumpAndSettle();

    expect(runner.boundTitles, <String>['Doraemon Movies']);
    expect(runner.boundLookups.single.externalId, '65733');
    expect(
        runner.boundLookups.single.provider, VideoMetadataProviderKind.anidb);
    // 处理完的条目从待办里消失，用户看得见进度。
    expect(find.text('Doraemon Movies'), findsNothing);
  });

  testWidgets(
      'completed run with pending works still offers a rescrape entry '
      '(BUG-1721)', (WidgetTester tester) async {
    final FushiDatabase db = _memDb();
    addTearDown(db.close);
    final int sourceId = await _seedSource(db, mediaKind: 'video');
    final SourceLibraryRow source = (await db.getMediaSourceById(sourceId))!;
    final int runId = await _seedUnresolvedRun(db, sourceId);
    final _ManualBindingRunner runner = _ManualBindingRunner();
    final VideoSourceScrapeTaskController controller =
        VideoSourceScrapeTaskController(runner);
    addTearDown(controller.dispose);
    int retried = 0;

    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (BuildContext context) => Scaffold(
            body: TextButton(
              onPressed: () => unawaited(showVideoSourceScrapeTaskPanel(
                context: context,
                controller: controller,
                loadRuns: () => db.getVideoSourceScrapeRuns(limit: 20),
                loadSource: (int id) => db.getMediaSourceById(id),
                onRetry: (VideoSourceScrapeRunRow run) async {
                  retried++;
                },
              )),
              child: const Text('Open tasks'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Open tasks'));
    await tester.pumpAndSettle();

    await tester
        .tap(find.byKey(const ValueKey<String>('video-source-tab-history')));
    await tester.pumpAndSettle();
    // 这次 run 的 status 是 completed —— 旧判据（status 白名单）在这里没有入口。
    final Finder rescrape = find.descendant(
      of: find.byKey(ValueKey<String>('video-source-scrape-run-$runId')),
      matching: find.byTooltip('Rescrape this source'),
    );
    expect(rescrape, findsOneWidget);
    await tester.tap(rescrape);
    await tester.pumpAndSettle();
    expect(retried, 1);

    // 点条目本身进详情，能看到逐条作品级失败原因。
    await tester.tap(find.byKey(ValueKey<String>(
      'video-source-scrape-run-$runId',
    )));
    await tester.pumpAndSettle();
    expect(find.text('Scrape result'), findsOneWidget);
    expect(find.text('No match found'), findsOneWidget);
    expect(source.id, sourceId);
  });

  group('AI identify in the pending tab', () {
    for (final bool reloadFails in <bool>[false, true]) {
      testWidgets(
          'long AI conclusion scrolls during reload and after '
          '${reloadFails ? 'failure' : 'the last work is cleared'}', (
        WidgetTester tester,
      ) async {
        await tester.binding.setSurfaceSize(const Size(800, 600));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        final FushiDatabase db = _memDb();
        addTearDown(db.close);
        final VideoPendingScrapeWork entry = await _seedPendingWork(db);
        final _AiIdentifyRunner runner = _AiIdentifyRunner(
          available: true,
          reason: List<String>.generate(
            20,
            (int index) => 'AI evidence $index: matching year and studio.',
          ).join('\n'),
        );
        final VideoSourceScrapeTaskController controller =
            VideoSourceScrapeTaskController(runner);
        addTearDown(controller.dispose);
        final Completer<List<VideoPendingScrapeWork>> reload =
            Completer<List<VideoPendingScrapeWork>>();
        bool retried = false;
        await _openPendingTab(
          tester,
          db,
          controller,
          entry,
          loadPendingWorks: () async {
            if (runner.identifiedKeys.isEmpty) {
              return <VideoPendingScrapeWork>[entry];
            }
            if (retried) return <VideoPendingScrapeWork>[];
            return reload.future;
          },
        );
        await tester.tap(find.byKey(_aiButtonKey));
        await tester.pump();
        await tester.pump(const Duration(seconds: 1));
        expect(runner.identifiedKeys, <String>['book:movie-a']);
        expect(find.textContaining('AI evidence 19'), findsOneWidget);
        expect(
          tester.takeException(),
          isNull,
          reason: '长结论在等待重新加载时也必须滚动，不能固定在正文外',
        );

        if (reloadFails) {
          reload.completeError(StateError('pending refresh failed'));
        } else {
          reload.complete(<VideoPendingScrapeWork>[]);
        }
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(find.byKey(_aiButtonKey), findsNothing);
        final Finder list = find.byKey(
          const PageStorageKey<String>('video-source-pending-list'),
        );
        final Finder scrollable =
            find.descendant(of: list, matching: find.byType(Scrollable)).first;
        final Finder outcome = find.text(
          reloadFails
              ? t.video_source_scrape_list_reload
              : t.video_source_scrape_pending_empty,
        );
        await tester.scrollUntilVisible(outcome, 200, scrollable: scrollable);
        await tester.pumpAndSettle();
        expect(
          outcome.hitTestable(),
          findsOneWidget,
          reason: '结论底下的空态或重试按钮必须能滚进正文视口',
        );
        expect(tester.takeException(), isNull);
        if (reloadFails) {
          retried = true;
          await tester.tap(outcome);
          await tester.pumpAndSettle();
          await tester.scrollUntilVisible(
            find.text(t.video_source_scrape_pending_empty),
            200,
            scrollable: scrollable,
          );
          await tester.pumpAndSettle();
          expect(
            find.text(t.video_source_scrape_pending_empty).hitTestable(),
            findsOneWidget,
          );
          expect(tester.takeException(), isNull);
        }
      });
    }

    testWidgets('available AI: the button runs identifyWorkWithAi once',
        (WidgetTester tester) async {
      final FushiDatabase db = _memDb();
      addTearDown(db.close);
      final VideoPendingScrapeWork entry = await _seedPendingWork(db);
      final _AiIdentifyRunner runner = _AiIdentifyRunner(available: true);
      final VideoSourceScrapeTaskController controller =
          VideoSourceScrapeTaskController(runner);
      addTearDown(controller.dispose);

      await _openPendingTab(tester, db, controller, entry);
      expect(find.byKey(_aiButtonKey), findsOneWidget);
      await tester.tap(find.byKey(_aiButtonKey));
      await tester.pumpAndSettle();

      expect(runner.identifiedKeys, <String>['book:movie-a']);
      // 结论逐条译成文案：汇总 + ai:matched 标记的本地化标题与理由。
      expect(find.textContaining(t.video_scrape_ai_matched), findsOneWidget);
      expect(find.textContaining('same year and studio'), findsOneWidget);
      expect(find.text(t.ai_assist_no_provider), findsNothing);
    });

    testWidgets(
        'unavailable AI: the button only points to settings and sends nothing',
        (WidgetTester tester) async {
      final FushiDatabase db = _memDb();
      addTearDown(db.close);
      final VideoPendingScrapeWork entry = await _seedPendingWork(db);
      final _AiIdentifyRunner runner = _AiIdentifyRunner(available: false);
      final VideoSourceScrapeTaskController controller =
          VideoSourceScrapeTaskController(runner);
      addTearDown(controller.dispose);

      await _openPendingTab(tester, db, controller, entry);
      // 入口对没指派 AI 的用户也可见（BUG-2694 的约定）。
      expect(find.byKey(_aiButtonKey), findsOneWidget);
      await tester.tap(find.byKey(_aiButtonKey));
      await tester.pumpAndSettle();

      expect(find.text(t.ai_assist_no_provider), findsOneWidget);
      expect(runner.identifiedKeys, isEmpty);
      expect(controller.isRunning, isFalse);
      expect(controller.queuedManualRequestCount, 0);
    });

    testWidgets('runner without AI support: no AI button at all',
        (WidgetTester tester) async {
      final FushiDatabase db = _memDb();
      addTearDown(db.close);
      final VideoPendingScrapeWork entry = await _seedPendingWork(db);
      final VideoSourceScrapeTaskController controller =
          VideoSourceScrapeTaskController(_ManualBindingRunner());
      addTearDown(controller.dispose);

      await _openPendingTab(tester, db, controller, entry);
      expect(find.byKey(_aiButtonKey), findsNothing);
      expect(find.byTooltip(t.video_source_scrape_ai_identify), findsNothing);
      // 手动指定入口照旧在。
      expect(find.byTooltip(t.video_source_scrape_manual_search_title),
          findsOneWidget);
    });
  });

  testWidgets('confirmation marks only the AI-suggested candidate',
      (WidgetTester tester) async {
    final FushiDatabase db = _memDb();
    addTearDown(db.close);
    final int sourceId = await _seedSource(db, mediaKind: 'video');
    final SourceLibraryRow source = (await db.getMediaSourceById(sourceId))!;
    final _AiSuggestionConfirmationRunner runner =
        _AiSuggestionConfirmationRunner(
            <VideoSourceScrapeConfirmationCandidate>[
      _candidate(id: '1001', title: 'Doraemon (TV)', year: 2005),
      _candidate(id: '1002', title: 'Doraemon Movie', year: 2006),
      _candidate(id: '1003', title: 'Doraemon Special', year: 2007),
    ]);
    final VideoSourceScrapeTaskController controller =
        VideoSourceScrapeTaskController(runner);
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (BuildContext context) => Scaffold(
            body: TextButton(
              onPressed: () {
                unawaited(controller.scrapeSource(source, interactive: true));
                unawaited(showVideoSourceScrapeTaskPanel(
                  context: context,
                  controller: controller,
                  loadRuns: () => db.getVideoSourceScrapeRuns(limit: 20),
                ));
              },
              child: const Text('Start'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Start'));
    await tester.pumpAndSettle();
    expect(controller.pendingConfirmation, isNotNull);

    final String label = t.video_source_scrape_ai_suggested(percent: 72);
    Finder labelIn(String id) => find.descendant(
          of: find
              .byKey(ValueKey<String>('video-source-candidate-anidb-tv-$id')),
          matching: find.textContaining(label),
        );
    // 重设计后弹窗页眉 / tab 栏更高，800×600 测试窗里活动列表视口只剩一百多
    // 像素，AI 建议的那条候选落在视口外：先滚进来再看标注（用户同样要滚）。
    await tester.ensureVisible(find.byKey(
        const ValueKey<String>('video-source-candidate-anidb-tv-1002'),
        skipOffstage: false));
    await tester.pumpAndSettle();
    expect(find.textContaining(label), findsOneWidget);
    expect(labelIn('1002'), findsOneWidget);
    expect(labelIn('1001'), findsNothing);
    expect(labelIn('1003'), findsNothing);
    expect(find.textContaining('theatrical release matches the folder'),
        findsOneWidget);

    // 只作标注：选哪条仍由用户决定，选了非 AI 建议的那条也照常交回。
    final Finder first = find.byKey(
        const ValueKey<String>('video-source-candidate-anidb-tv-1001'),
        skipOffstage: false);
    await tester.ensureVisible(first);
    await tester.pumpAndSettle();
    await tester.tap(first);
    await tester.pumpAndSettle();
    expect(runner.chosen?.lookup.externalId, '1001');
    expect(controller.isRunning, isFalse);
  });
}
