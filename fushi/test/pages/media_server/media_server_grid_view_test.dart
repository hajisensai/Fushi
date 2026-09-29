import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/media_server/media_server_browser.dart';
import 'package:fushi/src/pages/implementations/media_server/media_server_grid_view.dart';
import 'package:fushi/src/pages/implementations/media_server/media_server_session.dart';
import 'package:fushi/utils.dart';

import 'fake_media_server_browser.dart';

/// 库网格：首页 60 条、滚到底追加第二页且**只认 nextStartIndex**、排序切换重置
/// 分页、搜索改走 `search`、电影点卡直接播放（无同伴）。
void main() {
  late FakeMediaServerBrowser browser;
  late List<MediaServerPlayRequest> played;

  setUp(() {
    LocaleSettings.setLocale(AppLocale.zhCn);
    browser = FakeMediaServerBrowser();
    played = <MediaServerPlayRequest>[];
  });

  Widget harness({String? parentId = 'lib-movies'}) {
    return TranslationProvider(
      child: MaterialApp(
        home: Scaffold(
          body: MediaServerGridView(
            session: MediaServerSession(
              browser: browser,
              play: (BuildContext _, MediaServerPlayRequest request) =>
                  played.add(request),
            ),
            parentId: parentId,
            title: 'Movies',
          ),
        ),
      ),
    );
  }

  Iterable<FakePageRequest> childrenRequests() =>
      browser.requests.where((FakePageRequest r) => r.kind == 'children');

  Future<void> scrollToBottom(WidgetTester tester) async {
    await tester.drag(find.byType(CustomScrollView), const Offset(0, -20000));
    await tester.pumpAndSettle();
  }

  testWidgets('首页拉 60 条；滚到底追加第二页，起点用服务器给的 nextStartIndex', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(1000, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    browser.children['lib-movies'] = fakeMovies(150);
    // 模拟实现侧滤掉了 3 条非视频域条目：服务器那边序号照占，下一页起点必须是
    // 60 + 3 = 63，而不是页面自己数出来的 60。
    browser.nextStartIndexShift = 3;

    await tester.pumpWidget(harness());
    await tester.pumpAndSettle();

    final List<FakePageRequest> first = childrenRequests().toList();
    expect(first, hasLength(1), reason: '首页只发一次；视口没铺满也不重复拉同一页');
    expect(first.single.startIndex, 0);
    expect(first.single.limit, kMediaServerPageSize);
    expect(first.single.parentId, 'lib-movies');
    expect(
      find.byKey(const ValueKey<String>('media-server-grid-card-movie-0')),
      findsOneWidget,
    );

    await scrollToBottom(tester);

    final List<FakePageRequest> after = childrenRequests().toList();
    expect(after.length, greaterThanOrEqualTo(2), reason: '滚到底必须追加下一页');
    expect(
      after[1].startIndex,
      63,
      reason: '翻页只认 nextStartIndex（BUG 模式：startIndex + items.length = 60）',
    );
    expect(after[1].sort, MediaServerSort.name);
  });

  testWidgets('切换排序重置分页：从 0 重拉并带新排序', (WidgetTester tester) async {
    browser.children['lib-movies'] = fakeMovies(150);
    await tester.pumpWidget(harness());
    await tester.pumpAndSettle();
    await scrollToBottom(tester);
    final int before = childrenRequests().length;
    expect(before, greaterThanOrEqualTo(2));

    final FushiDropdown<MediaServerSort> dropdown = tester
        .widget<FushiDropdown<MediaServerSort>>(
          find.byKey(const ValueKey<String>('media-server-grid-sort')),
        );
    dropdown.onChanged(MediaServerSort.dateAdded);
    await tester.pumpAndSettle();

    final FakePageRequest last = childrenRequests().last;
    expect(last.startIndex, 0, reason: '换排序必须从第一页重来');
    expect(last.sort, MediaServerSort.dateAdded);
  });

  testWidgets('搜索框非空改走 search（分页同款），清空回到 listChildren', (
    WidgetTester tester,
  ) async {
    browser.children['lib-movies'] = fakeMovies(5);
    browser.searchResults.addAll(fakeMovies(2, prefix: 'hit'));
    await tester.pumpWidget(harness());
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(const ValueKey<String>('media-server-grid-search')),
      'hit',
    );
    // 防抖 350ms。
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();

    final List<FakePageRequest> searches = browser.requests
        .where((FakePageRequest r) => r.kind == 'search')
        .toList();
    expect(searches, hasLength(1));
    expect(searches.single.query, 'hit');
    expect(searches.single.startIndex, 0);
    expect(
      find.byKey(const ValueKey<String>('media-server-grid-card-hit-0')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('media-server-grid-card-movie-0')),
      findsNothing,
      reason: '搜索态只显示搜索结果',
    );
    expect(
      tester
          .widget<FushiDropdown<MediaServerSort>>(
            find.byKey(const ValueKey<String>('media-server-grid-sort')),
          )
          .enabled,
      isFalse,
      reason: '搜索走服务器相关度序，排序菜单禁用',
    );

    await tester.tap(
      find.byKey(const ValueKey<String>('media-server-grid-search-clear')),
    );
    await tester.pumpAndSettle();
    expect(childrenRequests().length, 2, reason: '清空搜索回到浏览并重拉第一页');
    expect(
      find.byKey(const ValueKey<String>('media-server-grid-card-movie-0')),
      findsOneWidget,
    );
  });

  testWidgets('搜索首页 0 条但 hasMore：不挂滚动视图也要自动续扫，直到命中出现', (
    WidgetTester tester,
  ) async {
    // BUG-2608 第三种形状：服务器前 500 行全被客户端把关滤掉、精确命中在后面。
    // 空态没有 CustomScrollView，_onScroll 拿不到 hasClients，必须绕过它续扫。
    final List<MediaServerItem> hit = fakeMovies(1, prefix: 'hit');
    browser.searchPager = (int startIndex, int limit) {
      if (startIndex == 0) {
        return const MediaServerPage(
          items: <MediaServerItem>[],
          totalCount: 900,
          startIndex: 0,
          nextStartIndex: 500,
        );
      }
      return MediaServerPage(
        items: hit,
        totalCount: 900,
        startIndex: startIndex,
        nextStartIndex: 900,
      );
    };
    await tester.pumpWidget(harness());
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(const ValueKey<String>('media-server-grid-search')),
      'hit',
    );
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();

    final List<int> starts = browser.requests
        .where((FakePageRequest r) => r.kind == 'search')
        .map((FakePageRequest r) => r.startIndex)
        .toList();
    expect(starts, <int>[0, 500], reason: '首页 0 条后按 nextStartIndex 续扫');
    expect(
      find.byKey(const ValueKey<String>('media-server-grid-card-hit-0')),
      findsOneWidget,
    );
    expect(find.byType(FushiPlaceholderMessage), findsNothing);
  });

  testWidgets('续扫时 nextStartIndex 不前进 → 视为到尾，不无限自动翻页', (
    WidgetTester tester,
  ) async {
    int calls = 0;
    browser.searchPager = (int startIndex, int limit) {
      calls++;
      // 服务器坏了：totalCount 说还有，但页面永远 0 行、游标不动。
      return MediaServerPage(
        items: const <MediaServerItem>[],
        totalCount: 900,
        startIndex: startIndex,
        nextStartIndex: startIndex,
      );
    };
    await tester.pumpWidget(harness());
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(const ValueKey<String>('media-server-grid-search')),
      'hit',
    );
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();

    expect(calls, lessThanOrEqualTo(2), reason: '首页 + 至多一次续扫就该停');
    expect(find.byType(FushiPlaceholderMessage), findsOneWidget);
  });

  testWidgets('电影点卡直接播放：info 是它自己、不带同伴', (WidgetTester tester) async {
    browser.children['lib-movies'] = fakeMovies(3);
    await tester.pumpWidget(harness());
    await tester.pumpAndSettle();

    await tester.tap(
      find.byKey(const ValueKey<String>('media-server-grid-card-movie-1')),
    );
    await tester.pumpAndSettle();

    expect(played, hasLength(1));
    expect(played.single.info.id, 'movie-1');
    expect(played.single.hasCollection, isFalse, reason: '电影不建剧集面板');
    expect(identical(played.single.browser, browser), isTrue);
  });

  testWidgets('首页失败显示错误 + 重试；重试后正常渲染', (WidgetTester tester) async {
    browser.children['lib-movies'] = fakeMovies(3);
    browser.failChildren = true;
    await tester.pumpWidget(harness());
    await tester.pumpAndSettle();

    expect(find.text(t.media_server_items_load_failed), findsOneWidget);
    browser.failChildren = false;
    await tester.tap(
      find.byKey(const ValueKey<String>('media-server-grid-retry')),
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey<String>('media-server-grid-card-movie-0')),
      findsOneWidget,
    );
  });
}
