import 'dart:io' show Platform;

import 'package:fushi/src/models/store_compliance.dart';

/// 小说在线源（LNReader 插件）的运行时平台门：插件跑在 headless WebView 里。
///
/// Linux 走 vendored 的 WPE WebKit 后端（`packages/flutter_inappwebview_linux`，
/// 含 `HeadlessInAppWebView`）。WPE 是发行版运行时可选依赖：目标机没装、或不允许
/// 非特权 user namespace 时，宿主启动抛 `LinuxWebViewUnavailableException`（带
/// 「缺什么、装什么」），经浏览页的错误态展示给用户，而不是把整个入口藏掉——
/// 这个门是同步的，问不到运行时加载结果。
bool get isLnReaderRuntimeSupported =>
    Platform.isAndroid ||
    Platform.isWindows ||
    Platform.isMacOS ||
    Platform.isLinux;

/// 书的「导入」视图里的在线源三段（仓库 / 扩展 / 在线源）是否该出现：合规门
/// （iOS 不带在线源宿主）+ 运行时平台门（headless WebView 可用的平台）。两个都过
/// 才有。
///
/// 判据只写在这一处，消费端只问它——这条边界失效是静默的（本地与 CI 全绿、
/// 上架才被拒），守卫见 `test/build/ios_store_compliance_guard_test.dart`。
bool get isNovelOnlineSourcesAvailable =>
    StoreRestrictedCapability.onlineNovelSource.isAvailable &&
    isLnReaderRuntimeSupported;
