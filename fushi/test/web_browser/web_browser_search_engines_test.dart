import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_engine/foundation/pref_store.dart';

import 'package:fushi/src/web_browser/web_browser_sites.dart';

class _MapPrefStore implements PrefStore {
  final Map<String, dynamic> values = <String, dynamic>{};

  @override
  dynamic getPref(String key, {dynamic defaultValue}) =>
      values[key] ?? defaultValue;

  @override
  Future<void> setPref(String key, dynamic value) async => values[key] = value;
}

void main() {
  const WebBrowserCustomSearchEngine wiki = WebBrowserCustomSearchEngine(
    id: 'w1',
    name: 'Wikipedia',
    searchTemplate: 'https://ja.wikipedia.org/w/index.php?search=%s',
    suggestTemplate:
        'https://ja.wikipedia.org/w/api.php?action=opensearch&search=%s',
  );

  test('template validation', () {
    expect(isValidWebBrowserSearchTemplate('https://x.com/?q=%s'), isTrue);
    expect(isValidWebBrowserSearchTemplate('https://x.com/?q='), isFalse);
    expect(isValidWebBrowserSearchTemplate('ftp://x.com/%s'), isFalse);
    expect(isValidWebBrowserSearchTemplate('%s'), isFalse);
  });

  test('custom engine fills %s with an encoded query', () {
    expect(
      wiki.searchUrl(' 日本 語&x ').toString(),
      'https://ja.wikipedia.org/w/index.php?search=%E6%97%A5%E6%9C%AC+%E8%AA%9E%26x',
    );
    expect(wiki.suggestUrl('a')?.queryParameters['search'], 'a');
    expect(
      const WebBrowserCustomSearchEngine(
        id: 'n',
        name: 'n',
        searchTemplate: 'https://n.com/?q=%s',
      ).suggestUrl('a'),
      isNull,
    );
  });

  test('builtin suggest urls', () {
    expect(
      WebBrowserSearchEngine.google.suggestUrl('one piece').toString(),
      'https://suggestqueries.google.com/complete/search?client=firefox&q=one+piece',
    );
    expect(WebBrowserSearchEngine.bing.suggestUrl('x')?.host, 'api.bing.com');
    expect(WebBrowserSearchEngine.duckDuckGo.suggestUrl('x')?.path, '/ac/');
  });

  test('legacy pref values still resolve', () async {
    final _MapPrefStore prefs = _MapPrefStore();
    expect(readWebBrowserSearchProvider(prefs), WebBrowserSearchEngine.google);
    prefs.values[kWebBrowserSearchEnginePref] = 'bing';
    expect(readWebBrowserSearchProvider(prefs), WebBrowserSearchEngine.bing);
    expect(readWebBrowserSearchEngine(prefs), WebBrowserSearchEngine.bing);
    await writeWebBrowserSearchEngine(prefs, WebBrowserSearchEngine.duckDuckGo);
    expect(prefs.values[kWebBrowserSearchEnginePref], 'duckDuckGo');
  });

  test('custom engines persist, select, edit, and remove', () async {
    final _MapPrefStore prefs = _MapPrefStore();
    await upsertWebBrowserCustomSearchEngine(prefs, wiki);
    expect(
      readWebBrowserCustomSearchEngines(prefs),
      <WebBrowserCustomSearchEngine>[wiki],
    );
    expect(webBrowserSearchProviders(prefs), hasLength(4));

    await writeWebBrowserSearchProvider(prefs, wiki);
    expect(prefs.values[kWebBrowserSearchEnginePref], 'custom:w1');
    expect(readWebBrowserSearchProvider(prefs), wiki);
    // 旧接口读到自定义值时回落 Google，不抛。
    expect(readWebBrowserSearchEngine(prefs), WebBrowserSearchEngine.google);

    const WebBrowserCustomSearchEngine renamed = WebBrowserCustomSearchEngine(
      id: 'w1',
      name: 'Wiki',
      searchTemplate: 'https://ja.wikipedia.org/w/index.php?search=%s',
    );
    await upsertWebBrowserCustomSearchEngine(prefs, renamed);
    expect(readWebBrowserSearchProvider(prefs).label, 'Wiki');

    expect(
      resolveWebBrowserInput('猫', readWebBrowserSearchProvider(prefs))?.host,
      'ja.wikipedia.org',
    );

    await removeWebBrowserCustomSearchEngine(prefs, 'w1');
    expect(readWebBrowserCustomSearchEngines(prefs), isEmpty);
    expect(readWebBrowserSearchProvider(prefs), WebBrowserSearchEngine.google);
  });

  test('bad stored entries are dropped, duplicates collapse', () {
    expect(parseWebBrowserCustomSearchEngines('oops'), isEmpty);
    expect(
      parseWebBrowserCustomSearchEngines(
        '[{"id":"a","name":"A","search":"https://a.com/?q=%s"},'
        '{"id":"a","name":"A2","search":"https://a.com/?q=%s"},'
        '{"id":"b","name":"B","search":"https://b.com/"}]',
      ).map((WebBrowserCustomSearchEngine e) => e.name),
      <String>['A'],
    );
  });

  test('new ids avoid collisions', () {
    final DateTime now = DateTime.fromMillisecondsSinceEpoch(1000);
    final String first = newWebBrowserCustomSearchEngineId(
      const <WebBrowserCustomSearchEngine>[],
      now: now,
    );
    final String second =
        newWebBrowserCustomSearchEngineId(<WebBrowserCustomSearchEngine>[
          WebBrowserCustomSearchEngine(
            id: first,
            name: 'x',
            searchTemplate: 'https://x.com/%s',
          ),
        ], now: now);
    expect(second, isNot(first));
  });
}
