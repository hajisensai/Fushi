/// 互联对端版本过旧时，被跳过 / 降级的同步维度统一在同步报告里报出（拍板
/// other-sync-peer-version-errors）。
///
/// 钉住：
/// 1. 能力位三态（supported / declaredOff / undeclared）的解析；
/// 2. [SyncRunReport.notePeerGap] 每轮每维度至多一条、日志行与类型并存、跨通道合并不重复；
/// 3. 真·旧 host（连 `/api/capabilities` 都没有、各端点 404）上，标签 / 作品图谱 / 视频
///    刮削元数据 / 删除墓碑 / 视频删除逐维度各记一条「版本过旧」，再跑一遍不重复；
/// 4. 现版本 host 只是没接这些实现（能力位在、为 false）时不叫用户去升级；
/// 5. 手动同步摘要在有「版本过旧」时直说要升级对端；降级同步的维度不说成没同步；
/// 6. 能力表每轮至多读一次、各维度复用（读失败也复用，逐条墓碑不重复记错），明文
///    会话上的服务配置连能力表都不问（BUG-5101）。
library;

import 'dart:io';

import 'package:drift/drift.dart' show DatabaseConnection;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/sync/interconnect_sync_backend.dart';
import 'package:fushi/src/sync/sync_backend.dart';
import 'package:fushi/src/sync/sync_orchestrator.dart';
import 'package:fushi/src/sync/sync_peer_gap_ui.dart';
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
    final List<String> paths = <String>[];
    int capabilityReads() =>
        paths.where((String p) => p == '/api/capabilities').length;

    setUp(() async {
      paths.clear();
      old = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      old.listen((HttpRequest req) async {
        paths.add(req.uri.path);
        await req.drain<void>();
        req.response.statusCode = HttpStatus.notFound;
        await req.response.close();
      });
      backend = await _client('http://127.0.0.1:${old.port}');
      paths.clear();
    });

    test('能力表每轮至多读一次、各维度复用；新一轮重新读（不跨轮缓存）', () async {
      final FushiDatabase db = _memDb();
      addTearDown(db.close);
      final DateTime now = DateTime.now();
      for (final String id in <String>['video/a', 'video/b', 'video/c']) {
        await db.writeSyncDeletionTombstone(
          SyncTombstoneKind.video.dbValue,
          id,
          now.millisecondsSinceEpoch - 1000,
        );
      }
      final SyncOrchestrator orch = _orchestrator(db, backend);

      final SyncRunReport first = SyncRunReport();
      await _runGapDimensions(orch, first, backend);
      expect(first.peerGaps, hasLength(5), reason: '${first.errors}');
      expect(
        capabilityReads(),
        1,
        reason: '五个维度 + 三条视频删除各自走不通，整轮只该问一次能力表：$paths',
      );

      final SyncRunReport second = SyncRunReport();
      await orch.syncTagsLiveForTest(second, backend);
      expect(second.hasPeerGap(SyncPeerGapDimension.tags), isTrue);
      expect(capabilityReads(), 2, reason: 'host 可能换版本，下一轮必须重新读');
    });

    test('明文会话上服务配置本地已知不给：不发请求、不问能力表、不记', () async {
      final FushiDatabase db = _memDb();
      addTearDown(db.close);
      final SyncRunReport report = SyncRunReport();

      await _orchestrator(
        db,
        backend,
      ).syncServiceConfigLiveForTest(report, backend);

      expect(paths, isEmpty, reason: '存量默认就是明文，正常轮次不能为它多发请求');
      expect(report.peerGaps, isEmpty);
      expect(report.errors, isEmpty);
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
      final String s = summarizeSyncReport(report);
      expect(s, contains(t.sync_now_peer_outdated(count: 1)));
    });
  });

  test('能力表读失败：逐条墓碑推送也只读一次、每维度只记一条错误', () async {
    final List<String> paths = <String>[];
    final HttpServer host = await HttpServer.bind(
      InternetAddress.loopbackIPv4,
      0,
    );
    addTearDown(() => host.close(force: true));
    host.listen((HttpRequest req) async {
      paths.add(req.uri.path);
      await req.drain<void>();
      req.response.statusCode = req.uri.path == '/api/capabilities'
          ? HttpStatus.internalServerError
          : HttpStatus.notFound;
      await req.response.close();
    });
    final InterconnectSyncBackend backend = await _client(
      'http://127.0.0.1:${host.port}',
    );
    final FushiDatabase db = _memDb();
    addTearDown(db.close);
    final int at = DateTime.now().millisecondsSinceEpoch - 1000;
    for (final String id in <String>['video/a', 'video/b', 'video/c']) {
      await db.writeSyncDeletionTombstone(
        SyncTombstoneKind.video.dbValue,
        id,
        at,
      );
    }
    paths.clear();
    final SyncRunReport report = SyncRunReport();

    await _orchestrator(
      db,
      backend,
    ).syncDeletionTombstonesLiveForTest(report, backend);

    expect(
      paths.where((String p) => p.startsWith('/api/library/videos/')),
      hasLength(3),
      reason: '三条视频删除都真推了：$paths',
    );
    expect(
      paths.where((String p) => p == '/api/capabilities'),
      hasLength(1),
      reason: '读失败也复用同一次读取，不逐条重发：$paths',
    );
    expect(
      report.errors.where(
        (String e) => e.startsWith(
          '${SyncPeerGapDimension.videoDeletion.label}: peer capabilities '
          'unreadable',
        ),
      ),
      hasLength(1),
      reason: '${report.errors}',
    );
    expect(report.peerGaps, isEmpty, reason: '读不到能力表就不猜版本');
  });

  group('手动同步摘要：降级同步不说成没同步', () {
    test('只有降级维度 → 「只能降级同步」', () {
      final SyncRunReport r = SyncRunReport()
        ..notePeerGap(SyncPeerGapDimension.localAudioIdentity, outdated: true);
      final String s = summarizeSyncReport(r);
      expect(s, contains(t.sync_now_peer_outdated_degraded(count: 1)));
      expect(s, isNot(contains(t.sync_now_peer_outdated(count: 1))));
    });

    test('没同步与降级并存 → 分开数', () {
      final SyncRunReport r = SyncRunReport()
        ..notePeerGap(SyncPeerGapDimension.tags, outdated: true)
        ..notePeerGap(SyncPeerGapDimension.mediaLinks, outdated: true)
        ..notePeerGap(SyncPeerGapDimension.localAudioIdentity, outdated: true);
      expect(
        summarizeSyncReport(r),
        contains(t.sync_now_peer_outdated_mixed(missing: 2, limited: 1)),
      );
    });

    test('对端不支持（非版本过旧）不叫升级', () {
      final SyncRunReport r = SyncRunReport()
        ..notePeerGap(SyncPeerGapDimension.pdfBooks, outdated: false);
      final String s = summarizeSyncReport(r);
      expect(s, isNot(contains('older Fushi')));
    });

    test('只有本地音频身份是降级维度', () {
      expect(
        <SyncPeerGapDimension>[
          for (final SyncPeerGapDimension d in SyncPeerGapDimension.values)
            if (d.degraded) d,
        ],
        <SyncPeerGapDimension>[SyncPeerGapDimension.localAudioIdentity],
      );
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

  test('报告原句可精确还原成维度，面板据此换成本地化说明；别的行不误认', () {
    final Set<String> lines = <String>{};
    for (final SyncPeerGapDimension d in SyncPeerGapDimension.values) {
      for (final bool outdated in const <bool>[true, false]) {
        final SyncPeerGap gap = SyncPeerGap(dimension: d, outdated: outdated);
        final SyncPeerGap? back = SyncPeerGap.fromMessage(gap.message);
        expect(back?.dimension, d);
        expect(back?.outdated, outdated);
        final String line = localizedSyncTaskError(gap.message);
        expect(line, isNot(gap.message), reason: '$d/$outdated 没换成本地化文案');
        lines.add(line);
      }
    }
    expect(lines, hasLength(SyncPeerGapDimension.values.length * 2));
    expect(SyncPeerGap.fromMessage('online library live sync: boom'), isNull);
    expect(
      localizedSyncTaskError('online library live sync: boom'),
      'online library live sync: boom',
    );
  });
}
