#pragma once

#include <array>
#include <cstddef>
#include <cstdint>

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
  uintptr_t embed_leaf_hook_rva = 0;
  uintptr_t input_poller_first_return_rva = 0;
  uintptr_t input_poller_last_return_rva = 0;
  uintptr_t text_traversal_rva = 0;
  uintptr_t raster_draw_rva = 0;
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
    0x0512bfu, // selected HSX0:0 hook at VA 0x004512bf.
    0x04a83eu, // first GetAsyncKeyState return at VA 0x0044a83e.
    0x04a9b4u, // last GetAsyncKeyState return at VA 0x0044a9b4.
    0x0462c0u, // one 26-dword text-object traversal at VA 0x004462c0.
    0x03b590u, // raster/atlas draw at VA 0x0043b590.
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
      profile.embed_leaf_hook_rva == 0 || profile.text_traversal_rva == 0 ||
      profile.raster_draw_rva == 0 || profile.raster_glyph_return_rva == 0 ||
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

} // namespace fushi_voice_hook
