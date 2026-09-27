#pragma once

// RealLive in-game lookup: pure, unit-tested half.
//
// Engine facts (RealLive.exe, x86, GDI; measured 2026-09-27 with Frida on the
// 智代アフター 2005 build — the sample only, never an identity input):
//   * One engine function renders one character into a 32-bit ARGB text
//     surface: TextRender(surface, 0, surface_w, surface_h, sjis_code, x, y,
//     colour*, shadow*, ...).  After its glyph-cache lookup it either reuses a
//     cached bitmap or rasterises one through GetGlyphOutlineA, and both paths
//     join at one block that reads the current font size global and turns the
//     pen (x, y) into the bitmap origin.  At that join the caller's arguments
//     sit at fixed stack offsets (four callee-saved pushes + 0x10 locals).
//     LunaHook's RealLive text hook patches the function entry and one call
//     site, so this provider never touches either: it detours the join only.
//   * A whole line is rendered into the surface up front; the typing reveal is
//     done by the compositor.  The compositor redraws dirty tiles of the
//     presented 800x600 screen buffer bottom-up (stage, then windows, then the
//     text surfaces), all through one generic blitter
//       Blit(dst, dst_w, dst_h, src, src_w, src_h, 0, 0, 1, dx, dy,
//            clip_x0, clip_y0, clip_x1, clip_y1, alpha)      (clip inclusive).
//     A glyph cell is visible iff the last blit that touched it came from its
//     own surface; hiding the message window re-blits the stage over the text
//     with no text blit after it.  Overlays drawn by other blitters are caught
//     at press time by comparing the glyph's opaque surface pixels with the
//     presented screen buffer (a revealed glyph matches verbatim).
//   * The screen buffer is presented 1:1 at the client origin
//     (SetDIBitsToDevice, 800x600), windowed and exclusive fullscreen alike;
//     a DPI-unaware process is then stretched by DWM to the physical client.
//   * Input: once per main-loop pass the engine fills a local 256-byte key
//     table from GetKeyboardState (only while its window is foreground, else it
//     zero-fills it) and derives every logical button from it.  Masking
//     VK_LBUTTON's high bit in that table from press to release means the
//     script never sees the click (measured: masked clicks do not advance).
//
// Every site, offset and global below is proven by a byte signature plus a
// structural cross-check (jump target, import slot, epilogue, callee
// prologue).  No hash, file name or title is consulted; anything missing or
// ambiguous installs nothing.

#include <windows.h>

#include <algorithm>
#include <array>
#include <cstddef>
#include <cstdint>
#include <cstring>

#include "exact_lookup_signature.h"
#include "../lookup_line_text_match.h"

