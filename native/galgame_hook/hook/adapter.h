#pragma once

#include <cstdint>

#include "voice_hook_ipc.h"

namespace fushi_voice_hook {

enum class AdapterCapability : uint32_t {
  kNone = 0,
  kText = 1u << 0,
  kResourceAudio = 1u << 1,
  kPcmAudio = 1u << 2,
  // 这里**没有** kIngameLookup 位，是刻意的：「本 adapter 带不带查词传感器」已经由
  // lookupAdmission() 的默认实现表达了（不 override 就是 EngineUnsupported，见下）。
  // 再加一位就是同一个事实的第二处声明，而 registry 的汇总从头到尾不读 capabilities()
  // ——那一位会变成写了没人读、且能与 override 悄悄对不上的东西。
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
  // **默认实现就是正确答案**——没做查词传感器的 adapter 一个字都不用写，它们天然是
  // EngineUnsupported。只有真的带传感器的那几家才 override，去区分「身份不符 /
  // 身份通过但还没装上 / 已装上」。这条"不 override 即不支持"就是该事实的唯一声明处，
  // 别再往 capabilities() 里加一位平行表达（见上）。
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
