import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_engine/foundation/pref_store.dart';

import 'package:fushi/src/web_browser/data/web_browser_site_settings.dart';

class _MapPrefStore implements PrefStore {
  final Map<String, dynamic> values = <String, dynamic>{};

  @override
  dynamic getPref(String key, {dynamic defaultValue}) =>
      values[key] ?? defaultValue;

  @override
  Future<void> setPref(String key, dynamic value) async => values[key] = value;
}

void main() {
  test('webBrowserOriginOf normalizes scheme, host and default ports', () {
    expect(
      webBrowserOriginOf(Uri.parse('https://Example.com:443/a?b')),
      'https://example.com',
    );
    expect(
      webBrowserOriginOf(Uri.parse('http://localhost:8080/x')),
      'http://localhost:8080',
    );
    expect(webBrowserOriginOf(Uri.parse('about:blank')), isNull);
  });

  test('decisions default to ask and persist across instances', () async {
    final _MapPrefStore prefs = _MapPrefStore();
    final WebBrowserSiteSettings settings = WebBrowserSiteSettings(prefs);
    expect(
      settings.decision('https://a.com', WebBrowserSitePermission.camera),
      WebBrowserPermissionDecision.ask,
    );
    await settings.setDecision(
      'https://a.com/page',
      WebBrowserSitePermission.camera,
      WebBrowserPermissionDecision.allow,
    );
    await settings.setDecision(
      'https://b.com',
      WebBrowserSitePermission.popups,
      WebBrowserPermissionDecision.block,
    );
    final WebBrowserSiteSettings reloaded = WebBrowserSiteSettings(prefs);
    expect(
      reloaded.decision('https://a.com', WebBrowserSitePermission.camera),
      WebBrowserPermissionDecision.allow,
    );
    expect(reloaded.all().keys, <String>['https://a.com', 'https://b.com']);
    expect(
      reloaded.all()['https://b.com'],
      <WebBrowserSitePermission, WebBrowserPermissionDecision>{
        WebBrowserSitePermission.popups: WebBrowserPermissionDecision.block,
      },
    );
  });

  test('setting ask forgets, clearSite and clearAll remove', () async {
    final _MapPrefStore prefs = _MapPrefStore();
    final WebBrowserSiteSettings settings = WebBrowserSiteSettings(prefs);
    await settings.setDecision(
      'https://a.com',
      WebBrowserSitePermission.microphone,
      WebBrowserPermissionDecision.block,
    );
    await settings.setDecision(
      'https://a.com',
      WebBrowserSitePermission.microphone,
      WebBrowserPermissionDecision.ask,
    );
    expect(settings.all(), isEmpty);

    await settings.setDecision(
      'https://a.com',
      WebBrowserSitePermission.geolocation,
      WebBrowserPermissionDecision.allow,
    );
    await settings.setDecision(
      'https://b.com',
      WebBrowserSitePermission.notifications,
      WebBrowserPermissionDecision.allow,
    );
    await settings.clearSite('https://a.com');
    expect(settings.all().keys, <String>['https://b.com']);
    await settings.clearAll();
    expect(WebBrowserSiteSettings(prefs).all(), isEmpty);
  });

  test('bad json and unknown names are dropped', () {
    expect(decodeWebBrowserSitePermissions('{not json'), isEmpty);
    expect(
      decodeWebBrowserSitePermissions(
        '{"https://a.com":{"camera":"allow","laser":"allow","clipboard":"maybe"}}',
      ),
      <String, Map<WebBrowserSitePermission, WebBrowserPermissionDecision>>{
        'https://a.com':
            <WebBrowserSitePermission, WebBrowserPermissionDecision>{
              WebBrowserSitePermission.camera:
                  WebBrowserPermissionDecision.allow,
            },
      },
    );
  });
}
