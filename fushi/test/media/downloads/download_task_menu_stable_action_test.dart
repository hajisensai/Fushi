import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/pages/implementations/video_download_jobs_panel.dart';
import 'package:fushi_core/fushi_core.dart';

// HBK-AUDIT-036 / BUG-2993：下载任务「⋯」菜单弹出后任务状态实时刷新，菜单必须按
// 稳定动作 id 派发、并在派发时按当前能力重新校验——旧下标绝不能映射到新动作。
final class _Jobs implements VideoDownloadJobsPanelStore {
  final StreamController<List<VideoDownloadJobRow>> updates =
      StreamController<List<VideoDownloadJobRow>>.broadcast();

  @override
  Stream<List<VideoDownloadJobRow>> watchJobs() => updates.stream;
}

VideoDownloadJobRow _job(String lifecycle) => VideoDownloadJobRow(
  jobId: 'audio',
  resourceProvider: 'nyaa:default',
  selectedResourceId: 'resource-audio',
  magnetUri: null,
  resourceTitle: 'Review audiobook',
  torrentHash: null,
  metadataProvider: 'anilist',
  externalId: 'audio',
  mediaKind: 'audiobook',
  discoveryCategory: 'audiobook',
  title: 'Review audiobook',
  year: 2026,
  season: 1,
  coverUrl: null,
  backendKind: 'embedded',
  backendTaskId: null,
  backendProfileId: 'default',
  fingerprint: 'review-only',
  category: 'fushi-audio',
  targetSourceId: null,
  collectionId: null,
  organizationPolicy: 'download-only-audiobook',
  subtitlePolicy: 'bestEffort',
  observedSavePath: null,
  targetRelativeRoot: null,
  lifecycle: lifecycle,
  stage: VideoDownloadJobStage.download,
  stageProgress: lifecycle == VideoDownloadJobLifecycle.completed ? 1 : 0.4,
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

void main() {
  setUp(() => LocaleSettings.setLocale(AppLocale.en));

  Future<_Jobs> pumpPanel(
    WidgetTester tester, {
    required void Function() onPair,
    required void Function() onDelete,
  }) async {
    final _Jobs jobs = _Jobs();
    addTearDown(jobs.updates.close);
    tester.view.physicalSize = const Size(1100, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(
          theme: ThemeData(
            useMaterial3: true,
            splashFactory: NoSplash.splashFactory,
          ),
          builder: (BuildContext context, Widget? child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(disableAnimations: true),
            child: child!,
          ),
          home: Scaffold(
            body: VideoDownloadJobsPanel(
              store: jobs,
              unified: true,
              onPairAudiobook: (VideoDownloadJobRow _) async => onPair(),
              onDelete:
                  (VideoDownloadJobRow _, {required bool deleteFiles}) async =>
                      onDelete(),
            ),
          ),
        ),
      ),
    );
    return jobs;
  }

  testWidgets('stale Delete stays Delete after the job completes', (
    WidgetTester tester,
  ) async {
    int pairCalls = 0;
    int deleteCalls = 0;
    final _Jobs jobs = await pumpPanel(
      tester,
      onPair: () => pairCalls++,
      onDelete: () => deleteCalls++,
    );
    jobs.updates.add(<VideoDownloadJobRow>[
      _job(VideoDownloadJobLifecycle.active),
    ]);
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey<String>('download-task-menu-audio')),
    );
    await tester.pumpAndSettle();
    expect(find.text(t.download_task_audiobook_pair), findsNothing);
    expect(find.text(t.download_task_delete), findsOneWidget);

    // 菜单还开着时任务完成：动作表多出「补对齐」并插在「删除」前面。
    jobs.updates.add(<VideoDownloadJobRow>[
      _job(VideoDownloadJobLifecycle.completed),
    ]);
    await tester.pumpAndSettle();
    await tester.tap(find.text(t.download_task_delete));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(pairCalls, 0, reason: 'Delete must never become Pair audiobook.');
    expect(deleteCalls, 0, reason: 'Deletion must go through its confirm.');
    expect(
      find.byKey(
        const ValueKey<String>('video-download-job-delete-confirm-audio'),
      ),
      findsOneWidget,
    );
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('stale Pair is dropped once the capability disappears', (
    WidgetTester tester,
  ) async {
    int pairCalls = 0;
    int deleteCalls = 0;
    final _Jobs jobs = await pumpPanel(
      tester,
      onPair: () => pairCalls++,
      onDelete: () => deleteCalls++,
    );
    jobs.updates.add(<VideoDownloadJobRow>[
      _job(VideoDownloadJobLifecycle.completed),
    ]);
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey<String>('download-task-menu-audio')),
    );
    await tester.pumpAndSettle();
    expect(find.text(t.download_task_audiobook_pair), findsOneWidget);

    // 菜单还开着时任务回到进行中：「补对齐」能力消失。
    jobs.updates.add(<VideoDownloadJobRow>[
      _job(VideoDownloadJobLifecycle.active),
    ]);
    await tester.pumpAndSettle();
    await tester.tap(find.text(t.download_task_audiobook_pair));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(pairCalls, 0);
    expect(deleteCalls, 0);
    expect(
      find.byKey(
        const ValueKey<String>('video-download-job-delete-confirm-audio'),
      ),
      findsNothing,
    );
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
