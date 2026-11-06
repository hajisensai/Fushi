import 'dart:async';
import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_engine/media/source_library/source_library_row.dart';
import 'package:fushi_engine/media/video/metadata/video_library_scrape_sweep.dart';
import 'package:fushi_engine/media/video/metadata/video_scrape_pending_note.dart';
import 'package:fushi/src/media/video/metadata/video_source_scrape_dialog.dart';
import 'package:fushi_engine/media/video/metadata/video_source_scrape_task.dart';
import 'package:fushi_engine/media/video/metadata/video_source_work_planner.dart';
import 'package:fushi_core/fushi_core.dart';

const SourceLibraryRow _source = SourceLibraryRow(
  id: 1,
  label: 'Anime',
  mediaKind: 'video',
  transport: 'local',
  rootPath: '/videos',
  recursive: true,
  videoGroupingMode: 'series',
  isPrivate: false,
  mediaCount: 1500,
  sortOrder: 0,
  createdAt: 1,
);

class _IdleRunner implements VideoSourceScrapeRunner {
  @override
  Future<SourceScrapeReport> scrapeSource(
    SourceLibraryRow source, {
    required VideoSourceScrapeCancellationToken cancellationToken,
    required VideoSourceScrapeProgressCallback onProgress,
    VideoSourceScrapeConfirmationCallback? onConfirmation,
    VideoSourceScrapeBatchContext? batchContext,
    List<VideoSourceScrapeWork>? plannedWorks,
    String runScope = 'source',
  }) async => SourceScrapeReport(sourceIds: <int>[source.id]);
}

VideoPendingScrapeWork _pending(int index, {VideoScrapePendingNote? note}) =>
    VideoPendingScrapeWork(
      source: _source,
      pendingNote: note,
      work: VideoSourceScrapeWork(
        source: _source,
        title: 'Unmatched video $index',
        members: <VideoBookRow>[
          VideoBookRow(
            bookUid: 'video-$index',
            title: 'Unmatched video $index',
            videoPath: '/videos/video-$index.mkv',
            lastPositionMs: 0,
            currentEpisode: 0,
            delayMs: 0,
          ),
        ],
      ),
    );

