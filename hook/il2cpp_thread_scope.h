#pragma once

// IL2CPP 托管线程注册守卫。
//
// Unity IL2CPP 用 Boehm-Demers-Weiser 保守 GC：只有**已向 GC 注册**的线程才能在托管堆上
// 分配内存（il2cpp_array_new、装箱 int 返回值、AudioClip.GetData、Object.get_name 等都会
// 分配）。若在未注册线程上触发一次托管分配并恰好引发回收，GC 会以
//   "Fatal error in GC: Collecting from unknown thread"
// 直接 abort，把整个游戏进程杀掉。
//
// 我们把 AudioSource.Play/PlayOneShot/PlayScheduled/PlayDelayed 及其内部 Helper 都下钩以在
// 播放时读取资源 PCM。public 入口由游戏主线程（已注册）调用是安全的；但 Unity 的 scheduled /
// delayed / 流式播放会由**原生 audio/mixer 线程**延迟执行内部 Helper，那条线程没注册到 IL2CPP
// 域——在其上分配托管内存就会命中上面的崩溃。
//
// 这里把“进入托管调用前确保当前线程已注册、退出后还原”的策略收敛为一个 RAII 作用域，并按
// 函数指针注入 IL2CPP 的三个线程 API，使决策矩阵可离线单测（无需真实 GameAssembly.dll）。

namespace hibiki_voice_hook {

// 来自 GameAssembly.dll 的 IL2CPP 线程 API（GetProcAddress 动态取址）：
//   thread_current(): 当前线程已注册返回非空、未注册返回 nullptr；可安全跨任意线程调用。
//   thread_attach(domain): 把当前线程注册进 IL2CPP 域，返回 Il2CppThread*（失败返回 nullptr）。
//   thread_detach(thread): 注销 thread_attach 返回的句柄。
//   domain_get(): 取当前 IL2CPP 域，供 thread_attach 使用。
// 任一为空表示该运行时不可用，守卫据此放弃而非冒险分配。
struct Il2CppThreadFns {
  void* (*thread_current)() = nullptr;
  void* (*thread_attach)(void*) = nullptr;
  void (*thread_detach)(void*) = nullptr;
  void* (*domain_get)() = nullptr;
};

// 进入托管调用前构造；safe() 为真才可分配托管内存。决策矩阵：
//   thread_current 不可用                 -> 无法判定线程状态，safe=false，不 attach。
//   thread_current() != nullptr           -> 已是托管线程（通常主线程），safe=true，无需 attach。
//   thread_current() == nullptr 且能 attach -> attach 当前线程，safe=(句柄非空)，析构时 detach。
// 只有本作用域自己 attach 出来的句柄才会在析构时 detach——绝不去动游戏原生线程的注册状态。
class Il2CppManagedThreadScope {
 public:
  explicit Il2CppManagedThreadScope(const Il2CppThreadFns& fns) : fns_(fns) {
    if (fns_.thread_current == nullptr) {
      return;
    }
    if (fns_.thread_current() != nullptr) {
      safe_ = true;
      return;
    }
    if (fns_.thread_attach != nullptr && fns_.domain_get != nullptr) {
      attached_ = fns_.thread_attach(fns_.domain_get());
      safe_ = attached_ != nullptr;
    }
  }

  ~Il2CppManagedThreadScope() {
    if (attached_ != nullptr && fns_.thread_detach != nullptr) {
      fns_.thread_detach(attached_);
    }
  }

  Il2CppManagedThreadScope(const Il2CppManagedThreadScope&) = delete;
  Il2CppManagedThreadScope& operator=(const Il2CppManagedThreadScope&) = delete;

  // 当前线程可安全进行托管分配（已注册，或本作用域已成功 attach）。
  bool safe() const { return safe_; }
  // 本作用域是否真正 attach 了当前线程（用于测试/诊断）。
  bool attached() const { return attached_ != nullptr; }

 private:
  const Il2CppThreadFns& fns_;
  void* attached_ = nullptr;
  bool safe_ = false;
};

}  // namespace hibiki_voice_hook
