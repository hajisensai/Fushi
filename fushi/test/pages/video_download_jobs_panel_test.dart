import 'dart:async';
import 'dart:io';

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
  group('reveal command', () {
    test('windows keeps /select, and the path as separate arguments', () {
      final VideoDownloadRevealCommand command = videoDownloadRevealCommand(
        host: VideoDownloadRevealHost.windows,
        path: r'D:\media\Show S01E01.mkv',
        isDirectory: false,
      );

      expect(command.executable, 'explorer');
      // Measured on Windows 11: joining these into one argument makes Dart
      // quote it ("/select,D:\media\Show S01E01.mkv") and explorer answers by
      // opening Documents. Split, it selects the file every time.
      expect(
          command.arguments, <String>['/select,', r'D:\media\Show S01E01.mkv']);
    });

    test('windows explorer exit codes carry no success signal', () {
      expect(
        videoDownloadRevealCommand(
          host: VideoDownloadRevealHost.windows,
          path: r'D:\media\Show S01E01.mkv',
          isDirectory: false,
        ).exitCodeIsMeaningful,
        isFalse,
      );
      expect(
        videoDownloadRevealCommand(
          host: VideoDownloadRevealHost.macos,
          path: '/media/Show S01E01.mkv',
          isDirectory: false,
        ).exitCodeIsMeaningful,
        isTrue,
      );
    });

    test('windows reveal succeeds although explorer.exe exits with 1',
        () async {
      String? executable;
      List<String>? arguments;
      final bool revealed = await revealVideoDownloadPathOn(
        r'D:\media\Show S01E01.mkv',
        host: VideoDownloadRevealHost.windows,
        typeOf: (String _) async => FileSystemEntityType.file,
        run: (String value, List<String> args) async {
          executable = value;
          arguments = args;
          // explorer.exe returns 1 even when it opened and selected the file.
          return ProcessResult(0, 1, '', '');
        },
      );

      expect(revealed, isTrue);
      expect(executable, 'explorer');
      expect(arguments, <String>['/select,', r'D:\media\Show S01E01.mkv']);
    });

    test('a failing exit code still fails where it means something', () async {
      expect(
        await revealVideoDownloadPathOn(
          '/media/Show S01E01.mkv',
          host: VideoDownloadRevealHost.macos,
          typeOf: (String _) async => FileSystemEntityType.file,
          run: (String _, List<String> __) async => ProcessResult(0, 1, '', ''),
        ),
        isFalse,
      );
    });

    test('a host without a file manager never spawns anything', () async {
      bool spawned = false;
      final bool revealed = await revealVideoDownloadPathOn(
        '/storage/emulated/0/Show S01E01.mkv',
        host: null,
        typeOf: (String _) async => FileSystemEntityType.file,
        run: (String _, List<String> __) async {
          spawned = true;
          return ProcessResult(0, 0, '', '');
        },
      );

      expect(revealed, isFalse);
      expect(spawned, isFalse);
    });

    test('a missing path never spawns anything', () async {
      bool spawned = false;
      final bool revealed = await revealVideoDownloadPathOn(
        r'D:\media\gone.mkv',
        host: VideoDownloadRevealHost.windows,
        typeOf: (String _) async => FileSystemEntityType.notFound,
        run: (String _, List<String> __) async {
          spawned = true;
          return ProcessResult(0, 0, '', '');
        },
      );

      expect(revealed, isFalse);
      expect(spawned, isFalse);
    });
  });

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

  testWidgets('retry, resume and cancel actions match their lifecycles',
      (WidgetTester tester) async {
    final _MemoryJobsStore store = _MemoryJobsStore();
    addTearDown(store.close);
    final List<String> retried = <String>[];
    final List<String> resumed = <String>[];
    final List<String> cancelled = <String>[];
    await _pumpPanel(
      tester,
      // Five cards, and the list builds lazily: the viewport has to be tall
      // enough for the paused and completed cards to exist at all.
      size: const Size(800, 1800),
      panel: VideoDownloadJobsPanel(
        store: store,
        onRetry: (VideoDownloadJobRow job) async => retried.add(job.jobId),
        onResume: (VideoDownloadJobRow job) async => resumed.add(job.jobId),
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
        id: 'paused',
        title: 'Paused',
        lifecycle: VideoDownloadJobLifecycle.cancelled,
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
    expect(
      find.byKey(const ValueKey<String>('video-download-job-resume-paused')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('video-download-job-resume-active')),
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
    await tester.tap(
      find.byKey(const ValueKey<String>('video-download-job-resume-paused')),
    );
    await tester.pump();
    expect(cancelled, <String>['active']);
    expect(retried, <String>['attention']);
    expect(resumed, <String>['paused']);
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

  // 删除确认里的「同时删除文件」行由框架 CheckboxListTile 换成了共享 MD3
  // `FushiListItem` + 裸 `Checkbox`（MD3 守卫禁用本地 chrome）。换件必须等价：
  // 勾选框本身可点、整行也可点、默认不删文件、勾选后的取值真的穿到 onDelete。
  testWidgets('delete confirm passes the delete-files choice through',
      (WidgetTester tester) async {
    final _MemoryJobsStore store = _MemoryJobsStore();
    addTearDown(store.close);
    final List<bool> deleteCalls = <bool>[];
    await _pumpPanel(
      tester,
      panel: VideoDownloadJobsPanel(
        store: store,
        onDelete: (VideoDownloadJobRow job, {required bool deleteFiles}) async {
          deleteCalls.add(deleteFiles);
        },
      ),
    );
    store.emit(<VideoDownloadJobRow>[
      _job(
        id: 'gone',
        title: 'Finished task',
        lifecycle: VideoDownloadJobLifecycle.completed,
      ),
    ]);
    await tester.pump();
    await tester.pump();

    Future<void> openDialog() async {
      await tester.tap(
        find.byKey(const ValueKey<String>('video-download-job-delete-gone')),
      );
      await tester.pumpAndSettle();
    }

    Finder checkboxRow() => find.byKey(
          const ValueKey<String>('video-download-job-delete-files-gone'),
        );
    bool checked() => tester
        .widget<Checkbox>(
          find.descendant(of: checkboxRow(), matching: find.byType(Checkbox)),
        )
        .value!;

    // ① 不碰勾选框直接确认 ⇒ 默认保留文件。
    await openDialog();
    expect(checked(), isFalse, reason: '删除文件是破坏性选项，默认必须不勾');
    await tester.tap(
      find.byKey(
        const ValueKey<String>('video-download-job-delete-confirm-gone'),
      ),
    );
    await tester.pumpAndSettle();
    expect(deleteCalls, <bool>[false]);

    // ② 点勾选框本身翻转。
    await openDialog();
    await tester.tap(
      find.descendant(of: checkboxRow(), matching: find.byType(Checkbox)),
    );
    await tester.pump();
    expect(checked(), isTrue);
    await tester.tap(
      find.byKey(
        const ValueKey<String>('video-download-job-delete-confirm-gone'),
      ),
    );
    await tester.pumpAndSettle();
    expect(deleteCalls, <bool>[false, true]);

    // ③ 点整行（标题文字）同样翻转——这是 CheckboxListTile 原有的整行命中区，
    //    换成 FushiListItem 后靠 onTap 保住，丢了就是可点区域缩水。
    await openDialog();
    await tester.tap(find.text(t.download_task_delete_files));
    await tester.pump();
    expect(checked(), isTrue, reason: '整行命中区不得随组件替换丢失');
    await tester.tap(
      find.byKey(
        const ValueKey<String>('video-download-job-delete-confirm-gone'),
      ),
    );
    await tester.pumpAndSettle();
    expect(deleteCalls, <bool>[false, true, true]);
    expect(tester.takeException(), isNull);
  });

  // 用户报障：「没办法设置每个任务的优先权」。priority 列和 DAO 侧的
  // `priority DESC` 排序一直都在，缺的就是这个写入口。
  testWidgets('优先级菜单把选中的档位原样交给宿主（绝对值，不是加减）', (WidgetTester tester) async {
    final _MemoryJobsStore store = _MemoryJobsStore();
    addTearDown(store.close);
    final List<(String, int)> calls = <(String, int)>[];
    await _pumpPanel(
      tester,
      panel: VideoDownloadJobsPanel(
        store: store,
        onSetPriority: (VideoDownloadJobRow job, int priority) async {
          calls.add((job.jobId, priority));
        },
      ),
    );
    store.emit(<VideoDownloadJobRow>[
      _job(id: 'active', title: 'Downloading show'),
    ]);
    await tester.pumpAndSettle();

    await tester.tap(
      find.byKey(const ValueKey<String>('video-download-job-priority-active')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text(t.download_task_priority_high).last);
    await tester.pumpAndSettle();

    expect(calls, <(String, int)>[('active', 1)],
        reason: '菜单选「高」必须原样传 1。用加减实现的话反复点会漂，'
            '同一档点两次得到不同结果。');
    expect(tester.takeException(), isNull);
  });

  testWidgets('已完成的任务不给优先级入口（调了也不会被重新取走）', (WidgetTester tester) async {
    final _MemoryJobsStore store = _MemoryJobsStore();
    addTearDown(store.close);
    await _pumpPanel(
      tester,
      panel: VideoDownloadJobsPanel(
        store: store,
        onSetPriority: (VideoDownloadJobRow job, int priority) async {},
      ),
    );
    store.emit(<VideoDownloadJobRow>[
      _job(
        id: 'done',
        title: 'Finished show',
        lifecycle: VideoDownloadJobLifecycle.completed,
        progress: 1,
        completedAt: 10,
      ),
    ]);
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey<String>('video-download-job-priority-done')),
      findsNothing,
      reason: '给一个不会再被取走的任务露出「优先级」，等于骗用户能插队。',
    );
  });
}
