import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:fushi_engine/media/video/metadata/anidb_ed2k.dart';
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
}
