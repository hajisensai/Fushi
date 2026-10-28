// Kavita EPUB 系列页：章节行的服务器进度文案、长按 / 右键菜单标已读、下拉刷新、
// 静默重取失败保留旧列表、阅读器关闭后等关书推送再重取（KavitaOpenBooks，单测见 kavita_open_books_test）。假服务器（MockClient）+ 真页面；
// 书服务注入内存库，不构造 AppModel。
import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/kavita/kavita_book_service.dart';
import 'package:fushi/src/media/kavita/kavita_server_config.dart';
import 'package:fushi/src/pages/implementations/kavita/kavita_book_series_page.dart';
import 'package:fushi/utils.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/kavita/kavita_api.dart';
import 'package:fushi_engine/media/kavita/kavita_models.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:material_ui/material_ui.dart';

class _FakeKavita {
  /// chapterId -> pagesRead
  final Map<int, int> pagesRead = <int, int>{1: 0, 2: 5, 3: 10};
  bool detailFails = false;
  int detailCalls = 0;
  final List<String> marks = <String>[];

  Map<String, Object?> _chapter(int id) => <String, Object?>{
    'id': id,
    'volumeId': 1,
    'pages': 10,
    'pagesRead': pagesRead[id],
    'titleName': 'Chapter $id',
    'sortOrder': id,
  };

  Future<http.Response> handle(http.Request r) async {
    final String path = r.url.path;
    if (path == '/api/Plugin/authenticate') {
      return http.Response('{"token":"jwt"}', 200);
    }
    if (path == '/api/Series/series-detail') {
      detailCalls++;
      if (detailFails) return http.Response('down', 503);
      return http.Response(
        jsonEncode(<String, Object?>{
          'chapters': <Object?>[
            for (final int id in <int>[1, 2, 3]) _chapter(id),
          ],
        }),
        200,
        headers: <String, String>{'content-type': 'application/json'},
      );
    }
    if (path == '/api/Reader/mark-multiple-read' ||
        path == '/api/Reader/mark-multiple-unread') {
      final bool read = path.endsWith('-read');
      final Map<String, Object?> body =
          jsonDecode(r.body) as Map<String, Object?>;
      final int id = (body['chapterIds']! as List<Object?>).single! as int;
      pagesRead[id] = read ? 10 : 0;
      marks.add('${read ? 'read' : 'unread'}:$id');
      return http.Response('', 200);
    }
    return http.Response('not found', 404);
  }
}

/// 本地对齐（alignLocalWithServerMark）自身由 kavita_chapter_mark_test 覆盖；它走进程级
/// 静态串行锁，锁链在 testWidgets 的 fake zone 里会跨用例悬住，所以这里只记录调用。
class _RecordingService extends KavitaBookService {
  _RecordingService(FushiDatabase db) : super(db: db);

  final List<String> aligned = <String>[];

