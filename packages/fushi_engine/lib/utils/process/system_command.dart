import 'dart:io';

/// macOS 自带系统命令的绝对路径（macOS 27 上实测存在）。
///
/// Dart 3.14 起 macOS 的 `Process.run` / `Process.start` 改走 `posix_spawn`，
/// 按**父进程**的 `PATH` 解析裸命令名。从 Finder / launchd 拉起的 GUI 进程
/// `PATH` 只有 `/usr/bin:/bin:/usr/sbin:/sbin`，被别的启动器 / 精简环境拉起时
/// 可能更短，`/usr/sbin` 下的 `lsof` / `scutil` 尤其容易解析不到。系统自带命令
/// 一律按绝对路径调，不依赖 `PATH`。
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
