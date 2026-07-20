import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:hibiki/src/media/torrent/nyaa_client.dart';

/// 构造只关心 [title] / [infoHash] 的最小 [NyaaTorrent]，供派生 getter 测试用。
NyaaTorrent makeTorrent(String title, {String infoHash = ''}) {
  return NyaaTorrent(
    title: title,
    torrentUrl: '',
    pageUrl: '',
    infoHash: infoHash,
    seeders: 0,
    leechers: 0,
    downloads: 0,
    sizeText: '',
    sizeBytes: null,
    categoryId: '',
    trusted: false,
    remake: false,
    pubDate: null,
  );
}

const String sampleRss = '''
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:atom="http://www.w3.org/2005/Atom" xmlns:nyaa="https://nyaa.si/xmlns/nyaa">
  <channel>
    <title>Nyaa - Home - Torrent File RSS</title>
    <description>RSS Feed for Home</description>
    <link>https://nyaa.si/</link>
    <item>
      <title>[SubsPlease] Sousou no Frieren - 05 (1080p) [ABCD1234].mkv</title>
      <link>https://nyaa.si/download/1234567.torrent</link>
      <guid isPermaLink="true">https://nyaa.si/view/1234567</guid>
      <pubDate>Fri, 03 Nov 2023 12:30:00 -0000</pubDate>
      <nyaa:seeders>120</nyaa:seeders>
      <nyaa:leechers>4</nyaa:leechers>
      <nyaa:downloads>2048</nyaa:downloads>
      <nyaa:infoHash>0123456789abcdef0123456789abcdef01234567</nyaa:infoHash>
      <nyaa:categoryId>1_2</nyaa:categoryId>
      <nyaa:category>Anime - English-translated</nyaa:category>
      <nyaa:size>1.4 GiB</nyaa:size>
      <nyaa:trusted>Yes</nyaa:trusted>
      <nyaa:remake>No</nyaa:remake>
    </item>
    <item>
      <title>[Judas] Frieren 01-12 [1080p][HEVC x265] (Batch)</title>
      <link>https://nyaa.si/download/7654321.torrent</link>
      <guid isPermaLink="true">https://nyaa.si/view/7654321</guid>
      <pubDate>not a date</pubDate>
      <nyaa:seeders>33</nyaa:seeders>
      <nyaa:leechers>2</nyaa:leechers>
      <nyaa:downloads>512</nyaa:downloads>
      <nyaa:infoHash>fedcba9876543210fedcba9876543210fedcba98</nyaa:infoHash>
      <nyaa:categoryId>1_0</nyaa:categoryId>
      <nyaa:size>700.5 MiB</nyaa:size>
      <nyaa:trusted>No</nyaa:trusted>
      <nyaa:remake>Yes</nyaa:remake>
    </item>
    <item>
      <title>Show Raw 980 kb sample</title>
      <link>https://nyaa.si/download/1111.torrent</link>
      <guid isPermaLink="true">https://nyaa.si/view/1111</guid>
      <pubDate>Fri, 03 Nov 2023 21:30:00 +0900</pubDate>
      <nyaa:seeders>bad</nyaa:seeders>
      <nyaa:leechers></nyaa:leechers>
      <nyaa:downloads>7</nyaa:downloads>
      <nyaa:infoHash>aaaa</nyaa:infoHash>
      <nyaa:categoryId>1_4</nyaa:categoryId>
      <nyaa:size>weird size</nyaa:size>
      <nyaa:trusted>No</nyaa:trusted>
      <nyaa:remake>No</nyaa:remake>
    </item>
  </channel>
</rss>
''';

