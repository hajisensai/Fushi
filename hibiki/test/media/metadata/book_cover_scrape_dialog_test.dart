import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/i18n/strings.g.dart';
import 'package:hibiki/src/media/metadata/book_cover_scrape_dialog.dart';
import 'package:hibiki/src/media/metadata/book_metadata_scraper.dart';
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
    await tester.pumpWidget(wrap(
      BookCoverScrapeDialog(initialQuery: '四叶', scraperOverride: scraper),
    ));
    await tester.pumpAndSettle();

    // 搜索框预填初始查询。
    expect(find.widgetWithText(TextField, '四叶'), findsOneWidget);
    // 候选主标题（name_cn 优先）渲染。
    expect(find.text('四叶妹妹！'), findsOneWidget);
    // 「使用」按钮存在。
    expect(find.text(t.book_scrape_use), findsOneWidget);
  });

  testWidgets('空结果显示空状态文案', (WidgetTester tester) async {
    final BookMetadataScraper scraper = scraperReturning('{"data":[]}');
    await tester.pumpWidget(wrap(
      BookCoverScrapeDialog(initialQuery: 'zzzz', scraperOverride: scraper),
    ));
    await tester.pumpAndSettle();

    expect(find.text(t.book_scrape_empty), findsOneWidget);
    expect(find.text(t.book_scrape_use), findsNothing);
  });

  testWidgets('搜索失败显示错误行（非静默空列表），且可重试', (WidgetTester tester) async {
    int calls = 0;
    final BookMetadataScraper scraper = BookMetadataScraper(
      client: MockClient((http.Request req) async {
        calls++;
        if (calls == 1) throw http.ClientException('network down');
        return http.Response.bytes(
          utf8.encode('{"data":[{"id":1,"name":"Yotsuba to!",'
              '"images":{"large":"https://i/l.jpg"}}]}'),
          200,
          headers: const <String, String>{'content-type': 'application/json'},
        );
      }),
    );
    await tester.pumpWidget(wrap(
      BookCoverScrapeDialog(initialQuery: '四叶', scraperOverride: scraper),
    ));
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
}