namespace fushi_voice_hook::reallive_lookup {

namespace exact = fushi_voice_hook::exact_lookup;

// ── signature helpers ──────────────────────────────────────────────────────

template <size_t Size, size_t Ranges>
constexpr std::array<uint8_t, Size> WildcardMask(
    const size_t (&ranges)[Ranges][2]) {
  std::array<uint8_t, Size> mask = {};
  for (size_t index = 0u; index < Size; ++index) mask[index] = 0xffu;
  for (size_t range = 0u; range < Ranges; ++range) {
    for (size_t index = ranges[range][0];
         index < ranges[range][1] && index < Size; ++index) {
      mask[index] = 0u;
    }
  }
  return mask;
}

// ── engine layout ──────────────────────────────────────────────────────────

// TextRender stack frame at the glyph join (esp-relative, before the detour
// saves any register).
inline constexpr size_t kFrameSurfaceOffset = 0x24u;
inline constexpr size_t kFrameSurfaceWidthOffset = 0x2cu;
inline constexpr size_t kFrameSurfaceHeightOffset = 0x30u;
inline constexpr size_t kFrameCodeOffset = 0x34u;
inline constexpr size_t kFramePenXOffset = 0x38u;
inline constexpr size_t kFramePenYOffset = 0x3cu;
inline constexpr size_t kFrameBytes = 0x40u;

// Key poll join: the 256-byte GetKeyboardState table lives at esp+0x10.
inline constexpr size_t kKeyTableOffset = 0x10u;
inline constexpr uint8_t kKeyDownBit = 0x80u;

inline constexpr int32_t kMinFontSize = 4;   // the engine clamps to [4, 64]
inline constexpr int32_t kMaxFontSize = 64;
inline constexpr int32_t kMaxSurfaceSide = 4096;

// ── signatures ─────────────────────────────────────────────────────────────

// TextRender body after its (LunaHook-patched) entry: cache lookup call,
// `jne join` for a cache hit, rasteriser call for a miss.
inline constexpr uint8_t kGlyphPathBytes[] = {
    0x53, 0x55, 0x56, 0x8d, 0x44, 0x24, 0x18, 0x57, 0x8b, 0x7c, 0x24, 0x34,
    0x8d, 0x4c, 0x24, 0x18, 0x50, 0x8d, 0x54, 0x24, 0x14, 0x51, 0x8b, 0x0d,
    0x00, 0x00, 0x00, 0x00, 0x8d, 0x44, 0x24, 0x1c, 0x52, 0x8b, 0x15, 0x00,
    0x00, 0x00, 0x00, 0x50, 0xa1, 0x00, 0x00, 0x00, 0x00, 0x51, 0x52, 0x50,
    0x57, 0xe8, 0x00, 0x00, 0x00, 0x00, 0x8b, 0xf0, 0x83, 0xc4, 0x20, 0x85,
    0xf6, 0x75, 0x60, 0x8d, 0x4c, 0x24, 0x1c, 0x8d, 0x54, 0x24, 0x18, 0x51,
    0x52, 0x57, 0xe8, 0x00, 0x00, 0x00, 0x00, 0x8b, 0xf0, 0x83, 0xc4, 0x0c,
    0x85, 0xf6, 0x0f, 0x84};
inline constexpr size_t kGlyphPathWildcards[][2] = {
    {24u, 28u}, {35u, 39u}, {41u, 45u}, {50u, 54u}, {75u, 79u}};
inline constexpr auto kGlyphPathMask =
    WildcardMask<sizeof(kGlyphPathBytes)>(kGlyphPathWildcards);
inline constexpr size_t kGlyphPathSizeOperand = 41u;
inline constexpr size_t kGlyphPathCacheJump = 61u;  // `75 60`
inline constexpr size_t kGlyphPathRasterCall = 74u;

// The join both paths reach: font size global, then x at [esp+0x38] and y at
// [esp+0x3c] become the bitmap origin.
inline constexpr uint8_t kGlyphJoinBytes[] = {
    0xa1, 0x00, 0x00, 0x00, 0x00, 0x8b, 0x5c, 0x24, 0x1c, 0x8b,
    0x7c, 0x24, 0x38, 0x8b, 0x6c, 0x24, 0x18, 0x8b, 0xc8, 0x03,
    0xfd, 0x2b, 0xcb, 0x8b, 0x5c, 0x24, 0x3c, 0x03, 0xd9};
inline constexpr size_t kGlyphJoinWildcards[][2] = {{1u, 5u}};
inline constexpr auto kGlyphJoinMask =
    WildcardMask<sizeof(kGlyphJoinBytes)>(kGlyphJoinWildcards);
inline constexpr size_t kGlyphJoinSizeOperand = 1u;
// `pop edi; pop esi; pop ebp; pop ebx; add esp, 0x10; ret`: proves the frame
// the join offsets assume.
inline constexpr uint8_t kGlyphEpilogueBytes[] = {0x5f, 0x5e, 0x5d, 0x5b,
                                                  0x83, 0xc4, 0x10, 0xc3};
inline constexpr size_t kGlyphEpilogueScanBytes = 0x280u;
inline constexpr size_t kRasterScanBytes = 0x60u;

// Key poll: `call Focused; test eax,eax; je zero; lea eax,[esp+0x10]; push
// eax; call [GetKeyboardState]; jmp join; ... memset; add esp,0xc; join:`.
inline constexpr uint8_t kKeyPathBytes[] = {
    0xe8, 0x00, 0x00, 0x00, 0x00, 0x85, 0xc0, 0x74, 0x0d, 0x8d, 0x44, 0x24,
    0x10, 0x50, 0xff, 0x15, 0x00, 0x00, 0x00, 0x00, 0xeb, 0x13, 0x56, 0x8d,
    0x4c, 0x24, 0x14, 0x68, 0x00, 0x01, 0x00, 0x00, 0x51, 0xe8, 0x00, 0x00,
    0x00, 0x00, 0x83, 0xc4, 0x0c, 0x8a, 0x44, 0x24, 0x36, 0xb3, 0x80, 0x84,
    0xc3};
inline constexpr size_t kKeyPathWildcards[][2] = {
    {1u, 5u}, {16u, 20u}, {34u, 38u}};
inline constexpr auto kKeyPathMask =
    WildcardMask<sizeof(kKeyPathBytes)>(kKeyPathWildcards);
inline constexpr size_t kKeyPathFocusCall = 0u;
inline constexpr size_t kKeyPathKeyboardOperand = 16u;
inline constexpr size_t kKeyPathJoinJump = 20u;  // `eb 13`
inline constexpr size_t kKeyPathJoin = 41u;

// Focused(): `call [GetForegroundWindow]; cmp eax,[hwnd]; jne; mov eax,1; ret`.
inline constexpr uint8_t kFocusBytes[] = {0xff, 0x15, 0x00, 0x00, 0x00, 0x00,
                                          0x3b, 0x05, 0x00, 0x00, 0x00, 0x00,
                                          0x75, 0x06, 0xb8, 0x01, 0x00, 0x00,
                                          0x00, 0xc3};
inline constexpr size_t kFocusWildcards[][2] = {{2u, 6u}, {8u, 12u}};
inline constexpr auto kFocusMask =
    WildcardMask<sizeof(kFocusBytes)>(kFocusWildcards);
inline constexpr size_t kFocusForegroundOperand = 2u;
inline constexpr size_t kFocusWindowOperand = 8u;

// The message-window compositor call: Blit(screen, W, H, src, ...) with the
// screen buffer and its size read from their globals.
inline constexpr uint8_t kCompositeCallBytes[] = {
    0x6a, 0x01, 0x6a, 0x00, 0x6a, 0x00, 0x52, 0x8b, 0x15, 0x00,
    0x00, 0x00, 0x00, 0x50, 0xa1, 0x00, 0x00, 0x00, 0x00, 0x51,
    0x8b, 0x0d, 0x00, 0x00, 0x00, 0x00, 0x52, 0x50, 0x51, 0xe8,
    0x00, 0x00, 0x00, 0x00, 0x83, 0xc4, 0x40};
inline constexpr size_t kCompositeCallWildcards[][2] = {
    {9u, 13u}, {15u, 19u}, {22u, 26u}, {30u, 34u}};
inline constexpr auto kCompositeCallMask =
    WildcardMask<sizeof(kCompositeCallBytes)>(kCompositeCallWildcards);
inline constexpr size_t kCompositeHeightOperand = 9u;
inline constexpr size_t kCompositeWidthOperand = 15u;
inline constexpr size_t kCompositeScreenOperand = 22u;
inline constexpr size_t kCompositeBlitCall = 29u;
// Blit prologue: src (arg 4) null check.
inline constexpr uint8_t kBlitPrologueBytes[] = {
    0x8b, 0x44, 0x24, 0x10, 0x53, 0x55, 0x56, 0x85, 0xc0, 0x57, 0x0f, 0x84};

struct ImportSlots {
  uintptr_t get_keyboard_state = 0u;     // IAT slot RVAs
  uintptr_t get_foreground_window = 0u;
  uintptr_t get_glyph_outline = 0u;
};

struct Sites {
  uintptr_t glyph_join = 0u;      // mapped addresses (hook targets)
  uintptr_t raster = 0u;
  uintptr_t key_join = 0u;
  uintptr_t composite_blit = 0u;
  uintptr_t font_size_rva = 0u;   // data globals (RVAs)
  uintptr_t screen_bits_rva = 0u;
  uintptr_t screen_width_rva = 0u;
  uintptr_t screen_height_rva = 0u;
  uintptr_t window_rva = 0u;
};

enum class SiteResult : uint32_t {
  kResolved = 0u,
  kNotX86 = 1u,
  kImportsMissing = 2u,
  kGlyphPathMissing = 3u,
  kGlyphJoinInvalid = 4u,
  kGlyphFrameInvalid = 5u,
  kRasterInvalid = 6u,
  kKeyPathMissing = 7u,
  kFocusInvalid = 8u,
  kCompositeMissing = 9u,
  kBlitInvalid = 10u,
};

inline bool IsExecutableImageAddress(const exact::LoadedPeImage& image,
                                     uintptr_t address, size_t bytes) {
  uintptr_t rva = 0u;
  return exact::AddressToRva(image, address, &rva) &&
         exact::SectionHasRole(exact::FindSectionForRva(image, rva, bytes),
                               IMAGE_SCN_MEM_EXECUTE) &&
         exact::IsReadableSpan(reinterpret_cast<const void*>(address), bytes);
}

// An absolute operand naming a readable, non-executable data word.
inline bool DecodeDataGlobal(const exact::LoadedPeImage& image,
                             const uint8_t* operand, uintptr_t* rva) {
  uintptr_t target = 0u;
  return exact::DecodeAbsolute32ImageAddress(image, operand, &target, rva) &&
         exact::SectionHasRole(
             exact::FindSectionForRva(image, *rva, sizeof(uint32_t)),
             IMAGE_SCN_MEM_READ, IMAGE_SCN_MEM_EXECUTE);
}

inline bool OperandNamesSlot(const exact::LoadedPeImage& image,
                             const uint8_t* operand, uintptr_t slot_rva) {
  uintptr_t target = 0u;
  uintptr_t rva = 0u;
  return slot_rva != 0u &&
         exact::DecodeAbsolute32ImageAddress(image, operand, &target, &rva) &&
         rva == slot_rva;
}

inline bool MatchesAt(const uint8_t* candidate, const uint8_t* bytes,
                      const uint8_t* mask, size_t size) {
  if (!exact::IsReadableSpan(candidate, size)) return false;
  for (size_t index = 0u; index < size; ++index) {
    const uint8_t m = mask == nullptr ? 0xffu : mask[index];
    if ((candidate[index] & m) != (bytes[index] & m)) return false;
  }
  return true;
}

// True when `needle` occurs at least once in [begin, begin + bytes).
inline bool ContainsBytes(const uint8_t* begin, size_t bytes,
                          const uint8_t* needle, size_t size) {
  if (begin == nullptr || bytes < size ||
      !exact::IsReadableSpan(begin, bytes)) {
    return false;
  }
  for (size_t index = 0u; index + size <= bytes; ++index) {
    if (std::memcmp(begin + index, needle, size) == 0) return true;
  }
  return false;
}

// The rasteriser must load GetGlyphOutlineA from its import slot
// (`mov reg,[slot]` or `call [slot]`) within its first bytes.
inline bool RasterUsesGlyphOutline(const exact::LoadedPeImage& image,
                                   uintptr_t raster, uintptr_t slot_rva) {
  if (!IsExecutableImageAddress(image, raster, kRasterScanBytes)) return false;
  const auto* bytes = reinterpret_cast<const uint8_t*>(raster);
  for (size_t index = 0u; index + 6u <= kRasterScanBytes; ++index) {
    const bool load = bytes[index] == 0x8bu &&
                      (bytes[index + 1u] & 0xc7u) == 0x05u;  // mov r32,[abs]
    const bool call = bytes[index] == 0xffu && bytes[index + 1u] == 0x15u;
    if ((load || call) && OperandNamesSlot(image, bytes + index + 2u, slot_rva))
      return true;
  }
  return false;
}

// Resolves every site from structure alone.  Any missing or ambiguous proof
// returns a failure and leaves `sites` zeroed.
inline SiteResult ResolveSites(const exact::LoadedPeImage& image,
                               const ImportSlots& imports, Sites* sites) {
  if (sites == nullptr) return SiteResult::kGlyphPathMissing;
  *sites = {};
  if (image.machine != IMAGE_FILE_MACHINE_I386 || image.pointer_bits != 32u) {
    return SiteResult::kNotX86;
  }
  if (imports.get_keyboard_state == 0u ||
      imports.get_foreground_window == 0u || imports.get_glyph_outline == 0u) {
    return SiteResult::kImportsMissing;
  }
  Sites found;

  // ── text render: path → join → frame → rasteriser ──
  const exact::MaskedPattern path_pattern = {
      kGlyphPathBytes, kGlyphPathMask.data(), sizeof(kGlyphPathBytes)};
  const auto path =
      exact::FindUniquePatternInExecutableSections(image, path_pattern);
  if (path.count != 1u) return SiteResult::kGlyphPathMissing;
  const uint8_t* join = path.address + kGlyphPathCacheJump + 2u +
                        path.address[kGlyphPathCacheJump + 1u];
  if (!IsExecutableImageAddress(image, reinterpret_cast<uintptr_t>(join),
                                sizeof(kGlyphJoinBytes)) ||
      !MatchesAt(join, kGlyphJoinBytes, kGlyphJoinMask.data(),
                 sizeof(kGlyphJoinBytes)) ||
      std::memcmp(join + kGlyphJoinSizeOperand,
                  path.address + kGlyphPathSizeOperand, 4u) != 0 ||
      !DecodeDataGlobal(image, join + kGlyphJoinSizeOperand,
                        &found.font_size_rva)) {
    return SiteResult::kGlyphJoinInvalid;
  }
  if (!IsExecutableImageAddress(image, reinterpret_cast<uintptr_t>(join),
                                kGlyphEpilogueScanBytes) ||
      !ContainsBytes(join, kGlyphEpilogueScanBytes, kGlyphEpilogueBytes,
                     sizeof(kGlyphEpilogueBytes))) {
    return SiteResult::kGlyphFrameInvalid;
  }
  uintptr_t raster = 0u;
  if (!exact::DecodeRel32CallTarget(path.address + kGlyphPathRasterCall,
                                    &raster) ||
      !RasterUsesGlyphOutline(image, raster, imports.get_glyph_outline)) {
    return SiteResult::kRasterInvalid;
  }
  found.glyph_join = reinterpret_cast<uintptr_t>(join);
  found.raster = raster;

  // ── key poll: GetKeyboardState table join + Focused() → window global ──
  const exact::MaskedPattern key_pattern = {
      kKeyPathBytes, kKeyPathMask.data(), sizeof(kKeyPathBytes)};
  const auto key =
      exact::FindUniquePatternInExecutableSections(image, key_pattern);
  if (key.count != 1u ||
      !OperandNamesSlot(image, key.address + kKeyPathKeyboardOperand,
                        imports.get_keyboard_state) ||
      kKeyPathJoinJump + 2u + key.address[kKeyPathJoinJump + 1u] !=
          kKeyPathJoin) {
    return SiteResult::kKeyPathMissing;
  }
  uintptr_t focus = 0u;
  if (!exact::DecodeRel32CallTarget(key.address + kKeyPathFocusCall, &focus) ||
      !IsExecutableImageAddress(image, focus, sizeof(kFocusBytes)) ||
      !MatchesAt(reinterpret_cast<const uint8_t*>(focus), kFocusBytes,
                 kFocusMask.data(), sizeof(kFocusBytes)) ||
      !OperandNamesSlot(
          image,
          reinterpret_cast<const uint8_t*>(focus) + kFocusForegroundOperand,
          imports.get_foreground_window) ||
      !DecodeDataGlobal(
          image, reinterpret_cast<const uint8_t*>(focus) + kFocusWindowOperand,
          &found.window_rva)) {
    return SiteResult::kFocusInvalid;
  }
  found.key_join = reinterpret_cast<uintptr_t>(key.address + kKeyPathJoin);

  // ── compositor: blitter + screen buffer globals ──
  const exact::MaskedPattern composite_pattern = {
      kCompositeCallBytes, kCompositeCallMask.data(),
      sizeof(kCompositeCallBytes)};
  const auto composite =
      exact::FindUniquePatternInExecutableSections(image, composite_pattern);
  if (composite.count != 1u ||
      !DecodeDataGlobal(image, composite.address + kCompositeHeightOperand,
                        &found.screen_height_rva) ||
      !DecodeDataGlobal(image, composite.address + kCompositeWidthOperand,
                        &found.screen_width_rva) ||
      !DecodeDataGlobal(image, composite.address + kCompositeScreenOperand,
                        &found.screen_bits_rva)) {
    return SiteResult::kCompositeMissing;
  }
  uintptr_t blit = 0u;
  if (!exact::DecodeRel32CallTarget(composite.address + kCompositeBlitCall,
                                    &blit) ||
      !IsExecutableImageAddress(image, blit, sizeof(kBlitPrologueBytes)) ||
      std::memcmp(reinterpret_cast<const void*>(blit), kBlitPrologueBytes,
                  sizeof(kBlitPrologueBytes)) != 0) {
    return SiteResult::kBlitInvalid;
  }
  found.composite_blit = blit;
  *sites = found;
  return SiteResult::kResolved;
}

// ── import slots (x86 import directory) ────────────────────────────────────

inline const uint8_t* ImageBytesAt(const exact::LoadedPeImage& image,
                                   uint64_t rva, uint64_t bytes) {
  return image.base != nullptr && bytes != 0u && rva < image.size &&
                 bytes <= static_cast<uint64_t>(image.size) - rva
             ? image.base + rva
             : nullptr;
}

inline bool AsciiEqualsIgnoreCase(const exact::LoadedPeImage& image,
                                  uint64_t rva, const char* expected,
                                  bool ignore_case) {
  for (size_t index = 0u;; ++index) {
    const uint8_t* ch = ImageBytesAt(image, rva + index, 1u);
    if (ch == nullptr) return false;
    char lhs = static_cast<char>(*ch);
    char rhs = expected[index];
    if (ignore_case) {
      if (lhs >= 'A' && lhs <= 'Z') lhs = static_cast<char>(lhs - 'A' + 'a');
      if (rhs >= 'A' && rhs <= 'Z') rhs = static_cast<char>(rhs - 'A' + 'a');
    }
    if (lhs != rhs) return false;
    if (lhs == '\0') return true;
  }
}

// IAT slot RVA of `dll!symbol` (by name), or 0.
inline uintptr_t FindImportSlotRva(const exact::LoadedPeImage& image,
                                   const char* dll, const char* symbol) {
  const uint8_t* dos_bytes = ImageBytesAt(image, 0u, sizeof(IMAGE_DOS_HEADER));
  if (dos_bytes == nullptr || dll == nullptr || symbol == nullptr) return 0u;
  const auto* dos = reinterpret_cast<const IMAGE_DOS_HEADER*>(dos_bytes);
  if (dos->e_magic != IMAGE_DOS_SIGNATURE || dos->e_lfanew <= 0) return 0u;
  const uint8_t* nt_bytes = ImageBytesAt(
      image, static_cast<uint64_t>(dos->e_lfanew), sizeof(IMAGE_NT_HEADERS32));
  if (nt_bytes == nullptr) return 0u;
  const auto* nt = reinterpret_cast<const IMAGE_NT_HEADERS32*>(nt_bytes);
  if (nt->Signature != IMAGE_NT_SIGNATURE ||
      nt->OptionalHeader.Magic != IMAGE_NT_OPTIONAL_HDR32_MAGIC ||
      nt->OptionalHeader.NumberOfRvaAndSizes <= IMAGE_DIRECTORY_ENTRY_IMPORT) {
    return 0u;
  }
  const uint32_t directory =
      nt->OptionalHeader.DataDirectory[IMAGE_DIRECTORY_ENTRY_IMPORT]
          .VirtualAddress;
  if (directory == 0u) return 0u;
  for (uint32_t offset = 0u;; offset += sizeof(IMAGE_IMPORT_DESCRIPTOR)) {
    const uint8_t* bytes = ImageBytesAt(
        image, static_cast<uint64_t>(directory) + offset,
        sizeof(IMAGE_IMPORT_DESCRIPTOR));
    if (bytes == nullptr) return 0u;
    const auto* desc = reinterpret_cast<const IMAGE_IMPORT_DESCRIPTOR*>(bytes);
    if (desc->Name == 0u && desc->FirstThunk == 0u) return 0u;
    if (!AsciiEqualsIgnoreCase(image, desc->Name, dll, true)) continue;
    const uint32_t lookup = desc->OriginalFirstThunk != 0u
                                ? desc->OriginalFirstThunk
                                : desc->FirstThunk;
    if (lookup == 0u || desc->FirstThunk == 0u) return 0u;
    for (uint32_t index = 0u;; ++index) {
      const uint8_t* entry_bytes = ImageBytesAt(
          image, static_cast<uint64_t>(lookup) + index * 4u, 4u);
      if (entry_bytes == nullptr) return 0u;
      uint32_t entry = 0u;
      std::memcpy(&entry, entry_bytes, sizeof(entry));
      if (entry == 0u) break;
      if ((entry & IMAGE_ORDINAL_FLAG32) != 0u) continue;
      if (AsciiEqualsIgnoreCase(image, static_cast<uint64_t>(entry) + 2u,
                                symbol, false)) {
        return static_cast<uintptr_t>(desc->FirstThunk) + index * 4u;
      }
    }
  }
}

// ── glyph codes ────────────────────────────────────────────────────────────

// The render argument is a Shift_JIS code: one byte (ASCII / half-width
// katakana) or lead<<8|trail.  Anything that is not exactly one printable
// character decodes to 0 ("unknown"), which keeps the glyph out of every
// text match.
inline uint32_t DecodeGlyphCode(uint32_t code) {
  if (code == 0u || code > 0xffffu) return 0u;
  char bytes[2] = {};
  int length = 1;
  if (code <= 0xffu) {
    bytes[0] = static_cast<char>(code);
  } else {
    bytes[0] = static_cast<char>(code >> 8u);
    bytes[1] = static_cast<char>(code & 0xffu);
    length = 2;
  }
  wchar_t decoded[2] = {};
  if (MultiByteToWideChar(932, MB_ERR_INVALID_CHARS, bytes, length, decoded,
                          2) != 1) {
    return 0u;
  }
  const uint32_t scalar = decoded[0];
  if (scalar < 0x20u || (scalar >= 0x7fu && scalar <= 0x9fu) ||
      scalar == 0xfffdu || (scalar >= 0xd800u && scalar <= 0xdfffu)) {
    return 0u;
  }
  return scalar;
}

// Pen cell of one character: full width for a two-byte code, half width for
// a single-byte one; the line height is the font size.
inline int32_t GlyphCellWidth(uint32_t code, int32_t font_size) {
  const int32_t width = code > 0xffu ? font_size : font_size / 2;
  return width > 0 ? width : 1;
}

// ── game-thread glyph / composite tracker ──────────────────────────────────

inline constexpr size_t kMaxSurfaceGlyphs = 256u;
inline constexpr size_t kSurfaceSlots = 4u;

struct GlyphRecord {
  uint32_t codepoint = 0u;  // 0 = unknown
  uint32_t seq = 0u;
  int16_t x = 0;  // surface pixels
  int16_t y = 0;
  int16_t w = 0;
  int16_t h = 0;
  uint8_t visible = 0u;
};

struct SurfaceRecord {
  uintptr_t bits = 0u;
  int32_t width = 0;
  int32_t height = 0;
  int32_t origin_x = 0;  // screen position of surface (0, 0)
  int32_t origin_y = 0;
  bool placed = false;
  bool overflow = false;
  uint64_t touched = 0u;
  uint32_t count = 0u;
  std::array<GlyphRecord, kMaxSurfaceGlyphs> glyphs{};
};

struct CompositeBlit {
  uintptr_t dst = 0u;
  int32_t dst_w = 0;
  int32_t dst_h = 0;
  uintptr_t src = 0u;
  int32_t src_w = 0;
  int32_t src_h = 0;
  int32_t dx = 0;
  int32_t dy = 0;
  int32_t clip_x0 = 0;  // inclusive
  int32_t clip_y0 = 0;
  int32_t clip_x1 = 0;
  int32_t clip_y1 = 0;
};

struct IntRect {
  int32_t x0 = 0;  // inclusive-exclusive
  int32_t y0 = 0;
  int32_t x1 = 0;
  int32_t y1 = 0;
  bool Empty() const { return x1 <= x0 || y1 <= y0; }
  bool Intersects(const IntRect& other) const {
    return !Empty() && !other.Empty() && x0 < other.x1 && other.x0 < x1 &&
           y0 < other.y1 && other.y0 < y1;
  }
};

inline IntRect Intersect(const IntRect& a, const IntRect& b) {
  return {(std::max)(a.x0, b.x0), (std::max)(a.y0, b.y0),
          (std::min)(a.x1, b.x1), (std::min)(a.y1, b.y1)};
}

class GlyphTracker {
 public:
  void Clear() {
    for (auto& slot : slots_) slot = SurfaceRecord();
    clock_ = 0u;
    seq_ = 0u;
    ++version_;
  }

