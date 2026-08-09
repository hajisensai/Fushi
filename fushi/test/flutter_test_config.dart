import 'dart:async';

import 'package:shared_preferences/shared_preferences.dart';

import 'helpers/fake_inappwebview_platform.dart';

/// Suite-wide setup for all tests under `test/`.
///
/// 1. Registers a no-op [InAppWebViewPlatform] (BUG-093) so any widget tree that
///    mounts an `InAppWebView` can build under the unit-test harness, which has
///    no real platform view. The persistent warm dictionary popup slot now mounts
///    its WebView as soon as any `BaseSourcePageState` page builds, so every
///    widget test that pumps a reader / video / audiobook surface needs this. The
///    fake is inert (renders an empty box, fires no callbacks) and only takes
///    effect when an `InAppWebView` actually builds, so tests that don't use one
///    are unaffected.
/// 2. Installs an in-memory `SharedPreferences` store suite-wide (BUG-1400). See
///    [installInMemorySharedPreferences].
Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  installFakeInAppWebViewPlatform();
  installInMemorySharedPreferences();
  await testMain();
}

/// BUG-1400：把 `SharedPreferences` 的**平台实现**在整个 `test/` 套件里换成进程内存储。
///
/// 为什么这必须是套件级默认，而不是「受影响的测试各自补 `setUp`」：
///
/// `AppPaths` 的路径解析（`lib/src/storage/app_paths.dart` 的 `_configuredDataRootPath` /
/// `_prefsOrNull`）每次都要 await `SharedPreferences.getInstance()`，而 `AppPaths` 是运行时
/// 静态便捷层——封面抽取、字幕落点、缩略图、着色器列举等**页面级 fire-and-forget 链**全从它
/// 派生，因此任何 pump 起真实页面的 widget 测试都可能在 `pump()` 的 **fake async 相位**里
/// 发起它。没装 mock 时这次调用穿到**真实平台通道**，应答只能由真实事件循环投递，fake async
/// 相位收不到 ⇒ 该 future 永久挂起；而 `SharedPreferences` 把首次调用的 `Completer` 存在
/// **进程级静态字段**里，于是这**一次**调用就把本 isolate 后续所有 `AppPaths` 解析（包括
/// `runAsync` 里的）全部 join 到同一条死 future 上。症状是挂死 / `pumpAndSettle` 超时 /
/// 「A Timer is still pending」/ 资产回收断言计数偏少，且**跨用例传染**。
///
/// 触发面 = 「所有会 pump 真实页面的 widget 测试」，是一个**开放集合**：新页面测试天然继承
/// 这条陷阱，而它**默认沉默**（fire-and-forget 链挂住通常不报错，只在某个用例恰好 await 到
/// 派生路径时才炸），所以逐文件补 `setUp` 只能追认已经踩过的坑，永远慢一个文件。把默认值改
/// 成「进程内 prefs」直接让这个特殊情况不存在。
///
/// 行为等价性：[SharedPreferences.setMockInitialValues] 走的是
/// `SharedPreferencesStorePlatform.instance = InMemorySharedPreferencesStore`，**不经任何
/// 平台通道**，并顺手把静态 `_completer` 复位。对 `AppPaths` 而言，空存储读出的
/// `getString(...) == null` 与原先「通道不可用 → catch → null」逐字节同结论（默认根 / 扁平
/// 布局判定都不变）。仓库里也没有任何测试依赖「prefs 通道不可用」这一事实。
///
/// 只在这里装**一次**（刻意不是每个用例的 `setUp`）：这样它严格早于任何 `setUpAll` /
/// `setUp` / 用例体，绝不会覆盖测试自己播下的种子值。需要按用例隔离 prefs 的文件继续在自己
/// 的 `setUp` 里调 [SharedPreferences.setMockInitialValues]（那会晚于本次安装，正常生效）。
///
/// 守卫：`test/storage/app_paths_fakeasync_prefs_channel_test.dart`（行为断言 + 对本文件的
/// 正向源码规则）。
void installInMemorySharedPreferences() {
  SharedPreferences.setMockInitialValues(<String, Object>{});
}
