#pragma once

#include <array>
#include <cstddef>
#include <cstdint>

#include "exact_lookup_signature.h"
#include "leaf_aquaplus_lookup.h"

namespace fushi_voice_hook {

inline constexpr uint16_t kLeafAquaplusPeMachineI386 = 0x014cu;
inline constexpr std::array<const wchar_t*, 2>
    kWhiteAlbum2LeafVoiceArchiveRelativePaths = {
        L"VOICE.PAK",
        L"IC\\VOICE.PAK",
};

// "Leaf" is only a LunaHook family label.  Runtime admission stays pinned to
// one measured executable; neither WA2.exe nor the surrounding *.pak files are
// sufficient to enable binary offsets in an unknown build.
struct LeafAquaplusProfile {
  std::array<uint8_t, 32> executable_sha256 = {};
  uint16_t pe_machine = 0;
  uint8_t pointer_bits = 0;
  uintptr_t d3d9_device_pointer_rva = 0;
  uintptr_t stack_cookie_rva = 0;
  uintptr_t get_async_key_state_iat_rva = 0;
  uintptr_t read_file_iat_rva = 0;
  uintptr_t embed_leaf_hook_rva = 0;
  uintptr_t input_poller_first_return_rva = 0;
  uintptr_t input_poller_last_return_rva = 0;
  uintptr_t text_traversal_rva = 0;
  uintptr_t raster_draw_rva = 0;
  uintptr_t glyph_dispatch_rva = 0;
  uintptr_t raster_glyph_return_rva = 0;
  uint32_t raster_parent_return_stack_offset = 0;
  uint32_t raster_packed_cp932_stack_offset = 0;
  uintptr_t glyph_single_return_rva = 0;
  uintptr_t glyph_double_first_return_rva = 0;
  uintptr_t glyph_double_second_return_rva = 0;
  uintptr_t quad_draw_return_rva = 0;
  uint32_t quad_vertex_stride = 0;
  uint32_t quad_fvf = 0;
  uintptr_t alternate_quad_draw_return_rva = 0;
  uint32_t alternate_quad_vertex_stride = 0;
  uint32_t alternate_quad_fvf = 0;
  uintptr_t voice_archive_read_return_rva = 0;
};

inline constexpr LeafAquaplusProfile kWhiteAlbum2LeafAquaplusProfile = {
    {0x00, 0x5e, 0x71, 0x10, 0x7e, 0xd7, 0x0e, 0x66, 0x2c, 0x41, 0xcb,
     0x52, 0x68, 0x79, 0xcd, 0xcf, 0x0b, 0x94, 0x86, 0xe0, 0x67, 0xc0,
     0xe5, 0xa3, 0x06, 0x30, 0x86, 0x88, 0xc1, 0x74, 0x09, 0xed},
    kLeafAquaplusPeMachineI386,
    32u,
    0x734430u, // IDirect3DDevice9* at VA 0x00b34430.
    0x0d1630u, // /GS cookie at relocated VA 0x004d1630.
    0x0a134cu, // GetAsyncKeyState IAT slot at VA 0x004a134c.
    0x0a10a4u, // ReadFile IAT slot at VA 0x004a10a4.
    0x0512bfu, // selected HSX0:0 hook at VA 0x004512bf.
    0x04a83eu, // first GetAsyncKeyState return at VA 0x0044a83e.
    0x04a9b4u, // last GetAsyncKeyState return at VA 0x0044a9b4.
    0x0462c0u, // one 26-dword text-object traversal at VA 0x004462c0.
    0x03b590u, // raster/atlas draw at VA 0x0043b590.
    0x0460a0u, // glyph dispatch called by the admitted single/double paths.
    0x0462b7u, // admitted 0x0043b590 caller inside the text traversal.
    0x00cu,    // parent 0x4460a0 return at return-address slot + 0x0c.
    0x110u,    // packed CP932 at _AddressOfReturnAddress() + 0x110.
    0x046f72u, // admitted single-byte 0x4460a0 return.
    0x0470c2u, // admitted first double-byte 0x4460a0 return.
    0x047185u, // admitted second double-byte 0x4460a0 return.
    0x03dd19u, // glyph DrawPrimitiveUP return inside VA 0x0043b590.
    0x20u,     // XYZRHW glyph vertex stride.
    0x01c4u,   // D3DFVF_XYZRHW | DIFFUSE | SPECULAR | TEX1.
    0x03c968u, // alternate text-descriptor DrawPrimitiveUP return.
    0x28u,     // alternate XYZRHW vertex stride.
    0x02c4u,   // alternate exact FVF observed at the descriptor path.
    0x059142u, // synchronous VOICE.PAK ReadFile return at VA 0x00459142.
};

inline bool MatchesLeafAquaplusDigest(const LeafAquaplusProfile &profile,
                                      const uint8_t *observed_sha256,
                                      size_t digest_bytes) {
  if (observed_sha256 == nullptr ||
      digest_bytes != profile.executable_sha256.size()) {
    return false;
  }
  uint8_t difference = 0;
  for (size_t index = 0; index < digest_bytes; ++index) {
    difference |= static_cast<uint8_t>(observed_sha256[index] ^
                                       profile.executable_sha256[index]);
  }
  return difference == 0;
}

inline bool MatchesLeafAquaplusProfile(const LeafAquaplusProfile &profile,
                                       const uint8_t *executable_sha256,
                                       size_t digest_bytes,
                                       uint16_t pe_machine) {
  if (pe_machine != profile.pe_machine || profile.pointer_bits != 32u ||
      profile.d3d9_device_pointer_rva == 0 ||
      profile.stack_cookie_rva == 0 ||
      profile.get_async_key_state_iat_rva == 0 ||
      profile.read_file_iat_rva == 0 ||
      profile.embed_leaf_hook_rva == 0 || profile.text_traversal_rva == 0 ||
      profile.raster_draw_rva == 0 || profile.glyph_dispatch_rva == 0 ||
      profile.raster_glyph_return_rva == 0 ||
      profile.raster_parent_return_stack_offset == 0 ||
      profile.raster_packed_cp932_stack_offset == 0 ||
      profile.glyph_single_return_rva == 0 ||
      profile.glyph_double_first_return_rva == 0 ||
      profile.glyph_double_second_return_rva == 0 ||
      profile.input_poller_first_return_rva == 0 ||
      profile.input_poller_last_return_rva <
          profile.input_poller_first_return_rva ||
      profile.quad_draw_return_rva == 0 || profile.quad_vertex_stride == 0 ||
      profile.quad_fvf == 0 || profile.alternate_quad_draw_return_rva == 0 ||
      profile.alternate_quad_vertex_stride == 0 ||
      profile.alternate_quad_fvf == 0 ||
      profile.voice_archive_read_return_rva == 0) {
    return false;
  }
  return MatchesLeafAquaplusDigest(profile, executable_sha256, digest_bytes);
}

namespace leaf_exact {

// The A1 operand is loader-relocated. Matching its preferred VA made the
// helper accidentally dependent on where this process was loaded. Wildcard it
// and require the hydrated operand to resolve to profile.stack_cookie_rva.
inline constexpr uint8_t kTextTraversalEntryBytes[] = {
    0x81, 0xec, 0x3c, 0x01, 0x00, 0x00, 0xa1, 0x00, 0x00, 0x00, 0x00,
    0x33, 0xc4, 0x89, 0x84, 0x24, 0x38, 0x01, 0x00, 0x00, 0x8b, 0x8c,
    0x24, 0x6c, 0x01, 0x00, 0x00, 0x8b, 0x84, 0x24, 0x5c, 0x01, 0x00,
    0x00,
};
inline constexpr auto kTextTraversalEntryMask =
    exact_lookup::MaskExceptRanges<sizeof(kTextTraversalEntryBytes)>(7u, 11u);
inline constexpr exact_lookup::MaskedPattern kTextTraversalEntryPattern = {
    kTextTraversalEntryBytes, kTextTraversalEntryMask.data(),
    sizeof(kTextTraversalEntryBytes)};
inline constexpr size_t kTextTraversalCookieOperandOffset = 7u;

inline constexpr uint8_t kRasterDrawEntryBytes[] = {
    0x55, 0x8b, 0xec, 0x83, 0xe4, 0xf8, 0xb8, 0xa4, 0x16, 0x00, 0x00,
    0xe8, 0x00, 0x00, 0x00, 0x00, 0xa1, 0x00, 0x00, 0x00, 0x00,
    0x33, 0xc4, 0x89, 0x84, 0x24, 0xa0, 0x16, 0x00, 0x00, 0x83,
    0x3d, 0x00, 0x00, 0x00, 0x00, 0x00, 0x53, 0x56, 0x8b, 0x75,
    0x08, 0x57, 0x8b, 0x7d, 0x0c,
};
inline constexpr auto kRasterDrawEntryMask =
    exact_lookup::MaskExceptRanges<sizeof(kRasterDrawEntryBytes)>(
        12u, 16u, 17u, 21u, 32u, 36u);
inline constexpr exact_lookup::MaskedPattern kRasterDrawEntryPattern = {
    kRasterDrawEntryBytes, kRasterDrawEntryMask.data(),
    sizeof(kRasterDrawEntryBytes)};
inline constexpr size_t kRasterDrawCookieOperandOffset = 17u;

inline constexpr uint8_t kInputPollerEntryBytes[] = {
    0x8b, 0x35, 0x00, 0x00, 0x00, 0x00, 0x6a, 0x01, 0xff, 0xd6,
    0xb9, 0x01, 0x80, 0x00, 0x00, 0x66, 0x85, 0xc1, 0x0f, 0x95,
    0xc0, 0xa2, 0x00, 0x00, 0x00, 0x00, 0x84, 0xc0, 0x0f, 0x85,
    0x00, 0x00, 0x00, 0x00,
};
inline constexpr auto kInputPollerEntryMask =
    exact_lookup::MaskExceptRanges<sizeof(kInputPollerEntryBytes)>(
        2u, 6u, 22u, 26u, 30u, 34u);
inline constexpr exact_lookup::MaskedPattern kInputPollerEntryPattern = {
    kInputPollerEntryBytes, kInputPollerEntryMask.data(),
    sizeof(kInputPollerEntryBytes)};
inline constexpr size_t kInputPollerIatOperandOffset = 2u;

// The selected HSX0:0 hook is 23 bytes into this uniquely measured loop
// anchor. Keeping the stable object-field and NUL-scan context prevents the
// common `sub eax, ebx` body from becoming a signature by itself.
inline constexpr uint8_t kEmbedLoopAnchorBytes[] = {
    0x8b, 0x90, 0xc0, 0x8c, 0x00, 0x00, 0x8b, 0x84, 0x97,
    0x14, 0x08, 0x00, 0x00, 0x8d, 0x58, 0x01, 0x8a, 0x10,
    0x40, 0x84, 0xd2, 0x75, 0xf9, 0x2b, 0xc3,
};
inline constexpr exact_lookup::MaskedPattern kEmbedLoopAnchorPattern = {
    kEmbedLoopAnchorBytes, nullptr, sizeof(kEmbedLoopAnchorBytes)};
inline constexpr size_t kEmbedHookOffsetFromAnchor = 23u;

// This is the only admitted access path that loads the IDirect3DDevice9
// global immediately before the vtable dispatch. Loader-relocated absolute
// operands are wildcarded; the A1 operand must decode back to the exact
// profile's module-relative device slot.
inline constexpr uint8_t kD3dDeviceAccessBytes[] = {
    0xa1, 0x00, 0x00, 0x00, 0x00, 0x8b, 0x08, 0x8b, 0x91,
    0x98, 0x00, 0x00, 0x00, 0x68, 0x00, 0x00, 0x00, 0x00,
    0x6a, 0x00, 0x50, 0xc7, 0x05, 0x00, 0x00, 0x00, 0x00,
    0x01, 0x00, 0x00, 0x00, 0xff, 0xd2,
};
inline constexpr auto kD3dDeviceAccessMask =
    exact_lookup::MaskExceptRanges<sizeof(kD3dDeviceAccessBytes)>(
        1u, 5u, 14u, 18u, 23u, 27u);
inline constexpr exact_lookup::MaskedPattern kD3dDeviceAccessPattern = {
    kD3dDeviceAccessBytes, kD3dDeviceAccessMask.data(),
    sizeof(kD3dDeviceAccessBytes)};
inline constexpr size_t kD3dDevicePointerOperandOffset = 1u;

}  // namespace leaf_exact

} // namespace fushi_voice_hook
