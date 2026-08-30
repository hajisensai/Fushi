// CI 走 `--config Release`，MSVC 在该配置下定义 NDEBUG，裸 assert 会被整条编译掉，
// 于是这个测试无论断言对不对都恒绿——与 BUG-1157「零测试执行伪装成通过」同一族。
// 必须在任何 include 之前撤销它。守卫：tests/assert_liveness_guard_test.py
#undef NDEBUG

#include <cassert>
#include <cstdint>

#include "module_settle.h"

namespace {

using fushi_voice_hook::ModuleTableSettle;

// 这条判据存在的理由：查词准入原本用「已经扫过一次模块表」当收敛闸，而那在注入
// 完成的第 1 拍就成立。下面五条分别钉住它与「扫过一次」的差别。
void TestNeverScannedIsNotSettled() {
  ModuleTableSettle settle;
  assert(!settle.settled(0));
  assert(!settle.settled(1000000));  // 光靠时间流逝不算稳定
  assert(!settle.scanned());
}

void TestFirstScanAloneIsNotSettled() {
  ModuleTableSettle settle;
  // 首拍：整张模块表一次性出现。这不是「变化」，但也绝不能当成「没变化」去起算
  // 安静计数——否则满表落地那一刻就开始攒，几拍之后就收敛。
  settle.OnScanCompleted(true, 0);
  assert(settle.scanned());
  assert(settle.quiet_scans() == 0);
  assert(!settle.settled(0));
  // 就算时间已经过了地板，安静拍数还不够。
  assert(!settle.settled(60000));
}

void TestQuietScansAloneIsNotSettled() {
  ModuleTableSettle settle;
  settle.OnScanCompleted(true, 0);
  // 攒够安静拍数，但离首次扫描还没到 5 秒地板：片头 logo / OP 动画期间模块表可以
  // 整整安静几秒，只看「连续 N 次安静」会在那段伪静默里过早收敛。
  for (int i = 0; i < 40; ++i) {
    settle.OnScanCompleted(false, static_cast<uint64_t>(20 * (i + 1)));
  }
  assert(settle.quiet_scans() >= 15);
  assert(!settle.settled(800));
  // 地板过了才算数。
  assert(settle.settled(5000));
}

void TestNewModuleResetsTheQuietRun() {
  ModuleTableSettle settle;
  settle.OnScanCompleted(true, 0);
  for (int i = 0; i < 14; ++i) {
    settle.OnScanCompleted(false, static_cast<uint64_t>(200 * (i + 1)));
  }
  assert(settle.quiet_scans() == 14);
  assert(!settle.settled(10000));  // 差一拍
  // 第 15 拍来了个新模块（KiriKiri 的 wuvorbis.dll 就是这么迟到的）：重新攒。
  settle.OnScanCompleted(true, 3000);
  assert(settle.quiet_scans() == 0);
  assert(!settle.settled(10000));
  for (int i = 0; i < 15; ++i) {
    settle.OnScanCompleted(false, static_cast<uint64_t>(3200 + 200 * i));
  }
  assert(settle.settled(10000));
}

void TestFailedSnapshotDoesNotAdvance() {
  // 快照失败（CreateToolhelp32Snapshot 的 ERROR_BAD_LENGTH 在启动期很常见）时
  // 调用方**不调** OnScanCompleted —— 那是「没观测到」，不是「观测到没变」。
  // 这条正是原 bug 的镜像：把两者混同，连续失败的进程会假装自己稳定了。
  ModuleTableSettle settle;
  settle.OnScanCompleted(true, 0);
  const uint32_t before = settle.quiet_scans();
  // 模拟 20 次快照失败：什么都不调。
  assert(settle.quiet_scans() == before);
  assert(!settle.settled(60000));
}

}  // namespace

int main() {
  TestNeverScannedIsNotSettled();
  TestFirstScanAloneIsNotSettled();
  TestQuietScansAloneIsNotSettled();
  TestNewModuleResetsTheQuietRun();
  TestFailedSnapshotDoesNotAdvance();
  return 0;
}
