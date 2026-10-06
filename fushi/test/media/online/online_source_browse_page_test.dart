import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/online/online_source_browse_page.dart';
import '../../helpers/glass_unwrap.dart';

/// 三域共用源浏览页（2026-09-27「浏览」阶段 2）的行为契约，用假适配器驱动：
/// 列表切换 / 搜索 / 筛选落点 / 离底自动翻页 / 全重复页停翻 / 过期响应丢弃。
void main() {
  Future<void> pumpPage(WidgetTester tester, _FakeCatalog catalog) async {
    await tester.binding.setSurfaceSize(const Size(800, 600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(home: OnlineSourceBrowsePage<String>(catalog: catalog)),
    );
    await tester.pump();
    await tester.pump();
  }

  Finder field() => find.byKey(const ValueKey<String>('fake_search_field'));

  testWidgets('进页取第一个列表；切列表按那个列表重新取第一页', (WidgetTester tester) async {
    final _FakeCatalog catalog = _FakeCatalog();
    await pumpPage(tester, catalog);
    expect(catalog.calls.single.$1.listingId, 'popular');
    expect(catalog.calls.single.$2, 1);
    expect(
      find.byKey(const ValueKey<String>('fake_item_popular-p1-0')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey<String>('fake_listing')), findsOneWidget);

    await tester.tap(find.text('Latest'));
    await tester.pump();
    await tester.pump();
    expect(catalog.calls.last.$1.listingId, 'latest');
    expect(catalog.calls.last.$1.isSearch, isFalse);
    expect(catalog.calls.last.$2, 1);
    expect(
      find.byKey(const ValueKey<String>('fake_item_latest-p1-0')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('fake_item_popular-p1-0')),
      findsNothing,
      reason: '切列表是重置，不与旧列表拼接。',
    );
  });

  testWidgets('搜索框提交走搜索查询，带上搜索词', (WidgetTester tester) async {
    final _FakeCatalog catalog = _FakeCatalog();
    await pumpPage(tester, catalog);
    await tester.enterText(field(), '  異世界 ');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pump();
    await tester.pump();
    final OnlineBrowseQuery query = catalog.calls.last.$1;
    expect(query.isSearch, isTrue);
    expect(query.listingId, isNull);
    expect(query.text, '異世界');
    expect(catalog.calls.last.$2, 1);
    expect(
      find.byKey(const ValueKey<String>('fake_item_search:異世界-p1-0')),
      findsOneWidget,
    );
  });

  testWidgets('筛选落到第一个列表时清空搜索词，查询标记 filtered', (WidgetTester tester) async {
    final _FakeCatalog catalog = _FakeCatalog()
      ..filterTarget = OnlineBrowseFilterTarget.firstListing;
    await pumpPage(tester, catalog);
    await tester.enterText(field(), 'query');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pump();
    await tester.pump();
    expect(catalog.calls.last.$1.isSearch, isTrue);

    await tester.tap(find.byKey(const ValueKey<String>('fake_filters')));
    await tester.pump();
    await tester.pump();
    expect(catalog.filterEdits, 1);
    final OnlineBrowseQuery query = catalog.calls.last.$1;
    expect(query.listingId, 'popular');
    expect(query.isSearch, isFalse);
    expect(query.filtered, isTrue);
    expect(tester.widget<TextField>(glassUnwrap<TextField>(field())).controller!.text, isEmpty);
  });

  // PR #1707 审查：合并成共用页后小说筛选按钮的提示变成了 Mihon 的「来源偏好」。
  testWidgets('筛选按钮的提示由适配器给出', (WidgetTester tester) async {
    final _FakeCatalog catalog = _FakeCatalog();
    await pumpPage(tester, catalog);
    final IconButton button = tester.widget<IconButton>(glassUnwrap<IconButton>(find.byKey(const ValueKey<String>('fake_filters'))),);
    expect(button.tooltip, 'Fake filters');
    expect(
      File(
        'lib/src/media/novel/online/lnreader_source_browse_page.dart',
      ).readAsStringSync().replaceAll(RegExp(r'\s+'), ''),
      contains('StringgetfiltersTooltip=>t.novel_source_filters_title;'),
      reason: 'LNReader 的筛选按钮提示是「筛选」，不是 Mihon 的「来源偏好」。',
    );
  });

  testWidgets('筛选落到搜索时切成搜索查询并保留搜索词', (WidgetTester tester) async {
    final _FakeCatalog catalog = _FakeCatalog()
      ..filterTarget = OnlineBrowseFilterTarget.search;
    await pumpPage(tester, catalog);
    await tester.enterText(field(), 'kept');
    await tester.tap(find.byKey(const ValueKey<String>('fake_filters')));
    await tester.pump();
    await tester.pump();
    final OnlineBrowseQuery query = catalog.calls.last.$1;
    expect(query.isSearch, isTrue);
    expect(query.text, 'kept');
    expect(query.filtered, isTrue);
  });

  testWidgets('滚到离底 600 以内自动取下一页，未到不取', (WidgetTester tester) async {
    final _FakeCatalog catalog = _FakeCatalog(pageSize: 40);
    await pumpPage(tester, catalog);
    expect(catalog.calls.map(((OnlineBrowseQuery, int) c) => c.$2), <int>[1]);

    // 小幅滚动：离底仍远，不翻页。
    await tester.drag(find.byType(GridView), const Offset(0, -100));
    await tester.pump();
    await tester.pump();
    expect(catalog.calls.map(((OnlineBrowseQuery, int) c) => c.$2), <int>[1]);

    final ScrollableState scrollable = tester.state<ScrollableState>(
      find.descendant(
        of: find.byType(GridView),
        matching: find.byType(Scrollable),
      ),
    );
    final ScrollPosition position = scrollable.position;
    expect(position.extentAfter, greaterThan(kOnlineBrowseAutoLoadExtent));
    // 第 2 页挂起：拖动手势还在发滚动通知时不让它提前回来（否则通知里的旧度量
    // 会再触发一页，与本用例要钉的「过线取下一页」无关）。
    final Completer<OnlineBrowsePageResult<String>> page2 =
        Completer<OnlineBrowsePageResult<String>>();
    catalog.pending = <Completer<OnlineBrowsePageResult<String>>>[page2];
    await tester.drag(
      find.byType(GridView),
      Offset(0, -(position.extentAfter - kOnlineBrowseAutoLoadExtent + 50)),
    );
    await tester.pump();
    await tester.pump();
    expect(catalog.calls.map(((OnlineBrowseQuery, int) c) => c.$2), <int>[
      1,
      2,
    ]);
    expect(catalog.calls.last.$1.listingId, 'popular');
    page2.complete((
      items: <String>[for (int i = 0; i < 40; i++) 'popular-p2-$i'],
      hasNextPage: true,
    ));
    await tester.pump();
    await tester.pump();
    await tester.drag(find.byType(GridView), const Offset(0, -300));
    await tester.pump();
    expect(
      find.byKey(const ValueKey<String>('fake_item_popular-p2-0')),
      findsOneWidget,
      reason: '第 2 页接在第 1 页后面。',
    );
    expect(catalog.calls.length, 2, reason: '接上第 2 页后离底又远了，不连翻。');
  });

  testWidgets('源立即返回时，同一次拖动只自动翻一页（旧度量不再连翻）', (WidgetTester tester) async {
    final _FakeCatalog catalog = _FakeCatalog(pageSize: 40);
    await pumpPage(tester, catalog);
    final ScrollPosition position = tester
        .state<ScrollableState>(
          find.descendant(
            of: find.byType(GridView),
            matching: find.byType(Scrollable),
          ),
        )
        .position;
    // 一次拖动里的多个 move 事件之间不出帧：第 2 页的 fetch 立即完成、_loading
    // 已回落，后面几个 move 触发的滚动通知带的仍是第 2 页排进网格前的度量。
    await tester.drag(
      find.byType(GridView),
      Offset(0, -(position.extentAfter - kOnlineBrowseAutoLoadExtent + 400)),
      touchSlopY: 0,
    );
    await tester.pumpAndSettle();
    expect(
      catalog.calls.map(((OnlineBrowseQuery, int) c) => c.$2),
      <int>[1, 2],
      reason: '第 2 页排进网格后离底又远了，不能因为旧度量再翻第 3 页。',
    );
  });

  testWidgets('下一页全是重复条目时停止翻页，「加载更多」消失', (WidgetTester tester) async {
    final _FakeCatalog catalog = _FakeCatalog(pageSize: 2)
      ..duplicatePagesAfterFirst = true;
    await pumpPage(tester, catalog);
    final Finder more = find.byKey(const ValueKey<String>('fake_more'));
    expect(more, findsOneWidget);

    await tester.tap(more);
    await tester.pump();
    await tester.pump();
    expect(catalog.calls.map(((OnlineBrowseQuery, int) c) => c.$2), <int>[
      1,
      2,
    ]);
    expect(more, findsNothing, reason: '源仍报 hasNextPage，但这一页没有新条目。');
    expect(
      find.byWidgetPredicate(
        (Widget w) =>
            w.key is ValueKey<String> &&
            (w.key! as ValueKey<String>).value.startsWith('fake_item_'),
      ),
      findsNWidgets(2),
      reason: '重复条目按 keyOf 去重，不重复渲染。',
    );
  });

  testWidgets('过期响应（旧一代请求晚到）被丢弃，不覆盖新结果', (WidgetTester tester) async {
    final _FakeCatalog catalog = _FakeCatalog();
    await pumpPage(tester, catalog);

    final Completer<OnlineBrowsePageResult<String>> latest =
        Completer<OnlineBrowsePageResult<String>>();
    final Completer<OnlineBrowsePageResult<String>> search =
        Completer<OnlineBrowsePageResult<String>>();
    catalog.pending = <Completer<OnlineBrowsePageResult<String>>>[
      latest,
      search,
    ];

    await tester.tap(find.text('Latest'));
    await tester.pump();
    await tester.enterText(field(), 'fresh');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pump();
    expect(catalog.calls.length, 3);

    search.complete((items: <String>['search-hit'], hasNextPage: false));
    await tester.pump();
    await tester.pump();
    latest.complete((items: <String>['latest-hit'], hasNextPage: true));
    await tester.pump();
    await tester.pump();

    expect(
      find.byKey(const ValueKey<String>('fake_item_search-hit')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('fake_item_latest-hit')),
      findsNothing,
    );
    expect(find.byKey(const ValueKey<String>('fake_more')), findsNothing);
  });
}

class _FakeCatalog extends OnlineSourceCatalog<String> {
  _FakeCatalog({this.pageSize = 6});

  final int pageSize;
  final List<(OnlineBrowseQuery, int)> calls = <(OnlineBrowseQuery, int)>[];
  OnlineBrowseFilterTarget? filterTarget;
  int filterEdits = 0;
  bool duplicatePagesAfterFirst = false;

  /// 非空时后续 fetch 依次挂在这些 completer 上（测过期响应）。
  List<Completer<OnlineBrowsePageResult<String>>> pending =
      <Completer<OnlineBrowsePageResult<String>>>[];

  @override
  String get title => 'Fake source';

  @override
  String get searchHint => 'Search fake';

  @override
  String get keyPrefix => 'fake';

  @override
  Future<void> prepare() async {}

  @override
  List<OnlineBrowseListing> get listings => const <OnlineBrowseListing>[
    OnlineBrowseListing(id: 'popular', label: 'Popular'),
    OnlineBrowseListing(id: 'latest', label: 'Latest'),
  ];

  @override
  bool get hasFilters => true;

  @override
  String get filtersTooltip => 'Fake filters';

  @override
  Future<OnlineBrowseFilterTarget?> editFilters(BuildContext context) async {
    filterEdits++;
    return filterTarget;
  }

  @override
  Future<OnlineBrowsePageResult<String>> fetch(
    OnlineBrowseQuery query,
    int page,
  ) {
    calls.add((query, page));
    if (pending.isNotEmpty) return pending.removeAt(0).future;
    final String scope = query.isSearch
        ? 'search:${query.text}'
        : query.listingId!;
    final int effectivePage = duplicatePagesAfterFirst ? 1 : page;
    return Future<OnlineBrowsePageResult<String>>.value((
      items: <String>[
        for (int i = 0; i < pageSize; i++) '$scope-p$effectivePage-$i',
      ],
      hasNextPage: true,
    ));
  }

  @override
  String keyOf(String item) => item;

  @override
  String titleOf(String item) => item;

  @override
  Widget buildCover(BuildContext context, String item) =>
      const ColoredBox(color: Colors.grey);

  @override
  void Function(BuildContext context, String item)? get openDetail => null;

  @override
  Widget buildVerifyAction(
    BuildContext context, {
    required Object? error,
    required Future<void> Function() onVerified,
  }) => const SizedBox.shrink();
}
