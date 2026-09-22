// 2026-09-20 第六轮 b：AniDB HTTP anime XML 装配成 Shoko 式资料链——
// MAL 交叉引用（`<resources type="2">` = Shoko CrossRef_AniDB_MAL）、前传关系、
// 逐集多语言集名别名、按 eid 的集信息（供哈希身份服务优先于 UDP EPISODE），
// 以及 `AnimeDoc_{aid}.xml` 落盘缓存（24h 内直接用、过期才远程、远程失败 / 封禁
// 回旧 XML）。
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_engine/media/video/metadata/anidb_ed2k.dart';
import 'package:fushi_engine/media/video/metadata/anidb_hash_identity_service.dart';
import 'package:fushi_engine/media/video/metadata/anidb_title_catalog.dart';
import 'package:fushi_engine/media/video/metadata/anidb_udp_file_client.dart';
import 'package:fushi_engine/media/video/metadata/anidb_video_metadata_provider.dart';
import 'package:fushi_engine/media/video/metadata/anime_identity_mapping.dart';
import 'package:fushi_engine/media/video/metadata/video_metadata_models.dart';
import 'package:fushi_engine/media/video/metadata/video_metadata_provider.dart';
import 'package:fushi_engine/media/video/metadata/video_metadata_transport.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path/path.dart' as p;

