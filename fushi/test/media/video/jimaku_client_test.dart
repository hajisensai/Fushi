import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/anilist_client.dart';
import 'package:fushi/src/media/video/jimaku_client.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  group('parseAniListSearchResponse', () {
    test('解析 media 列表', () {
      const String body = '''
{"data":{"Page":{"media":[
  {"id":21,"title":{"romaji":"One Piece","english":"One Piece","native":"ワンピース"}},
  {"id":1,"title":{"romaji":"Cowboy Bebop","english":null,"native":"カウボーイビバップ"}}
]}}}''';
      final List<AniListMedia> media = parseAniListSearchResponse(body);
      expect(media, hasLength(2));
      expect(media[0].id, 21);
      expect(media[0].displayTitle, 'One Piece');
      expect(media[1].displayTitle, 'Cowboy Bebop');
    });

    test('displayTitle 优先级 romaji→english→native→id', () {
      expect(const AniListMedia(id: 5, english: 'E', native: 'N').displayTitle,
          'E');
      expect(const AniListMedia(id: 5, native: 'N').displayTitle, 'N');
      expect(const AniListMedia(id: 5).displayTitle, 'AniList #5');
    });

    test('结构不符 / 非法 JSON → 空', () {
      expect(parseAniListSearchResponse('not json'), isEmpty);
      expect(parseAniListSearchResponse('{"data":null}'), isEmpty);
      expect(parseAniListSearchResponse('{"data":{"Page":{"media":"x"}}}'),
          isEmpty);
    });
  });

  group('parseJimakuEntries', () {
    test('解析条目（name 回退 english_name / #id）', () {
      const String body = '''
[{"id":10,"name":"鬼滅の刃","anilist_id":101922},
 {"id":11,"name":"  ","english_name":"Demon Slayer"},
 {"id":12}]''';
      final List<JimakuEntry> entries = parseJimakuEntries(body);
      expect(entries, hasLength(3));
      expect(entries[0].name, '鬼滅の刃');
      expect(entries[0].anilistId, 101922);
      expect(entries[1].name, 'Demon Slayer');
      expect(entries[2].name, '#12');
    });

    test('非数组 / 非法 → 空', () {
      expect(parseJimakuEntries('{}'), isEmpty);
      expect(parseJimakuEntries('garbage'), isEmpty);
    });
  });

  group('parseJimakuFiles + JimakuFile', () {
    test('解析文件，缺 name/url 的跳过', () {
      const String body = '''
[{"name":"ep01.ja.srt","url":"https://x/ep01.srt","size":1234},
 {"name":"ep02.ass","url":"https://x/ep02.ass"},
 {"url":"https://x/no-name"}]''';
      final List<JimakuFile> files = parseJimakuFiles(body);
      expect(files, hasLength(2));
      expect(files[0].name, 'ep01.ja.srt');
      expect(files[0].size, 1234);
      expect(files[1].url, 'https://x/ep02.ass');
    });

    test('extension / isTextSubtitle', () {
      expect(const JimakuFile(name: 'a.SRT', url: 'u').extension, 'srt');
      expect(const JimakuFile(name: 'a.ass', url: 'u').isTextSubtitle, isTrue);
      expect(const JimakuFile(name: 'a.vtt', url: 'u').isTextSubtitle, isTrue);
      expect(const JimakuFile(name: 'a.zip', url: 'u').isTextSubtitle, isFalse);
      expect(const JimakuFile(name: 'noext', url: 'u').extension, '');
    });

    test('BUG-1235 inventory 只统计可解析字幕，并汇总集数、语言与未标集号文件', () {
      final JimakuFileInventory inventory = JimakuFileInventory.fromFiles(
        const <JimakuFile>[
          JimakuFile(name: 'Show S01E01.ja.srt', url: 'u1'),
          JimakuFile(name: 'Show S01E01.zh-cn.ass', url: 'u2'),
          JimakuFile(name: 'Show S01E02.vtt', url: 'u3'),
          JimakuFile(name: 'Show extra.ja.srt', url: 'u4'),
          JimakuFile(name: 'Show S01E03.zip', url: 'u5'),
        ],
      );

      expect(inventory.files, hasLength(4));
      expect(inventory.episodes, <int>{1, 2});
      expect(inventory.languages, <String>{'ja', 'zh'});
      expect(inventory.unlabeledCount, 1);
      expect(inventory.filesForEpisode(1), hasLength(2));
      expect(inventory.filesForEpisode(3), isEmpty);
    });
  });

  group('detectSubtitleLanguage (TODO-674)', () {
    test('倒数第二段语言后缀', () {
      expect(detectSubtitleLanguage('ep01.ja.srt'), 'ja');
      expect(detectSubtitleLanguage('ep01.jpn.ass'), 'ja');
      expect(detectSubtitleLanguage('ep01.zh-CN.ass'), 'zh');
      expect(detectSubtitleLanguage('ep01.chs.srt'), 'zh');
      expect(detectSubtitleLanguage('ep01.cht.srt'), 'zh');
      expect(detectSubtitleLanguage('ep01.en.vtt'), 'en');
      expect(detectSubtitleLanguage('ep01.eng.srt'), 'en');
      expect(detectSubtitleLanguage('ep01.ko.srt'), 'ko');
    });

    test('Netflix 抽轨的 `ja[cc]` / `en[sdh]` 方括号修饰不挡语言识别', () {
      expect(
        detectSubtitleLanguage('私を喰べたい、ひとでなし.S01E01.WEBRip.Netflix.ja[cc].srt'),
        'ja',
      );
      expect(detectSubtitleLanguage('show.S01E01.en[sdh].srt'), 'en');
      // 修饰剥掉后仍不在白名单 → 照旧不猜。
      expect(detectSubtitleLanguage('show.S01E01.fr[cc].srt'), isNull);
    });

    test('方括号 / 圆括号语言标记', () {
      expect(detectSubtitleLanguage('[CHS]some show.srt'), 'zh');
      expect(detectSubtitleLanguage('[JP] show ep01.srt'), 'ja');
      expect(detectSubtitleLanguage('show (ENG).srt'), 'en');
    });

    test('中日韩文字语言标记', () {
      expect(detectSubtitleLanguage('鬼滅の刃 日本語字幕.srt'), 'ja');
      expect(detectSubtitleLanguage('某番 简体中文.ass'), 'zh');
      expect(detectSubtitleLanguage('某番 繁體.ass'), 'zh');
    });

    test('认不出 / 无后缀 → null（保底，绝不猜错）', () {
      expect(detectSubtitleLanguage('ep01.srt'), isNull);
      expect(detectSubtitleLanguage('no-ext'), isNull);
      expect(detectSubtitleLanguage('ep01.fr.srt'), isNull); // 白名单外
      expect(detectSubtitleLanguage('ep01.1080p.srt'), isNull);
    });
  });

  group('buildListFilesUri (TODO-674)', () {
    test('无 episode → 不带 query（向后兼容旧路径）', () {
      final Uri uri = buildListFilesUri('https://jimaku.cc/api', 42);
      expect(uri.toString(), 'https://jimaku.cc/api/entries/42/files');
      expect(uri.queryParameters, isEmpty);
    });

    test('有 episode → 拼 episode=<n>', () {
      final Uri uri =
          buildListFilesUri('https://jimaku.cc/api', 42, episode: 7);
      expect(uri.queryParameters['episode'], '7');
      expect(uri.path, '/api/entries/42/files');
    });
  });

  group('parseSubtitleEpisode（字幕文件名集号解析）', () {
    test('结尾集号带字幕扩展名 + 语言子标签', () {
      // `.srt` 扩展名 + `.ja` 语言子标签都被剥掉后才能命中破折号集号。
      expect(parseSubtitleEpisode('[Group] Show - 12.ja.srt'), 12);
      expect(parseSubtitleEpisode('Show - 05.srt'), 5);
    });

    test('CJK / EP / SxxEyy 前缀集号', () {
      expect(parseSubtitleEpisode('第08話.ass'), 8);
      expect(parseSubtitleEpisode('Show E03.vtt'), 3);
      expect(parseSubtitleEpisode('Show S02E10.zh-cn.ssa'), 10);
    });

    test('认不出集号 → null（不误判系列名里的数字）', () {
      expect(parseSubtitleEpisode('Steins;Gate.srt'), isNull);
      expect(parseSubtitleEpisode('movie.ja.ass'), isNull);
    });

    test('JimakuFile.episode 派生自文件名', () {
      const JimakuFile f =
          JimakuFile(name: 'Bocchi - 07.ja.srt', url: 'https://x/7');
      expect(f.episode, 7);
    });
  });

  group('JimakuClient.searchEntries（AniList id → 文本回退，BUG-1002）', () {
    test('anilist_id 命中 → 直接返回，不再走文本搜', () async {
      final List<String> calls = <String>[];
      final MockClient client = MockClient((http.Request req) async {
        final Map<String, String> p = req.url.queryParameters;
        if (p.containsKey('anilist_id')) {
          calls.add('id:${p['anilist_id']}');
          // 用 utf8 字节构造（贴合线上：body 是服务器 utf8 原始字节，
          // 而 http.Response 的 String 构造无 charset 时按 latin1 编码会毁日文）。
          return http.Response.bytes(
              utf8.encode('[{"id":10,"name":"命中"}]'), 200);
        }
        calls.add('query:${p['query']}');
        return http.Response('[]', 200);
      });
      final JimakuClient jc = JimakuClient(apiKey: 'k', client: client);
      final List<JimakuEntry> entries = await jc.searchEntries(
        anilistId: 21,
        queryFallbacks: <String>['とむとじぇりーごっこ'],
      );
      expect(entries, hasLength(1));
      expect(entries.first.name, '命中');
      expect(calls, <String>['id:21']); // 未回退文本搜
    });

    test('anilist_id 空 → 按序回退文本搜、跳过空串、首个命中即停（复现本 bug）', () async {
      final List<String> calls = <String>[];
      final MockClient client = MockClient((http.Request req) async {
        final Map<String, String> p = req.url.queryParameters;
        if (p.containsKey('anilist_id')) {
          calls.add('id');
          return http.Response('[]', 200); // 条目未挂 AniList id
        }
        calls.add('query:${p['query']}');
        if (p['query'] == 'とむとじぇりーごっこ') {
          return http.Response.bytes(
              utf8.encode('[{"id":7,"name":"字幕在此"}]'), 200);
        }
        return http.Response('[]', 200);
      });
      final JimakuClient jc = JimakuClient(apiKey: 'k', client: client);
      final List<JimakuEntry> entries = await jc.searchEntries(
        anilistId: 999,
        queryFallbacks: <String>['', 'Tom Jerry romaji', 'とむとじぇりーごっこ'],
      );
      expect(entries, hasLength(1));
      expect(entries.first.name, '字幕在此');
      // 空串被跳过；命中后不再尝试后续（此处第 3 个即命中，无第 4 个）。
      expect(
          calls, <String>['id', 'query:Tom Jerry romaji', 'query:とむとじぇりーごっこ']);
    });

    test('anilist_id 与全部文本都空 → 空', () async {
      final MockClient client =
          MockClient((http.Request req) async => http.Response('[]', 200));
      final JimakuClient jc = JimakuClient(apiKey: 'k', client: client);
      expect(
        await jc
            .searchEntries(anilistId: 1, queryFallbacks: <String>['a', 'b']),
        isEmpty,
      );
    });

    test('无 anilistId → 仅按文本回退', () async {
      final MockClient client = MockClient((http.Request req) async {
        if (req.url.queryParameters.containsKey('query')) {
          return http.Response('[{"id":3,"name":"q"}]', 200);
        }
        return http.Response('[]', 200);
      });
      final JimakuClient jc = JimakuClient(apiKey: 'k', client: client);
      final List<JimakuEntry> entries =
          await jc.searchEntries(queryFallbacks: <String>['x']);
      expect(entries.single.name, 'q');
    });
  });

  group('JimakuSearchScope（Live Action 接入）', () {
    test('scope 展开成 anime= 取值序列；all = 两次请求', () {
      expect(jimakuScopeAnimeFlags(JimakuSearchScope.anime), <bool>[true]);
      expect(
          jimakuScopeAnimeFlags(JimakuSearchScope.liveAction), <bool>[false]);
      // 服务端没有「不限分类」取值（anime 是硬相等过滤），故全部 = 两类各查一次。
      expect(jimakuScopeAnimeFlags(JimakuSearchScope.all), <bool>[true, false]);
    });

    test('buildSearchEntriesUri 恒显式拼 anime=，缺省值也不省略', () {
      final Uri anime = buildSearchEntriesUri('https://jimaku.cc/api',
          anime: true, query: 'x');
      expect(anime.queryParameters['anime'], 'true');
      expect(anime.path, '/api/entries/search');

      final Uri live = buildSearchEntriesUri('https://jimaku.cc/api',
          anime: false, query: '半沢直樹');
      expect(live.queryParameters['anime'], 'false');
      expect(live.queryParameters['query'], '半沢直樹');
    });

    test('buildSearchEntriesUri 只拼有值的检索键，空串忽略', () {
      final Uri uri = buildSearchEntriesUri(
        'https://jimaku.cc/api',
        anime: false,
        anilistId: 21,
        tmdbId: '  tv:12345  ',
        query: '   ',
      );
      expect(uri.queryParameters['anilist_id'], '21');
      expect(uri.queryParameters['tmdb_id'], 'tv:12345'); // 已 trim
      expect(uri.queryParameters.containsKey('query'), isFalse);
    });

    test('jimakuTmdbId 按服务端 (tv|movie):(\\d+) 编码', () {
      expect(jimakuTmdbId(movie: false, tmdbId: 12345), 'tv:12345');
      expect(jimakuTmdbId(movie: true, tmdbId: 669204), 'movie:669204');
    });

    test('parseJimakuEntryFlags 解析对象，缺字段/非对象 → false', () {
      final JimakuEntryFlags flags = parseJimakuEntryFlags(<String, Object?>{
        'anime': false,
        'movie': true,
        'adult': false,
      });
      expect(flags.anime, isFalse);
      expect(flags.movie, isTrue);
      expect(flags.unverified, isFalse); // 缺字段
      expect(flags.isLiveAction, isTrue);

      const JimakuEntryFlags empty = JimakuEntryFlags();
      expect(parseJimakuEntryFlags(null).anime, empty.anime);
      expect(parseJimakuEntryFlags(8).movie, isFalse); // 不解析 bitfield 形态
    });

    test('parseJimakuEntries 解析 tmdb_id / japanese_name / flags', () {
      const String body = '''
[{"id":6270,"name":"\\"Kakure Bitch\\" Yattemashita","japanese_name":"かくれビッチやってました",
  "tmdb_id":"movie:669204","flags":{"anime":false,"movie":true,"adult":false,
  "external":false,"unverified":false}}]''';
      final List<JimakuEntry> entries = parseJimakuEntries(body);
      final JimakuEntry entry = entries.single;
      expect(entry.tmdbId, 'movie:669204');
      expect(entry.japaneseName, 'かくれビッチやってました');
      expect(entry.flags.isLiveAction, isTrue);
      expect(entry.flags.movie, isTrue);
    });

    test('name 空时回退 japanese_name（真人条目常无 romaji 名）', () {
      final List<JimakuEntry> entries = parseJimakuEntries(
        '[{"id":9,"name":"","english_name":"","japanese_name":"最愛"}]',
      );
      expect(entries.single.name, '最愛');
    });

    test('scope=liveAction → 请求带 anime=false（真人剧接入的核心守卫）', () async {
      final List<String> seen = <String>[];
      final MockClient client = MockClient((http.Request req) async {
        seen.add(req.url.queryParameters['anime'] ?? '<missing>');
        return http.Response.bytes(
            utf8.encode('[{"id":1,"name":"半沢直樹"}]'), 200);
      });
      final JimakuClient jc = JimakuClient(apiKey: 'k', client: client);
      final List<JimakuEntry> entries = await jc.searchByQuery(
        '半沢直樹',
        scope: JimakuSearchScope.liveAction,
      );
      expect(entries.single.name, '半沢直樹');
      expect(seen, <String>['false']);
    });

    test('默认 scope 仍是 anime=true（不回归旧行为）', () async {
      final List<String> seen = <String>[];
      final MockClient client = MockClient((http.Request req) async {
        seen.add(req.url.queryParameters['anime'] ?? '<missing>');
        return http.Response('[]', 200);
      });
      final JimakuClient jc = JimakuClient(apiKey: 'k', client: client);
      await jc.searchByQuery('frieren');
      await jc.searchByAnilistId(154587);
      expect(seen, <String>['true', 'true']);
    });

    test('scope=all → 两次请求（动画在前）并按 id 去重合并', () async {
      final List<String> seen = <String>[];
      final MockClient client = MockClient((http.Request req) async {
        final String anime = req.url.queryParameters['anime']!;
        seen.add(anime);
        // 两类各返回一条，其中 id=5 重复出现，必须只保留一次。
        return http.Response(
          anime == 'true'
              ? '[{"id":5,"name":"dup"},{"id":1,"name":"a"}]'
              : '[{"id":5,"name":"dup"},{"id":2,"name":"b"}]',
          200,
        );
      });
      final JimakuClient jc = JimakuClient(apiKey: 'k', client: client);
      final List<JimakuEntry> entries =
          await jc.searchByQuery('x', scope: JimakuSearchScope.all);
      expect(seen, <String>['true', 'false']);
      expect(entries.map((JimakuEntry e) => e.id).toList(), <int>[5, 1, 2]);
    });

    test('scope=all 时一类失败不吞掉另一类结果', () async {
      final MockClient client = MockClient((http.Request req) async {
        return req.url.queryParameters['anime'] == 'true'
            ? http.Response('boom', 500)
            : http.Response('[{"id":3,"name":"live"}]', 200);
      });
      final JimakuClient jc = JimakuClient(apiKey: 'k', client: client);
      final List<JimakuEntry> entries =
          await jc.searchByQuery('x', scope: JimakuSearchScope.all);
      expect(entries.single.name, 'live');
    });

    test('searchByTmdbId 默认查两类（分类过滤先于 ID 匹配）', () async {
      final List<String> seen = <String>[];
      final MockClient client = MockClient((http.Request req) async {
        seen.add(
            '${req.url.queryParameters['anime']}:${req.url.queryParameters['tmdb_id']}');
        return http.Response('[]', 200);
      });
      final JimakuClient jc = JimakuClient(apiKey: 'k', client: client);
      await jc.searchByTmdbId('tv:12345');
      expect(seen, <String>['true:tv:12345', 'false:tv:12345']);
    });

    test('searchEntries 在 liveAction 下跳过 anilist_id、按 tmdb → 文本回退', () async {
      final List<String> calls = <String>[];
      final MockClient client = MockClient((http.Request req) async {
        final Map<String, String> p = req.url.queryParameters;
        if (p.containsKey('anilist_id')) {
          calls.add('anilist');
          return http.Response.bytes(
              utf8.encode('[{"id":99,"name":"不该被用到"}]'), 200);
        }
        if (p.containsKey('tmdb_id')) {
          calls.add('tmdb:${p['anime']}');
          return http.Response('[]', 200);
        }
        calls.add('query:${p['query']}:${p['anime']}');
        // 必须走 utf8 字节：http.Response 的 String 构造按 latin1 编码，日文直接炸。
        return http.Response.bytes(utf8.encode('[{"id":4,"name":"最愛"}]'), 200);
      });
      final JimakuClient jc = JimakuClient(apiKey: 'k', client: client);
      final List<JimakuEntry> entries = await jc.searchEntries(
        anilistId: 21,
        tmdbId: 'tv:126991',
        queryFallbacks: <String>['最愛'],
        scope: JimakuSearchScope.liveAction,
      );
      expect(entries.single.name, '最愛');
      // AniList 是动画专属键，真人范围下不得发这个请求。
      expect(calls, <String>['tmdb:false', 'query:最愛:false']);
    });
  });

  group('JimakuClient.listFiles strict availability check', () {
    test('默认保持 fail-open，预检查严格模式保留 HTTP 状态码', () async {
      final JimakuClient jc = JimakuClient(
        apiKey: 'k',
        client: MockClient(
          (http.Request request) async => http.Response('unavailable', 503),
        ),
      );

      expect(await jc.listFiles(42), isEmpty);
      await expectLater(
        jc.listFiles(42, throwOnError: true),
        throwsA(
          isA<JimakuRequestException>().having(
              (JimakuRequestException e) => e.statusCode, 'status', 503),
        ),
      );
    });

    test('BUG-1235 malformed HTTP 200 严格模式报失败，合法 [] 仍是零字幕', () async {
      final JimakuClient malformed = JimakuClient(
        apiKey: 'k',
        client: MockClient(
          (http.Request request) async => http.Response('{not-json', 200),
        ),
      );
      addTearDown(malformed.close);

      // 历史调用保持 fail-open。
      expect(await malformed.listFiles(42), isEmpty);
      // 但库存预检查不能把 malformed 200 冒充成合法空数组。
      await expectLater(
        malformed.listFiles(42, throwOnError: true),
        throwsA(
          isA<JimakuRequestException>().having(
            (JimakuRequestException e) => e.statusCode,
            'status',
            isNull,
          ),
        ),
      );

      final JimakuClient validEmpty = JimakuClient(
        apiKey: 'k',
        client: MockClient(
          (http.Request request) async => http.Response('[]', 200),
        ),
      );
      addTearDown(validEmpty.close);
      expect(
        await validEmpty.listFiles(42, throwOnError: true),
        isEmpty,
      );
    });

    test('strict 模式拒绝缺 name/url 的数组元素，默认模式仍跳过', () async {
      final JimakuClient client = JimakuClient(
        apiKey: 'k',
        client: MockClient(
          (http.Request request) async =>
              http.Response('[{"name":"missing-url"}]', 200),
        ),
      );
      addTearDown(client.close);

      expect(await client.listFiles(42), isEmpty);
      await expectLater(
        client.listFiles(42, throwOnError: true),
        throwsA(isA<JimakuRequestException>()),
      );
    });
  });
}
