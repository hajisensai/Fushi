import 'dart:async';

import 'package:fushi/src/lookup/browser_extension_installer.dart';
import 'package:fushi/src/models/app_model.dart';

/// 浏览器扩展安装助手的业务步骤（准备扩展目录 / 连接检测），从
/// `BrowserExtensionPage` 搬出来，页面与控制通道
/// （`fushi_cli config run lookup.browser_extension.cli.*`）共用同一份实现。

/// 判定「插件近期连上过」的时间窗：扩展 SW 启动/查词/心跳时打本机 server 刷新
/// last-seen。BUG-1045：扩展用 chrome.alarms 每 60s 心跳保活，窗口取 150s
/// （> 一个心跳周期 + 抖动余量），单次心跳丢包不会误判「未连接」。
const Duration kBrowserExtensionSeenWindow = Duration(seconds: 150);

/// [lastSeen] 是否落在 [kBrowserExtensionSeenWindow] 内。
bool isBrowserExtensionRecentlySeen(DateTime? lastSeen, {DateTime? now}) {
  if (lastSeen == null) return false;
  return (now ?? DateTime.now()).difference(lastSeen) <
      kBrowserExtensionSeenWindow;
}

/// 「验证插件已正常启用」：加载/重新加载扩展后其 SW 会主动打本机 server、刷新
/// last-seen。这里短轮询至多 [timeout]，检测到近期活跃即返回 true。
/// [cancelled] 返回 true 时提前结束（返回当时的判定）。
Future<bool> waitForBrowserExtensionConnection({
  required DateTime? Function() lastSeen,
  Duration timeout = const Duration(seconds: 8),
  Duration pollInterval = const Duration(milliseconds: 400),
  bool Function()? cancelled,
}) async {
  final DateTime start = DateTime.now();
  bool connected = isBrowserExtensionRecentlySeen(lastSeen());
  while (!connected && DateTime.now().difference(start) < timeout) {
    await Future<void>.delayed(pollInterval);
    if (cancelled?.call() ?? false) return connected;
    connected = isBrowserExtensionRecentlySeen(lastSeen());
  }
  return connected;
}

/// [prepareBrowserExtensionForInstall] 的结果快照。
class BrowserExtensionPrepareResult {
  const BrowserExtensionPrepareResult({
    required this.directory,
    required this.serverReady,
    required this.serverEnabled,
    required this.hasToken,
    required this.port,
  });

  /// 解压出的扩展目录绝对路径（浏览器「加载已解压的扩展程序」选它）。
  final String directory;

  /// 本机 yomitan-api server 是否就绪；false = 端口被占用。
  final bool serverReady;
  final bool serverEnabled;
  final bool hasToken;
  final int port;

  bool get portConflict => !serverReady;
}

/// 解压扩展的注入点（测试里换掉，避免写 app support 目录）。
typedef BrowserExtensionExtractor =
    Future<String> Function({
      required BrowserExtensionServerConfig serverConfig,
    });

/// 准备扩展：幂等开启 yomitan-api server（token 为空才播种、绝不覆盖）→ 用当前
/// server 真值解压扩展到本机（host/port/token 写进扩展默认配置，无需手填）。
Future<BrowserExtensionPrepareResult> prepareBrowserExtensionForInstall(
  AppModel appModel, {
  BrowserExtensionExtractor extract = prepareBundledBrowserExtension,
}) async {
  // TODO-1266：装扩展即默认开启 yomitan-api server（省得装完 401 连不上）。
  final bool serverReady = await appModel
      .ensureFushiApiServerForBrowserExtension();
  // TODO-1087：解压时注入当前 server 真值，扩展默认即连本机 app，无需手填。
  final String dir = await extract(
    serverConfig: BrowserExtensionServerConfig(
      host: '127.0.0.1',
      port: appModel.fushiApiPort,
      token: appModel.fushiApiKey,
    ),
  );
  return BrowserExtensionPrepareResult(
    directory: dir,
    serverReady: serverReady,
    serverEnabled: serverReady && appModel.fushiApiServerEnabled,
    hasToken: appModel.fushiApiKey.isNotEmpty,
    port: appModel.fushiApiPort,
  );
}
