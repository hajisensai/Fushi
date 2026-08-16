import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fushi/src/media/manga/aidoku/aidoku_package_store.dart';
import 'package:fushi/src/media/manga/aidoku/aidoku_runtime.dart';
import 'package:fushi/src/media/manga/manga_global_search_page.dart';

void main() {
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
