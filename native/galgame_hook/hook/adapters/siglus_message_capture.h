#pragma once

#include <atomic>
#include <cstddef>
#include <cstdint>
#include <type_traits>

namespace fushi_voice_hook {

struct SiglusMessageLayout {
  uint32_t voice_key_offset = 0;
  uint32_t surface_index_offset = 0;
  uint32_t surface_begin_offset = 0;
  uint32_t surface_end_offset = 0;
  uint32_t surface_stride = 0;
  uint32_t message_surface_return = 0;
  uint32_t scenario_return = 0;
};

struct SiglusMessageOwnerSnapshot {
  uint32_t voice_key;
  int32_t surface_index;
  uint32_t surface_begin;
  uint32_t surface_end;
  uint32_t surface;
};

struct SiglusMessageTicket {
  bool armed;
  uint32_t owner;
  uint32_t entry_esp;
  SiglusMessageOwnerSnapshot snapshot;
};
static_assert(std::is_trivial<SiglusMessageTicket>::value,
              "TLS tickets must not invoke a lazy initializer in callbacks");

inline bool SiglusMessageCheckedAddress(uint32_t base, uint32_t offset,
                                       uint32_t* result) {
  if (base == 0 || result == nullptr || offset > UINT32_MAX - base)
    return false;
  *result = base + offset;
  return true;
}

// Reader copies exactly one bounded uint32_t from a live or synthetic address.
// No pointers into game memory escape into the worker queue.
template <typename Reader>
bool ReadSiglusMessageOwner(const SiglusMessageLayout& layout, uint32_t owner,
                           Reader& read, SiglusMessageOwnerSnapshot* out) {
  if (out == nullptr || layout.surface_stride == 0) return false;
  SiglusMessageOwnerSnapshot value{};
  uint32_t address = 0, voice = 0, index = 0;
  if (!SiglusMessageCheckedAddress(owner, layout.voice_key_offset, &address) ||
      !read(address, &voice) ||
      !SiglusMessageCheckedAddress(owner, layout.surface_index_offset, &address) ||
      !read(address, &index) ||
      !SiglusMessageCheckedAddress(owner, layout.surface_begin_offset, &address) ||
      !read(address, &value.surface_begin) ||
      !SiglusMessageCheckedAddress(owner, layout.surface_end_offset, &address) ||
      !read(address, &value.surface_end) || index > INT32_MAX ||
      value.surface_begin == 0 || value.surface_end <= value.surface_begin)
    return false;
  const uint32_t span = value.surface_end - value.surface_begin;
  if (span % layout.surface_stride != 0 ||
      index >= span / layout.surface_stride) return false;
  value.voice_key = voice;
  value.surface_index = static_cast<int32_t>(index);
  // index < span/stride proves this multiply and addition remain in the vector.
  value.surface = value.surface_begin + index * layout.surface_stride;
  *out = value;
  return true;
}

template <typename Reader>
bool ArmSiglusMessageTicket(const SiglusMessageLayout& layout, uint32_t owner,
                           uint32_t entry_esp, Reader& read,
                           SiglusMessageTicket* ticket) {
  if (ticket == nullptr) return false;
  *ticket = {};  // Every outer entry revokes the previous ticket, including failure.
  if (entry_esp < 4 || layout.message_surface_return == 0 ||
      layout.scenario_return == 0 ||
      !ReadSiglusMessageOwner(layout, owner, read, &ticket->snapshot))
    return false;
  ticket->owner = owner;
  ticket->entry_esp = entry_esp;
  ticket->armed = true;
  return true;
}

template <typename Reader>
bool ConsumeSiglusMessageTicket(const SiglusMessageLayout& layout,
                               uint32_t surface, uint32_t entry_esp,
                               uint32_t wrapper_ebp, Reader& read,
                               SiglusMessageTicket* ticket,
                               SiglusMessageOwnerSnapshot* frozen) {
  if (ticket == nullptr) return false;
  const SiglusMessageTicket pending = *ticket;
  *ticket = {};  // A mismatching/recursive inner call consumes too; never retry it.
  if (!pending.armed || frozen == nullptr || entry_esp == 0 ||
      wrapper_ebp == 0 || entry_esp >= wrapper_ebp ||
      wrapper_ebp >= pending.entry_esp - 4 ||
      ((entry_esp | wrapper_ebp | pending.entry_esp) & 3u) != 0 ||
      surface != pending.snapshot.surface) return false;
  uint32_t saved_ebp = 0, wrapper_return = 0, scenario_return = 0, address = 0;
  if (!read(wrapper_ebp, &saved_ebp) || saved_ebp != pending.entry_esp - 4 ||
      !SiglusMessageCheckedAddress(wrapper_ebp, 4, &address) ||
      !read(address, &wrapper_return) ||
      wrapper_return != layout.message_surface_return ||
      !read(entry_esp, &scenario_return) ||
      scenario_return != layout.scenario_return) return false;
  SiglusMessageOwnerSnapshot current;
  if (!ReadSiglusMessageOwner(layout, pending.owner, read, &current) ||
      current.voice_key != pending.snapshot.voice_key ||
      current.surface_index != pending.snapshot.surface_index ||
      current.surface_begin != pending.snapshot.surface_begin ||
      current.surface_end != pending.snapshot.surface_end ||
      current.surface != surface) return false;
  *frozen = current;
  return true;
}

// Single consumer, multiple producers, fixed work per attempt. Contention/full
// queues drop the occurrence, never wait on a game thread or overwrite a reader.
template <typename T, uint32_t Capacity>
class SiglusMessageQueue {
  static_assert(Capacity >= 2 && (Capacity & (Capacity - 1)) == 0,
                "queue capacity must be a power of two");
  static_assert(std::is_trivially_copyable<T>::value,
                "callback tasks must be bounded plain data");
 public:
  SiglusMessageQueue() {
    for (uint32_t i = 0; i < Capacity; ++i) slots_[i].sequence.store(i);
  }
  bool TryPush(const T& value) {
    uint32_t position = write_.load(std::memory_order_relaxed);
    Slot& slot = slots_[position & (Capacity - 1)];
    if (slot.sequence.load(std::memory_order_acquire) != position ||
        !write_.compare_exchange_strong(position, position + 1,
                                       std::memory_order_relaxed)) return false;
    slot.value = value;
    slot.sequence.store(position + 1, std::memory_order_release);
    return true;
  }
  bool TryPop(T* out) {
    if (out == nullptr) return false;
    Slot& slot = slots_[read_ & (Capacity - 1)];
    if (slot.sequence.load(std::memory_order_acquire) != read_ + 1) return false;
    *out = slot.value;
    slot.sequence.store(read_ + Capacity, std::memory_order_release);
    ++read_;
    return true;
  }
 private:
  struct Slot {
    std::atomic<uint32_t> sequence{0};
    T value{};
  };
  Slot slots_[Capacity];
  std::atomic<uint32_t> write_{0};
  uint32_t read_ = 0;
};

}  // namespace fushi_voice_hook

