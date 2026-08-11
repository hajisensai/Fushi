import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_core/fushi_core.dart';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/torrent/torrent_backend.dart';
import 'package:fushi/src/media/video/download/video_download_error_presentation.dart';
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

  test('classifyVideoDownloadError maps common pipeline diagnostics', () {
    expect(
      classifyVideoDownloadError('The managed video source no longer exists'),
      VideoDownloadErrorCategory.managedSourceMissing,
    );
    // 复合原因以主因归类：未确认种子优先于字幕。
    expect(
      classifyVideoDownloadError(
        'needsAttention: backend torrent was not confirmed by hash, title, '
        'and category; legacy subtitle selection was unavailable',
      ),
      VideoDownloadErrorCategory.backendUnconfirmed,
    );
    expect(
      classifyVideoDownloadError('Required subtitles could not be installed'),
      VideoDownloadErrorCategory.subtitleUnavailable,
    );
    expect(
      classifyVideoDownloadError(
        'The original download backend is not configured on this device',
      ),
      VideoDownloadErrorCategory.backendUnavailable,
    );
    expect(
      classifyVideoDownloadError('Torrent id is missing'),
      VideoDownloadErrorCategory.torrentInfoMissing,
    );
    expect(
      classifyVideoDownloadError(
        'needsAttention: legacy collection is unavailable on this device',
      ),
      VideoDownloadErrorCategory.legacyImport,
    );
    expect(
      classifyVideoDownloadError('ENOSPC: no space left on device, write'),
      VideoDownloadErrorCategory.unknown,
    );
  });

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
    expect(find.text(t.download_task_status_downloading), findsOneWidget);
    expect(find.text(t.download_task_stage_download), findsOneWidget);
    expect(find.text('37%'), findsOneWidget);
    // BUG-1540：卡片上不再整句铺原始错误串，只显示分类后的一行摘要。
    expect(
      find.text('Subtitle quota exhausted; credentials were redacted.'),
      findsNothing,
    );
    expect(find.text(t.download_task_error_summary_subtitle), findsOneWidget);
    expect(
      find.text(t.download_task_lifecycle_needs_attention),
      findsOneWidget,
    );
    expect(find.text(t.download_task_stage_subtitle), findsOneWidget);
    expect(find.text('72%'), findsOneWidget);
    expect(find.text(t.download_task_status_completed), findsOneWidget);
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
    expect(find.text(t.download_task_stage_organize), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'error area shows one localized summary line and opens a copyable '
      'detail dialog with the raw error (BUG-1540)',
      (WidgetTester tester) async {
    const String rawError =
        'needsAttention: backend torrent was not confirmed by hash, title, '
        'and category; legacy subtitle selection was unavailable';
    final _MemoryJobsStore store = _MemoryJobsStore();
    addTearDown(store.close);
    await _pumpPanel(
      tester,
      size: const Size(360, 640),
      panel: VideoDownloadJobsPanel(store: store),
    );
    store.emit(<VideoDownloadJobRow>[
      _job(
        id: 'attention',
        title: 'Hibike! Euphonium',
        lifecycle: VideoDownloadJobLifecycle.needsAttention,
        stage: VideoDownloadJobStage.download,
        error: rawError,
      ),
    ]);
    await tester.pumpAndSettle();

    // 卡片上只有摘要（单行省略），没有整句原文，也没有布局溢出。
    expect(find.text(rawError), findsNothing);
    expect(
      find.text(t.download_task_error_summary_backend_unconfirmed),
      findsOneWidget,
    );
    final Text summary = tester.widget<Text>(
      find.text(t.download_task_error_summary_backend_unconfirmed),
    );
    expect(summary.maxLines, 1);
    expect(summary.overflow, TextOverflow.ellipsis);
    expect(tester.takeException(), isNull);

    // 点击错误行弹出详情对话框，原始错误完整可见且可复制。
    await tester.tap(
      find.byKey(const ValueKey<String>('video-download-job-error-attention')),
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(
        const ValueKey<String>('video-download-job-error-detail-dialog'),
      ),
      findsOneWidget,
    );
    expect(find.text(t.download_task_error_detail_title), findsOneWidget);
    expect(
      find.descendant(
        of: find.byType(SelectableText),
        matching: find.text(rawError),
      ),
      findsOneWidget,
    );
    expect(find.text(t.copy), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.tap(find.text(t.dialog_close));
    await tester.pumpAndSettle();
    expect(
      find.byKey(
        const ValueKey<String>('video-download-job-error-detail-dialog'),
      ),
      findsNothing,
    );
  });

  testWidgets('unknown errors fall back to the generic localized summary',
      (WidgetTester tester) async {
    final _MemoryJobsStore store = _MemoryJobsStore();
    addTearDown(store.close);
    await _pumpPanel(
      tester,
      panel: VideoDownloadJobsPanel(store: store),
    );
    store.emit(<VideoDownloadJobRow>[
      _job(
        id: 'weird',
        title: 'Unknown failure show',
        lifecycle: VideoDownloadJobLifecycle.failed,
        error: 'ENOSPC: no space left on device, write',
      ),
    ]);
    await tester.pumpAndSettle();

    expect(find.text('ENOSPC: no space left on device, write'), findsNothing);
    expect(
      find.text(t.download_task_error_summary_generic),
      findsOneWidget,
    );
    expect(find.text(t.download_task_lifecycle_failed), findsOneWidget);
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

  testWidgets('shows real torrent size, status, peers, rates, ETA and ratio',
      (WidgetTester tester) async {
    final _MemoryJobsStore store = _MemoryJobsStore();
    addTearDown(store.close);
    await _pumpPanel(
      tester,
      size: const Size(1400, 800),
      panel: VideoDownloadJobsPanel(
        store: store,
        metricsLoader: (Iterable<VideoDownloadJobRow> jobs) async =>
            <String, TorrentSnapshot>{
          'metrics': const TorrentSnapshot(
            hash: 'hash',
            name: 'Metrics release',
            progress: 0.5,
            state: 'downloading',
            savePath: r'D:\Downloads',
            contentPath: r'D:\Downloads\Metrics release',
            amountLeft: 10485760,
            totalSizeBytes: 2147483648,
            downRateBps: 1048576,
            upRateBps: 524288,
            downloadedBytes: 1073741824,
            uploadedBytes: 536870912,
            numSeeds: 3,
            swarmSeeds: 20,
            numLeechs: 7,
            swarmLeechs: 42,
          ),
        },
      ),
    );
    store.emit(<VideoDownloadJobRow>[
      _job(id: 'metrics', title: 'Metrics task'),
    ]);
    await tester.pump();
    await tester.pump();

    expect(find.text(t.download_task_status_downloading), findsOneWidget);
    expect(find.text('2.0 GB'), findsOneWidget);
    expect(find.text('3 (20)'), findsOneWidget);
    expect(find.text('7 (42)'), findsOneWidget);
    expect(find.text('1.0 MB/s'), findsOneWidget);
    expect(find.text('512.0 KB/s'), findsOneWidget);
    expect(find.text('10s'), findsOneWidget);
    expect(find.text('0.50'), findsOneWidget);
    expect(find.text('50%'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('falls back to durable selected file size without live backend',
      (WidgetTester tester) async {
    final _MemoryJobsStore store = _MemoryJobsStore();
    addTearDown(store.close);
    await _pumpPanel(
      tester,
      panel: VideoDownloadJobsPanel(
        store: store,
        selectedSizeLoader: (Iterable<VideoDownloadJobRow> jobs) async =>
            <String, int>{'history': 659721721},
      ),
    );
    store.emit(<VideoDownloadJobRow>[
      _job(
        id: 'history',
        title: 'Historical completed task',
        lifecycle: VideoDownloadJobLifecycle.completed,
      ),
    ]);
    await tester.pump();
    await tester.pump();

    expect(find.text('629.2 MB'), findsOneWidget);
    expect(find.text(t.download_task_status_completed), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
