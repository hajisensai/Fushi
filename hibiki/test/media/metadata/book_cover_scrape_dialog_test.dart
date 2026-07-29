import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/i18n/strings.g.dart';
import 'package:hibiki/src/media/metadata/book_cover_scrape_dialog.dart';
import 'package:hibiki/src/media/metadata/book_metadata_scraper.dart';
import 'package:hibiki/src/utils/misc/error_log_service.dart';
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

  // BUG-1176：失败行此前只说「失败了」，没有任何可行动原因，原始原因也没有出口。
  testWidgets('BUG-1176 搜索失败带可行动原因 + 落错误日志', (WidgetTester tester) async {
    final BookMetadataScraper scraper = BookMetadataScraper(
      client: MockClient(
          (http.Request req) async => throw http.ClientException('down')),
    );
    final int logsBefore = ErrorLogService.instance.entries.length;

    await tester.pumpWidget(wrap(
      BookCoverScrapeDialog(initialQuery: '四叶', scraperOverride: scraper),
    ));
    await tester.pumpAndSettle();

    expect(find.text(t.book_scrape_search_failed), findsOneWidget);
    // 没拿到可用响应 → 「检查网络后重试」。
    expect(find.text(t.scrape_reason_network), findsOneWidget);
    final List<ErrorLogEntry> added =
        ErrorLogService.instance.entries.sublist(logsBefore);
    expect(
      added
          .any((ErrorLogEntry e) => e.source == 'BookCoverScrapeDialog.search'),
      isTrue,
    );
  });

  testWidgets('BUG-1176 源站 HTTP 500 给出「源站报错」而非「检查网络」',
      (WidgetTester tester) async {
    final BookMetadataScraper scraper = BookMetadataScraper(
      client: MockClient((http.Request req) async => http.Response('', 500)),
    );

    await tester.pumpWidget(wrap(
      BookCoverScrapeDialog(initialQuery: '四叶', scraperOverride: scraper),
    ));
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
      client: MockClient((http.Request req) async =>
          throw http.ClientException("Failed host lookup: 'api.bgm.tv'")),
    );

    await tester.pumpWidget(wrap(
      BookCoverScrapeDialog(initialQuery: '四叶', scraperOverride: scraper),
    ));
    await tester.pumpAndSettle();

    // 折叠原因仍在（可行动指引不被详情取代）。
    expect(find.text(t.scrape_reason_network), findsOneWidget);
    // 详情**默认折叠**：普通断网场景不拿英文异常糊用户一脸。
    expect(find.byType(SelectableText), findsNothing);
    expect(find.text(t.copy_error), findsNothing);

    // 一键展开后底层原因（主机名）可见，并出现复制上报入口。
    await tester.tap(
        find.byKey(const ValueKey<String>('scrape_failure_detail_toggle')));
    await tester.pumpAndSettle();
    final Finder detailFinder = find.byWidgetPredicate((Widget w) =>
        w is SelectableText && (w.data ?? '').contains('api.bgm.tv'));
    expect(detailFinder, findsOneWidget);
    expect(find.text(t.copy_error), findsOneWidget);

    // 「复制错误」写出的必须是界面里这段完整详情，而不是折叠原因或截断文本。
    final String detail =
        tester.widget<SelectableText>(detailFinder).data ?? '';
    await tester.tap(find.text(t.copy_error));
    await tester.pump();
    expect(copied, detail);
  });

  testWidgets('BUG-1219 源站 HTTP 500 的详情里带得到状态码', (WidgetTester tester) async {
    final BookMetadataScraper scraper = BookMetadataScraper(
      client: MockClient((http.Request req) async => http.Response('', 500)),
    );

    await tester.pumpWidget(wrap(
      BookCoverScrapeDialog(initialQuery: '四叶', scraperOverride: scraper),
    ));
    await tester.pumpAndSettle();

    expect(find.text(t.scrape_reason_server), findsOneWidget);
    await tester.tap(
        find.byKey(const ValueKey<String>('scrape_failure_detail_toggle')));
    await tester.pumpAndSettle();
    expect(
      find.byWidgetPredicate(
          (Widget w) => w is SelectableText && (w.data ?? '').contains('500')),
      findsOneWidget,
    );
  });
}
