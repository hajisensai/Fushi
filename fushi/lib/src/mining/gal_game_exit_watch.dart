import 'package:fushi/src/mining/galgame_play_tracker.dart';
import 'package:fushi/src/mining/galgame_process_group.dart';

/// 一次采样的结论（见 [GalGameExitWatch.sample]）。
enum GalGameExitStatus {
  /// 被监视的进程活着。
  alive,

  /// 还不能下结论：从没见它活过（判活本身可能不可用），或失活次数未到确认门槛。
  unconfirmed,

  /// 开局时不知道游戏 PID（launch 没拿到目标进程），在游戏目录下认领到了一个
  /// 活进程；此后盯它。
  adopted,

  /// 原进程没了，但游戏目录下有接手的进程（游戏自重启、启动器换代）；改盯它，
  /// 整条捕获会话（hook、窗口绑定、计时主 PID）都要跟过去。
  handedOff,

  /// 确认游戏已经退出。
  exited,
}

/// 一局游戏「游戏进程还在不在」的**唯一**判据（BUG-3993）。纯状态机，不持定时器，
/// 由 `GalHookSessionController` 周期调用 [sample]；同一个结论既驱动会话结束 /
/// 跟随接手进程，也驱动游玩计时（计时器自己不判活，见
/// [GalgamePlaySessionMachine.followMainProcess]）——两边不会再各下各的结论。
///
/// 三条纪律：
/// - **从没见过它活着就永不判死**：判活靠 `OpenProcess`，受保护进程可能恒打不开，
///   恒 false 不能被当成「退出」把正在玩的会话停掉——那种情况退回手动停止。
/// - **连续 [confirmSamples] 次失活才算**：单次打不开可能只是句柄瞬时抖动。
/// - **先找接手进程再判死**：游戏目录下仍有别的存活进程（游戏改设置后自重启、
///   启动器拉起本体后退出）说明用户还在玩。归属判据走 [GalgameProcessGroup]。
class GalGameExitWatch {
  GalGameExitWatch({
    required int pid,
    required this.group,
    this.confirmSamples = kMaxConsecutiveFailures,
  }) : _pid = pid;

  /// 本局游戏的进程组（判活、认领 / 接手进程的归属）。
  final GalgameProcessGroup group;

  /// 连续失活多少次才判定退出。
  final int confirmSamples;

  int _pid;
  bool _seenAlive = false;
  int _misses = 0;

  /// 当前盯着的进程（认领 / 接手后会变；未知时 ≤ 0）。
  int get pid => _pid;

  GalGameExitStatus sample() {
    if (_pid <= 0) {
      final int? adopted = group.findLiveSuccessor(excludePid: 0);
      if (adopted == null) return GalGameExitStatus.unconfirmed;
      _pid = adopted;
      _seenAlive = true;
      _misses = 0;
      return GalGameExitStatus.adopted;
    }
    if (group.isAlive(_pid)) {
      _seenAlive = true;
      _misses = 0;
      return GalGameExitStatus.alive;
    }
    if (!_seenAlive) return GalGameExitStatus.unconfirmed;
    _misses++;
    if (_misses < confirmSamples) return GalGameExitStatus.unconfirmed;
    final int? successor = group.findLiveSuccessor(excludePid: _pid);
    if (successor != null) {
      _pid = successor;
      _misses = 0;
      return GalGameExitStatus.handedOff;
    }
    return GalGameExitStatus.exited;
  }
}