  // One rendered character.  Returns false when it cannot be tracked (bad
  // arguments, cell outside the surface); such a glyph is simply unknown.
  bool RecordGlyph(uintptr_t bits, int32_t width, int32_t height,
                   uint32_t code, int32_t x, int32_t y, int32_t font_size) {
    if (bits == 0u || width <= 0 || height <= 0 || width > kMaxSurfaceSide ||
        height > kMaxSurfaceSide || font_size < kMinFontSize ||
        font_size > kMaxFontSize) {
      return false;
    }
    const int32_t w = GlyphCellWidth(code, font_size);
    const int32_t h = font_size;
    if (x < 0 || y < 0 || x > width - w || y > height - h) return false;
    SurfaceRecord& slot = SlotFor(bits, width, height);
    const IntRect cell = {x, y, x + w, y + h};
    for (uint32_t index = 0u; index < slot.count; ++index) {
      const GlyphRecord& old = slot.glyphs[index];
      if (cell.Intersects({old.x, old.y, old.x + old.w, old.y + old.h})) {
        // Drawing over an existing cell means the buffer was cleared and a
        // new page is being rendered into it.
        slot.count = 0u;
        slot.overflow = false;
        break;
      }
    }
    slot.touched = ++clock_;
    ++version_;
    if (slot.count >= kMaxSurfaceGlyphs) {
      slot.overflow = true;
      return false;
    }
    GlyphRecord& out = slot.glyphs[slot.count++];
    out.codepoint = DecodeGlyphCode(code);
    out.seq = ++seq_;
    out.x = static_cast<int16_t>(x);
    out.y = static_cast<int16_t>(y);
    out.w = static_cast<int16_t>(w);
    out.h = static_cast<int16_t>(h);
    out.visible = 0u;
    return true;
  }

