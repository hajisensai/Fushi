// 反馈 wegu0vewts：浏览器下拉刷新太容易误触，加开关。
// · 偏好默认开（与此前行为一致），可关，且是设备本地键（不进备份 / 同步）；
// · 设置页有对应开关项，只在手机显示；
// · 标签页 WebView 按偏好挂控制器的 enabled，并在偏好变化时即时同步（源码接线守卫：
//   widget 测试没有平台视图，PullToRefreshController 只在真 WebView 分支里建）。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_engine/foundation/pref_store.dart';

import 'package:fushi/src/web_browser/web_browser_prefs.dart';

class _MemPrefs implements PrefStore {
  final Map<String, Object?> values = <String, Object?>{};

  @override
  dynamic getPref(String key, {dynamic defaultValue}) =>
      values.containsKey(key) ? values[key] : defaultValue;

  @override
  Future<void> setPref(String key, dynamic value) async => values[key] = value;
}

void main() {
  test('下拉刷新偏好：默认开，可关可再开', () async {
    final _MemPrefs prefs = _MemPrefs();
    expect(kWebBrowserPullToRefreshDefault, isTrue);
    expect(webBrowserPullToRefresh(prefs), isTrue);
    await setWebBrowserPullToRefresh(prefs, false);
    expect(prefs.values[kWebBrowserPullToRefreshPref], isFalse);
    expect(webBrowserPullToRefresh(prefs), isFalse);
    await setWebBrowserPullToRefresh(prefs, true);
    expect(webBrowserPullToRefresh(prefs), isTrue);
  });

  test('下拉刷新偏好是设备本地键', () {
    expect(
      kWebBrowserDeviceLocalPrefKeys,
      contains(kWebBrowserPullToRefreshPref),
    );
  });

  test('设置页有「下拉刷新」开关，只在手机显示', () {
    final String source = File(
      'lib/src/settings/settings_schema_web_browser.dart',
    ).readAsStringSync();
    final int at = source.indexOf("'system.web_browser_pull_to_refresh'");
    expect(at, greaterThan(0));
    final String item = source.substring(at, source.indexOf('),', at));
    expect(item, contains('visible: (_) => isMobilePlatform'));
    expect(item, contains('webBrowserPullToRefresh('));
  });

  test('标签页按偏好挂下拉刷新，偏好变化即时同步到已建的控制器', () {
    final String source = File(
      'lib/src/web_browser/tab_view/web_browser_tab_view.dart',
    ).readAsStringSync();
    expect(
      source,
      contains(
        'settings: PullToRefreshSettings(enabled: _appliedPullToRefresh)',
      ),
    );
    final int prefsChanged = source.indexOf('void _onPrefsChanged() {');
    expect(prefsChanged, greaterThan(0));
    expect(
      source.substring(prefsChanged, source.indexOf('}', prefsChanged)),
      contains('_syncPullToRefresh();'),
    );
    final int sync = source.indexOf('void _syncPullToRefresh() {');
    expect(sync, greaterThan(0));
    final String body = source.substring(sync, source.indexOf('\n  }\n', sync));
    expect(body, contains('webBrowserPullToRefresh(_prefs)'));
    expect(body, contains('controller.settings.enabled = enabled'));
    expect(body, contains('controller.setEnabled(enabled)'));
  });
}
