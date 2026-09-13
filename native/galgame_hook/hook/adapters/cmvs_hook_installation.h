#pragma once

namespace fushi_voice_hook::cmvs_layout {

// HookFn may create a trampoline and then fail to enable the detour. The
// trampoline belongs to the forwarding path; only a successful installer
// result establishes sensor availability. Owned by HookWorker only.
class HookInstallation {
 public:
  using Installer = bool (*)(void*, void*, void**);

  bool Install(Installer installer, void* target, void* detour, void** original) {
    if (attempted_) return enabled_;
    attempted_ = true;
    enabled_ = installer && target && detour && original &&
               installer(target, detour, original) && *original != nullptr;
    return enabled_;
  }

  bool enabled() const { return enabled_; }
  void Shutdown() { enabled_ = false; }

 private:
  bool attempted_ = false;
  bool enabled_ = false;
};

}  // namespace fushi_voice_hook::cmvs_layout
