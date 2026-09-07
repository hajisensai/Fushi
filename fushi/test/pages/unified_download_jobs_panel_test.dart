import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/downloads/download_task_browser.dart';
import 'package:fushi/src/media/downloads/download_task_card.dart';
import 'package:fushi/src/media/downloads/download_task_entry.dart';
import 'package:fushi/src/media/torrent/torrent_backend.dart';
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
      await tester.tap(
        find.byKey(const ValueKey<String>('download-task-toggle-done')),
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
}

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
