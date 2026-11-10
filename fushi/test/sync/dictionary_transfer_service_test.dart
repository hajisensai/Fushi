/// 按 host 推送 / 下载单本词典（[DictionaryTransferService]）。
///
/// 两台真实 [FushiSyncServer]（各带 [LocalLibraryHostService] + 真库 + 真资源目录）
/// 同时配对在本机：请求只能打到选中的那一台；选中的那台连不上就报错，绝不改投另一台。
library;

import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/sync/dictionary_transfer_service.dart';
import 'package:fushi/src/sync/interconnect_sync_backend.dart';
import 'package:fushi/src/sync/sync_orchestrator.dart';
import 'package:fushi/src/sync/sync_repository.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/sync/fushi_sync_server.dart';
import 'package:fushi_engine/sync/local_library_host_service.dart';
import 'package:fushi_engine/sync/sync_asset_package_service.dart';
import 'package:path/path.dart' as p;

FushiDatabase _memDb() =>
    FushiDatabase.forTesting(DatabaseConnection(NativeDatabase.memory()));

Future<void> _seedDictionary(
  FushiDatabase db,
  Directory dictRoot,
  String name,
) async {
  await db.upsertDictionaryMeta(
    DictionaryMetadataCompanion.insert(
      name: name,
      formatKey: 'yomichan',
      order: 0,
      type: const Value('term'),
      metadataJson: const Value('{}'),
      hiddenLanguagesJson: const Value('[]'),
      collapsedLanguagesJson: const Value('[]'),
    ),
  );
  final Directory dir = Directory(p.join(dictRoot.path, name))
    ..createSync(recursive: true);
  File(p.join(dir.path, 'blobs.bin')).writeAsBytesSync(<int>[1, 2, 3]);
}

Future<Set<String>> _names(FushiDatabase db) async => <String>{
  for (final DictionaryMetaRow r in await db.getAllDictionaryMetadata()) r.name,
};

/// 一台测试 host：真库 + 真资源目录 + 真同步服务器。
class _Host {
  _Host._(this.db, this.dictRoot, this.server);

  final FushiDatabase db;
  final Directory dictRoot;
  final FushiSyncServer server;

  String get url => 'http://127.0.0.1:${server.port}';

  static Future<_Host> start(Directory work, String id, String token) async {
    final FushiDatabase db = _memDb();
    final Directory dictRoot = Directory(p.join(work.path, '${id}_dicts'))
      ..createSync();
    final FushiSyncServer server = FushiSyncServer(
      syncDataDir: p.join(work.path, '${id}_data'),
      port: 0,
      token: token,
      allowLan: false,
      libraryService: LocalLibraryHostService(
        db: db,
        dictionaryResourceRoot: dictRoot,
        packages: SyncAssetPackageService(db: db),
        refreshDictionaryCache: () async {},
        runExclusive: (Future<void> Function() body) => body(),
      ),
    );
    await server.start();
    return _Host._(db, dictRoot, server);
  }

  Future<void> stop() async {
    await server.stop();
    await db.close();
  }
}

