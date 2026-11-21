#undef NDEBUG
#include <iostream>
#include <string>

#include "../audio_loopback_leases.h"

// loopback 采集租约表：galgame 会话与常驻的跨应用语音缓存共用系统混音那一路，
// 任何一方停都不能把另一方的环停掉。
namespace {

int g_assertions = 0;

bool Expect(bool condition, const char* message) {
  ++g_assertions;
  if (!condition) {
    std::cerr << "FAIL: " << message << "\n";
    return false;
  }
  return true;
}

bool TestSharedSessionStopsOnlyOnLastRelease() {
  bool ok = true;
  fushi::LoopbackLeaseTable table;
  const uint64_t cross_app = table.Acquire(1);
  const uint64_t galgame = table.Acquire(1);
  ok &= Expect(cross_app != 0 && galgame != 0 && cross_app != galgame,
               "every start gets its own non-zero lease");
  bool last = true;
  ok &= Expect(table.Release(galgame, &last) == 1,
               "releasing a known lease reports its session");
  ok &= Expect(!last,
               "galgame stopping must not stop the cross-app capture ring");
  ok &= Expect(table.SessionOf(cross_app) == 1,
               "the remaining holder still resolves to the running session");
  ok &= Expect(table.Release(cross_app, &last) == 1 && last,
               "the last release is the one that stops the capture");
  ok &= Expect(table.empty(), "nothing is left after both released");
  return ok;
}

bool TestUnknownAndDoubleReleaseAreNoOps() {
  bool ok = true;
  fushi::LoopbackLeaseTable table;
  const uint64_t cross_app = table.Acquire(7);
  const uint64_t galgame = table.Acquire(7);
  bool last = true;
  // A failed start followed by a defensive stop() carries no lease (0).
  ok &= Expect(table.Release(0, &last) == 0 && !last,
               "a stop without a lease never stops anyone");
  ok &= Expect(table.Release(galgame, &last) == 7 && !last, "first release");
  ok &= Expect(table.Release(galgame, &last) == 0 && !last,
               "a second stop with the same lease is a no-op");
  ok &= Expect(table.Count(7) == 1 && table.SessionOf(cross_app) == 7,
               "the other holder's lease survives repeated stops");
  return ok;
}

bool TestLeasesAreNeverReused() {
  bool ok = true;
  fushi::LoopbackLeaseTable table;
  const uint64_t first = table.Acquire(1);
  table.Release(first, nullptr);
  const uint64_t second = table.Acquire(1);
  ok &= Expect(second != first,
               "a stale lease can never alias a newer holder's lease");
  ok &= Expect(table.SessionOf(first) == 0, "the released lease is unknown");
  return ok;
}

bool TestRebindMovesHoldersToRestartedSession() {
  bool ok = true;
  fushi::LoopbackLeaseTable table;
  const uint64_t a = table.Acquire(3);
  const uint64_t b = table.Acquire(3);
  const uint64_t other = table.Acquire(4);
  table.Rebind(3, 9);
  ok &= Expect(table.SessionOf(a) == 9 && table.SessionOf(b) == 9,
               "holders of a dead capture follow its restart");
  ok &= Expect(table.SessionOf(other) == 4, "other sources are untouched");
  ok &= Expect(table.Count(3) == 0 && table.Count(9) == 2, "counts follow");
  return ok;
}

bool TestSourceKeys() {
  bool ok = true;
  ok &= Expect(fushi::LoopbackSourceKey(L"", 0).empty(),
               "system mix is the empty key");
  ok &= Expect(fushi::LoopbackSourceKey(L"C:/Data/WebView2/", 0) ==
                   fushi::LoopbackSourceKey(L"c:\\data\\webview2", 0),
               "user data folders compare case/separator-insensitively");
  ok &= Expect(fushi::LoopbackSourceKey(L"C:/Data/WebView2", 0) !=
                   fushi::LoopbackSourceKey(L"", 0),
               "a process tree never shares the system mix ring");
  ok &= Expect(fushi::LoopbackSourceKey(L"C:/x", 42) ==
                   fushi::LoopbackSourceKey(L"", 42),
               "an explicit pid wins over the folder");
  return ok;
}

}  // namespace

int main() {
  bool ok = true;
  ok &= TestSharedSessionStopsOnlyOnLastRelease();
  ok &= TestUnknownAndDoubleReleaseAreNoOps();
  ok &= TestLeasesAreNeverReused();
  ok &= TestRebindMovesHoldersToRestartedSession();
  ok &= TestSourceKeys();
  if (!ok) {
    return 1;
  }
  std::cout << "audio_loopback_leases_test: " << g_assertions
            << " assertions passed\n";
  return 0;
}
