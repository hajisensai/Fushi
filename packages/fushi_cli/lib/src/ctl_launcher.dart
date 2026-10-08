import 'dart:io';

import 'package:path/path.dart' as p;

/// 显式指定 app 可执行文件（或 macOS 的 `.app` 包）的环境变量。
const String kFushiAppEnv = 'FUSHI_APP';

/// 启动 app 进程的钩子（测试注入；生产走 [startDetachedProcess]）。
typedef CtlProcessStarter =
    Future<void> Function(String executable, List<String> arguments);

Future<void> startDetachedProcess(
  String executable,
  List<String> arguments,
) async {
  await Process.start(
    executable,
    arguments,
    mode: ProcessStartMode.detached,
    workingDirectory: p.dirname(executable),
  );
}

/// 按优先级列出 app 可能所在的位置（不判断存在性）。
///
/// 1. `--app` / `FUSHI_APP`；
/// 2. CLI 可执行文件的同级目录——安装包把 `fushi_cli` 放在 `fushi(.exe)` 旁边；
/// 3. 各平台默认安装位置：Windows 安装包 `DefaultDirName={localappdata}\Fushi`；
///    macOS `/Applications` 与 `~/Applications` 下的 `fushi.app` / `Fushi.app`。
List<String> fushiAppCandidates({
  required Map<String, String> environment,
  required String operatingSystem,
  required String cliExecutable,
  String? explicitPath,
}) {
  final List<String> out = <String>[];
  void add(String? value) {
    final String? v = value?.trim();
    if (v != null && v.isNotEmpty && !out.contains(v)) out.add(v);
  }

  add(explicitPath);
  add(environment[kFushiAppEnv]);
  final p.Context path = operatingSystem == 'windows' ? p.windows : p.posix;
  final String cliDir = path.dirname(cliExecutable);
  switch (operatingSystem) {
    case 'windows':
      add(p.windows.join(cliDir, 'fushi.exe'));
      final String? local = environment['LOCALAPPDATA'];
      if (local != null && local.isNotEmpty) {
        add(p.windows.join(local, 'Fushi', 'fushi.exe'));
      }
    case 'macos':
      // CLI 随包放在 `<bundle>.app/Contents/MacOS/` 时，同级就是 app 本体。
      add(p.posix.join(cliDir, 'fushi'));
      final String? home = environment['HOME'];
      for (final String root in <String>[
        '/Applications',
        if (home != null && home.isNotEmpty) p.posix.join(home, 'Applications'),
      ]) {
        add(p.posix.join(root, 'fushi.app'));
        add(p.posix.join(root, 'Fushi.app'));
      }
    default:
      add(p.posix.join(cliDir, 'fushi'));
  }
  return out;
}

/// 第一个真实存在的候选；都不存在返回 null。
Future<String?> locateFushiApp({
  required Map<String, String> environment,
  required String operatingSystem,
  required String cliExecutable,
  String? explicitPath,
}) async {
  for (final String candidate in fushiAppCandidates(
    environment: environment,
    operatingSystem: operatingSystem,
    cliExecutable: cliExecutable,
    explicitPath: explicitPath,
  )) {
    // 不能拿 CLI 自己当 app 拉起（同级候选名与 CLI 重名时会死循环）。
    if (p.equals(candidate, cliExecutable)) continue;
    if (candidate.endsWith('.app')) {
      if (await Directory(candidate).exists()) return candidate;
      continue;
    }
    if (await File(candidate).exists()) return candidate;
  }
  return null;
}

/// 拉起 app，不等它就绪（就绪由调用方轮询发现文件判定）。macOS 的 `.app` 包走
/// `open`，让 LaunchServices 按普通双击的方式启动（单实例、Dock 图标都对）。
Future<void> launchFushiApp(
  String appPath, {
  required String operatingSystem,
  CtlProcessStarter starter = startDetachedProcess,
}) async {
  if (operatingSystem == 'macos' && appPath.endsWith('.app')) {
    await starter('open', <String>[appPath]);
    return;
  }
  await starter(appPath, const <String>[]);
}
