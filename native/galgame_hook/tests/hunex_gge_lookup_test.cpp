// Release builds define NDEBUG. Undefine it before every include so these
// assertions remain executable focused test code.
#undef NDEBUG

#include <cassert>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <vector>

#include "../hook/adapters/hunex_gge_lookup.h"
#include "../include/hunex_gge_trace.h"

namespace lookup = fushi_voice_hook::hunex_lookup;

static_assert(sizeof(fushi_voice_hook::HunexGgeTraceEvent) == 240u);
static_assert(offsetof(fushi_voice_hook::HunexGgeTraceEvent,
                       draw_arg12_bits) == 32u);
static_assert(offsetof(fushi_voice_hook::HunexGgeTraceEvent, caller_rva) ==
              48u);
static_assert(offsetof(fushi_voice_hook::HunexGgeTraceEvent, glyph_ordinal) ==
              60u);
static_assert(offsetof(fushi_voice_hook::HunexGgeTraceEvent,
                       utf16_char_index) == 64u);
static_assert(offsetof(fushi_voice_hook::HunexGgeTraceEvent, draw_arg13) ==
              76u);
static_assert(sizeof(fushi_voice_hook::HunexGgeTraceSlot) == 248u);
static_assert(offsetof(fushi_voice_hook::HunexGgeTraceBuffer, slots) == 120u);

