import 'dart:async';
import 'dart:io';

/// 我们自己拉起的**辅助子进程**登记处（ffmpeg / ffprobe 这类可执行文件就躺在安装目录里）。
///
/// 根因（BUG-1708 第二面）：Dart 的 `Process.start` 在 Windows 上不把子进程绑进任何 job
/// object，父进程 `exit(0)` 后它们照常活着。应用内更新恰恰是「app 主动退出、把安装交给
/// 别人」，于是一个还在转码的 ffmpeg 会**在 app 消失之后**继续锁着 `<安装目录>\ffmpeg.exe`；
/// Inno 复制到该文件时 `DeleteFile failed; code 5`，重试三次后**整包回滚**——用户现场日志
/// 2026-08-18 12:12 就是这样，安装全程无人可见，app 也再没起来。
///
/// 修法是给「我们拉起的进程」一个所有者：所有会落在安装目录里的辅助可执行文件都经这里启动，
/// 退出前统一终止并**等到它们真的死掉**（Windows 要等内核回收句柄，只发 kill 不等于文件已
/// 可替换）。不用 job object：Dart 无法给 `Process.start` 传 `CREATE_BREAKAWAY_FROM_JOB`，
/// 而 update launcher 必须在 app 死后继续活着——把它连坐杀掉会直接砍断整条更新链。
class HelperProcessRegistry {
  HelperProcessRegistry();

  static final HelperProcessRegistry instance = HelperProcessRegistry();

  final Set<Process> _live = <Process>{};

  /// 当前存活的登记进程数（诊断/测试用）。
  int get liveCount => _live.length;

  /// 启动一个受登记的子进程。签名与 `Process.start` 对齐，便于原地替换。
  ///
  /// 进程自然退出时自动注销，故长时间运行的 app 不会累积僵尸条目。
  Future<Process> start(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
    Map<String, String>? environment,
    bool includeParentEnvironment = true,
    bool runInShell = false,
    ProcessStartMode mode = ProcessStartMode.normal,
  }) async {
    final Process process = await Process.start(
      executable,
      arguments,
      workingDirectory: workingDirectory,
      environment: environment,
      includeParentEnvironment: includeParentEnvironment,
      runInShell: runInShell,
      mode: mode,
    );
    _live.add(process);
    unawaited(process.exitCode.then<void>(
      (int _) => _live.remove(process),
      onError: (Object _) => _live.remove(process),
    ));
    return process;
  }

  /// 终止全部登记进程，并等待它们真正退出。
  ///
  /// 返回实际等到退出的进程数。[grace] 是等待上限；超时后不再等待（调用方是退出路径，
  /// 卡死在这里比留下一个孤儿更糟），但已发出的 kill 仍然有效。
  ///
  /// 先 SIGTERM 再 SIGKILL：ffmpeg 收到 SIGTERM 会收尾关闭输出文件，直接 SIGKILL 会留下
  /// 半截产物。Windows 上两者都映射为 TerminateProcess，顺序无害。
  Future<int> terminateAll({
    Duration grace = const Duration(seconds: 5),
  }) async {
    final List<Process> targets = List<Process>.of(_live);
    if (targets.isEmpty) return 0;
    for (final Process process in targets) {
      try {
        process.kill();
      } catch (_) {
        // 已经退出：忽略。
      }
    }
    int reaped = 0;
    final List<Future<void>> waits = <Future<void>>[
      for (final Process process in targets)
        process.exitCode.then<void>((int _) {
          reaped++;
        }, onError: (Object _) {}),
    ];
    try {
      await Future.wait(waits).timeout(grace);
    } on TimeoutException {
      for (final Process process in targets) {
        try {
          process.kill(ProcessSignal.sigkill);
        } catch (_) {
          // 同上。
        }
      }
    }
    return reaped;
  }
}
