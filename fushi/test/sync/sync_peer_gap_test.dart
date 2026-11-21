/// 互联对端版本过旧时，被跳过 / 降级的同步维度统一在同步报告里报出（拍板
/// other-sync-peer-version-errors）。
///
/// 钉住：
/// 1. 能力位三态（supported / declaredOff / undeclared）的解析；
/// 2. [SyncRunReport.notePeerGap] 每轮每维度至多一条、日志行与类型并存、跨通道合并不重复；
/// 3. 真·旧 host（连 `/api/capabilities` 都没有、各端点 404）上，标签 / 作品图谱 / 视频
///    刮削元数据 / 删除墓碑 / 视频删除逐维度各记一条「版本过旧」，再跑一遍不重复；
/// 4. 现版本 host 只是没接这些实现（能力位在、为 false）时不叫用户去升级；
/// 5. 手动同步摘要在有「版本过旧」时直说要升级对端。
library;

import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/sync/interconnect_sync_backend.dart';
import 'package:fushi/src/sync/sync_backend.dart';
import 'package:fushi/src/sync/sync_orchestrator.dart';
import 'package:fushi/src/sync/sync_repository.dart';
import 'package:fushi/src/sync/sync_settings_schema.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/sync/fushi_library_host_service.dart';
import 'package:fushi_engine/sync/fushi_sync_server.dart';
import 'package:path/path.dart' as p;

FushiDatabase _memDb() =>
    FushiDatabase.forTesting(DatabaseConnection(NativeDatabase.memory()));

/// 现版本 server 上跑着一个只实现主接口的库服务：能力位都在，但 tags / mediaLinks /
/// videoMetadata / deletionTombstones / videoDeletion 全是 false，对应端点 404。
class _HostWithoutOptionalServices implements FushiLibraryHostService {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName} not needed here');
}

Future<InterconnectSyncBackend> _client(String base) async {
  final FushiDatabase db = _memDb();
  addTearDown(db.close);
  final SyncRepository repo = SyncRepository(db);
  await repo.setFushiClientUrls(<FushiClientUrl>[
    FushiClientUrl(url: base, enabled: true),
  ]);
  await repo.setFushiClientToken('tok');
  final InterconnectSyncBackend backend = InterconnectSyncBackend.withProbe(
    (String u, String t) async => true,
  );
  await backend.restoreAuth(repo);
  await backend.authenticate(repo: repo);
  return backend;
}

SyncOrchestrator _orchestrator(FushiDatabase db, SyncBackend backend) =>
    SyncOrchestrator(
      db: db,
      backend: backend,
      dictionaryResourceRoot: Directory.systemTemp,
      audioDatabaseRoot: Directory.systemTemp,
      tempDir: Directory.systemTemp,
      syncStats: false,
      syncAudioBookPosition: false,
      syncContent: false,
      syncMangaContent: false,
      syncAudioBookFiles: false,
      syncVideoFiles: false,
      syncDictionary: false,
    );

/// 跑一遍会撞到「对端缺能力」的几个 live 维度（含一条待推的视频删除墓碑）。
Future<void> _runGapDimensions(
  SyncOrchestrator orch,
  SyncRunReport report,
  InterconnectSyncBackend backend,
) async {
  await orch.syncTagsLiveForTest(report, backend);
  await orch.syncMediaLinksLiveForTest(report, backend);
  await orch.syncVideoMetadataLiveForTest(report, backend);
  await orch.syncDeletionTombstonesLiveForTest(report, backend);
}

