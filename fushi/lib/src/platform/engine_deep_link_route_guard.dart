import 'package:flutter/widgets.dart';

/// BUG-2459：把引擎自带的 deep-link 路由推送在根部截断。
///
/// Flutter ≥ 3.27 默认开启引擎 deep linking：iOS 引擎在
/// `scene:openURLContexts:` / `scene:willConnectToSession:` 里，把没被任何
/// 插件消费的 URL 经 `flutter/navigation` 的 `pushRouteInformation` 转给框架；
/// 框架侧 `WidgetsApp.didPushRouteInformation` 对**没有 Router** 的
/// `MaterialApp(home:, navigatorKey:)` 直接 `navigator.pushNamed(path)`——
/// `fushi://ankiFetch` 的 path 为空被补成 `'/'`，于是在当前页面**上面再压一个
/// 全新的 [home]**。用户在制卡设置页点「刷新牌组」→ AnkiMobile 同意 → 回跳，
/// 看到的就是「Fushi 跳回主页」；设置页连同它正在等的结果一起被埋在栈底。
///
/// Fushi 的每一条 `fushi://` URL（AnkiMobile x-callback、OAuth 回跳、查词深链）
/// 都由自己的平台通道（iOS `app.fushi.reader/url_events`、Android
/// `receive_intent`、Windows WM_COPYDATA）送到 `handleIncomingUrl` 处理，
/// **从来不是导航路由名**；这个 app 也没有任何命名路由表（无 `routes` /
/// `onGenerateRoute`），所以引擎推来的任何 route information 都没有合法落点：
/// 空 path 会复制一份 home，非空 path 会撞 `onUnknownRoute`。
///
/// 截断方式：根 widget 的 [WidgetsBindingObserver] 在 `WidgetsApp` 之前注册
/// （`initState` 里 `addObserver` 早于子树 build），`WidgetsBinding` 按注册顺序
/// 逐个问 [WidgetsBindingObserver.didPushRouteInformation]，第一个答 `true`
/// 的就终止分发——根观察者在这里答 `true`，`WidgetsApp` 永远看不到这条推送。
/// 这一层与 iOS `Info.plist` 的 `FlutterDeepLinkingEnabled=false` 互为
/// 双保险：前者是与平台无关的框架侧不变式（Android 引擎同样会在 `onNewIntent`
/// 里推送），后者是 Apple 侧的官方关法。
///
/// 若将来 app 引入命名路由并希望引擎深链真的走 Navigator，这里必须改成按
/// scheme 分流，而不是删掉整层。
bool swallowEngineDeepLinkRoute(RouteInformation routeInformation) {
  // 有意不看 scheme：见上——本 app 没有任何命名路由，`pushNamed` 没有合法目标。
  return true;
}

/// [swallowEngineDeepLinkRoute] 的独立观察者形态，供根 widget 之外的宿主
/// （测试、弹窗词典等第二 entry point）复用同一条不变式。
class EngineDeepLinkRouteGuard with WidgetsBindingObserver {
  @override
  Future<bool> didPushRouteInformation(
    RouteInformation routeInformation,
  ) async {
    return swallowEngineDeepLinkRoute(routeInformation);
  }
}
