/// 反馈 Et3pmRzo0k：主机「从所有设备删除」的书，客户端下一轮互联同步不得再把它推回
/// 主机、也不得借这次推送清掉主机的删除墓碑。
///
/// 真实链路：client [SyncOrchestrator] → [InterconnectSyncBackend] HTTP →
/// [FushiSyncServer] → [LocalLibraryHostService]（host 导入走 `insertEpubBook`，与生产
/// 一样会清同步墓碑）。两层各钉一遍：
/// * client：内容推送前先读 host 墓碑，删除前就在本机的那份不进推送清单；整轮跑完后
///   删除确认候选照常产出（本机那份等用户确认后再删）。
/// * host：推送方（含旧版 client，不报存在起始时刻）推来被墓碑覆盖的书 / 有声书 /
///   视频 → 409、不导入、墓碑保留。
/// 以及合法的「删了又在本机重新导入」：本机 `localAddedAt` 晚于删除 → 照推，host 收下
/// 并清墓碑。
library;

import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/sync/interconnect_sync_backend.dart';
import 'package:fushi/src/sync/sync_orchestrator.dart';
import 'package:fushi/src/sync/sync_repository.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/sync/deletion_propagation.dart';
import 'package:fushi_engine/sync/fushi_sync_server.dart';
import 'package:fushi_engine/sync/local_library_host_service.dart';
import 'package:fushi_engine/sync/sync_asset_package_service.dart';
import 'package:fushi_engine/sync/ttu_filename.dart';
import 'package:path/path.dart' as p;

FushiDatabase _memDb() =>
    FushiDatabase.forTesting(DatabaseConnection(NativeDatabase.memory()));

/// 删除发生的时刻（host 时钟）。本机「删除前就有」= 早于它，「删后重新导入」= 晚于它。
const int _deletedAt = 1700000000000;

Future<void> _seedBook({
  required FushiDatabase db,
  required String title,
  required String extractDir,
  int? localAddedAt,
}) async {
  Directory(extractDir).createSync(recursive: true);
  File(
    p.join(extractDir, 'mimetype'),
  ).writeAsStringSync('application/epub+zip');
  final Directory metaInf = Directory(p.join(extractDir, 'META-INF'))
    ..createSync();
  File(p.join(metaInf.path, 'container.xml')).writeAsStringSync(
    '<?xml version="1.0"?>'
    '<container version="1.0" xmlns="urn:oasis:schemas:container">'
    '<rootfiles><rootfile full-path="content.opf"'
    ' media-type="application/oebps-package+xml"/></rootfiles>'
    '</container>',
  );
  File(p.join(extractDir, 'content.opf')).writeAsStringSync(
    '<?xml version="1.0"?>'
    '<package xmlns="http://www.idpf.org/2007/opf" version="2.0">'
    '<metadata/><manifest/><spine/></package>',
  );
  await db.insertEpubBook(
    EpubBooksCompanion.insert(
      bookKey: title,
      title: title,
      epubPath: p.join(extractDir, 'original.epub'),
      extractDir: extractDir,
      chapterCount: 1,
      chaptersJson: '["ch1"]',
      importedAt: 1,
      localAddedAt: localAddedAt == null
          ? const Value<int?>.absent()
          : Value<int?>(localAddedAt),
    ),
  );
}

Future<InterconnectSyncBackend> _clientBackend(
  String base,
  String token,
) async {
  final FushiDatabase db = _memDb();
  final SyncRepository repo = SyncRepository(db);
  await repo.setFushiClientUrls(<FushiClientUrl>[
    FushiClientUrl(url: base, enabled: true),
  ]);
  await repo.setFushiClientToken(token);
  final InterconnectSyncBackend backend = InterconnectSyncBackend.withProbe(
    (String u, String t) async => true,
  );
  await backend.restoreAuth(repo);
  await backend.authenticate(repo: repo);
  return backend;
}

Future<Map<String, int>> _hostTombstones(
  FushiDatabase db,
) async => <String, int>{
  for (final SyncDeletionTombstoneRow r in await db.getSyncDeletionTombstones())
    '${r.mediaType}|${r.itemKey}': r.deletedAt,
};

