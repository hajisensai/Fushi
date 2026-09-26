import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/downloads/download_keep_alive_bindings.dart';
import 'package:fushi/src/platform/mobile/android_download_keep_alive.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/discovery/discovery_download_queue.dart';
import 'package:fushi_engine/media/discovery/discovery_models.dart';
import 'package:fushi_engine/media/torrent/anime_download_config.dart';
import 'package:fushi_engine/utils/misc/resumable_downloader.dart';

/// 记录 update / stop 顺序的假保活（BUG-2714）。
class _RecordingKeepAlive implements DownloadKeepAlive {
  final List<String> events = <String>[];
  final List<int?> percents = <int?>[];

  @override
  Future<void> update({
    required String title,
    required String text,
    int? percent,
  }) async {
    events.add('update:$title');
    percents.add(percent);
  }

  @override
  Future<void> stop() async {
    events.add('stop');
  }
}

DiscoveryResourceItem _item(String id) => DiscoveryResourceItem(
      sourceId: 'src',
      title: 'title-$id',
      id: id,
      kind: DiscoveryMediaKind.novel,
      payloadKind: DiscoveryPayloadKind.httpFile,
      payload: const DiscoveryHttpPayload(
        url: 'https://example.com/files/book.epub',
      ),
    );

Future<void> _waitFor(bool Function() condition) async {
  for (int i = 0; i < 500 && !condition(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  expect(condition(), isTrue);
}

VideoDownloadJobRow _job(
  String id, {
  String lifecycle = VideoDownloadJobLifecycle.active,
  String backendKind = QbConnectionConfig.backendEmbedded,
  String stage = VideoDownloadJobStage.download,
  double stageProgress = 0.4,
}) =>
    VideoDownloadJobRow(
      jobId: id,
      resourceProvider: 'nyaa:default',
      selectedResourceId: 'resource-$id',
      magnetUri: null,
      resourceTitle: null,
      torrentHash: null,
      metadataProvider: null,
      externalId: null,
      mediaKind: 'tv',
      discoveryCategory: null,
      title: 'video-$id',
      year: null,
      season: null,
      coverUrl: null,
      backendKind: backendKind,
      backendTaskId: null,
      backendProfileId: 'default',
      fingerprint: 'fp',
      category: 'fushi-video',
      targetSourceId: null,
      collectionId: null,
      organizationPolicy: 'library',
      subtitlePolicy: 'bestEffort',
      observedSavePath: null,
      targetRelativeRoot: null,
      lifecycle: lifecycle,
      stage: stage,
      stageProgress: stageProgress,
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
  group('DiscoveryDownloadKeepAliveBinding', () {
    late Directory tempDir;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('discovery_keep_alive');
    });

    tearDown(() async {
      try {
        await tempDir.delete(recursive: true);
      } catch (_) {
        // Windows 上偶发句柄未释放，不让清理失败弄红测试。
      }
    });

    DiscoveryDownloadQueue buildQueue(Completer<void> gate) =>
        DiscoveryDownloadQueue(
          resolvePayload: (DiscoveryResourceItem item) async => item.payload!,
          importer: (DiscoveryDownloadTask task, File file) async {
            await gate.future;
            return const DiscoveryImportOutcome(importedCount: 1);
          },
          openOverride: (Uri uri, Map<String, String> headers) async {
            final List<int> body = utf8.encode('bytes');
            return ResumableDownloadResponse.bytes(
              statusCode: 200,
              body: body,
              headers: <String, String>{'content-length': '${body.length}'},
            );
          },
        );

    test('入队即保活，任务结束后撤', () async {
      final Completer<void> gate = Completer<void>();
      final DiscoveryDownloadQueue queue = buildQueue(gate);
      addTearDown(queue.dispose);
      final _RecordingKeepAlive keepAlive = _RecordingKeepAlive();
      final DiscoveryDownloadKeepAliveBinding binding =
          DiscoveryDownloadKeepAliveBinding(queue, keepAlive: keepAlive);
      addTearDown(binding.dispose);

      expect(keepAlive.events, isEmpty, reason: '空队列不该挂保活');
      queue.enqueue(_item('1'), destinationDir: tempDir.path);
      expect(keepAlive.events.first, 'update:title-1');
      expect(keepAlive.events, isNot(contains('stop')));

      gate.complete();
      await _waitFor(() => queue.tasks.single.isFinished);
      expect(keepAlive.events.last, 'stop');
      expect(keepAlive.events.where((String e) => e == 'stop'), hasLength(1));
    });

    test('多个任务：标题报汇总，全部结束才撤', () async {
      final Completer<void> gate = Completer<void>();
      final DiscoveryDownloadQueue queue = buildQueue(gate);
      addTearDown(queue.dispose);
      final _RecordingKeepAlive keepAlive = _RecordingKeepAlive();
      final DiscoveryDownloadKeepAliveBinding binding =
          DiscoveryDownloadKeepAliveBinding(queue, keepAlive: keepAlive);
      addTearDown(binding.dispose);

      queue.enqueue(_item('1'), destinationDir: tempDir.path);
      queue.enqueue(_item('2'), destinationDir: tempDir.path);
      expect(keepAlive.events.last, isNot('update:title-1'));
      expect(keepAlive.events.last, isNot('update:title-2'));
      expect(keepAlive.events.last, startsWith('update:'));

      gate.complete();
      await _waitFor(
        () => queue.tasks.every((DiscoveryDownloadTask t) => t.isFinished),
      );
      expect(keepAlive.events.where((String e) => e == 'stop'), hasLength(1));
      expect(keepAlive.events.last, 'stop');
    });

    test('dispose 时有未结束任务 → 撤保活', () async {
      final Completer<void> gate = Completer<void>();
      final DiscoveryDownloadQueue queue = buildQueue(gate);
      addTearDown(queue.dispose);
      final _RecordingKeepAlive keepAlive = _RecordingKeepAlive();
      final DiscoveryDownloadKeepAliveBinding binding =
          DiscoveryDownloadKeepAliveBinding(queue, keepAlive: keepAlive);

      queue.enqueue(_item('1'), destinationDir: tempDir.path);
      binding.dispose();
      expect(keepAlive.events.last, 'stop');
      gate.complete();
    });
  });

  group('VideoDownloadJobsKeepAliveBinding', () {
    test('判据：只认 active + 内置引擎', () {
      expect(videoDownloadJobNeedsKeepAlive(_job('a')), isTrue);
      expect(
        videoDownloadJobNeedsKeepAlive(
          _job('a', stage: VideoDownloadJobStage.import),
        ),
        isTrue,
      );
      expect(
        videoDownloadJobNeedsKeepAlive(
          _job('a', backendKind: QbConnectionConfig.backendQbittorrent),
        ),
        isFalse,
        reason: '外接 qB 的字节在别的进程里下',
      );
      for (final String lifecycle in <String>[
        VideoDownloadJobLifecycle.cancelled,
        VideoDownloadJobLifecycle.completed,
        VideoDownloadJobLifecycle.failed,
        VideoDownloadJobLifecycle.needsAttention,
      ]) {
        expect(
          videoDownloadJobNeedsKeepAlive(_job('a', lifecycle: lifecycle)),
          isFalse,
          reason: lifecycle,
        );
      }
    });

    test('有活动任务即保活（带进度），全部结束后撤', () async {
      final StreamController<List<VideoDownloadJobRow>> jobs =
          StreamController<List<VideoDownloadJobRow>>();
      addTearDown(jobs.close);
      final _RecordingKeepAlive keepAlive = _RecordingKeepAlive();
      final VideoDownloadJobsKeepAliveBinding binding =
          VideoDownloadJobsKeepAliveBinding(jobs.stream, keepAlive: keepAlive);
      addTearDown(binding.dispose);

      jobs.add(<VideoDownloadJobRow>[
        _job('done', lifecycle: VideoDownloadJobLifecycle.completed),
      ]);
      await pumpEventQueue();
      expect(keepAlive.events, isEmpty);

      jobs.add(<VideoDownloadJobRow>[_job('1', stageProgress: 0.4)]);
      await pumpEventQueue();
      expect(keepAlive.events, <String>['update:video-1']);
      expect(keepAlive.percents.last, 40);

      jobs.add(<VideoDownloadJobRow>[
        _job('1', lifecycle: VideoDownloadJobLifecycle.completed),
      ]);
      await pumpEventQueue();
      expect(keepAlive.events.last, 'stop');
    });

    test('只有外接 qB 任务 → 不保活', () async {
      final StreamController<List<VideoDownloadJobRow>> jobs =
          StreamController<List<VideoDownloadJobRow>>();
      addTearDown(jobs.close);
      final _RecordingKeepAlive keepAlive = _RecordingKeepAlive();
      final VideoDownloadJobsKeepAliveBinding binding =
          VideoDownloadJobsKeepAliveBinding(jobs.stream, keepAlive: keepAlive);
      addTearDown(binding.dispose);

      jobs.add(<VideoDownloadJobRow>[
        _job('1', backendKind: QbConnectionConfig.backendQbittorrent),
      ]);
      await pumpEventQueue();
      expect(keepAlive.events, isEmpty);
    });

    test('dispose 时仍有活动任务 → 撤保活', () async {
      final StreamController<List<VideoDownloadJobRow>> jobs =
          StreamController<List<VideoDownloadJobRow>>();
      addTearDown(jobs.close);
      final _RecordingKeepAlive keepAlive = _RecordingKeepAlive();
      final VideoDownloadJobsKeepAliveBinding binding =
          VideoDownloadJobsKeepAliveBinding(jobs.stream, keepAlive: keepAlive);

      jobs.add(<VideoDownloadJobRow>[_job('1'), _job('2')]);
      await pumpEventQueue();
      expect(keepAlive.events.single, startsWith('update:'));
      expect(keepAlive.percents.single, isNull, reason: '多任务不报单一进度');

      await binding.dispose();
      expect(keepAlive.events.last, 'stop');
    });
  });
}
