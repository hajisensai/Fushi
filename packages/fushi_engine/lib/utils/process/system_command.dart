import 'dart:io';

/// macOS 自带系统命令的绝对路径（macOS 27 上实测存在）。
///
/// **防御性改动，不修任何已知 bug。** Dart 3.14 起 macOS 的 `Process.run` /
/// `Process.start` 从 fork + exec 改走 `posix_spawn`，裸命令名改按**父进程**的
/// `PATH` 解析（以前按传给子进程的 `environment` 里的 `PATH`）。只有「传了与父进程
/// 不同的 `PATH`」的调用行为才会变；本仓调这些命令都继承父进程环境，两者相同，
/// Finder / launchd 拉起的 GUI 进程 `PATH` 也含 `/usr/bin:/bin:/usr/sbin:/sbin`。
/// 这里按 Dart CHANGELOG 的建议给绝对路径，只是去掉对启动环境 `PATH` 的依赖；
/// 表外的 `chmod` 等裸名调用同理不受 3.14 影响，不强制迁移。
const Map<String, String> kMacosSystemCommandPaths = <String, String>{
  'defaults': '/usr/bin/defaults',
  'lsof': '/usr/sbin/lsof',
  'ps': '/bin/ps',
  'say': '/usr/bin/say',
  'scutil': '/usr/sbin/scutil',
};

/// [name] 在当前平台上应交给 `Process` 的可执行文件：macOS 上表内命令给绝对
/// 路径，其余平台 / 表外命令原样返回（Linux 发行版间路径不统一，交给 `PATH`）。
String systemCommand(String name, {bool? macos}) {
  if (!(macos ?? Platform.isMacOS)) return name;
  return kMacosSystemCommandPaths[name] ?? name;
}
