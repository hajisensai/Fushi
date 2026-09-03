import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'package:fushi/src/anki/ankiconnect_addon_installer.dart'
    show kAnkiConnectAddonId, locateAnkiDataDir;

/// AnkiConnect 端口自愈。
///
/// 为什么需要它：AnkiConnect 默认蹲 8765，这个端口在装了别的开发/游戏/加速工具的
/// 机器上经常已经被别人占了。占用者**接受 TCP 连接却不按 AnkiConnect 应答**时，
/// 用户能看到的只有一句超时——而真正的解法要同时改两处：Hibiki 这边的端口，和
/// Anki「工具 → 插件 → AnkiConnect → 配置」里的 `webBindPort`。少改一处就仍然连不上，
/// 这正是这个流程劝退人的地方。这里把「挑一个空闲端口 + 两处一起写」收成一次点击。
///
/// AnkiConnect 的 `webBindPort` **没有环境变量覆盖**（上游 `util.DEFAULT_CONFIG`
/// 只给 `webBindAddress` / `webCorsOrigin` 留了 env 口子），插件配置是唯一真相源，
/// 所以写 `addons21/<id>/meta.json` 的 `config.webBindPort` 就是权威改法：Anki 的
/// `addonManager.getConfig` 取包内 `config.json` 作默认值，再用 `meta.json` 的
/// `config` 覆盖。插件只在加载时读一次，因此写完必须重启 Anki 才生效。

/// 扫描空闲端口的起点。AnkiConnect 默认端口的紧邻区间，仍落在 IANA 用户端口段
/// （1024–49151）内且远离常见服务，用户日后手填也好记。
const int kAnkiConnectPortScanStart = 8765;

/// 扫描长度。200 个候选够覆盖「几个端口被占」的现实情况，又不会在全被占的病态
/// 机器上把 UI 卡太久（每次 bind 尝试是本机操作，失败即刻返回）。
const int kAnkiConnectPortScanCount = 200;

/// [port] 在本机 loopback 上是否空闲。
///
/// 判据就是「能不能 bind」——与 AnkiConnect 自己启动时做的是同一件事（它绑
/// `webBindAddress`，默认 `127.0.0.1`），所以这个探测的结论和插件下次启动时的
/// 成败同源，不是另造一套猜测。探测完立刻释放，不占住端口。
Future<bool> ankiConnectPortIsFree(int port) async {
  if (port < 1024 || port > 65535) return false;
  ServerSocket? socket;
  try {
    socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, port);
    return true;
  } on SocketException {
    return false;
  } finally {
    await socket?.close();
  }
}

/// 从 [kAnkiConnectPortScanStart] 起找第一个空闲端口，跳过 [exclude]。
///
/// [exclude] 是**当前配置的端口**：调用这个函数的前提就是它不好使，把它选回来
/// 等于什么都没做。全被占时返回 null。
Future<int?> findFreeAnkiConnectPort({
  int? exclude,
  int start = kAnkiConnectPortScanStart,
  int count = kAnkiConnectPortScanCount,
}) async {
  for (int port = start; port < start + count && port <= 65535; port++) {
    if (port == exclude) continue;
    if (await ankiConnectPortIsFree(port)) return port;
  }
  return null;
}

/// 写插件配置的结果。
enum AnkiConnectPortWriteStatus {
  /// `meta.json` 的 `config.webBindPort` 已写成目标端口；重启 Anki 后生效。
  updated,

  /// 找不到 Anki 数据目录或 AnkiConnect 插件目录（Anki 没装 / 一次都没运行过 /
  /// 插件没装 / 用了自定义 `-b` 基目录）。此时只能让用户自己去插件配置里改。
  addonNotFound,
}

class AnkiConnectPortWriteResult {
  const AnkiConnectPortWriteResult(this.status, {this.metaFile});

  final AnkiConnectPortWriteStatus status;

  /// 实际写入的 `meta.json`（仅 [AnkiConnectPortWriteStatus.updated] 时非空）。
  final File? metaFile;
}

/// 把 [port] 写进 AnkiConnect 插件配置（`addons21/<id>/meta.json` 的
/// `config.webBindPort`）。
///
/// 只改这一个键：`meta.json` 里其余字段（用户改过的 `apiKey`、
/// `webCorsOriginList`、`disabled`、`mod` 等）原样保留——这跟
/// [installAnkiConnectAddon] 保留用户配置是同一条纪律。
///
/// [ankiDataDir] 仅测试注入；生产走 [locateAnkiDataDir]。
Future<AnkiConnectPortWriteResult> writeAnkiConnectAddonPort(
  int port, {
  Directory? ankiDataDir,
}) async {
  final Directory? base = ankiDataDir ?? locateAnkiDataDir();
  if (base == null || !base.existsSync()) {
    return const AnkiConnectPortWriteResult(
      AnkiConnectPortWriteStatus.addonNotFound,
    );
  }
  final Directory addonDir = Directory(
    p.join(base.path, 'addons21', kAnkiConnectAddonId),
  );
  if (!addonDir.existsSync()) {
    return const AnkiConnectPortWriteResult(
      AnkiConnectPortWriteStatus.addonNotFound,
    );
  }

  final File metaFile = File(p.join(addonDir.path, 'meta.json'));
  Map<String, dynamic> meta = <String, dynamic>{};
  if (metaFile.existsSync()) {
    try {
      final Object? decoded = json.decode(metaFile.readAsStringSync());
      if (decoded is Map<String, dynamic>) meta = decoded;
    } on FormatException {
      // 坏 meta 当缺失处理，重写骨架（与安装器同样的容错）。
    }
  }
  final Object? existingConfig = meta['config'];
  final Map<String, dynamic> config = existingConfig is Map
      ? Map<String, dynamic>.from(existingConfig)
      : <String, dynamic>{};
  config['webBindPort'] = port;
  meta['config'] = config;
  metaFile.writeAsStringSync(json.encode(meta), flush: true);

  return AnkiConnectPortWriteResult(
    AnkiConnectPortWriteStatus.updated,
    metaFile: metaFile,
  );
}
