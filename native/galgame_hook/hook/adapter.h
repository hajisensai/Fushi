#pragma once

#include <cstdint>

namespace hibiki_voice_hook {

enum class AdapterCapability : uint32_t {
  kNone = 0,
  kText = 1u << 0,
  kResourceAudio = 1u << 1,
  kPcmAudio = 1u << 2,
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
};

}  // namespace hibiki_voice_hook