void main() {
  const VideoMetadataLookup lookup = VideoMetadataLookup(
    provider: VideoMetadataProviderKind.anidb,
    externalId: '42',
    mediaKind: VideoMetadataMediaKind.tv,
  );

  // 标题目录显式注入：默认的共享目录会去解析 app 支持目录（需要平台绑定）。
  late Directory catalogDirectory;
  late AniDbTitleCatalog catalog;
  setUp(() async {
    catalogDirectory =
        await Directory.systemTemp.createTemp('fushi-anidb-catalog-');
    catalog = AniDbTitleCatalog(
      cacheDirectory: catalogDirectory,
      client: MockClient((_) async =>
          http.Response.bytes(gzip.encode(utf8.encode(_titleCatalogXml)), 200)),
    );
  });
  tearDown(() async {
    catalog.close();
    await catalogDirectory.delete(recursive: true);
  });

  AniDbVideoMetadataProvider provider({
    required Future<http.Response> Function(http.Request) handler,
    Directory? cacheDirectory,
    DateTime Function()? now,
  }) {
    final AniDbVideoMetadataProvider result = AniDbVideoMetadataProvider(
      clientName: 'fushitest',
      clientVersion: 1,
      language: 'zh-CN',
      titleCatalog: catalog,
      client: MockClient(handler),
      now: now,
      sleep: (Duration _) async {},
      xmlCacheDirectory:
          cacheDirectory == null ? null : () async => cacheDirectory,
    );
    addTearDown(result.close);
    return result;
  }

  http.Response xml(String body) => http.Response.bytes(
        utf8.encode(body),
        200,
        headers: const <String, String>{'content-type': 'application/xml'},
      );

  test('MAL ids from <resources type="2"> become non-default cross references',
      () async {
    final AniDbVideoMetadataProvider anidb =
        provider(handler: (_) async => xml(_animeXml));
    final VideoMetadataWork work = (await anidb.fetchWork(lookup))!;
    expect(
      work.ids
          .where((VideoMetadataId id) => id.type == 'mal')
          .map((VideoMetadataId id) => '${id.value}:${id.isDefault}'),
      <String>['21827:false'],
      reason: 'AniDB 自己登记的 MAL 条目只是交叉引用，不是主身份',
    );
    expect(
      work.ids.singleWhere((VideoMetadataId id) => id.type == 'anidb'),
      const VideoMetadataId(type: 'anidb', value: '42', isDefault: true),
    );
    // type 1（ANN）/ 其它资源类型不当 MAL。
    expect(work.ids.where((VideoMetadataId id) => id.value == '9999'), isEmpty);
  });

  test('prequels come from <relatedanime type="Prequel"> only', () async {
    final AniDbVideoMetadataProvider anidb =
        provider(handler: (_) async => xml(_animeXml));
    final List<VideoMetadataLookup> prequels =
        await anidb.fetchPrequels(lookup);
    expect(
        prequels.map((VideoMetadataLookup l) => l.externalId), <String>['41']);
    expect(prequels.single.provider, VideoMetadataProviderKind.anidb);
    expect(prequels.single.mediaKind, VideoMetadataMediaKind.tv);
  });

  test('episode title aliases carry every language per episode number',
      () async {
    final AniDbVideoMetadataProvider anidb =
        provider(handler: (_) async => xml(_animeXml));
    final Map<int, List<String>> regular =
        await anidb.fetchEpisodeTitleAliases(lookup, seasonNumber: 1);
    expect(regular.keys, <int>[1, 2]);
    expect(
      regular[1],
      containsAll(<String>[
        'Not a Tool',
        '「愛してる」と自動手記人形',
        'Aishiteru to Jidou Shuki Ningyou'
      ]),
    );
    final Map<int, List<String>> specials =
        await anidb.fetchEpisodeTitleAliases(lookup, seasonNumber: 0);
    expect(specials, <int, List<String>>{
      1: <String>['Special']
    });
    expect(
        await anidb.fetchEpisodeTitleAliases(lookup, seasonNumber: 2), isEmpty);
  });

  test('episodeInfo answers from the anime XML in UDP EPISODE shape', () async {
    int calls = 0;
    final AniDbVideoMetadataProvider anidb = provider(handler: (_) async {
      calls++;
      return xml(_animeXml);
    });
    final AnidbEpisodeInfo regular =
        (await anidb.episodeInfo(animeId: 42, episodeId: 4201))!;
    expect(regular.episodeNumber, '1');
    expect(regular.airedAt, DateTime.utc(2018, 1, 11));
    expect(regular.englishTitle, 'Not a Tool');
    expect(regular.romajiTitle, 'Aishiteru to Jidou Shuki Ningyou');
    expect(regular.kanjiTitle, '「愛してる」と自動手記人形');
    final AnidbEpisodeInfo special =
        (await anidb.episodeInfo(animeId: 42, episodeId: 4299))!;
    expect(special.episodeNumber, 'S1', reason: '特典走 S 型集号');
    expect(special.airedAt, isNull);
    expect(await anidb.episodeInfo(animeId: 42, episodeId: 1), isNull,
        reason: '不在这部作品里的 eid → null，交给 UDP');
    expect(calls, 1, reason: '整部作品一次请求，集信息都从同一份 XML 取');
  });

  // BUG-2623：`<error code="302">client version missing or invalid</error>` 是
  // AniDB 在说「这对身份不是 HTTP API 客户端」。换 aid 再问答案也一样——闩住这对
  // 身份、不再发请求，并把服务端原话交给调用方，而不是每部作品都吞成一句
  // 「HTTP 详情不可用」再撞一次 3s 限流闸。
  test('a 302 client identity rejection latches the identity and is reported',
      () async {
    int calls = 0;
    final AniDbVideoMetadataProvider anidb = provider(handler: (_) async {
      calls++;
      return xml('<error code="302">client version missing or invalid</error>');
    });
    expect(anidb.isHttpApiAvailable, isTrue);
    expect(anidb.httpIdentityRejection, isNull);

    final VideoMetadataWork work = (await anidb.fetchWork(lookup))!;
    expect(
      work.rawPayload?[AniDbVideoMetadataProvider.catalogOnlyPayloadKey],
      isTrue,
      reason: '作品层回落标题目录',
    );
    expect(calls, 1);
    expect(anidb.httpIdentityRejection,
        contains('client version missing or invalid'));
    expect(anidb.isHttpApiAvailable, isFalse);
    expect(
      anidb.httpDetailUnavailableReason,
      allOf(contains('fushitest/1'), contains('302'),
          contains('client version missing or invalid')),
    );

    // 同一部 / 集层 / 季层再问：一次请求都不再发。
    expect(
      (await anidb.fetchWork(lookup))!
          .rawPayload?[AniDbVideoMetadataProvider.catalogOnlyPayloadKey],
      isTrue,
    );
    expect(await anidb.fetchSeasons(lookup), hasLength(1),
        reason: '标题目录兜底出一季摘要');
    await expectLater(
      anidb.fetchEpisodes(lookup, seasonNumber: 1),
      throwsA(isA<VideoMetadataNetworkException>()),
    );
    expect(await anidb.episodeInfo(animeId: 42, episodeId: 4201), isNull);
    expect(calls, 1, reason: '身份被拒后不再撞 httpapi');
  });

  test('a transport failure is reported as the detail-unavailable reason',
      () async {
    final AniDbVideoMetadataProvider anidb =
        provider(handler: (_) async => throw const SocketException('offline'));
    expect(
      (await anidb.fetchWork(lookup))!
          .rawPayload?[AniDbVideoMetadataProvider.catalogOnlyPayloadKey],
      isTrue,
    );
    expect(anidb.isHttpApiAvailable, isTrue, reason: '网络故障不是身份问题');
    expect(anidb.httpIdentityRejection, isNull);
    expect(anidb.httpDetailUnavailableReason, contains('anime XML 请求失败'));
  });

  group('AnimeDoc_{aid}.xml disk cache', () {
    late Directory dir;
    setUp(() async {
      dir = await Directory.systemTemp.createTemp('fushi-anidb-xml-');
    });
    tearDown(() => dir.delete(recursive: true));

    File cacheFile() => File(p.join(dir.path, 'AnimeDoc_42.xml'));

    test('download writes the XML and a fresh file is served without HTTP',
        () async {
      int calls = 0;
      final AniDbVideoMetadataProvider first = provider(
        cacheDirectory: dir,
        handler: (_) async {
          calls++;
          return xml(_animeXml);
        },
      );
      expect((await first.fetchWork(lookup))!.title, '紫罗兰永恒花园');
      expect(calls, 1);
      expect(await cacheFile().exists(), isTrue);
      expect(await cacheFile().readAsString(), _animeXml);

      // 新 provider 实例（内存缓存为空）：磁盘 XML 未过 24h → 不发请求。
      int secondCalls = 0;
      final AniDbVideoMetadataProvider second = provider(
        cacheDirectory: dir,
        handler: (_) async {
          secondCalls++;
          return xml(_animeXml);
        },
      );
      expect((await second.fetchWork(lookup))!.title, '紫罗兰永恒花园');
      expect(secondCalls, 0);
    });

    test('a stale file is re-downloaded, and kept when the download fails',
        () async {
      await cacheFile().writeAsString(_animeXml.replaceFirst(
          '<title type="official" xml:lang="zh-Hans">紫罗兰永恒花园</title>',
          '<title type="official" xml:lang="zh-Hans">旧缓存标题</title>'));
      await cacheFile()
          .setLastModified(DateTime.now().subtract(const Duration(hours: 25)));

      // 远程失败 → 用旧 XML。
      int failingCalls = 0;
      final AniDbVideoMetadataProvider failing = provider(
        cacheDirectory: dir,
        handler: (_) async {
          failingCalls++;
          throw const SocketException('offline');
        },
      );
      expect((await failing.fetchWork(lookup))!.title, '旧缓存标题');
      expect(failingCalls, 1, reason: '过期就该重下，只是失败后回旧');

      // 远程成功 → 新 XML 覆盖磁盘。
      final AniDbVideoMetadataProvider ok = provider(
        cacheDirectory: dir,
        handler: (_) async => xml(_animeXml),
      );
      expect((await ok.fetchWork(lookup))!.title, '紫罗兰永恒花园');
      expect(await cacheFile().readAsString(), _animeXml);
    });

    test('a ban reply falls back to the stale XML instead of failing',
        () async {
      await cacheFile().writeAsString(_animeXml);
      await cacheFile()
          .setLastModified(DateTime.now().subtract(const Duration(hours: 25)));
      final AniDbVideoMetadataProvider banned = provider(
        cacheDirectory: dir,
        handler: (_) async => xml('<error>banned</error>'),
      );
      expect((await banned.fetchWork(lookup))!.title, '紫罗兰永恒花园');
    });

    test('without any cache a network failure still surfaces', () async {
      final AniDbVideoMetadataProvider failing = provider(
        cacheDirectory: dir,
        handler: (_) async => throw const SocketException('offline'),
      );
      // 作品层回落标题目录（catalog-only），集层没有兜底就抛网络异常。
      final VideoMetadataWork catalogOnly = (await failing.fetchWork(lookup))!;
      expect(
        catalogOnly
            .rawPayload?[AniDbVideoMetadataProvider.catalogOnlyPayloadKey],
        isTrue,
      );
      await expectLater(
        failing.fetchEpisodes(lookup, seasonNumber: 1),
        throwsA(isA<VideoMetadataNetworkException>()),
      );
      expect(await cacheFile().exists(), isFalse);
    });
  });

  group('AnidbHashIdentityService prefers the XML episode source', () {
    late Directory dir;
    late File video;
    setUp(() async {
      dir = await Directory.systemTemp.createTemp('fushi-anidb-xmlfirst-');
      video = await File(p.join(dir.path, 'show.mkv')).writeAsString('a');
    });
    tearDown(() => dir.delete(recursive: true));

    const AnidbFileIdentity identity = AnidbFileIdentity(
      fileId: 200,
      animeId: 42,
      episodeId: 4201,
      episodeNumber: '1',
      romajiTitle: 'Violet Evergarden',
      kanjiTitle: '',
      englishTitle: '',
      episodeTitle: '',
      episodeRomajiTitle: '',
      episodeKanjiTitle: '',
    );

    AnidbHashIdentityService service({
      required AnidbEpisodeLookup udp,
      required AnidbEpisodeInfoSource xml,
    }) {
      final AnidbHashIdentityService result = AnidbHashIdentityService(
        enabled: true,
        config: const AnidbUdpConfig(
          clientName: 'fushitest',
          clientVersion: 1,
          username: 'u',
          password: 'p',
        ),
        mapping: AnimeIdentityMapping(
          httpClient: VideoMetadataHttpClient(
            client: MockClient((_) async => http.Response('[]', 200)),
          ),
        ),
        hasher: (String path, {isCancelled, onProgress}) async {
          final FileStat stat = await File(path).stat();
          return AnidbEd2kHash(
            ed2k: '0123456789abcdef0123456789abcdef',
            size: stat.size,
            modifiedAt: stat.modified,
            changedAt: stat.changed,
          );
        },
        lookup: ({required int size, required String ed2k}) async => identity,
        episodeLookup: udp,
        episodeInfoSource: xml,
      );
      addTearDown(result.close);
      return result;
    }

    test('XML answers first; UDP EPISODE is only the fallback', () async {
      int udpCalls = 0;
      int xmlCalls = 0;
      final AnidbHashIdentityService svc = service(
        udp: ({required int episodeId}) async {
          udpCalls++;
          return AnidbEpisodeInfo(
            episodeId: episodeId,
            animeId: 42,
            episodeNumber: '1',
            airedAt: DateTime.utc(2000, 1, 1),
          );
        },
        xml: ({required int animeId, required int episodeId}) async {
          xmlCalls++;
          expect(animeId, 42);
          expect(episodeId, 4201);
          return AnidbEpisodeInfo(
            episodeId: episodeId,
            animeId: animeId,
            episodeNumber: '1',
            airedAt: DateTime.utc(2018, 1, 11),
          );
        },
      );
      final AnidbHashIdentityResult result = await svc.identifyFile(video.path);
      expect(result.status, AnidbHashIdentityStatus.matched);
      expect(result.identity!.episodeAiredAt, DateTime.utc(2018, 1, 11));
      expect(xmlCalls, 1);
      expect(udpCalls, 0);
    });

    test('XML miss or failure falls through to UDP', () async {
      int udpCalls = 0;
      int xmlCalls = 0;
      final AnidbHashIdentityService svc = service(
        udp: ({required int episodeId}) async {
          udpCalls++;
          return AnidbEpisodeInfo(
            episodeId: episodeId,
            animeId: 42,
            episodeNumber: '1',
            airedAt: DateTime.utc(2018, 1, 11),
          );
        },
        xml: ({required int animeId, required int episodeId}) async {
          xmlCalls++;
          if (xmlCalls == 1) return null;
          throw const VideoMetadataNetworkException('AniDB HTTP down');
        },
      );
      for (int i = 0; i < 2; i++) {
        // 每次换个文件，绕开服务内的哈希 / 身份缓存。
        final File file =
            await File(p.join(dir.path, 'show-$i.mkv')).writeAsString('a$i');
        final AnidbHashIdentityResult result =
            await svc.identifyFile(file.path);
        expect(result.status, AnidbHashIdentityStatus.matched);
        expect(result.identity!.episodeAiredAt, DateTime.utc(2018, 1, 11));
      }
      expect(xmlCalls, 2);
      expect(udpCalls, 2, reason: 'XML 空 / 抛错各一次都退到 UDP');
    });
  });
}

