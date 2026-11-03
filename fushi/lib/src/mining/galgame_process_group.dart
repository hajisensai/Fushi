import 'dart:io' as io;

import 'package:fushi/src/mining/galgame_path_match.dart';
import 'package:fushi/src/mining/galgame_play_tracker.dart';

/// 一局游戏的「进程组」：游戏目录下正在跑的全部进程。
///
/// 「某个进程算不算这局游戏」的**唯一**判据。游玩计时器
/// （[GalgamePlaySessionMachine]：前台逃逸检测、候选组重扫）与捕获会话的进程
/// 存活监视（`GalGameExitWatch`：认领 / 接手进程）都用它，不各写一份——两份判据
/// 曾在游戏装在 junction 后面时给出相反结论（计时器认为还在玩、会话却判退出）。
///
/// 归属判定先比原始路径，不命中再对两侧 `canonicalize` 后比一次：游戏装在符号链接
/// / junction 后面时，用户配置的 exe 路径是链接路径，而进程枚举报的是解析后的真实
/// 路径。
class GalgameProcessGroup {
  GalgameProcessGroup({
    required String? gameDirectory,
    required this.probe,
    int? selfPid,
  }) : gameDirectory = galgameProcessGroupDirectory(gameDirectory),
       _selfPid = selfPid ?? io.pid;

  /// 以 exe 路径的上一级目录为游戏目录建组。
  factory GalgameProcessGroup.forExecutable(
    String? executablePath, {
    required GalgameProcessProbe probe,
    int? selfPid,
  }) => GalgameProcessGroup(
    gameDirectory: galgameExecutableDirectory(executablePath),
    probe: probe,
    selfPid: selfPid,
  );

  /// 游戏目录（原样保留调用方给的写法，`canonicalize` 要用）；未知或是盘符根时为
  /// null——此时组里没有任何成员（「整个盘上的进程」不能当本游戏）。
  final String? gameDirectory;

  /// 进程判活 / 枚举 / 路径解析的平台依赖面。
  final GalgameProcessProbe probe;

  final int _selfPid;
  String? _canonicalGameDirectory;
  bool _canonicalGameDirectoryResolved = false;

  /// 进程是否仍在运行（透传 [probe]，PID ≤ 0 恒为 false）。
  bool isAlive(int pid) => pid > 0 && probe.isProcessAlive(pid);

  /// [path] 是否位于游戏目录下（原始路径与 `canonicalize` 后的路径任一命中）。
  bool isUnderGameDirectory(String path) {
    final String? directory = gameDirectory;
    if (directory == null) return false;
    if (galgamePathIsWithin(path, directory)) return true;
    if (!_canonicalGameDirectoryResolved) {
      _canonicalGameDirectoryResolved = true;
      _canonicalGameDirectory = probe.canonicalize(directory);
    }
    final String? canonicalDirectory = _canonicalGameDirectory;
    if (canonicalDirectory == null) return false;
    final String? canonicalPath = probe.canonicalize(path);
    if (canonicalPath == null) return false;
    return galgamePathIsWithin(canonicalPath, canonicalDirectory);
  }

  /// 枚举一次进程表，返回游戏目录下的全部 PID（不含 Fushi 自身）。
  Set<int> scanMembers() {
    final Set<int> members = <int>{};
    if (gameDirectory == null) return members;
    for (final GalgameProcessInfo info in probe.listProcesses()) {
      final String? imagePath = info.imagePath;
      if (info.pid <= 0 || info.pid == _selfPid || imagePath == null) continue;
      if (isUnderGameDirectory(imagePath)) members.add(info.pid);
    }
    return members;
  }

  /// 游戏目录下除 [excludePid] 外第一个仍活着的进程；没有则 null。
  ///
  /// 每次都**重新枚举**，不复用旧集合：旧集合里可能有已退出、PID 又被系统回收给
  /// 别人的条目，直接判活会把毫不相干的进程认成本游戏。
  int? findLiveSuccessor({required int excludePid}) {
    for (final int pid in scanMembers()) {
      if (pid == excludePid) continue;
      if (isAlive(pid)) return pid;
    }
    return null;
  }
}

/// exe 路径 → 游戏目录（去掉最后一个路径组件，保留原写法）。exe 直接放在盘符根
/// （或只剩一段）时返回 null。
String? galgameExecutableDirectory(String? executablePath) {
  if (executablePath == null) return null;
  final int slash = executablePath.lastIndexOf(RegExp(r'[\\/]'));
  if (slash <= 0) return null;
  return galgameProcessGroupDirectory(executablePath.substring(0, slash));
}

/// 进程组目录的合法性门：按路径组件算（`\` 与 `/` 等价），至少两段（盘符 + 一层
/// 目录）才可用；盘符根 / 空串返回 null。合法时原样返回 [directory]。
String? galgameProcessGroupDirectory(String? directory) {
  if (directory == null) return null;
  if (galgamePathComponents(directory).length < 2) return null;
  return directory;
}
