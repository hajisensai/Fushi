// 通用种子 RSS / Atom 解析：用各站真实返回的结构（字段、命名空间、CDATA、实体
// 转义原样照抄，只把条目内容换成固定值）钉住取值规则。
import 'package:fushi_engine/media/torrent/rss_feed_parser.dart';
import 'package:test/test.dart';

const String _hashA = '0123456789abcdef0123456789abcdef01234567';

/// nyaa.si `?page=rss&q=...`：link 是 .torrent、guid 是详情页，扩展字段在
/// `nyaa:` 命名空间。
const String _nyaaFeed = '''<?xml version="1.0" encoding="UTF-8"?>
<rss xmlns:atom="http://www.w3.org/2005/Atom" xmlns:nyaa="https://nyaa.si/xmlns/nyaa" version="2.0">
	<channel>
		<title>Nyaa - "frieren" - Torrent File RSS</title>
		<description>RSS Feed for "frieren"</description>
		<link>https://nyaa.si/</link>
		<atom:link href="https://nyaa.si/?page=rss" rel="self" type="application/rss+xml" />
		<item>
			<title>[SubsPlease] Sousou no Frieren - 01 (1080p) [F02B9CEE].mkv</title>
				<link>https://nyaa.si/download/1700000.torrent</link>
				<guid isPermaLink="true">https://nyaa.si/view/1700000</guid>
				<pubDate>Fri, 29 Sep 2023 15:00:00 -0000</pubDate>
				<nyaa:seeders>1234</nyaa:seeders>
				<nyaa:leechers>12</nyaa:leechers>
				<nyaa:downloads>45678</nyaa:downloads>
				<nyaa:infoHash>0123456789ABCDEF0123456789ABCDEF01234567</nyaa:infoHash>
				<nyaa:categoryId>1_2</nyaa:categoryId>
				<nyaa:category>Anime - English-translated</nyaa:category>
				<nyaa:size>1.4 GiB</nyaa:size>
				<nyaa:comments>3</nyaa:comments>
				<nyaa:trusted>Yes</nyaa:trusted>
				<nyaa:remake>No</nyaa:remake>
				<description><![CDATA[<a href="https://nyaa.si/view/1700000">#1700000 | [SubsPlease] Sousou no Frieren - 01 (1080p) [F02B9CEE].mkv</a> | 1.4 GiB | Anime - English-translated | 0123456789ABCDEF0123456789ABCDEF01234567]]></description>
		</item>
	</channel>
</rss>''';

/// 蜜柑 `RSS/Search?searchstr=`：guid 是标题文本，体积 / 时间在默认命名空间的
/// `<torrent>` 子元素里，种子地址与详情页都带 40 位 hash。
const String _mikanFeed = '''<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0"><channel><title>Mikan Project - 搜索结果:葬送的芙莉莲</title><link>http://mikanani.me/RSS/Search?searchstr=%E8%91%AC%E9%80%81%E7%9A%84%E8%8A%99%E8%8E%89%E8%8E%B2</link><description>Mikan Project - 搜索结果:葬送的芙莉莲</description>
<item><guid isPermaLink="false">[LoliHouse] 葬送的芙莉莲 / Sousou no Frieren - 01 [WebRip 1080p HEVC-10bit AAC][简繁内封字幕]</guid><link>https://mikanani.me/Home/Episode/0123456789abcdef0123456789abcdef01234567</link><title>[LoliHouse] 葬送的芙莉莲 / Sousou no Frieren - 01 [WebRip 1080p HEVC-10bit AAC][简繁内封字幕]</title><description>[LoliHouse] 葬送的芙莉莲 / Sousou no Frieren - 01 [WebRip 1080p HEVC-10bit AAC][简繁内封字幕][1.1GB]</description><torrent xmlns="https://mikanani.me/0.1/"><link>https://mikanani.me/Home/Episode/0123456789abcdef0123456789abcdef01234567</link><contentLength>1181116006</contentLength><pubDate>2023-09-30T08:31:33.123</pubDate></torrent><enclosure type="application/x-bittorrent" length="1181116006" url="https://mikanani.me/Download/20230930/0123456789abcdef0123456789abcdef01234567.torrent" /></item>
</channel></rss>''';

