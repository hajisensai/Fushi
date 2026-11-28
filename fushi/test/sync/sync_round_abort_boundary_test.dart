/// BUG-5614 守卫：编排器各维度的 catch-all 不得把「本轮同步的事实」吞成维度错误。
///
/// 修复前 `_noteDimensionError` 只放行 [SyncPeerUnreachableError]，标签 / 作品图谱
/// 等维度的裸 `catch (e)` 把 [SyncCancelledException]（模块被关掉）与凭据类
/// [SyncAuthError]（401 / 配对被拒）记成一条报告行后接着跑后续阶段：取消形同虚设，
/// 401 也到不了手动同步的登出 / 重新配对分支。错误边界现在只在
/// [syncErrorAbortsRound] 判一次。
library;

import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/sync/interconnect_sync_backend.dart';
import 'package:fushi/src/sync/sync_backend.dart';
import 'package:fushi/src/sync/sync_module_gate.dart';
import 'package:fushi/src/sync/sync_orchestrator.dart';
import 'package:fushi/src/sync/sync_progress.dart';
import 'package:fushi/src/sync/sync_repository.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/sync/media_link_sync.dart';
import 'package:fushi_engine/sync/tag_sync.dart';

import 'fake_asset_store.dart';
import 'sync_orchestrator_test.dart' show FakeSyncBackend;

FushiDatabase _memDb() =>
    FushiDatabase.forTesting(DatabaseConnection(NativeDatabase.memory()));

/// 标签 / 作品图谱端点一调就抛 [error] 的互联后端（其余端点不该被碰到）。
class _ThrowingInterconnect extends InterconnectSyncBackend {
  _ThrowingInterconnect(this.error)
    : super.withProbe((String u, String t) async => true);

  final Exception error;

  @override
  Future<TagManifest?> getRemoteTagManifest() async => throw error;

  @override
  Future<MediaLinkManifest?> getRemoteMediaLinkManifest() async => throw error;
}

/// 云后端：合集命名空间（合集 + 作品图谱云阶段的第一次后端触点）一碰就抛 [error]。
class _CollectionsThrowingBackend extends FakeSyncBackend {
  _CollectionsThrowingBackend(super.store, this.error);

  final Exception error;

  @override
  Future<String> ensureNamespace(String name) {
    if (name == kSyncCollectionsNamespace) throw error;
    return super.ensureNamespace(name);
  }
}

SyncOrchestrator _orchestrator(
  FushiDatabase db,
  SyncBackend backend,
  Directory root, {
  void Function(SyncProgress)? onProgress,
}) => SyncOrchestrator(
  db: db,
  backend: backend,
  dictionaryResourceRoot: root,
  audioDatabaseRoot: root,
  tempDir: root,
  deviceId: 'device-a',
  syncStats: false,
  syncAudioBookPosition: false,
  syncContent: false,
  syncMangaContent: false,
  syncAudioBookFiles: false,
  syncDictionary: false,
  onProgress: onProgress,
);

typedef _LiveDimension =
    Future<void> Function(
      SyncOrchestrator orchestrator,
      SyncRunReport report,
      InterconnectSyncBackend backend,
    );

