import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 源码守卫（TODO-855）：手机外查词 warm-reuse 弹窗每次查词性能回退。
///
/// 根因——`lib/popup_main.dart` 的 `onNewProcessText` 回调在 warm-reuse 路径上对
/// 每个新选词**无条件** `await appModel.refreshPrefCache()`。`refreshPrefCache`
/// 单次开销 = 3 次 `preferences` 全表扫描 + 3 次 notifyListeners + 快捷键 JSON
/// 解析，preferences 越大越慢；而 v0.4.1 的同路径是纯 setState、零 DB。
///
/// 修复——改成只在 profile / 偏好真正变化时刷新：弹窗回调走
/// `appModel.refreshPrefCacheIfChanged()`，它先做一次廉价的单行 `prefs_version`
/// DB 读，仅当版本变化才跑全量 `refreshPrefCache`。:popup 是独立进程、缓存跨查词
/// 存活，故这是它感知主 app profile/pref 变化的唯一通道——不能裸删，要条件化。
///
/// 这条 warm-reuse 路径无法在 host 单测里真实驱动（要起 :popup 进程 + 平台通道），
/// 故用源码扫描守卫钉住「弹窗回调不得无条件 await refreshPrefCache()」不被回退。
/// 配套行为测试见 test/models/preferences_repository_test.dart（prefsVersion 单调 +
/// 跨进程可读）与 test/profile/profile_repository_test.dart（profile 切换 bump 版本）。
void main() {
  test(
      'popup_main onNewProcessText must NOT unconditionally refreshPrefCache '
      'on every external lookup (TODO-855 warm-reuse perf regression)', () {
    final String src = File('lib/popup_main.dart').readAsStringSync();

    // The unconditional full reload on the warm-reuse hot path is the
    // regression. The popup must gate it behind the cheap version check.
    expect(
      src.contains('await appModel.refreshPrefCache()'),
      isFalse,
      reason: 'TODO-855 回归：popup_main 又在每次查词无条件 await '
          'refreshPrefCache() —— 该路径必须走 refreshPrefCacheIfChanged() 先做廉价 '
          'prefs_version 检查，仅在 profile/偏好真正变化时才全量刷新。',
    );

    // The conditional path must be present (it is the fix; deleting it would
    // make warm-reuse popups blind to profile/pref changes).
    expect(
      src.contains('refreshPrefCacheIfChanged()'),
      isTrue,
      reason: 'popup_main 必须调用 refreshPrefCacheIfChanged() —— 否则 warm-reuse '
          '弹窗看不到主 app 的 profile 切换 / 偏好变化（功能回归）。',
    );
  });
}
