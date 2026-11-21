import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/downloads/download_batch.dart';
import 'package:fushi/src/media/downloads/download_task_browser.dart';
import 'package:fushi/src/media/downloads/download_task_card.dart';
import 'package:fushi/src/media/downloads/download_task_entry.dart';
import 'package:fushi_engine/media/torrent/torrent_backend.dart';
import 'package:fushi/src/pages/implementations/video_download_jobs_panel.dart';
import 'package:fushi_core/fushi_core.dart';

final class _JobsStore implements VideoDownloadJobsPanelStore {
  final StreamController<List<VideoDownloadJobRow>> controller =
      StreamController<List<VideoDownloadJobRow>>.broadcast();
  int subscriptions = 0;

  @override
  Stream<List<VideoDownloadJobRow>> watchJobs() {
    subscriptions++;
    return controller.stream;
  }

  Future<void> close() => controller.close();
}

DownloadTaskEntry _external(String id, String title) => DownloadTaskEntry(
  id: id,
  title: title,
  kind: DownloadTaskKind.game,
  status: DownloadTaskStatus.active,
  builder: (BuildContext context) => DownloadTaskCard(
    taskId: id,
    title: title,
    status: 'Downloading',
    details: const Text('External source actions'),
  ),
);

Widget _host(VideoDownloadJobsPanel panel) => TranslationProvider(
  child: MaterialApp(
    theme: ThemeData.dark(useMaterial3: true),
    // MD3 Expressive 波浪进度在确定态（0<value<1）也持续推相位，pumpAndSettle
    // 永远等不到静止；「减少动态效果」下它退回静止直线，面板行为不受影响。
    builder: (BuildContext context, Widget? child) => MediaQuery(
      data: MediaQuery.of(context).copyWith(disableAnimations: true),
      child: child!,
    ),
    home: Scaffold(body: panel),
  ),
);

