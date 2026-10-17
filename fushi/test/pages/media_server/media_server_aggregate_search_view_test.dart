import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/media_server/media_server_browser.dart';
import 'package:fushi/src/pages/implementations/media_server/media_server_aggregate_search_view.dart';
import 'package:fushi/src/pages/implementations/media_server/media_server_grid_view.dart';
import 'package:fushi/src/pages/implementations/media_server/media_server_session.dart';
import 'package:fushi/utils.dart';

import 'fake_media_server_browser.dart';

/// 「搜索所有服务器」（反馈 WzyI2H87rw）：同一个关键词并发问每台服务器，按服务器
/// 分组展示；一台失败只在它那组显示错误，不连累其它；「查看全部」带着关键词进那台
/// 的搜索网格。
void main() {
  late FakeMediaServerBrowser emby;
  late FakeMediaServerBrowser jellyfin;
  late FakeMediaServerBrowser broken;

  setUp(() {
    LocaleSettings.setLocale(AppLocale.zhCn);
    emby = FakeMediaServerBrowser(serverId: 'emby:a', displayName: 'Emby A');
    jellyfin = FakeMediaServerBrowser(
      serverId: 'jellyfin:b',
      displayName: 'Jellyfin B',
    );
    broken = FakeMediaServerBrowser(serverId: 'emby:c', displayName: 'Emby C')
      ..failSearch = true;
    emby.searchResults.addAll(fakeMovies(2, prefix: 'a'));
    jellyfin.searchResults.addAll(fakeMovies(3, prefix: 'b'));
  });

  MediaServerSession session(MediaServerBrowser browser) => MediaServerSession(
    browser: browser,
    play: (BuildContext _, MediaServerPlayRequest __) {},
  );

  Widget harness() => TranslationProvider(
    child: MaterialApp(
      home: Scaffold(
        body: MediaServerAggregateSearchView(
          sessions: <MediaServerSession>[
            session(emby),
            session(jellyfin),
            session(broken),
          ],
        ),
      ),
    ),
  );

  Future<void> search(WidgetTester tester, String query) async {
    await tester.enterText(
      find.byKey(const ValueKey<String>('media-server-aggregate-search')),
      query,
    );
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
  }

  testWidgets('一次搜索问遍所有服务器，按服务器分组；失败只影响自己那组', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1200, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(harness());
    await tester.pumpAndSettle();
    expect(emby.requests, isEmpty, reason: '空关键词不发请求');

    await search(tester, '猫');

    for (final FakeMediaServerBrowser browser in <FakeMediaServerBrowser>[
      emby,
      jellyfin,
      broken,
    ]) {
      final List<FakePageRequest> searches = browser.requests
          .where((FakePageRequest r) => r.kind == 'search')
          .toList();
      expect(searches, hasLength(1), reason: browser.serverId);
      expect(searches.single.query, '猫');
    }
    expect(find.text('Emby A'), findsOneWidget);
    expect(find.text('Jellyfin B'), findsOneWidget);
    expect(find.text('Emby C'), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('emby:a-aggregate-search-card-a-1')),
      findsOneWidget,
    );
    expect(
      find.byKey(
        const ValueKey<String>('jellyfin:b-aggregate-search-card-b-2'),
      ),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('media-server-aggregate-retry-emby:c')),
      findsOneWidget,
    );

    // 修好后重试：只重问失败的那台。
    broken
      ..failSearch = false
      ..searchResults.addAll(fakeMovies(1, prefix: 'c'));
    await tester.tap(
      find.byKey(const ValueKey<String>('media-server-aggregate-retry-emby:c')),
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey<String>('emby:c-aggregate-search-card-c-0')),
      findsOneWidget,
    );
    expect(
      emby.requests.where((FakePageRequest r) => r.kind == 'search'),
      hasLength(1),
    );
  });

  testWidgets('「查看全部」带着关键词进那台服务器的搜索网格', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1200, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(harness());
    await tester.pumpAndSettle();
    await search(tester, '猫');

    await tester.tap(find.text(t.media_server_row_view_all).first);
    await tester.pumpAndSettle();

    final MediaServerGridView grid = tester.widget(
      find.byType(MediaServerGridView),
    );
    expect(grid.initialQuery, '猫');
    expect(grid.session.serverId, 'emby:a');
    final List<FakePageRequest> searches = emby.requests
        .where((FakePageRequest r) => r.kind == 'search')
        .toList();
    expect(searches, hasLength(2), reason: '网格一进来就按带入的关键词搜');
    expect(searches.last.query, '猫');
  });

  test('searchMediaServerSession 把失败收成结果而不是抛出', () async {
    final MediaServerSearchOutcome ok = await searchMediaServerSession(
      session(emby),
      'x',
    );
    expect(ok.error, isNull);
    expect(ok.items, hasLength(2));
    final MediaServerSearchOutcome failed = await searchMediaServerSession(
      session(broken),
      'x',
    );
    expect(failed.error, isA<StateError>());
    expect(failed.items, isEmpty);
  });
}