void main() {
  group('liveLibraryCapabilityState', () {
    test(
      'true → supported；键在非 true → declaredOff；缺键 / 缺段 / 非表 → undeclared',
      () {
        const String k = 'tags';
        expect(
          liveLibraryCapabilityState(<String, Object?>{
            'liveLibrary': <String, Object?>{k: true},
          }, k),
          LiveLibraryCapabilityState.supported,
        );
        expect(
          liveLibraryCapabilityState(<String, Object?>{
            'liveLibrary': <String, Object?>{k: false},
          }, k),
          LiveLibraryCapabilityState.declaredOff,
        );
        expect(
          liveLibraryCapabilityState(<String, Object?>{
            'liveLibrary': <String, Object?>{'other': true},
          }, k),
          LiveLibraryCapabilityState.undeclared,
        );
        expect(
          liveLibraryCapabilityState(<String, Object?>{'tls': true}, k),
          LiveLibraryCapabilityState.undeclared,
        );
        expect(
          liveLibraryCapabilityState(null, k),
          LiveLibraryCapabilityState.undeclared,
        );
      },
    );
  });

  group('SyncRunReport.notePeerGap', () {
    test('每维度至多一条；日志行与类型并存；mergeFrom 不重复类型', () {
      final List<String> observed = <String>[];
      final SyncRunReport r = SyncRunReport(onError: observed.add)
        ..notePeerGap(SyncPeerGapDimension.tags, outdated: true)
        ..notePeerGap(SyncPeerGapDimension.tags, outdated: true)
        ..notePeerGap(SyncPeerGapDimension.pdfBooks, outdated: false);
      expect(r.peerGaps.map((SyncPeerGap g) => g.dimension), <Object>[
        SyncPeerGapDimension.tags,
        SyncPeerGapDimension.pdfBooks,
      ]);
      expect(r.errors, hasLength(2));
      expect(observed, r.errors, reason: '同步任务面板实时收到同样的行');
      expect(r.errors.first, startsWith('tags live sync: '));
      expect(r.errors.first, contains('older Fushi'));
      expect(r.errors.first, contains('Update Fushi on the peer'));
      expect(r.errors.last, isNot(contains('Update Fushi')));

      final SyncRunReport other = SyncRunReport()
        ..notePeerGap(SyncPeerGapDimension.tags, outdated: true)
        ..notePeerGap(SyncPeerGapDimension.videoMetadata, outdated: true);
      r.mergeFrom(other);
      expect(r.peerGaps.map((SyncPeerGap g) => g.dimension), <Object>[
        SyncPeerGapDimension.tags,
        SyncPeerGapDimension.pdfBooks,
        SyncPeerGapDimension.videoMetadata,
      ]);
    });
  });

  group('真·旧 host（无能力端点、各端点 404）', () {
    late HttpServer old;
    late InterconnectSyncBackend backend;

    setUp(() async {
      old = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      old.listen((HttpRequest req) async {
        await req.drain<void>();
        req.response.statusCode = HttpStatus.notFound;
        await req.response.close();
      });
      backend = await _client('http://127.0.0.1:${old.port}');
    });

    tearDown(() => old.close(force: true));

    test('每个被跳过的维度各记一条「版本过旧」，再跑一轮同一报告不重复', () async {
      final FushiDatabase db = _memDb();
      addTearDown(db.close);
      await db.writeSyncDeletionTombstone(
        SyncTombstoneKind.video.dbValue,
        'video/mine',
        DateTime.now().millisecondsSinceEpoch - 1000,
      );
      final SyncOrchestrator orch = _orchestrator(db, backend);
      final SyncRunReport report = SyncRunReport();

      await _runGapDimensions(orch, report, backend);
      await _runGapDimensions(orch, report, backend);

      expect(
        report.peerGaps.map((SyncPeerGap g) => g.dimension).toSet(),
        <SyncPeerGapDimension>{
          SyncPeerGapDimension.tags,
          SyncPeerGapDimension.mediaLinks,
          SyncPeerGapDimension.videoMetadata,
          SyncPeerGapDimension.videoDeletion,
          SyncPeerGapDimension.deletionTombstones,
        },
        reason: '${report.errors}',
      );
      expect(report.peerGaps, hasLength(5), reason: '每维度至多一条');
      expect(report.peerGaps.every((SyncPeerGap g) => g.outdated), isTrue);
      expect(
        report.errors.where((String e) => e.contains('older Fushi')),
        hasLength(5),
        reason: '${report.errors}',
      );
    });

    test('手动同步摘要直说要升级对端', () async {
      final SyncRunReport report = SyncRunReport();
      await _orchestrator(
        _memDb(),
        backend,
      ).syncTagsLiveForTest(report, backend);
      await LocaleSettings.setLocale(AppLocale.en);
      final String s = summarizeSyncReport(report);
      expect(s, contains(t.sync_now_peer_outdated(count: 1)));
    });
  });

  test('现版本 host 只是没接这些实现（能力位为 false）：不叫用户升级', () async {
    final Directory work = Directory.systemTemp.createTempSync('peer_gap_');
    addTearDown(() => work.deleteSync(recursive: true));
    final FushiSyncServer server = FushiSyncServer(
      syncDataDir: p.join(work.path, 'server_data'),
      port: 0,
      token: 'tok',
      allowLan: false,
      libraryService: _HostWithoutOptionalServices(),
    );
    await server.start();
    addTearDown(server.stop);
    final InterconnectSyncBackend backend = await _client(
      'http://127.0.0.1:${server.port}',
    );
    final FushiDatabase db = _memDb();
    addTearDown(db.close);
    await db.writeSyncDeletionTombstone(
      SyncTombstoneKind.video.dbValue,
      'video/mine',
      DateTime.now().millisecondsSinceEpoch - 1000,
    );
    final SyncRunReport report = SyncRunReport();

    await _runGapDimensions(_orchestrator(db, backend), report, backend);

    // 视频删除是用户的操作落空，照样要说（但说「不支持」，不说「升级」）；其余维度
    // host 主动不提供，静默。
    expect(
      report.peerGaps.map((SyncPeerGap g) => (g.dimension, g.outdated)),
      <(SyncPeerGapDimension, bool)>[
        (SyncPeerGapDimension.videoDeletion, false),
      ],
      reason: '${report.errors}',
    );
    expect(report.errors, <String>[report.peerGaps.single.message]);
  });
}
