import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_engine/media/video/metadata/anime_episode_relations.dart';
import 'package:fushi_engine/media/video/metadata/video_metadata_transport.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

// 真实 anime-relations.txt 片段（2026-08-03 版），含 meta 段、注释与各种语法。
const String _sample = '''
# This file includes anime relation data for Taiga.

::meta

# Do not change this line.
- version: 1.3.0
- last_modified: 2026-08-03

::rules

# Fairy Tail -> ~ (2014) / ~: Final Series
- 6702|4676|6702:176-277 -> 22043|8203|20626:1-102!
- 6702|4676|6702:278-328 -> 35972|13658|99749:1-51!

# Kusuriya no Hitorigoto -> ~ 2nd Season
- 54492|47083|161645:25-48 -> 58514|48649|176301:1-24!

# Oshi no Ko -> ~ 2nd Season
- 52034|46170|150672:12-24 -> 55791|47659|166531:1-13!

# Sousou no Frieren -> ~ 2nd Season
- 52991|46474|154587:29-38 -> 59978|49240|182255:1-10!

# MAL 列未知：整条丢弃
- ?|?|170068:13-18 -> ?|?|189513:1-6!
- ?|?|170068:19-? -> ?|?|206425:1-?!

# 源侧 MAL 已知、AniList 未知：保留
- 52198|46206|?:1-4 -> ~|~|?:1

# ~ 复用源 id、单点规则、第 0 集
- 33820|12478|21898:0 -> ~|~|~:1
- 58749|48796|177175:17-26 -> ~|~|~:1-10

# 开区间
- 100001|?|?:19-? -> 100002|?|?:1-?!

# 歧义：同一源集号被两条规则指向不同目标
- 200001|?|?:13-24 -> 200002|?|?:1-12
- 200001|?|?:20-24 -> 200003|?|?:1-5
''';