/// 动漫花园 `topics/rss/rss.xml?keyword=`：enclosure 是 base32 磁链（length 恒 1），
/// 标题包在 CDATA 里，链接是明文 http。
const String _dmhyFeed = '''<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:content="http://purl.org/rss/1.0/modules/content/" xmlns:wfw="http://wellformedweb.org/CommentAPI/">
<channel>
<title><![CDATA[動漫花園資源網 - 動漫愛好者的自由交流平台]]></title>
<link>http://share.dmhy.org</link>
<description><![CDATA[動漫花園資訊網是一個動漫愛好者交流的平台,提供最及時,最全面的動畫,漫畫,動漫音樂,動漫下載,BT,ED,動漫遊戲,資訊,分享,交流,讨论.]]></description>
<language>zh-cn</language>
<pubDate>Sat, 30 Sep 2023 17:10:00 +0800</pubDate>
<item>
<title><![CDATA[[喵萌奶茶屋&LoliHouse] 葬送的芙莉莲 / Sousou no Frieren - 01 [WebRip 1080p HEVC-10bit AAC][简繁日内封字幕]]]></title>
<link>http://share.dmhy.org/topics/view/650000_LoliHouse_Sousou_no_Frieren_-_01.html</link>
<pubDate>Sat, 30 Sep 2023 17:00:00 +0800</pubDate>
<description><![CDATA[<p>葬送的芙莉莲 第01话</p>]]></description>
<enclosure url="magnet:?xt=urn:btih:AERUKZ4JVPG66AJDIVTYTK6N54ASGRLH&amp;dn=&amp;tr=http%3A%2F%2F104.143.10.186%3A8000%2Fannounce" length="1" type="application/x-bittorrent"></enclosure>
<author><![CDATA[LoliHouse]]></author>
<guid isPermaLink="true" >http://share.dmhy.org/topics/view/650000_LoliHouse_Sousou_no_Frieren_-_01.html</guid>
<category domain="http://share.dmhy.org/topics/list/sort_id/2" ><![CDATA[動畫]]></category>
</item>
</channel>
</rss>''';

/// acg.rip `.xml?term=`：enclosure 是站内 .torrent（length 是种子文件大小）。
const String _acgRipFeed = '''<?xml version="1.0" encoding="UTF-8"?>
<rss version="2.0">
  <channel>
    <title>ACG.RIP</title>
    <description>ACG.RIP has super cow power</description>
    <link>https://acg.rip/.xml?term=frieren</link>
    <ttl>1800</ttl>
    <item>
      <title>[LoliHouse] Sousou no Frieren - 01 [WebRip 1080p HEVC-10bit AAC][简繁内封字幕]</title>
      <description>葬送的芙莉莲 第01话</description>
      <pubDate>Sat, 30 Sep 2023 09:01:02 -0700</pubDate>
      <link>https://acg.rip/t/290000</link>
      <guid>https://acg.rip/t/290000</guid>
      <enclosure url="https://acg.rip/t/290000.torrent" type="application/x-bittorrent" length="40960"/>
    </item>
  </channel>
</rss>''';

