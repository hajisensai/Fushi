#undef NDEBUG
#include "launcher_wait.h"

#include <cstdio>
#include <cstdlib>

using namespace fushi_voice_hook;
namespace {
void Check(bool ok) { if (!ok) std::abort(); }
void TestInteractiveLineage() {
  ChildProcessLineage lineage({100, 1000});
  Check(lineage.UpdateLifetime({100, 1000}, 1200, 0));
  Check(lineage.Observe({200, 1100}, 100));
  Check(lineage.UpdateLifetime({200, 1100}, 1400, 0));
  Check(lineage.UpdateLifetime({100, 1000}, 1500, 1300));
  LauncherWaitState wait(true, 0, 30000);
  // Exited Start is retained, while the real menu keeps the launch alive well
  // beyond a machine injection budget. No fallback PID is manufactured.
  Check(lineage.Find(100)->exited_at != 0 && lineage.Find(200)->exited_at == 0);
  Check(wait.Observe(31000, true, {}, true, false) == ChildWaitAction::kWait);
  Check(wait.Observe(3600000, true, {}, true, false) == ChildWaitAction::kWait);
  Check(lineage.UpdateLifetime({200, 1100}, 4000, 0));
  Check(lineage.Observe({300, 3500}, 200));
  Check(wait.Observe(3600100, true, {300, 3500}, true, false) == ChildWaitAction::kWait);
  Check(wait.Observe(3600200, true, {300, 3500}, true, false) == ChildWaitAction::kGame);
  Check(!lineage.Observe({300, 4500}, 200)); // PID reuse is not a descendant identity.
  Check(!lineage.Observe({400, 1400}, 100)); // Born after the parent's exit.
  LauncherWaitState ended(true, 0, 30000);
  Check(ended.Observe(100, true, {}, false, false) == ChildWaitAction::kEnded);
}
void TestUnknownAndRuntime() {
  LauncherWaitState unknown(false, 100, 30000);
  Check(unknown.Observe(30099, true, {}, true, false) == ChildWaitAction::kWait);
  Check(unknown.Observe(30100, true, {}, true, false) == ChildWaitAction::kTimedOut);
  LauncherWaitState root(false, 0, 30000);
  Check(root.Observe(999, true, {}, true, true) == ChildWaitAction::kWait);
  Check(root.Observe(1000, true, {}, true, true) == ChildWaitAction::kRootRuntime);
  LauncherWaitState changing(true, 0, 30000);
  Check(changing.Observe(10, true, {10, 1}, true, false) == ChildWaitAction::kWait);
  Check(changing.Observe(20, true, {10, 2}, true, false) == ChildWaitAction::kWait);
  Check(changing.Observe(30, true, {}, true, false) == ChildWaitAction::kWait);
  Check(changing.Observe(40, true, {10, 2}, true, false) == ChildWaitAction::kWait);
  Check(changing.Observe(50, true, {10, 2}, true, false) == ChildWaitAction::kGame);
  LauncherWaitState invalid(true, 100, 30000);
  Check(invalid.Observe(200, false, {}, true, false) == ChildWaitAction::kFailed);
  Check(invalid.Observe(99, true, {}, true, false) == ChildWaitAction::kFailed);
  LauncherWaitState deadline(false, 0, 100);
  Check(deadline.Observe(99, true, {10, 1}, true, false) == ChildWaitAction::kWait);
  Check(deadline.Observe(100, true, {10, 1}, true, false) == ChildWaitAction::kTimedOut);
}
}
int main() {
  TestInteractiveLineage(); TestUnknownAndRuntime();
  std::puts("Launcher wait: interactive lineage, bounded unknown discovery and stable lifetime passed");
}
