## BUG-2459 · iOS AnkiMobile 回跳被引擎 deep linking 压出第二个 HomePage
- **报告**：2026-09-11（用户：「ios端刷新牌组和笔记类型 anki同意后跳回fushi后，fushi跳回主页然后也没成功」）
- **真实性**：✅ 真 bug。**不是**剪贴板链路（BUG-2150 那条），而是同一个 URL 被两条路各处理了一遍：
  1. 我们自己的路：`fushi/ios/Runner/SceneDelegate.swift:16` `scene(_:openURLContexts:)` → `AppDelegate.deliverUrl`
     → EventChannel `app.fushi.reader/url_events` → `fushi/lib/main.dart` `handleIncomingUrl` → `_handleAnkiMobileInfoCallback`。这条是对的。
  2. **引擎自带的路**：`SceneDelegate` 随后 `super.scene(scene, openURLContexts:)` → Flutter 引擎
     `FlutterPluginSceneLifeCycleDelegate.scene:openURLContexts:`（3.44.0 `FlutterSceneLifeCycle.mm:289`）：没有任何插件消费这条 URL，
     且 `FlutterSharedApplication.isFlutterDeepLinkingEnabled`（`FlutterSharedApplication.mm:60`：Info.plist 缺 `FlutterDeepLinkingEnabled` 时**缺省 YES**，
     Flutter ≥ 3.27 行为）→ `sendDeepLinkToFramework:` → `flutter/navigation` `pushRouteInformation`
     → 框架 `WidgetsApp.didPushRouteInformation`（`packages/flutter/lib/src/widgets/app.dart:1636`）对无 Router 的
     `MaterialApp(home:, navigatorKey:)` 直接 `navigator.pushNamed(uri.path.isEmpty ? '/' : uri.path)`。
     `fushi://ankiFetch` 的 path 为空 → `pushNamed('/')` → `home`（`HomePage`）**在制卡设置页上面又压了一份**。
  用户看到的「跳回主页」就是这份多出来的 HomePage；设置页连同它正在等的结果一起埋在栈底。剪贴板那条并行跑完了也没人看得到，
  且第二个 HomePage 的整套 init（词典预热、焦点接管、生命周期观察者）与栈底那份并存。`fushi/ios/Runner/Info.plist` 此前没有 `FlutterDeepLinkingEnabled`。
  `fushi://ankiSuccess`（制卡回跳）与 `fushi://auth/<provider>`（OAuth 回跳）走同一条错路：前者同样复制 home，后者 path 非空会撞 `onUnknownRoute`。
- **[x] ① 已修复** — 两层，互为双保险：
  - **Apple 侧官方关法**：`fushi/ios/Runner/Info.plist` 加 `FlutterDeepLinkingEnabled=false`（引擎源码注释原话：「Developers may disable deep linking through their Info.plist if they are using a plugin that handles deeplinking instead」——我们正是自己处理 `fushi://`）。
  - **框架侧不变式（平台无关）**：新增 `fushi/lib/src/platform/engine_deep_link_route_guard.dart`（`swallowEngineDeepLinkRoute` + `EngineDeepLinkRouteGuard`），
    `_FushiReaderAppState` 覆写 `didPushRouteInformation` 答 `true`。根 observer 在 `initState` 里 `addObserver` 早于子树 build，
    `WidgetsBinding._handlePushRouteInformation` 按注册顺序问、第一个答 true 即终止，`WidgetsApp` 永远看不到这条推送。
    本 app 没有任何命名路由表（无 `routes` / `onGenerateRoute`），引擎推来的任何 route information 都没有合法落点，所以不按 scheme 分流、整层截断；Android 引擎 `onNewIntent` 同样会推送，这层一并盖住。
    URL 的真正处理仍由各平台通道送进 `handleIncomingUrl`，零改动。
- **[x] ② 已加自动化测试** — `fushi/test/platform/engine_deep_link_route_guard_test.dart`（6 条）：
  - **复现**：走**真实的** `flutter/navigation` 平台消息（`defaultBinaryMessenger.handlePlatformMessage` 送 `pushRouteInformation{location:'fushi://ankiFetch'}`），
    不挂守卫时 `MaterialApp(home:)` 上 `_Home` 变成 2 份、`_Settings` 被压到 offstage——框架自己把这条链演了一遍。
  - **修复**：与 main.dart 同序（observer 先于 WidgetsApp 注册）挂 `EngineDeepLinkRouteGuard`，同一条消息后栈纹丝不动。
  - 四种回跳 URL（ankiFetch / ankiSuccess / auth / lookup）都被截断；源码守卫钉住 Info.plist 的 `FlutterDeepLinkingEnabled=false` 与
    `_FushiReaderAppState` 的「`initState` → `addObserver(this)` → `build`」顺序（注册顺序是这层不变式的前提）。
  - **变异实测**：把 `swallowEngineDeepLinkRoute` 改成 `return false` → 修复用例红（`Found 0 widgets with type "_Settings"`）+ 四 URL 用例红；还原后 11/11 绿（含相邻 `ankimobile_ios_callback_static_test.dart`）。
- **备注**：
  - 与 BUG-2150 的关系：那次修的是「回到前台前读剪贴板必空」（时序）与三态文案；本次修的是 URL 被引擎再推一次导航。两次都在同一条回跳链上，症状不同（那次是错误文案，这次是页面被换掉）。
  - **真机缺口**：本机没有能跑 AnkiMobile 的 iOS 设备（付费 app、装不进模拟器），「回到原始失败路径复测」没做。已做到的最强验证是让框架真跑一遍
    `pushRouteInformation` 复现/修复（不是 mock），以及引擎源码（3.44.0 `FlutterSceneLifeCycle.mm` / `FlutterSharedApplication.mm`）逐行核对默认值与调用链。
    若真机复测后设置页留在栈顶但刷新仍报错，那就是 BUG-2150 三态里的某一条，错误行会直接写明是哪一条。
  - Android 主 Activity 的 `fushi://auth/<provider>` 有同款隐患（manifest 也没写 `flutter_deeplinking_enabled=false`），本次由 Dart 守卫盖住；弹窗词典 Activity（独立引擎、`fushi://lookup`）不在本次范围。
