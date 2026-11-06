// knife（AuroraWright/knife：《月姬 -A piece of blue glass moon-》Switch 引擎的 Rust
// 重写版）的台词来源是它自带的 WebSocket 文本服务，**默认关闭**：只有 knife.ini 里有
// `text-websocket = HOST:PORT`，或启动时带 `-t` / `--text-websocket`，游戏才会推送台词。
// native adapter（native/galgame_hook/hook/adapters/knife_adapter.inc）在游戏进程里连
// 这个服务；服务没开时它只能报 kKnifeDiagWebSocketUnconfigured。
//
// 本文件是 host 侧的两处补位，判据与 native knife_profile.h 同一份（引擎的 romfs 目录
// 结构，不认 exe 名 / 哈希）：
//   * 从游戏库启动：服务没开就自动追加 `--text-websocket 127.0.0.1:<空闲端口>`；
//   * 附着到已在运行、服务没开的游戏：经用户确认把开关写进 knife.ini（重启游戏后生效）。

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

/// 写进 knife.ini 的地址：texthooker 生态的通用端口，别的文本工具也能直接连。
const String kKnifeIniTextWebSocketAddress = '127.0.0.1:6677';

/// Nintendo Opus 头块魔数（小端 0x80000001），knife 的 `stream/*.opus` 都以它开头。
const List<int> _kNintendoOpusMagic = <int>[0x01, 0x00, 0x00, 0x80];

/// knife.ini 里与台词服务有关的两项（knife/src/ini.rs：`key = value`、长选项名、
/// `;` / `#` 注释、空值等于未设置）。
class KnifeIniOptions {
  const KnifeIniOptions({this.assetsDir, this.textWebSocket});

  final String? assetsDir;
  final String? textWebSocket;
}

KnifeIniOptions parseKnifeIni(String text) {
  String? assetsDir;
  String? textWebSocket;
  for (final String raw in const LineSplitter().convert(text)) {
    final String line = raw.replaceFirst('﻿', '').trim();
    if (line.isEmpty || line.startsWith(';') || line.startsWith('#')) continue;
    final int eq = line.indexOf('=');
    if (eq < 0) continue;
    final String key = line.substring(0, eq).trim();
    final String value = line.substring(eq + 1).trim();
    if (value.isEmpty) continue;
    if (key == 'assets-dir') assetsDir = value;
    if (key == 'text-websocket') textWebSocket = value;
  }
  return KnifeIniOptions(assetsDir: assetsDir, textWebSocket: textWebSocket);
}

/// 用户启动参数里是否已经开了台词服务（`-t V` / `-tV` / `--text-websocket V` /
/// `--text-websocket=V`）。命令行优先于 knife.ini，已开就不能再追加一份。
bool knifeArgsEnableTextWebSocket(List<String> args) {
  for (int i = 0; i < args.length; i++) {
    final String arg = args[i];
    if (arg == '-t' || arg == '--text-websocket') {
      return i + 1 < args.length && args[i + 1].trim().isNotEmpty;
    }
    if (arg.startsWith('--text-websocket=')) {
      return arg.length > '--text-websocket='.length;
    }
    if (arg.length > 2 && arg.startsWith('-t') && arg[2] != '-') return true;
  }
  return false;
}

/// 用户启动参数里的 `-a` / `--assets-dir`（相对路径按工作目录解析，与 knife 一致）。
String? _knifeArgsAssetsDir(List<String> args) {
  for (int i = 0; i < args.length; i++) {
    final String arg = args[i];
    if (arg == '-a' || arg == '--assets-dir') {
      return i + 1 < args.length ? args[i + 1] : null;
    }
    if (arg.startsWith('--assets-dir=')) {
      return arg.substring('--assets-dir='.length);
    }
    if (arg.length > 2 && arg.startsWith('-a') && arg[2] != '-') {
      return arg.substring(2);
    }
  }
  return null;
}

/// 一个 knife 安装的台词服务现状。`null` = 不是 knife。
class KnifeInstall {
  const KnifeInstall({
    required this.iniPath,
    required this.assetsDir,
    required this.iniTextWebSocket,
  });

  final String iniPath;
  final String assetsDir;

  /// knife.ini 里配置的台词服务地址；`null` = 没开。
  final String? iniTextWebSocket;
}

String _readTextOrEmpty(String path) {
  try {
    return utf8.decode(File(path).readAsBytesSync(), allowMalformed: true);
  } on FileSystemException {
    return '';
  }
}

