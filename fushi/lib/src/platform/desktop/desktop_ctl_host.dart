import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:fushi_cli/fushi_cli.dart';
import 'package:fushi_engine/media/video/external_video.dart';
import 'package:fushi_engine/sync/pairing/fushi_pair_link.dart';

import 'package:fushi/src/lookup/lookup_deep_link.dart';
import 'package:fushi/src/platform/source_url_channel.dart';
import 'package:fushi/src/startup/test_environment.dart';

/// 关闭桌面控制通道的环境变量（值为 `off`）。
const String kDesktopCtlDisableEnv = 'FUSHI_CTL';

/// `fushi_cli open <target>` 的裁决：与 argv / 单实例转交（`main.dart` 的
/// `_handleExternalVideoChannel`）认同一组候选，顺序也相同——卡片来源 URL →
/// 配对深链 → 查词深链 → 视频文件。这里只判定，不执行；接受后由调用方交给那条
/// 既有通道落地，CLI 不另开第二条打开路径。
///
/// 与 argv 路径的区别只在「拒绝要说出来」：argv 遇到不认识的参数静默忽略，CLI
/// 要把原因回给终端。
CtlOpenResult classifyCtlOpenTarget(
  String target, {
  required bool videoModuleEnabled,
  bool Function(String path)? fileExists,
}) {
  if (SourceUrlChannel.isSourceUrl(target)) {
    return const CtlOpenResult.accepted(CtlOpenKind.sourceUrl);
  }
  if (FushiPairLink.tryParse(target) != null) {
    return const CtlOpenResult.accepted(CtlOpenKind.pairLink);
  }
  if (lookupWordFromDeepLink(target) != null) {
    return const CtlOpenResult.accepted(CtlOpenKind.lookup);
  }
  if (isSupportedVideoFile(target)) {
    if (!videoModuleEnabled) return const CtlOpenResult.rejected('视频模块已关闭');
    final bool exists =
        (fileExists ?? (String path) => File(path).existsSync())(target);
    if (!exists) return CtlOpenResult.rejected('文件不存在：$target');
    return const CtlOpenResult.accepted(CtlOpenKind.video);
  }
  return const CtlOpenResult.rejected('不支持的目标（目前只认视频文件、fushi:// 深链与卡片来源 URL）');
}

/// 桌面控制通道的 app 侧实现：把 [CtlDesktopHandler] 的四个动作接到 app 已有的
/// 入口上（具体落点由 `main.dart` 的 `_FushiReaderAppState` 以回调注入）。
class DesktopCtlHost implements CtlDesktopHandler {
  DesktopCtlHost({
    required this.isReady,
    required this.appVersion,
    required this.openTarget,
    required this.lookupWord,
    required this.quitApp,
    this.routes = const <CtlRoute>[],
  });

  /// AppModel 初始化完成且主导航可用。
  final bool Function() isReady;
  final String? Function() appVersion;
  final Future<CtlOpenResult> Function(String target) openTarget;
  final Future<void> Function(String word) lookupWord;
  final Future<void> Function() quitApp;

  /// 按域注册的路由（`ctl/desktop_ctl_routes.dart`）。
  @override
  final List<CtlRoute> routes;

  @override
  CtlAppStatus status() {
    final bool ready = isReady();
    return CtlAppStatus(
      pid: pid,
      platform: Platform.operatingSystem,
      initialised: ready,
      version: ready ? appVersion() : null,
    );
  }

  @override
  Future<CtlOpenResult> open(String target) => openTarget(target);

  @override
  Future<void> lookup(String word) => lookupWord(word);

  @override
  Future<void> quit() => quitApp();
}

/// 启动桌面控制通道（127.0.0.1 随机端口 + token，发现文件见 [resolveCtlStateDir]）。
///
/// 失败只记日志返回 null：CLI 用不了不该拖垮 app 启动。`FUSHI_CTL=off` 时不启动。
Future<CtlServer?> startDesktopCtlServer(
  CtlDesktopHandler handler, {
  Map<String, String>? environment,
}) async {
  final Map<String, String> env = environment ?? Platform.environment;
  if (env[kDesktopCtlDisableEnv]?.trim().toLowerCase() == 'off') return null;
  final String? stateDir = resolveCtlStateDir(
    environment: env,
    operatingSystem: Platform.operatingSystem,
    testRoot: fushiTestRootPath(environment: env),
  );
  if (stateDir == null) {
    debugPrint('[Fushi] ctl channel disabled: no per-user state dir');
    return null;
  }
  final CtlServer server = CtlServer(handler: handler, stateDir: stateDir);
  try {
    final CtlEndpoint endpoint = await server.start();
    debugPrint('[Fushi] ctl channel listening on 127.0.0.1:${endpoint.port}');
    return server;
  } on Object catch (error) {
    debugPrint('[Fushi] ctl channel failed to start: $error');
    return null;
  }
}
