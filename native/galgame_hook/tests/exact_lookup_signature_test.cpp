#include <windows.h>

#ifdef NDEBUG
#undef NDEBUG
#endif
#include <cassert>
#include <cstdint>
#include <cstring>

#include "exact_lookup_signature.h"
#include "leaf_aquaplus_profile.h"
#include "sgre_lookup.h"
#include "siglus_lookup.h"

namespace {

using fushi_voice_hook::exact_lookup::LoadedPeImage;
using fushi_voice_hook::exact_lookup::MaskedPattern;

class ExecutableTestPage {
 public:
  ExecutableTestPage() {
    bytes = static_cast<uint8_t*>(VirtualAlloc(
        nullptr, 4096u, MEM_RESERVE | MEM_COMMIT, PAGE_EXECUTE_READWRITE));
    assert(bytes != nullptr);
    std::memset(bytes, 0xcc, 4096u);
  }

  ~ExecutableTestPage() {
    if (bytes != nullptr) VirtualFree(bytes, 0u, MEM_RELEASE);
  }

  ExecutableTestPage(const ExecutableTestPage&) = delete;
  ExecutableTestPage& operator=(const ExecutableTestPage&) = delete;

  uint8_t* bytes = nullptr;
};

LoadedPeImage TwoSectionImage(uint8_t* base, bool second_executable = true) {
  LoadedPeImage image;
  image.base = base;
  image.size = 4096u;
  image.machine = sizeof(void*) == 8u ? IMAGE_FILE_MACHINE_AMD64
                                      : IMAGE_FILE_MACHINE_I386;
  image.pointer_bits = static_cast<uint8_t>(sizeof(void*) * 8u);
  image.section_count = 2u;
  image.sections[0] = {base, 128u, 0u,
                       IMAGE_SCN_MEM_READ | IMAGE_SCN_MEM_EXECUTE};
  image.sections[1] = {
      base + 128u, 128u, 128u,
      IMAGE_SCN_MEM_READ |
          (second_executable ? IMAGE_SCN_MEM_EXECUTE : IMAGE_SCN_MEM_WRITE)};
  return image;
}

void WriteRel32Call(uint8_t* call, const uint8_t* target) {
  call[0] = 0xe8u;
  const intptr_t distance = reinterpret_cast<intptr_t>(target) -
                            (reinterpret_cast<intptr_t>(call) + 5);
  assert(distance >= INT32_MIN && distance <= INT32_MAX);
  const int32_t displacement = static_cast<int32_t>(distance);
  std::memcpy(call + 1u, &displacement, sizeof(displacement));
}

}  // namespace

