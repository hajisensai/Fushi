#ifndef HIBIKI_LAUNCH_FAILURE_POLICY_H_
#define HIBIKI_LAUNCH_FAILURE_POLICY_H_

namespace hibiki_voice_hook {

// 启动/注入失败的结构化原因。
//
// token 与 Hibiki 消费端 `GalHookInjectorFailure` 的枚举名逐字对应：injector 把
// `ERR reason=<token>` 打到 stderr，host 直接映射成可执行处置（需要管理员、位数不符、
// 被杀软拦截……）。旧实现只有人类可读的中文诊断，host 无法据此分流，最终只能给用户
// 一句没有原因的失败。
enum class LaunchFailureReason {
  kNone = 0,
  kBitnessMismatch,
  kStaleSession,
  kSharedMemoryUnavailable,
  kInjectionFailed,
  kReadyTimeout,
  kGuardedHookFailed,
  kResumeFailed,
  kCreateProcessFailed,
  kGameExeMissing,
  kHookDllMissing,
  kSteamTimeout,
};

inline const char* LaunchFailureToken(LaunchFailureReason reason) {
  switch (reason) {
    case LaunchFailureReason::kNone:
      return "none";
    case LaunchFailureReason::kBitnessMismatch:
      return "bitnessMismatch";
    case LaunchFailureReason::kStaleSession:
      return "staleSession";
    case LaunchFailureReason::kSharedMemoryUnavailable:
      return "sharedMemoryUnavailable";
    case LaunchFailureReason::kInjectionFailed:
      return "injectionFailed";
    case LaunchFailureReason::kReadyTimeout:
      return "readyTimeout";
    case LaunchFailureReason::kGuardedHookFailed:
      return "guardedHookFailed";
    case LaunchFailureReason::kResumeFailed:
      return "resumeFailed";
    case LaunchFailureReason::kCreateProcessFailed:
      return "createProcessFailed";
    case LaunchFailureReason::kGameExeMissing:
      return "gameExeMissing";
    case LaunchFailureReason::kHookDllMissing:
      return "hookDllMissing";
    case LaunchFailureReason::kSteamTimeout:
      return "steamTimeout";
  }
  return "unknown";
}

// 注入失败后，已经创建出来的游戏进程该怎么处置。
enum class LaunchedProcessDisposition {
  // 进程已经在正常运行（未挂起或已恢复）：不动它。
  kLeaveRunning,
  // 仍处 CREATE_SUSPENDED：必须恢复，让游戏以「无 hook」降级方式跑起来。
  kResumeDegraded,
  // 已经无法恢复成可用状态：结束进程，不留挂起僵尸。
  kTerminate,
};

// 核心不变式：**任何失败路径都不允许留下一个永久挂起的游戏进程**。
//
// 旧实现按返回码猜测状态——`rc==1` 直接 TerminateProcess（杀掉用户明明要玩的游戏），
// `rc==2` 依据一句「超时但已 Resume」的注释放着不管；而 `rc==2` 的两个来源（就绪事件
// 超时、旧映射不可复用）都发生在 ResumeThread **之前**。结果是进程存在、窗口永不出现，
// 用户看到的就是「启动失败」。所以「是否已恢复」必须作为事实传进来，而不是从返回码推断。
inline LaunchedProcessDisposition DecideLaunchedProcessDisposition(
    bool created_suspended, bool already_resumed, LaunchFailureReason reason) {
  if (reason == LaunchFailureReason::kNone) {
    return LaunchedProcessDisposition::kLeaveRunning;
  }
  // 恢复动作本身失败：进程留着也永远起不来，只能结束。
  if (reason == LaunchFailureReason::kResumeFailed) {
    return LaunchedProcessDisposition::kTerminate;
  }
  if (created_suspended && !already_resumed) {
    return LaunchedProcessDisposition::kResumeDegraded;
  }
  return LaunchedProcessDisposition::kLeaveRunning;
}

}  // namespace hibiki_voice_hook

#endif  // HIBIKI_LAUNCH_FAILURE_POLICY_H_