void main() {
  late AnimeEpisodeRelations relations;

  setUpAll(() {
    relations = AnimeEpisodeRelations.parse(_sample);
  });

  test('parses rules, skips meta/comments/unknown MAL rows', () {
    // 6702 x2(+2 self) + 54492(+1) + 52034(+1) + 52991(+1) + 52198 + 33820
    // + 58749 + 100001(+1) + 200001 x2 = 17
    expect(relations.ruleCount, 17);
    expect(relations.rulesFor(170068), isEmpty);
    expect(relations.rulesFor(189513), isEmpty);
    expect(relations.rulesFor(206425), isEmpty);
  });

  test('Frieren S1 continuous numbering redirects into S2', () {
    expect(
      relations.redirect(malId: 52991, episode: 29),
      const AnimeEpisodeRedirection(malId: 59978, episode: 1),
    );
    expect(
      relations.redirect(malId: 52991, episode: 38),
      const AnimeEpisodeRedirection(malId: 59978, episode: 10),
    );
    expect(relations.redirect(malId: 52991, episode: 28), isNull);
    expect(relations.redirect(malId: 52991, episode: 39), isNull);
  });

  test('Oshi no Ko and Kusuriya redirect with offset', () {
    expect(
      relations.redirect(malId: 52034, episode: 12),
      const AnimeEpisodeRedirection(malId: 55791, episode: 1),
    );
    expect(
      relations.redirect(malId: 52034, episode: 24),
      const AnimeEpisodeRedirection(malId: 55791, episode: 13),
    );
    expect(
      relations.redirect(malId: 54492, episode: 30),
      const AnimeEpisodeRedirection(malId: 58514, episode: 6),
    );
  });

  test('Fairy Tail two-segment chain picks the segment by episode', () {
    expect(
      relations.redirect(malId: 6702, episode: 176),
      const AnimeEpisodeRedirection(malId: 22043, episode: 1),
    );
    expect(
      relations.redirect(malId: 6702, episode: 277),
      const AnimeEpisodeRedirection(malId: 22043, episode: 102),
    );
    expect(
      relations.redirect(malId: 6702, episode: 278),
      const AnimeEpisodeRedirection(malId: 35972, episode: 1),
    );
    expect(
      relations.redirect(malId: 6702, episode: 328),
      const AnimeEpisodeRedirection(malId: 35972, episode: 51),
    );
    expect(relations.redirect(malId: 6702, episode: 175), isNull);
  });

  test('! suffix adds a destination self-redirect', () {
    expect(
      relations.redirect(malId: 59978, episode: 3),
      const AnimeEpisodeRedirection(malId: 59978, episode: 3),
    );
    expect(relations.redirect(malId: 59978, episode: 11), isNull);
    // 没有 ! 的规则不产生自映射。
    expect(relations.redirect(malId: 200002, episode: 3), isNull);
  });

  test('~ reuses the source MAL id; single-point rules and episode 0', () {
    expect(
      relations.redirect(malId: 33820, episode: 0),
      const AnimeEpisodeRedirection(malId: 33820, episode: 1),
    );
    expect(
      relations.redirect(malId: 58749, episode: 20),
      const AnimeEpisodeRedirection(malId: 58749, episode: 4),
    );
    expect(relations.redirect(malId: 58749, episode: 27), isNull);
  });

  test('single-point destination range applies no offset', () {
    for (int episode = 1; episode <= 4; episode++) {
      expect(
        relations.redirect(malId: 52198, episode: episode),
        const AnimeEpisodeRedirection(malId: 52198, episode: 1),
      );
    }
    expect(relations.redirect(malId: 52198, episode: 5), isNull);
  });

  test('open-ended range redirects without an upper bound', () {
    expect(
      relations.redirect(malId: 100001, episode: 19),
      const AnimeEpisodeRedirection(malId: 100002, episode: 1),
    );
    expect(
      relations.redirect(malId: 100001, episode: 1000),
      const AnimeEpisodeRedirection(malId: 100002, episode: 982),
    );
    expect(relations.redirect(malId: 100001, episode: 18), isNull);
    // 开区间的 ! 自映射同样无上界。
    expect(
      relations.redirect(malId: 100002, episode: 500),
      const AnimeEpisodeRedirection(malId: 100002, episode: 500),
    );
  });

  test('ambiguous hits return null, unambiguous part still resolves', () {
    expect(
      relations.redirect(malId: 200001, episode: 15),
      const AnimeEpisodeRedirection(malId: 200002, episode: 3),
    );
    expect(relations.redirect(malId: 200001, episode: 22), isNull);
  });

  test('unknown ids and negative episodes return null', () {
    expect(relations.redirect(malId: 1, episode: 1), isNull);
    expect(relations.redirect(malId: 52991, episode: -1), isNull);
  });

  test('redirectRange requires both ends on one destination', () {
    expect(
      relations.redirectRange(malId: 52991, start: 29, end: 31),
      (
        start: const AnimeEpisodeRedirection(malId: 59978, episode: 1),
        end: const AnimeEpisodeRedirection(malId: 59978, episode: 3),
      ),
    );
    // 跨越 Fairy Tail 两段：目标 id 不同。
    expect(relations.redirectRange(malId: 6702, start: 276, end: 279), isNull);
    // 一端无规则命中。
    expect(relations.redirectRange(malId: 52991, start: 27, end: 30), isNull);
    // 倒置区间。
    expect(relations.redirectRange(malId: 52991, start: 31, end: 29), isNull);
  });

  test('malformed lines are ignored instead of throwing', () {
    final AnimeEpisodeRelations parsed = AnimeEpisodeRelations.parse('''
- 1|2:3 -> 4|5|6:7
- 1|2|3:3 -> 4|5|6
- 1|2|3:x -> 4|5|6:7
- 1|2|3:9-3 -> 4|5|6:1
- 1|2|3:3 -> 4|5|6:7 -> 8|9|10:11
- ~|2|3:3 -> 4|5|6:7
- 1|2|3:3 -> 4|5|6:7
''');
    expect(parsed.ruleCount, 1);
    expect(
      parsed.redirect(malId: 1, episode: 3),
      const AnimeEpisodeRedirection(malId: 4, episode: 7),
    );
    expect(AnimeEpisodeRelations.parse('').ruleCount, 0);
    expect(AnimeEpisodeRelations.empty.redirect(malId: 1, episode: 1), isNull);
  });

  group('AnimeEpisodeRelationsCatalog', () {
    test('downloads once within TTL and re-downloads after expiry', () async {
      DateTime now = DateTime(2026);
      int calls = 0;
      final AnimeEpisodeRelationsCatalog catalog = AnimeEpisodeRelationsCatalog(
        now: () => now,
        httpClient: VideoMetadataHttpClient(client: MockClient((_) async {
          calls++;
          // 样例含中文注释，走 UTF-8 字节体（String 构造默认按 Latin-1 编码）。
          return http.Response.bytes(utf8.encode(_sample), 200);
        })),
      );
      expect(
        await catalog.redirect(malId: 52991, episode: 30),
        const AnimeEpisodeRedirection(malId: 59978, episode: 2),
      );
      expect((await catalog.load()).ruleCount, 17);
      expect(calls, 1);
      now = now.add(const Duration(hours: 25));
      await catalog.load();
      expect(calls, 2);
      catalog.close();
    });

    test('rejects oversized payloads', () async {
      final AnimeEpisodeRelationsCatalog catalog = AnimeEpisodeRelationsCatalog(
        maxResponseBytes: 32,
        httpClient: VideoMetadataHttpClient(client: MockClient((_) async {
          return http.Response('#' * 33, 200);
        })),
      );
      await expectLater(catalog.load(), throwsFormatException);
      catalog.close();
    });
  });
}
