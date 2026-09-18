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
      now = now.add(const Duration(days: 6));
      final AnidbHashIdentityResult fresh =
          await make().identifyFile(file.path);
      expect(fresh.status, AnidbHashIdentityStatus.notFound);
      expect(fresh.fromStore, isTrue);
      expect(lookups, 1);
      now = now.add(const Duration(days: 2));
      expect((await make().identifyFile(file.path)).fromStore, isFalse);
      expect(lookups, 2, reason: '过了复查期再问一次 AniDB');
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
