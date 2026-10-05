import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fushi/src/media/manga/aidoku/aidoku_package_store.dart';
import 'package:fushi/src/media/manga/aidoku/aidoku_runtime.dart';
import 'package:fushi/src/media/manga/aidoku/aidoku_source_browse_page.dart';
import 'package:fushi/utils.dart';

AidokuInstalledPackage _fixturePackage() => AidokuInstalledPackage(
      id: 'ja.fixture',
      name: 'Aidoku fixture',
      version: 1,
      languages: const <String>['ja'],
      requiresWebView: false,
      packagePath: '/fixture.aix',
      installedAt: DateTime.utc(2026),
    );

void main() {
  setUp(() => LocaleSettings.setLocale(AppLocale.en));

  // 2026-10 体验优化：Aidoku 的 buildVerifyAction 原先把错误文字再画一遍，同一
  // 句话在页面上出现两次；且原文带 `Exception:` 前缀。
  testWidgets('浏览失败时错误只显示一次，且去掉 Exception: 前缀',
      (WidgetTester tester) async {
    final _BrowseRuntime runtime =
        _BrowseRuntime(browseError: Exception('Source said no'));
    await tester.pumpWidget(
      MaterialApp(
        home: AidokuSourceBrowsePage(
          package: _fixturePackage(),
          runtime: runtime,
        ),
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(find.text('Source said no'), findsOneWidget);
    expect(find.textContaining('Exception:'), findsNothing);
    expect(find.text(t.retry), findsOneWidget);
  });

  testWidgets('Cloudflare 拦截给专门文案且只出现一次', (WidgetTester tester) async {
    final _BrowseRuntime runtime = _BrowseRuntime(
      browseError: const AidokuRuntimeException(
        kAidokuCloudflareChallengeCode,
        'challenge',
      ),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: AidokuSourceBrowsePage(
          package: _fixturePackage(),
          runtime: runtime,
        ),
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(find.text(t.manga_source_cloudflare_blocked), findsOneWidget);
  });

  testWidgets('uses the source listing and renders the Mihon-shaped grid',
      (WidgetTester tester) async {
    final _BrowseRuntime runtime = _BrowseRuntime();
    final AidokuInstalledPackage package = AidokuInstalledPackage(
      id: 'ja.fixture',
      name: 'Aidoku fixture',
      version: 1,
      languages: const <String>['ja'],
      requiresWebView: false,
      packagePath: '/fixture.aix',
      installedAt: DateTime.utc(2026),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: AidokuSourceBrowsePage(package: package, runtime: runtime),
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(runtime.browseCalls, 1);
    expect(runtime.searchCalls, 0);
    expect(find.text('Latest fixture manga'), findsOneWidget);
    expect(find.byType(GridView), findsOneWidget);
    // 版式是三域共用的 OnlineSourceBrowsePage（2026-09-27「浏览」阶段 2）：页头
    // 搜索框，listing 是正文顶部的分段条（不再是页头下拉框）。
    expect(
      find.byKey(const ValueKey<String>('aidoku_source_search_field')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('aidoku_source_listing')),
      findsOneWidget,
    );
    expect(find.text('Aidoku fixture'), findsOneWidget);

    await tester.tap(find.text('Latest fixture manga'));
    await tester.pump();
    // 详情页并入共享的 MangaSeriesPage 后多了一次异步跳：页面先离线渲染，再由
    // 自己去拉章节（旧详情页是在 initState 里一次拉完）。与 Mihon 侧同款用例
    // 一致，给这次拉取一个 pump 窗口。
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.text('Ch. 13.5'), findsOneWidget);
  });
}

class _BrowseRuntime extends Fake implements AidokuRuntime {
  _BrowseRuntime({this.browseError});

  final Exception? browseError;
  int browseCalls = 0;
  int searchCalls = 0;

  @override
  Future<AidokuPackageInspection> inspect(String packagePath) async =>
      AidokuPackageInspection(
        manifest: const <String, Object?>{
          'info': <String, Object?>{
            'id': 'ja.fixture',
            'name': 'Aidoku fixture',
            'version': 1,
            'urls': <Object?>['https://fixture.example'],
          },
          'listings': <Object?>[
            <String, Object?>{'id': '/latest/', 'name': 'Latest'},
          ],
        },
        imports: const <String>[],
        exports: const <String>['get_manga_list'],
        requiresWebView: false,
      );

  @override
  Future<Map<String, Object?>> browse(
    String packagePath,
    AidokuListing listing, {
    int page = 1,
  }) async {
    browseCalls++;
    final Exception? error = browseError;
    if (error != null) throw error;
    return <String, Object?>{
      'entries': <Object?>[
        <String, Object?>{
          'key': '/latest-fixture/',
          'title': 'Latest fixture manga',
        },
      ],
      'has_next_page': false,
    };
  }

  @override
  Future<Map<String, Object?>> search(
    String packagePath, {
    String? query,
    int page = 1,
  }) async {
    searchCalls++;
    return <String, Object?>{
      'entries': const <Object?>[],
      'has_next_page': false,
    };
  }

  @override
  Future<Map<String, Object?>> getDetails(
    String packagePath,
    Map<String, Object?> manga,
  ) async =>
      <String, Object?>{
        ...manga,
        'description': 'Fixture description',
        'chapters': <Object?>[
          <String, Object?>{
            'key': '/internal/chapter-key/',
            'title': null,
            'chapter_number': 13.5,
            'volume_number': null,
            'scanlators': <Object?>['Fixture group'],
            'language': 'ja',
            'locked': false,
          },
        ],
      };

  @override
  Future<List<Object?>> getPages(
    String packagePath,
    Map<String, Object?> manga,
    Map<String, Object?> chapter,
  ) async =>
      <Object?>[
        <String, Object?>{
          'content': <String, Object?>{
            'Url': <Object?>['https://example.test/page.jpg', null],
          },
        },
      ];
}
