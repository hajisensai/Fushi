#pragma once

#include <cstdint>

#include "voice_hook_ipc.h"

namespace fushi_voice_hook {

enum class AdapterCapability : uint32_t {
  kNone = 0,
  kText = 1u << 0,
  kResourceAudio = 1u << 1,
  kPcmAudio = 1u << 2,
  // v19：本 adapter 带游戏内查词传感器。加这一位是为了让「本引擎没做查词」成为
  // **可推导**的事实，而不是让 host 去猜：registry 看见命中的 adapter 没有这位，
  // 就直接得出 kLookupAdmissionEngineUnsupported。没有它，12 个不带传感器的 adapter
  // 就得各自写一行"我不支持"，而漏写的那个会静默退化成"不知道"——这正是特殊情况繁殖
  // 的方式。声明能力，而不是逐个否认。
  kIngameLookup = 1u << 3,
};

constexpr AdapterCapability operator|(AdapterCapability left,
                                      AdapterCapability right) {
  return static_cast<AdapterCapability>(static_cast<uint32_t>(left) |
                                        static_cast<uint32_t>(right));
}

struct AdapterDiagnostics {
  const char* id = nullptr;
  bool applicable = false;
  bool installed = false;
  uint32_t flags = 0;
};

// P1 的稳定 adapter 契约。具体 adapter 不拥有共享内存生命周期；registry 在 HookWorker
// 已校验 IPC、初始化 MinHook/锁之后统一调用。onModuleLoaded 始终在工作线程执行，绝不在
// loader lock 或音频回调里安装 hook。
class EngineAdapter {
 public:
  virtual ~EngineAdapter() = default;

  virtual const char* id() const = 0;
  virtual bool probe() const = 0;
  virtual bool install() = 0;
  virtual AdapterCapability capabilities() const = 0;
  virtual void onModuleLoaded(const wchar_t* module_name) = 0;
  virtual void shutdown() = 0;
  virtual AdapterDiagnostics diagnostics() const = 0;

  // v19：本 adapter 对「游戏内查词能不能用」的当前结论。
  //
  // **默认实现就是正确答案**——不带 kIngameLookup 能力的 adapter 一个字都不用写，
  // 它们天然是 EngineUnsupported。只有真的带传感器的那几家才 override，去区分
  // 「身份不符 / 身份通过但还没装上 / 已装上」。
  //
  // 纯查询、不得有副作用：registry 每轮 Poll 都会调它，在这里装 hook 或算 SHA-256
  // 就等于把安装时序绑死在轮询节奏上。哈希这类昂贵结果必须由 adapter 自己缓存
  // （Siglus/Leaf 都已有一次性 profile 状态缓存，直接读那个）。
  virtual LookupAdmissionReport lookupAdmission() const {
    LookupAdmissionReport report;
    report.state = kLookupAdmissionEngineUnsupported;
    return report;
  }
};

}  // namespace fushi_voice_hook
