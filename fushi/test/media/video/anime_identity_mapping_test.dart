import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:fushi/src/media/video/metadata/anime_identity_mapping.dart';
import 'package:fushi/src/media/video/metadata/video_metadata_transport.dart';

// Fribb anime-list-full.json 的**实测**形状（2026-09-08 抓真文件核对，39304 行）：
// `themoviedb_id` 恒为对象 `{"tv": N}`（7092 行）或 `{"movie": [N]}`（1363 行，
// movie 侧的值是数组），从不是裸数字；TVDB 键是 `tvdb_id` 而不是 `thetvdb_id`
// （后者零命中）。用错形状会让 tmdbId / tvdbId 恒为 null，多季对齐与 id 接力
// 静默失效——本 fixture 照真数据写，别再改回裸数字。
const String _fribbSample = '[' // Frieren S1
    '{"anidb_id":17617,"mal_id":52991,"anilist_id":154587,"tvdb_id":424536,'
    '"themoviedb_id":{"tv":209867},"season":{"tvdb":1,"tmdb":1},"type":"TV"},'
    // Frieren S2：tmdb 同剧、偏移 28；字符串数字（旧文件里出现过）
    '{"anidb_id":18886,"mal_id":"59978","anilist_id":182255,"tvdb_id":"424536",'
    '"themoviedb_id":{"tv":"209867"},"season":{"tvdb":2,"tmdb":"1"},'
    '"episode_offset":{"tmdb":"28"},"type":"TV"},'
    // 特典：同 tmdb 剧、无偏移字段、season 0
    '{"anidb_id":19000,"mal_id":59978,"themoviedb_id":{"tv":209867},'
    '"season":{"tvdb":0,"tmdb":0},"type":"SPECIAL"},'
    // 电影：movie 命名空间且值是数组，不进 tv 索引
    '{"anidb_id":20000,"mal_id":70000,"themoviedb_id":{"movie":[128]},'
    '"type":"MOVIE"},'
    // 电影但 type 缺失：命名空间本身就足以判定，不能按 tv 拉
    '{"anidb_id":20001,"mal_id":70001,"themoviedb_id":{"movie":[129]}},'
    // 脏值：负 id、小数、乱字符串、season 不是对象、空数组
    '{"anidb_id":30000,"mal_id":-1,"anilist_id":2.5,"tvdb_id":"abc",'
    '"themoviedb_id":{"tv":0,"movie":[]},"season":"x",'
    '"episode_offset":{"tmdb":-3},"type":""},'
    // 非对象行
    '42,null'
    ']';

AnimeIdentityMapping _mapping(String body, {void Function()? onCall}) {
  return AnimeIdentityMapping(
    httpClient: VideoMetadataHttpClient(client: MockClient((_) async {
      onCall?.call();
      return http.Response(body, 200);
    })),
  );
}

