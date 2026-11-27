/// 反馈 L60rttoC0U 守卫：互联对端在一轮同步中途探不到时，
///
/// ① 编排器不得把 [SyncPeerUnreachableError] 逐维度吞成报告行（修复前每个维度各把
///    全部候选串行探一遍、各记一条同样的 `No reachable Fushi server address`，任务
///    面板「全量同步 7 项失败」），而要原样抛出本轮，交给通道层按 BUG-5368 处理；
/// ② 任务面板按结构渲染失败：原因本地化、互联维度名本地化、同因合成一行，不再把
///    `tags live sync: SyncBackendError: …` 这种日志行原样上屏。
library;

import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/sync/background_tasks_indicator.dart';
import 'package:fushi/src/sync/interconnect_sync_backend.dart';
import 'package:fushi/src/sync/sync_activity.dart';
import 'package:fushi/src/sync/sync_backend.dart';
import 'package:fushi/src/sync/sync_failure_ui.dart';
import 'package:fushi/src/sync/sync_orchestrator.dart';
import 'package:fushi/src/sync/sync_repository.dart';
import 'package:fushi/src/sync/sync_task_board.dart';
import 'package:fushi_core/fushi_core.dart';

FushiDatabase _memDb() =>
    FushiDatabase.forTesting(DatabaseConnection(NativeDatabase.memory()));

/// 配了一条地址 + token、但探测永远不通的互联后端（= 对端离线）。
Future<InterconnectSyncBackend> _offlineBackend(FushiDatabase db) async {
  final SyncRepository repo = SyncRepository(db);
  await repo.setFushiClientUrls(<FushiClientUrl>[
    const FushiClientUrl(url: 'http://127.0.0.1:9', enabled: true),
  ]);
  await repo.setFushiClientToken('peer-offline-token');
  final InterconnectSyncBackend backend = InterconnectSyncBackend.withProbe(
    (String u, String t) async => false,
  );
  expect(await backend.restoreAuth(repo), isTrue);
  return backend;
}

