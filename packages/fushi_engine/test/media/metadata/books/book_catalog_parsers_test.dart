import 'dart:convert';
import 'dart:io';

import 'package:fushi_engine/media/metadata/books/anilist_novels.dart';
import 'package:fushi_engine/media/metadata/books/book_catalog.dart';
import 'package:fushi_engine/media/metadata/books/ndl_search.dart';
import 'package:fushi_engine/media/metadata/books/openbd.dart';
import 'package:fushi_engine/media/metadata/books/rakuten_books.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

/// 录制的真实响应（2026-11-16 live：AniList「薬屋のひとりごと」、NDL OpenSearch
/// 同名 + mediatype=books、openBD 三个 ISBN、AniList 不存在的 id、NDL 并发 429）。
/// 楽天没有可用凭据，`rakuten_books_search_formatv2.json` 按官方 formatVersion=2 字段
/// 形状构造；两份楽天错误体是新端点的真实回包。
String fixture(String name) =>
    File('test/media/metadata/books/fixtures/$name').readAsStringSync();

void main() {
  group('ISBN', () {
    test('findIsbnIn 认连字符 / urn / ISBN-10 并规范成 13 位', () {
      expect(findIsbnIn('ISBN 978-4-301-00195-9'), '9784301001959');
      expect(findIsbnIn('urn:isbn:4040702476'), '9784040702476');
      // 9784040702477 校验位不对（正确是 …476），不收。
      expect(findIsbnIn('9784040702477'), isNull);
      expect(findIsbnIn('薬屋のひとりごと'), isNull);
      // 校验位错不猜。
      expect(findIsbnIn('9784301001958'), isNull);
    });

    test('catalogPersonName 规整典拠形人名', () {
      expect(catalogPersonName('村上, 春樹, 1949-'), '村上春樹');
      expect(catalogPersonName('夏目, 漱石, 1867-1916'), '夏目漱石');
      expect(catalogPersonName('日向, 夏'), '日向夏');
      expect(catalogPersonName('Hyuuga, Natsu'), 'Natsu Hyuuga');
      expect(catalogPersonName('しのとうこ'), 'しのとうこ');
    });
  });

  group('AniList', () {
    test('搜索响应：native 标题、罗马字原名、Story 作者、extraLarge 封面、横幅', () {
      final List<BookCatalogRecord> found = parseAniListNovelSearchResponse(
        fixture('anilist_search_kusuriya.json'),
      );
      expect(found, hasLength(1));
      final BookCatalogRecord r = found.single;
      expect(r.id, '99026');
      expect(r.title, '薬屋のひとりごと');
      expect(r.originalTitle, 'Kusuriya no Hitorigoto');
      // Illustration / Translator 不算作者。
      expect(r.author, '日向夏');
      expect(r.coverUrl, contains('/cover/large/nx99026-'));
      expect(r.bannerUrl, contains('/banner/99026-'));
      expect(r.year, 2014);
      expect(r.pageUrl, 'https://anilist.co/manga/99026');
      expect(r.summary, isNot(contains('<br>')));
      expect(r.isAdult, isFalse);
    });

    test('不存在的 id：fetchById 返回 null（404 + data.Media null）', () async {
      final AniListNovelClient client = AniListNovelClient(
        BookCatalogHttp(
          client: MockClient(
            (http.Request req) async =>
                http.Response(fixture('anilist_media_not_found.json'), 404),
          ),
          throttle: false,
        ),
      );
      expect(await client.fetchById('999999999'), isNull);
    });

    test('搜索请求是 MANGA + NOVEL 的 GraphQL POST，带通用 UA', () async {
      late http.Request seen;
      final AniListNovelClient client = AniListNovelClient(
        BookCatalogHttp(
          client: MockClient((http.Request req) async {
            seen = req;
            return http.Response.bytes(
              utf8.encode(fixture('anilist_search_kusuriya.json')),
              200,
            );
          }),
          throttle: false,
        ),
      );
      await client.search('薬屋のひとりごと');
      expect(seen.method, 'POST');
      expect(seen.url.host, 'graphql.anilist.co');
      final Map<String, Object?> body =
          jsonDecode(seen.body) as Map<String, Object?>;
      expect(body['query'], contains('format: NOVEL'));
      expect(body['query'], contains('type: MANGA'));
      expect(seen.headers['User-Agent'], kBookCatalogUserAgent);
    });

    test('GraphQL 报错且无 data → BookCatalogException', () {
      expect(
        () => parseAniListNovelSearchResponse(
          '{"errors":[{"message":"Too Many Requests.","status":429}],"data":null}',
        ),
        throwsA(
          isA<BookCatalogException>().having(
            (BookCatalogException e) => e.statusCode,
            'statusCode',
            429,
          ),
        ),
      );
    });

    test('parseAniListMediaUrl', () {
      expect(parseAniListMediaUrl('https://anilist.co/manga/99026/x'), '99026');
      expect(parseAniListMediaUrl('薬屋'), isNull);
    });
  });

  group('openBD', () {
    test('有封面的记录：summary 字段 + ONIX 作者', () {
      final BookCatalogRecord r = parseOpenBdResponse(
        fixture('openbd_9784480432292.json'),
      )!;
      expect(r.id, '9784480432292');
      expect(r.isbn, '9784480432292');
      expect(r.title, '人は変われる');
      expect(r.author, '高橋 和巳');
      expect(r.publisher, '筑摩書房');
      expect(r.year, 2014);
      expect(r.coverUrl, 'https://cover.openbd.jp/9784480432292.jpg');
      expect(r.coverHeaders, isNull);
    });

    test('无封面：回落 NDL 缩略图并带 Referer；series / volume / 典拠形作者', () {
      final BookCatalogRecord r = parseOpenBdResponse(
        fixture('openbd_9784065141113.json'),
      )!;
      expect(r.title, '私の愛人になりなさいっ!');
      expect(r.author, '天乃聖樹');
      expect(r.series, '講談社ラノベ文庫');
      expect(r.volume, 'あ-19-1-1');
      expect(r.coverUrl, ndlThumbnailUrl('9784065141113'));
      expect(r.coverHeaders, kNdlThumbnailHeaders);
    });

    test('另一条：ONIX PersonName 优先于 summary.author', () {
      final BookCatalogRecord r = parseOpenBdResponse(
        fixture('openbd_9784065136225.json'),
      )!;
      expect(r.author, '松本 ひで吉');
      expect(r.series, 'プレミアムKC');
      expect(r.publisher, '講談社');
    });

    test('未收录（[null]）→ null；不是数组 → 异常', () {
      expect(parseOpenBdResponse(fixture('openbd_not_found.json')), isNull);
      expect(
        () => parseOpenBdResponse('{}'),
        throwsA(isA<BookCatalogException>()),
      );
    });

    test('fetchByIsbn 规范化 ISBN 后请求；非法 ISBN 不发请求', () async {
      final List<Uri> seen = <Uri>[];
      final OpenBdClient client = OpenBdClient(
        BookCatalogHttp(
          client: MockClient((http.Request req) async {
            seen.add(req.url);
            return http.Response.bytes(
              utf8.encode(fixture('openbd_9784480432292.json')),
              200,
            );
          }),
          throttle: false,
        ),
      );
      expect(await client.fetchByIsbn('not an isbn'), isNull);
      expect(seen, isEmpty);
      expect((await client.fetchByIsbn('978-4-480-43229-2'))?.title, '人は変われる');
      expect(seen.single.queryParameters['isbn'], '9784480432292');
    });
  });

  group('NDL Search', () {
    test('只留有 ISBN 的图书、按 ISBN 去重，字段映射', () {
      final List<BookCatalogRecord> found = parseNdlOpenSearchResponse(
        fixture('ndl_opensearch_kusuriya.rss'),
      );
      expect(found.map((BookCatalogRecord r) => r.id), <String>[
        '9784301001959',
        '9784301009085',
        '9784301009092',
      ]);
      final BookCatalogRecord first = found.first;
      expect(first.title, '薬屋のひとりごと外伝小蘭回想録');
      expect(first.author, '日向夏, 七緒一綺');
      expect(first.publisher, 'スクウェア・エニックス');
      expect(first.series, 'ビッグガンガンコミックス');
      expect(first.volume, '1');
      expect(first.year, 2025);
      expect(
        first.pageUrl,
        'https://ndlsearch.ndl.go.jp/books/R100000002-I034419633',
      );
      expect(
        first.coverUrl,
        'https://ndlsearch.ndl.go.jp/thumbnail/9784301001959.jpg',
      );
      expect(first.coverHeaders?['Referer'], 'https://ndlsearch.ndl.go.jp/');
    });

    test('429 错误文档 → 带状态码的异常', () {
      expect(
        () =>
            parseNdlOpenSearchResponse(fixture('ndl_opensearch_error_429.rss')),
        throwsA(
          isA<BookCatalogException>().having(
            (BookCatalogException e) => e.statusCode,
            'statusCode',
            429,
          ),
        ),
      );
    });

    test('search：书名走 title=，ISBN 走 isbn=，都带 mediatype=books', () async {
      final List<Uri> seen = <Uri>[];
      final NdlSearchClient client = NdlSearchClient(
        BookCatalogHttp(
          client: MockClient((http.Request req) async {
            seen.add(req.url);
            return http.Response.bytes(
              utf8.encode(fixture('ndl_opensearch_kusuriya.rss')),
              200,
            );
          }),
          throttle: false,
        ),
      );
      await client.search('薬屋のひとりごと');
      await client.search('978-4-301-00195-9');
      expect(seen[0].queryParameters['title'], '薬屋のひとりごと');
      expect(seen[0].queryParameters['mediatype'], 'books');
      expect(seen[1].queryParameters['isbn'], '9784301001959');
      expect(seen[1].queryParameters.containsKey('title'), isFalse);
    });
  });

  group('楽天ブックス', () {
    const RakutenBooksCredentials creds = RakutenBooksCredentials(
      applicationId: 'app-id',
      accessKey: 'pk_test',
    );

    test('formatVersion=2：字段映射、去缩放参数、跳过 noimage / 无 ISBN', () {
      final List<BookCatalogRecord> found = parseRakutenBooksResponse(
        fixture('rakuten_books_search_formatv2.json'),
      );
      expect(found, hasLength(1));
      final BookCatalogRecord r = found.single;
      expect(r.id, '9784070000009');
      expect(r.title, '薬屋のひとりごと');
      expect(r.author, '日向夏, しのとうこ');
      expect(r.publisher, 'イマジカインフォス');
      expect(r.series, 'ヒーロー文庫');
      expect(r.year, 2014);
      expect(
        r.coverUrl,
        'https://thumbnail.image.rakuten.co.jp/@0_mall/book/cabinet/0000/9784070000009.jpg',
      );
      expect(r.pageUrl, 'https://books.rakuten.co.jp/rb/12900000/');
    });

    test('请求打新端点并同时带 applicationId + accessKey', () async {
      late Uri seen;
      final RakutenBooksClient client = RakutenBooksClient(
        BookCatalogHttp(
          client: MockClient((http.Request req) async {
            seen = req.url;
            return http.Response.bytes(
              utf8.encode(fixture('rakuten_books_search_formatv2.json')),
              200,
            );
          }),
          throttle: false,
        ),
        creds,
      );
      await client.search('薬屋のひとりごと');
      expect(seen.host, 'openapi.rakuten.co.jp');
      expect(seen.path, '/services/api/BooksBook/Search/20170404');
      expect(seen.queryParameters['applicationId'], 'app-id');
      expect(seen.queryParameters['accessKey'], 'pk_test');
      expect(seen.queryParameters['title'], '薬屋のひとりごと');
      expect(seen.queryParameters['formatVersion'], '2');
    });

    test('凭据不齐：不发请求直接抛', () async {
      int calls = 0;
      final RakutenBooksClient client = RakutenBooksClient(
        BookCatalogHttp(
          client: MockClient((http.Request req) async {
            calls++;
            return http.Response('{}', 200);
          }),
          throttle: false,
        ),
        const RakutenBooksCredentials(applicationId: 'x', accessKey: ''),
      );
      await expectLater(
        client.search('x'),
        throwsA(isA<BookCatalogException>()),
      );
      expect(calls, 0);
    });

    test('新端点错误体 → 带状态码与原因的异常', () async {
      final RakutenBooksClient client = RakutenBooksClient(
        BookCatalogHttp(
          client: MockClient(
            (http.Request req) async => http.Response(
              fixture('rakuten_error_invalid_access_key.json'),
              403,
            ),
          ),
          throttle: false,
        ),
        creds,
      );
      await expectLater(
        client.search('x'),
        throwsA(
          isA<BookCatalogException>()
              .having((BookCatalogException e) => e.statusCode, 'status', 403)
              .having(
                (BookCatalogException e) => e.message,
                'message',
                contains('Invalid Access Key'),
              ),
        ),
      );
      expect(
        rakutenErrorMessage(fixture('rakuten_error_missing_access_key.json')),
        contains('accessKey must be present'),
      );
    });
  });

  test('节流：同 host 连续两次请求间隔不少于配置值', () async {
    BookCatalogHttp.resetRateLimitForTesting();
    final List<DateTime> starts = <DateTime>[];
    final BookCatalogHttp http0 = BookCatalogHttp(
      client: MockClient((http.Request req) async {
        starts.add(DateTime.now());
        return http.Response('[null]', 200);
      }),
    );
    final OpenBdClient client = OpenBdClient(http0);
    await Future.wait(<Future<Object?>>[
      client.fetchByIsbn('9784480432292'),
      client.fetchByIsbn('9784480432292'),
    ]);
    final Duration gap = starts[1].difference(starts[0]);
    expect(
      gap.inMilliseconds,
      greaterThanOrEqualTo(
        kBookCatalogMinIntervals['api.openbd.jp']!.inMilliseconds - 20,
      ),
    );
    BookCatalogHttp.resetRateLimitForTesting();
  });
}