Future<void> _open(
  WidgetTester tester,
  VideoSourceScrapeTaskController controller,
  Future<List<VideoPendingScrapeWork>> Function() load, {
  Future<List<VideoPendingScrapeWork>> Function()? loadIgnored,
  VideoPendingWorkIgnoreSetter? onSetWorkIgnored,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: ThemeData(
        useMaterial3: true,
        fontFamily: const bool.fromEnvironment('CAPTURE_WORKFLOW_UI')
            ? 'WorkflowTest'
            : null,
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xff426957)),
      ),
      home: Builder(
        builder: (BuildContext context) => Scaffold(
          body: TextButton(
            onPressed: () => unawaited(
              showVideoSourceScrapeTaskPanel(
                context: context,
                controller: controller,
                loadRuns: () async => const <VideoSourceScrapeRunRow>[],
                loadPendingWorks: load,
                loadIgnoredWorks: loadIgnored,
                onSetWorkIgnored: onSetWorkIgnored,
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
}

void main() {
  testWidgets('1500 pending works are lazy and accessible at a narrow viewport', (
    WidgetTester tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(420, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    if (const bool.fromEnvironment('CAPTURE_WORKFLOW_UI')) {
      final Uint8List bytes = File(
        'C:/Windows/Fonts/segoeui.ttf',
      ).readAsBytesSync();
      await (FontLoader(
        'WorkflowTest',
      )..addFont(Future<ByteData>.value(ByteData.sublistView(bytes)))).load();
      final Uint8List icons = File(
        'build/unit_test_assets/fonts/MaterialIcons-Regular.otf',
      ).readAsBytesSync();
      await (FontLoader(
        'MaterialIcons',
      )..addFont(Future<ByteData>.value(ByteData.sublistView(icons)))).load();
    }
    final VideoSourceScrapeTaskController controller =
        VideoSourceScrapeTaskController(_IdleRunner());
    addTearDown(controller.dispose);
    await _open(
      tester,
      controller,
      () async => List<VideoPendingScrapeWork>.generate(1500, _pending),
    );
    expect(tester.takeException(), isNull);
    expect(find.text('Unmatched video 0'), findsOneWidget);
    expect(find.text('Unmatched video 1499'), findsNothing);
    final Finder list = find.byKey(
      const PageStorageKey<String>('video-source-pending-list'),
    );
    final ScrollableState scrollable = tester.state<ScrollableState>(
      find.descendant(of: list, matching: find.byType(Scrollable)).first,
    );
    scrollable.position.jumpTo(scrollable.position.maxScrollExtent);
    await tester.pumpAndSettle();
    // The extent estimate settles after the last lazily built rows are measured.
    scrollable.position.jumpTo(scrollable.position.maxScrollExtent);
    await tester.pumpAndSettle();
    expect(find.text('Unmatched video 1499'), findsOneWidget);
    expect(tester.takeException(), isNull);
    if (const bool.fromEnvironment('CAPTURE_WORKFLOW_UI')) {
      scrollable.position.jumpTo(0);
      await tester.pumpAndSettle();
      await expectLater(
        find.byType(AlertDialog),
        matchesGoldenFile('../../.codex-test/video-task-center-narrow.png'),
      );
      await tester.binding.setSurfaceSize(const Size(1100, 800));
      await tester.pumpAndSettle();
      await expectLater(
        find.byType(AlertDialog),
        matchesGoldenFile('../../.codex-test/video-task-center-wide.png'),
      );
    }
  });

  // BUG-2828：每部待确认作品说明为什么还没认出来（原因 · AI 结果），没刮过的
  // 如实说「尚无刮削记录」，而不是只有一个来源名。
  testWidgets('pending rows explain why the work is still unmatched', (
    WidgetTester tester,
  ) async {
    final VideoSourceScrapeTaskController controller =
        VideoSourceScrapeTaskController(_IdleRunner());
    addTearDown(controller.dispose);
    await _open(
      tester,
      controller,
      () async => <VideoPendingScrapeWork>[
        _pending(
          1,
          note: const VideoScrapePendingNote(
            cause: VideoScrapePendingCause.awaitingConfirmation,
            aiOutcome: VideoScrapeAiOutcome.unassigned,
            candidateCount: 3,
            workKeys: <String>['k'],
            reason: 'r',
          ),
        ),
        _pending(2),
      ],
    );
    expect(
      find.text(
        'Anime\n3 candidates, waiting for your pick · '
        'No AI provider assigned to video identification',
      ),
      findsOneWidget,
    );
    expect(find.text('Anime\nNo reason in recent scrape runs'), findsOneWidget);
  });

  testWidgets('a pending-list failure offers an actual reload', (
    WidgetTester tester,
  ) async {
    final VideoSourceScrapeTaskController controller =
        VideoSourceScrapeTaskController(_IdleRunner());
    addTearDown(controller.dispose);
    int calls = 0;
    await _open(tester, controller, () async {
      if (++calls == 1) throw StateError('offline');
      return <VideoPendingScrapeWork>[_pending(7)];
    });
    expect(find.text('Could not load this list. Try again.'), findsOneWidget);
    // M3E 错误占位（9da1a2a5458：色块图标 + 原因 + 详情 + 重试）比旧的一行
    // 文字高，800x600 下按钮落在错误态 ListView 视口之外——滚到它再点，与
    // 用户在小窗口里的真实路径一致。
    await tester.ensureVisible(find.text('Reload'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Reload'));
    await tester.pumpAndSettle();
    expect(calls, 2);
    expect(find.text('Unmatched video 7'), findsOneWidget);
    expect(find.text('Could not load this list. Try again.'), findsNothing);
  });

  testWidgets('a slower prior refresh cannot restore stale pending works', (
    WidgetTester tester,
  ) async {
    final VideoSourceScrapeTaskController controller =
        VideoSourceScrapeTaskController(_IdleRunner());
    addTearDown(controller.dispose);
    final Completer<List<VideoPendingScrapeWork>> older =
        Completer<List<VideoPendingScrapeWork>>();
    int calls = 0;
    await _open(tester, controller, () {
      if (++calls == 2) return older.future;
      return Future<List<VideoPendingScrapeWork>>.value(
        <VideoPendingScrapeWork>[_pending(calls == 1 ? 1 : 7)],
      );
    });
    await controller.scrapeSource(_source);
    await tester.pump();
    await controller.scrapeSource(_source);
    await tester.pumpAndSettle();
    expect(find.text('Unmatched video 7'), findsOneWidget);
    older.complete(<VideoPendingScrapeWork>[_pending(9)]);
    await tester.pumpAndSettle();
    expect(find.text('Unmatched video 7'), findsOneWidget);
    expect(find.text('Unmatched video 9'), findsNothing);
  });

  // 反馈 Fbchzxuq6f：确认界面以前只有「搜索作品」「AI 识别」，特典这类本来就没有
  // 条目的作品永远清不掉。每行加「忽略」；被忽略的作品列在「已忽略」里，可撤销。
  testWidgets(
    'ignoring a pending work moves it to the ignored group and back',
    (WidgetTester tester) async {
      await tester.binding.setSurfaceSize(const Size(1100, 1000));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final VideoSourceScrapeTaskController controller =
          VideoSourceScrapeTaskController(_IdleRunner());
      addTearDown(controller.dispose);
      final List<VideoPendingScrapeWork> all = <VideoPendingScrapeWork>[
        _pending(1),
        _pending(2),
      ];
      final Set<String> ignoredKeys = <String>{};
      final List<(String, bool)> calls = <(String, bool)>[];
      await _open(
        tester,
        controller,
        () async => <VideoPendingScrapeWork>[
          for (final VideoPendingScrapeWork e in all)
            if (!ignoredKeys.contains(e.work.stableKey)) e,
        ],
        loadIgnored: () async => <VideoPendingScrapeWork>[
          for (final VideoPendingScrapeWork e in all)
            if (ignoredKeys.contains(e.work.stableKey)) e,
        ],
        onSetWorkIgnored:
            (VideoPendingScrapeWork entry, {required bool ignored}) async {
              calls.add((entry.work.stableKey, ignored));
              if (ignored) {
                ignoredKeys.add(entry.work.stableKey);
              } else {
                ignoredKeys.remove(entry.work.stableKey);
              }
            },
      );
      expect(
        find.byKey(const ValueKey<String>('video-source-ignored-header')),
        findsNothing,
        reason: 'no ignored works, no ignored group',
      );

      await tester.tap(
        find.byKey(
          const ValueKey<String>('video-source-pending-ignore-book:video-2'),
        ),
      );
      await tester.pumpAndSettle();
      expect(calls, <(String, bool)>[('book:video-2', true)]);
      expect(
        find.byKey(
          const ValueKey<String>('video-source-pending-work-book:video-2'),
        ),
        findsNothing,
        reason: 'the ignored work leaves the pending list',
      );
      // 已忽略分组在清单末尾，懒加载列表里可能还在视口之外：先滚过去。
      await tester.ensureVisible(
        find.byKey(
          const ValueKey<String>('video-source-ignored-restore-book:video-2'),
          skipOffstage: false,
        ),
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(
          const ValueKey<String>('video-source-ignored-work-book:video-2'),
        ),
        findsOneWidget,
        reason: 'and stays visible in the ignored group',
      );
      expect(find.text('Ignored (1)'), findsOneWidget);
      expect(
        find.text('1'),
        findsOneWidget,
        reason: 'pending count badge drops',
      );

      await tester.tap(
        find.byKey(
          const ValueKey<String>('video-source-ignored-restore-book:video-2'),
        ),
      );
      await tester.pumpAndSettle();
      expect(calls.last, ('book:video-2', false));
      expect(
        find.byKey(
          const ValueKey<String>('video-source-pending-work-book:video-2'),
        ),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey<String>('video-source-ignored-header')),
        findsNothing,
      );
    },
  );

  testWidgets(
    'without an ignore port the pending rows offer no ignore button',
    (WidgetTester tester) async {
      final VideoSourceScrapeTaskController controller =
          VideoSourceScrapeTaskController(_IdleRunner());
      addTearDown(controller.dispose);
      await _open(
        tester,
        controller,
        () async => <VideoPendingScrapeWork>[_pending(1)],
      );
      expect(
        find.byKey(
          const ValueKey<String>('video-source-pending-ignore-book:video-1'),
        ),
        findsNothing,
      );
    },
  );
}