void main() {
  test('duplicate rows collapse, conflicting MAL IDs are not auto-selected',
      () async {
    int calls = 0;
    final AnimeIdentityMapping mapping = AnimeIdentityMapping(
      httpClient: VideoMetadataHttpClient(client: MockClient((_) async {
        calls++;
        return http.Response(
            '[{"anidb_id":1,"mal_id":2},{"anidb_id":1,"mal_id":"2"},'
            '{"anidb_id":3,"mal_id":4},{"anidb_id":3,"mal_id":5},'
            '{"anidb_id":1,"mal_id":0},{"anidb_id":1,"mal_id":2.5}]',
            200);
      })),
    );
    expect((await mapping.lookupAnidb(1)).confirmedMalId, 2);
    final AnimeIdentityMappingResult ambiguous = await mapping.lookupAnidb(3);
    expect(ambiguous.isAmbiguous, isTrue);
    expect(ambiguous.confirmedMalId, isNull);
    expect((await mapping.lookupAnidb(6)).confirmedMalId, isNull);
    expect(calls, 1);
  });

  test('expires catalog and rejects oversized or malformed catalog', () async {
    DateTime now = DateTime(2026);
    int calls = 0;
    final AnimeIdentityMapping mapping = AnimeIdentityMapping(
      now: () => now,
      maxResponseBytes: 64,
      httpClient: VideoMetadataHttpClient(client: MockClient((_) async {
        calls++;
        return http.Response(calls == 1 ? '[]' : 'x' * 65, 200);
      })),
    );
    await mapping.lookupAnidb(1);
    now = now.add(const Duration(days: 2));
    await expectLater(mapping.lookupAnidb(1), throwsFormatException);
    expect(calls, 2);
  });

  test('entryForAnidb exposes cross-service ids, season and episode offset',
      () async {
    int calls = 0;
    final AnimeIdentityMapping mapping =
        _mapping(_fribbSample, onCall: () => calls++);

    final AnimeIdentityEntry? s1 = await mapping.entryForAnidb(17617);
    expect(s1, isNotNull);
    expect(s1!.malIds, <int>{52991});
    expect(s1.anilistId, 154587);
    expect(s1.tvdbId, 424536);
    expect(s1.tmdbId, 209867);
    expect(s1.tmdbSeason, 1);
    expect(s1.tvdbSeason, 1);
    expect(s1.tmdbEpisodeOffset, isNull);
    expect(s1.tvdbEpisodeOffset, isNull);
    expect(s1.type, 'TV');
    expect(s1.isMovie, isFalse);

    // 字符串数字照样解析。
    final AnimeIdentityEntry? s2 = await mapping.entryForAnidb(18886);
    expect(s2!.malIds, <int>{59978});
    expect(s2.tvdbId, 424536);
    expect(s2.tmdbId, 209867);
    expect(s2.tmdbSeason, 1);
    expect(s2.tvdbSeason, 2);
    expect(s2.tmdbEpisodeOffset, 28);

    // season 0 是合法值（TVDB specials）。
    final AnimeIdentityEntry? special = await mapping.entryForAnidb(19000);
    expect(special!.tmdbSeason, 0);
    expect(special.tvdbSeason, 0);

    // 脏值静默跳过，条目本身仍存在。
    final AnimeIdentityEntry? dirty = await mapping.entryForAnidb(30000);
    expect(dirty, isNotNull);
    expect(dirty!.malIds, isEmpty);
    expect(dirty.anilistId, isNull);
    expect(dirty.tvdbId, isNull);
    expect(dirty.tmdbId, isNull);
    expect(dirty.tmdbSeason, isNull);
    expect(dirty.tmdbEpisodeOffset, isNull);
    expect(dirty.type, isNull);

    // `themoviedb_id.movie` 是数组，取首个正整数；命名空间本身判定 isMovie，
    // 即便 type 缺失也不能按 /tv/{id} 拉。
    final AnimeIdentityEntry? movie = await mapping.entryForAnidb(20000);
    expect(movie!.tmdbId, 128);
    expect(movie.isMovie, isTrue);
    final AnimeIdentityEntry? movieNoType = await mapping.entryForAnidb(20001);
    expect(movieNoType!.tmdbId, 129);
    expect(movieNoType.type, isNull);
    expect(movieNoType.isMovie, isTrue, reason: 'movie 命名空间优先于缺失的 type 字段');

    expect(await mapping.entryForAnidb(99999), isNull);
    expect(() => mapping.entryForAnidb(0), throwsArgumentError);
    // lookupAnidb 与 entryForAnidb 共用一份缓存。
    expect((await mapping.lookupAnidb(17617)).confirmedMalId, 52991);
    expect(calls, 1);
  });

  test('entriesForMal is a reverse index that keeps every AniDB entry',
      () async {
    final AnimeIdentityMapping mapping = _mapping(_fribbSample);
    final List<AnimeIdentityEntry> entries = await mapping.entriesForMal(59978);
    expect(
      entries.map((AnimeIdentityEntry e) => e.anidbId).toList(),
      <int>[18886, 19000],
    );
    expect(await mapping.entriesForMal(1), isEmpty);
    expect(() => mapping.entriesForMal(-5), throwsArgumentError);
  });

  test('entriesForTmdbTv lists tv seasons by episode offset and skips movies',
      () async {
    final AnimeIdentityMapping mapping = _mapping(_fribbSample);
    final List<AnimeIdentityEntry> entries =
        await mapping.entriesForTmdbTv(209867);
    expect(
      entries.map((AnimeIdentityEntry e) => e.anidbId).toList(),
      <int>[19000, 17617, 18886],
    );
    expect(
      entries.map((AnimeIdentityEntry e) => e.tmdbEpisodeOffset).toList(),
      <int?>[null, null, 28],
    );
    expect(entries.any((AnimeIdentityEntry e) => e.isMovie), isFalse);
    expect(await mapping.entriesForTmdbTv(1), isEmpty);
    expect(() => mapping.entriesForTmdbTv(0), throwsArgumentError);
  });
}
