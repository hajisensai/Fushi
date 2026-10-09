import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/media_server/media_server_browser.dart';
import 'package:fushi/src/pages/implementations/media_server/media_server_grid_view.dart';
import 'package:fushi/src/pages/implementations/media_server/media_server_home_view.dart';
import 'package:fushi/src/pages/implementations/media_server/media_server_session.dart';
import 'package:fushi/src/pages/implementations/media_server/media_server_widgets.dart';
import 'package:fushi/utils.dart';

import 'fake_media_server_browser.dart';

/// 服务器首页：库行渲染 + 每库一行「该库最新」（海报，不是库内物理文件夹）；
/// 装饰行（继续观看 / 最新）失败不影响页面；`listLibraries` 失败显示错误与重试。
void main() {
  late FakeMediaServerBrowser browser;

  const MediaServerLibrary movies = MediaServerLibrary(
    id: 'lib-movies',
    name: '动画电影',
    kind: MediaServerLibraryKind.movies,
  );
  const MediaServerLibrary shows = MediaServerLibrary(
    id: 'lib-shows',
    name: '动漫剧集',
    kind: MediaServerLibraryKind.tvShows,
  );

  setUp(() {
    LocaleSettings.setLocale(AppLocale.zhCn);
    browser = FakeMediaServerBrowser();
  });

  Widget harness() {
    return TranslationProvider(
      child: MaterialApp(
        home: Scaffold(
          body: MediaServerHomeView(
            session: MediaServerSession(
              browser: browser,
              play: (BuildContext _, MediaServerPlayRequest __) {},
            ),
          ),
        ),
      ),
    );
  }

  testWidgets('库行 + 继续观看 + 每库一行最新（前 20 条）', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1200, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    browser.libraries.addAll(<MediaServerLibrary>[movies, shows]);
    browser.latestByLibrary['lib-movies'] = fakeMovies(30);
    browser.latestByLibrary['lib-shows'] = const <MediaServerItem>[
      MediaServerItem(
        id: 's1',
        name: 'Series s1',
        type: MediaServerItemType.series,
        unplayedChildCount: 3,
      ),
    ];
    browser.resume.addAll(
      fakeEpisodes(seriesId: 's1', seasonId: 'sea1', seasonNumber: 1, count: 2),
    );
    // NextUp 与 Resume 重复的一条要去重。
    browser.nextUp.addAll(
      fakeEpisodes(seriesId: 's1', seasonId: 'sea1', seasonNumber: 1, count: 3),
    );

    await tester.pumpWidget(harness());
    await tester.pumpAndSettle();

    expect(find.text(t.media_server_libraries_title), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('media-server-library-lib-movies')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('media-server-home-continue')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('media-server-home-row-lib-movies')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('media-server-home-row-lib-shows')),
      findsOneWidget,
    );
    // 每库一行按库问最新，不再列库的直接子级；只要前 20 条。
    expect(
      browser.latestRequests,
      unorderedEquals(<String?>['lib-movies', 'lib-shows']),
    );
    expect(
      browser.requests.where((FakePageRequest r) => r.kind == 'children'),
      isEmpty,
    );
    expect(
      tester
          .widget<MediaServerRow>(
            find.byKey(
              const ValueKey<String>('media-server-home-row-lib-movies'),
            ),
          )
          .itemCount,
      kMediaServerRowLimit,
    );
    // 继续观看 = Resume ∪ NextUp 去重：2 + 3 - 2 = 3 张卡。
    expect(
      find.byWidgetPredicate(
        (Widget w) =>
            w.key is ValueKey<String> &&
            (w.key! as ValueKey<String>).value.startsWith(
              'fake:server-home-continue-card-',
            ),
        skipOffstage: false,
      ),
      findsNWidgets(3),
    );
    // 剧卡未看角标。
    expect(find.text('3'), findsOneWidget);
  });

  testWidgets('库是按物理文件夹组织的：首页行显示最新作品海报，不显示文件夹卡', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1200, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    // 用户截图里的「动漫」库：直接子级是「完结动漫 / 新番完结」两个文件夹，
    // 最新是折成系列的剧（带未看数）。
    browser.libraries.add(shows);
    browser.children['lib-shows'] = const <MediaServerItem>[
      MediaServerItem(
        id: 'folder-done',
        name: '完结动漫',
        type: MediaServerItemType.folder,
        childCount: 58,
      ),
      MediaServerItem(
        id: 'folder-new',
        name: '新番完结',
        type: MediaServerItemType.folder,
        childCount: 6,
      ),
    ];
    browser.latestByLibrary['lib-shows'] = const <MediaServerItem>[
      MediaServerItem(
        id: 'series-reife',
        name: '重生计划',
        type: MediaServerItemType.series,
        productionYear: 2016,
        unplayedChildCount: 17,
      ),
      MediaServerItem(
        id: 'series-onepiece',
        name: '航海王',
        type: MediaServerItemType.series,
        productionYear: 1999,
      ),
    ];

    await tester.pumpWidget(harness());
    await tester.pumpAndSettle();

    final Finder row = find.byKey(
      const ValueKey<String>('media-server-home-row-lib-shows'),
    );
    expect(row, findsOneWidget);
    expect(
      find.descendant(of: row, matching: find.text('重生计划')),
      findsOneWidget,
    );
    expect(find.descendant(of: row, matching: find.text('17')), findsOneWidget);
    expect(find.text('完结动漫'), findsNothing, reason: '不再列库内物理文件夹');
    expect(find.text('新番完结'), findsNothing);
  });

  testWidgets('Latest 拿不到（兼容层）：该库行退回直接子级', (WidgetTester tester) async {
    browser.libraries.add(movies);
    browser.children['lib-movies'] = fakeMovies(2);

    await tester.pumpWidget(harness());
    await tester.pumpAndSettle();

    expect(browser.latestRequests, <String?>['lib-movies']);
    final Iterable<FakePageRequest> rows = browser.requests.where(
      (FakePageRequest r) => r.kind == 'children' && r.parentId == 'lib-movies',
    );
    expect(rows.single.limit, kMediaServerRowLimit);
    expect(
      find.byKey(const ValueKey<String>('media-server-home-row-lib-movies')),
      findsOneWidget,
    );
  });

  testWidgets('装饰行全部失败：页面照常，只是没有那几行', (WidgetTester tester) async {
    browser.libraries.add(movies);
    browser.children['lib-movies'] = fakeMovies(2);
    browser.failResume = true;
    browser.failNextUp = true;
    browser.failLatest = true;

    await tester.pumpWidget(harness());
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey<String>('media-server-library-lib-movies')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('media-server-home-row-lib-movies')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('media-server-home-continue')),
      findsNothing,
    );
    expect(
      find.byType(FushiPlaceholderMessage),
      findsNothing,
      reason: '装饰行失败不是整页错误',
    );
  });

  testWidgets('listLibraries 失败：错误 + 重试；重试后渲染', (WidgetTester tester) async {
    browser.libraries.add(movies);
    browser.children['lib-movies'] = fakeMovies(1);
    browser.failLibraries = true;

    await tester.pumpWidget(harness());
    await tester.pumpAndSettle();

    expect(find.text(t.jellyfin_libraries_load_failed), findsOneWidget);
    expect(browser.listLibrariesCalls, 1);

    browser.failLibraries = false;
    await tester.tap(
      find.byKey(const ValueKey<String>('media-server-home-retry')),
    );
    await tester.pumpAndSettle();

    expect(browser.listLibrariesCalls, 2);
    expect(
      find.byKey(const ValueKey<String>('media-server-library-lib-movies')),
      findsOneWidget,
    );
  });

  testWidgets('点库卡进库网格（parentId = 库 id）', (WidgetTester tester) async {
    browser.libraries.add(movies);
    browser.children['lib-movies'] = fakeMovies(1);

    await tester.pumpWidget(harness());
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey<String>('media-server-library-lib-movies')),
    );
    await tester.pumpAndSettle();

    final MediaServerGridView grid = tester.widget<MediaServerGridView>(
      find.byType(MediaServerGridView),
    );
    expect(grid.parentId, 'lib-movies');
    expect(grid.title, '动画电影');
  });
}
