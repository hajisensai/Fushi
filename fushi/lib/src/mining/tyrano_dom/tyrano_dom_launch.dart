// 从 Fushi 启动 TyranoScript（Electron / NW.js）游戏时追加的 Chrome 远程调试参数。
//
// 只产出参数与端口，不改启动调用处（接线由 gal_hook 启动流程负责）。远程调试端口只绑
// 回环地址（Chromium 默认），但同机任何进程都能连上并完全控制页面——这是本数据源的
// 固有代价，端口每次启动随机取。

import 'package:fushi/src/mining/knife_text_websocket.dart'
    show pickFreeLoopbackPort;
import 'package:fushi/src/mining/tyrano_dom/tyrano_dom_game_detect.dart';

/// Chromium 远程调试开关的前缀（Electron 与 NW.js 都认）。
const String kRemoteDebuggingPortFlag = '--remote-debugging-port';

/// 一次启动要用的调试端口与要追加的参数。
class TyranoDomLaunchPlan {
  /// 创建启动计划。
  const TyranoDomLaunchPlan({required this.port, required this.extraArgs});

  /// 游戏页面的 CDP 端口（`127.0.0.1:<port>`）。
  final int port;

  /// 要追加到启动参数末尾的参数；用户参数里已有调试端口时为空。
  final List<String> extraArgs;
}

/// `--remote-debugging-port=<port>`。
List<String> tyranoDomRemoteDebuggingArgs(int port) => <String>[
  '$kRemoteDebuggingPortFlag=$port',
];

/// 用户参数里已经写了的调试端口（`--remote-debugging-port=N` 或分开两项），没有返回 null。
int? parseRemoteDebuggingPort(Iterable<String> args) {
  final List<String> list = args.toList();
  for (int i = 0; i < list.length; i++) {
    final String arg = list[i].trim();
    if (arg.startsWith('$kRemoteDebuggingPortFlag=')) {
      return _validPort(arg.substring(kRemoteDebuggingPortFlag.length + 1));
    }
    if (arg == kRemoteDebuggingPortFlag && i + 1 < list.length) {
      return _validPort(list[i + 1]);
    }
  }
  return null;
}

int? _validPort(String text) {
  final int? port = int.tryParse(text.trim());
  // 0 表示让 Chromium 自选端口，Fushi 读不到实际端口，当作没给。
  if (port == null || port <= 0 || port > 65535) return null;
  return port;
}

/// [exePath] 是 Tyrano 打包游戏时给出启动计划，否则 null。
///
/// 用户参数已带调试端口就沿用它、不再追加；否则取一个空闲回环端口。
/// [isTyranoGame] / [pickPort] 仅供测试替换。
Future<TyranoDomLaunchPlan?> planTyranoDomLaunch(
  String exePath, {
  List<String> userArgs = const <String>[],
  bool Function(String exePath) isTyranoGame = isTyranoElectronGameDirectory,
  Future<int> Function() pickPort = pickFreeLoopbackPort,
}) async {
  if (!isTyranoGame(exePath)) return null;
  final int? existing = parseRemoteDebuggingPort(userArgs);
  if (existing != null) {
    return TyranoDomLaunchPlan(port: existing, extraArgs: const <String>[]);
  }
  final int port = await pickPort();
  return TyranoDomLaunchPlan(
    port: port,
    extraArgs: tyranoDomRemoteDebuggingArgs(port),
  );
}
