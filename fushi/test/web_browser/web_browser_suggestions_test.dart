import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import 'package:fushi/src/web_browser/data/memory_web_browser_store.dart';
import 'package:fushi/src/web_browser/data/web_browser_store.dart';
import 'package:fushi/src/web_browser/web_browser_sites.dart';
import 'package:fushi/src/web_browser/web_browser_suggestions.dart';

WebBrowserHistoryEntry _h(
  int id,
  String url,
  String title, {
  int visits = 1,
  int minutesAgo = 0,
}) => WebBrowserHistoryEntry(
  id: id,
  url: Uri.parse(url),
  title: title,
  lastVisitedAt: DateTime(
    2026,
    10,
    23,
    12,
  ).subtract(Duration(minutes: minutesAgo)),
  visitCount: visits,
);

WebBrowserBookmark _b(int id, String url, String title) => WebBrowserBookmark(
  id: id,
  title: title,
  url: Uri.parse(url),
  parentId: null,
  position: id,
  createdAt: DateTime(2026),
);

void main() {
  group('rankWebBrowserLocalSuggestions', () {
    test('empty input yields nothing', () {
      expect(
        rankWebBrowserLocalSuggestions(
          input: '  ',
          bookmarks: <WebBrowserBookmark>[_b(1, 'https://a.com/', 'A')],
          history: const <WebBrowserHistoryEntry>[],
        ),
        isEmpty,
      );
    });

    test('bookmarks first, then prefix, visits, recency', () {
      final List<WebBrowserSuggestion> result = rankWebBrowserLocalSuggestions(
        input: 'man',
        bookmarks: <WebBrowserBookmark>[
          _b(1, 'https://example.com/manga', 'Reading list'),
        ],
        history: <WebBrowserHistoryEntry>[
          _h(1, 'https://www.mangadex.org/', 'MangaDex', visits: 2),
          _h(2, 'https://mangaplus.com/', 'Plus', visits: 9),
          _h(3, 'https://foo.com/romance', 'Romance', visits: 50),
          _h(4, 'https://manhua.com/', 'Manhua', visits: 2, minutesAgo: 30),
          _h(5, 'https://other.com/', 'Other', visits: 99),
        ],
      );
      expect(result.map((WebBrowserSuggestion s) => s.url.toString()), <String>[
        'https://example.com/manga',
        'https://mangaplus.com/',
        'https://www.mangadex.org/',
        'https://manhua.com/',
        'https://foo.com/romance',
      ]);
      expect(result.first.kind, WebBrowserSuggestionKind.bookmark);
      expect(result[1].kind, WebBrowserSuggestionKind.history);
    });

    test('scheme and www in input are ignored, url dedup keeps bookmark', () {
      final List<WebBrowserSuggestion> result = rankWebBrowserLocalSuggestions(
        input: 'https://www.github.com/f',
        bookmarks: <WebBrowserBookmark>[
          _b(1, 'https://github.com/foo', 'Foo repo'),
        ],
        history: <WebBrowserHistoryEntry>[
          _h(1, 'https://github.com/foo', 'Foo', visits: 3),
        ],
      );
      expect(result, hasLength(1));
      expect(result.single.kind, WebBrowserSuggestionKind.bookmark);
      expect(result.single.title, 'Foo repo');
    });

    test('respects limit', () {
      final List<WebBrowserSuggestion> result = rankWebBrowserLocalSuggestions(
        input: 'a',
        bookmarks: const <WebBrowserBookmark>[],
        history: <WebBrowserHistoryEntry>[
          for (int i = 0; i < 10; i++) _h(i, 'https://a$i.com/', 'a$i'),
        ],
        limit: 3,
      );
      expect(result, hasLength(3));
    });
  });

  test('parseOpenSearchSuggestions', () {
    expect(parseOpenSearchSuggestions('["q",["q1","q2",""]]'), <String>[
      'q1',
      'q2',
    ]);
    expect(parseOpenSearchSuggestions('not json'), isEmpty);
    expect(parseOpenSearchSuggestions('{"a":1}'), isEmpty);
  });

  test('mergeWebBrowserSuggestions drops the typed text and duplicates', () {
    final List<WebBrowserSuggestion> merged = mergeWebBrowserSuggestions(
      input: 'one',
      local: <WebBrowserSuggestion>[
        WebBrowserSuggestion.page(
          kind: WebBrowserSuggestionKind.history,
          title: 'One',
          url: Uri.parse('https://one.com/'),
        ),
      ],
      remote: <String>['one', 'one piece', 'one piece', 'one ok rock'],
      remoteLimit: 5,
    );
    expect(merged.map((WebBrowserSuggestion s) => s.title), <String>[
      'One',
      'one piece',
      'one ok rock',
    ]);
    expect(merged.last.kind, WebBrowserSuggestionKind.search);
  });

  group('WebBrowserSuggestionsController', () {
    test('pushes local first then merged, stale results dropped', () async {
      final MemoryWebBrowserStore store = MemoryWebBrowserStore();
      await store.recordVisit(
        url: Uri.parse('https://mangadex.org/'),
        title: 'MangaDex',
      );
      final List<Uri> fetched = <Uri>[];
      final Map<String, Completer<List<String>>> pending =
          <String, Completer<List<String>>>{};
      final WebBrowserSuggestionsController controller =
          WebBrowserSuggestionsController(
            store: store,
            provider: () => WebBrowserSearchEngine.google,
            debounce: Duration.zero,
            fetcher: (Uri url) {
              fetched.add(url);
              final Completer<List<String>> c = Completer<List<String>>();
              pending[url.queryParameters['q']!] = c;
              return c.future;
            },
          );
      final List<List<WebBrowserSuggestion>> pushes =
          <List<WebBrowserSuggestion>>[];
      controller.suggestions.listen(pushes.add);

      await controller.update('man');
      await Future<void>.delayed(Duration.zero);
      await controller.update('mang');
      await Future<void>.delayed(Duration.zero);
      expect(fetched.map((Uri u) => u.host), <String>[
        'suggestqueries.google.com',
        'suggestqueries.google.com',
      ]);
      pending['man']!.complete(<String>['stale']);
      pending['mang']!.complete(<String>['manga']);
      await Future<void>.delayed(Duration.zero);

      expect(pushes, hasLength(3));
      expect(pushes.last.map((WebBrowserSuggestion s) => s.title), <String>[
        'MangaDex',
        'manga',
      ]);
      expect(
        pushes
            .expand((List<WebBrowserSuggestion> p) => p)
            .map((WebBrowserSuggestion s) => s.title),
        isNot(contains('stale')),
      );
      controller.dispose();
    });

    test('fetch failures are silent and offline mode sends nothing', () async {
      final MemoryWebBrowserStore store = MemoryWebBrowserStore();
      int calls = 0;
      bool online = true;
      final WebBrowserSuggestionsController controller =
          WebBrowserSuggestionsController(
            store: store,
            provider: () => WebBrowserSearchEngine.bing,
            onlineEnabled: () => online,
            debounce: Duration.zero,
            fetcher: (Uri url) async {
              calls++;
              throw Exception('boom');
            },
          );
      await controller.update('x');
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(calls, 1);
      expect(controller.current, isEmpty);
      online = false;
      await controller.update('y');
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(calls, 1);
      await controller.update('');
      expect(controller.current, isEmpty);
      controller.dispose();
    });
  });
}