#if defined(_MSC_VER) && defined(_M_IX86)
// The same machine-code body is exercised by the x86 executable test. pushad
// saves ECX at +24 and EBP at +8; the original entry ESP is save-frame +36.
// FX state also survives C++ copies; DF is cleared only while calling C++.
// Original arguments/return address are untouched; only the trampoline owns ret.
#define FUSHI_SIGLUS_MESSAGE_THUNK(name, observer, original) \
  __declspec(naked) void name() {                           \
    __asm { pushfd }                                       \
    __asm { pushad }                                       \
    __asm { mov ebx, esp }                                 \
    __asm { sub esp, 528 }                                 \
    __asm { and esp, -16 }                                 \
    __asm { fxsave [esp] }                                 \
    __asm { mov eax, fs:[34h] }                            \
    __asm { mov [esp + 512], eax }                         \
    __asm { cld }                                          \
    __asm { push dword ptr [ebx + 8] }                     \
    __asm { lea eax, [ebx + 36] }                          \
    __asm { push eax }                                     \
    __asm { push dword ptr [ebx + 24] }                    \
    __asm { call observer }                                \
    __asm { mov eax, [esp + 512] }                         \
    __asm { mov fs:[34h], eax }                            \
    __asm { fxrstor [esp] }                                \
    __asm { mov esp, ebx }                                 \
    __asm { popad }                                        \
    __asm { popfd }                                        \
    __asm { jmp dword ptr [original] }                      \
  }
#endif