void main() {
  late Directory work;
  late FushiDatabase hostDb;
  late FushiSyncServer server;
  late String base;
  const String token = 'et3pmrzo0k-token';

  setUp(() async {
    work = await Directory.systemTemp.createTemp('et3pmrzo0k_');
    hostDb = _memDb();
    final LocalLibraryHostService libSvc = LocalLibraryHostService(
      db: hostDb,
      dictionaryResourceRoot: Directory(work.path),
      packages: SyncAssetPackageService(db: hostDb),
      refreshDictionaryCache: () async {},
      runExclusive: (Future<void> Function() body) => body(),
      // 与生产同形：tmp 文件名 = URL 书名，入库走 insertEpubBook（会清同步墓碑）。
      importBookFromFile: (File f) async {
        final String title = p.basenameWithoutExtension(f.path);
        await _seedBook(
          db: hostDb,
          title: title,
          extractDir: p.join(work.path, 'host_$title'),
        );
        return sanitizeTtuFilename(title);
      },
    );
    server = FushiSyncServer(
      syncDataDir: p.join(work.path, 'server_data'),
      port: 0,
      token: token,
      allowLan: false,
      libraryService: libSvc,
    );
    await server.start();
    base = 'http://127.0.0.1:${server.port}';
    // host 上这本书已被「从所有设备删除」：行没了，同步删除墓碑在。
    await hostDb.writeSyncDeletionTombstone(
      SyncTombstoneKind.book.dbValue,
      'BookD',
      _deletedAt,
    );
  });

  tearDown(() async {
    await server.stop();
    await hostDb.close();
    if (work.existsSync()) await work.delete(recursive: true);
  });

  SyncOrchestrator orchestrator(FushiDatabase db, Directory tmp) =>
      SyncOrchestrator(
        db: db,
        backend: InterconnectSyncBackend.withProbe((_, __) async => true),
        dictionaryResourceRoot: tmp,
        audioDatabaseRoot: tmp,
        tempDir: tmp,
        syncStats: false,
        syncAudioBookPosition: false,
        syncContent: true,
        syncMangaContent: true,
        syncAudioBookFiles: false,
        syncDictionary: false,
      );

  test('client 删除前就有的那本：整轮同步不推回 host，host 墓碑保留，本机出删除确认候选', () async {
    final FushiDatabase localDb = _memDb();
    addTearDown(localDb.close);
    await _seedBook(
      db: localDb,
      title: 'BookD',
      extractDir: p.join(work.path, 'local_D'),
      localAddedAt: _deletedAt - 60000,
    );
    // 对照组：host 从没有过、也没有墓碑的书照常推。
    await _seedBook(
      db: localDb,
      title: 'BookN',
      extractDir: p.join(work.path, 'local_N'),
      localAddedAt: _deletedAt - 60000,
    );
    final Directory tmp = Directory(p.join(work.path, 'tmp_run'))..createSync();
    final InterconnectSyncBackend backend = await _clientBackend(base, token);
    final SyncOrchestrator orch = SyncOrchestrator(
      db: localDb,
      backend: backend,
      dictionaryResourceRoot: tmp,
      audioDatabaseRoot: tmp,
      tempDir: tmp,
      syncStats: false,
      syncAudioBookPosition: false,
      syncContent: true,
      syncMangaContent: true,
      syncAudioBookFiles: false,
      syncDictionary: false,
    );

    final SyncRunReport report = await orch.run();

    expect(report.errors, isEmpty, reason: '${report.errors}');
    expect(
      await hostDb.getEpubBook('BookD'),
      isNull,
      reason: '被「从所有设备删除」的书不得被推回 host',
    );
    expect(
      await hostDb.getEpubBook('BookN'),
      isNotNull,
      reason: '无墓碑的本端独有书照常推送',
    );
    expect(
      (await _hostTombstones(hostDb))['book|BookD'],
      _deletedAt,
      reason: 'host 的删除墓碑不得被推送清掉',
    );
    expect(
      report.deletionCandidates,
      contains(
        const DeletionPropagationCandidate(
          mediaType: 'book',
          itemKey: 'BookD',
          direction: DeletionPropagationDirection.deleteLocal,
        ),
      ),
      reason: '删除意图仍要传到本机，等用户确认',
    );
  });

  test('本机删后重新导入（localAddedAt 晚于删除）：照推，host 收下并清墓碑', () async {
    final FushiDatabase localDb = _memDb();
    addTearDown(localDb.close);
    await _seedBook(
      db: localDb,
      title: 'BookD',
      extractDir: p.join(work.path, 'local_D_readd'),
      localAddedAt: _deletedAt + 60000,
    );
    final Directory tmp = Directory(p.join(work.path, 'tmp_readd'))
      ..createSync();
    final InterconnectSyncBackend backend = await _clientBackend(base, token);
    final SyncRunReport report = SyncRunReport();
    await orchestrator(
      localDb,
      tmp,
    ).syncBooksContentLiveForTest(report, backend);

    expect(report.errors, isEmpty, reason: '${report.errors}');
    expect(await hostDb.getEpubBook('BookD'), isNotNull);
    expect((await _hostTombstones(hostDb)).containsKey('book|BookD'), isFalse);
  });

  group('host 闸门（旧版 client 不报存在起始时刻）', () {
    late InterconnectSyncBackend backend;
    late File payload;

    setUp(() async {
      backend = await _clientBackend(base, token);
      payload = File(p.join(work.path, 'payload.bin'))
        ..writeAsBytesSync(List<int>.filled(4096, 7));
    });

    test('书：未报时刻 → 409、不导入、墓碑保留；报了删后的时刻 → 收下', () async {
      await expectLater(
        backend.putRemoteBook('BookD', payload),
        throwsA(predicate((Object e) => '$e'.contains('HTTP 409'))),
      );
      await expectLater(
        backend.putRemoteBook('BookD', payload, presentSinceAt: _deletedAt - 1),
        throwsA(predicate((Object e) => '$e'.contains('HTTP 409'))),
      );
      expect(await hostDb.getEpubBook('BookD'), isNull);
      expect((await _hostTombstones(hostDb))['book|BookD'], _deletedAt);

      await backend.putRemoteBook(
        'BookD',
        payload,
        presentSinceAt: _deletedAt + 1,
      );
      expect(await hostDb.getEpubBook('BookD'), isNotNull);
      expect(
        (await _hostTombstones(hostDb)).containsKey('book|BookD'),
        isFalse,
      );
    });

    test('有声书：自身墓碑或所属书的墓碑都拒收', () async {
      await hostDb.writeSyncDeletionTombstone(
        SyncTombstoneKind.audiobook.dbValue,
        'AudioA',
        _deletedAt,
      );
      await expectLater(
        backend.putRemoteAudiobook('AudioA', payload),
        throwsA(predicate((Object e) => '$e'.contains('HTTP 409'))),
      );
      // 删书只立 `book` 墓碑却连带删掉 host 的有声书：推回来会落成孤儿有声书。
      await expectLater(
        backend.putRemoteAudiobook('BookD', payload),
        throwsA(predicate((Object e) => '$e'.contains('HTTP 409'))),
      );
      expect(await hostDb.getAudiobookByBookKey('AudioA'), isNull);
      expect((await _hostTombstones(hostDb))['audiobook|AudioA'], _deletedAt);
    });

    test('视频：墓碑覆盖的 bookUid 拒收', () async {
      await hostDb.writeSyncDeletionTombstone(
        SyncTombstoneKind.video.dbValue,
        'video/v1',
        _deletedAt,
      );
      await expectLater(
        backend.putRemoteVideo('video/v1', payload, title: 'V1'),
        throwsA(predicate((Object e) => '$e'.contains('HTTP 409'))),
      );
      expect(await hostDb.getVideoBookByBookUid('video/v1'), isNull);
      expect((await _hostTombstones(hostDb))['video|video/v1'], _deletedAt);
    });
  });

  group('peerTombstoneVetoesPush（纯判据）', () {
    final DeletionTombstoneEntries tombs = <String, Map<String, int>>{
      'book': <String, int>{'K': 100},
    };

    test('删除前就在 / 时刻未知 → 否决；删后加入 → 放行；无墓碑 → 放行', () {
      bool veto(int? since, {String key = 'K'}) => peerTombstoneVetoesPush(
        peerTombstones: tombs,
        mediaTypes: const <String>['book'],
        itemKeys: <String>[key],
        presentSinceAt: since,
      );
      expect(veto(50), isTrue);
      expect(veto(null), isTrue);
      expect(veto(100), isFalse);
      expect(veto(150), isFalse);
      expect(veto(50, key: 'other'), isFalse);
    });

    test('多种类：任一种墓碑管得着即否决', () {
      expect(
        peerTombstoneVetoesPush(
          peerTombstones: tombs,
          mediaTypes: const <String>['audiobook', 'book'],
          itemKeys: const <String>['K'],
          presentSinceAt: 50,
        ),
        isTrue,
      );
    });
  });
}
