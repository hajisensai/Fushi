import 'dart:convert';

import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/metadata/book_cover_scrape_dialog.dart';
import 'package:fushi/src/media/metadata/book_metadata_scraper.dart';
import 'package:fushi/src/media/metadata/transport_retry.dart';
import 'package:fushi/src/utils/misc/error_log_service.dart';
import 'package:fushi_engine/media/metadata/books/book_catalog.dart'
    show BookCatalogHttp;
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// 书籍封面刮削弹窗冒烟：候选渲染 + 空状态。下载路径（点「使用」）走真实网络，不在
/// widget 测试覆盖，由 book_metadata_scraper_test / image_download_test 单测覆盖。
void main() {
  setUp(() => LocaleSettings.setLocale(AppLocale.zhCn));

  Widget wrap(Widget child) => TranslationProvider(
    child: MaterialApp(home: Scaffold(body: child)),
  );

  BookMetadataScraper scraperReturning(String body) => BookMetadataScraper(
    client: MockClient(
      (http.Request req) async => http.Response.bytes(
        utf8.encode(body),
        200,
        headers: const <String, String>{'content-type': 'application/json'},
      ),
    ),
  );

  testWidgets('预填标题自动搜索 → 候选渲染', (WidgetTester tester) async {
    final BookMetadataScraper scraper = scraperReturning(
      '{"data":[{"id":1,"name":"Yotsuba to!","name_cn":"四叶妹妹！",'
      '"images":{"large":"https://i/l.jpg"},"date":"2003-08-10"}]}',
    );
    await tester.pumpWidget(
      wrap(BookCoverScrapeDialog(initialQuery: '四叶', scraperOverride: scraper)),
    );
    await tester.pumpAndSettle();

    // 搜索框预填初始查询。
    expect(find.widgetWithText(TextField, '四叶'), findsOneWidget);
    // 候选主标题（name_cn 优先）渲染。
    expect(find.text('四叶妹妹！'), findsOneWidget);
    // 「使用」按钮存在。
    expect(find.text(t.book_scrape_use), findsOneWidget);
  });

  // 应用内反馈 T_KdsLEY9l：导入的歌曲（LRC 歌词）默认搜 iTunes，不再先去 Bangumi。
  testWidgets('导入的歌曲：默认源 iTunes，自动搜索打到 iTunes 并渲染歌曲候选', (
    WidgetTester tester,
  ) async {
    final List<Uri> requests = <Uri>[];
    final MockClient client = MockClient((http.Request req) async {
      requests.add(req.url);
      return http.Response.bytes(
        utf8.encode(
          '{"resultCount":1,"results":[{"wrapperType":"track","kind":"song",'
          '"trackId":1537460612,"trackName":"Lemon","artistName":"米津玄師",'
          '"collectionName":"Lemon - Single",'
          '"artworkUrl100":"https://i.test/a.jpg/100x100bb.jpg",'
          '"releaseDate":"2018-02-12T12:00:00Z","primaryGenreName":"J-Pop"}]}',
        ),
        200,
      );
    });
    await tester.pumpWidget(
      wrap(
        BookCoverScrapeDialog(
          initialQuery: 'Lemon',
          isSong: true,
          scraperOverride: BookMetadataScraper(
            client: client,
            catalogHttp: BookCatalogHttp(client: client, throttle: false),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(requests.single.host, 'itunes.apple.com');
    expect(find.text(BookScrapeSource.itunes.label), findsWidgets);
    expect(find.text('Lemon'), findsWidgets);
    expect(find.textContaining('米津玄師'), findsOneWidget);
  });

  // 拍板台 pr3497：NSFW 候选跟随书自己的 NSFW 标记，对所有源一视同仁。
  const String nsfwMixedBody =
      '{"data":[{"id":1,"name":"Yotsuba to!","name_cn":"四叶妹妹！",'
      '"images":{"large":"https://i/l.jpg"},"date":"2003-08-10"},'
      '{"id":2,"name":"Adult work","nsfw":true,'
      '"images":{"large":"https://i/a.jpg"},"date":"2010-01-01"}]}';

  testWidgets('书没标 NSFW：NSFW 候选藏起来并提示条数；「标为 NSFW」后显示且标 NSFW', (
    WidgetTester tester,
  ) async {
    int marked = 0;
    await tester.pumpWidget(
      wrap(
        BookCoverScrapeDialog(
          initialQuery: '四叶',
          scraperOverride: scraperReturning(nsfwMixedBody),
          onMarkNsfw: () async => marked++,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('四叶妹妹！'), findsOneWidget);
    expect(find.text('Adult work'), findsNothing);
    expect(find.text(t.book_scrape_nsfw_hidden(count: 1)), findsOneWidget);

    await tester.tap(
      find.byKey(const ValueKey<String>('book_scrape_nsfw_mark')),
    );
    await tester.pumpAndSettle();
    expect(marked, 1);
    expect(find.text('Adult work'), findsOneWidget);
    expect(find.textContaining('NSFW'), findsWidgets);
    expect(
      find.byKey(const ValueKey<String>('book_scrape_nsfw_hidden')),
      findsNothing,
    );
  });

  testWidgets('书已是 NSFW：直接显示 NSFW 候选，标「NSFW」而不是 R18', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      wrap(
        BookCoverScrapeDialog(
          initialQuery: '四叶',
          scraperOverride: scraperReturning(nsfwMixedBody),
          includeNsfw: true,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Adult work'), findsOneWidget);
    expect(find.text('NSFW · 2010'), findsOneWidget);
    expect(find.textContaining('R18'), findsNothing);
    expect(
      find.byKey(const ValueKey<String>('book_scrape_nsfw_hidden')),
      findsNothing,
    );
  });

  testWidgets('标 NSFW 失败：候选仍藏着，不重搜成显示', (WidgetTester tester) async {
    await tester.pumpWidget(
      wrap(
        BookCoverScrapeDialog(
          initialQuery: '四叶',
          scraperOverride: scraperReturning(nsfwMixedBody),
          onMarkNsfw: () async => throw StateError('db locked'),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey<String>('book_scrape_nsfw_mark')),
    );
    await tester.pumpAndSettle();
    expect(find.text('Adult work'), findsNothing);
    expect(find.text(t.book_scrape_nsfw_hidden(count: 1)), findsOneWidget);
  });

  testWidgets('楽天没填凭据：提示只在选中楽天时出现，且不发请求', (WidgetTester tester) async {
    final List<Uri> requests = <Uri>[];
    final BookMetadataScraper scraper = BookMetadataScraper(
      client: MockClient((http.Request req) async {
        requests.add(req.url);
        return http.Response.bytes(
          utf8.encode('{"data":[]}'),
          200,
          headers: const <String, String>{'content-type': 'application/json'},
        );
      }),
    );
    await tester.pumpWidget(
      wrap(BookCoverScrapeDialog(initialQuery: '四叶', scraperOverride: scraper)),
    );
    await tester.pumpAndSettle();
    expect(find.text(t.book_scrape_rakuten_unavailable), findsNothing);
    final int before = requests.length;

    await tester.tap(
      find.byKey(const ValueKey<String>('book_scrape_source_picker')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text(BookScrapeSource.rakuten.label).last);
    await tester.pumpAndSettle();
    expect(find.text(t.book_scrape_rakuten_unavailable), findsOneWidget);
    expect(requests.length, before);
  });

  testWidgets('空结果显示空状态文案', (WidgetTester tester) async {
    final BookMetadataScraper scraper = scraperReturning('{"data":[]}');
    await tester.pumpWidget(
      wrap(
        BookCoverScrapeDialog(initialQuery: 'zzzz', scraperOverride: scraper),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text(t.book_scrape_empty), findsOneWidget);
    expect(find.text(t.book_scrape_use), findsNothing);
  });

  testWidgets('搜索失败显示错误行（非静默空列表），且可重试', (WidgetTester tester) async {
    int calls = 0;
    final BookMetadataScraper scraper = BookMetadataScraper(
      client: MockClient((http.Request req) async {
        calls++;
        // BUG-1272 起传输失败会自动重试 [kTransportMaxAttempts] 次，所以要让整轮
        // 搜索都失败，必须打满一整轮尝试；只失败一次的话现在会被自动重试救回来，
        // 用户根本看不到错误行（这正是本次修复的目的）。手动重试从下一轮开始成功。
        if (calls <= kTransportMaxAttempts) {
          throw http.ClientException('network down');
        }
        return http.Response.bytes(
          utf8.encode(
            '{"data":[{"id":1,"name":"Yotsuba to!",'
            '"images":{"large":"https://i/l.jpg"}}]}',
          ),
          200,
          headers: const <String, String>{'content-type': 'application/json'},
        );
      }),
    );
    await tester.pumpWidget(
      wrap(BookCoverScrapeDialog(initialQuery: '四叶', scraperOverride: scraper)),
    );
    await tester.pumpAndSettle();

    // 失败态：错误行可见，不是「无匹配」空态。
    expect(find.text(t.book_scrape_search_failed), findsOneWidget);
    expect(find.text(t.book_scrape_empty), findsNothing);

    // 再点「搜索」重试：错误行消失，候选正常渲染。
    await tester.tap(find.text(t.book_scrape_search));
    await tester.pumpAndSettle();
    expect(find.text(t.book_scrape_search_failed), findsNothing);
    expect(find.text('Yotsuba to!'), findsOneWidget);
  });

  // BUG-1176：失败行此前只说「失败了」，没有任何可行动原因，原始原因也没有出口。
  testWidgets('BUG-1176 搜索失败带可行动原因 + 落错误日志', (WidgetTester tester) async {
    final BookMetadataScraper scraper = BookMetadataScraper(
      client: MockClient(
        (http.Request req) async => throw http.ClientException('down'),
      ),
    );
    final int logsBefore = ErrorLogService.instance.entries.length;

    await tester.pumpWidget(
      wrap(BookCoverScrapeDialog(initialQuery: '四叶', scraperOverride: scraper)),
    );
    await tester.pumpAndSettle();

    expect(find.text(t.book_scrape_search_failed), findsOneWidget);
    // 没拿到可用响应 → 「检查网络后重试」。
    expect(find.text(t.scrape_reason_network), findsOneWidget);
    final List<ErrorLogEntry> added = ErrorLogService.instance.entries.sublist(
      logsBefore,
    );
    expect(
      added.any(
        (ErrorLogEntry e) => e.source == 'BookCoverScrapeDialog.search',
      ),
      isTrue,
    );
  });

  testWidgets('BUG-1176 源站 HTTP 500 给出「源站报错」而非「检查网络」', (
    WidgetTester tester,
  ) async {
    final BookMetadataScraper scraper = BookMetadataScraper(
      client: MockClient((http.Request req) async => http.Response('', 500)),
    );

    await tester.pumpWidget(
      wrap(BookCoverScrapeDialog(initialQuery: '四叶', scraperOverride: scraper)),
    );
    await tester.pumpAndSettle();

    expect(find.text(t.book_scrape_search_failed), findsOneWidget);
    expect(find.text(t.scrape_reason_server), findsOneWidget);
    expect(find.text(t.scrape_reason_network), findsNothing);
  });

  // BUG-1219：两句折叠文案只回答「我该做什么」，不回答「到底怎么了」。完整异常串必须
  // 留在出错的地方，并且可一键复制上报（与视频封面匹配弹窗共用 ScrapeFailureView）。
  testWidgets('BUG-1219 搜索失败在弹窗内直出完整技术详情 + 可复制', (WidgetTester tester) async {
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (MethodCall call) async {
        if (call.method == 'Clipboard.setData') {
          copied = (call.arguments as Map<Object?, Object?>)['text'] as String?;
        }
        return null;
      },
    );
    addTearDown(() {
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      );
    });

    final BookMetadataScraper scraper = BookMetadataScraper(
      client: MockClient(
        (http.Request req) async =>
            throw http.ClientException("Failed host lookup: 'api.bgm.tv'"),
      ),
    );

    await tester.pumpWidget(
      wrap(BookCoverScrapeDialog(initialQuery: '四叶', scraperOverride: scraper)),
    );
    await tester.pumpAndSettle();

    // 折叠原因仍在（可行动指引不被详情取代）。
    expect(find.text(t.scrape_reason_network), findsOneWidget);
    // 详情**默认折叠**：普通断网场景不拿英文异常糊用户一脸。
    expect(find.byType(SelectableText), findsNothing);
    expect(find.text(t.copy_error), findsNothing);

    // 一键展开后底层原因（主机名）可见，并出现复制上报入口。
    await tester.tap(
      find.byKey(const ValueKey<String>('scrape_failure_detail_toggle')),
    );
    await tester.pumpAndSettle();
    final Finder detailFinder = find.byWidgetPredicate(
      (Widget w) =>
          w is SelectableText && (w.data ?? '').contains('api.bgm.tv'),
    );
    expect(detailFinder, findsOneWidget);
    expect(find.text(t.copy_error), findsOneWidget);

    // 「复制错误」写出的必须是界面里这段完整详情，而不是折叠原因或截断文本。
    final String detail =
        tester.widget<SelectableText>(detailFinder).data ?? '';
    // M3E 失败态（FushiPlaceholderMessage 图标块 + 按钮组）比旧版高，800x600 测试
    // 窗下展开详情后「复制错误」落在结果区外层滚动视口之外——先滚到它，同用户操作。
    await tester.ensureVisible(find.text(t.copy_error));
    await tester.pumpAndSettle();
    await tester.tap(find.text(t.copy_error));
    await tester.pump();
    expect(copied, detail);
  });

  testWidgets('BUG-1219 源站 HTTP 500 的详情里带得到状态码', (WidgetTester tester) async {
    final BookMetadataScraper scraper = BookMetadataScraper(
      client: MockClient((http.Request req) async => http.Response('', 500)),
    );

    await tester.pumpWidget(
      wrap(BookCoverScrapeDialog(initialQuery: '四叶', scraperOverride: scraper)),
    );
    await tester.pumpAndSettle();

    expect(find.text(t.scrape_reason_server), findsOneWidget);
    await tester.tap(
      find.byKey(const ValueKey<String>('scrape_failure_detail_toggle')),
    );
    await tester.pumpAndSettle();
    expect(
      find.byWidgetPredicate(
        (Widget w) => w is SelectableText && (w.data ?? '').contains('500'),
      ),
      findsOneWidget,
    );
  });

  testWidgets('MangaBaka 源：署名可见；「使用」进卷封面网格，本地卷号那一卷排最前', (
    WidgetTester tester,
  ) async {
    final BookMetadataScraper scraper = BookMetadataScraper(
      client: MockClient((http.Request req) async {
        final String body;
        if (req.url.host == 'api.mangabaka.org' &&
            req.url.path == '/v1/series/search') {
          body =
              '{"data":[{"id":100,"state":"active","title":"Test Manga",'
              '"native_title":"テスト漫画","authors":["Taro"],"type":"manga",'
              '"content_rating":"safe","cover":{"raw":{"url":'
              '"https://images.mangabaka.dev/c","width":1200,"height":1800}}}],'
              '"pagination":{"next":null}}';
        } else if (req.url.path == '/v1/series/100/images') {
          String image(String index) =>
              '{"id":$index,"index":"$index","index_numeric":$index,'
              '"type":"volume","language":"ja","note":null,'
              '"content_rating":"safe","image":{"raw":{"url":'
              '"https://images.mangabaka.dev/v$index","width":1200,'
              '"height":1800}}}';
          body =
              '{"data":[${image('1')},${image('2')}],'
              '"pagination":{"next":null}}';
        } else {
          body = '{"data":[]}';
        }
        return http.Response.bytes(
          utf8.encode(body),
          200,
          headers: const <String, String>{'content-type': 'application/json'},
        );
      }),
    );
    await tester.pumpWidget(
      wrap(
        BookCoverScrapeDialog(
          initialQuery: 'テスト漫画',
          volume: 2,
          scraperOverride: scraper,
        ),
      ),
    );
    await tester.pumpAndSettle();
    final Finder attribution = find.byKey(
      const ValueKey<String>('book_scrape_mangabaka_attribution'),
    );
    expect(attribution, findsNothing);

    // 源是下拉（七个源分段放不下）：先展开，再点 MangaBaka 那一项。
    await tester.tap(
      find.byKey(const ValueKey<String>('book_scrape_source_picker')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('MangaBaka').last);
    await tester.pumpAndSettle();
    expect(find.text('テスト漫画'), findsWidgets);
    expect(attribution, findsOneWidget);

    await tester.tap(find.text(t.book_scrape_use));
    await tester.pumpAndSettle();
    final Finder v1 = find.byKey(
      const ValueKey<String>('book_scrape_volume_1'),
    );
    final Finder v2 = find.byKey(
      const ValueKey<String>('book_scrape_volume_2'),
    );
    expect(v1, findsOneWidget);
    expect(v2, findsOneWidget);
    // 预选的第 2 卷排在第 1 卷前面。
    expect(tester.getTopLeft(v2).dx, lessThan(tester.getTopLeft(v1).dx));
    expect(attribution, findsOneWidget);
  });
}
