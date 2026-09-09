import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:fushi_engine/media/torrent/anime_release_descriptor.dart';
import 'package:fushi_engine/media/torrent/download_timeouts.dart';
import 'package:fushi_engine/media/torrent/nyaa_client.dart';
import 'package:fushi_engine/media/torrent/public_trackers.dart';

import 'nyaa_html_fixture.dart';

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

/// 三行 HTML 首屏：trusted / remake / 普通 各一。
const List<NyaaHtmlRow> _sampleRows = <NyaaHtmlRow>[
  NyaaHtmlRow(
    title: '[SubsPlease] Sousou no Frieren - 05 (1080p) [ABCD1234].mkv',
    infoHash: '0123456789abcdef0123456789abcdef01234567',
    id: '1234567',
    seeders: 120,
    leechers: 4,
    downloads: 2048,
    size: '1.4 GiB',
    categoryId: '1_2',
    trusted: true,
  ),
  NyaaHtmlRow(
    title: '[Judas] Frieren 01-12 [1080p][HEVC x265] (Batch)',
    infoHash: 'fedcba9876543210fedcba9876543210fedcba98',
    id: '7654321',
    seeders: 33,
    leechers: 2,
    downloads: 512,
    size: '700.5 MiB',
    categoryId: '1_0',
    remake: true,
  ),
  NyaaHtmlRow(
    title: 'Show Raw 980 kb sample',
    infoHash: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
    id: '1111',
    downloads: 7,
    size: 'weird size',
    categoryId: '1_4',
  ),
];

/// 测试用 client：节流归零（节流本身单独测），其余默认。
NyaaClient _clientWith(
  Future<http.Response> Function(http.Request request) handler, {
  Duration? requestTimeout,
  Duration minRequestInterval = Duration.zero,
}) =>
    NyaaClient(
      client: MockClient(handler),
      requestTimeout: requestTimeout ?? kDownloadDiscoveryTimeout,
      minRequestInterval: minRequestInterval,
    );

