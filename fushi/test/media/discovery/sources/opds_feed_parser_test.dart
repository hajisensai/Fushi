/// OPDS 1.2 (Atom) / 2.0 (JSON) 解析器与格式表的契约测试。
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:fushi/src/media/discovery/discovery_models.dart';
import 'package:fushi/src/media/discovery/sources/opds/opds_atom_parser.dart';
import 'package:fushi/src/media/discovery/sources/opds/opds_feed.dart';
import 'package:fushi/src/media/discovery/sources/opds/opds_json_parser.dart';

final Uri _base = Uri.parse('https://books.example.com/api/v1/opds');

void main() {
  group('OPDS 1.2 Atom', () {
    test('导航 feed → 导航条目，相对 href 按 feed 地址 resolve', () {
      final OpdsFeed feed = parseOpdsAtomFeed('''
<?xml version="1.0" encoding="utf-8"?>
<feed xmlns="http://www.w3.org/2005/Atom">
  <title>BookOrbit</title>
  <entry>
    <title>All Books</title>
    <link href="/api/v1/opds/books"
          type="application/atom+xml;profile=opds-catalog;kind=acquisition"/>
  </entry>
  <entry>
    <title>Series</title>
    <link rel="subsection" href="series"
          type="application/atom+xml;profile=opds-catalog;kind=navigation"/>
  </entry>
</feed>
''', baseUri: _base);

      expect(feed.entries, hasLength(2));
      final OpdsNavigationEntry first =
          feed.entries.first as OpdsNavigationEntry;
      expect(first.title, 'All Books');
      expect(first.href, 'https://books.example.com/api/v1/opds/books');
      // 相对 href 相对 feed 自身所在目录解析。
      final OpdsNavigationEntry second = feed.entries[1] as OpdsNavigationEntry;
      expect(second.href, 'https://books.example.com/api/v1/series');
    });

    test('acquisition feed → 出版物条目，带作者/封面/体积/下一页', () {
      final OpdsFeed feed = parseOpdsAtomFeed('''
<?xml version="1.0" encoding="utf-8"?>
<feed xmlns="http://www.w3.org/2005/Atom">
  <link rel="next" href="/api/v1/opds/books?page=2"
        type="application/atom+xml;profile=opds-catalog"/>
  <entry>
    <title>雪国</title>
    <id>urn:uuid:1234</id>
    <author><name>川端康成</name></author>
    <updated>2026-01-02T03:04:05Z</updated>
    <summary>ノーベル賞作品</summary>
    <link rel="http://opds-spec.org/image" href="/cover/1.jpg" type="image/jpeg"/>
    <link rel="http://opds-spec.org/acquisition"
          href="/api/v1/opds/download/1"
          type="application/epub+zip" length="524288"/>
  </entry>
</feed>
''', baseUri: _base);

      expect(
          feed.nextHref, 'https://books.example.com/api/v1/opds/books?page=2');
      final OpdsPublicationEntry pub =
          feed.entries.single as OpdsPublicationEntry;
      expect(pub.title, '雪国');
      expect(pub.id, 'urn:uuid:1234');
      expect(pub.author, '川端康成');
      expect(pub.updatedText, '2026-01-02T03:04:05Z');
      expect(pub.summary, 'ノーベル賞作品');
      expect(pub.coverHref, 'https://books.example.com/cover/1.jpg');
      final OpdsAcquisitionLink link = pub.links.single;
      expect(link.href, 'https://books.example.com/api/v1/opds/download/1');
      expect(link.fileType, OpdsFileType.epub);
      expect(link.sizeBytes, 524288);
    });

    test(
      '命名空间守卫：带前缀的 <atom:entry>/<atom:title> 必须照样解析出条目',
      () {
        // 这正是 epub_parser 栽过的跟头：package:xml 不传 namespace 时按
        // qualified name 匹配，'entry' 匹配不到 <atom:entry>，整个目录会
        // 解析成 0 条，表现为「这台 OPDS 服务器是空的」。
        final OpdsFeed feed = parseOpdsAtomFeed('''
<?xml version="1.0" encoding="utf-8"?>
<atom:feed xmlns:atom="http://www.w3.org/2005/Atom">
  <atom:link rel="next" href="/next"/>
  <atom:entry>
    <atom:title>Prefixed Book</atom:title>
    <atom:id>urn:uuid:9</atom:id>
    <atom:author><atom:name>Someone</atom:name></atom:author>
    <atom:link rel="http://opds-spec.org/acquisition"
               href="/dl/9" type="application/epub+zip"/>
  </atom:entry>
</atom:feed>
''', baseUri: _base);

        expect(feed.entries, hasLength(1),
            reason: '带命名空间前缀的 feed 必须与裸 feed 等价解析');
        final OpdsPublicationEntry pub =
            feed.entries.single as OpdsPublicationEntry;
        expect(pub.title, 'Prefixed Book');
        expect(pub.author, 'Someone');
        expect(pub.links.single.fileType, OpdsFileType.epub);
        expect(feed.nextHref, 'https://books.example.com/next');
      },
    );

    test('rel=search：描述文档地址与内联模板两种写法都识别', () {
      final OpdsFeed viaDescription = parseOpdsAtomFeed('''
<feed xmlns="http://www.w3.org/2005/Atom">
  <link rel="search" href="/opensearch.xml"
        type="application/opensearchdescription+xml"/>
</feed>
''', baseUri: _base);
      expect(viaDescription.searchDescriptionHref,
          'https://books.example.com/opensearch.xml');
      expect(viaDescription.searchTemplate, isNull);

      final OpdsFeed inline = parseOpdsAtomFeed('''
<feed xmlns="http://www.w3.org/2005/Atom">
  <link rel="search" href="/search?q={searchTerms}"
        type="application/atom+xml"/>
</feed>
''', baseUri: _base);
      // 花括号不能被 Uri.resolve 百分号编码，否则下游替换永远匹配不上。
      expect(inline.searchTemplate,
          'https://books.example.com/search?q={searchTerms}');
    });

    test('OpenSearch 描述文档 → 模板，优先 atom 类型的 Url', () {
      const String xml = '''
<OpenSearchDescription xmlns="http://a9.com/-/spec/opensearch/1.1/">
  <Url type="text/html" template="/html?q={searchTerms}"/>
  <Url type="application/atom+xml;profile=opds-catalog"
       template="/api/v1/opds/search?q={searchTerms}"/>
</OpenSearchDescription>
''';
      expect(
        parseOpenSearchTemplate(xml, baseUri: _base),
        'https://books.example.com/api/v1/opds/search?q={searchTerms}',
      );
    });

    test('partial entry：根是 <entry> 的单条目文档也要能解析', () {
      // COPS / Calibre-Web 的出版物条目可以只带一条指向单 entry 文档的
      // alternate 链接。不兜这一形态，那种条目就是个点进去报
      //「不是可读的 OPDS 目录」的死目录。
      final OpdsFeed feed = parseOpdsAtomFeed('''
<?xml version="1.0" encoding="utf-8"?>
<entry xmlns="http://www.w3.org/2005/Atom">
  <title>Partial Book</title>
  <id>urn:uuid:partial</id>
  <link rel="http://opds-spec.org/acquisition" href="/dl/p"
        type="application/epub+zip"/>
</entry>
''', baseUri: _base);
      final OpdsPublicationEntry pub =
          feed.entries.single as OpdsPublicationEntry;
      expect(pub.title, 'Partial Book');
      expect(pub.links.single.fileType, OpdsFileType.epub);
    });

    test('既没有 <feed> 也没有 <entry> 才算畸形', () {
      expect(
        () =>
            parseOpdsAtomFeed('<html><body>nope</body></html>', baseUri: _base),
        throwsA(isA<FormatException>()),
      );
    });

    test('无标题条目与无链接条目被丢弃，不产生点不开的空行', () {
      final OpdsFeed feed = parseOpdsAtomFeed('''
<feed xmlns="http://www.w3.org/2005/Atom">
  <entry><title></title></entry>
  <entry><title>No links at all</title></entry>
</feed>
''', baseUri: _base);
      expect(feed.entries, isEmpty);
    });
  });

  group('OPDS 2.0 JSON', () {
    test('navigation + publications + groups 摊平，next/search 归一', () {
      final OpdsFeed feed = parseOpdsJsonFeed('''
{
  "metadata": {"title": "Kavita"},
  "links": [
    {"rel": "self", "href": "/opds/v2", "type": "application/opds+json"},
    {"rel": "next", "href": "/opds/v2?page=2"},
    {"rel": "search", "href": "/opds/v2/search{?query}", "templated": true}
  ],
  "navigation": [
    {"href": "/opds/v2/libraries", "title": "Libraries",
     "type": "application/opds+json"}
  ],
  "publications": [
    {
      "metadata": {"title": "Book A", "author": "Writer",
                   "identifier": "urn:x:1", "modified": "2026-02-03"},
      "links": [{"rel": "http://opds-spec.org/acquisition",
                 "href": "/dl/a", "type": "application/epub+zip"}],
      "images": [{"href": "/cover/a.jpg", "type": "image/jpeg"}]
    }
  ],
  "groups": [
    {
      "metadata": {"title": "Recent"},
      "publications": [
        {
          "metadata": {"title": "Comic B"},
          "links": [{"rel": "http://opds-spec.org/acquisition",
                     "href": "/dl/b",
                     "type": "application/vnd.comicbook+zip"}]
        }
      ]
    }
  ]
}
''', baseUri: _base);

      expect(feed.nextHref, 'https://books.example.com/opds/v2?page=2');
      // RFC 6570 的 {?query} 必须展开成 ?query=<占位符>，否则拼出来的是
      // https://host/searchVALUE 这种废 URL。
      expect(feed.searchTemplate,
          'https://books.example.com/opds/v2/search?query={searchTerms}');

      expect(feed.entries, hasLength(3));
      expect((feed.entries[0] as OpdsNavigationEntry).title, 'Libraries');
      final OpdsPublicationEntry a = feed.entries[1] as OpdsPublicationEntry;
      expect(a.title, 'Book A');
      expect(a.author, 'Writer');
      expect(a.id, 'urn:x:1');
      expect(a.coverHref, 'https://books.example.com/cover/a.jpg');
      final OpdsPublicationEntry b = feed.entries[2] as OpdsPublicationEntry;
      expect(b.title, 'Comic B');
      expect(b.links.single.fileType, OpdsFileType.cbz);
    });

    test('标量字段的多形态：title 语言映射 / author 三种写法 / rel 数组', () {
      final OpdsFeed feed = parseOpdsJsonFeed('''
{
  "publications": [
    {
      "metadata": {"title": {"en": "English Title", "ja": "日本語"},
                   "author": [{"name": "First Author"}, "Second"]},
      "links": [{"rel": ["collection", "http://opds-spec.org/acquisition"],
                 "href": "/dl/x", "type": "application/pdf"}]
    },
    {
      "metadata": {"title": "Obj author", "author": {"name": "Named"}},
      "links": [{"rel": "http://opds-spec.org/acquisition",
                 "href": "/dl/y", "type": "application/epub+zip"}]
    }
  ]
}
''', baseUri: _base);

      final OpdsPublicationEntry first =
          feed.entries[0] as OpdsPublicationEntry;
      expect(first.title, 'English Title');
      expect(first.author, 'First Author');
      expect(first.links.single.fileType, OpdsFileType.pdf,
          reason: 'rel 是数组时也要认出 acquisition');
      expect((feed.entries[1] as OpdsPublicationEntry).author, 'Named');
    });

    test('没有 acquisition 链接的出版物被丢弃', () {
      final OpdsFeed feed = parseOpdsJsonFeed('''
{"publications": [
  {"metadata": {"title": "No download"},
   "links": [{"rel": "self", "href": "/x"}]}
]}
''', baseUri: _base);
      expect(feed.entries, isEmpty);
    });
  });

  group('OpdsFileType', () {
    test('MIME 带参数段与大小写差异都能定型', () {
      expect(OpdsFileType.fromMediaType('application/epub+zip;charset=utf-8'),
          OpdsFileType.epub);
      expect(OpdsFileType.fromMediaType('APPLICATION/PDF'), OpdsFileType.pdf);
    });

    test('别名表：Komga/Calibre 插件的非规范 MIME 也认', () {
      expect(OpdsFileType.fromMediaType('application/x-cbz'), OpdsFileType.cbz);
      expect(OpdsFileType.fromMediaType('application/vnd.comicbook+rar'),
          OpdsFileType.cbr);
    });

    test('epub 与 cbz 不许被混为一谈（两者都是 zip 壳）', () {
      // 模糊包含匹配（contains('zip')）会让漫画进小说域、epub 进漫画域，
      // 且只在混合库里暴露。
      expect(OpdsFileType.fromMediaType('application/epub+zip')!.kind,
          DiscoveryMediaKind.novel);
      expect(OpdsFileType.fromMediaType('application/vnd.comicbook+zip')!.kind,
          DiscoveryMediaKind.manga);
    });

    test('MIME 认不出时按 URL 扩展名兜底', () {
      expect(OpdsFileType.fromPath('/files/book.EPUB'), OpdsFileType.epub);
      expect(OpdsFileType.fromPath('/files/vol1.cbz'), OpdsFileType.cbz);
      expect(OpdsFileType.fromPath('/opds/download/1234'), isNull);
    });
  });

  group('bestLinkFor', () {
    OpdsPublicationEntry entryWith(List<OpdsAcquisitionLink> links) =>
        OpdsPublicationEntry(title: 't', id: 'i', links: links);

    OpdsAcquisitionLink link(
      OpdsFileType type, {
      OpdsAcquisitionRel rel = OpdsAcquisitionRel.generic,
    }) =>
        OpdsAcquisitionLink(
            href: 'https://h/${type.extension}', rel: rel, fileType: type);

    test('同域多格式时优先本仓导入器吃得下的，再按 epub > pdf > txt', () {
      final OpdsPublicationEntry entry = entryWith(<OpdsAcquisitionLink>[
        link(OpdsFileType.mobi),
        link(OpdsFileType.pdf),
        link(OpdsFileType.epub),
      ]);
      expect(entry.bestLinkFor(DiscoveryMediaKind.novel)!.fileType,
          OpdsFileType.epub);
    });

    test('只有不可导入格式时仍给出链接（宁可下下来，也别显示成空目录）', () {
      final OpdsPublicationEntry entry =
          entryWith(<OpdsAcquisitionLink>[link(OpdsFileType.mobi)]);
      expect(entry.bestLinkFor(DiscoveryMediaKind.novel)!.fileType,
          OpdsFileType.mobi);
    });

    test('跨域不串：漫画域拿不到 epub，小说域拿不到 cbz', () {
      final OpdsPublicationEntry entry = entryWith(<OpdsAcquisitionLink>[
        link(OpdsFileType.epub),
        link(OpdsFileType.cbz),
      ]);
      expect(entry.bestLinkFor(DiscoveryMediaKind.novel)!.fileType,
          OpdsFileType.epub);
      expect(entry.bestLinkFor(DiscoveryMediaKind.manga)!.fileType,
          OpdsFileType.cbz);
      expect(entry.bestLinkFor(DiscoveryMediaKind.game), isNull);
    });

    test('buy/borrow/subscribe 不是直链，不许当下载物', () {
      // 这些 rel 指向交易流程页，下下来是个 HTML 错误页并以导入失败收场。
      for (final OpdsAcquisitionRel rel in <OpdsAcquisitionRel>[
        OpdsAcquisitionRel.buy,
        OpdsAcquisitionRel.borrow,
        OpdsAcquisitionRel.subscribe,
      ]) {
        final OpdsPublicationEntry entry = entryWith(
          <OpdsAcquisitionLink>[link(OpdsFileType.epub, rel: rel)],
        );
        expect(entry.bestLinkFor(DiscoveryMediaKind.novel), isNull,
            reason: '$rel 不该被当成可下载直链');
      }
      final OpdsPublicationEntry openAccess = entryWith(<OpdsAcquisitionLink>[
        link(OpdsFileType.epub, rel: OpdsAcquisitionRel.openAccess),
      ]);
      expect(openAccess.bestLinkFor(DiscoveryMediaKind.novel), isNotNull);
    });
  });
}
