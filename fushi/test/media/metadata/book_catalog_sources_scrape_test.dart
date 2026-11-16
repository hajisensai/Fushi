import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_engine/media/metadata/books/book_catalog.dart';
import 'package:fushi_engine/media/metadata/books/ndl_search.dart';
import 'package:fushi_engine/media/metadata/books/rakuten_books.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:fushi/src/media/metadata/book_cover_scrape_dialog.dart';
import 'package:fushi/src/media/metadata/book_metadata_scrape_facade.dart';
import 'package:fushi/src/media/metadata/book_metadata_scraper.dart';

/// 录制的真实响应与引擎层共用一份（packages/fushi_engine/test/.../fixtures）。
String _fixture(String name) => File(
  '../packages/fushi_engine/test/media/metadata/books/fixtures/$name',
).readAsStringSync();

http.Response _utf8(String body, [int status = 200]) =>
    http.Response.bytes(utf8.encode(body), status);

/// 按 host 分发的离线书目源；记下每个请求。
class _Offline {
  final List<Uri> requests = <Uri>[];
  int status = 200;

  http.Client get client => MockClient((http.Request req) async {
    requests.add(req.url);
    if (status != 200) return http.Response('oops', status);
    switch (req.url.host) {
      case 'graphql.anilist.co':
        return _utf8(_fixture('anilist_search_kusuriya.json'));
      case 'api.openbd.jp':
        return _utf8(_fixture('openbd_9784065141113.json'));
      case 'ndlsearch.ndl.go.jp':
        return _utf8(_fixture('ndl_opensearch_kusuriya.rss'));
      case 'openapi.rakuten.co.jp':
        return _utf8(_fixture('rakuten_books_search_formatv2.json'));
    }
    return http.Response('', 404);
  });

  BookMetadataScraper scraper({RakutenBooksCredentials? rakuten}) {
    final http.Client c = client;
    return BookMetadataScraper(
      client: c,
      catalogHttp: BookCatalogHttp(client: c, throttle: false),
      rakuten: rakuten,
    );
  }
}

