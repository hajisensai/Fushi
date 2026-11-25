// 反馈 wegu0vewts：浏览器下拉刷新太容易误触，加开关。
// · 偏好默认开（与此前行为一致），可关，且是设备本地键（不进备份 / 同步）；
// · 标签页的控制器按偏好建出 `enabled`，偏好变化时即时同步到已建的控制器
//   （[WebBrowserPullToRefreshBinding]，用假平台控制器直接驱动行为）。
// 设置页开关项的可见性与读写见 test/pages/web_browser_settings_page_test.dart。
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_engine/foundation/pref_store.dart';

import 'package:fushi/src/web_browser/tab_view/web_browser_pull_to_refresh.dart';
import 'package:fushi/src/web_browser/web_browser_prefs.dart';

class _MemPrefs implements PrefStore {
  final Map<String, Object?> values = <String, Object?>{};

  @override
  dynamic getPref(String key, {dynamic defaultValue}) =>
      values.containsKey(key) ? values[key] : defaultValue;

  @override
  Future<void> setPref(String key, dynamic value) async => values[key] = value;
}

/// 记录原生调用的假平台控制器（真实现走 MethodChannel 改 SwipeRefreshLayout）。
class _FakePullToRefreshPlatform extends PlatformPullToRefreshController {
  _FakePullToRefreshPlatform(super.params) : super.implementation();

  final List<String> calls = <String>[];

  @override
  Future<void> setEnabled(bool enabled) async =>
      calls.add('setEnabled($enabled)');

  @override
  Future<void> endRefreshing() async => calls.add('endRefreshing');
}

({WebBrowserPullToRefreshBinding binding, _FakePullToRefreshPlatform platform})
_bind(_MemPrefs prefs) {
  late _FakePullToRefreshPlatform platform;
  final WebBrowserPullToRefreshBinding binding = WebBrowserPullToRefreshBinding(
    prefs: prefs,
    createController: (PullToRefreshSettings settings) {
      platform = _FakePullToRefreshPlatform(
        PlatformPullToRefreshControllerCreationParams(settings: settings),
      );
      return PullToRefreshController.fromPlatform(platform: platform);
    },
  );
  return (binding: binding, platform: platform);
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

  test('标签页控制器按当前偏好建出：关着时以 enabled: false 挂上', () async {
    final _MemPrefs prefs = _MemPrefs();
    await setWebBrowserPullToRefresh(prefs, false);
    final (:binding, :platform) = _bind(prefs);
    expect(binding.enabled, isFalse);
    expect(binding.controller.settings.enabled, isFalse);
    expect(platform.calls, isEmpty);
  });

  test('偏好变化即时同步到已建的控制器：关掉收起指示器，再开恢复', () async {
    final _MemPrefs prefs = _MemPrefs();
    final (:binding, :platform) = _bind(prefs);
    expect(binding.controller.settings.enabled, isTrue);

    // 偏好没变（别的偏好触发的通知）不碰原生控件。
    binding.sync();
    expect(platform.calls, isEmpty);

    await setWebBrowserPullToRefresh(prefs, false);
    binding.sync();
    expect(binding.enabled, isFalse);
    expect(binding.controller.settings.enabled, isFalse);
    expect(platform.calls, <String>['endRefreshing', 'setEnabled(false)']);

    platform.calls.clear();
    await setWebBrowserPullToRefresh(prefs, true);
    binding.sync();
    expect(binding.enabled, isTrue);
    expect(binding.controller.settings.enabled, isTrue);
    expect(platform.calls, <String>['setEnabled(true)']);
  });
}