void main() {
  group('parseNyaaRss', () {
    test('解析全部字段', () {
      final List<NyaaTorrent> items = parseNyaaRss(sampleRss);
      expect(items, hasLength(3));

      final NyaaTorrent first = items[0];
      expect(
        first.title,
        '[SubsPlease] Sousou no Frieren - 05 (1080p) [ABCD1234].mkv',
      );
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

  group('parseNyaaRssStrict（原 RSS 首屏解析层，保留给旧调用方）', () {
    NyaaFeedErrorCode? codeOf(String body) {
      try {
        parseNyaaRssStrict(body);
        return null;
      } on NyaaFeedFormatException catch (error) {
        return error.code;
      }
    }

    test('严格错误矩阵：编码/XML/RSS结构/命名空间/必需字段稳定可区分', () {
      expect(codeOf(''), NyaaFeedErrorCode.emptyBody);
      expect(
        codeOf(
            '<?xml version="1.0" encoding="shift_jis"?><rss><channel/></rss>'),
        NyaaFeedErrorCode.unsupportedEncoding,
      );
      expect(codeOf('<rss><channel>'), NyaaFeedErrorCode.malformedXml);
      expect(codeOf('<html><body/></html>'), NyaaFeedErrorCode.notRss);
      expect(codeOf('<rss/>'), NyaaFeedErrorCode.missingStructure);
      expect(
        codeOf(
          '<rss><channel><item><link>x</link><guid>y</guid>'
          '<n:infoHash xmlns:n="$_nyaaNamespaceForTest">'
          '${'a' * 40}</n:infoHash></item></channel></rss>',
        ),
        NyaaFeedErrorCode.missingField,
      );
      expect(
        codeOf(
          '<rss><channel><item><title>x</title><link>x</link><guid>y</guid>'
          '<bad:infoHash xmlns:bad="https://invalid.example/ns">'
          '${'a' * 40}</bad:infoHash></item></channel></rss>',
        ),
        NyaaFeedErrorCode.invalidNamespace,
      );
      expect(
        codeOf('<rss><channel><title>valid empty</title></channel></rss>'),
        isNull,
        reason: '结构有效、确实没有 item 才是 0 条',
      );
      // 严格版对坏 seeders / 坏 infoHash 抛 invalidField（宽松版 parseNyaaRss
      // 容错保留）；把第三条修好后三条都能解析。
      expect(codeOf(sampleRss), NyaaFeedErrorCode.invalidField);
      expect(
        parseNyaaRssStrict(
          sampleRss
              .replaceFirst(
                '<nyaa:seeders>bad</nyaa:seeders>',
                '<nyaa:seeders>0</nyaa:seeders>',
              )
              .replaceFirst(
                '<nyaa:leechers></nyaa:leechers>',
                '<nyaa:leechers>0</nyaa:leechers>',
              )
              .replaceFirst(
                '<nyaa:infoHash>aaaa</nyaa:infoHash>',
                '<nyaa:infoHash>${'a' * 40}</nyaa:infoHash>',
              ),
        ),
        hasLength(3),
      );
    });

    test('BUG-1946：sukebei / 镜像站 <site>/xmlns/nyaa 命名空间被接受，路径不同才拒', () {
      String feed(String ns) => '''
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:nyaa="$ns">
  <channel><item>
    <title>[260825][破顔研] イモータルリコール 外伝 [RJ01660478]</title>
    <link>https://sukebei.nyaa.si/download/4697097.torrent</link>
    <guid isPermaLink="true">https://sukebei.nyaa.si/view/4697097</guid>
    <nyaa:seeders>29</nyaa:seeders>
    <nyaa:infoHash>14d40b587d2a237150b6b019e6236e93e16a1f73</nyaa:infoHash>
    <nyaa:categoryId>1_3</nyaa:categoryId>
    <nyaa:size>252.8 MiB</nyaa:size>
    <nyaa:trusted>Yes</nyaa:trusted>
  </item></channel>
</rss>''';

      for (final String ns in <String>[
        'https://sukebei.nyaa.si/xmlns/nyaa',
        'https://nyaa.si/xmlns/nyaa',
        'https://nyaa.land/xmlns/nyaa',
        'http://127.0.0.1:8080/xmlns/nyaa',
      ]) {
        final NyaaTorrent item = parseNyaaRssStrict(feed(ns)).single;
        expect(item.infoHash, '14d40b587d2a237150b6b019e6236e93e16a1f73');
        expect(item.seeders, 29, reason: '$ns：nyaa:seeders 也要按命名空间读到');
        expect(item.categoryId, '1_3', reason: ns);
        expect(item.trusted, isTrue, reason: ns);
      }
      for (final String ns in <String>[
        'https://invalid.example/ns',
        'https://nyaa.si/xmlns/other',
        'https://nyaa.si/xmlns/nyaa/',
        'nyaa',
      ]) {
        expect(codeOf(feed(ns)), NyaaFeedErrorCode.invalidNamespace,
            reason: ns);
      }

      expect(isNyaaNamespace(null), isFalse);
      expect(isNyaaNamespace(''), isFalse);
      expect(isNyaaNamespace('/xmlns/nyaa'), isFalse, reason: '无 host 不算');
      expect(isNyaaNamespace('https://sukebei.nyaa.si/xmlns/nyaa'), isTrue);
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
    test('拼 infoHash + dn + 全部内置 tracker', () {
      final NyaaTorrent t = makeTorrent(
        'My Show [x]',
        infoHash: '0123456789abcdef0123456789abcdef01234567',
      );
      expect(
        t.magnet,
        startsWith(
          'magnet:?xt=urn:btih:0123456789abcdef0123456789abcdef01234567'
          '&dn=My%20Show%20%5Bx%5D',
        ),
      );
      // 数量跟着常量走，但不是同源恒真：它抓的是拼接漏写了其中某几条。
      expect('&tr='.allMatches(t.magnet), hasLength(kNyaaTrackers.length));
      for (final String tracker in kNyaaTrackers) {
        expect(t.magnet, contains('&tr=${Uri.encodeComponent(tracker)}'));
      }
      expect(
        t.magnet,
        contains('&tr=http%3A%2F%2Fnyaa.tracker.wf%3A7777%2Fannounce'),
      );
      expect(
        t.magnet,
        contains('&tr=udp%3A%2F%2Fexodus.desync.com%3A6969%2Fannounce'),
      );
    });

    test('内置 tracker 列表无重复、站点专属排最前', () {
      // 上面按 `&tr=` 出现次数计数，列表里混进重复项它抓不到。
      expect(kNyaaTrackers.toSet(), hasLength(kNyaaTrackers.length));
      expect(kNyaaTrackers.first, 'http://nyaa.tracker.wf:7777/announce');
      expect(kNyaaTrackers, containsAll(kPublicTrackers));
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
      expect(makeTorrent('[G] Show 1920x1080').resolution, '1080p');
      expect(makeTorrent('[G] Show [4K]').resolution, '2160p');
      expect(makeTorrent('[G] Show').resolution, isNull);
    });

    test('releaseGroup 取开头第一个方括号块', () {
      expect(makeTorrent('[SubsPlease] Show - 05').releaseGroup, 'SubsPlease');
      expect(makeTorrent('Show - 05 [1080p]').releaseGroup, isNull);
    });
  });

  group('releaseDescriptor', () {
    test('解析 WEB-DL、编码、位深、HDR、音频与软字幕', () {
      final AnimeReleaseDescriptor descriptor = makeTorrent(
        '[SubsPlease] Show - 05 (2160p) '
        '[WEB-DL HEVC Main10 HDR10+ DV E-AC-3 AAC SoftSubs]',
      ).releaseDescriptor;

      expect(descriptor.releaseGroup, 'SubsPlease');
      expect(descriptor.resolutionHeight, 2160);
      expect(descriptor.videoSource, AnimeVideoSource.webDl);
      expect(descriptor.videoCodec, AnimeVideoCodec.hevc);
      expect(descriptor.bitDepth, 10);
      expect(
        descriptor.dynamicRanges,
        <AnimeDynamicRange>{
          AnimeDynamicRange.hdr10Plus,
          AnimeDynamicRange.dolbyVision,
        },
      );
      expect(
        descriptor.audioCodecs,
        <AnimeAudioCodec>{AnimeAudioCodec.eac3, AnimeAudioCodec.aac},
      );
      expect(
        descriptor.subtitlePresentation,
        AnimeSubtitlePresentation.soft,
      );
      expect(descriptor.isHdr, isTrue);
    });

    test('解析蓝光尺寸、AVC、FLAC/DTS-HD 与硬字幕', () {
      final AnimeReleaseDescriptor descriptor = makeTorrent(
        '[VCB-Studio] Show [BDRip 1920x1080 x264 10bit FLAC DTS-HD MA HardSub]',
      ).releaseDescriptor;

      expect(descriptor.resolution, '1080p');
      expect(descriptor.videoSource, AnimeVideoSource.bluRay);
      expect(descriptor.videoCodec, AnimeVideoCodec.avc);
      expect(descriptor.bitDepth, 10);
      expect(
        descriptor.audioCodecs,
        <AnimeAudioCodec>{AnimeAudioCodec.flac, AnimeAudioCodec.dtsHd},
      );
      expect(
        descriptor.subtitlePresentation,
        AnimeSubtitlePresentation.hard,
      );
      expect(descriptor.isHdr, isFalse);
    });

    test('没有明确标签时不猜资源规格', () {
      final AnimeReleaseDescriptor descriptor =
          makeTorrent('Show - 05 [ABCD1234]').releaseDescriptor;

      expect(descriptor.releaseGroup, isNull);
      expect(descriptor.resolution, isNull);
      expect(descriptor.videoSource, AnimeVideoSource.unknown);
      expect(descriptor.videoCodec, AnimeVideoCodec.unknown);
      expect(descriptor.bitDepth, isNull);
      expect(descriptor.dynamicRanges, isEmpty);
      expect(descriptor.audioCodecs, isEmpty);
      expect(
        descriptor.subtitlePresentation,
        AnimeSubtitlePresentation.unknown,
      );
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

  group('NyaaClient.search（HTML 搜索页）', () {
    Future<Object?> searchResponse(
      List<int> bytes, {
      Map<String, String> headers = const <String, String>{},
    }) async {
      final NyaaClient client = _clientWith(
        (_) async => http.Response.bytes(bytes, 200, headers: headers),
      );
      try {
        return await client.search('show');
      } catch (error) {
        return error;
      } finally {
        client.close();
      }
    }

    test('首屏拼 q&c&f&s&o（默认做种降序、不带 page=rss / p）并解析 HTML', () async {
      Uri? captured;
      final NyaaClient client = _clientWith((http.Request req) async {
        captured = req.url;
        return http.Response(nyaaSearchHtml(_sampleRows), 200);
      });
      final List<NyaaTorrent> items = await client.search(
        'frieren',
        category: '1_2',
        filter: '2',
      );
      expect(captured, isNotNull);
      expect(captured!.host, 'nyaa.si');
      expect(captured!.scheme, 'https');
      expect(captured!.queryParameters, <String, String>{
        'q': 'frieren',
        'c': '1_2',
        'f': '2',
        's': 'seeders',
        'o': 'desc',
      });

      expect(items, hasLength(3));
      final NyaaTorrent first = items[0];
      expect(
        first.title,
        '[SubsPlease] Sousou no Frieren - 05 (1080p) [ABCD1234].mkv',
      );
      expect(first.torrentUrl, 'https://nyaa.si/download/1234567.torrent');
      expect(first.pageUrl, 'https://nyaa.si/view/1234567');
      expect(first.infoHash, '0123456789abcdef0123456789abcdef01234567');
      expect(first.seeders, 120);
      expect(first.leechers, 4);
      expect(first.downloads, 2048);
      expect(first.sizeText, '1.4 GiB');
      expect(first.sizeBytes, (1.4 * 1024 * 1024 * 1024).round());
      expect(first.categoryId, '1_2');
      expect(
        first.pubDate,
        DateTime.fromMillisecondsSinceEpoch(1700000000 * 1000, isUtc: true),
      );
      expect(items[1].sizeBytes, (700.5 * 1024 * 1024).round());
      expect(items[1].episodeRange, (1, 12));
      expect(items[2].seeders, 0);
      expect(items[2].sizeBytes, isNull, reason: '认不出的体积 → null');
      client.close();
    });

    test('行 class → trusted（success）/ remake（danger）；普通行两者皆否', () async {
      final NyaaClient client = _clientWith(
        (_) async => http.Response(nyaaSearchHtml(_sampleRows), 200),
      );
      final List<NyaaTorrent> items = await client.search('x');
      expect(items[0].trusted, isTrue);
      expect(items[0].remake, isFalse);
      expect(items[1].trusted, isFalse);
      expect(items[1].remake, isTrue);
      expect(items[2].trusted, isFalse);
      expect(items[2].remake, isFalse);
      client.close();
    });

    test('sort / order 透传：订阅按发布时间用 s=id', () async {
      Uri? captured;
      final NyaaClient client = _clientWith((http.Request req) async {
        captured = req.url;
        return http.Response(kNyaaNoResultsHtml, 200);
      });
      await client.search(
        'x',
        sort: NyaaSort.date,
        order: NyaaSortOrder.asc,
      );
      expect(captured!.queryParameters['s'], 'id');
      expect(captured!.queryParameters['o'], 'asc');
      client.close();
    });

    test('第二页带 p 参数，其余参数不变', () async {
      Uri? captured;
      final NyaaClient client = _clientWith((http.Request request) async {
        captured = request.url;
        return http.Response(nyaaSearchHtml(_sampleRows.take(1)), 200);
      });

      final List<NyaaTorrent> items = await client.search(
        'Example',
        category: '1_2',
        filter: '2',
        page: 2,
      );

      expect(captured!.queryParameters, <String, String>{
        'q': 'Example',
        'c': '1_2',
        'f': '2',
        's': 'seeders',
        'o': 'desc',
        'p': '2',
      });
      expect(items, hasLength(1));
      client.close();
    });

    test('越过后端上限的页直接返回空、不发请求：关键词 14 页 / 浏览 100 页', () async {
      int requests = 0;
      final NyaaClient client = _clientWith((http.Request request) async {
        requests++;
        return http.Response(kNyaaNoResultsHtml, 200);
      });

      expect(await client.search('x', page: kNyaaMaxSearchPages + 1), isEmpty);
      expect(requests, 0, reason: '越界页不该打网络');
      expect(await client.search('x', page: kNyaaMaxSearchPages), isEmpty);
      expect(requests, 1, reason: '上限页本身仍然要请求');

      expect(await client.search('', page: kNyaaMaxBrowsePages + 1), isEmpty);
      expect(requests, 1);
      expect(
          await client.search('   ', page: kNyaaMaxBrowsePages + 1), isEmpty);
      expect(requests, 1, reason: '空白关键词按浏览算');
      expect(await client.search('', page: kNyaaMaxBrowsePages), isEmpty);
      expect(requests, 2);
      // 浏览允许比关键词搜索翻得更深。
      expect(await client.search('', page: kNyaaMaxSearchPages + 1), isEmpty);
      expect(requests, 3);
      client.close();

      expect(kNyaaMaxSearchPages, 14);
      expect(kNyaaMaxBrowsePages, 100);
    });

    test('page <= 0 仍是调用方 bug，抛 ArgumentError', () async {
      final NyaaClient client = _clientWith(
        (_) async => http.Response(kNyaaNoResultsHtml, 200),
      );
      await expectLater(client.search('x', page: 0), throwsArgumentError);
      client.close();
    });

    test('HTML 后续页 404 表示越过末页并安全结束', () async {
      Uri? captured;
      final NyaaClient client = _clientWith((http.Request request) async {
        captured = request.url;
        return http.Response('not found', 404);
      });

      expect(await client.search('Example', page: 3), isEmpty);
      expect(captured!.queryParameters['p'], '3');
      client.close();
    });

    test(
      '默认 category=1_0 / filter=0；非 200 → 抛 ClientException（含状态码）',
      () async {
        // 以前吞错返回空列表，真实网络故障（站点被墙/代理未配）会被误报成
        // 「无结果」；现在必须抛出让调用方展示真实错误。
        Uri? captured;
        final NyaaClient client = _clientWith((http.Request req) async {
          captured = req.url;
          return http.Response('server error', 500);
        });
        await expectLater(
          client.search('frieren'),
          throwsA(
            isA<http.ClientException>().having(
              (http.ClientException e) => e.message,
              'message',
              'HTTP 500',
            ),
          ),
        );
        expect(captured!.queryParameters['c'], '1_0');
        expect(captured!.queryParameters['f'], '0');
        client.close();
      },
    );

    // BUG-2079：`_client.get(uri)` 原本不带 `.timeout(...)`，整条 search 无时限。
    // Dart 的 `HttpClient.connectionTimeout` 默认是 null（不超时），站点被墙 /
    // 代理半开时 TCP 连接能挂到操作系统重传耗尽；discovery source 与 resource
    // provider 这两条注册表路径的调用点也没有外层超时，于是一次挂死的 Nyaa
    // 请求会把整次扇出一起拖住。
    test('永不完成的响应在 requestTimeout 后抛 TimeoutException，不是无限等待', () async {
      // 永不完成：这个 Completer 从不 complete、也不 throw。若 search 不设超时，
      // 下面的 await 就永远不返回，只能被 flutter_test 自己的超时打死。
      final Completer<http.Response> never = Completer<http.Response>();
      final NyaaClient client = _clientWith(
        (http.Request req) => never.future,
        requestTimeout: const Duration(milliseconds: 50),
      );
      await expectLater(
        client.search('frieren'),
        throwsA(isA<TimeoutException>()),
      );
      client.close();
    });

    test('翻页路径同样受 requestTimeout 约束', () async {
      final Completer<http.Response> never = Completer<http.Response>();
      final NyaaClient client = _clientWith(
        (http.Request req) => never.future,
        requestTimeout: const Duration(milliseconds: 50),
      );
      await expectLater(
        client.search('frieren', page: 3),
        throwsA(isA<TimeoutException>()),
      );
      client.close();
    });

    test('默认超时取发现链路唯一真相源，不是 torznab 的 20s', () {
      // 20s 正是 BUG-1141 从这条链路上拆掉的直连口径魔法数字；而且
      // anime_download_subscription / anime_download_dialog 的调用点外层就是
      // kDownloadDiscoveryTimeout，内层更紧等于替它们偷偷回退 BUG-1141。
      // 注入 MockClient 只为避免建真 IO client；被测的是默认参数值本身。
      final NyaaClient client =
          NyaaClient(client: MockClient((_) async => http.Response('', 200)));
      expect(client.requestTimeout, kDownloadDiscoveryTimeout);
      expect(client.minRequestInterval, kNyaaMinRequestInterval);
      expect(kNyaaMinRequestInterval, const Duration(seconds: 2));
      client.close();
    });

    test('同一实例请求按 minRequestInterval 串行节流（并发调用也排队）', () async {
      const Duration interval = Duration(milliseconds: 120);
      final List<DateTime> startedAt = <DateTime>[];
      final NyaaClient client = _clientWith(
        (http.Request req) async {
          startedAt.add(DateTime.now());
          return http.Response(kNyaaNoResultsHtml, 200);
        },
        minRequestInterval: interval,
      );
      // 三个并发调用：不能同时打出去。
      await Future.wait<List<NyaaTorrent>>(<Future<List<NyaaTorrent>>>[
        client.search('a'),
        client.search('b'),
        client.search('c'),
      ]);
      expect(startedAt, hasLength(3));
      for (int i = 1; i < startedAt.length; i++) {
        final Duration gap = startedAt[i].difference(startedAt[i - 1]);
        // 定时器精度留 20ms 余量；断言的是「至少隔开」，不是精确值。
        expect(
          gap,
          greaterThanOrEqualTo(interval - const Duration(milliseconds: 20)),
          reason: '第 $i 次与上一次只隔了 $gap',
        );
      }
      client.close();
    });

    test('底层网络异常（如握手失败）原样穿透，不吞成空列表', () async {
      final NyaaClient client = _clientWith((http.Request req) async {
        throw http.ClientException('HandshakeException: 模拟被墙', req.url);
      });
      await expectLater(
        client.search('frieren'),
        throwsA(
          isA<http.ClientException>().having(
            (http.ClientException e) => e.message,
            'message',
            contains('HandshakeException'),
          ),
        ),
      );
      client.close();
    });

    test('空响应 / 不是搜索页的 HTML 抛格式错误；「No results found」页才是 0 条', () async {
      Future<Object?> searchBody(String body) async {
        final NyaaClient client = _clientWith(
          (http.Request req) async => http.Response(body, 200),
        );
        try {
          return await client.search('frieren');
        } catch (error) {
          return error;
        } finally {
          client.close();
        }
      }

      expect(
        await searchBody(''),
        isA<FormatException>().having(
          (FormatException e) => e.message,
          'message',
          contains('empty'),
        ),
      );
      expect(
        await searchBody('not xml <<<'),
        isA<NyaaFeedFormatException>().having(
          (NyaaFeedFormatException e) => e.code,
          'code',
          NyaaFeedErrorCode.missingStructure,
        ),
      );
      // 旧 RSS 空 feed 现在也不是搜索页：不能再被当成 0 条。
      expect(
        await searchBody(
          '<rss><channel><title>valid empty</title></channel></rss>',
        ),
        isA<NyaaFeedFormatException>().having(
          (NyaaFeedFormatException e) => e.code,
          'code',
          NyaaFeedErrorCode.missingStructure,
        ),
      );
      expect(
        await searchBody(kNyaaNoResultsHtml),
        isA<List<NyaaTorrent>>().having(
          (List<NyaaTorrent> items) => items,
          'items',
          isEmpty,
        ),
      );
    });

    test('UTF-8 无 charset 响应按 UTF-8 解码（日文标题不乱码）', () async {
      // Nyaa 实际返回 UTF-8 字节但常不声明 charset；用 Response.bytes 模拟。
      // 旧实现走 res.body(latin1) 会把「ソ・ラ・ノ・ヲ・ト」变成「Soã»...」。
      const String jpTitle =
          '[ReinForce] ソ・ラ・ノ・ヲ・ト (BDRip 1920x1080 x264 FLAC)';
      final NyaaClient client = _clientWith((http.Request req) async {
        // bytes 构造 = UTF-8 字节 + 无 charset 头（正是踩坑场景）。
        return http.Response.bytes(
          utf8.encode(
            nyaaSearchHtml(const <NyaaHtmlRow>[
              NyaaHtmlRow(
                title: jpTitle,
                infoHash: 'abcdef0123456789abcdef0123456789abcdef01',
                id: '9',
                seeders: 1,
              ),
            ]),
          ),
          200,
        );
      });
      final List<NyaaTorrent> items = await client.search('sora');
      expect(items, hasLength(1));
      expect(items.single.title, jpTitle);
      expect(items.single.title.contains('ソ・ラ・ノ・ヲ・ト'), isTrue);
      client.close();
    });

    test('严格错误矩阵：编码 / UTF-8 / 页面结构 / 必需字段稳定可区分', () async {
      Future<void> expectCode(
        List<int> bytes,
        NyaaFeedErrorCode code, {
        Map<String, String> headers = const <String, String>{},
      }) async {
        expect(
          await searchResponse(bytes, headers: headers),
          isA<NyaaFeedFormatException>().having(
            (NyaaFeedFormatException error) => error.code,
            'code',
            code,
          ),
        );
      }

      await expectCode(const <int>[], NyaaFeedErrorCode.emptyBody);
      await expectCode(
        utf8.encode(kNyaaNoResultsHtml),
        NyaaFeedErrorCode.unsupportedEncoding,
        headers: const <String, String>{
          'content-type': 'text/html; charset=shift_jis',
        },
      );
      await expectCode(<int>[
        ...utf8.encode('<html>'),
        0xff,
        ...utf8.encode('</html>'),
      ], NyaaFeedErrorCode.invalidUtf8);
      await expectCode(
        utf8.encode('<html><body/></html>'),
        NyaaFeedErrorCode.missingStructure,
      );
      // infoHash 不是 40 位十六进制 → 缺必需字段。
      await expectCode(
        utf8.encode(
          nyaaSearchHtml(const <NyaaHtmlRow>[
            NyaaHtmlRow(title: 'x', infoHash: 'aaaa', id: '1'),
          ]),
        ),
        NyaaFeedErrorCode.missingField,
      );
    });

    test('真实本地 HTTP：特殊字符 query/category 与 gzip 响应（transport 自动解压）', () async {
      final HttpServer server = await HttpServer.bind(
        InternetAddress.loopbackIPv4,
        0,
      );
      addTearDown(() => server.close(force: true));
      Uri? captured;
      server.listen((HttpRequest request) async {
        captured = request.uri;
        request.response.headers.contentType = ContentType.html;
        // nyaa 真实响应是 gzip；dart:io HttpClient 默认 autoUncompress，
        // createAppHttpClient 不能把它关掉——关了这里就拿到一坨二进制。
        request.response.headers.set(HttpHeaders.contentEncodingHeader, 'gzip');
        request.response.add(
          gzip.encode(
            utf8.encode(
              nyaaSearchHtml(<NyaaHtmlRow>[
                NyaaHtmlRow(
                  title: 'ソラ & 星',
                  infoHash: 'a' * 40,
                  id: '1',
                  trusted: true,
                ),
              ]),
            ),
          ),
        );
        await request.response.close();
      });

      final NyaaClient client = NyaaClient(
        baseUrl: 'http://${server.address.address}:${server.port}',
        minRequestInterval: Duration.zero,
      );
      addTearDown(client.close);
      final List<NyaaTorrent> items = await client.search(
        'ソラ & 星/空',
        category: '1_4 special',
        filter: '2',
      );
      expect(items.single.title, 'ソラ & 星');
      expect(items.single.trusted, isTrue);
      expect(
        items.single.pageUrl,
        'http://${server.address.address}:${server.port}/view/1',
      );
      expect(captured!.queryParameters, <String, String>{
        'q': 'ソラ & 星/空',
        'c': '1_4 special',
        'f': '2',
        's': 'seeders',
        'o': 'desc',
      });
    });
  });
}

const String _nyaaNamespaceForTest = 'https://nyaa.si/xmlns/nyaa';