  // One blit into some buffer.  Only blits into the presented screen buffer
  // change visibility: the source's own glyphs inside the drawn region become
  // visible, every other tracked glyph there is covered.
  bool RecordComposite(const CompositeBlit& blit, uintptr_t screen_bits,
                       int32_t screen_w, int32_t screen_h) {
    if (blit.dst == 0u || blit.dst != screen_bits || blit.dst_w != screen_w ||
        blit.dst_h != screen_h || screen_w <= 0 || screen_h <= 0 ||
        blit.src_w <= 0 || blit.src_h <= 0) {
      return false;
    }
    const IntRect clip = {blit.clip_x0, blit.clip_y0, blit.clip_x1 + 1,
                          blit.clip_y1 + 1};
    const IntRect source = {blit.dx, blit.dy, blit.dx + blit.src_w,
                            blit.dy + blit.src_h};
    const IntRect drawn =
        Intersect(Intersect(clip, source), {0, 0, screen_w, screen_h});
    if (drawn.Empty()) return false;
    bool changed = false;
    for (auto& slot : slots_) {
      if (slot.bits == 0u) continue;
      const bool own = slot.bits == blit.src && slot.width == blit.src_w &&
                       slot.height == blit.src_h;
      if (own && (!slot.placed || slot.origin_x != blit.dx ||
                  slot.origin_y != blit.dy)) {
        slot.placed = true;
        slot.origin_x = blit.dx;
        slot.origin_y = blit.dy;
        for (uint32_t index = 0u; index < slot.count; ++index) {
          slot.glyphs[index].visible = 0u;
        }
        changed = true;
      }
      if (!slot.placed) continue;
      for (uint32_t index = 0u; index < slot.count; ++index) {
        GlyphRecord& glyph = slot.glyphs[index];
        const IntRect cell = {slot.origin_x + glyph.x, slot.origin_y + glyph.y,
                              slot.origin_x + glyph.x + glyph.w,
                              slot.origin_y + glyph.y + glyph.h};
        if (!cell.Intersects(drawn)) continue;
        const uint8_t visible = own ? 1u : 0u;
        if (glyph.visible != visible) {
          glyph.visible = visible;
          changed = true;
        }
      }
    }
    if (changed) ++version_;
    return changed;
  }