void main() {
  group('parseNyaaRss', () {
    test('解析全部字段', () {
      final List<NyaaTorrent> items = parseNyaaRss(sampleRss);
      expect(items, hasLength(3));

      final NyaaTorrent first = items[0];
      expect(first.title,
          '[SubsPlease] Sousou no Frieren - 05 (1080p) [ABCD1234].mkv');
      expect(first.torrentUrl, 'https://nyaa.si/download/1234567.torrent');
      expect(first.pageUrl, 'https://nyaa.si/view/1234567');
      expect(first.infoHash, '0123456789abcdef0123456789abcdef01234567');
      expect(first.seeders, 120);
      expect(first.leechers, 4);
      expect(first.downloads, 2048);
      expect(first.sizeText, '1.4 GiB');
      expect(first.sizeBytes, (1.4 * 1024 * 1024 * 1024).round());
      expect(first.categoryId, '1_2');
      expect(first.trusted, isTrue);
      expect(first.remake, isFalse);
      expect(first.pubDate, DateTime.utc(2023, 11, 3, 12, 30));
      expect(first.episode, 5);
      expect(first.parsedSeries, 'Sousou no Frieren');
      expect(first.resolution, '1080p');
      expect(first.releaseGroup, 'SubsPlease');
      expect(first.isBatch, isFalse);

      final NyaaTorrent second = items[1];
      expect(second.trusted, isFalse);
      expect(second.remake, isTrue);
      expect(second.sizeBytes, (700.5 * 1024 * 1024).round());
      expect(second.pubDate, isNull); // 坏日期 → null
      expect(second.episodeRange, (1, 12));
      expect(second.isBatch, isTrue);

      final NyaaTorrent third = items[2];
      expect(third.seeders, 0); // 非法数字容错为 0
      expect(third.leechers, 0);
      expect(third.sizeBytes, isNull); // 认不出的体积 → null
      expect(third.pubDate, DateTime.utc(2023, 11, 3, 12, 30)); // +0900 归一 UTC
      expect(third.releaseGroup, isNull);
    });

    test('坏 XML / 空 body / 无 item → 空列表且不抛', () {
      expect(parseNyaaRss('not xml <<<'), isEmpty);
      expect(parseNyaaRss(''), isEmpty);
      expect(parseNyaaRss('   '), isEmpty);
      expect(
        parseNyaaRss('<rss><channel><title>empty</title></channel></rss>'),
        isEmpty,
      );
    });
  });

  group('parseNyaaSize', () {
    test('各单位换算', () {
      expect(parseNyaaSize('1.4 GiB'), 1503238554);
      expect(parseNyaaSize('700.5 MiB'), 734527488);
      expect(parseNyaaSize('980 KiB'), 1003520);
      expect(parseNyaaSize('123 B'), 123);
      expect(parseNyaaSize('2 TiB'), 2 * 1024 * 1024 * 1024 * 1024);
    });

    test('非法输入 → null', () {
      expect(parseNyaaSize(''), isNull);
      expect(parseNyaaSize('garbage'), isNull);
      expect(parseNyaaSize('1.4 GB'), isNull); // 非 IEC 单位不猜
      expect(parseNyaaSize('GiB'), isNull);
    });
  });

  group('magnet', () {
    test('拼 infoHash + dn + 5 个 tracker', () {
      final NyaaTorrent t = makeTorrent(
        'My Show [x]',
        infoHash: '0123456789abcdef0123456789abcdef01234567',
      );
      expect(
        t.magnet,
        startsWith(
            'magnet:?xt=urn:btih:0123456789abcdef0123456789abcdef01234567'
            '&dn=My%20Show%20%5Bx%5D'),
      );
      expect('&tr='.allMatches(t.magnet), hasLength(5));
      expect(
        t.magnet,
        contains('&tr=http%3A%2F%2Fnyaa.tracker.wf%3A7777%2Fannounce'),
      );
      expect(
        t.magnet,
        contains('&tr=udp%3A%2F%2Fexodus.desync.com%3A6969%2Fannounce'),
      );
    });
  });

  group('episodeRange / isBatch', () {
    test('正例：01-12 / 01~13', () {
      expect(makeTorrent('[G] Show 01-12 [1080p]').episodeRange, (1, 12));
      expect(makeTorrent('[G] Show 01~13').episodeRange, (1, 13));
      expect(makeTorrent('[G] Show 01-12').isBatch, isTrue);
    });

    test('反例：分辨率 / 年份 / 单集号 / 超宽区间', () {
      expect(makeTorrent('[G] Show 1920x1080').episodeRange, isNull);
      expect(makeTorrent('[G] Show (2024) [1080p]').episodeRange, isNull);
      expect(makeTorrent('[G] Show - 05 [1080p]').episodeRange, isNull);
      expect(makeTorrent('[G] Show - 05 [1080p]').isBatch, isFalse);
      expect(makeTorrent('Show 1-1000').episodeRange, isNull); // 差值 ≥200
    });

    test('batch 关键词且无单集号 → isBatch，range 仍为 null', () {
      final NyaaTorrent t = makeTorrent('[G] Show Complete Batch [1080p]');
      expect(t.episodeRange, isNull);
      expect(t.isBatch, isTrue);
      // 有单集号时 batch 字样不算合集。
      expect(makeTorrent('[G] Show - 05 [Batch]').isBatch, isFalse);
    });
  });

  group('resolution / releaseGroup', () {
    test('resolution 匹配常见档位', () {
      expect(makeTorrent('[G] Show (2160p)').resolution, '2160p');
      expect(makeTorrent('[G] Show [720p]').resolution, '720p');
      expect(makeTorrent('[G] Show 480p').resolution, '480p');
      expect(makeTorrent('[G] Show').resolution, isNull);
    });

    test('releaseGroup 取开头第一个方括号块', () {
      expect(makeTorrent('[SubsPlease] Show - 05').releaseGroup, 'SubsPlease');
      expect(makeTorrent('Show - 05 [1080p]').releaseGroup, isNull);
    });
  });

  group('parseNyaaPubDate', () {
    test('RFC822 解析与时区归一', () {
      expect(
        parseNyaaPubDate('Fri, 03 Nov 2023 12:30:00 -0000'),
        DateTime.utc(2023, 11, 3, 12, 30),
      );
      expect(
        parseNyaaPubDate('Fri, 03 Nov 2023 21:30:00 +0900'),
        DateTime.utc(2023, 11, 3, 12, 30),
      );
      expect(parseNyaaPubDate('nonsense'), isNull);
      expect(parseNyaaPubDate(''), isNull);
    });
  });

  group('NyaaClient.search', () {
    test('拼出 page=rss&q&c&f 的查询 URL 并解析响应', () async {
      Uri? captured;
      final MockClient mock = MockClient((http.Request req) async {
        captured = req.url;
        return http.Response(sampleRss, 200);
      });
      final NyaaClient client = NyaaClient(client: mock);
      final List<NyaaTorrent> items =
          await client.search('frieren', category: '1_2', filter: '2');
      expect(items, hasLength(3));
      expect(captured, isNotNull);
      expect(captured!.host, 'nyaa.si');
      expect(captured!.scheme, 'https');
      expect(captured!.queryParameters, <String, String>{
        'page': 'rss',
        'q': 'frieren',
        'c': '1_2',
        'f': '2',
      });
      client.close();
    });

    test('默认 category=1_0 / filter=0；非 200 → 空列表', () async {
      Uri? captured;
      final MockClient mock = MockClient((http.Request req) async {
        captured = req.url;
        return http.Response('server error', 500);
      });
      final NyaaClient client = NyaaClient(client: mock);
      expect(await client.search('frieren'), isEmpty);
      expect(captured!.queryParameters['c'], '1_0');
      expect(captured!.queryParameters['f'], '0');
      client.close();
    });

    test('UTF-8 无 charset 响应按 UTF-8 解码（日文标题不乱码）', () async {
      // Nyaa 实际返回 UTF-8 字节但常不声明 charset；用 Response.bytes 模拟。
      // 旧实现走 res.body(latin1) 会把「ソ・ラ・ノ・ヲ・ト」变成「Soã»...」。
      const String jpTitle =
          '[ReinForce] ソ・ラ・ノ・ヲ・ト (BDRip 1920x1080 x264 FLAC)';
      const String rss = '''
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:nyaa="https://nyaa.si/xmlns/nyaa">
  <channel><item>
    <title>$jpTitle</title>
    <link>https://nyaa.si/download/9.torrent</link>
    <guid>https://nyaa.si/view/9</guid>
    <nyaa:infoHash>abcdef0123456789abcdef0123456789abcdef01</nyaa:infoHash>
    <nyaa:seeders>1</nyaa:seeders>
  </item></channel>
</rss>''';
      final MockClient mock = MockClient((http.Request req) async {
        // bytes 构造 = UTF-8 字节 + 无 charset 头（正是踩坑场景）。
        return http.Response.bytes(utf8.encode(rss), 200);
      });
      final NyaaClient client = NyaaClient(client: mock);
      final List<NyaaTorrent> items = await client.search('sora');
      expect(items, hasLength(1));
      expect(items.single.title, jpTitle);
      expect(items.single.title.contains('ソ・ラ・ノ・ヲ・ト'), isTrue);
      client.close();
    });
  });
}