int main() {
  using namespace fushi_voice_hook;
  using namespace fushi_voice_hook::exact_lookup;

  ExecutableTestPage page;
  LoadedPeImage image = TwoSectionImage(page.bytes);
  constexpr uint8_t pattern_bytes[] = {0xaau, 0x00u, 0xccu, 0xddu};
  constexpr uint8_t pattern_mask[] = {0xffu, 0x00u, 0xffu, 0xffu};
  const MaskedPattern pattern = {pattern_bytes, pattern_mask,
                                 sizeof(pattern_bytes)};

  const uint8_t first_candidate[] = {0xaau, 0x51u, 0xccu, 0xddu};
  std::memcpy(page.bytes + 16u, first_candidate, sizeof(first_candidate));
  auto match = FindUniquePatternInExecutableSections(image, pattern);
  assert(match.count == 1u && match.address == page.bytes + 16u);

  // A matching non-executable data section is not a code candidate.
  image.sections[1].characteristics = IMAGE_SCN_MEM_READ | IMAGE_SCN_MEM_WRITE;
  std::memcpy(page.bytes + 160u, first_candidate, sizeof(first_candidate));
  match = FindUniquePatternInExecutableSections(image, pattern);
  assert(match.count == 1u && match.address == page.bytes + 16u);

  // The same bytes in any second executable section make the whole image
  // ambiguous. The sole expected-RVA section is intentionally insufficient.
  image.sections[1].characteristics =
      IMAGE_SCN_MEM_READ | IMAGE_SCN_MEM_EXECUTE;
  match = FindUniquePatternInExecutableSections(image, pattern);
  assert(match.count == 2u && match.address == nullptr);
  std::memset(page.bytes + 160u, 0xcc, sizeof(first_candidate));

  // Duplicate candidates inside one executable section fail the same way.
  std::memcpy(page.bytes + 32u, first_candidate, sizeof(first_candidate));
  match = FindUniquePatternInExecutableSections(image, pattern);
  assert(match.count == 2u && match.address == nullptr);
  std::memset(page.bytes + 32u, 0xcc, sizeof(first_candidate));

  // An uninspectable executable section cannot be silently treated as empty;
  // it may contain the missing second candidate.
  void* no_access = VirtualAlloc(nullptr, 4096u, MEM_RESERVE | MEM_COMMIT,
                                 PAGE_NOACCESS);
  assert(no_access != nullptr);
  image.section_count = 3u;
  image.sections[2] = {static_cast<const uint8_t*>(no_access), 4096u, 256u,
                       IMAGE_SCN_MEM_EXECUTE};
  match = FindUniquePatternInExecutableSections(image, pattern);
  assert(match.count == 2u && match.address == nullptr);
  image.section_count = 2u;
  VirtualFree(no_access, 0u, MEM_RELEASE);

  // Relocation masks do not relax decoded-target validation.
  constexpr uint8_t rip_bytes[] = {0x48u, 0x8du, 0x05u, 0u, 0u, 0u, 0u,
                                    0x90u};
  constexpr uint8_t rip_mask[] = {0xffu, 0xffu, 0xffu, 0u,
                                   0u,    0u,    0u,    0xffu};
  const MaskedPattern rip_pattern = {rip_bytes, rip_mask, sizeof(rip_bytes)};
  auto* rip_candidate = page.bytes + 48u;
  std::memcpy(rip_candidate, rip_bytes, sizeof(rip_bytes));
  const uintptr_t expected_rip_target =
      reinterpret_cast<uintptr_t>(page.bytes + 112u);
  const int32_t rip_displacement = static_cast<int32_t>(
      expected_rip_target - reinterpret_cast<uintptr_t>(rip_candidate + 7u));
  std::memcpy(rip_candidate + 3u, &rip_displacement, sizeof(rip_displacement));
  match = FindUniqueRipRelativePatternInExecutableSections(
      image, rip_pattern, 0u, 3u, 7u, expected_rip_target);
  assert(match.count == 1u && match.address == rip_candidate);
  match = FindUniqueRipRelativePatternInExecutableSections(
      image, rip_pattern, 0u, 3u, 7u, expected_rip_target + 1u);
  assert(match.count == 0u && match.address == nullptr);
  auto* second_rip_candidate = page.bytes + 160u;
  std::memcpy(second_rip_candidate, rip_bytes, sizeof(rip_bytes));
  const int32_t second_rip_displacement = static_cast<int32_t>(
      expected_rip_target + 1u -
      reinterpret_cast<uintptr_t>(second_rip_candidate + 7u));
  std::memcpy(second_rip_candidate + 3u, &second_rip_displacement,
              sizeof(second_rip_displacement));
  match = FindUniqueRipRelativePatternInExecutableSections(
      image, rip_pattern, 0u, 3u, 7u, expected_rip_target);
  assert(match.count == 2u && match.address == nullptr);
  std::memset(second_rip_candidate, 0xcc, sizeof(rip_bytes));

  // Internal call-graph gates require both the caller and target to be in
  // executable PE sections and bind the return to the exact target RVA.
  auto* rel32_call = page.bytes + 72u;
  auto* rel32_target = page.bytes + 104u;
  WriteRel32Call(rel32_call, rel32_target);
  assert(MatchesRel32CallEndingAt(image, 77u, 104u));
  assert(!MatchesRel32CallEndingAt(image, 77u, 105u));
  assert(MatchesExecutableCallEndingAt(image, 77u));
  page.bytes[88u] = 0xffu;
  page.bytes[89u] = 0xd0u;
  assert(MatchesRegisterIndirectCallEndingAt(image, 90u, 0xd0u));
  assert(MatchesExecutableCallEndingAt(image, 90u));

#if !defined(_WIN64)
  // x86 absolute operands are loader-relocated VAs. The signature wildcards
  // the operand, then constrains it to a module-relative target.
  constexpr uint8_t absolute_bytes[] = {0xa1u, 0u, 0u, 0u, 0u, 0x85u, 0xc0u};
  constexpr uint8_t absolute_mask[] = {0xffu, 0u, 0u, 0u,
                                       0u,    0xffu, 0xffu};
  const MaskedPattern absolute_pattern = {
      absolute_bytes, absolute_mask, sizeof(absolute_bytes)};
  auto* absolute_candidate = page.bytes + 8u;
  std::memcpy(absolute_candidate, absolute_bytes, sizeof(absolute_bytes));
  const uintptr_t absolute_target =
      reinterpret_cast<uintptr_t>(page.bytes + 192u);
  const uint32_t encoded_target = static_cast<uint32_t>(absolute_target);
  std::memcpy(absolute_candidate + 1u, &encoded_target,
              sizeof(encoded_target));
  match = FindUniqueAbsolute32PatternInExecutableSections(
      image, absolute_pattern, 1u, absolute_target);
  assert(match.count == 1u && match.address == absolute_candidate);
  match = FindUniqueAbsolute32PatternInExecutableSections(
      image, absolute_pattern, 1u, absolute_target + 1u);
  assert(match.count == 0u && match.address == nullptr);
  auto* second_absolute_candidate = page.bytes + 160u;
  std::memcpy(second_absolute_candidate, absolute_bytes,
              sizeof(absolute_bytes));
  const uint32_t second_encoded_target =
      static_cast<uint32_t>(absolute_target + 1u);
  std::memcpy(second_absolute_candidate + 1u, &second_encoded_target,
              sizeof(second_encoded_target));
  match = FindUniqueAbsolute32PatternInExecutableSections(
      image, absolute_pattern, 1u, absolute_target);
  assert(match.count == 2u && match.address == nullptr);
  std::memset(second_absolute_candidate, 0xcc, sizeof(absolute_bytes));
#endif

  // Leaf's A1 cookie operand must remain wildcarded: ASLR changes the
  // hydrated VA, not the admitted function identity.
  uint8_t leaf_traversal[sizeof(leaf_exact::kTextTraversalEntryBytes)] = {};
  std::memcpy(leaf_traversal, leaf_exact::kTextTraversalEntryBytes,
              sizeof(leaf_traversal));
  leaf_traversal[7] = 0x78u;
  leaf_traversal[8] = 0x56u;
  leaf_traversal[9] = 0x34u;
  leaf_traversal[10] = 0x12u;
  assert(MatchesMaskedPattern(leaf_traversal,
                              leaf_exact::kTextTraversalEntryPattern));
  leaf_traversal[11] ^= 1u;
  assert(!MatchesMaskedPattern(leaf_traversal,
                               leaf_exact::kTextTraversalEntryPattern));

  uint8_t siglus_glyph[sizeof(siglus_exact::kGlyphLayoutEntryBytes)] = {};
  std::memcpy(siglus_glyph, siglus_exact::kGlyphLayoutEntryBytes,
              sizeof(siglus_glyph));
  siglus_glyph[siglus_exact::kGlyphLayoutStackByteOffset] = 0xecu;
  assert(MatchesMaskedPattern(siglus_glyph,
                              siglus_exact::kGlyphLayoutEntryPattern));
  assert(siglus_exact::IsMeasuredGlyphStackSize(siglus_glyph));
  siglus_glyph[siglus_exact::kGlyphLayoutStackByteOffset] = 0xfcu;
  assert(MatchesMaskedPattern(siglus_glyph,
                              siglus_exact::kGlyphLayoutEntryPattern));
  assert(!siglus_exact::IsMeasuredGlyphStackSize(siglus_glyph));
  assert(siglus_exact::InputMessagePatternForProfile(
             kAnemoiSiglusLookupProfile) ==
         &siglus_exact::kAnemoiInputMessageEntryPattern);
  assert(siglus_exact::InputMessagePatternForProfile(
             kSummerPocketsReflectionBlueSiglusLookupProfile) ==
         &siglus_exact::kSprbInputMessageEntryPattern);

  // The strengthened SGRE entry deliberately includes enough ABI context to
  // distinguish the measured draw routine from its duplicate short prologue.
  assert(sgre_exact::kTextDrawEntryPattern.size >= 64u);
  assert(MatchesMaskedPattern(sgre_exact::kTextDrawEntryBytes,
                              sgre_exact::kTextDrawEntryPattern));

  return 0;
}
