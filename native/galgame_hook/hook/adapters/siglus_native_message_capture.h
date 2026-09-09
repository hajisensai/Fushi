#pragma once

#include "siglus_message_capture.h"

namespace fushi_voice_hook {

// Layout of pushad after pushfd, before the observer modifies any register.
// pushad's saved ESP points to the saved flags, four bytes below entry ESP.
struct SiglusNativeMessageSavedRegisters {
  uint32_t edi, esi, ebp, saved_esp, ebx, edx, ecx, eax, eflags;
};
static_assert(sizeof(SiglusNativeMessageSavedRegisters) == 36);
static_assert(offsetof(SiglusNativeMessageSavedRegisters, ebx) == 16);
static_assert(offsetof(SiglusNativeMessageSavedRegisters, ecx) == 24);

struct SiglusNativeMessageLayout {
  SiglusMessageLayout owner;
  uint32_t native_text_return = 0;
};

struct SiglusNativeMessageTicket {
  bool armed;
  uint32_t owner, entry_esp, outer_return;
  SiglusMessageOwnerSnapshot snapshot;
};
static_assert(std::is_trivial<SiglusNativeMessageTicket>::value);

inline uint32_t SiglusNativeMessageEntryEsp(
    const SiglusNativeMessageSavedRegisters& registers) {
  return registers.saved_esp <= UINT32_MAX - 4
      ? registers.saved_esp + 4 : 0;
}

template <typename Reader>
bool ArmSiglusNativeMessageTicket(
    const SiglusNativeMessageLayout& layout,
    const SiglusNativeMessageSavedRegisters& registers, Reader& read,
    SiglusNativeMessageTicket* ticket) {
  if (ticket == nullptr) return false;
  *ticket = {};  // A fresh outer invocation always revokes the previous ticket.
  const uint32_t esp = SiglusNativeMessageEntryEsp(registers);
  if (layout.native_text_return == 0 || esp < 0x20 || (esp & 3u) != 0 ||
      esp > UINT32_MAX - 0xcu || !read(esp, &ticket->outer_return) ||
      ticket->outer_return == 0 ||
      !ReadSiglusMessageOwner(layout.owner, registers.ecx, read,
                             &ticket->snapshot)) return false;
  ticket->owner = registers.ecx;
  ticket->entry_esp = esp;
  ticket->armed = true;
  return true;
}

template <typename Reader>
bool ConsumeSiglusNativeMessageTicket(
    const SiglusNativeMessageLayout& layout,
    const SiglusNativeMessageSavedRegisters& registers, Reader& read,
    SiglusNativeMessageTicket* ticket, SiglusMessageOwnerSnapshot* frozen) {
  if (frozen != nullptr) *frozen = {};
  if (ticket == nullptr) return false;
  const SiglusNativeMessageTicket pending = *ticket;
  *ticket = {};  // Invalid/reentrant attempts consume too, never revive later.
  const uint32_t esp = SiglusNativeMessageEntryEsp(registers);
  if (!pending.armed || frozen == nullptr || esp == 0 || (esp & 3u) != 0 ||
      pending.entry_esp < 0x20 || pending.entry_esp > UINT32_MAX - 0xcu ||
      layout.native_text_return == 0 ||
      registers.ebx != pending.entry_esp - 4 ||
      registers.ecx != pending.entry_esp + 0xc ||
      registers.edi != pending.owner ||
      // Exact dynamic-alignment prologue, not the older Scenario EBP chain:
      // push ebx; EBX=ESP; sub ESP,8; and ESP,-8; add ESP,4; push ebp.
      registers.ebp != ((pending.entry_esp - 12) & ~7u) ||
      // The proved entry allocates/saves 0x5c bytes below EBP; the unique
      // direct NativeText call adds its four-byte return address.
      registers.ebp < 0x60 || esp != registers.ebp - 0x60) return false;
  uint32_t saved_ebx = 0, copied_return = 0, native_return = 0;
  if (!read(registers.ebp - 0x10, &saved_ebx) ||
      saved_ebx != registers.ebx ||
      !read(registers.ebp + 4, &copied_return) ||
      copied_return != pending.outer_return ||
      !read(esp, &native_return) || native_return != layout.native_text_return)
    return false;
  SiglusMessageOwnerSnapshot current{};
  if (!ReadSiglusMessageOwner(layout.owner, pending.owner, read, &current) ||
      current.voice_key != pending.snapshot.voice_key ||
      current.surface_index != pending.snapshot.surface_index ||
      current.surface_begin != pending.snapshot.surface_begin ||
      current.surface_end != pending.snapshot.surface_end ||
      current.surface != pending.snapshot.surface) return false;
  *frozen = current;
  // UINT32_MAX is a valid silent text occurrence; the audio worker rejects it.
  // Each outer invocation is one fragment, not an identity derived from owner,
  // stack address, key or text. Only the later committed TextSlot supplies its ID.
  return true;
}
}  // namespace fushi_voice_hook

#if defined(_MSC_VER) && defined(_M_IX86)
// observer is __stdcall(const SiglusNativeMessageSavedRegisters*). The pointer
// is callback-scoped; copy bounded scalars only. The trampoline alone owns ret.
#define FUSHI_SIGLUS_NATIVE_MESSAGE_THUNK(name, observer, original) \
  __declspec(naked) void name() {                                 \
    __asm { pushfd }                                              \
    __asm { pushad }                                              \
    __asm { mov ebx, esp }                                        \
    __asm { sub esp, 528 }                                        \
    __asm { and esp, -16 }                                        \
    __asm { fxsave [esp] }                                        \
    __asm { mov eax, fs:[34h] }                                   \
    __asm { mov [esp + 512], eax }                                \
    __asm { cld }                                                 \
    __asm { push ebx }                                            \
    __asm { call observer }                                       \
    __asm { mov eax, [esp + 512] }                                \
    __asm { mov fs:[34h], eax }                                   \
    __asm { fxrstor [esp] }                                       \
    __asm { mov esp, ebx }                                        \
    __asm { popad }                                               \
    __asm { popfd }                                               \
    __asm { jmp dword ptr [original] }                             \
  }
#endif
