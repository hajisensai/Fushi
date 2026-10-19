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
}