Future<void> _pump(WidgetTester tester, VideoDownloadJobsPanel panel) async {
  tester.view.physicalSize = const Size(1200, 1000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(_host(panel));
  await tester.pumpAndSettle();
}

List<DownloadTaskEntry> _entries(WidgetTester tester) =>
    tester.widget<DownloadTaskBrowser>(find.byType(DownloadTaskBrowser)).tasks;

void main() {
  setUp(() => LocaleSettings.setLocale(AppLocale.en));

  testWidgets(
    'durable jobs replace only exact legacy ids, not identical titles',
    (WidgetTester tester) async {
      final _JobsStore store = _JobsStore();
      addTearDown(store.close);
      await _pump(
        tester,
        VideoDownloadJobsPanel(
          store: store,
          unified: true,
          additionalTasks: <DownloadTaskEntry>[
            _external('shared-id', 'Stale legacy title'),
            _external('different-id', 'Same game'),
          ],
        ),
      );
      store.controller.add(<VideoDownloadJobRow>[
        _job(id: 'shared-id', title: 'Same game'),
      ]);
      await tester.pumpAndSettle();
      expect(
        _entries(tester).map((DownloadTaskEntry task) => task.id),
        unorderedEquals(<String>['shared-id', 'different-id']),
      );
      expect(find.text('Stale legacy title'), findsNothing);
      expect(find.byType(DownloadTaskCard), findsNWidgets(2));
      expect(
        _entries(
          tester,
        ).singleWhere((DownloadTaskEntry task) => task.id == 'shared-id').kind,
        DownloadTaskKind.video,
        reason: 'The durable entry must own the duplicate',
      );
    },
  );

  testWidgets(
    'external tasks render before database emits and with empty rows',
    (WidgetTester tester) async {
      final _JobsStore store = _JobsStore();
      addTearDown(store.close);
      await _pump(
        tester,
        VideoDownloadJobsPanel(
          store: store,
          unified: true,
          additionalTasks: <DownloadTaskEntry>[_external('http', 'HTTP game')],
        ),
      );
      expect(find.text('HTTP game'), findsOneWidget);
      store.controller.add(const <VideoDownloadJobRow>[]);
      await tester.pumpAndSettle();
      expect(find.text('HTTP game'), findsOneWidget);
      expect(find.text(t.anime_download_no_tasks), findsNothing);
    },
  );

  testWidgets('database errors keep external tasks actionable', (
    WidgetTester tester,
  ) async {
    final _JobsStore store = _JobsStore();
    addTearDown(store.close);
    await _pump(
      tester,
      VideoDownloadJobsPanel(
        store: store,
        unified: true,
        additionalTasks: <DownloadTaskEntry>[_external('http', 'HTTP game')],
      ),
    );
    store.controller.addError(StateError('Database unavailable'));
    await tester.pumpAndSettle();
    expect(find.text(t.error_load_failed), findsOneWidget);
    expect(find.text('HTTP game'), findsOneWidget);
    await tester.tap(
      find.byKey(const ValueKey<String>('download-task-toggle-http')),
    );
    await tester.pumpAndSettle();
    expect(find.text('External source actions'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('external refresh retains durable stream and its rows', (
    WidgetTester tester,
  ) async {
    final _JobsStore store = _JobsStore();
    addTearDown(store.close);
    await _pump(tester, VideoDownloadJobsPanel(store: store, unified: true));
    store.controller.add(<VideoDownloadJobRow>[
      _job(id: 'durable', title: 'Saved game'),
    ]);
    await tester.pumpAndSettle();
    await tester.pumpWidget(
      _host(
        VideoDownloadJobsPanel(
          store: store,
          unified: true,
          additionalTasks: <DownloadTaskEntry>[_external('http', 'HTTP game')],
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(store.subscriptions, 1);
    expect(
      _entries(tester).map((DownloadTaskEntry task) => task.id),
      unorderedEquals(<String>['durable', 'http']),
    );
  });

  testWidgets(
    'compact durable cards retain details and safe deletion actions',
    (WidgetTester tester) async {
      final _JobsStore store = _JobsStore();
      addTearDown(store.close);
      final List<String> opened = <String>[];
      final List<(String, bool)> deleted = <(String, bool)>[];
      await _pump(
        tester,
        VideoDownloadJobsPanel(
          store: store,
          unified: true,
          onOpenDetails: (VideoDownloadJobRow job) async {
            opened.add(job.jobId);
          },
          onDelete:
              (VideoDownloadJobRow job, {required bool deleteFiles}) async {
                deleted.add((job.jobId, deleteFiles));
              },
        ),
      );
      store.controller.add(<VideoDownloadJobRow>[
        _job(
          id: 'done',
          title: 'Finished game',
          lifecycle: VideoDownloadJobLifecycle.completed,
        ),
      ]);
      await tester.pumpAndSettle();
      final Finder details = find.byKey(
        const ValueKey<String>('video-download-job-details-done'),
      );
      final Finder delete = find.byKey(
        const ValueKey<String>('video-download-job-delete-done'),
      );
      expect(details, findsNothing);
      expect(delete, findsNothing);
      // 点行里的标题：行中心可能正落在标题旁可点的方式 / 来源标签上（标签
      // 点按弹说明，不展开行）。
      await tester.tap(
        find.descendant(
          of: find.byKey(const ValueKey<String>('download-task-toggle-done')),
          matching: find.text('Finished game'),
        ),
      );
      await tester.pumpAndSettle();
      await tester.ensureVisible(details);
      await tester.tap(details);
      await tester.pumpAndSettle();
      expect(opened, <String>['done']);
      await tester.ensureVisible(delete);
      await tester.tap(delete);
      await tester.pumpAndSettle();
      expect(
        deleted,
        isEmpty,
        reason: 'Opening the confirmation must not delete anything',
      );
      await tester.tap(
        find.byKey(
          const ValueKey<String>('video-download-job-delete-confirm-done'),
        ),
      );
      await tester.pumpAndSettle();
      expect(deleted, <(String, bool)>[('done', false)]);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('live paused and queued snapshots enter unified status filters', (
    WidgetTester tester,
  ) async {
    final _JobsStore store = _JobsStore();
    addTearDown(store.close);
    await _pump(
      tester,
      VideoDownloadJobsPanel(
        store: store,
        unified: true,
        metricsLoader: (Iterable<VideoDownloadJobRow> jobs) async =>
            <String, TorrentSnapshot>{
              for (final VideoDownloadJobRow job in jobs)
                job.jobId: TorrentSnapshot(
                  hash: job.jobId,
                  name: job.title,
                  progress: 0.3,
                  state: job.jobId == 'paused' ? 'pausedDL' : 'queuedDL',
                  savePath: '',
                  contentPath: '',
                  amountLeft: 100,
                ),
            },
      ),
    );
    store.controller.add(<VideoDownloadJobRow>[
      _job(id: 'paused', title: 'Paused game'),
      _job(id: 'queued', title: 'Queued game'),
    ]);
    await tester.pumpAndSettle();
    expect(
      selectDownloadTasks(
        _entries(tester),
        status: DownloadTaskStatus.paused,
      ).map((DownloadTaskEntry task) => task.id),
      <String>['paused'],
    );
    expect(
      selectDownloadTasks(
        _entries(tester),
        status: DownloadTaskStatus.queued,
      ).map((DownloadTaskEntry task) => task.id),
      <String>['queued'],
    );
    await tester.pumpWidget(const SizedBox.shrink());
  });

  // BUG-5072：已完成但种子仍在后端的任务，批量与单条都能停 / 续做种，且走
  // 做种回调而不是改持久生命周期的 cancel/resume；种子已不在后端的不提供。
  testWidgets(
    'completed jobs still in the backend can pause and resume seeding '
    'from both the batch slot and the card',
    (WidgetTester tester) async {
      final _JobsStore store = _JobsStore();
      addTearDown(store.close);
      final List<String> pausedSeeding = <String>[];
      final List<String> resumedSeeding = <String>[];
      final List<String> lifecycleCalls = <String>[];
      await _pump(
        tester,
        VideoDownloadJobsPanel(
          store: store,
          unified: true,
          onCancel: (VideoDownloadJobRow job) async =>
              lifecycleCalls.add('cancel:${job.jobId}'),
          onResume: (List<VideoDownloadJobRow> jobs) async {
            lifecycleCalls.addAll(<String>[
              for (final VideoDownloadJobRow job in jobs) 'resume:${job.jobId}',
            ]);
            return const <String, Object>{};
          },
          onPauseSeeding: (List<VideoDownloadJobRow> jobs) async {
            pausedSeeding.addAll(_ids(jobs));
            return const <String, Object>{};
          },
          onResumeSeeding: (List<VideoDownloadJobRow> jobs) async {
            resumedSeeding.addAll(_ids(jobs));
            return const <String, Object>{};
          },
          metricsLoader: (Iterable<VideoDownloadJobRow> jobs) async =>
              <String, TorrentSnapshot>{
                for (final VideoDownloadJobRow job in jobs)
                  if (job.jobId != 'gone')
                    job.jobId: TorrentSnapshot(
                      hash: job.jobId,
                      name: job.title,
                      progress: 1,
                      state: job.jobId == 'stopped' ? 'pausedUP' : 'uploading',
                      savePath: '',
                      contentPath: '',
                      amountLeft: 0,
                    ),
              },
        ),
      );
      const String completed = VideoDownloadJobLifecycle.completed;
      store.controller.add(<VideoDownloadJobRow>[
        _job(id: 'seeding', title: 'Seeding show', lifecycle: completed),
        _job(id: 'stopped', title: 'Stopped show', lifecycle: completed),
        _job(id: 'gone', title: 'Removed show', lifecycle: completed),
      ]);
      await tester.pumpAndSettle();

      final Map<String, DownloadTaskEntry> byId = <String, DownloadTaskEntry>{
        for (final DownloadTaskEntry task in _entries(tester)) task.id: task,
      };
      expect(byId['seeding']!.actions.pause, isNotNull);
      expect(byId['seeding']!.actions.resume, isNull);
      expect(byId['stopped']!.actions.pause, isNull);
      expect(byId['stopped']!.actions.resume, isNotNull);
      expect(byId['gone']!.actions.pause, isNull);
      expect(byId['gone']!.actions.resume, isNull);

      // 用户的路径：全选后批量暂停 / 继续。
      final DownloadBatchOutcome pauseOutcome = await runDownloadTaskBatch(
        tasks: byId.values,
        action: DownloadBatchAction.pause,
      );
      expect(pauseOutcome.done, 1);
      expect(pauseOutcome.unsupported, 2);
      expect(pausedSeeding, <String>['seeding']);
      final DownloadBatchOutcome resumeOutcome = await runDownloadTaskBatch(
        tasks: byId.values,
        action: DownloadBatchAction.resume,
      );
      expect(resumeOutcome.done, 1);
      expect(resumedSeeding, <String>['stopped']);

      // 单条入口与批量同一判据：卡片行尾主操作。
      expect(
        find.byKey(
          const ValueKey<String>('video-download-job-quick-pause-seeding'),
        ),
        findsOneWidget,
      );
      expect(
        find.byKey(
          const ValueKey<String>('video-download-job-quick-resume-stopped'),
        ),
        findsOneWidget,
      );
      expect(
        find.byKey(
          const ValueKey<String>('video-download-job-quick-pause-gone'),
        ),
        findsNothing,
      );
      expect(
        find.byKey(
          const ValueKey<String>('video-download-job-quick-resume-gone'),
        ),
        findsNothing,
      );
      await tester.tap(
        find.byKey(
          const ValueKey<String>('video-download-job-quick-pause-seeding'),
        ),
      );
      await tester.pumpAndSettle();
      expect(pausedSeeding, <String>['seeding', 'seeding']);
      expect(lifecycleCalls, isEmpty);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  // HBK-AUDIT-025：批量暂停 / 继续整批交给来源一次（来源整批只枚举一次后端），
  // 整批结束只重读一次快照。修复前逐条调做种回调、每条各刷新一次面板。
  testWidgets('batch pause / resume hands each source one batch call and '
      'refreshes snapshots once', (WidgetTester tester) async {
    final _JobsStore store = _JobsStore();
    addTearDown(store.close);
    final List<List<String>> seedingPauseCalls = <List<String>>[];
    final List<List<String>> seedingResumeCalls = <List<String>>[];
    final List<List<String>> lifecycleResumeCalls = <List<String>>[];
    final List<String> cancelled = <String>[];
    final Set<String> pausedSeeds = <String>{};
    int metricsLoads = 0;
    await _pump(
      tester,
      VideoDownloadJobsPanel(
        store: store,
        unified: true,
        onCancel: (VideoDownloadJobRow job) async => cancelled.add(job.jobId),
        onResume: (List<VideoDownloadJobRow> jobs) async {
          lifecycleResumeCalls.add(_ids(jobs));
          return const <String, Object>{};
        },
        onPauseSeeding: (List<VideoDownloadJobRow> jobs) async {
          seedingPauseCalls.add(_ids(jobs));
          pausedSeeds.addAll(_ids(jobs));
          // 第一条在来源侧失败：只它计入失败，其余照常。
          return <String, Object>{jobs.first.jobId: StateError('boom')};
        },
        onResumeSeeding: (List<VideoDownloadJobRow> jobs) async {
          seedingResumeCalls.add(_ids(jobs));
          return const <String, Object>{};
        },
        metricsLoader: (Iterable<VideoDownloadJobRow> jobs) async {
          metricsLoads++;
          return <String, TorrentSnapshot>{
            for (final VideoDownloadJobRow job in jobs)
              if (job.lifecycle == VideoDownloadJobLifecycle.completed)
                job.jobId: TorrentSnapshot(
                  hash: job.jobId,
                  name: job.title,
                  progress: 1,
                  state: job.jobId.startsWith('stopped')
                      ? 'pausedUP'
                      : 'uploading',
                  savePath: '',
                  contentPath: '',
                  amountLeft: 0,
                ),
          };
        },
      ),
    );
    const String completed = VideoDownloadJobLifecycle.completed;
    store.controller.add(<VideoDownloadJobRow>[
      for (int i = 0; i < 4; i++)
        _job(id: 'seed-$i', title: 'Seed $i', lifecycle: completed),
      for (int i = 0; i < 3; i++)
        _job(id: 'stopped-$i', title: 'Stopped $i', lifecycle: completed),
      _job(id: 'running', title: 'Running'),
      _job(
        id: 'paused',
        title: 'Paused',
        lifecycle: VideoDownloadJobLifecycle.cancelled,
      ),
    ]);
    await tester.pumpAndSettle();
    final List<DownloadTaskEntry> tasks = _entries(tester);
    expect(tasks, hasLength(9));

    final int loadsBeforePause = metricsLoads;
    final DownloadBatchOutcome pause = await runDownloadTaskBatch(
      tasks: tasks,
      action: DownloadBatchAction.pause,
    );
    await tester.pump();
    expect(seedingPauseCalls, <List<String>>[
      <String>['seed-0', 'seed-1', 'seed-2', 'seed-3'],
    ]);
    expect(cancelled, <String>['running']);
    expect(pause.done, 4);
    expect(pause.failed, 1);
    expect(pause.unsupported, 4);
    expect(metricsLoads - loadsBeforePause, 1);

    final int loadsBeforeResume = metricsLoads;
    final DownloadBatchOutcome resume = await runDownloadTaskBatch(
      tasks: tasks,
      action: DownloadBatchAction.resume,
    );
    await tester.pump();
    expect(seedingResumeCalls, <List<String>>[
      <String>['stopped-0', 'stopped-1', 'stopped-2'],
    ]);
    expect(lifecycleResumeCalls, <List<String>>[
      <String>['paused'],
    ]);
    expect(resume.done, 4);
    expect(metricsLoads - loadsBeforeResume, 1);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}

List<String> _ids(List<VideoDownloadJobRow> jobs) => <String>[
  for (final VideoDownloadJobRow job in jobs) job.jobId,
];

VideoDownloadJobRow _job({
  required String id,
  required String title,
  String lifecycle = VideoDownloadJobLifecycle.active,
}) => VideoDownloadJobRow(
  jobId: id,
  resourceProvider: 'nyaa:default',
  selectedResourceId: 'resource-$id',
  magnetUri: null,
  resourceTitle: 'A-Rather-Long-Release-Group 1080p HEVC',
  torrentHash: null,
  metadataProvider: 'anidb',
  externalId: 'media-$id',
  mediaKind: 'tv',
  discoveryCategory: 'anime',
  title: title,
  year: 2026,
  season: 1,
  coverUrl: null,
  backendKind: 'embedded',
  backendTaskId: null,
  backendProfileId: 'default',
  fingerprint: 'embedded-test',
  category: 'fushi-video',
  targetSourceId: null,
  collectionId: null,
  organizationPolicy: 'library',
  subtitlePolicy: 'bestEffort',
  observedSavePath: null,
  targetRelativeRoot: null,
  lifecycle: lifecycle,
  stage: VideoDownloadJobStage.download,
  stageProgress: 0.4,
  priority: 0,
  attemptCount: 0,
  maxAttempts: 3,
  nextAttemptAt: null,
  claimedBy: null,
  claimExpiresAt: null,
  lastError: null,
  createdAt: 1,
  updatedAt: 2,
  completedAt: null,
);
