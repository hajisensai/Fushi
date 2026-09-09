#pragma once

#include <cstdint>
#include <type_traits>

#include "siglus_message_capture.h"

namespace fushi_voice_hook::siglus_eightarg_message {

struct Layout {
  uint32_t message_return = 0;
  uint32_t scenario_return = 0;
};

struct Owner {
  uint32_t address, surface_index, surface_begin, surface_end, surface;
};

struct Ticket {
  bool armed;
  uint32_t entry_esp, outer_return, scenario_return;
  Owner owner;
};
static_assert(std::is_trivial<Ticket>::value);

template <typename Reader>
bool ReadOwner(uint32_t owner, Reader& read, Owner* out) {
  if (!out) return false;
  *out = {};
  Owner value{};
  uint32_t address = 0;
  if (owner < 0x10000u || (owner & 3u) != 0 ||
      !SiglusMessageCheckedAddress(owner, 0x160, &address) ||
      !read(address, &value.surface_index) ||
      !SiglusMessageCheckedAddress(owner, 0x1a8, &address) ||
      !read(address, &value.surface_begin) ||
      !SiglusMessageCheckedAddress(owner, 0x1ac, &address) ||
      !read(address, &value.surface_end) ||
      value.surface_begin < 0x10000u || (value.surface_begin & 3u) != 0 ||
      value.surface_end <= value.surface_begin) return false;
  const uint32_t span = value.surface_end - value.surface_begin;
  if (span % 0x124u != 0 || span / 0x124u > 256u ||
      value.surface_index >= span / 0x124u) return false;
  value.address = owner;
  value.surface = value.surface_begin + value.surface_index * 0x124u;
  *out = value;
  return true;
}

inline bool Same(const Owner& a, const Owner& b) {
  return a.address == b.address && a.surface_index == b.surface_index &&
      a.surface_begin == b.surface_begin && a.surface_end == b.surface_end &&
      a.surface == b.surface;
}

// The selected message owner is observed at the proved script call. Never
// evaluate the game's selector VM or treat an expression slot as a pointer.
template <typename Reader>
bool Arm(const Layout& layout, uint32_t owner, uint32_t entry_esp,
         Reader& read, Ticket* ticket) {
  if (!ticket) return false;
  *ticket = {};
  if (!layout.message_return || !layout.scenario_return || entry_esp < 0x20 ||
      entry_esp > UINT32_MAX - 0x24 || (entry_esp & 3u) != 0 ||
      !read(entry_esp, &ticket->outer_return) ||
      ticket->outer_return != layout.message_return ||
      !ReadOwner(owner, read, &ticket->owner)) return false;
  ticket->entry_esp = entry_esp;
  ticket->scenario_return = layout.scenario_return;
  ticket->armed = true;
  return true;
}

// This family calls Scenario directly from Message's EBP frame. The modern
// family's extra surface wrapper and the legacy FPO frame are incompatible.
// The consumer must still validate normal-render membership and copy the
// TextUnion bytes before queuing an occurrence; this ticket proves no audio.
template <typename Reader>
bool Consume(const Layout& layout, uint32_t surface, uint32_t entry_esp,
             uint32_t message_ebp, Reader& read, Ticket* ticket, Owner* out,
             uint32_t* text_union) {
  if (out) *out = {};
  if (text_union) *text_union = 0;
  if (!ticket) return false;
  const Ticket pending = *ticket;
  *ticket = {};
  if (!out || !text_union || !pending.armed || !layout.message_return ||
      !layout.scenario_return || pending.entry_esp < 0x20 ||
      pending.scenario_return != layout.scenario_return ||
      pending.entry_esp > UINT32_MAX - 0x24 || entry_esp < 0x10000u ||
      entry_esp > UINT32_MAX - 4 || message_ebp != pending.entry_esp - 4 ||
      entry_esp >= message_ebp || ((entry_esp | message_ebp) & 3u) != 0 ||
      surface != pending.owner.surface) return false;
  uint32_t scenario_return = 0, outer_return = 0, argument = 0;
  if (!read(entry_esp, &scenario_return) ||
      scenario_return != layout.scenario_return ||
      !read(pending.entry_esp, &outer_return) ||
      outer_return != pending.outer_return || outer_return != layout.message_return ||
      !read(entry_esp + 4, &argument) || argument != pending.entry_esp + 0xc)
    return false;
  Owner current{};
  if (!ReadOwner(pending.owner.address, read, &current) ||
      !Same(current, pending.owner)) return false;
  *out = current;
  *text_union = argument;
  return true;
}

}  // namespace fushi_voice_hook::siglus_eightarg_message