  @override
  Future<void> alignLocalWithServerMark({
    required String serverConfigId,
    required int chapterId,
    required bool read,
    required int totalPages,
  }) async {
    aligned.add('$chapterId:${read ? 'read' : 'unread'}:$totalPages');
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _FakeKavita fake;
  late FushiDatabase db;
  late KavitaApi api;
  late _RecordingService service;
  final KavitaServerConfig server = KavitaServerConfig(
    id: 'srv',
    name: 'n',
    serverUrl: Uri.parse('https://kavita.example.com'),
    apiKey: 'K',
    enabled: true,
  );
  final KavitaSeries series = KavitaSeries.fromJson(<String, Object?>{
    'id': 7,
    'name': 'My Series',
    'libraryId': 1,
    'pages': 30,
    'pagesRead': 0,
  });

  setUp(() {
    LocaleSettings.setLocale(AppLocale.en);
    fake = _FakeKavita();
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    service = _RecordingService(db);
    api = KavitaApi(
      serverUrl: 'https://kavita.example.com',
      apiKey: 'K',
      client: MockClient(fake.handle),
    );
  });
  tearDown(() => db.close());

  Future<void> pumpPage(WidgetTester tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(900, 1400);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(
          home: KavitaBookSeriesPage(
            server: server,
            series: series,
            api: api,
            service: service,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// MockClient / 内存库的完成回调走真异步，而 KavitaApi 的超时计时器在 fake zone：
  /// 交替让出真实时间并推进帧，直到 [done]，再多泵几轮把收尾微任务冲干净（书服务的
  /// 串行锁是进程级静态链，留尾巴会让下一个用例的写入排在它后面）。
  Future<void> settleUntil(WidgetTester tester, bool Function() done) async {
    for (int i = 0; i < 200 && !done(); i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 5)),
      );
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(done(), isTrue, reason: 'condition never became true');
    for (int i = 0; i < 5; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 5)),
      );
      await tester.pump(const Duration(milliseconds: 50));
    }
    await tester.pumpAndSettle();
  }

  Finder row(int id) => find.byKey(ValueKey<String>('kavita_chapter_$id'));

  testWidgets('章节行按服务器 pagesRead / pages 显示进度', (WidgetTester tester) async {
    await pumpPage(tester);
    expect(find.text(t.kavita_book_progress_finished), findsOneWidget);
    expect(
      find.text(t.kavita_book_progress_percent(percent: '50')),
      findsOneWidget,
    );
    // 没读的章节没有进度文案。
    expect(
      find.descendant(of: row(1), matching: find.textContaining('%')),
      findsNothing,
    );
  });

  testWidgets('右键打开菜单，标已读 -> 调 API 并刷新进度', (WidgetTester tester) async {
    await pumpPage(tester);
    final int before = fake.detailCalls;
    final TestGesture mouse = await tester.startGesture(
      tester.getCenter(row(1)),
      kind: PointerDeviceKind.mouse,
      buttons: kSecondaryMouseButton,
    );
    await mouse.up();
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey<String>('kavita-chapter-menu')),
      findsOneWidget,
    );

    await tester.tap(
      find.byKey(const ValueKey<String>('kavita-chapter-mark-read')),
    );
    await settleUntil(tester, () => fake.detailCalls > before);

    expect(fake.marks, <String>['read:1']);
    expect(service.aligned, <String>['1:read:10']);
    expect(fake.detailCalls, greaterThan(before));
    expect(
      find.descendant(
        of: row(1),
        matching: find.text(t.kavita_book_progress_finished),
      ),
      findsOneWidget,
    );
  });

  testWidgets('长按打开菜单，已读章节标未读', (WidgetTester tester) async {
    await pumpPage(tester);
    final int before = fake.detailCalls;
    await tester.longPress(row(3));
    await tester.pumpAndSettle();
    // 已读章节只给「标未读」。
    expect(
      find.byKey(const ValueKey<String>('kavita-chapter-mark-read')),
      findsNothing,
    );
    await tester.tap(
      find.byKey(const ValueKey<String>('kavita-chapter-mark-unread')),
    );
    await settleUntil(tester, () => fake.detailCalls > before);

    expect(fake.marks, <String>['unread:3']);
    expect(service.aligned, <String>['3:unread:10']);
    expect(
      find.descendant(
        of: row(3),
        matching: find.text(t.kavita_book_progress_finished),
      ),
      findsNothing,
    );
  });

  testWidgets('下拉刷新重取，服务器上的变化显示出来', (WidgetTester tester) async {
    await pumpPage(tester);
    expect(
      find.text(t.kavita_book_progress_percent(percent: '50')),
      findsOneWidget,
    );
    fake.pagesRead[2] = 8;
    final int before = fake.detailCalls;
    await tester.fling(find.byType(ListView), const Offset(0, 400), 1000);
    await settleUntil(tester, () => fake.detailCalls > before);

    expect(fake.detailCalls, greaterThan(before));
    expect(
      find.text(t.kavita_book_progress_percent(percent: '80')),
      findsOneWidget,
    );
  });

  testWidgets('静默重取失败保留旧列表，不弹错误页', (WidgetTester tester) async {
    await pumpPage(tester);
    fake.detailFails = true;
    fake.pagesRead[2] = 8;
    final int before = fake.detailCalls;
    await tester.fling(find.byType(ListView), const Offset(0, 400), 1000);
    await settleUntil(tester, () => fake.detailCalls > before);

    expect(row(1), findsOneWidget);
    expect(
      find.text(t.kavita_book_progress_percent(percent: '50')),
      findsOneWidget,
    );
    expect(find.text(t.retry), findsNothing);
  });
}