const String _animeXml = '''
<?xml version="1.0" encoding="UTF-8"?>
<anime id="42" restricted="false">
  <type>TV Series</type>
  <episodecount>2</episodecount>
  <startdate>2018-01-11</startdate>
  <enddate>2018-04-05</enddate>
  <titles>
    <title type="main" xml:lang="x-jat">Violet Evergarden</title>
    <title type="official" xml:lang="ja">ヴァイオレット・エヴァーガーデン</title>
    <title type="official" xml:lang="zh-Hans">紫罗兰永恒花园</title>
  </titles>
  <relatedanime>
    <anime id="41" type="Prequel">Violet Evergarden: Kitto "Ai" o Shiru Hi ga Kuru no Darou</anime>
    <anime id="43" type="Sequel">Violet Evergarden Gaiden</anime>
    <anime id="44" type="Side Story">Violet Evergarden Movie</anime>
  </relatedanime>
  <resources>
    <resource type="1">
      <externalentity><identifier>9999</identifier></externalentity>
    </resource>
    <resource type="2">
      <externalentity><identifier>21827</identifier></externalentity>
    </resource>
    <resource type="4">
      <externalentity><url>https://example.test/</url></externalentity>
    </resource>
  </resources>
  <episodes>
    <episode id="4201">
      <epno type="1">1</epno>
      <length>24</length>
      <airdate>2018-01-11</airdate>
      <title xml:lang="en">Not a Tool</title>
      <title xml:lang="x-jat">Aishiteru to Jidou Shuki Ningyou</title>
      <title xml:lang="ja">「愛してる」と自動手記人形</title>
    </episode>
    <episode id="4202">
      <epno type="1">2</epno>
      <length>24</length>
      <airdate>2018-01-18</airdate>
      <title xml:lang="en">Never Coming Back</title>
    </episode>
    <episode id="4299">
      <epno type="2">S1</epno>
      <title xml:lang="en">Special</title>
    </episode>
  </episodes>
</anime>
''';

const String _titleCatalogXml = '''
<?xml version="1.0" encoding="UTF-8"?>
<animetitles>
  <anime aid="42">
    <title type="main" xml:lang="x-jat">Violet Evergarden</title>
  </anime>
</animetitles>
''';
