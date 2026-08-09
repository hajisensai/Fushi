#include <cassert>
#include <cstring>

#include "launch_failure_policy.h"

int main() {
  using fushi_voice_hook::DecideLaunchedProcessDisposition;
  using fushi_voice_hook::LaunchedProcessDisposition;
  using fushi_voice_hook::LaunchFailureReason;
  using fushi_voice_hook::LaunchFailureToken;

  // 根因回归：CREATE_SUSPENDED 拉起的游戏在 ResumeThread 之前失败时，绝不允许把进程
  // 留在挂起态。旧实现对「就绪事件超时」「旧映射不可复用」这两条（都在 Resume 之前
  // 返回 2）什么都不做，用户就得到一个有进程、无窗口的「启动失败」。
  assert(DecideLaunchedProcessDisposition(
             /*created_suspended=*/true, /*already_resumed=*/false,
             LaunchFailureReason::kReadyTimeout) ==
         LaunchedProcessDisposition::kResumeDegraded);
  assert(DecideLaunchedProcessDisposition(
             true, false, LaunchFailureReason::kStaleSession) ==
         LaunchedProcessDisposition::kResumeDegraded);
  assert(DecideLaunchedProcessDisposition(
             true, false, LaunchFailureReason::kInjectionFailed) ==
         LaunchedProcessDisposition::kResumeDegraded);
  assert(DecideLaunchedProcessDisposition(
             true, false, LaunchFailureReason::kBitnessMismatch) ==
         LaunchedProcessDisposition::kResumeDegraded);

  // 已经恢复过（例如守卫 hook 在 Resume 之后失败）：进程在正常跑，不再动它。
  assert(DecideLaunchedProcessDisposition(
             true, true, LaunchFailureReason::kGuardedHookFailed) ==
         LaunchedProcessDisposition::kLeaveRunning);
  // Siglus / 跟随子进程这类本来就不挂起启动的路径同样不动。
  assert(DecideLaunchedProcessDisposition(
             false, false, LaunchFailureReason::kReadyTimeout) ==
         LaunchedProcessDisposition::kLeaveRunning);
  // 成功路径永远不动进程。
  assert(DecideLaunchedProcessDisposition(true, true,
                                          LaunchFailureReason::kNone) ==
         LaunchedProcessDisposition::kLeaveRunning);

  // 恢复动作自身失败：留着也永远起不来，只有这一种情况才结束进程。
  assert(DecideLaunchedProcessDisposition(
             true, false, LaunchFailureReason::kResumeFailed) ==
         LaunchedProcessDisposition::kTerminate);

  // token 是与 Hibiki 消费端共享的契约（Dart `GalHookInjectorFailure` 枚举名）。
  assert(std::strcmp(LaunchFailureToken(LaunchFailureReason::kReadyTimeout),
                     "readyTimeout") == 0);
  assert(std::strcmp(LaunchFailureToken(LaunchFailureReason::kBitnessMismatch),
                     "bitnessMismatch") == 0);
  assert(std::strcmp(LaunchFailureToken(LaunchFailureReason::kStaleSession),
                     "staleSession") == 0);
  assert(std::strcmp(
             LaunchFailureToken(LaunchFailureReason::kSharedMemoryUnavailable),
             "sharedMemoryUnavailable") == 0);
  assert(std::strcmp(LaunchFailureToken(LaunchFailureReason::kResumeFailed),
                     "resumeFailed") == 0);
  assert(std::strcmp(LaunchFailureToken(LaunchFailureReason::kNone), "none") ==
         0);

  // ---- 挂起事实与恢复责任（真机现场回归：Locale Emulator 路径静默不恢复）----
  //
  // 现场（屋上の百合霊さん，x86 Unity，日语 locale，非 Siglus、非 follow-child）：
  // injector 打了 LAUNCH pid= 与 OK hooked、rc==0，但游戏主线程数小时后仍 Suspended、
  // 窗口从未出现；外部对主线程调一次 ResumeThread 返回 1（= 调用前挂起计数）→ 计数
  // 从未被减过。根因是「必须恢复」这件事从未被显式表达，只靠线程句柄非空隐式推断。

  // 普通 launch：请求了 CREATE_SUSPENDED → 挂起。
  assert(LaunchedProcessIsSuspended(true, false));
  // **本 bug 的核心负向断言**：走了 Locale Emulator 时，即使调用方的 creation_flags
  // 不含 CREATE_SUSPENDED（follow-child 策略下就是 0），LoaderDll 仍会叠加它，进程
  // 一定是挂起态。旧实现漏掉这一半，于是 locale 路径上「必须恢复」直接失效。
  assert(LaunchedProcessIsSuspended(false, true));
  // 两者都没有才是真的没挂起（Siglus 延迟附着、纯 follow-child 非 locale）。
  assert(!LaunchedProcessIsSuspended(false, false));

  // 现场组合：挂起且尚未恢复 → 注入后必须由注入编排恢复。
  assert(MustResumeAfterInjection(/*launched_suspended=*/true,
                                  /*resumed_before_discovery=*/false));
  // pre-discovery 已经恢复过（follow-child / Siglus 策略）→ 不得再恢复第二次。
  assert(!MustResumeAfterInjection(true, true));
  // 本来就没挂起 → 没有恢复责任。
  assert(!MustResumeAfterInjection(false, false));

  // ---- 挂起窗口预算：绝不与宿主的整体超时同时到期 ----
  //
  // Hibiki 把 --wait-ms 与自己的握手超时同源下发（都是 readyTimeout=30000），并在到期时
  // kill injector。若 injector 也拿满 30s 让游戏挂着等 hook，被 kill 时可能恰好还没
  // ResumeThread → 游戏永久挂起，且外部杀死时没有任何补偿代码会执行。
  assert(SuspendedStartupWaitBudgetMs(30000) == 5000);   // 上限封顶，留 25s 余量
  assert(SuspendedStartupWaitBudgetMs(30000) < 30000);   // 核心不变式：必须严格小于总预算
  assert(SuspendedStartupWaitBudgetMs(8000) == 2000);    // 未达上限时取四分之一
  assert(SuspendedStartupWaitBudgetMs(4000) == 1000);
  // 短预算（测试/自定义超时）不再切分到无意义的小值，但仍不得超过总预算。
  assert(SuspendedStartupWaitBudgetMs(1200) == 500);
  assert(SuspendedStartupWaitBudgetMs(300) == 300);
  assert(SuspendedStartupWaitBudgetMs(0) == 0);
  // 任何输入下都不得超过总预算——否则又回到「两侧同时到期」的竞态。
  for (unsigned long total = 0; total <= 60000; total += 137) {
    assert(SuspendedStartupWaitBudgetMs(total) <= total);
  }

  // 处置策略与上面的事实必须同源：locale 路径挂起、注入失败、尚未恢复时，绝不能
  // 因为「creation_flags 不含 CREATE_SUSPENDED」而被判成 kLeaveRunning ——那正是把
  // 一个永久挂起的进程留在原地。
  assert(DecideLaunchedProcessDisposition(
             LaunchedProcessIsSuspended(false, /*locale_launched=*/true),
             /*already_resumed=*/false, LaunchFailureReason::kReadyTimeout) ==
         LaunchedProcessDisposition::kResumeDegraded);
  return 0;
}
