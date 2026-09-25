import 'dart:io' show Platform;

import 'package:fushi/src/models/store_compliance.dart';

/// 小说在线源（LNReader 插件）的运行时平台门：插件跑在 headless WebView 里，
/// flutter_inappwebview 在 Linux 上没有实现。
bool get isLnReaderRuntimeSupported =>
    Platform.isAndroid || Platform.isWindows || Platform.isMacOS;

/// 书的「导入」视图里的在线源三段（仓库 / 扩展 / 在线源）是否该出现：合规门
/// （iOS 不带在线源宿主）+ 运行时平台门（Linux 没有 headless WebView）。两个都过
/// 才有。
///
/// 判据只写在这一处，消费端只问它——这条边界失效是静默的（本地与 CI 全绿、
/// 上架才被拒），守卫见 `test/build/ios_store_compliance_guard_test.dart`。
bool get isNovelOnlineSourcesAvailable =>
    StoreRestrictedCapability.onlineNovelSource.isAvailable &&
    isLnReaderRuntimeSupported;
