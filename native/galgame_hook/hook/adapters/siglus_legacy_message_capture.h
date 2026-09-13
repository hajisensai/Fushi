#pragma once

#include <tuple>
#include "siglus_native_message_capture.h"

namespace fushi_voice_hook {
// Use the existing full-register naked thunk. saved_esp is the pushfd ESP;
// never recover original EDI/EBX/EBP from ordinary C++ register allocation.
using SiglusLegacyMessageSavedRegisters = SiglusNativeMessageSavedRegisters;

struct SiglusLegacyMessageLayout {
  uint32_t script_slot = 0;  // Absolute address from the admitted image profile.
  uint32_t text_return = 0;
  uint32_t max_text_units = 2048;  // Copy budget, not an engine format limit.
};
struct SiglusLegacyMessageSnapshot {
  uint32_t script, voice_key, voice_second;
  uint8_t voice_flag;
  // These are the prior owner values: the wrapper writes this occurrence's
  // script key to owner+0x120 AFTER the inner text function returns.
  uint32_t prior_owner_key;
  uint8_t prior_owner_flag;
  uint32_t text_address, text_units, text_capacity;
  uint32_t scalar1, scalar2;
  uint8_t argument_flag;
};
struct SiglusLegacyMessageTicket {
  bool armed;
  uint32_t owner, entry_esp, outer_return;
  uint32_t saved_edi, saved_esi, saved_ebp, saved_ebx;
  uint32_t script_slot, text_return, max_text_units;
  SiglusLegacyMessageSnapshot snapshot;
};
struct SiglusLegacyMessageOccurrence {
  uint32_t owner, string_object;
  SiglusLegacyMessageSnapshot snapshot;
};
static_assert(std::is_trivial<SiglusLegacyMessageSnapshot>::value);
static_assert(std::is_trivial<SiglusLegacyMessageTicket>::value);

namespace siglus_legacy_message_capture {
template <typename Reader, typename T>
bool Read(Reader& read, uint32_t base, uint32_t offset, T* out) {
  static_assert(sizeof(T) == 1 || sizeof(T) == 4);
  if (base == 0 || offset > UINT32_MAX - base ||
      sizeof(T) - 1 > UINT32_MAX - base - offset ||
      (sizeof(T) == 4 && ((base + offset) & 3u) != 0)) return false;
  return read(base + offset, out, sizeof(T));
}
inline auto Identity(const SiglusLegacyMessageSnapshot& s) {
  return std::tie(s.script, s.voice_key, s.voice_second, s.voice_flag,
      s.prior_owner_key, s.prior_owner_flag, s.text_address, s.text_units,
      s.text_capacity, s.scalar1, s.scalar2, s.argument_flag);
}
template <typename Reader>
bool Snapshot(const SiglusLegacyMessageLayout& layout, uint32_t owner,
              uint32_t esp, Reader& read, SiglusLegacyMessageSnapshot* out) {
  SiglusLegacyMessageSnapshot s{};
  if (!Read(read, layout.script_slot, 0, &s.script) || s.script == 0 ||
      (s.script & 3u) != 0 ||
      !Read(read, s.script, 0x19c, &s.voice_key) ||
      !Read(read, s.script, 0x1a0, &s.voice_second) ||
      !Read(read, s.script, 0x1a4, &s.voice_flag) ||
      !Read(read, owner, 0x120, &s.prior_owner_key) ||
      !Read(read, owner, 0x124, &s.prior_owner_flag) ||
      !Read(read, esp, 0x18, &s.text_units) ||
      !Read(read, esp, 0x1c, &s.text_capacity) ||
      !Read(read, esp, 0x20, &s.scalar1) ||
      !Read(read, esp, 0x24, &s.scalar2) ||
      !Read(read, esp, 0x28, &s.argument_flag) ||
      s.text_units == 0 || s.text_units > layout.max_text_units ||
      s.text_units > s.text_capacity || s.text_capacity < 7) return false;
  if (s.text_capacity < 8) {
    if (esp > UINT32_MAX - 8) return false;
    s.text_address = esp + 8;
  } else if (!Read(read, esp, 8, &s.text_address)) return false;
  // A WCHAR buffer includes the terminator. Do not read payload here; the
  // caller must bounded-copy from the proven inner text object before return.
  if (s.text_address == 0 || (s.text_address & 1u) != 0 ||
      static_cast<uint64_t>(s.text_address) +
          2ull * (static_cast<uint64_t>(s.text_capacity) + 1) >
              static_cast<uint64_t>(UINT32_MAX) + 1) return false;
  *out = s;
  return true;
}
}  // namespace siglus_legacy_message_capture

// Caller owns one ticket per OS thread and clears it on session/installation
// change. Every outer invocation revokes a previous ticket, even at the same
// stack address. There is no deduplication by owner/key/ESP or wall clock.
// Reader must be bounded, nonthrowing and SEH-protected in production.
// Two passes reject observed drift; no engine epoch exists here to detect an
// ABA change wholly between reads. The caller copies text at this inner entry,
// and must not treat the snapshot as a durable pointer after callback return.
template <typename Reader>
bool ArmSiglusLegacyMessageTicket(const SiglusLegacyMessageLayout& layout,
    const SiglusLegacyMessageSavedRegisters& registers, Reader& read,
    SiglusLegacyMessageTicket* ticket) {
  using namespace siglus_legacy_message_capture;
  if (ticket == nullptr) return false;
  *ticket = {};
  const uint32_t esp = SiglusNativeMessageEntryEsp(registers);
  if (esp < 0x68 || esp > UINT32_MAX - 0x28 || (esp & 3u) != 0 ||
      registers.ecx == 0 || (registers.ecx & 3u) != 0 ||
      layout.script_slot == 0 || layout.text_return == 0 ||
      layout.max_text_units == 0) return false;
  uint32_t outer_return = 0, second_return = 0;
  SiglusLegacyMessageSnapshot first{}, second{};
  if (!Read(read, esp, 0, &outer_return) || outer_return == 0 ||
      !Snapshot(layout, registers.ecx, esp, read, &first) ||
      !Snapshot(layout, registers.ecx, esp, read, &second) ||
      !Read(read, esp, 0, &second_return) || outer_return != second_return ||
      Identity(first) != Identity(second)) return false;
  ticket->owner = registers.ecx;
  ticket->entry_esp = esp;
  ticket->outer_return = outer_return;
  ticket->saved_edi = registers.edi;
  ticket->saved_esi = registers.esi;
  ticket->saved_ebp = registers.ebp;
  ticket->saved_ebx = registers.ebx;
  ticket->script_slot = layout.script_slot;
  ticket->text_return = layout.text_return;
  ticket->max_text_units = layout.max_text_units;
  ticket->snapshot = second;
  ticket->armed = true;
  return true;
}

template <typename Reader>
bool ConsumeSiglusLegacyMessageTicket(const SiglusLegacyMessageLayout& layout,
    const SiglusLegacyMessageSavedRegisters& registers, Reader& read,
    SiglusLegacyMessageTicket* ticket, SiglusLegacyMessageOccurrence* out) {
  using namespace siglus_legacy_message_capture;
  if (out != nullptr) *out = {};
  if (ticket == nullptr) return false;
  const SiglusLegacyMessageTicket pending = *ticket;
  *ticket = {};  // Failure/reentry consumes too; an old invocation never revives.
  const uint32_t esp = SiglusNativeMessageEntryEsp(registers);
  const uint32_t outer = pending.entry_esp;
  if (!pending.armed || out == nullptr || outer < 0x68 ||
      outer > UINT32_MAX - 0x28 || layout.script_slot != pending.script_slot ||
      layout.text_return != pending.text_return ||
      layout.max_text_units != pending.max_text_units ||
      esp != outer - 0x68 || registers.ecx != outer + 4 ||
      registers.edi != pending.owner || registers.esi != 0 ||
      registers.ebx != pending.snapshot.scalar1 ||
      registers.ebp != pending.snapshot.scalar2) return false;
  uint32_t value = 0;
  if (!Read(read, esp, 0, &value) || value != layout.text_return ||
      !Read(read, outer, 0, &value) || value != pending.outer_return ||
      !Read(read, outer - 0x60, 0, &value) || value != pending.saved_edi ||
      !Read(read, outer - 0x5c, 0, &value) || value != pending.saved_esi ||
      !Read(read, outer - 0x58, 0, &value) || value != pending.saved_ebp ||
      !Read(read, outer - 0x54, 0, &value) || value != pending.saved_ebx)
    return false;
  SiglusLegacyMessageSnapshot first{}, second{};
  if (!Snapshot(layout, pending.owner, outer, read, &first) ||
      !Snapshot(layout, pending.owner, outer, read, &second) ||
      Identity(first) != Identity(pending.snapshot) ||
      Identity(first) != Identity(second)) return false;
  out->owner = pending.owner;
  out->string_object = outer + 4;
  out->snapshot = second;
  // UINT32_MAX is a legal silent occurrence. Only a committed TextSlot assigns
  // event identity; source observation and audio binding are separate gates.
  return true;
}
}  // namespace fushi_voice_hook
