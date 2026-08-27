import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';

import 'package:fushi/src/media/manga/aidoku/aidoku_package_store.dart';
import 'package:fushi/src/media/manga/aidoku/aidoku_runtime.dart';
import 'package:fushi/src/media/manga/manga_global_search_page.dart';
import 'package:fushi/src/pages/implementations/media_library_shell.dart';

void main() {
  setUp(() => LocaleSettings.setLocale(AppLocale.zhCn));

  AidokuInstalledPackage package(String id, String name) =>
      AidokuInstalledPackage(
        id: id,
        name: name,
        version: 1,
        languages: const <String>['en'],
        requiresWebView: false,
        packagePath: '/$id.aix',
        installedAt: DateTime.utc(2026),
      );

  testWidgets(
      'searches every enabled Aidoku source and renders hits per source',
      (WidgetTester tester) async {
    final _GlobalRuntime runtime = _GlobalRuntime();

    await tester.pumpWidget(
      MaterialApp(
        home: MangaGlobalSearchPage(
          mihonManager: null,
          mihonSources: const <Never>[],
          aidokuPackages: <AidokuInstalledPackage>[
            package('en.good', 'Good Source'),
            package('en.blocked', 'Blocked Source'),
          ],
          aidokuRuntime: runtime,
        ),
      ),
    );
    await tester.pump();

    // Before searching: a prompt, no source rows.
    expect(find.text('Good Source'), findsNothing);

    await tester.enterText(
      find.byKey(const ValueKey<String>('manga_global_search_field')),
      'one piece',
    );
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pump();
    await tester.pump();

    // Both sources were queried once with the entered query.
    expect(runtime.searchQueries, <String>['one piece', 'one piece']);

    // The healthy source shows its hit; the CF source shows the friendly line
    // instead of a raw exception.
    expect(find.text('Good Source'), findsOneWidget);
    expect(find.text('Blocked Source'), findsOneWidget);
    expect(find.text('One Piece'), findsOneWidget);
    expect(
      find.textContaining('Cloudflare'),
      findsOneWidget,
    );
  });

  // 空态此前只有一句「请先安装并启用扩展」：漫画库里根本没有叫「扩展」的 tab
  // （来源都在「导入」视图装），而且没有任何可点的东西。现在文案指向「导入」，
  // 并给一个按钮把用户带回壳里的「导入」视图。
  //
  // **弹掉本页由壳做**（[MediaLibraryShellScope.select]），本页只管调回调：本页
  // 上面可能压着别的路由，也可能本身就压在别的页面上（发现详情页 → 全源搜索页
  // 是两层）。下面两条分别钉住「压一层」和「压两层」两个真实入口。
  Widget shellHarness({required int pushDepth}) {
    Widget searchPage(BuildContext shellContext) => MangaGlobalSearchPage(
          mihonManager: null,
          mihonSources: const <Never>[],
          aidokuPackages: const <AidokuInstalledPackage>[],
          onOpenSources: MediaLibraryShellScope.maybeOf(shellContext)
              ?.actionFor(MediaLibraryViewKind.sources),
        );

    return TranslationProvider(
      child: MaterialApp(
        home: Scaffold(
          body: MediaLibraryShell(
            focusIdPrefix: 'manga-global-search-test',
            views: <MediaLibraryViewSpec>[
              MediaLibraryViewSpec(
                kind: MediaLibraryViewKind.discover,
                label: '发现',
                builder: (BuildContext context, Widget navigation) => Builder(
                  builder: (BuildContext inner) => TextButton(
                    onPressed: () => Navigator.of(inner).push(
                      MaterialPageRoute<void>(
                        builder: (_) => pushDepth == 1
                            ? searchPage(inner)
                            : Scaffold(
                                body: Builder(
                                  builder: (BuildContext mid) => TextButton(
                                    onPressed: () => Navigator.of(mid).push(
                                      MaterialPageRoute<void>(
                                        builder: (_) => searchPage(inner),
                                      ),
                                    ),
                                    child: const Text('详情页'),
                                  ),
                                ),
                              ),
                      ),
                    ),
                    child: const Text('搜索'),
                  ),
                ),
              ),
              MediaLibraryViewSpec(
                kind: MediaLibraryViewKind.sources,
                label: '导入',
                builder: (BuildContext context, Widget navigation) =>
                    const Text('导入视图'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  testWidgets(
      'no sources: empty state names the Import tab and its button lands on it',
      (WidgetTester tester) async {
    await tester.pumpWidget(shellHarness(pushDepth: 1));
    await tester.tap(find.text('搜索'));
    await tester.pumpAndSettle();

    expect(find.text(t.manga_global_search_no_sources), findsOneWidget);
    expect(
      t.manga_global_search_no_sources,
      contains(t.library_view_import),
      reason: '空态文案必须点名用户真能找到的那个 tab（「导入」），不是「扩展」',
    );
    final Finder button =
        find.byKey(const ValueKey<String>('manga_global_search_open_sources'));
    expect(button, findsOneWidget);
    // 图标必须是「导入」的图标：拼图块（extension_outlined）正是本 bug 的病根。
    expect(
      tester.widget<Icon>(
        find.descendant(of: button, matching: find.byType(Icon)),
      ).icon,
      Icons.library_add_outlined,
    );

    await tester.tap(button);
    await tester.pumpAndSettle();
    expect(find.byType(MangaGlobalSearchPage), findsNothing,
        reason: '搜索页必须被弹掉，用户回到壳里才看得见切过去的「导入」视图');
    expect(find.text('导入视图'), findsOneWidget);
  });

  // BUG-1871 复审：第二个入口（发现详情页 → 全源搜索页）在搜索页下面还压着详情页。
  // 「本页 pop 自己」那套写法在这里只弹掉一层，详情页仍盖在壳上面。
  testWidgets('no sources: 从详情页进来（压两层）也落到「导入」视图',
      (WidgetTester tester) async {
    await tester.pumpWidget(shellHarness(pushDepth: 2));
    await tester.tap(find.text('搜索'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('详情页'));
    await tester.pumpAndSettle();
    expect(find.byType(MangaGlobalSearchPage), findsOneWidget);

    await tester.tap(
      find.byKey(const ValueKey<String>('manga_global_search_open_sources')),
    );
    await tester.pumpAndSettle();

    expect(find.byType(MangaGlobalSearchPage), findsNothing);
    expect(find.text('详情页'), findsNothing, reason: '中间那层详情页也必须被弹掉');
    expect(find.text('导入视图'), findsOneWidget);
  });

  testWidgets('no sources without a shell to switch: text only, no button',
      (WidgetTester tester) async {
    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(
          home: MangaGlobalSearchPage(
            mihonManager: null,
            mihonSources: const <Never>[],
            aidokuPackages: const <AidokuInstalledPackage>[],
          ),
        ),
      ),
    );
    await tester.pump();
    expect(find.text(t.manga_global_search_no_sources), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('manga_global_search_open_sources')),
      findsNothing,
    );
  });
}

class _GlobalRuntime extends Fake implements AidokuRuntime {
  final List<String> searchQueries = <String>[];

  @override
  Future<Map<String, Object?>> search(
    String packagePath, {
    String? query,
    int page = 1,
  }) async {
    searchQueries.add(query ?? '');
    if (packagePath.contains('blocked')) {
      throw const AidokuRuntimeException(
        'CLOUDFLARE_CHALLENGE',
        'Cloudflare challenge blocked this source',
      );
    }
    return <String, Object?>{
      'entries': <Object?>[
        <String, Object?>{'key': '/one-piece/', 'title': 'One Piece'},
      ],
      'has_next_page': false,
    };
  }
}
