import 'package:flutter_test/flutter_test.dart';

import 'package:fushi/src/web_browser/web_browser_sites.dart';

void main() {
  test('从没改过站点表 / 坏 JSON：空表，不预置任何站点', () {
    expect(parseWebBrowserSites(''), isEmpty);
    expect(parseWebBrowserSites('{bad'), isEmpty);
  });

  test('用户的表原样回读；删光就是空表', () {
    final WebBrowserSite site = WebBrowserSite(
      name: 'Ex',
      url: Uri.parse('https://example.com/'),
    );
    final List<WebBrowserSite> added = addWebBrowserSite(
      const <WebBrowserSite>[],
      site,
    );
    expect(parseWebBrowserSites(encodeWebBrowserSites(added)), <WebBrowserSite>[
      site,
    ]);
    expect(addWebBrowserSite(added, site), same(added), reason: '同 URL 不重复加');
    expect(
      parseWebBrowserSites(
        encodeWebBrowserSites(removeWebBrowserSite(added, site)),
      ),
      isEmpty,
    );
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

  test('5wWlKU_Rir：本机 / 局域网地址直接打开，不送去搜索', () {
    // 写了协议：任何非空主机都是网址（主机不带点也算）。
    for (final String input in <String>[
      'http://localhost:55000/texthooker',
      'http://nas:8080/',
      'https://intranet/wiki',
      'http://[::1]:8080/',
    ]) {
      expect(parseWebBrowserAddress(input)?.toString(), input, reason: input);
      expect(
        resolveWebBrowserInput(input, WebBrowserSearchEngine.bing)?.toString(),
        input,
        reason: input,
      );
    }
    // 没写协议：回环与 IP 字面量补 http，其余补 https。
    expect(
      parseWebBrowserAddress('localhost:55000/texthooker')?.toString(),
      'http://localhost:55000/texthooker',
    );
    expect(
      parseWebBrowserAddress('192.168.1.10:8096')?.toString(),
      'http://192.168.1.10:8096',
    );
    expect(
      parseWebBrowserAddress('[::1]:8080')?.toString(),
      'http://[::1]:8080',
    );
    expect(
      parseWebBrowserAddress('example.com/a')?.toString(),
      'https://example.com/a',
    );
    // 单个词、`协议:` 形状的非网址仍走搜索。
    expect(parseWebBrowserAddress('nas'), isNull);
    expect(parseWebBrowserAddress('foo:bar'), isNull);
    expect(parseWebBrowserAddress('http://'), isNull);
  });

  test('编辑站点：按旧 URL 原位替换；新 URL 撞上已有项时不产生重复', () {
    final WebBrowserSite a = WebBrowserSite(
      name: 'A',
      url: Uri.parse('https://a.example/'),
    );
    final WebBrowserSite b = WebBrowserSite(
      name: 'B',
      url: Uri.parse('https://b.example/'),
    );
    final WebBrowserSite c = WebBrowserSite(
      name: 'C',
      url: Uri.parse('https://c.example/'),
    );
    final WebBrowserSite edited = WebBrowserSite(
      name: 'Texthooker',
      url: Uri.parse('http://localhost:55000/texthooker'),
    );
    expect(
      replaceWebBrowserSite(<WebBrowserSite>[a, b, c], b, edited),
      <WebBrowserSite>[a, edited, c],
    );
    final WebBrowserSite toC = WebBrowserSite(name: 'B2', url: c.url);
    expect(
      replaceWebBrowserSite(<WebBrowserSite>[a, b, c], b, toC),
      <WebBrowserSite>[a, c],
    );
    // 编辑后的站点经偏好往返仍可读回（无点号主机不再在解析时被丢掉）。
    expect(
      parseWebBrowserSites(encodeWebBrowserSites(<WebBrowserSite>[edited])),
      <WebBrowserSite>[edited],
    );
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