/// bangumi.moe `rss/search/<kw>`：id 是 24 位十六进制（不是 info hash），
/// enclosure 是带文件名的 .torrent。
const String _bangumiMoeFeed =
    '''<?xml version="1.0" encoding="UTF-8"?><rss xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:content="http://purl.org/rss/1.0/modules/content/" xmlns:atom="http://www.w3.org/2005/Atom" version="2.0"><channel><title><![CDATA[Bangumi Moe Search Results]]></title><description><![CDATA[Bangumi Moe Search Results]]></description><link>https://bangumi.moe</link><generator>RSS for Node</generator><lastBuildDate>Sat, 30 Sep 2023 10:00:00 GMT</lastBuildDate><item><title><![CDATA[[LoliHouse] 葬送的芙莉莲 / Sousou no Frieren - 01 [WebRip 1080p HEVC-10bit AAC]]]></title><description><![CDATA[<p>葬送的芙莉莲</p>]]></description><link>https://bangumi.moe/torrent/651800aa1234567890abcdef</link><guid isPermaLink="true">https://bangumi.moe/torrent/651800aa1234567890abcdef</guid><pubDate>Sat, 30 Sep 2023 09:00:00 GMT</pubDate><enclosure url="https://bangumi.moe/download/torrent/651800aa1234567890abcdef/%5BLoliHouse%5D%20Sousou%20no%20Frieren%20-%2001.torrent" type="application/x-bittorrent"/></item></channel></rss>''';

const String _atomFeed = '''<?xml version="1.0" encoding="utf-8"?>
<feed xmlns="http://www.w3.org/2005/Atom">
  <title>Example torrents</title>
  <id>urn:example:feed</id>
  <updated>2023-09-30T09:00:00Z</updated>
  <entry>
    <title>Example Movie 2023 1080p WEB-DL</title>
    <id>urn:example:entry:1</id>
    <updated>2023-09-30T09:00:00+08:00</updated>
    <link rel="alternate" href="https://tracker.example/t/1"/>
    <link rel="enclosure" type="application/x-bittorrent" href="https://tracker.example/t/1.torrent" length="2147483648"/>
  </entry>
  <entry>
    <title>Magnet only</title>
    <id>urn:example:entry:2</id>
    <published>2023-09-29T10:00:00Z</published>
    <content type="html">&lt;a href="magnet:?xt=urn:btih:0123456789abcdef0123456789abcdef01234567&amp;amp;dn=x"&gt;magnet&lt;/a&gt;</content>
  </entry>
</feed>''';

/// Torznab 风格（Jackett 等转出的 RSS）：attr 里给 magneturl / seeders / peers / grabs / size。
const String _torznabStyleFeed = '''<?xml version="1.0" encoding="UTF-8"?>
<rss version="2.0" xmlns:torznab="http://torznab.com/schemas/2015/feed">
  <channel>
    <item>
      <title>Torznab Release 720p</title>
      <guid>https://indexer.example/details/9?passkey=SECRET</guid>
      <link>https://indexer.example/dl/9?passkey=SECRET</link>
      <pubDate>Sat, 30 Sep 2023 09:00:00 +0000</pubDate>
      <torznab:attr name="magneturl" value="magnet:?xt=urn:btih:0123456789abcdef0123456789abcdef01234567"/>
      <torznab:attr name="seeders" value="7"/>
      <torznab:attr name="peers" value="3"/>
      <torznab:attr name="grabs" value="99"/>
      <torznab:attr name="size" value="734003200"/>
    </item>
  </channel>
</rss>''';

