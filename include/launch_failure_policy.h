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

// 刚创建出来的游戏进程是否处于挂起态（纯函数，单一事实来源）。
//
// 为什么不能只看调用方请求的 CREATE_SUSPENDED：走 Locale Emulator 时进程由 LoaderDll 的
// `LeCreateProcess` 代创建，而 injector 在那个调用上**无条件叠加** CREATE_SUSPENDED，
// 所以只要走了 locale，进程就一定是挂起态——即使 creation_flags 本身是 0
// （follow-child 策略下就是 0）。旧实现算「是否挂起」时漏掉了 locale 这一半，于是
// 「必须恢复」的判断在 locale 路径上直接失效。
inline bool LaunchedProcessIsSuspended(bool create_suspended_requested,
                                       bool locale_launched) {
  return create_suspended_requested || locale_launched;
}

// 注入完成后，是否仍由注入编排负责恢复游戏主线程（纯函数）。
//
// 挂起态是必要条件，「尚未被恢复」是另一个必要条件：follow-child / Siglus 策略会在进程
// 发现之前就先恢复，此时不能再恢复第二次。把这两件事写成一个显式判定，替掉旧实现那个
// 「线程句柄非空就顺便当成需要恢复」的隐式约定——后者让「句柄没拿到」被静默当成
// 「不需要恢复」，游戏因此永久挂起而 injector 照报成功。
inline bool MustResumeAfterInjection(bool launched_suspended,
                                     bool resumed_before_discovery) {
  return launched_suspended && !resumed_before_discovery;
}

// 游戏停在挂起态等待启动期 hook 就绪的时间预算（纯函数）。
//
// 为什么不能直接用宿主下发的 --wait-ms：Hibiki 把 `--wait-ms` 与它自己的整体握手超时
// **同源**下发（两边都是 readyTimeout），而 injector 又拿同一个值作为「让游戏挂着等
// audio hook 就绪」的上限。于是两侧同时到期：Hibiki 一超时就 kill injector，而 injector
// 可能恰好还停在那个等待里、尚未执行 ResumeThread——CREATE_SUSPENDED 的游戏于是被永久
// 留在挂起态（进程在、CPU 有、窗口永不出现）。注意 BUG-1066 那套失败处置只在 injector
// 自己还活着并检测到失败时才生效；被外部杀死时**没有任何代码会跑**，所以不能靠它兜底。
//
// 因此挂起窗口只取总预算的一小部分，把剩余时间留给 resume 与后续 IPC，确保 injector
// 一定先于宿主的超时把游戏放行。上限 5s：启动期 hook 是注入线程装的，与游戏主线程是否
// 运行无关，正常几百毫秒内就绪，等更久只会扩大竞态窗口而不会提高成功率。
inline unsigned long SuspendedStartupWaitBudgetMs(unsigned long total_wait_ms) {
  const unsigned long kCeiling = 5000ul;
  const unsigned long kFloor = 500ul;
  const unsigned long quarter = total_wait_ms / 4ul;
  const unsigned long capped = quarter > kCeiling ? kCeiling : quarter;
  if (capped >= kFloor) return capped;
  // 预算本来就很小（测试/短超时）时不再切分，但也绝不超过总预算。
  return total_wait_ms < kFloor ? total_wait_ms : kFloor;
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