namespace {

void Append(std::vector<uint8_t>* out, const uint8_t* bytes, size_t count) {
  out->insert(out->end(), bytes, bytes + count);
}

void TestUniqueMaskedPatternsFailClosed() {
  std::vector<uint8_t> code(17u, 0xccu);
  const size_t draw_at = code.size();
  Append(&code, lookup::kDrawEntryBytes, sizeof(lookup::kDrawEntryBytes));
  code.insert(code.end(), 9u, 0xccu);
  auto match = lookup::FindUniqueMaskedPattern(
      code.data(), code.size(), lookup::kDrawEntryPattern);
  assert(match.count == 1u);
  assert(match.offset == draw_at);

  code[draw_at + 3u] ^= 1u;
  match = lookup::FindUniqueMaskedPattern(code.data(), code.size(),
                                          lookup::kDrawEntryPattern);
  assert(match.count == 0u);
  assert(match.offset == lookup::kInvalidOffset);

  code[draw_at + 3u] ^= 1u;
  Append(&code, lookup::kDrawEntryBytes, sizeof(lookup::kDrawEntryBytes));
  match = lookup::FindUniqueMaskedPattern(code.data(), code.size(),
                                          lookup::kDrawEntryPattern);
  assert(match.count == 2u);
  assert(match.offset == lookup::kInvalidOffset);
}

void TestRel32CallGraphRequiresExactlyTwoCalls() {
  std::vector<uint8_t> code(256u, 0x90u);
  const uintptr_t target = reinterpret_cast<uintptr_t>(code.data() + 220u);
  const size_t first = 24u;
  const size_t second = 144u;
  for (const size_t call_at : {first, second}) {
    code[call_at] = 0xe8u;
    const intptr_t after =
        reinterpret_cast<intptr_t>(code.data() + call_at + 5u);
    const int32_t displacement = static_cast<int32_t>(
        static_cast<intptr_t>(target) - after);
    std::memcpy(code.data() + call_at + 1u, &displacement,
                sizeof(displacement));
  }
  uintptr_t first_return = 0u;
  uintptr_t second_return = 0u;
  assert(lookup::FindRel32CallReturnsToTarget(
             code.data(), 200u, target, &first_return, &second_return) == 2u);
  assert(first_return == reinterpret_cast<uintptr_t>(code.data() + first + 5u));
  assert(second_return ==
         reinterpret_cast<uintptr_t>(code.data() + second + 5u));

  code[second] = 0x90u;
  assert(lookup::FindRel32CallReturnsToTarget(
             code.data(), 200u, target, &first_return, &second_return) == 1u);
  assert(second_return == 0u);
}

void TestInputCallShapesMaskOnlyDisplacements() {
  std::vector<uint8_t> generic(
      lookup::kGenericKeyPollBytes,
      lookup::kGenericKeyPollBytes + sizeof(lookup::kGenericKeyPollBytes));
  std::vector<uint8_t> left(
      lookup::kLeftButtonPollBytes,
      lookup::kLeftButtonPollBytes + sizeof(lookup::kLeftButtonPollBytes));
  generic[23u] = 0x12u;
  generic[24u] = 0x34u;
  generic[29u] = 0x56u;
  left[7u] = 0x78u;
  assert(lookup::FindUniqueMaskedPattern(
             generic.data(), generic.size(),
             lookup::kGenericKeyPollPattern)
             .count == 1u);
  assert(lookup::FindUniqueMaskedPattern(
             left.data(), left.size(), lookup::kLeftButtonPollPattern)
             .count == 1u);
  generic[22u] = 0x14u;
  left[6u] = 0x14u;
  assert(lookup::FindUniqueMaskedPattern(
             generic.data(), generic.size(),
             lookup::kGenericKeyPollPattern)
             .count == 0u);
  assert(lookup::FindUniqueMaskedPattern(
             left.data(), left.size(), lookup::kLeftButtonPollPattern)
             .count == 0u);
}

void TestRipIndirectCallSlotDecode() {
  alignas(8) uint8_t storage[96] = {};
  uint8_t* call = storage + 8u;
  void** slot = reinterpret_cast<void**>(storage + 64u);
  *slot = reinterpret_cast<void*>(static_cast<uintptr_t>(0x12345678u));
  call[0] = 0xffu;
  call[1] = 0x15u;
  const intptr_t after = reinterpret_cast<intptr_t>(call + 6u);
  const int32_t displacement = static_cast<int32_t>(
      reinterpret_cast<intptr_t>(slot) - after);
  std::memcpy(call + 2u, &displacement, sizeof(displacement));
  uintptr_t decoded_slot = 0u;
  uintptr_t decoded_return = 0u;
  assert(lookup::DecodeRipIndirectCallSlot(
      call, &decoded_slot, &decoded_return));
  assert(decoded_slot == reinterpret_cast<uintptr_t>(slot));
  assert(decoded_return == reinterpret_cast<uintptr_t>(call + 6u));
  call[1] = 0x25u;
  assert(!lookup::DecodeRipIndirectCallSlot(
      call, &decoded_slot, &decoded_return));
}

void TestInputTraceStateChangesOnly() {
  uint32_t previous = 0u;
  assert(lookup::IsInputTraceStateChange(previous, 0));
  previous = lookup::EncodeInputTraceState(0);
  assert(!lookup::IsInputTraceStateChange(previous, 0));
  assert(lookup::IsInputTraceStateChange(
      previous, static_cast<int16_t>(0x8000u)));
  previous = lookup::EncodeInputTraceState(static_cast<int16_t>(0x8000u));
  assert(!lookup::IsInputTraceStateChange(previous,
                                          static_cast<int16_t>(0x8000u)));
  assert(lookup::IsInputTraceStateChange(previous, 1));
  previous = lookup::EncodeInputTraceState(1);
  assert(!lookup::IsInputTraceStateChange(previous, 1));
  assert(lookup::IsInputTraceStateChange(previous, 0));
}

void TestGlyphTraceOrdinalsAndUtf16Pairing() {
  lookup::GlyphTraceCursor cursor;
  auto position = lookup::ObserveGlyphTraceCall(&cursor, true, 1u);
  assert(position.valid);
  assert(position.glyph_ordinal == 0u);
  assert(position.utf16_char_index == 0u);

  position = lookup::ObserveGlyphTraceCall(&cursor, false, 1u);
  assert(position.valid);
  assert(position.glyph_ordinal == 1u);
  assert(position.utf16_char_index == 0u);

  position = lookup::ObserveGlyphTraceCall(&cursor, true, 2u);
  assert(position.valid);
  assert(position.glyph_ordinal == 2u);
  assert(position.utf16_char_index == 1u);

  position = lookup::ObserveGlyphTraceCall(&cursor, false, 2u);
  assert(position.valid);
  assert(position.glyph_ordinal == 3u);
  assert(position.utf16_char_index == 1u);

  position = lookup::ObserveGlyphTraceCall(&cursor, true, 1u);
  assert(position.valid);
  assert(position.glyph_ordinal == 4u);
  assert(position.utf16_char_index == 3u);

  lookup::GlyphTraceCursor orphan_cursor;
  position = lookup::ObserveGlyphTraceCall(&orphan_cursor, false, 1u);
  assert(!position.valid);
  assert(orphan_cursor.next_glyph_ordinal == 0u);
  assert(orphan_cursor.next_utf16_char_index == 0u);
}

}  // namespace

int main() {
  TestUniqueMaskedPatternsFailClosed();
  TestRel32CallGraphRequiresExactlyTwoCalls();
  TestInputCallShapesMaskOnlyDisplacements();
  TestRipIndirectCallSlotDecode();
  TestInputTraceStateChangesOnly();
  TestGlyphTraceOrdinalsAndUtf16Pairing();
  return 0;
}
