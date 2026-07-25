#include <cassert>
#include <cstring>

#include "launch_failure_policy.h"

int main() {
  using hibiki_voice_hook::DecideLaunchedProcessDisposition;
  using hibiki_voice_hook::LaunchedProcessDisposition;
  using hibiki_voice_hook::LaunchFailureReason;
  using hibiki_voice_hook::LaunchFailureToken;

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
  return 0;
}