void main() {
  const RakutenBooksCredentials creds = RakutenBooksCredentials(
    applicationId: 'app',
    accessKey: 'pk_x',
  );

  test('AniList：候选带作者 / 横幅，源与详情页正确；贴 URL 走按 id 直取', () async {
    final _Offline offline = _Offline();
    final BookMetadataScrapeFacade facade = BookMetadataScrapeFacade(
      scraper: offline.scraper(),
    );
    final List<BookScrapeCandidate> found = await facade.search(
      source: BookScrapeSource.anilist,
      query: '薬屋のひとりごと',
    );
    final BookScrapeCandidate c = found.single;
    expect(c.source, BookScrapeSource.anilist);
    expect(c.title, '薬屋のひとりごと');
    expect(c.author, '日向夏');
    expect(c.bannerUrl, contains('/banner/'));
    expect(c.detailUrl, 'https://anilist.co/manga/99026');

    await facade.search(
      source: BookScrapeSource.anilist,
      query: 'https://anilist.co/manga/99026/Kusuriya',
    );
    expect(offline.requests, hasLength(2));
  });

  test('openBD：没有 ISBN 不发请求；有 ISBN 回落 NDL 缩略图，下载带 Referer', () async {
    final _Offline offline = _Offline();
    final List<Map<String, String>?> downloadHeaders = <Map<String, String>?>[];
    final Directory tmp = await Directory.systemTemp.createTemp('fushi_bc_');
    addTearDown(() => tmp.delete(recursive: true));
    final BookMetadataScrapeFacade facade = BookMetadataScrapeFacade(
      scraper: offline.scraper(),
      downloadImage: (String url, {Map<String, String>? headers}) async {
        downloadHeaders.add(headers);
        return File('${tmp.path}/x.jpg')..writeAsBytesSync(<int>[1]);
      },
    );
    expect(
      await facade.search(
        source: BookScrapeSource.openbd,
        query: '私の愛人になりなさいっ!',
      ),
      isEmpty,
    );
    expect(offline.requests, isEmpty);

    final BookScrapeCandidate c = (await facade.search(
      source: BookScrapeSource.openbd,
      query: 'ISBN978-4-06-514111-3',
    )).single;
    expect(c.isbn, '9784065141113');
    expect(c.series, '講談社ラノベ文庫');
    expect(c.coverUrl, ndlThumbnailUrl('9784065141113'));
    await facade.downloadCover(c);
    expect(downloadHeaders.single, kNdlThumbnailHeaders);
  });

  test('NDL：按书名搜，ISBN 当 id，fetchById 走 isbn=', () async {
    final _Offline offline = _Offline();
    final BookMetadataScrapeFacade facade = BookMetadataScrapeFacade(
      scraper: offline.scraper(),
    );
    final List<BookScrapeCandidate> found = await facade.search(
      source: BookScrapeSource.ndl,
      query: '薬屋のひとりごと',
    );
    expect(found.first.subjectId, '9784301001959');
    expect(found.first.publisher, 'スクウェア・エニックス');
    expect(found.first.coverHeaders, kNdlThumbnailHeaders);
    final BookScrapeCandidate? byId = await facade.fetchById(
      source: BookScrapeSource.ndl,
      id: '978-4-301-00195-9',
    );
    expect(byId?.subjectId, '9784301001959');
    expect(offline.requests.last.queryParameters['isbn'], '9784301001959');
  });

  test('楽天：没凭据不可用、搜索抛 BookScrapeException 且不发请求；有凭据正常', () async {
    final _Offline offline = _Offline();
    final BookMetadataScrapeFacade without = BookMetadataScrapeFacade(
      scraper: offline.scraper(),
    );
    expect(without.isSourceAvailable(BookScrapeSource.rakuten), isFalse);
    expect(without.isSourceAvailable(BookScrapeSource.ndl), isTrue);
    await expectLater(
      without.search(source: BookScrapeSource.rakuten, query: 'x'),
      throwsA(isA<BookScrapeException>()),
    );
    expect(offline.requests, isEmpty);

    final BookMetadataScrapeFacade withKey = BookMetadataScrapeFacade(
      scraper: offline.scraper(rakuten: creds),
    );
    expect(withKey.isSourceAvailable(BookScrapeSource.rakuten), isTrue);
    final BookScrapeCandidate c = (await withKey.search(
      source: BookScrapeSource.rakuten,
      query: '薬屋のひとりごと',
    )).single;
    expect(c.source, BookScrapeSource.rakuten);
    expect(c.series, 'ヒーロー文庫');
    expect(c.detailUrl, 'https://books.rakuten.co.jp/rb/12900000/');
  });

  test('门面自建 scraper 时带上传入的楽天凭据', () {
    final BookMetadataScrapeFacade withKey = BookMetadataScrapeFacade(
      rakuten: creds,
    );
    final BookMetadataScrapeFacade without = BookMetadataScrapeFacade();
    addTearDown(withKey.close);
    addTearDown(without.close);
    expect(withKey.isSourceAvailable(BookScrapeSource.rakuten), isTrue);
    expect(without.isSourceAvailable(BookScrapeSource.rakuten), isFalse);
  });

  test('源站非 2xx → BookScrapeException 带状态码（弹窗据此给「源站报错」）', () async {
    final _Offline offline = _Offline()..status = 503;
    final BookMetadataScrapeFacade facade = BookMetadataScrapeFacade(
      scraper: offline.scraper(),
    );
    for (final BookScrapeSource source in <BookScrapeSource>[
      BookScrapeSource.anilist,
      BookScrapeSource.ndl,
    ]) {
      await expectLater(
        facade.search(source: source, query: '薬屋'),
        throwsA(
          isA<BookScrapeException>().having(
            (BookScrapeException e) => e.statusCode,
            'statusCode',
            503,
          ),
        ),
      );
    }
    await expectLater(
      facade.fetchById(source: BookScrapeSource.openbd, id: '9784065141113'),
      throwsA(isA<BookScrapeException>()),
    );
  });

  test('弹窗初始源：DLsite 编号 > ISBN（openBD）> Bangumi；楽天无凭据不列', () {
    expect(bookScrapeInitialState('RJ01014447 某作'), (
      BookScrapeSource.dlsite,
      'RJ01014447',
    ));
    expect(bookScrapeInitialState('978-4-06-514111-3'), (
      BookScrapeSource.openbd,
      '9784065141113',
    ));
    expect(bookScrapeInitialState('薬屋のひとりごと'), (
      BookScrapeSource.bangumi,
      '薬屋のひとりごと',
    ));
    expect(
      bookScrapeSelectableSources(rakutenAvailable: false),
      isNot(contains(BookScrapeSource.rakuten)),
    );
    expect(
      bookScrapeSelectableSources(rakutenAvailable: true),
      BookScrapeSource.values,
    );
  });
}