  const std::array<SurfaceRecord, kSurfaceSlots>& slots() const {
    return slots_;
  }
  uint64_t version() const { return version_; }

 private:
  SurfaceRecord& SlotFor(uintptr_t bits, int32_t width, int32_t height) {
    SurfaceRecord* victim = &slots_[0];
    for (auto& slot : slots_) {
      if (slot.bits == bits && slot.width == width && slot.height == height) {
        return slot;
      }
      if (slot.bits == 0u) {
        victim = &slot;
        break;
      }
      if (slot.touched < victim->touched) victim = &slot;
    }
    // A buffer at a reused address with another size, or a new buffer: start
    // clean; it is unplaced until the compositor blits it.
    *victim = SurfaceRecord();
    victim->bits = bits;
    victim->width = width;
    victim->height = height;
    return *victim;
  }

  std::array<SurfaceRecord, kSurfaceSlots> slots_{};
  uint64_t clock_ = 0u;
  uint32_t seq_ = 0u;
  uint64_t version_ = 0u;
};

// ── selected text → one surface's visible glyphs ───────────────────────────

inline constexpr uint16_t kNoSource = 0xffffu;

struct LineGlyph {
  uint32_t codepoint = 0u;
  int32_t x = 0;  // screen (design) pixels
  int32_t y = 0;
  int32_t w = 0;
  int32_t h = 0;
  int32_t local_x = 0;  // surface pixels
  int32_t local_y = 0;
  uint16_t source_index = kNoSource;
  uint8_t source_length = 0u;
};

// Visible glyphs of one placed surface, in render order, with each cell
// trimmed to the pen advance of its right neighbour on the same row (the
// engine's letter spacing can be tighter than the font size, and overlapping
// cells would make a press between two characters ambiguous).
inline size_t CollectVisibleGlyphs(const SurfaceRecord& slot, LineGlyph* out,
                                   size_t capacity) {
  if (out == nullptr || !slot.placed || slot.overflow) return 0u;
  size_t count = 0u;
  for (uint32_t index = 0u; index < slot.count && count < capacity; ++index) {
    const GlyphRecord& glyph = slot.glyphs[index];
    if (glyph.visible == 0u) continue;
    int32_t w = glyph.w;
    if (index + 1u < slot.count) {
      const GlyphRecord& next = slot.glyphs[index + 1u];
      if (next.y == glyph.y && next.x > glyph.x && next.x < glyph.x + w) {
        w = next.x - glyph.x;
      }
    }
    LineGlyph& line = out[count++];
    line.codepoint = glyph.codepoint;
    line.local_x = glyph.x;
    line.local_y = glyph.y;
    line.x = slot.origin_x + glyph.x;
    line.y = slot.origin_y + glyph.y;
    line.w = w;
    line.h = glyph.h;
    line.source_index = kNoSource;
    line.source_length = 0u;
  }
  return count;
}

// The selected LunaHook line is the most recent sentence of the page, i.e.
// the render-order suffix of the page's visible glyphs.  Match it
// whitespace-insensitively; the whole line must be consumed and every glyph
// of it must be visible.  Glyphs before the match stay unmapped.  Returns
// the index of the first mapped glyph, or `count` when there is no match.
inline size_t MapSelectedSuffix(LineGlyph* glyphs, size_t count,
                                const wchar_t* selected,
                                size_t selected_count) {
  if (glyphs == nullptr || selected == nullptr || count == 0u ||
      selected_count == 0u || selected_count >= kNoSource) {
    return count;
  }
  for (size_t index = 0u; index < count; ++index) {
    glyphs[index].source_index = kNoSource;
    glyphs[index].source_length = 0u;
  }
  // Any failure leaves every glyph unmapped: a partial suffix match must not
  // leave stale mappings behind for the hit test.
  auto fail = [glyphs, count]() {
    for (size_t index = 0u; index < count; ++index) {
      glyphs[index].source_index = kNoSource;
      glyphs[index].source_length = 0u;
    }
    return count;
  };
  size_t source = selected_count;
  size_t glyph = count;
  bool any = false;
  for (;;) {
    while (source > 0u && IsLookupLineWhitespace(selected[source - 1u])) {
      --source;
    }
    if (source == 0u) break;
    if (glyph == 0u) return fail();
    const uint32_t codepoint = glyphs[glyph - 1u].codepoint;
    if (codepoint == 0u || codepoint > 0xffffu) return fail();
    const wchar_t unit = static_cast<wchar_t>(codepoint);
    if (IsLookupLineWhitespace(unit)) {
      --glyph;
      continue;
    }
    if (selected[source - 1u] != unit) return fail();
    --source;
    glyphs[glyph - 1u].source_index = static_cast<uint16_t>(source);
    glyphs[glyph - 1u].source_length = 1u;
    any = true;
    --glyph;
  }
  if (!any) return fail();
  return glyph;
}

// ── projection and hit testing ─────────────────────────────────────────────

struct PixelRect {
  int32_t x = 0;
  int32_t y = 0;
  int32_t w = 0;
  int32_t h = 0;
};

// Screen (design) pixels -> physical client pixels.  The screen buffer is
// presented 1:1 at the client origin, so the engine's logical client must be
// exactly the screen size; DWM's DPI stretch scales both axes uniformly.
// Rounds outward; the result must lie inside the physical client.
inline bool ProjectCell(const LineGlyph& glyph, int32_t screen_w,
                        int32_t screen_h, int32_t physical_w,
                        int32_t physical_h, PixelRect* out) {
  if (out == nullptr || screen_w <= 0 || screen_h <= 0 || physical_w <= 0 ||
      physical_h <= 0 || glyph.w <= 0 || glyph.h <= 0 || glyph.x < 0 ||
      glyph.y < 0 || glyph.x + glyph.w > screen_w ||
      glyph.y + glyph.h > screen_h) {
    return false;
  }
  const double sx = static_cast<double>(physical_w) / screen_w;
  const double sy = static_cast<double>(physical_h) / screen_h;
  const int32_t x0 = static_cast<int32_t>(glyph.x * sx);
  const int32_t y0 = static_cast<int32_t>(glyph.y * sy);
  const double right = (glyph.x + glyph.w) * sx;
  const double bottom = (glyph.y + glyph.h) * sy;
  int32_t x1 = static_cast<int32_t>(right);
  int32_t y1 = static_cast<int32_t>(bottom);
  if (x1 < right) ++x1;
  if (y1 < bottom) ++y1;
  if (x1 > physical_w || y1 > physical_h || x1 - x0 < 1 || y1 - y0 < 1) {
    return false;
  }
  *out = {x0, y0, x1 - x0, y1 - y0};
  return true;
}

// The single mapped glyph whose screen cell contains (x, y); none or more
// than one is a miss.
inline bool HitTestLine(const LineGlyph* glyphs, size_t count, int32_t x,
                        int32_t y, size_t* hit) {
  if (glyphs == nullptr || hit == nullptr) return false;
  size_t found = count;
  for (size_t index = 0u; index < count; ++index) {
    const LineGlyph& glyph = glyphs[index];
    if (glyph.source_index == kNoSource) continue;
    if (x < glyph.x || y < glyph.y || x >= glyph.x + glyph.w ||
        y >= glyph.y + glyph.h) {
      continue;
    }
    if (found != count) return false;
    found = index;
  }
  if (found == count) return false;
  *hit = found;
  return true;
}

// Press-time presentation proof: the glyph's fully opaque surface pixels must
// appear verbatim (RGB) in the presented screen buffer.  A glyph that is not
// yet revealed, hidden, or under any overlay fails.  Both buffers are 32-bit,
// top-down, stride = width.
struct PresentationCount {
  uint32_t opaque = 0u;
  uint32_t matched = 0u;
};

inline PresentationCount CountPresentedPixels(
    const uint32_t* surface, int32_t surface_w, int32_t surface_h,
    const uint32_t* screen, int32_t screen_w, int32_t screen_h,
    int32_t origin_x, int32_t origin_y, int32_t local_x, int32_t local_y,
    int32_t w, int32_t h) {
  PresentationCount count;
  if (surface == nullptr || screen == nullptr || w <= 0 || h <= 0 ||
      local_x < 0 || local_y < 0 || local_x + w > surface_w ||
      local_y + h > surface_h || origin_x + local_x < 0 ||
      origin_y + local_y < 0 || origin_x + local_x + w > screen_w ||
      origin_y + local_y + h > screen_h) {
    return count;
  }
  for (int32_t row = 0; row < h; ++row) {
    const uint32_t* src =
        surface + static_cast<size_t>(local_y + row) * surface_w + local_x;
    const uint32_t* dst = screen +
                          static_cast<size_t>(origin_y + local_y + row) *
                              screen_w +
                          origin_x + local_x;
    for (int32_t column = 0; column < w; ++column) {
      const uint32_t pixel = src[column];
      if ((pixel >> 24u) != 0xffu) continue;
      ++count.opaque;
      if (((pixel ^ dst[column]) & 0x00ffffffu) == 0u) ++count.matched;
    }
  }
  return count;
}

inline constexpr uint32_t kMinOpaquePixels = 4u;

inline bool GlyphPresented(const PresentationCount& count) {
  return count.opaque >= kMinOpaquePixels &&
         count.matched * 10u >= count.opaque * 9u;
}

// ── game-thread click claim ────────────────────────────────────────────────

struct ClaimState {
  bool owned = false;
  bool was_down = false;
};

struct ClaimDecision {
  bool fresh_press = false;  // caller must evaluate eligibility
  bool mask = false;         // clear VK_LBUTTON's high bit in the key table
  bool submit = false;       // queue the resolved glyph for the worker
};

// Two-step reducer.  `Observe` tells the caller whether this sample is a new
// press (the only moment eligibility is evaluated); `Decide` then owns a
// claimed press until the button is up again, masking every sample in
// between so the engine never sees either edge.
inline bool IsFreshPress(uint8_t raw, const ClaimState& claim) {
  return (raw & kKeyDownBit) != 0u && !claim.was_down && !claim.owned;
}

inline ClaimDecision DecideLeftButton(uint8_t raw, bool eligible,
                                      ClaimState* claim) {
  ClaimDecision decision;
  if (claim == nullptr) return decision;
  const bool down = (raw & kKeyDownBit) != 0u;
  decision.fresh_press = down && !claim->was_down && !claim->owned;
  if (claim->owned) {
    if (down) {
      decision.mask = true;
    } else {
      claim->owned = false;
    }
  } else if (decision.fresh_press && eligible) {
    claim->owned = true;
    decision.mask = true;
    decision.submit = true;
  }
  claim->was_down = down;
  return decision;
}

}  // namespace fushi_voice_hook::reallive_lookup