void main() {
  group('syncErrorAbortsRound：错误边界的唯一判据', () {
    test('取消 / 对端离线 / 凭据类鉴权失败中止整轮', () {
      expect(syncErrorAbortsRound(const SyncCancelledException()), isTrue);
      expect(syncErrorAbortsRound(SyncPeerUnreachableError()), isTrue);
      for (final SyncAuthFailureKind kind in <SyncAuthFailureKind>[
        SyncAuthFailureKind.credentials,
        SyncAuthFailureKind.pairingRejected,
        SyncAuthFailureKind.pairingNotConfigured,
        SyncAuthFailureKind.browserTimeout,
        SyncAuthFailureKind.cancelled,
      ]) {
        expect(
          syncErrorAbortsRound(SyncAuthError('x', kind: kind)),
          isTrue,
          reason: '$kind',
        );
      }
    });

    test('403 一族与普通故障只属于那一个维度', () {
      for (final SyncAuthFailureKind kind in <SyncAuthFailureKind>[
        SyncAuthFailureKind.forbidden,
        SyncAuthFailureKind.htmlPage,
      ]) {
        expect(
          syncErrorAbortsRound(SyncAuthError('x', kind: kind)),
          isFalse,
          reason: '$kind',
        );
      }
      expect(syncErrorAbortsRound(SyncBackendError('boom')), isFalse);
      expect(syncErrorAbortsRound(const FormatException('bad')), isFalse);
      expect(syncErrorAbortsRound(StateError('bad')), isFalse);
    });
  });

  group('互联维度：标签 / 作品图谱', () {
    late FushiDatabase db;
    late Directory work;

    setUp(() async {
      db = _memDb();
      work = await Directory.systemTemp.createTemp('bug5614_live_');
    });

    tearDown(() async {
      await db.close();
      if (work.existsSync()) await work.delete(recursive: true);
    });

    final Map<String, _LiveDimension> dims = <String, _LiveDimension>{
      'tags':
          (SyncOrchestrator o, SyncRunReport r, InterconnectSyncBackend b) =>
              o.syncTagsLiveForTest(r, b),
      'media links':
          (SyncOrchestrator o, SyncRunReport r, InterconnectSyncBackend b) =>
              o.syncMediaLinksLiveForTest(r, b),
    };

    final Map<String, Exception> aborting = <String, Exception>{
      'cancelled': const SyncCancelledException(),
      'credentials 401': SyncAuthError('Authentication failed'),
      'pairing rejected': SyncAuthError(
        'rejected',
        kind: SyncAuthFailureKind.pairingRejected,
      ),
    };

    for (final MapEntry<String, _LiveDimension> dim in dims.entries) {
      for (final MapEntry<String, Exception> err in aborting.entries) {
        test('${dim.key}：${err.key} 冲出本维度，不记成报告行', () async {
          final _ThrowingInterconnect backend = _ThrowingInterconnect(
            err.value,
          );
          final SyncRunReport report = SyncRunReport();
          await expectLater(
            dim.value(_orchestrator(db, backend, work), report, backend),
            throwsA(same(err.value)),
          );
          expect(report.errors, isEmpty);
          expect(report.authFailures, isEmpty);
        });
      }

      test('${dim.key}：403 只记这一维度，带类型进 authFailures', () async {
        final _ThrowingInterconnect backend = _ThrowingInterconnect(
          SyncAuthError(
            'Server refused (403)',
            kind: SyncAuthFailureKind.forbidden,
            serverReason: 'HTTPS required',
          ),
        );
        final SyncRunReport report = SyncRunReport();
        await dim.value(_orchestrator(db, backend, work), report, backend);
        expect(report.errors, hasLength(1));
        expect(report.authFailures.single.kind, SyncAuthFailureKind.forbidden);
      });
    }
  });

  group('整轮 run()：合集 / 作品图谱阶段抛出', () {
    late FushiDatabase db;
    late Directory work;

    setUp(() async {
      db = _memDb();
      work = await Directory.systemTemp.createTemp('bug5614_run_');
    });

    tearDown(() async {
      await db.close();
      if (work.existsSync()) await work.delete(recursive: true);
    });

    final Map<String, Exception> aborting = <String, Exception>{
      'cancelled': const SyncCancelledException(),
      'credentials 401': SyncAuthError('Authentication expired'),
    };

    for (final MapEntry<String, Exception> err in aborting.entries) {
      test('${err.key}：整轮中止并向上抛，后续阶段不跑、冷却戳不写', () async {
        final List<SyncPhase> phases = <SyncPhase>[];
        await expectLater(
          _orchestrator(
            db,
            _CollectionsThrowingBackend(FakeAssetStore(), err.value),
            work,
            onProgress: (SyncProgress p) => phases.add(p.phase),
          ).run(),
          throwsA(same(err.value)),
        );
        expect(phases, contains(SyncPhase.collections));
        expect(
          phases,
          isNot(contains(SyncPhase.deletions)),
          reason: '中止后不得再进入下一阶段',
        );
        expect(
          await SyncRepository(db).getLastSyncMs(SyncChannelScope.unscoped),
          isNull,
          reason: '没跑完的一轮不得写冷却戳',
        );
      });
    }

    test('普通故障：记进报告，流水线照常跑完', () async {
      final List<SyncPhase> phases = <SyncPhase>[];
      final SyncRunReport report = await _orchestrator(
        db,
        _CollectionsThrowingBackend(FakeAssetStore(), SyncBackendError('boom')),
        work,
        onProgress: (SyncProgress p) => phases.add(p.phase),
      ).run();
      expect(report.errors.where((String e) => e.contains('boom')), isNotEmpty);
      expect(phases, contains(SyncPhase.deletions));
    });
  });
}
