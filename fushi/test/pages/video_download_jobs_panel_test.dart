import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_core/fushi_core.dart';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/pages/implementations/video_download_jobs_panel.dart';

final class _MemoryJobsStore implements VideoDownloadJobsPanelStore {
  final StreamController<List<VideoDownloadJobRow>> controller =
      StreamController<List<VideoDownloadJobRow>>.broadcast();

  @override
  Stream<List<VideoDownloadJobRow>> watchJobs() => controller.stream;

  void emit(List<VideoDownloadJobRow> jobs) => controller.add(jobs);

  Future<void> close() => controller.close();
}

VideoDownloadJobRow _job({
  required String id,
  required String title,
  String lifecycle = VideoDownloadJobLifecycle.active,
  String stage = VideoDownloadJobStage.download,
  double progress = 0.4,
  String? error,
  int? completedAt,
}) =>
    VideoDownloadJobRow(
      jobId: id,
      resourceProvider: 'nyaa:default',
      selectedResourceId: 'resource-$id',
      magnetUri: null,
      resourceTitle: 'A-Rather-Long-Release-Group 1080p HEVC',
      torrentHash: null,
      metadataProvider: 'anilist',
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
      stage: stage,
      stageProgress: progress,
      priority: 0,
      attemptCount: 0,
      maxAttempts: 3,
      nextAttemptAt: null,
      claimedBy: null,
      claimExpiresAt: null,
      lastError: error,
      createdAt: 1,
      updatedAt: 2,
      completedAt: completedAt,
    );

Future<void> _pumpPanel(
  WidgetTester tester, {
  required VideoDownloadJobsPanel panel,
  Size size = const Size(800, 700),
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });
  await tester.pumpWidget(
    TranslationProvider(
      child: MaterialApp(
        theme: ThemeData.dark(useMaterial3: true),
        home: Scaffold(body: panel),
      ),
    ),
  );
}

void main() {
  setUp(() => LocaleSettings.setLocale(AppLocale.en));

  testWidgets('watches lifecycle, stage, progress and safe error text',
      (WidgetTester tester) async {
    final _MemoryJobsStore store = _MemoryJobsStore();
    addTearDown(store.close);
    await _pumpPanel(
      tester,
      panel: VideoDownloadJobsPanel(store: store),
    );
    store.emit(<VideoDownloadJobRow>[
      _job(
        id: 'active',
        title: 'Downloading show',
        progress: 0.37,
      ),
      _job(
        id: 'attention',
        title: 'Needs attention show',
        lifecycle: VideoDownloadJobLifecycle.needsAttention,
        stage: VideoDownloadJobStage.subtitle,
        progress: 0.72,
        error: 'Subtitle quota exhausted; credentials were redacted.',
      ),
      _job(
        id: 'done',
        title: 'Completed show',
        lifecycle: VideoDownloadJobLifecycle.completed,
        stage: VideoDownloadJobStage.scrape,
        progress: 0.2,
        completedAt: 3,
      ),
    ]);
    await tester.pumpAndSettle();

    expect(find.text('Downloading show'), findsOneWidget);
    expect(find.text(VideoDownloadJobLifecycle.active), findsOneWidget);
    expect(find.text(VideoDownloadJobStage.download), findsOneWidget);
    expect(find.text('37%'), findsOneWidget);
    expect(
      find.text('Subtitle quota exhausted; credentials were redacted.'),
      findsOneWidget,
    );
    expect(find.text(VideoDownloadJobLifecycle.needsAttention), findsOneWidget);
    expect(find.text(VideoDownloadJobStage.subtitle), findsOneWidget);
    expect(find.text('72%'), findsOneWidget);
    expect(find.text(VideoDownloadJobLifecycle.completed), findsOneWidget);
    expect(find.text('100%'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('retry and cancel actions are limited to valid lifecycles',
      (WidgetTester tester) async {
    final _MemoryJobsStore store = _MemoryJobsStore();
    addTearDown(store.close);
    final List<String> retried = <String>[];
    final List<String> cancelled = <String>[];
    await _pumpPanel(
      tester,
      panel: VideoDownloadJobsPanel(
        store: store,
        onRetry: (VideoDownloadJobRow job) async => retried.add(job.jobId),
        onCancel: (VideoDownloadJobRow job) async => cancelled.add(job.jobId),
      ),
    );
    store.emit(<VideoDownloadJobRow>[
      _job(id: 'active', title: 'Active'),
      _job(
        id: 'attention',
        title: 'Attention',
        lifecycle: VideoDownloadJobLifecycle.needsAttention,
      ),
      _job(
        id: 'failed',
        title: 'Failed',
        lifecycle: VideoDownloadJobLifecycle.failed,
      ),
      _job(
        id: 'done',
        title: 'Done',
        lifecycle: VideoDownloadJobLifecycle.completed,
      ),
    ]);
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey<String>('video-download-job-cancel-active')),
      findsOneWidget,
    );
    expect(
      find.byKey(
        const ValueKey<String>('video-download-job-retry-attention'),
      ),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('video-download-job-retry-failed')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('video-download-job-retry-done')),
      findsNothing,
    );

    await tester.tap(
      find.byKey(const ValueKey<String>('video-download-job-cancel-active')),
    );
    await tester.tap(
      find.byKey(
        const ValueKey<String>('video-download-job-retry-attention'),
      ),
    );
    await tester.pump();
    expect(cancelled, <String>['active']);
    expect(retried, <String>['attention']);
  });

  testWidgets('long task content has no overflow at 360 logical pixels',
      (WidgetTester tester) async {
    final _MemoryJobsStore store = _MemoryJobsStore();
    addTearDown(store.close);
    await _pumpPanel(
      tester,
      size: const Size(360, 640),
      panel: VideoDownloadJobsPanel(
        store: store,
        onRetry: (VideoDownloadJobRow job) async {},
      ),
    );
    store.emit(<VideoDownloadJobRow>[
      _job(
        id: 'narrow',
        title:
            'A very long anime title that must wrap safely on a narrow phone',
        lifecycle: VideoDownloadJobLifecycle.needsAttention,
        stage: VideoDownloadJobStage.organize,
        error:
            'The configured remote-to-local path cannot be mapped to the target source; review the backend mapping before retrying.',
      ),
    ]);
    await tester.pumpAndSettle();

    expect(find.textContaining('A very long anime title'), findsOneWidget);
    expect(find.text(VideoDownloadJobStage.organize), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('wide download task cards fill the available page width',
      (WidgetTester tester) async {
    final _MemoryJobsStore store = _MemoryJobsStore();
    addTearDown(store.close);
    await _pumpPanel(
      tester,
      size: const Size(1400, 800),
      panel: VideoDownloadJobsPanel(store: store),
    );
    store.emit(<VideoDownloadJobRow>[
      _job(id: 'wide', title: 'Full width task'),
    ]);
    await tester.pumpAndSettle();

    final Finder card = find.byKey(
      const ValueKey<String>('video-download-job-wide'),
    );
    expect(tester.getSize(card).width, greaterThan(1300));
    expect(tester.takeException(), isNull);
  });
}
