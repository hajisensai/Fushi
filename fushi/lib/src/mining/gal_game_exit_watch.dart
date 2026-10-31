import 'dart:io' as io;

import 'package:fushi/src/mining/galgame_path_match.dart';
import 'package:fushi/src/mining/galgame_play_tracker.dart';

/// 一次采样的结论（见 [GalGameExitWatch.sample]）。
enum GalGameExitStatus {
  /// 被监视的进程活着。
  alive,

  /// 还不能下结论：从没见它活过（判活本身可能不可用），或失活次数未到确认门槛。
  unconfirmed,

  /// 原进程没了，但游戏目录下有接手的进程（游戏自重启、启动器换代）；改盯它。
  handedOff,

  /// 确认游戏已经退出。
  exited,
}

/// 捕获会话的「游戏进程还在不在」判据（BUG-3928）。纯状态机，不持定时器，
/// 由 [GalHookSessionController] 周期喂 [GalgameProcessProbe]。
///
/// 三条纪律，与游玩计时器 [GalgamePlaySessionMachine] 的判活同源：
/// - **从没见过它活着就永不判死**：判活靠 `OpenProcess`，受保护进程可能恒打不开，
///   恒 false 不能被当成「退出」把正在玩的会话停掉——那种情况退回旧行为（手动停止）。
/// - **连续 [confirmSamples] 次失活才算**：单次打不开可能只是句柄瞬时抖动。
/// - **先找接手进程再判死**：游戏目录下仍有别的存活进程（游戏改设置后自重启、
///   启动器拉起本体后退出）说明用户还在玩。
class GalGameExitWatch {
  GalGameExitWatch({
    required int pid,
    required String? executablePath,
    this.confirmSamples = 3,
    int? selfPid,
  }) : _pid = pid,
       gameDirectory = galGameExitWatchDirectory(executablePath),
       _selfPid = selfPid ?? io.pid;

  /// 找接手进程用的游戏目录（exe 的上一级）；未知或是盘符根时为 null，不找接手。
  final String? gameDirectory;

  /// 连续失活多少次才判定退出。
  final int confirmSamples;

  final int _selfPid;
  int _pid;
  bool _seenAlive = false;
  int _misses = 0;

  /// 当前盯着的进程（接手后会变）。
  int get pid => _pid;

  GalGameExitStatus sample(GalgameProcessProbe probe) {
    if (probe.isProcessAlive(_pid)) {
      _seenAlive = true;
      _misses = 0;
      return GalGameExitStatus.alive;
    }
    if (!_seenAlive) return GalGameExitStatus.unconfirmed;
    _misses++;
    if (_misses < confirmSamples) return GalGameExitStatus.unconfirmed;
    final int? successor = _findSuccessor(probe);
    if (successor != null) {
      _pid = successor;
      _misses = 0;
      return GalGameExitStatus.handedOff;
    }
    return GalGameExitStatus.exited;
  }

  int? _findSuccessor(GalgameProcessProbe probe) {
    final String? directory = gameDirectory;
    if (directory == null) return null;
    for (final GalgameProcessInfo info in probe.listProcesses()) {
      final String? imagePath = info.imagePath;
      if (info.pid <= 0 || info.pid == _pid || info.pid == _selfPid) continue;
      if (imagePath == null || !galgamePathIsWithin(imagePath, directory)) {
        continue;
      }
      if (probe.isProcessAlive(info.pid)) return info.pid;
    }
    return null;
  }
}

/// exe 路径 → 找接手进程用的游戏目录。按路径组件算（`\` 与 `/` 等价），不经
/// `dart:io` 的平台分隔符，两端结果一致。exe 直接放在盘符根（或只剩一段）时返回
/// null：「同目录的进程」就成了整个盘上的进程，不能当接手判据。
String? galGameExitWatchDirectory(String? executablePath) {
  if (executablePath == null) return null;
  final List<String> components = galgamePathComponents(executablePath);
  if (components.length < 3) return null;
  return components.sublist(0, components.length - 1).join('/');
}
