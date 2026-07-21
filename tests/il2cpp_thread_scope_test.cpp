// Il2CppManagedThreadScope 决策矩阵的离线单测（不需真实 GameAssembly.dll）。
//
// 根因回归：注入 DLL 在 Unity 原生 audio 线程上分配托管内存触发 Boehm GC
// "Collecting from unknown thread" 崩溃。守卫保证进入托管分配前当前线程已注册；本测试用假的
// IL2CPP 线程 API 固定四条路径：已注册免 attach、未注册则 attach+detach 且句柄配平、attach
// 失败或 API 缺失时判定为不安全并放弃。

#include <cstdio>

#include "il2cpp_thread_scope.h"

using hibiki_voice_hook::Il2CppManagedThreadScope;
using hibiki_voice_hook::Il2CppThreadFns;

namespace {

// 假 IL2CPP 线程 API 的观测状态。函数指针不能捕获，用文件级静态记录调用。
int g_attach_calls = 0;
int g_detach_calls = 0;
void* g_current_ret = nullptr;   // thread_current 返回值
void* g_attach_ret = nullptr;    // thread_attach 返回值
void* g_last_detached = nullptr;  // 最近一次 detach 收到的句柄

void ResetFakes() {
  g_attach_calls = 0;
  g_detach_calls = 0;
  g_current_ret = nullptr;
  g_attach_ret = nullptr;
  g_last_detached = nullptr;
}

void* FakeCurrent() { return g_current_ret; }
void* FakeDomainGet() { return reinterpret_cast<void*>(0xD0'11); }
void* FakeAttach(void* /*domain*/) {
  ++g_attach_calls;
  return g_attach_ret;
}
void FakeDetach(void* thread) {
  ++g_detach_calls;
  g_last_detached = thread;
}

int g_failures = 0;

void Check(bool ok, const char* what) {
  if (!ok) {
    std::printf("FAIL: %s\n", what);
    ++g_failures;
  }
}

Il2CppThreadFns FullFns() {
  return Il2CppThreadFns{&FakeCurrent, &FakeAttach, &FakeDetach, &FakeDomainGet};
}

// 1) 已注册线程：thread_current() 非空 -> safe，不 attach、不 detach。
void TestAlreadyRegistered() {
  ResetFakes();
  g_current_ret = reinterpret_cast<void*>(0x1234);  // 已注册
  {
    Il2CppManagedThreadScope scope(FullFns());
    Check(scope.safe(), "already-registered: safe() should be true");
    Check(!scope.attached(), "already-registered: must not attach");
    Check(g_attach_calls == 0, "already-registered: attach not called");
  }
  Check(g_detach_calls == 0, "already-registered: detach not called on destruct");
}

// 2) 未注册线程 + attach 成功 -> safe，attach 一次，析构 detach 同一句柄一次。
void TestUnregisteredAttachSucceeds() {
  ResetFakes();
  g_current_ret = nullptr;                          // 未注册（audio 线程）
  g_attach_ret = reinterpret_cast<void*>(0xABCD);   // attach 成功
  {
    Il2CppManagedThreadScope scope(FullFns());
    Check(scope.safe(), "unregistered/attach-ok: safe() should be true");
    Check(scope.attached(), "unregistered/attach-ok: attached() should be true");
    Check(g_attach_calls == 1, "unregistered/attach-ok: attach called once");
    Check(g_detach_calls == 0, "unregistered/attach-ok: detach deferred to destruct");
  }
  Check(g_detach_calls == 1, "unregistered/attach-ok: detach called once on destruct");
  Check(g_last_detached == reinterpret_cast<void*>(0xABCD),
        "unregistered/attach-ok: detach receives the attached handle");
}

// 3) 未注册 + attach 失败（返回 nullptr）-> 不安全，不 detach。
void TestUnregisteredAttachFails() {
  ResetFakes();
  g_current_ret = nullptr;
  g_attach_ret = nullptr;  // attach 失败
  {
    Il2CppManagedThreadScope scope(FullFns());
    Check(!scope.safe(), "unregistered/attach-fail: safe() should be false");
    Check(!scope.attached(), "unregistered/attach-fail: attached() should be false");
    Check(g_attach_calls == 1, "unregistered/attach-fail: attach attempted once");
  }
  Check(g_detach_calls == 0, "unregistered/attach-fail: never detach a failed attach");
}

// 4) thread_current API 缺失 -> 无法判定，不安全、绝不 attach。
void TestCurrentUnavailable() {
  ResetFakes();
  Il2CppThreadFns fns{nullptr, &FakeAttach, &FakeDetach, &FakeDomainGet};
  {
    Il2CppManagedThreadScope scope(fns);
    Check(!scope.safe(), "current-unavailable: safe() should be false");
    Check(g_attach_calls == 0, "current-unavailable: must not attach");
  }
  Check(g_detach_calls == 0, "current-unavailable: must not detach");
}

// 5) 未注册但 domain_get / attach 缺失 -> 无法 attach，不安全。
void TestAttachUnavailable() {
  ResetFakes();
  g_current_ret = nullptr;
  Il2CppThreadFns no_attach{&FakeCurrent, nullptr, &FakeDetach, &FakeDomainGet};
  {
    Il2CppManagedThreadScope scope(no_attach);
    Check(!scope.safe(), "attach-unavailable: safe() should be false");
  }
  ResetFakes();
  g_current_ret = nullptr;
  Il2CppThreadFns no_domain{&FakeCurrent, &FakeAttach, &FakeDetach, nullptr};
  {
    Il2CppManagedThreadScope scope(no_domain);
    Check(!scope.safe(), "domain-unavailable: safe() should be false");
    Check(g_attach_calls == 0, "domain-unavailable: must not attach without a domain");
  }
}

}  // namespace

int main() {
  TestAlreadyRegistered();
  TestUnregisteredAttachSucceeds();
  TestUnregisteredAttachFails();
  TestCurrentUnavailable();
  TestAttachUnavailable();
  if (g_failures == 0) {
    std::printf("il2cpp_thread_scope_test: all checks passed\n");
    return 0;
  }
  std::printf("il2cpp_thread_scope_test: %d check(s) failed\n", g_failures);
  return 1;
}