void main() {
  group('parseRssSearchFeed 真实站点格式', () {
    test('Nyaa：.torrent + nyaa:infoHash / size / seeders / trusted', () {
      final RssSearchItem item = parseRssSearchFeed(_nyaaFeed).single;
      expect(
        item.title,
        '[SubsPlease] Sousou no Frieren - 01 (1080p) [F02B9CEE].mkv',
      );
      expect(item.magnetUri, isNull);
      expect(
        item.torrentUri,
        Uri.parse('https://nyaa.si/download/1700000.torrent'),
      );
      expect(item.detailsUrl, 'https://nyaa.si/view/1700000');
      expect(item.infoHash, _hashA);
      expect(item.sizeBytes, (1.4 * 1024 * 1024 * 1024).round());
      expect(item.seeders, 1234);
      expect(item.leechers, 12);
      expect(item.downloads, 45678);
      expect(item.category, '1_2');
      expect(item.trusted, isTrue);
      expect(item.publishedAt, DateTime.utc(2023, 9, 29, 15));
    });

    test('蜜柑：<torrent> 子元素的 contentLength / ISO 时间，hash 从种子地址取', () {
      final RssSearchItem item = parseRssSearchFeed(_mikanFeed).single;
      expect(
        item.torrentUri.toString(),
        'https://mikanani.me/Download/20230930/$_hashA.torrent',
      );
      expect(item.detailsUrl, 'https://mikanani.me/Home/Episode/$_hashA');
      expect(item.infoHash, _hashA);
      expect(item.sizeBytes, 1181116006);
      expect(item.publishedAt, DateTime.utc(2023, 9, 30, 8, 31, 33, 123));
      expect(item.seeders, 0, reason: '蜜柑不给做种数');
      expect(item.trusted, isFalse);
    });

    test('动漫花园：enclosure 里的 base32 磁链（实体反转义）解出 hex hash，length=1 不当体积', () {
      final RssSearchItem item = parseRssSearchFeed(_dmhyFeed).single;
      expect(item.title, startsWith('[喵萌奶茶屋&LoliHouse] 葬送的芙莉莲'));
      expect(
        item.magnetUri,
        startsWith(
          'magnet:?xt=urn:btih:AERUKZ4JVPG66AJDIVTYTK6N54ASGRLH&dn=&tr=',
        ),
      );
      expect(item.torrentUri, isNull, reason: '有磁链就不再用 .torrent');
      expect(item.infoHash, '0123456789abcdef0123456789abcdef01234567');
      expect(item.sizeBytes, isNull);
      expect(
        item.detailsUrl,
        startsWith('http://share.dmhy.org/topics/view/650000_'),
      );
      expect(item.category, '動畫');
      expect(item.publishedAt, DateTime.utc(2023, 9, 30, 9));
    });

    test('acg.rip：enclosure .torrent，种子文件大小（40 KB）不当资源体积', () {
      final RssSearchItem item = parseRssSearchFeed(_acgRipFeed).single;
      expect(item.torrentUri, Uri.parse('https://acg.rip/t/290000.torrent'));
      expect(item.detailsUrl, 'https://acg.rip/t/290000');
      expect(item.infoHash, isNull);
      expect(item.sizeBytes, isNull);
      expect(item.publishedAt, DateTime.utc(2023, 9, 30, 16, 1, 2));
    });

    test('bangumi.moe：24 位站内 id 不被误认成 info hash', () {
      final RssSearchItem item = parseRssSearchFeed(_bangumiMoeFeed).single;
      expect(
        item.torrentUri.toString(),
        startsWith(
          'https://bangumi.moe/download/torrent/651800aa1234567890abcdef/',
        ),
      );
      expect(item.infoHash, isNull);
      expect(
        item.detailsUrl,
        'https://bangumi.moe/torrent/651800aa1234567890abcdef',
      );
      expect(item.publishedAt, DateTime.utc(2023, 9, 30, 9));
    });

    test('Atom：rel=enclosure 的 .torrent 与 content 里的磁链都认', () {
      final List<RssSearchItem> items = parseRssSearchFeed(_atomFeed);
      expect(items, hasLength(2));
      expect(
        items.first.torrentUri,
        Uri.parse('https://tracker.example/t/1.torrent'),
      );
      expect(items.first.detailsUrl, 'https://tracker.example/t/1');
      expect(items.first.sizeBytes, 2147483648);
      expect(items.first.publishedAt, DateTime.utc(2023, 9, 30, 1));
      expect(items.last.magnetUri, 'magnet:?xt=urn:btih:$_hashA&dn=x');
      expect(items.last.infoHash, _hashA);
      expect(items.last.publishedAt, DateTime.utc(2023, 9, 29, 10));
    });

    test(
      'Torznab attr：magneturl / seeders / peers / grabs / size；带 passkey 的地址不当详情页',
      () {
        final RssSearchItem item = parseRssSearchFeed(_torznabStyleFeed).single;
        expect(item.magnetUri, 'magnet:?xt=urn:btih:$_hashA');
        expect(item.infoHash, _hashA);
        expect(item.seeders, 7);
        expect(item.leechers, 3);
        expect(item.downloads, 99);
        expect(item.sizeBytes, 734003200);
        expect(item.detailsUrl, isNull);
      },
    );

    test('remoteId 稳定（同一 guid 两次解析一致），不同条目不同', () {
      expect(
        parseRssSearchFeed(_nyaaFeed).single.remoteId,
        parseRssSearchFeed(_nyaaFeed).single.remoteId,
      );
      expect(
        parseRssSearchFeed(_nyaaFeed).single.remoteId,
        isNot(parseRssSearchFeed(_acgRipFeed).single.remoteId),
      );
    });
  });

  group('parseRssSearchFeed 边界', () {
    test('没有下载地址（无磁链、无 .torrent）的条目跳过', () {
      const String feed =
          '<rss version="2.0"><channel>'
          '<item><title>page only</title><link>https://site.example/view/1</link></item>'
          '<item><title>ok</title><link>https://site.example/dl/2.torrent</link></item>'
          '<item><title></title><link>https://site.example/dl/3.torrent</link></item>'
          '</channel></rss>';
      expect(
        parseRssSearchFeed(feed).map((RssSearchItem i) => i.title),
        <String>['ok'],
      );
    });

    test('结构有效但没有条目：空列表', () {
      expect(
        parseRssSearchFeed(
          '<rss version="2.0"><channel><title>x</title></channel></rss>',
        ),
        isEmpty,
      );
    });

    test('不是 XML / 根不是 rss/feed（如被拦下来的 HTML 页）：抛 FormatException，不伪装成 0 条', () {
      expect(
        () => parseRssSearchFeed('<html><body>Just a moment...</body>'),
        throwsFormatException,
      );
      expect(
        () => parseRssSearchFeed(
          '<!doctype html><html><body>blocked</body></html>',
        ),
        throwsFormatException,
      );
      expect(() => parseRssSearchFeed(''), throwsFormatException);
      expect(() => parseRssSearchFeed('{"items":[]}'), throwsFormatException);
    });
  });

  group('parseRssDate / parseRssPubDate / parseHumanByteSize', () {
    test('RFC 822 带偏移归一到 UTC；字母时区按 0', () {
      expect(
        parseRssPubDate('Fri, 03 Nov 2023 12:30:00 -0000'),
        DateTime.utc(2023, 11, 3, 12, 30),
      );
      expect(
        parseRssPubDate('Fri, 03 Nov 2023 21:30:00 +0900'),
        DateTime.utc(2023, 11, 3, 12, 30),
      );
      expect(
        parseRssPubDate('Sat, 30 Sep 2023 09:00:00 GMT'),
        DateTime.utc(2023, 9, 30, 9),
      );
      expect(parseRssPubDate('nonsense'), isNull);
      expect(parseRssPubDate(''), isNull);
    });

    test('ISO 8601：带时区换算，不带时区按 UTC（不随设备时区漂移）', () {
      expect(
        parseRssDate('2023-09-30T09:00:00+08:00'),
        DateTime.utc(2023, 9, 30, 1),
      );
      expect(
        parseRssDate('2023-09-30T09:00:00Z'),
        DateTime.utc(2023, 9, 30, 9),
      );
      expect(parseRssDate('2023-09-30T09:00:00'), DateTime.utc(2023, 9, 30, 9));
      expect(parseRssDate('   '), isNull);
    });

    test('体积：二进制 / 十进制单位都按 1024 进位，纯数字按字节', () {
      expect(parseHumanByteSize('1.4 GiB'), (1.4 * 1024 * 1024 * 1024).round());
      expect(parseHumanByteSize('700 MB'), 700 * 1024 * 1024);
      expect(parseHumanByteSize('1.2GB'), (1.2 * 1024 * 1024 * 1024).round());
      expect(parseHumanByteSize('980 KiB'), 980 * 1024);
      expect(parseHumanByteSize('123 B'), 123);
      expect(parseHumanByteSize('4096'), 4096);
      expect(parseHumanByteSize('big'), isNull);
      expect(parseHumanByteSize(''), isNull);
    });
  });
}
