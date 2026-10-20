import 'package:flutter_test/flutter_test.dart';

import 'package:fushi/src/web_browser/web_browser_sites.dart';

void main() {
  test('从没改过站点表：漫画能力可用才预置漫画站（iOS 合规：空表）', () {
    expect(
      parseWebBrowserSites(
        '',
        presets: webBrowserPresetSites(mangaAvailable: true),
      ).map((WebBrowserSite s) => s.url.host),
      contains('mangadex.org'),
    );
    expect(
      parseWebBrowserSites(
        '',
        presets: webBrowserPresetSites(mangaAvailable: false),
      ),
      isEmpty,
    );
  });

  test('用户的表原样回读；删光就是空表，不补回预置', () {
    final List<WebBrowserSite> presets = webBrowserPresetSites(
      mangaAvailable: true,
    );
    final WebBrowserSite site = WebBrowserSite(
      name: 'Ex',
      url: Uri.parse('https://example.com/'),
    );
    final List<WebBrowserSite> added = addWebBrowserSite(
      const <WebBrowserSite>[],
      site,
    );
    expect(
      parseWebBrowserSites(encodeWebBrowserSites(added), presets: presets),
      <WebBrowserSite>[site],
    );
    expect(addWebBrowserSite(added, site), same(added), reason: '同 URL 不重复加');
    expect(
      parseWebBrowserSites(
        encodeWebBrowserSites(removeWebBrowserSite(added, site)),
        presets: presets,
      ),
      isEmpty,
    );
    expect(parseWebBrowserSites('{bad', presets: presets), presets);
  });

  test('地址栏输入：补 https、拒绝非 http(s) 与不像网址的输入', () {
    expect(
      parseWebBrowserAddress('mangadex.org')?.toString(),
      'https://mangadex.org',
    );
    expect(
      parseWebBrowserAddress(' http://a.example/x?y=1 ')?.toString(),
      'http://a.example/x?y=1',
    );
    expect(parseWebBrowserAddress('javascript:alert(1)'), isNull);
    expect(parseWebBrowserAddress('file:///etc/passwd'), isNull);
    expect(parseWebBrowserAddress('hello world'), isNull);
    expect(parseWebBrowserAddress('localhost'), isNull);
    expect(parseWebBrowserAddress(''), isNull);
  });

  group('resolveWebBrowserInput', () {
    test('像网址的输入直接打开，不经搜索引擎', () {
      for (final WebBrowserSearchEngine engine
          in WebBrowserSearchEngine.values) {
        expect(
          resolveWebBrowserInput('mangadex.org', engine)?.toString(),
          'https://mangadex.org',
        );
        expect(
          resolveWebBrowserInput(
            ' http://a.example/x?y=1 ',
            engine,
          )?.toString(),
          'http://a.example/x?y=1',
        );
      }
    });

    test('空输入返回 null', () {
      expect(resolveWebBrowserInput('', WebBrowserSearchEngine.google), isNull);
      expect(
        resolveWebBrowserInput('   ', WebBrowserSearchEngine.google),
        isNull,
      );
    });

    test('不像网址的输入交给所选引擎搜索（q 参数，去首尾空白）', () {
      final Uri? google = resolveWebBrowserInput(
        '  進撃の巨人 1話 ',
        WebBrowserSearchEngine.google,
      );
      expect(google?.scheme, 'https');
      expect(google?.host, 'www.google.com');
      expect(google?.path, '/search');
      expect(google?.queryParameters, <String, String>{'q': '進撃の巨人 1話'});

      final Uri? bing = resolveWebBrowserInput(
        'hello world',
        WebBrowserSearchEngine.bing,
      );
      expect(bing?.host, 'www.bing.com');
      expect(bing?.path, '/search');
      expect(bing?.queryParameters['q'], 'hello world');

      final Uri? ddg = resolveWebBrowserInput(
        'localhost',
        WebBrowserSearchEngine.duckDuckGo,
      );
      expect(ddg?.host, 'duckduckgo.com');
      expect(ddg?.queryParameters['q'], 'localhost');
    });

    test('非 http(s) 协议不会被当成地址打开，只会被搜索', () {
      for (final String input in <String>[
        'javascript:alert(1)',
        'file:///etc/passwd',
      ]) {
        final Uri? uri = resolveWebBrowserInput(
          input,
          WebBrowserSearchEngine.google,
        );
        expect(uri?.scheme, 'https', reason: input);
        expect(uri?.host, 'www.google.com', reason: input);
        expect(uri?.queryParameters['q'], input, reason: input);
      }
    });

    test('引擎持久化值：未知 / 缺省回落 Google', () {
      expect(
        WebBrowserSearchEngine.fromName('bing'),
        WebBrowserSearchEngine.bing,
      );
      expect(
        WebBrowserSearchEngine.fromName('duckDuckGo'),
        WebBrowserSearchEngine.duckDuckGo,
      );
      expect(
        WebBrowserSearchEngine.fromName(null),
        WebBrowserSearchEngine.google,
      );
      expect(
        WebBrowserSearchEngine.fromName('yahoo'),
        WebBrowserSearchEngine.google,
      );
    });
  });
}
