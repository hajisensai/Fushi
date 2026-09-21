import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:fushi_engine/media/video/metadata/anidb_ed2k.dart';
import 'package:fushi_engine/media/video/metadata/anidb_file_identity_store.dart';
import 'package:fushi_engine/media/video/metadata/anidb_hash_identity_service.dart';
import 'package:fushi_engine/media/video/metadata/anidb_udp_file_client.dart';
import 'package:fushi_engine/media/video/metadata/anime_identity_mapping.dart';
import 'package:fushi_engine/media/video/metadata/video_metadata_transport.dart';

const AnidbUdpConfig config = AnidbUdpConfig(
    username: 'testuser',
    password: 'secret',
    clientName: 'testclient',
    clientVersion: 1);
const AnidbFileIdentity identity = AnidbFileIdentity(
    fileId: 1,
    animeId: 2,
    episodeId: 3,
    episodeNumber: 'S1',
    romajiTitle: 'Title',
    kanjiTitle: '',
    englishTitle: '',
    episodeTitle: '',
    episodeRomajiTitle: '',
    episodeKanjiTitle: '');

void main() {
  test('file mutation during identity lookup cannot be reported as matched',
      () async {
    final Directory dir =
        await Directory.systemTemp.createTemp('anidb-changed-');
    addTearDown(() => dir.delete(recursive: true));
    final File file = await File('${dir.path}/video').writeAsString('a');
    final AnidbHashIdentityService service = AnidbHashIdentityService(
      enabled: true,
      config: config,
      lookup: ({required int size, required String ed2k}) async => identity,
      mapping: AnimeIdentityMapping(httpClient: VideoMetadataHttpClient(
        client: MockClient((_) async {
          await file.writeAsString('different contents');
          return http.Response('[{"anidb_id":2,"mal_id":9}]', 200);
        }),
      )),
    );
    addTearDown(service.close);
    final AnidbHashIdentityResult result =
        await service.identifyFile(file.path);
    expect(result.status, AnidbHashIdentityStatus.failed);
    expect(result.error, isA<FileSystemException>());
    expect(result.identity, isNull);
    expect(result.confirmedMalId, isNull);
  });

  test('disabled and unconfigured skip file hashing', () async {
    for (final bool enabled in <bool>[false, true]) {
      final AnidbHashIdentityService service = AnidbHashIdentityService(
        enabled: enabled,
        config: const AnidbUdpConfig(
            username: '', password: '', clientName: '', clientVersion: 0),
        hasher: (_, {isCancelled, onProgress}) =>
            throw StateError('must not hash'),
      );
      final AnidbHashIdentityResult result =
          await service.identifyFile('/missing');
      expect(
          result.status,
          enabled
              ? AnidbHashIdentityStatus.unavailable
              : AnidbHashIdentityStatus.disabled);
      await service.close();
    }
  });

  test('alternate only after miss; cached hash invalidates on file change',
      () async {
    final Directory dir =
        await Directory.systemTemp.createTemp('anidb-identity-');
    addTearDown(() => dir.delete(recursive: true));
    final File file = await File('${dir.path}/video.mkv').writeAsString('a');
    int hashes = 0;
    final List<String> lookedUp = <String>[];
    final AnidbHashIdentityService service = AnidbHashIdentityService(
      enabled: true,
      config: config,
      mapping: AnimeIdentityMapping(
          httpClient: VideoMetadataHttpClient(
              client: MockClient((_) async =>
                  http.Response('[{"anidb_id":2,"mal_id":9}]', 200)))),
      hasher: (String path, {isCancelled, onProgress}) async {
        hashes++;
        final FileStat stat = await File(path).stat();
        return AnidbEd2kHash(
            ed2k: 'a',
            alternativeEd2k: 'b',
            size: stat.size,
            modifiedAt: stat.modified,
            changedAt: stat.changed);
      },
      lookup: ({required int size, required String ed2k}) async {
        lookedUp.add(ed2k);
        return ed2k == 'a' ? null : identity;
      },
    );
    addTearDown(service.close);
    final AnidbHashIdentityResult result =
        await service.identifyFile(file.path);
    expect(result.status, AnidbHashIdentityStatus.matched);
    expect(result.confirmedMalId, 9);
    expect(result.matchedEd2k, 'b');
    expect(result.identity!.episodeNumber, 'S1');
    expect(lookedUp, <String>['a', 'b']);
    await service.identifyFile(file.path);
    expect(hashes, 1);
    await file.writeAsString('changed length');
    await service.identifyFile(file.path);
    expect(hashes, 2);
  });

  test(
      'mapping failure retains hash identity; network failure never tries alternate',
      () async {
    final Directory dir =
        await Directory.systemTemp.createTemp('anidb-identity-');
    addTearDown(() => dir.delete(recursive: true));
    final File file = await File('${dir.path}/video').writeAsString('a');
    int calls = 0;
    bool failLookup = false;
    final AnidbHashIdentityService service = AnidbHashIdentityService(
      enabled: true,
      config: config,
      mapping: AnimeIdentityMapping(
          httpClient: VideoMetadataHttpClient(
              maxAttempts: 1,
              client:
                  MockClient((_) async => http.Response('unavailable', 503)))),
      hasher: (String path, {isCancelled, onProgress}) async {
        final FileStat stat = await File(path).stat();
        return AnidbEd2kHash(
            ed2k: 'a',
            alternativeEd2k: 'b',
            size: stat.size,
            modifiedAt: stat.modified,
            changedAt: stat.changed);
      },
      lookup: ({required int size, required String ed2k}) async {
        calls++;
        if (failLookup) throw const AnidbUdpException(AnidbUdpFailure.timeout);
        return identity;
      },
    );
    addTearDown(service.close);
    final AnidbHashIdentityResult result =
        await service.identifyFile(file.path);
    expect(result.status, AnidbHashIdentityStatus.matched);
    expect(result.mappingError, isNotNull);
    expect(result.matchedEd2k, 'a');
    expect(result.confirmedMalId, isNull);
    failLookup = true;
    expect((await service.identifyFile(file.path)).status,
        AnidbHashIdentityStatus.failed);
    expect(calls, 2);
    expect(
        (await service.identifyFile(file.path, isCancelled: () => true)).status,
        AnidbHashIdentityStatus.cancelled);
    expect(calls, 2);
  });

  // BUG-2586（对齐 Shoko）：文件级身份持久化——路径+大小+mtime 命中免哈希，
  // 哈希后内容键命中免 FILE，未收录也落行并在复查期内不重问。
  group('persistent file identity store', () {
    AnimeIdentityMapping mapping() => AnimeIdentityMapping(
        httpClient: VideoMetadataHttpClient(
            client: MockClient((_) async =>
                http.Response('[{"anidb_id":2,"mal_id":9}]', 200))));

    AnidbHashIdentityService service(_MemoryStore store,
        {required void Function() onHash,
        required void Function(String) onLookup,
        AnidbFileIdentity? lookupResult = identity,
        DateTime Function()? now}) {
      final AnidbHashIdentityService s = AnidbHashIdentityService(
        enabled: true,
        config: config,
        mapping: mapping(),
        store: store,
        now: now,
        hasher: (String path, {isCancelled, onProgress}) async {
          onHash();
          final FileStat stat = await File(path).stat();
          return AnidbEd2kHash(
              ed2k: 'a',
              size: stat.size,
              modifiedAt: stat.modified,
              changedAt: stat.changed);
        },
        lookup: ({required int size, required String ed2k}) async {
          onLookup(ed2k);
          return lookupResult;
        },
      );
      addTearDown(s.close);
      return s;
    }

    test('second sight of the same file uses the stored identity', () async {
      final Directory dir =
          await Directory.systemTemp.createTemp('anidb-store-');
      addTearDown(() => dir.delete(recursive: true));
      final File file = await File('${dir.path}/video.mkv').writeAsString('a');
      final _MemoryStore store = _MemoryStore();
      int hashes = 0;
      int lookups = 0;
      final AnidbHashIdentityService first =
          service(store, onHash: () => hashes++, onLookup: (_) => lookups++);
      final AnidbHashIdentityResult online =
          await first.identifyFile(file.path);
      expect(online.status, AnidbHashIdentityStatus.matched);
      expect(online.fromStore, isFalse);
      expect(store.records.single.identity?.fileId, 1);
      expect(store.records.single.filePath, File(file.path).absolute.path);

      // 新的服务实例（新进程 / 新协调器）：只查表，不哈希不发 FILE。
      final AnidbHashIdentityService second =
          service(store, onHash: () => hashes++, onLookup: (_) => lookups++);
      final AnidbHashIdentityResult stored =
          await second.identifyFile(file.path);
      expect(stored.status, AnidbHashIdentityStatus.matched);
      expect(stored.fromStore, isTrue);
      expect(stored.identity?.animeId, 2);
      expect(stored.confirmedMalId, 9, reason: '映射照查，调用方不用区分来源');
      expect(stored.hash?.ed2k, 'a');
      expect(hashes, 1);
      expect(lookups, 1);
    });

    test('a moved file is re-hashed but not re-queried', () async {
      final Directory dir =
          await Directory.systemTemp.createTemp('anidb-store-');
      addTearDown(() => dir.delete(recursive: true));
      final File file = await File('${dir.path}/video.mkv').writeAsString('a');
      final _MemoryStore store = _MemoryStore();
      int hashes = 0;
      int lookups = 0;
      await service(store, onHash: () => hashes++, onLookup: (_) => lookups++)
          .identifyFile(file.path);
      final File moved = await file.rename('${dir.path}/renamed.mkv');
      final AnidbHashIdentityResult result = await service(store,
          onHash: () => hashes++,
          onLookup: (_) => lookups++).identifyFile(moved.path);
      expect(result.status, AnidbHashIdentityStatus.matched);
      expect(result.fromStore, isTrue);
      expect(hashes, 2);
      expect(lookups, 1);
      expect(store.records.single.filePath, File(moved.path).absolute.path,
          reason: '路径提示跟着搬家');
    });

    test(
        'an unknown hash is stored and not re-queried until the recheck period',
        () async {
      final Directory dir =
          await Directory.systemTemp.createTemp('anidb-store-');
      addTearDown(() => dir.delete(recursive: true));
      final File file = await File('${dir.path}/video.mkv').writeAsString('a');
      final _MemoryStore store = _MemoryStore();
      int lookups = 0;
      DateTime now = DateTime(2026, 9, 18);
      AnidbHashIdentityService make() => service(store,
          onHash: () {},
          onLookup: (_) => lookups++,
          lookupResult: null,
          now: () => now);
      expect((await make().identifyFile(file.path)).status,
          AnidbHashIdentityStatus.notFound);
      expect(store.records.single.identity, isNull);
      expect(store.records.single.missAttempts, 1);
      now = now.add(const Duration(hours: 20));
      final AnidbHashIdentityResult fresh =
          await make().identifyFile(file.path);
      expect(fresh.status, AnidbHashIdentityStatus.notFound);
      expect(fresh.fromStore, isTrue);
      expect(fresh.missAttempts, 1);
      expect(lookups, 1);
      // Shoko `File_UpdateFrequency` 默认每日：过了一天再问一次 AniDB。
      now = now.add(const Duration(hours: 6));
      final AnidbHashIdentityResult again =
          await make().identifyFile(file.path);
      expect(again.fromStore, isFalse);
      expect(again.missAttempts, 2);
      expect(lookups, 2, reason: '过了复查期再问一次 AniDB');
      expect(store.records.single.missAttempts, 2);
    });

    test(
        'after 15 misses the file is no longer re-queried automatically '
        '(Shoko MaxAutoScanAttemptsPerFile)', () async {
      final Directory dir =
          await Directory.systemTemp.createTemp('anidb-store-');
      addTearDown(() => dir.delete(recursive: true));
      final File file = await File('${dir.path}/video.mkv').writeAsString('a');
      final _MemoryStore store = _MemoryStore();
      int lookups = 0;
      DateTime now = DateTime(2026, 9, 18);
      AnidbHashIdentityService make() => service(store,
          onHash: () {},
          onLookup: (_) => lookups++,
          lookupResult: null,
          now: () => now);
      for (int attempt = 1; attempt <= 15; attempt++) {
        final AnidbHashIdentityResult result =
            await make().identifyFile(file.path);
        expect(result.fromStore, isFalse, reason: '第 $attempt 次复查要真问');
        expect(result.missAttempts, attempt);
        now = now.add(const Duration(days: 2));
      }
      expect(lookups, 15);
      final AnidbHashIdentityResult exhausted =
          await make().identifyFile(file.path);
      expect(exhausted.status, AnidbHashIdentityStatus.notFound);
      expect(exhausted.fromStore, isTrue);
      expect(exhausted.missExhausted, isTrue);
      expect(lookups, 15, reason: '用尽 15 次后不再自动问 AniDB');
    });

    test('a hit resets the miss counter', () async {
      final Directory dir =
          await Directory.systemTemp.createTemp('anidb-store-');
      addTearDown(() => dir.delete(recursive: true));
      final File file = await File('${dir.path}/video.mkv').writeAsString('a');
      final _MemoryStore store = _MemoryStore();
      DateTime now = DateTime(2026, 9, 18);
      await service(store,
          onHash: () {},
          onLookup: (_) {},
          lookupResult: null,
          now: () => now).identifyFile(file.path);
      expect(store.records.single.missAttempts, 1);
      now = now.add(const Duration(days: 2));
      final AnidbHashIdentityResult hit =
          await service(store, onHash: () {}, onLookup: (_) {}, now: () => now)
              .identifyFile(file.path);
      expect(hit.status, AnidbHashIdentityStatus.matched);
      expect(store.records.single.missAttempts, 0);
    });
  });

  test('other_episodes column round-trips and tolerates garbage', () {
    const List<AnidbEpisodeShare> shares = <AnidbEpisodeShare>[
      AnidbEpisodeShare(episodeId: 301, percentage: 50),
      AnidbEpisodeShare(episodeId: 302, percentage: 50),
    ];
    expect(encodeOtherEpisodes(const <AnidbEpisodeShare>[]), '');
    expect(encodeOtherEpisodes(shares), '[[301,50],[302,50]]');
    expect(decodeOtherEpisodes('[[301,50],[302,50]]'), shares);
    expect(decodeOtherEpisodes(''), isEmpty);
    expect(decodeOtherEpisodes('not json'), isEmpty);
    expect(decodeOtherEpisodes('[[0,50],["x",1],[303]]'), isEmpty);
    // 问到集信息的份额多带 epno / 播出日 / 三语集名；两种长度同列并存。
    final List<AnidbEpisodeShare> resolved = <AnidbEpisodeShare>[
      AnidbEpisodeShare(
          episodeId: 301,
          percentage: 50,
          episodeNumber: '02',
          airedAt: DateTime.utc(2026, 4, 25),
          englishTitle: 'Ashes',
          romajiTitle: 'Hai',
          kanjiTitle: '灰'),
      const AnidbEpisodeShare(episodeId: 302, percentage: 50),
    ];
    final String encoded = encodeOtherEpisodes(resolved);
    expect(encoded,
        '[[301,50,"02",${DateTime.utc(2026, 4, 25).millisecondsSinceEpoch},"Ashes","Hai","灰"],[302,50]]');
    expect(decodeOtherEpisodes(encoded), resolved);
    expect(decodeOtherEpisodes(encoded).first.isResolved, isTrue);
    expect(decodeOtherEpisodes(encoded).first.airDate, '2026-04-25');
    expect(decodeOtherEpisodes(encoded).first.titles,
        <String>['Ashes', 'Hai', '灰']);
    expect(decodeOtherEpisodes(encoded).last.isResolved, isFalse);
  });

  group('episode air date (Shoko DateAndTitle input via UDP EPISODE)', () {
    final DateTime aired = DateTime.utc(2026, 4, 25);
    AnimeIdentityMapping mapping() => AnimeIdentityMapping(
        httpClient: VideoMetadataHttpClient(
            client: MockClient((_) async =>
                http.Response('[{"anidb_id":2,"mal_id":9}]', 200))));

    AnidbHashIdentityService service(_MemoryStore store,
        {required AnidbEpisodeLookup? episodeLookup}) {
      final AnidbHashIdentityService s = AnidbHashIdentityService(
        enabled: true,
        config: config,
        mapping: mapping(),
        store: store,
        hasher: (String path, {isCancelled, onProgress}) async {
          final FileStat stat = await File(path).stat();
          return AnidbEd2kHash(
              ed2k: 'a',
              size: stat.size,
              modifiedAt: stat.modified,
              changedAt: stat.changed);
        },
        lookup: ({required int size, required String ed2k}) async => identity,
        episodeLookup: episodeLookup,
      );
      addTearDown(s.close);
      return s;
    }

    test('a fresh FILE match asks EPISODE once and persists the air date',
        () async {
      final Directory dir =
          await Directory.systemTemp.createTemp('anidb-aired-');
      addTearDown(() => dir.delete(recursive: true));
      final File file = await File('${dir.path}/video.mkv').writeAsString('a');
      final _MemoryStore store = _MemoryStore();
      final List<int> asked = <int>[];
      final AnidbHashIdentityResult result = await service(store,
          episodeLookup: ({required int episodeId}) async {
        asked.add(episodeId);
        return AnidbEpisodeInfo(
            episodeId: episodeId,
            animeId: 2,
            episodeNumber: 'S1',
            airedAt: aired);
      }).identifyFile(file.path);
      expect(result.status, AnidbHashIdentityStatus.matched);
      expect(asked, <int>[3], reason: '按 FILE 给的 eid 问');
      expect(result.identity?.episodeAiredAt, aired);
      expect(result.identity?.episodeAirDate, '2026-04-25');
      expect(result.episodeInfoError, isNull);
      expect(store.records.single.identity?.episodeAiredAt, aired,
          reason: '落库的身份带播出日，下次不再问');
    });

    test('a stored identity without an air date is backfilled once', () async {
      final Directory dir =
          await Directory.systemTemp.createTemp('anidb-aired-');
      addTearDown(() => dir.delete(recursive: true));
      final File file = await File('${dir.path}/video.mkv').writeAsString('a');
      final _MemoryStore store = _MemoryStore();
      // v109 之前落的行：有身份、无播出日。
      await service(store, episodeLookup: null).identifyFile(file.path);
      expect(store.records.single.identity?.episodeAiredAt, isNull);
      int asked = 0;
      final AnidbHashIdentityService backfilling = service(store,
          episodeLookup: ({required int episodeId}) async {
        asked++;
        return AnidbEpisodeInfo(
            episodeId: episodeId,
            animeId: 2,
            episodeNumber: 'S1',
            airedAt: aired);
      });
      final AnidbHashIdentityResult first =
          await backfilling.identifyFile(file.path);
      expect(first.fromStore, isTrue);
      expect(first.identity?.episodeAiredAt, aired);
      expect(store.records.single.identity?.episodeAiredAt, aired);
      await backfilling.identifyFile(file.path);
      expect(asked, 1, reason: '回填后持久层已有播出日，不再问');
    });

    test('EPISODE failure keeps the identity and reports episodeInfoError',
        () async {
      final Directory dir =
          await Directory.systemTemp.createTemp('anidb-aired-');
      addTearDown(() => dir.delete(recursive: true));
      final File file = await File('${dir.path}/video.mkv').writeAsString('a');
      final _MemoryStore store = _MemoryStore();
      final AnidbHashIdentityResult result = await service(store,
              episodeLookup: ({required int episodeId}) async =>
                  throw const AnidbUdpException(AnidbUdpFailure.timeout))
          .identifyFile(file.path);
      expect(result.status, AnidbHashIdentityStatus.matched,
          reason: '身份来自 FILE，EPISODE 失败不影响身份');
      expect(result.identity?.fileId, 1);
      expect(result.identity?.episodeAiredAt, isNull);
      expect(result.episodeInfoError, isA<AnidbUdpException>());
      expect(store.records.single.identity?.episodeAiredAt, isNull,
          reason: '留 null 让下次 sweep 再补');
    });

    test(
        'other episodes of a multi-episode file get their number / titles / '
        'air date from EPISODE and are persisted (one file, many episodes)',
        () async {
      final Directory dir =
          await Directory.systemTemp.createTemp('anidb-aired-');
      addTearDown(() => dir.delete(recursive: true));
      final File file = await File('${dir.path}/video.mkv').writeAsString('a');
      final _MemoryStore store = _MemoryStore();
      final List<int> asked = <int>[];
      AnidbEpisodeInfo info(int eid) => AnidbEpisodeInfo(
          episodeId: eid,
          animeId: 2,
          episodeNumber: eid == 3 ? '01' : '0${eid - 2}',
          airedAt: aired.add(Duration(days: 7 * (eid - 3))),
          englishTitle: 'Ep $eid',
          romajiTitle: 'Rom $eid',
          kanjiTitle: '');
      final AnidbHashIdentityService s = AnidbHashIdentityService(
        enabled: true,
        config: config,
        mapping: mapping(),
        store: store,
        hasher: (String path, {isCancelled, onProgress}) async {
          final FileStat stat = await File(path).stat();
          return AnidbEd2kHash(
              ed2k: 'a',
              size: stat.size,
              modifiedAt: stat.modified,
              changedAt: stat.changed);
        },
        lookup: ({required int size, required String ed2k}) async =>
            identity.copyWith(otherEpisodes: const <AnidbEpisodeShare>[
          AnidbEpisodeShare(episodeId: 4, percentage: 50),
          AnidbEpisodeShare(episodeId: 5, percentage: 50),
        ]),
        episodeLookup: ({required int episodeId}) async {
          asked.add(episodeId);
          return episodeId == 5 ? null : info(episodeId);
        },
      );
      addTearDown(s.close);
      final AnidbHashIdentityResult result = await s.identifyFile(file.path);
      expect(result.status, AnidbHashIdentityStatus.matched);
      expect(asked, <int>[3, 4, 5], reason: '主集 + 其余每集各问一次');
      final List<AnidbEpisodeShare> shares = result.identity!.otherEpisodes;
      expect(shares.length, 2);
      expect(shares[0].isResolved, isTrue);
      expect(shares[0].episodeNumber, '02');
      expect(shares[0].airDate, '2026-05-02');
      expect(shares[0].titles, <String>['Ep 4', 'Rom 4']);
      expect(shares[1].isResolved, isFalse, reason: '340 → 留待下次再问');
      expect(result.identity!.hasUnresolvedOtherEpisodes, isTrue);
      // 落库的就是补全后的份额；再看一次只补没解出的那一集。
      expect(store.records.single.identity?.otherEpisodes, shares);
      asked.clear();
      await s.identifyFile(file.path);
      expect(asked, <int>[5]);
    });

    test('340 / unknown air date leaves the identity untouched', () async {
      final Directory dir =
          await Directory.systemTemp.createTemp('anidb-aired-');
      addTearDown(() => dir.delete(recursive: true));
      final File file = await File('${dir.path}/video.mkv').writeAsString('a');
      final _MemoryStore store = _MemoryStore();
      final AnidbHashIdentityResult result = await service(store,
              episodeLookup: ({required int episodeId}) async => null)
          .identifyFile(file.path);
      expect(result.status, AnidbHashIdentityStatus.matched);
      expect(result.identity?.episodeAiredAt, isNull);
      expect(result.episodeInfoError, isNull);
    });
  });
}

class _MemoryStore implements AnidbFileIdentityStore {
  final List<AnidbFileIdentityRecord> records = <AnidbFileIdentityRecord>[];

  @override
  Future<AnidbFileIdentityRecord?> findForFile(
          {required String filePath,
          required int size,
          required DateTime modifiedAt}) async =>
      records
          .where((r) =>
              r.filePath == filePath &&
              r.size == size &&
              r.fileModifiedAt == modifiedAt)
          .firstOrNull;

  @override
  Future<AnidbFileIdentityRecord?> findByHash(
          {required String ed2k, required int size}) async =>
      records.where((r) => r.ed2k == ed2k && r.size == size).firstOrNull;

  @override
  Future<void> save(AnidbFileIdentityRecord record) async {
    records.removeWhere((r) => r.ed2k == record.ed2k && r.size == record.size);
    records.add(record);
  }
}
