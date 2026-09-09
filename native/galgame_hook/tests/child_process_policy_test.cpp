// CI 走 `--config Release`，MSVC 在该配置下定义 NDEBUG，裸 assert 会被整条编译掉，
// 于是这个测试无论断言对不对都恒绿——与 BUG-1157「零测试执行伪装成通过」同一族。
// 必须在任何 include 之前撤销它。守卫：tests/assert_liveness_guard_test.py
#undef NDEBUG

#include "child_process_policy.h"

#include <cassert>
#include <vector>

using fushi_voice_hook::ChildProcessCandidate;
using fushi_voice_hook::SelectGameChildProcess;
using fushi_voice_hook::ChildProcessLineage;

void TestRetainedLauncherLineage() {
  ChildProcessLineage lineage({100, 10});
  assert(lineage.UpdateLifetime({100, 10}, 30, 25));
  assert(lineage.Observe({200, 20}, 100));
  assert(lineage.UpdateLifetime({200, 20}, 60, 50));
  // Both launcher snapshots are gone before the game is observed.
  assert(lineage.Observe({300, 40}, 200));
  assert(lineage.Find(300)->depth == 2);
  assert(lineage.UpdateLifetime({300, 40}, 80, 0));
  assert(lineage.Observe({400, 70}, 300));
  assert(lineage.Find(400)->depth == 3);
  assert(lineage.Observe({200, 20}, 100));
  assert(!lineage.Observe({200, 20}, 400));
  // A live observation proves no later birth until its next lifetime refresh.
  assert(!lineage.Observe({401, 90}, 300));

  // PID reuse must not extend an old parent's lifetime or adopt its new child.
  assert(!lineage.UpdateLifetime({200, 55}, 90, 0));
  assert(!lineage.Observe({200, 55}, 100));
  assert(!lineage.Observe({500, 60}, 200));
  assert(!lineage.Observe({100, 60}, 300));
  assert(!lineage.Observe({600, 5}, 100));
  assert(!lineage.Observe({600, 10}, 100));
  assert(!lineage.Observe({600, 20}, 999));
  assert(!lineage.Observe({600, 20}, 600));
  assert(!lineage.Observe({0, 20}, 100));
  assert(!lineage.Observe({600, 0}, 100));
  assert(!lineage.UpdateLifetime({100, 10}, 90, 0));
  assert(!lineage.UpdateLifetime({300, 40}, 90, 20));
  assert(!lineage.UpdateLifetime({300, 40}, 90, 100));

  // Unknown/unobserved relays and cycles fail closed, never infer by game name.
  assert(!lineage.Observe({701, 75}, 702));
  assert(!lineage.Observe({702, 76}, 701));
  assert(lineage.size() == 4);

  ChildProcessLineage bounded({1, 1});
  assert(bounded.UpdateLifetime({1, 1}, 1000, 0));
  for (uint32_t pid = 2; pid <= ChildProcessLineage::kMaxProcesses; ++pid) {
    assert(bounded.Observe({pid, pid}, 1));
  }
  assert(!bounded.Observe({1000, 999}, 1));
  assert(bounded.size() == ChildProcessLineage::kMaxProcesses);

  ChildProcessLineage deep({1, 1});
  for (uint32_t pid = 2; pid <= ChildProcessLineage::kMaxDepth + 1; ++pid) {
    assert(deep.UpdateLifetime({pid - 1, pid - 1}, 100, 0));
    assert(deep.Observe({pid, pid}, pid - 1));
  }
  assert(deep.UpdateLifetime({17, 17}, 100, 0));
  assert(!deep.Observe({18, 18}, 17));
  ChildProcessLineage invalid({1, 0});
  assert(!invalid.Observe({2, 20}, 1));
}

int main() {
  TestRetainedLauncherLineage();
  const std::vector<ChildProcessCandidate> renpy = {
      {200, 100, L"crashpad.exe", false, false},
      {201, 100, L"pythonw.exe", false, false},
      {202, 201, L"game.exe", true, true},
      {300, 999, L"python.exe", true, true},
  };
  assert(SelectGameChildProcess(100, renpy) == 202);

  const std::vector<ChildProcessCandidate> python_only = {
      {410, 400, L"helper.exe", false, false},
      {411, 400, L"python.exe", false, false},
  };
  assert(SelectGameChildProcess(400, python_only) == 411);

  const std::vector<ChildProcessCandidate> unrelated = {
      {501, 999, L"python.exe", true, true},
  };
  assert(SelectGameChildProcess(500, unrelated) == 0);

  // Siglus 启动器链（AngelBeats 体験版）：真正的游戏进程一个 ffmpeg 模块都不加载，
  // 只有「镜像目录带引擎数据签名」这条证据认得出它。没有这条证据时全员 -1，选出 0，
  // 于是 hook 留在转手即退的启动器上——文本/音频一条都不来。
  const std::vector<ChildProcessCandidate> siglus_launcher = {
      {601, 600, L"StartMenu.exe", false, false, false},
      {602, 601, L"SiglusEngine.exe", false, false, true},
  };
  assert(SelectGameChildProcess(600, siglus_launcher) == 602);

  // 引擎签名压过 ffmpeg 全中：解码器进程可能只是 helper，引擎签名不会。
  const std::vector<ChildProcessCandidate> signature_beats_ffmpeg = {
      {701, 700, L"decoder.exe", true, true, false},
      {702, 700, L"game.exe", false, false, true},
  };
  assert(SelectGameChildProcess(700, signature_beats_ffmpeg) == 702);

  // 不是后代的进程即使带签名也不选（同机开着的另一台游戏不该被抢过来）。
  const std::vector<ChildProcessCandidate> foreign_signature = {
      {801, 999, L"SiglusEngine.exe", false, false, true},
  };
  assert(SelectGameChildProcess(800, foreign_signature) == 0);
  return 0;
}