void main() {
  group('编排器：对端中途离线是通道级事实', () {
    late FushiDatabase db;
    late Directory work;
    late InterconnectSyncBackend backend;
    late SyncOrchestrator orchestrator;

    setUp(() async {
      db = _memDb();
      work = await Directory.systemTemp.createTemp('l60rttoc0u_');
      backend = await _offlineBackend(db);
      orchestrator = SyncOrchestrator(
        db: db,
        backend: backend,
        dictionaryResourceRoot: work,
        audioDatabaseRoot: work,
        tempDir: work,
        syncStats: true,
        syncAudioBookPosition: false,
        syncContent: false,
        syncMangaContent: false,
        syncAudioBookFiles: false,
        syncDictionary: false,
      );
    });

    tearDown(() async {
      await db.close();
      if (work.existsSync()) await work.delete(recursive: true);
    });

    final Map<
      String,
      Future<void> Function(
        SyncOrchestrator,
        SyncRunReport,
        InterconnectSyncBackend,
      )
    >
    dims =
        <
          String,
          Future<void> Function(
            SyncOrchestrator,
            SyncRunReport,
            InterconnectSyncBackend,
          )
        >{
          'aggregate':
              (
                SyncOrchestrator o,
                SyncRunReport r,
                InterconnectSyncBackend b,
              ) => o.syncAggregateLiveForTest(r, b),
          'collections':
              (
                SyncOrchestrator o,
                SyncRunReport r,
                InterconnectSyncBackend b,
              ) => o.syncCollectionsLiveForTest(r, b),
          'tags':
              (
                SyncOrchestrator o,
                SyncRunReport r,
                InterconnectSyncBackend b,
              ) => o.syncTagsLiveForTest(r, b),
          'media links':
              (
                SyncOrchestrator o,
                SyncRunReport r,
                InterconnectSyncBackend b,
              ) => o.syncMediaLinksLiveForTest(r, b),
          'video metadata':
              (
                SyncOrchestrator o,
                SyncRunReport r,
                InterconnectSyncBackend b,
              ) => o.syncVideoMetadataLiveForTest(r, b),
          'online library':
              (
                SyncOrchestrator o,
                SyncRunReport r,
                InterconnectSyncBackend b,
              ) => o.syncOnlineLibraryLiveForTest(r, b),
          'deletion tombstones':
              (
                SyncOrchestrator o,
                SyncRunReport r,
                InterconnectSyncBackend b,
              ) => o.syncDeletionTombstonesLiveForTest(r, b),
        };

    for (final MapEntry<
          String,
          Future<void> Function(
            SyncOrchestrator,
            SyncRunReport,
            InterconnectSyncBackend,
          )
        >
        dim
        in dims.entries) {
      test('${dim.key} live sync：对端探不到 → 抛出本轮，不吞成报告行', () async {
        final List<SyncFailure> seen = <SyncFailure>[];
        final SyncRunReport report = SyncRunReport(onError: seen.add);
        await expectLater(
          dim.value(orchestrator, report, backend),
          throwsA(isA<SyncPeerUnreachableError>()),
          reason:
              '修复前：吞成「${dim.key} live sync: SyncBackendError: No reachable …」',
        );
        expect(report.errors, isEmpty);
        expect(seen, isEmpty);
      });
    }
  });

  group('报告：失败带结构', () {
    test('noteError 的维度与原因随回调与 failures 一起留下，日志行一字不变', () {
      final List<SyncFailure> seen = <SyncFailure>[];
      final SyncRunReport report = SyncRunReport(onError: seen.add);
      final Exception boom = Exception('boom');
      report.noteError('tags live sync', boom);
      report.errors.add('books: raw');
      expect(report.errors, <String>[
        'tags live sync: Exception: boom',
        'books: raw',
      ]);
      expect(seen.first.label, 'tags live sync');
      expect(seen.first.cause, same(boom));
      expect(seen.last.cause, isNull);
      expect(report.failures, seen);

      final SyncRunReport merged = SyncRunReport()..mergeFrom(report);
      expect(merged.errors, report.errors);
      expect(merged.failures.first.cause, same(boom), reason: '合并不丢结构');
    });
  });

  group('任务面板：本地化 + 同因合并', () {
    setUp(resetSyncTasksForTest);
    tearDown(resetSyncTasksForTest);

    test('7 个维度同一原因 → 一行本地化原因带条数，「N 项失败」仍按项计', () {
      final SyncTaskHandle sweep = beginSyncTask(SyncActivityKind.fullSweep);
      for (final String label in <String>[
        'aggregate live sync',
        'online library live sync',
        'collections live sync',
        'tags live sync',
        'media links live sync',
        'video metadata live sync',
        'deletion tombstones live sync',
      ]) {
        sweep.fail(SyncFailure.of(label, const SocketException('reset')));
      }
      sweep.finish();
      final BackgroundTask task = syncBackgroundTasks().single;
      expect(task.errors, <String>[
        t.sync_task_errors_same_reason(reason: t.sync_err_network, count: 7),
      ]);
      expect(task.failureCount, 7);
      for (final String line in task.errors) {
        expect(line, isNot(contains('SocketException')));
        expect(line, isNot(contains('live sync')));
      }
    });

    test('单条：互联维度名本地化 + 友好原因；未知维度保留标签；原文行原样', () {
      final List<String> lines = syncFailureLines(<SyncFailure>[
        SyncFailure.of('tags live sync', SyncPeerUnreachableError()),
        SyncFailure.of('aggregate live sync', const SocketException('x')),
        const SyncFailure.raw('books: raw'),
      ]);
      expect(lines, <String>[
        '${t.sync_peer_gap_dim_tags}: ${t.sync_err_peer_unreachable}',
        'aggregate live sync: ${t.sync_err_network}',
        'books: raw',
      ]);
    });
  });
}