bool _directoryHasNintendoOpus(String dir) {
  final Directory stream = Directory(dir);
  if (!stream.existsSync()) return false;
  int scanned = 0;
  try {
    for (final FileSystemEntity entry in stream.listSync(followLinks: false)) {
      if (entry is! File || !entry.path.toLowerCase().endsWith('.opus')) {
        continue;
      }
      // 与 native engine_dir 同口径：命中即停，病态目录最多看 64 个。
      if (++scanned > 64) break;
      RandomAccessFile? file;
      try {
        file = entry.openSync();
        final Uint8List head = file.readSync(_kNintendoOpusMagic.length);
        bool match = head.length == _kNintendoOpusMagic.length;
        for (int i = 0; match && i < head.length; i++) {
          match = head[i] == _kNintendoOpusMagic[i];
        }
        if (match) return true;
      } on FileSystemException {
        continue;
      } finally {
        file?.closeSync();
      }
    }
  } on FileSystemException {
    return false;
  }
  return false;
}

/// 按 knife 自己找数据的方式定位 romfs（`-a` > knife.ini `assets-dir` > exe 旁的
/// `assets`），并用引擎结构判定：`allscr.mrg` + `stream/` 下的 Nintendo Opus。
KnifeInstall? detectKnifeInstall(
  String executablePath, {
  List<String> launchArgs = const <String>[],
  String? workingDirectory,
}) {
  if (executablePath.trim().isEmpty) return null;
  final String exeDir = p.dirname(executablePath);
  final String iniPath = p.join(exeDir, 'knife.ini');
  final KnifeIniOptions ini = parseKnifeIni(_readTextOrEmpty(iniPath));
  final String? cliAssets = _knifeArgsAssetsDir(launchArgs);
  final String assetsDir = cliAssets != null && cliAssets.trim().isNotEmpty
      ? p.normalize(p.join(workingDirectory ?? exeDir, cliAssets))
      : p.normalize(p.join(exeDir, ini.assetsDir ?? 'assets'));
  if (!File(p.join(assetsDir, 'allscr.mrg')).existsSync() ||
      !_directoryHasNintendoOpus(p.join(assetsDir, 'stream'))) {
    return null;
  }
  return KnifeInstall(
    iniPath: iniPath,
    assetsDir: assetsDir,
    iniTextWebSocket: ini.textWebSocket,
  );
}

/// 从游戏库启动时是否要替用户打开台词服务：是 knife，且 knife.ini 与用户参数都没开。
bool knifeNeedsTextWebSocketLaunchArg(
  String executablePath, {
  required List<String> userArgs,
  String? workingDirectory,
}) {
  if (knifeArgsEnableTextWebSocket(userArgs)) return false;
  final KnifeInstall? install = detectKnifeInstall(
    executablePath,
    launchArgs: userArgs,
    workingDirectory: workingDirectory,
  );
  return install != null && install.iniTextWebSocket == null;
}

/// 要追加的启动参数（[knifeNeedsTextWebSocketLaunchArg] 为真时）：
/// `--text-websocket 127.0.0.1:<freePort>`；否则空表，不动用户配置。
List<String> knifeAutoLaunchArgs({
  required String executablePath,
  required List<String> userArgs,
  required int freePort,
  String? workingDirectory,
}) {
  return knifeNeedsTextWebSocketLaunchArg(
        executablePath,
        userArgs: userArgs,
        workingDirectory: workingDirectory,
      )
      ? <String>['--text-websocket', '127.0.0.1:$freePort']
      : const <String>[];
}

/// 本机一个当前空闲的回环端口（绑 0 端口取系统分配值后立即释放）。
Future<int> pickFreeLoopbackPort() async {
  final ServerSocket socket = await ServerSocket.bind(
    InternetAddress.loopbackIPv4,
    0,
  );
  final int port = socket.port;
  await socket.close();
  return port;
}

/// 把 knife.ini 的台词服务开关打开：已有空值的 `text-websocket =` 行就地填上，否则
/// 追加一行；其余内容（含注释行）与换行风格原样保留。已经开着则不写。返回生效的地址。
String enableKnifeTextWebSocketInIni(
  String iniPath, {
  String address = kKnifeIniTextWebSocketAddress,
}) {
  final File file = File(iniPath);
  final String original = file.existsSync() ? _readTextOrEmpty(iniPath) : '';
  final String? existing = parseKnifeIni(original).textWebSocket;
  if (existing != null) return existing;
  final String newline = original.contains('\r\n') ? '\r\n' : '\n';
  final List<String> lines = original.isEmpty
      ? <String>[]
      : original.split(RegExp(r'\r?\n'));
  // 尾部换行拆出来的空串放回最后，保持文件原有结尾。
  final bool trailingNewline = lines.isNotEmpty && lines.last.isEmpty;
  if (trailingNewline) lines.removeLast();
  final String entry = 'text-websocket = $address';
  final int empty = lines.indexWhere((String line) {
    final String trimmed = line.trim();
    if (!trimmed.startsWith('text-websocket')) return false;
    final int eq = trimmed.indexOf('=');
    return eq >= 0 && trimmed.substring(0, eq).trim() == 'text-websocket';
  });
  if (empty >= 0) {
    lines[empty] = entry;
  } else {
    lines.add(entry);
  }
  file.writeAsStringSync('${lines.join(newline)}$newline', flush: true);
  return address;
}
