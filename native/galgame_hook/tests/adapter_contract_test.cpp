#include <cassert>
#include <cstdint>

#include "adapter.h"

namespace {

class FakeAdapter final : public hibiki_voice_hook::EngineAdapter {
 public:
  const char* id() const override { return "fake"; }
  bool probe() const override { return applicable; }
  bool install() override {
    installed = true;
    return true;
  }
  hibiki_voice_hook::AdapterCapability capabilities() const override {
    return hibiki_voice_hook::AdapterCapability::kText |
           hibiki_voice_hook::AdapterCapability::kResourceAudio;
  }
  void onModuleLoaded(const wchar_t*) override { ++module_notifications; }
  void shutdown() override { installed = false; }
  hibiki_voice_hook::AdapterDiagnostics diagnostics() const override {
    return {id(), applicable, installed, 0x42u};
  }

  bool applicable = true;
  bool installed = false;
  int module_notifications = 0;
};

}  // namespace

int main() {
  FakeAdapter adapter;
  hibiki_voice_hook::EngineAdapter* contract = &adapter;
  assert(contract->probe());
  assert(contract->install());
  contract->onModuleLoaded(L"engine.dll");
  assert(adapter.module_notifications == 1);

  const auto capabilities = static_cast<uint32_t>(contract->capabilities());
  assert((capabilities & static_cast<uint32_t>(
                             hibiki_voice_hook::AdapterCapability::kText)) != 0);
  assert((capabilities &
          static_cast<uint32_t>(
              hibiki_voice_hook::AdapterCapability::kResourceAudio)) != 0);
  assert((capabilities & static_cast<uint32_t>(
                             hibiki_voice_hook::AdapterCapability::kPcmAudio)) == 0);

  const hibiki_voice_hook::AdapterDiagnostics diagnostics =
      contract->diagnostics();
  assert(diagnostics.applicable);
  assert(diagnostics.installed);
  assert(diagnostics.flags == 0x42u);
  contract->shutdown();
  assert(!adapter.installed);
  return 0;
}
