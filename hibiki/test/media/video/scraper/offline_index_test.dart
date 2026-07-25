import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/media/video/scraper/offline_index.dart';
import 'package:hibiki/src/media/video/scraper/scraper_types.dart';

void main() {
  late String fixtureText;
  late List<OfflineAnimeRecord> records;
  late OfflineIndex index;

  setUpAll(() {
    fixtureText = File(
      'test/media/video/scraper/fixtures/offline_db_fixture.json',
    ).readAsStringSync();
    records = OfflineIndex.parseDatabaseJson(fixtureText);
    index = OfflineIndex(records);
  });

  group('parseDatabaseJson', () {
    test('解析出全部有海报条目，跳过无/空 picture 条目', () {
      expect(records.length, 12);
      final Iterable<String> titles =
          records.map((OfflineAnimeRecord r) => r.title);
      expect(titles, isNot(contains('No Picture Show')));
      expect(titles, isNot(contains('Empty Picture Show')));
    });

    test('字段映射正确（Mushoku Tensei 第一季）', () {
      final OfflineAnimeRecord mushoku = records.firstWhere(
        (OfflineAnimeRecord r) =>
            r.title == 'Mushoku Tensei: Isekai Ittara Honki Dasu',
      );
      expect(mushoku.type, ScrapeEntryType.tv);
      expect(mushoku.year, 2021);
      expect(mushoku.episodes, 11);
      expect(mushoku.sourceId, 'myanimelist.net/anime/39535');
      expect(mushoku.picture, startsWith('https://'));
      expect(mushoku.synonyms, contains('无职转生～到了异世界就拿出真本事～'));
    });

    test('类型映射：MOVIE/OVA/SPECIAL/ONA/UNKNOWN', () {
      ScrapeEntryType typeOf(String title) =>
          records.firstWhere((OfflineAnimeRecord r) => r.title == title).type;
      expect(typeOf('Kimi no Na wa.'), ScrapeEntryType.movie);
      expect(typeOf('Hellsing Ultimate'), ScrapeEntryType.ova);
      expect(typeOf('Steins;Gate: Kyoukaimenjou no Missing Link'),
          ScrapeEntryType.special);
      // ONA 契约无对应值，归入 tv。
      expect(typeOf('Cyberpunk: Edgerunners'), ScrapeEntryType.tv);
      expect(typeOf('Mystery Pilot'), ScrapeEntryType.unknown);
    });

    test('缺 sources/animeSeason/episodes 的条目容忍为 null/退化 id', () {
      final OfflineAnimeRecord pilot = records.firstWhere(
        (OfflineAnimeRecord r) => r.title == 'Mystery Pilot',
      );
      expect(pilot.year, isNull);
      expect(pilot.episodes, isNull);
      expect(pilot.sourceId, 'Mystery Pilot');
    });

    test('顶层结构不对抛 FormatException', () {
      expect(() => OfflineIndex.parseDatabaseJson('[]'), throwsFormatException);
      expect(() => OfflineIndex.parseDatabaseJson('{"nope": 1}'),
          throwsFormatException);
    });
  });

  group('slim 序列化', () {
    test('encode/decode roundtrip 保留全部字段', () {
      final String slim = OfflineIndex.encodeSlim(records);
      final List<OfflineAnimeRecord> decoded = OfflineIndex.decodeSlim(slim);
      expect(decoded.length, records.length);
      for (int i = 0; i < records.length; i++) {
        expect(decoded[i].title, records[i].title);
        expect(decoded[i].synonyms, records[i].synonyms);
        expect(decoded[i].type, records[i].type);
        expect(decoded[i].episodes, records[i].episodes);
        expect(decoded[i].year, records[i].year);
        expect(decoded[i].picture, records[i].picture);
        expect(decoded[i].sourceId, records[i].sourceId);
      }
    });

    test('坏 slim 缓存抛 FormatException', () {
      expect(() => OfflineIndex.decodeSlim('{"v": 999, "d": []}'),
          throwsFormatException);
      expect(() => OfflineIndex.decodeSlim('garbage'), throwsFormatException);
    });
  });

  group('OfflineIndex.search', () {
    test('中文查询命中罗马字主标题条目', () {
      final List<ScrapeCandidate> results = index.search('无职转生');
      expect(results, isNotEmpty);
      final Iterable<String> topTitles =
          results.take(2).map((ScrapeCandidate c) => c.title);
      expect(
        topTitles.where((String t) => t.startsWith('Mushoku Tensei')),
        hasLength(2),
        reason: '同系列两季都应进 top2',
      );
    });

    test('罗马字查询命中，同系列多季都在 topN', () {
      final List<ScrapeCandidate> results = index.search('Mushoku Tensei');
      expect(results, isNotEmpty);
      final Iterable<String> titles =
          results.map((ScrapeCandidate c) => c.title);
      expect(titles, contains('Mushoku Tensei: Isekai Ittara Honki Dasu'));
      expect(titles, contains('Mushoku Tensei II: Isekai Ittara Honki Dasu'));
    });

    test('带季度中文别名查询时正确季条目排第一', () {
      final List<ScrapeCandidate> results = index.search('无职转生 第二季');
      expect(
          results.first.title, 'Mushoku Tensei II: Isekai Ittara Honki Dasu');
    });

    test('中文别名精确命中排第一（电影/TV 同系列并存）', () {
      final List<ScrapeCandidate> results = index.search('紫罗兰永恒花园');
      expect(results.first.title, 'Violet Evergarden');
      final Iterable<String> titles =
          results.map((ScrapeCandidate c) => c.title);
      expect(titles, contains('Violet Evergarden Movie'));
    });

    test('候选转换字段正确（source/poster/detailUrl/type）', () {
      final ScrapeCandidate kimi = index.search('你的名字').first;
      expect(kimi.title, 'Kimi no Na wa.');
      expect(kimi.source, ScrapeSource.offlineDb);
      expect(kimi.type, ScrapeEntryType.movie);
      expect(kimi.entryId, 'myanimelist.net/anime/32281');
      expect(kimi.detailUrl, 'https://myanimelist.net/anime/32281');
      expect(kimi.posterUrl,
          'https://cdn.myanimelist.net/images/anime/5/87048.jpg');
      expect(kimi.aliases, contains('你的名字。'));
      expect(kimi.episodeCount, 1);
      expect(kimi.year, 2016);
    });

    test('limit 生效，无关查询返回空', () {
      expect(index.search('无职转生', limit: 1), hasLength(1));
      expect(index.search('qqqq zzzz'), isEmpty);
      expect(index.search('～！？'), isEmpty);
    });
  });

  group('借来别名的联动/CM 降级（BUG-1080）', () {
    test('主标题直接命中的正片，排在只靠借来别名命中的联动 CM 之前', () {
      // 复刻真实 bug：Suntory「天然水」联动 CM 把「君の名は / Kimi no Na wa」塞进
      // synonyms，于是它对查询的 title+synonyms 最大相似度与正片相同；但 CM 自己的主
      // 标题「Suntory…」与查询无关。tiebreaker（主标题相似度）应让正片压过 CM。
      final OfflineIndex idx = OfflineIndex(const <OfflineAnimeRecord>[
        OfflineAnimeRecord(
          title: 'Suntory Minami Alps no Tennensui',
          synonyms: <String>['Kimi no Na wa', '君の名は'],
          type: ScrapeEntryType.special,
          picture: 'https://example.invalid/cm.jpg',
          sourceId: 'anidb/cm',
        ),
        OfflineAnimeRecord(
          title: 'Kimi no Na wa.',
          synonyms: <String>['你的名字。', 'Your Name.'],
          type: ScrapeEntryType.movie,
          picture: 'https://example.invalid/movie.jpg',
          sourceId: 'myanimelist.net/anime/32281',
        ),
      ]);
      // 用户实际输入（含 "-your name"），两者 best 相似度打平在 0.8。
      final List<ScrapeCandidate> results =
          idx.search('Kimi no Na wa. -your name');
      expect(results.first.title, 'Kimi no Na wa.',
          reason: '正片主标题直接命中，应压过靠借来别名蹭分的联动 CM');
    });
  });
}
