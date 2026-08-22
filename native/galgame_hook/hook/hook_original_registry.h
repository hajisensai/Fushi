#pragma once

#include <array>
#include <atomic>
#include <cstddef>

namespace fushi_voice_hook {

// MinHook detours that can be reached through more than one COM vtable target
// must call the trampoline that belongs to the current target.  Publication is
// serialized by HookFnWithOriginalRegistry; Lookup stays lock-free for
// real-time audio callbacks.
template <size_t Capacity>
class HookOriginalRegistry {
 public:
  bool Publish(void* target, void* original) {
    if (target == nullptr || original == nullptr) return false;
    for (auto& entry : entries_) {
      if (entry.target.load(std::memory_order_acquire) == target) {
        return entry.original.load(std::memory_order_acquire) == original;
      }
    }
    for (auto& entry : entries_) {
      if (entry.target.load(std::memory_order_acquire) != nullptr) continue;
      entry.original.store(original, std::memory_order_relaxed);
      entry.target.store(target, std::memory_order_release);
      return true;
    }
    return false;
  }

  void* Lookup(void* target) const {
    if (target == nullptr) return nullptr;
    for (const auto& entry : entries_) {
      if (entry.target.load(std::memory_order_acquire) == target) {
        return entry.original.load(std::memory_order_acquire);
      }
    }
    return nullptr;
  }

  bool Erase(void* target, void* original) {
    for (auto& entry : entries_) {
      if (entry.target.load(std::memory_order_acquire) != target) continue;
      if (entry.original.load(std::memory_order_acquire) != original) {
        return false;
      }
      entry.target.store(nullptr, std::memory_order_release);
      entry.original.store(nullptr, std::memory_order_relaxed);
      return true;
    }
    return false;
  }

 private:
  struct Entry {
    std::atomic<void*> target{nullptr};
    std::atomic<void*> original{nullptr};
  };

  std::array<Entry, Capacity> entries_{};
};

}  // namespace fushi_voice_hook