void main() {
  late Directory work;
  late _Host hostA;
  late _Host hostB;
  late FushiDatabase local;
  late Directory localDictRoot;
  late Directory tmp;

  /// 每次探测的地址（按 host 归类断言「另一台从没被碰过」）。
  late List<String> probed;

  /// 探测时视为连不上的地址。
  late Set<String> down;

  late List<SyncRunReport> postRuns;

  setUp(() async {
    work = await Directory.systemTemp.createTemp('dict_transfer_');
    hostA = await _Host.start(work, 'a', 'token-a');
    hostB = await _Host.start(work, 'b', 'token-b');
    local = _memDb();
    localDictRoot = Directory(p.join(work.path, 'local_dicts'))..createSync();
    tmp = Directory(p.join(work.path, 'tmp'))..createSync();
    probed = <String>[];
    down = <String>{};
    postRuns = <SyncRunReport>[];
    await SyncRepository(local).setFushiClientUrls(<FushiClientUrl>[
      FushiClientUrl(
        url: hostA.url,
        hostId: 'host-a',
        token: 'token-a',
        deviceName: 'A',
      ),
      FushiClientUrl(
        url: hostB.url,
        hostId: 'host-b',
        token: 'token-b',
        deviceName: 'B',
      ),
    ]);
  });

  tearDown(() async {
    await hostA.stop();
    await hostB.stop();
    await local.close();
    if (work.existsSync()) await work.delete(recursive: true);
  });

  DictionaryTransferService service() => DictionaryTransferService(
    db: local,
    dictionaryResourceRoot: localDictRoot,
    tempDir: tmp,
    onPostRun: (SyncRunReport r) async => postRuns.add(r),
    backendFor: (String hostId) => InterconnectSyncBackend.scopedToHost(
      hostId,
      probe: (String url, String token) async {
        probed.add(url);
        return !down.contains(url);
      },
    ),
  );

  bool touched(_Host host) => probed.any((String u) => u.startsWith(host.url));

  group('host-scoped session', () {
    test('push goes only to the chosen host', () async {
      await _seedDictionary(local, localDictRoot, 'JMdict');

      final DictionaryTransferResult result = await service().pushToHost(
        'host-b',
        'JMdict',
      );

      expect(result, isA<DictionaryTransferDone>());
      expect(await _names(hostB.db), contains('JMdict'));
      expect(await _names(hostA.db), isNot(contains('JMdict')));
      expect(touched(hostA), isFalse, reason: 'host A must never be probed');
      // 推完对账：host-b 的目录行有了这本 → 管理页这一行翻成「两者」。
      final List<RemoteDictionaryMetaRow> catalog = await local
          .getAllRemoteDictionaryMetadata();
      expect(
        catalog.map((RemoteDictionaryMetaRow r) => '${r.hostId}/${r.name}'),
        contains('host-b/JMdict'),
      );
      expect(
        catalog.where((RemoteDictionaryMetaRow r) => r.hostId == 'host-a'),
        isEmpty,
      );
    });

    test('unreachable chosen host fails without falling back', () async {
      await _seedDictionary(local, localDictRoot, 'JMdict');
      down.add(hostA.url);

      final DictionaryTransferResult result = await service().pushToHost(
        'host-a',
        'JMdict',
      );

      expect(result, isA<DictionaryTransferFailed>());
      expect(
        (result as DictionaryTransferFailed).kind,
        DictionaryTransferFailureKind.unreachable,
      );
      expect(touched(hostB), isFalse, reason: 'no fallback to host B');
      expect(await _names(hostB.db), isNot(contains('JMdict')));
      expect(await _names(hostA.db), isNot(contains('JMdict')));
    });

    test('host that is not paired reports notPaired', () async {
      await _seedDictionary(local, localDictRoot, 'JMdict');

      final DictionaryTransferResult result = await service().pushToHost(
        'host-z',
        'JMdict',
      );

      expect(
        (result as DictionaryTransferFailed).kind,
        DictionaryTransferFailureKind.notPaired,
      );
      expect(probed, isEmpty);
    });

    test('rejected pairing token reports unauthorized', () async {
      await SyncRepository(local).setFushiClientUrls(<FushiClientUrl>[
        FushiClientUrl(url: hostA.url, hostId: 'host-a', token: 'wrong'),
        FushiClientUrl(url: hostB.url, hostId: 'host-b', token: 'token-b'),
      ]);
      await _seedDictionary(hostA.db, hostA.dictRoot, '明镜');

      final DictionaryTransferResult result = await service().downloadFromHost(
        'host-a',
        '明镜',
      );

      expect(
        (result as DictionaryTransferFailed).kind,
        DictionaryTransferFailureKind.unauthorized,
      );
      expect(await _names(local), isNot(contains('明镜')));
    });
  });

  group('download', () {
    test(
      'imports from the chosen host and runs the post-import hook',
      () async {
        await _seedDictionary(hostA.db, hostA.dictRoot, '明镜');
        await _seedDictionary(hostB.db, hostB.dictRoot, 'Other');
        final List<DictionaryTransferStage> stages =
            <DictionaryTransferStage>[];

        final DictionaryTransferResult result = await service()
            .downloadFromHost(
              'host-a',
              '明镜',
              onProgress: (DictionaryTransferProgress p) => stages.add(p.stage),
            );

        expect(result, isA<DictionaryTransferDone>());
        expect(await _names(local), <String>{'明镜'});
        expect(touched(hostB), isFalse);
        expect(stages, contains(DictionaryTransferStage.importing));
        expect(postRuns, hasLength(1));
        expect(postRuns.single.dictionariesImported, 1);
        expect(postRuns.single.errors, isEmpty);
        final List<RemoteDictionaryMetaRow> catalog = await local
            .getAllRemoteDictionaryMetadata();
        expect(
          catalog.map((RemoteDictionaryMetaRow r) => '${r.hostId}/${r.name}'),
          <String>['host-a/明镜'],
        );
      },
    );

    test('same-name local dictionary means already installed', () async {
      await _seedDictionary(hostA.db, hostA.dictRoot, 'JMdict');
      await _seedDictionary(local, localDictRoot, 'JMdict');

      final DictionaryTransferResult result = await service().downloadFromHost(
        'host-a',
        'JMdict',
      );

      expect(result, isA<DictionaryTransferAlreadyPresent>());
      expect(probed, isEmpty, reason: 'no network for an installed dictionary');
      expect(postRuns, isEmpty);
    });

    test('dictionary missing on the host reports notFound', () async {
      final DictionaryTransferResult result = await service().downloadFromHost(
        'host-a',
        'Nope',
      );

      expect(
        (result as DictionaryTransferFailed).kind,
        DictionaryTransferFailureKind.notFound,
      );
      expect(await _names(local), isEmpty);
    });
  });

  group('push', () {
    test('host that already has it reports alreadyPresent', () async {
      await _seedDictionary(local, localDictRoot, 'JMdict');
      await _seedDictionary(hostA.db, hostA.dictRoot, 'JMdict');

      final DictionaryTransferResult result = await service().pushToHost(
        'host-a',
        'JMdict',
      );

      expect(result, isA<DictionaryTransferAlreadyPresent>());
      expect(postRuns.single.dictionariesExported, 0);
    });

    test('a second transfer while one runs reports busy', () async {
      await _seedDictionary(local, localDictRoot, 'JMdict');
      final DictionaryTransferService s = service();

      final Future<DictionaryTransferResult> first = s.pushToHost(
        'host-a',
        'JMdict',
      );
      final DictionaryTransferResult second = await s.pushToHost(
        'host-b',
        'JMdict',
      );

      expect(
        (second as DictionaryTransferFailed).kind,
        DictionaryTransferFailureKind.busy,
      );
      expect(await first, isA<DictionaryTransferDone>());
      expect(await _names(hostB.db), isNot(contains('JMdict')));
    });
  });

  group('classifyDictionaryTransferError', () {
    test('disk full is outOfDisk', () {
      expect(
        classifyDictionaryTransferError(
          const FileSystemException(
            'write failed',
            '/x',
            OSError('No space left on device', 28),
          ),
        ),
        DictionaryTransferFailureKind.outOfDisk,
      );
    });

    test('other file errors stay generic', () {
      expect(
        classifyDictionaryTransferError(
          const FileSystemException('denied', '/x', OSError('Access', 5)),
        ),
        DictionaryTransferFailureKind.failed,
      );
    });
  });
}
