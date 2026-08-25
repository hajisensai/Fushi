import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';

import 'package:fushi/src/media/manga/aidoku/aidoku_package_store.dart';
import 'package:fushi/src/media/manga/aidoku/aidoku_runtime.dart';
import 'package:fushi/src/media/manga/manga_global_search_page.dart';

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
  // 并给一个按钮：先 pop 本页、再让调用方切壳视图（顺序不能反）。
  testWidgets(
      'no sources: empty state names the Import tab and its button pops then opens it',
      (WidgetTester tester) async {
    int opened = 0;
    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(
          home: Builder(
            builder: (BuildContext context) => Scaffold(
              body: TextButton(
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => MangaGlobalSearchPage(
                      mihonManager: null,
                      mihonSources: const <Never>[],
                      aidokuPackages: const <AidokuInstalledPackage>[],
                      onOpenSources: () => opened++,
                    ),
                  ),
                ),
                child: const Text('shell'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('shell'));
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

    await tester.tap(button);
    await tester.pumpAndSettle();
    expect(opened, 1);
    expect(find.byType(MangaGlobalSearchPage), findsNothing,
        reason: '按钮先把搜索页弹掉，用户回到壳里才看得见切过去的「导入」视图');
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
