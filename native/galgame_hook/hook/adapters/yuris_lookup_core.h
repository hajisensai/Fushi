#pragma once

// YU-RIS message text lane + in-game lookup: pure, unit-tested half.
//
// Engine facts (x86, Watcom register convention; read from a 2011 v500 build
// and a 2016 v481 build — the samples only, never an identity input):
//   * A message is tokenised into per-character ops when its text command
//     runs.  A message state object S (a global pointer) holds the text
//     bytes the ops consume (S+T, CP932, display characters only), the byte
//     index of the next character (S+TI), the op index (S+IDX), per-op word
//     arrays (font size at S+SZ, ...) and the pen (S+X, S+X+4) in the text
//     layer's pixels.  [S] is the text layer object.
//   * Every displayed character goes through one engine function DRAW
//     (register args), called from a handful of sites that all read the
//     character into a global 2-byte buffer, call DRAW and then advance the
//     pen by its return value: `call DRAW; mov edx,[S]; add [edx+X],eax`.
//     DRAW rasterises through a function that calls TextOutA.
//   * Input: once per frame the engine runs a loop over virtual keys 1..7
//     (`mov ebx,1; movzx edx,byte[ebx+K]; sar edx,7; ...; call [T+..]`)
//     over the table GetKeyboardState filled (`push K; call [GetKeyboardState]`).
//     Masking VK_LBUTTON's high bit in K before that loop hides the click
//     from the engine.
//
// Every site, offset and global below is proven by a byte signature plus a
// structural cross-check (call target, import slot, matching globals across
// sites).  No hash, file name or title is consulted; anything missing or
// ambiguous installs nothing.

#include <windows.h>

#include <algorithm>
#include <array>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <string>

#include "../lookup_line_text_match.h"

namespace fushi_voice_hook::yuris_lookup {

inline constexpr size_t kMaxTextBytes = 1024u;
inline constexpr size_t kMaxCells = 256u;
inline constexpr size_t kMaxDrawSites = 8u;
inline constexpr int32_t kMaxCellSide = 512;
inline constexpr int32_t kMinDesignSide = 64;
inline constexpr int32_t kMaxDesignSide = 8192;
inline constexpr uint8_t kKeyDownBit = 0x80u;
inline constexpr uint16_t kNoSource = 0xffffu;

// ── image view ─────────────────────────────────────────────────────────────

// A loaded (or synthetic) x86 image: bytes at RVA 0.., absolute operands are
// relative to `va_base`.  Executable ranges bound every scan.
struct ImageView {
  const uint8_t* bytes = nullptr;
  size_t size = 0u;
  uint32_t va_base = 0u;
  struct Range {
    uint32_t begin = 0u;
    uint32_t end = 0u;
  };
  std::array<Range, 8> code{};
  size_t code_count = 0u;
};

inline bool InCode(const ImageView& image, uint32_t rva, uint32_t bytes) {
  for (size_t i = 0u; i < image.code_count; ++i) {
    const auto& r = image.code[i];
    if (rva >= r.begin && rva <= r.end && bytes <= r.end - rva) return true;
  }
  return false;
}

inline uint32_t U32(const ImageView& image, uint32_t rva) {
  if (rva > image.size || image.size - rva < 4u) return 0u;
  uint32_t v = 0u;
  std::memcpy(&v, image.bytes + rva, 4u);
  return v;
}

inline uint8_t U8(const ImageView& image, uint32_t rva) {
  return rva < image.size ? image.bytes[rva] : 0u;
}

// Absolute VA operand -> RVA inside the image (0 when outside).
inline uint32_t VaToRva(const ImageView& image, uint32_t va) {
  if (va < image.va_base || va - image.va_base >= image.size) return 0u;
  return va - image.va_base;
}

inline bool Rel32Target(const ImageView& image, uint32_t call_rva,
                        uint32_t* target) {
  if (U8(image, call_rva) != 0xe8u && U8(image, call_rva) != 0xe9u) {
    return false;
  }
  const int32_t rel = static_cast<int32_t>(U32(image, call_rva + 1u));
  const int64_t t = static_cast<int64_t>(call_rva) + 5 + rel;
  if (t < 0 || t >= static_cast<int64_t>(image.size)) return false;
  *target = static_cast<uint32_t>(t);
  return true;
}

// ── tiny decoders for the few instruction forms the resolver reads ─────────

struct Disp8Load {  // 8B /r, mod=01, rm!=100: mov r32,[base+disp8]
  uint8_t reg = 0u;
  uint8_t base = 0u;
  uint8_t disp = 0u;
};

inline bool DecodeDisp8Load(const ImageView& image, uint32_t rva,
                            Disp8Load* out) {
  if (U8(image, rva) != 0x8bu) return false;
  const uint8_t m = U8(image, rva + 1u);
  if ((m >> 6) != 1u || (m & 7u) == 4u) return false;
  out->reg = static_cast<uint8_t>((m >> 3) & 7u);
  out->base = static_cast<uint8_t>(m & 7u);
  out->disp = U8(image, rva + 2u);
  return true;
}

struct ScaledWordLoad {  // 0F BF /r, mod=00, rm=100, SIB scale x2
  uint8_t reg = 0u;
  uint8_t base = 0u;
  uint8_t index = 0u;
};

inline bool DecodeScaledWordLoad(const ImageView& image, uint32_t rva,
                                 ScaledWordLoad* out) {
  if (U8(image, rva) != 0x0fu || U8(image, rva + 1u) != 0xbfu) return false;
  const uint8_t m = U8(image, rva + 2u);
  const uint8_t sib = U8(image, rva + 3u);
  if ((m >> 6) != 0u || (m & 7u) != 4u || (sib >> 6) != 1u ||
      (sib & 7u) == 5u) {
    return false;
  }
  out->reg = static_cast<uint8_t>((m >> 3) & 7u);
  out->base = static_cast<uint8_t>(sib & 7u);
  out->index = static_cast<uint8_t>((sib >> 3) & 7u);
  return true;
}

// ── sites ──────────────────────────────────────────────────────────────────

struct ImportSlots {
  uint32_t text_out = 0u;           // IAT slot RVA of gdi32!TextOutA
  uint32_t get_keyboard_state = 0u; // IAT slot RVA of user32!GetKeyboardState
  uint32_t screen_to_client = 0u;   // IAT slot RVA of user32!ScreenToClient
};

struct Sites {
  uint32_t draw = 0u;        // DRAW entry RVA
  uint32_t raster = 0u;      // rasteriser RVA (calls TextOutA)
  std::array<uint32_t, kMaxDrawSites> returns{};  // call+5 of each typing site
  uint32_t return_count = 0u;
  uint32_t state_global = 0u;  // RVA of the S pointer
  uint32_t char_buffer = 0u;   // RVA of the 2-byte character buffer
  uint8_t pen_x = 0u;          // S+pen_x, pen y at S+pen_x+4
  uint8_t text_ptr = 0u;       // S+text_ptr -> CP932 text
  uint8_t text_index = 0u;     // S+text_index: byte index of the character
  uint8_t op_index = 0u;       // S+op_index
  uint8_t size_array = 0u;     // S+size_array -> int16 font size per op
  uint32_t key_table = 0u;     // RVA of the 256-byte GetKeyboardState table
  uint32_t key_loop = 0u;      // RVA of the mouse-button loop head (mov ebx,1)
  // DRAW's stack arguments, as offsets from esp at DRAW's first instruction
  // ([esp] is the return address).  Every DRAW caller uses this ABI.
  uint8_t arg_size = 0u;
  uint8_t arg_x = 0u;
  uint8_t arg_y = 0u;
  uint8_t arg_layer = 0u;
  // A layer's screen position is the sum of its sprite positions up the
  // parent chain (the engine's own sprite hit test walks it the same way):
  // node -> [node+chain_sprite] -> x/y; node = [node+chain_parent] while
  // [node+chain_live] != 0.
  uint8_t chain_sprite = 0u;
  uint8_t chain_parent = 0u;
  uint8_t chain_live = 0u;
  uint32_t sprite_x = 0u;
  uint32_t sprite_y = 0u;
  // Main window record: [window_table] -> W; W+window_hwnd is its HWND and
  // W+design_w / W+design_h the design screen the engine maps the cursor to.
  uint32_t window_table = 0u;
  uint32_t window_hwnd = 0u;
  uint8_t design_w = 0u;
  uint8_t design_h = 0u;
};

enum class SiteResult : uint32_t {
  kResolved = 0,
  kNoImports = 1,
  kDrawMissing = 2,
  kDrawAmbiguous = 3,
  kStateMismatch = 4,
  kSizeArrayMissing = 5,
  kTextIndexMissing = 6,
  kTextPointerMissing = 7,
  kCharBufferMissing = 8,
  kKeyPollMissing = 9,
  kKeyLoopMissing = 10,
  kHookTargetPatched = 11,  // a hook target's live bytes differ on disk
  kDrawAbiMissing = 12,
  kLayerChainMissing = 13,
  kWindowMissing = 14,
};

// A rasteriser: a function (entered by rel32 call from DRAW's first bytes)
// whose body holds `call [TextOutA]`.
inline bool CallsTextOut(const ImageView& image, uint32_t function,
                         uint32_t text_out_slot) {
  constexpr uint32_t kSpan = 0x200u;
  const uint32_t slot_va = image.va_base + text_out_slot;
  for (uint32_t at = function; at + 6u <= function + kSpan; ++at) {
    if (!InCode(image, at, 6u)) return false;
    if (U8(image, at) == 0xffu && U8(image, at + 1u) == 0x15u &&
        U32(image, at + 2u) == slot_va) {
      return true;
    }
  }
  return false;
}

inline uint32_t FindRaster(const ImageView& image, uint32_t draw,
                           uint32_t text_out_slot) {
  constexpr uint32_t kSpan = 0x60u;
  uint32_t found = 0u;
  for (uint32_t at = draw; at + 5u <= draw + kSpan; ++at) {
    uint32_t target = 0u;
    if (U8(image, at) != 0xe8u || !Rel32Target(image, at, &target) ||
        !InCode(image, target, 16u) ||
        !CallsTextOut(image, target, text_out_slot)) {
      continue;
    }
    if (found != 0u && found != target) return 0u;
    found = target;
  }
  return found;
}

// The per-op font size array and op index, read from the argument setup that
// precedes a typing site: `mov a,[s+SZ]; movsx a,word [a+i*2]` where i was
// loaded by `mov i,[s+IDX]` earlier in the same window.
inline bool DecodeSizeArray(const ImageView& image, uint32_t call,
                            uint8_t* size_array, uint8_t* op_index) {
  constexpr uint32_t kWindow = 0x90u;
  const uint32_t begin = call > kWindow ? call - kWindow : 0u;
  for (uint32_t at = begin; at < call; ++at) {
    Disp8Load load;
    ScaledWordLoad word;
    if (!DecodeDisp8Load(image, at, &load) ||
        !DecodeScaledWordLoad(image, at + 3u, &word) || word.base != load.reg) {
      continue;
    }
    // Most recent load of the index register from the same base.
    bool have = false;
    uint8_t index = 0u;
    for (uint32_t back = begin; back < at; ++back) {
      Disp8Load idx;
      if (DecodeDisp8Load(image, back, &idx) && idx.reg == word.index &&
          idx.base == load.base) {
        have = true;
        index = idx.disp;
      }
    }
    if (!have) continue;
    *size_array = load.disp;
    *op_index = index;
    return true;
  }
  return false;
}

// `add dword [edx+TI],2` or `inc dword [edx+TI]` shortly after the pen
// advance: the text byte index the site consumed.
inline bool DecodeTextIndex(const ImageView& image, uint32_t after_add,
                            uint8_t* text_index) {
  constexpr uint32_t kSpan = 0x30u;
  for (uint32_t at = after_add; at + 4u <= after_add + kSpan; ++at) {
    if (U8(image, at) == 0x83u && U8(image, at + 1u) == 0x42u &&
        U8(image, at + 3u) == 0x02u) {
      *text_index = U8(image, at + 2u);
      return true;
    }
    if (U8(image, at) == 0xffu && U8(image, at + 1u) == 0x42u) {
      *text_index = U8(image, at + 2u);
      return true;
    }
  }
  return false;
}

// The character buffer: `mov eax, imm32` right before the call.
inline bool DecodeCharBuffer(const ImageView& image, uint32_t call,
                             uint32_t* buffer) {
  constexpr uint32_t kSpan = 0x20u;
  if (call < kSpan) return false;
  uint32_t found = 0u;
  for (uint32_t at = call - kSpan; at < call; ++at) {
    if (U8(image, at) == 0xb8u) {
      const uint32_t rva = VaToRva(image, U32(image, at + 1u));
      if (rva != 0u) found = rva;
    }
  }
  if (found == 0u) return false;
  *buffer = found;
  return true;
}

// Fields loaded right before a `movzx r,byte[a+b(+disp8)]` whose result is
// stored to the character buffer: the text pointer and the text index.
inline void CollectTextFieldCandidates(const ImageView& image, uint32_t call,
                                       uint32_t char_buffer,
                                       std::array<uint8_t, 16>* out,
                                       size_t* count) {
  constexpr uint32_t kWindow = 0xa0u;
  const uint32_t begin = call > kWindow ? call - kWindow : 0u;
  const uint32_t buffer_va = image.va_base + char_buffer;
  for (uint32_t at = begin; at + 6u <= call; ++at) {
    const bool store_al = U8(image, at) == 0xa2u &&
                          U32(image, at + 1u) == buffer_va;
    const bool store_r8 = U8(image, at) == 0x88u &&
                          (U8(image, at + 1u) & 0xc7u) == 0x05u &&
                          U32(image, at + 2u) == buffer_va;
    if (!store_al && !store_r8) continue;
    for (uint32_t back : {4u, 5u}) {
      const uint32_t q = at - back;
      const uint8_t m = U8(image, q + 2u);
      if (U8(image, q) != 0x0fu || U8(image, q + 1u) != 0xb6u ||
          (m & 7u) != 4u || (m >> 6) != (back == 4u ? 0u : 1u)) {
        continue;
      }
      const uint8_t sib = U8(image, q + 3u);
      const uint8_t regs[2] = {static_cast<uint8_t>(sib & 7u),
                               static_cast<uint8_t>((sib >> 3) & 7u)};
      for (uint8_t reg : regs) {
        bool have = false;
        uint8_t disp = 0u;
        for (uint32_t z = begin; z < q; ++z) {
          Disp8Load load;
          if (DecodeDisp8Load(image, z, &load) && load.reg == reg) {
            have = true;
            disp = load.disp;
          }
        }
        if (!have) continue;
        bool seen = false;
        for (size_t i = 0u; i < *count; ++i) seen = seen || (*out)[i] == disp;
        if (!seen && *count < out->size()) (*out)[(*count)++] = disp;
      }
    }
  }
}

// `mov [esp+k], r32` (89 /r, mod=01, rm=100, SIB 0x24): returns k.
inline bool DecodeStackStore(const ImageView& image, uint32_t rva,
                             uint8_t* reg, uint8_t* offset) {
  if (U8(image, rva) != 0x89u || U8(image, rva + 2u) != 0x24u) return false;
  const uint8_t m = U8(image, rva + 1u);
  if ((m >> 6) != 1u || (m & 7u) != 4u) return false;
  *reg = static_cast<uint8_t>((m >> 3) & 7u);
  *offset = U8(image, rva + 3u);
  return true;
}

struct DrawAbi {
  uint8_t size = 0u;
  uint8_t x = 0u;
  uint8_t y = 0u;
  uint8_t layer = 0u;
};

// DRAW's argument slots, read from the argument setup of a typing site: the
// store right after the pen loads (`mov r,[s+X]` / `[s+X+4]`), the store
// right after the font-size word load (`mov a,[s+SZ]; movsx a,word[a+i*2]`)
// and, for the layer, the last argument (highest dword store).  Offsets are
// returned relative to esp at DRAW's entry (+4 for the return address).
inline bool DecodeDrawAbi(const ImageView& image, uint32_t call,
                          uint8_t pen_x, uint8_t size_array, DrawAbi* out) {
  constexpr uint32_t kWindow = 0x90u;
  const uint32_t begin = call > kWindow ? call - kWindow : 0u;
  DrawAbi abi;
  // The font-size store opens this call's argument setup; only stores after
  // it (up to the call) belong to this call.
  uint32_t setup = 0u;
  for (uint32_t at = begin + 7u; at + 4u <= call; ++at) {
    uint8_t reg = 0u, offset = 0u;
    ScaledWordLoad word;
    Disp8Load array;
    if (DecodeStackStore(image, at, &reg, &offset) &&
        DecodeScaledWordLoad(image, at - 4u, &word) && word.reg == reg &&
        DecodeDisp8Load(image, at - 7u, &array) && array.reg == word.base &&
        array.disp == size_array && offset < 0xfbu) {
      abi.size = static_cast<uint8_t>(offset + 4u);
      setup = at;  // the last such store before the call
    }
  }
  if (setup == 0u) return false;
  bool have_x = false, have_y = false;
  abi.layer = 0u;
  for (uint32_t at = setup; at + 4u <= call; ++at) {
    uint8_t reg = 0u, offset = 0u;
    if (!DecodeStackStore(image, at, &reg, &offset)) continue;
    if (offset >= 0xfbu) return false;
    if (offset + 4u > abi.layer) abi.layer = static_cast<uint8_t>(offset + 4u);
    Disp8Load load;
    if (DecodeDisp8Load(image, at - 3u, &load) && load.reg == reg) {
      if (load.disp == pen_x) {
        abi.x = static_cast<uint8_t>(offset + 4u);
        have_x = true;
      } else if (load.disp == static_cast<uint8_t>(pen_x + 4u)) {
        abi.y = static_cast<uint8_t>(offset + 4u);
        have_y = true;
      }
    }
  }
  if (!have_x || !have_y || abi.layer <= abi.x || abi.layer <= abi.y ||
      abi.layer <= abi.size) {
    return false;
  }
  *out = abi;
  return true;
}

struct LayerChain {
  uint8_t sprite = 0u;
  uint8_t parent = 0u;
  uint8_t live = 0u;
  uint32_t x = 0u;
  uint32_t y = 0u;
};

// `mov r32,[base+disp]` with disp8 or disp32; returns its length (0 = no).
inline uint32_t DecodeBaseLoad(const ImageView& image, uint32_t rva,
                               uint8_t base, uint8_t* reg, uint32_t* disp) {
  if (U8(image, rva) != 0x8bu) return 0u;
  const uint8_t m = U8(image, rva + 1u);
  if ((m & 7u) != base || base == 4u) return 0u;
  *reg = static_cast<uint8_t>((m >> 3) & 7u);
  if ((m >> 6) == 1u) {
    *disp = U8(image, rva + 2u);
    return 3u;
  }
  if ((m >> 6) == 2u) {
    *disp = U32(image, rva + 2u);
    return 6u;
  }
  return 0u;
}

// The engine's sprite hit test walks a layer's parent chain summing sprite
// positions:
//   L: mov S,[N+sprite]; mov a,[S+x] ... mov b,[S+y] ...;
//      mov N,[N+parent]; test N,N; je out; cmp dword [N+live],0; jne L
// Exactly one such loop must exist.
inline bool DecodeLayerChain(const ImageView& image, LayerChain* out) {
  bool found = false;
  LayerChain chain;
  for (size_t r = 0u; r < image.code_count; ++r) {
    for (uint32_t t = image.code[r].begin + 3u; t + 16u <= image.code[r].end;
         ++t) {
      const uint8_t m = U8(image, t + 1u);
      if (U8(image, t) != 0x85u || (m >> 6) != 3u ||
          (m & 7u) != ((m >> 3) & 7u) || U8(image, t + 2u) != 0x0fu ||
          U8(image, t + 3u) != 0x84u) {
        continue;
      }
      const uint8_t node = static_cast<uint8_t>(m & 7u);
      const uint32_t c = t + 8u;
      if (U8(image, c) != 0x83u || U8(image, c + 1u) != (0x78u | node) ||
          U8(image, c + 3u) != 0u || U8(image, c + 4u) != 0x75u) {
        continue;
      }
      const int8_t rel = static_cast<int8_t>(U8(image, c + 5u));
      if (rel >= 0) continue;
      const uint32_t loop = c + 6u + rel;
      if (U8(image, t - 3u) != 0x8bu ||
          U8(image, t - 2u) != (0x40u | (node << 3) | node) || loop + 3u > t) {
        continue;
      }
      uint8_t sprite_reg = 0u;
      uint32_t sprite = 0u;
      if (DecodeBaseLoad(image, loop, node, &sprite_reg, &sprite) != 3u) {
        continue;
      }
      uint32_t loads[2] = {};
      uint32_t count = 0u;
      for (uint32_t q = loop + 3u; q + 3u <= t - 3u && count < 2u;) {
        uint8_t reg = 0u;
        uint32_t disp = 0u;
        const uint32_t length = DecodeBaseLoad(image, q, sprite_reg, &reg, &disp);
        if (length != 0u) {
          loads[count++] = disp;
          q += length;
        } else {
          ++q;
        }
      }
      if (count != 2u || loads[1] != loads[0] + 8u) continue;
      if (found) return false;
      found = true;
      chain.sprite = static_cast<uint8_t>(sprite);
      chain.parent = U8(image, t - 1u);
      chain.live = U8(image, c + 2u);
      chain.x = loads[0];
      chain.y = loads[1];
    }
  }
  if (!found) return false;
  *out = chain;
  return true;
}

struct WindowRecord {
  uint32_t table = 0u;  // RVA
  uint32_t hwnd = 0u;
  uint8_t design_w = 0u;
  uint8_t design_h = 0u;
};

// The cursor mapping: `mov r,[table + ...]; ... push [r+hwnd]; call
// [ScreenToClient]`, followed by the design bounds check `cmp a,[w+dw];
// jge; cmp b,[w+dw+4]`.  Exactly one site must carry all three.
inline bool DecodeWindowRecord(const ImageView& image,
                               uint32_t screen_to_client_slot,
                               WindowRecord* out) {
  const uint32_t slot_va = image.va_base + screen_to_client_slot;
  bool found = false;
  WindowRecord record;
  for (size_t r = 0u; r < image.code_count; ++r) {
    for (uint32_t at = image.code[r].begin + 0x70u;
         at + 0xd0u <= image.code[r].end; ++at) {
      if (U8(image, at) != 0xffu || U8(image, at + 1u) != 0x15u ||
          U32(image, at + 2u) != slot_va || U8(image, at - 6u) != 0xffu ||
          (U8(image, at - 5u) & 0xf8u) != 0xb0u) {
        continue;
      }
      const uint8_t window_reg = static_cast<uint8_t>(U8(image, at - 5u) & 7u);
      const uint32_t hwnd = U32(image, at - 4u);
      uint32_t table = 0u;
      for (uint32_t q = at - 0x66u; q < at - 6u; ++q) {
        const uint8_t m = U8(image, q + 1u);
        if (U8(image, q) != 0x8bu || ((m >> 3) & 7u) != window_reg) continue;
        uint32_t va = 0u;
        if ((m >> 6) == 2u && (m & 7u) != 4u) {
          va = U32(image, q + 2u);
        } else if ((m >> 6) == 0u && (m & 7u) == 4u &&
                   (U8(image, q + 2u) & 7u) == 5u &&
                   (U8(image, q + 2u) >> 6) == 2u) {
          va = U32(image, q + 3u);
        }
        const uint32_t rva = VaToRva(image, va);
        if (rva != 0u && !InCode(image, rva, 4u)) table = rva;
      }
      uint8_t dw = 0u;
      bool bounds = false;
      for (uint32_t q = at + 6u; q + 8u <= at + 6u + 0xc0u; ++q) {
        if (U8(image, q) == 0x3bu && (U8(image, q + 1u) >> 6) == 1u &&
            U8(image, q + 3u) == 0x7du && U8(image, q + 5u) == 0x3bu &&
            (U8(image, q + 6u) >> 6) == 1u &&
            U8(image, q + 7u) == static_cast<uint8_t>(U8(image, q + 2u) + 4u)) {
          dw = U8(image, q + 2u);
          bounds = true;
          break;
        }
      }
      if (table == 0u || !bounds) continue;
      if (found) return false;
      found = true;
      record.table = table;
      record.hwnd = hwnd;
      record.design_w = dw;
      record.design_h = static_cast<uint8_t>(dw + 4u);
    }
  }
  if (!found) return false;
  *out = record;
  return true;
}

inline SiteResult ResolveSites(const ImageView& image,
                               const ImportSlots& imports, Sites* out) {
  if (out == nullptr || imports.text_out == 0u ||
      imports.get_keyboard_state == 0u) {
    return SiteResult::kNoImports;
  }
  Sites found;
  // 1. typing sites, grouped by call target.
  struct Candidate {
    uint32_t draw = 0u;
    uint32_t state = 0u;
    uint8_t pen_x = 0u;
    std::array<uint32_t, kMaxDrawSites> calls{};
    uint32_t count = 0u;
    bool consistent = true;
    bool overflow = false;
  };
  std::array<Candidate, 8> candidates{};
  size_t candidate_count = 0u;
  for (size_t r = 0u; r < image.code_count; ++r) {
    for (uint32_t at = image.code[r].begin; at + 14u <= image.code[r].end;
         ++at) {
      if (U8(image, at) != 0xe8u || U8(image, at + 5u) != 0x8bu ||
          U8(image, at + 6u) != 0x15u || U8(image, at + 11u) != 0x01u ||
          U8(image, at + 12u) != 0x42u) {
        continue;
      }
      uint32_t target = 0u;
      const uint32_t state = VaToRva(image, U32(image, at + 7u));
      if (!Rel32Target(image, at, &target) || !InCode(image, target, 16u) ||
          state == 0u) {
        continue;
      }
      Candidate* c = nullptr;
      for (size_t i = 0u; i < candidate_count; ++i) {
        if (candidates[i].draw == target) c = &candidates[i];
      }
      if (c == nullptr) {
        if (candidate_count >= candidates.size()) return SiteResult::kDrawAmbiguous;
        c = &candidates[candidate_count++];
        c->draw = target;
        c->state = state;
        c->pen_x = U8(image, at + 13u);
      }
      if (c->state != state || c->pen_x != U8(image, at + 13u)) {
        c->consistent = false;
      }
      if (c->count >= kMaxDrawSites) {
        c->overflow = true;
      } else {
        c->calls[c->count++] = at;
      }
    }
  }
  const Candidate* draw = nullptr;
  for (size_t i = 0u; i < candidate_count; ++i) {
    const Candidate& c = candidates[i];
    if (c.count < 2u || c.overflow ||
        FindRaster(image, c.draw, imports.text_out) == 0u) {
      continue;
    }
    if (draw != nullptr) return SiteResult::kDrawAmbiguous;
    draw = &c;
  }
  if (draw == nullptr) return SiteResult::kDrawMissing;
  if (!draw->consistent) return SiteResult::kStateMismatch;
  found.draw = draw->draw;
  found.raster = FindRaster(image, draw->draw, imports.text_out);
  found.state_global = draw->state;
  found.pen_x = draw->pen_x;
  // 2. per-site fields; every site must agree.
  bool have_size = false, have_index = false, have_buffer = false;
  std::array<uint8_t, 16> text_fields{};
  size_t text_field_count = 0u;
  for (uint32_t i = 0u; i < draw->count; ++i) {
    const uint32_t call = draw->calls[i];
    found.returns[found.return_count++] = call + 5u;
    uint8_t size_array = 0u, op_index = 0u, text_index = 0u;
    uint32_t buffer = 0u;
    if (!DecodeSizeArray(image, call, &size_array, &op_index)) {
      return SiteResult::kSizeArrayMissing;
    }
    if (have_size && (size_array != found.size_array ||
                      op_index != found.op_index)) {
      return SiteResult::kSizeArrayMissing;
    }
    have_size = true;
    found.size_array = size_array;
    found.op_index = op_index;
    if (DecodeTextIndex(image, call + 14u, &text_index)) {
      if (have_index && text_index != found.text_index) {
        return SiteResult::kTextIndexMissing;
      }
      have_index = true;
      found.text_index = text_index;
    }
    if (!DecodeCharBuffer(image, call, &buffer) ||
        (have_buffer && buffer != found.char_buffer)) {
      return SiteResult::kCharBufferMissing;
    }
    have_buffer = true;
    found.char_buffer = buffer;
    CollectTextFieldCandidates(image, call, buffer, &text_fields,
                               &text_field_count);
    DrawAbi abi;
    if (!DecodeDrawAbi(image, call, found.pen_x, size_array, &abi) ||
        (i != 0u && (abi.x != found.arg_x || abi.y != found.arg_y ||
                     abi.size != found.arg_size ||
                     abi.layer != found.arg_layer))) {
      return SiteResult::kDrawAbiMissing;
    }
    found.arg_x = abi.x;
    found.arg_y = abi.y;
    found.arg_size = abi.size;
    found.arg_layer = abi.layer;
  }
  if (!have_index) return SiteResult::kTextIndexMissing;
  uint8_t text_ptr = 0u;
  size_t pointers = 0u;
  for (size_t i = 0u; i < text_field_count; ++i) {
    if (text_fields[i] == found.text_index) continue;
    text_ptr = text_fields[i];
    ++pointers;
  }
  if (pointers != 1u) return SiteResult::kTextPointerMissing;
  found.text_ptr = text_ptr;
  // 3. key table: `push K; call [GetKeyboardState]` (unique K).
  const uint32_t gks_va = image.va_base + imports.get_keyboard_state;
  uint32_t key_table = 0u;
  for (size_t r = 0u; r < image.code_count; ++r) {
    for (uint32_t at = image.code[r].begin; at + 11u <= image.code[r].end;
         ++at) {
      if (U8(image, at) != 0x68u || U8(image, at + 5u) != 0xffu ||
          U8(image, at + 6u) != 0x15u || U32(image, at + 7u) != gks_va) {
        continue;
      }
      const uint32_t table = VaToRva(image, U32(image, at + 1u));
      if (table == 0u || (key_table != 0u && key_table != table)) {
        return SiteResult::kKeyPollMissing;
      }
      key_table = table;
    }
  }
  if (key_table == 0u) return SiteResult::kKeyPollMissing;
  found.key_table = key_table;
  // 4. mouse-button loop over that table (unique):
  //    BB 01000000 0FB693 <K> C1FA07 0FBE83 <P> 03C0 03C0 53 FF9490 <T> 59 43
  //    83FB07
  const uint32_t key_va = image.va_base + key_table;
  uint32_t loop = 0u;
  for (size_t r = 0u; r < image.code_count; ++r) {
    for (uint32_t at = image.code[r].begin; at + 38u <= image.code[r].end;
         ++at) {
      static constexpr uint8_t kHead[] = {0xbb, 0x01, 0x00, 0x00, 0x00,
                                          0x0f, 0xb6, 0x93};
      if (std::memcmp(image.bytes + at, kHead, sizeof(kHead)) != 0 ||
          U32(image, at + 8u) != key_va || U8(image, at + 12u) != 0xc1u ||
          U8(image, at + 13u) != 0xfau || U8(image, at + 14u) != 0x07u ||
          U8(image, at + 15u) != 0x0fu || U8(image, at + 16u) != 0xbeu ||
          U8(image, at + 17u) != 0x83u || U8(image, at + 22u) != 0x03u ||
          U8(image, at + 23u) != 0xc0u || U8(image, at + 24u) != 0x03u ||
          U8(image, at + 25u) != 0xc0u || U8(image, at + 26u) != 0x53u ||
          U8(image, at + 27u) != 0xffu || U8(image, at + 28u) != 0x94u ||
          U8(image, at + 29u) != 0x90u || U8(image, at + 34u) != 0x59u ||
          U8(image, at + 35u) != 0x43u || U8(image, at + 36u) != 0x83u ||
          U8(image, at + 37u) != 0xfbu) {
        continue;
      }
      if (loop != 0u) return SiteResult::kKeyLoopMissing;
      loop = at;
    }
  }
  if (loop == 0u) return SiteResult::kKeyLoopMissing;
  found.key_loop = loop;
  // 5. layer placement chain and the main window record.
  LayerChain chain;
  if (!DecodeLayerChain(image, &chain)) return SiteResult::kLayerChainMissing;
  found.chain_sprite = chain.sprite;
  found.chain_parent = chain.parent;
  found.chain_live = chain.live;
  found.sprite_x = chain.x;
  found.sprite_y = chain.y;
  WindowRecord window;
  if (imports.screen_to_client == 0u ||
      !DecodeWindowRecord(image, imports.screen_to_client, &window)) {
    return SiteResult::kWindowMissing;
  }
  found.window_table = window.table;
  found.window_hwnd = window.hwnd;
  found.design_w = window.design_w;
  found.design_h = window.design_h;
  *out = found;
  return SiteResult::kResolved;
}

// ── text ───────────────────────────────────────────────────────────────────

inline bool IsCp932Lead(uint8_t byte) {
  return (byte >= 0x81u && byte <= 0x9fu) || (byte >= 0xe0u && byte <= 0xfcu);
}

// The message text the ops consume: display characters only, NUL-terminated.
// Returns its byte length, or 0 when it is not a clean CP932 run (a control
// byte, a dangling lead byte, or no terminator within the bound).
inline size_t MessageTextLength(const uint8_t* text, size_t bound) {
  if (text == nullptr) return 0u;
  size_t at = 0u;
  while (at < bound && text[at] != 0u) {
    if (text[at] < 0x20u) return 0u;
    if (IsCp932Lead(text[at])) {
      if (at + 1u >= bound || text[at + 1u] < 0x40u) return 0u;
      at += 2u;
    } else {
      ++at;
    }
  }
  return at < bound ? at : 0u;
}

// The engine's in-text line break: the double-byte code 0xEFF0 (outside the
// CP932 table, never drawn).  Measured on the 2011 build: a two-line message
// is `line1 EF F0 line2`.
inline constexpr uint8_t kLineBreakLead = 0xefu;
inline constexpr uint8_t kLineBreakTrail = 0xf0u;

// The message text as displayed: CP932 characters converted one by one, the
// engine line break dropped.  Any other unconvertible character fails the
// whole message (empty result).
inline std::wstring DecodeMessageText(const uint8_t* text, size_t bytes) {
  std::wstring out;
  if (text == nullptr) return out;
  size_t at = 0u;
  while (at < bytes) {
    const size_t size = IsCp932Lead(text[at]) ? 2u : 1u;
    if (at + size > bytes) return std::wstring();
    if (size == 2u && text[at] == kLineBreakLead &&
        text[at + 1u] == kLineBreakTrail) {
      at += size;
      continue;
    }
    wchar_t wide[4] = {};
    if (MultiByteToWideChar(932, MB_ERR_INVALID_CHARS,
                            reinterpret_cast<const char*>(text + at),
                            static_cast<int>(size), wide, 4) != 1) {
      return std::wstring();
    }
    out.push_back(wide[0]);
    at += size;
  }
  return out;
}

// Inline ruby in the message text: `≪base／reading≫` (U+226A, U+FF0F,
// U+226B), measured on the 2011 build.  The displayed line is the base text;
// the reading is drawn above it in a smaller font.  Returns the text with
// every ruby group replaced by its base; *had_ruby tells whether any was.
// A malformed group (no separator or no closing mark) is left unchanged.
inline std::wstring StripRubyMarkup(const std::wstring& text, bool* had_ruby) {
  constexpr wchar_t kOpen = 0x226a, kSeparator = 0xff0f, kClose = 0x226b;
  std::wstring out;
  bool any = false;
  size_t at = 0u;
  while (at < text.size()) {
    if (text[at] == kOpen) {
      const size_t separator = text.find(kSeparator, at + 1u);
      const size_t close = text.find(kClose, at + 1u);
      const size_t next_open = text.find(kOpen, at + 1u);
      if (separator != std::wstring::npos && close != std::wstring::npos &&
          separator < close && separator > at + 1u &&
          (next_open == std::wstring::npos || next_open > close)) {
        out.append(text, at + 1u, separator - at - 1u);
        at = close + 1u;
        any = true;
        continue;
      }
    }
    out.push_back(text[at]);
    ++at;
  }
  if (had_ruby != nullptr) *had_ruby = any;
  return out;
}

// The text lane line of a message: the decoded text with ruby groups reduced
// to their base.  Nothing else is removed.  In particular a bracketed quote
// after some leading text is NOT taken as `NAME「…」`: the shape alone cannot
// tell a speaker prefix from narration (`そう言って「ありがとう」`,
// `彼女は小さく「うん」`), and the message text carries no separate name
// field, so the line is published as the engine holds it.  Whether a prefix
// is a name plate is decided only for lookup, from where the engine drew it
// (ChooseLineLayer).
inline std::wstring PublishedMessageText(const std::wstring& decoded,
                                         bool* had_ruby) {
  return StripRubyMarkup(decoded, had_ruby);
}

// Shape candidate only: `PREFIX「…」` (or 『…』 / （…）) with a bracket-free
// prefix of at most 32 units and the line ending in the matching closer.
// Returns the index where the quote starts (0 = no candidate).  A candidate
// is never acted on by itself; ChooseLineLayer needs the engine to have drawn
// exactly the prefix on a layer of its own (the name plate) before it treats
// the prefix as a speaker.
inline size_t SpeakerPrefixCandidate(const wchar_t* text, size_t length) {
  constexpr size_t kMaxSpeaker = 32u;
  if (text == nullptr || length < 3u) return 0u;
  static constexpr wchar_t kOpen[] = {0x300c, 0x300e, 0xff08};
  static constexpr wchar_t kClose[] = {0x300d, 0x300f, 0xff09};
  for (size_t at = 1u; at < length && at <= kMaxSpeaker; ++at) {
    for (size_t k = 0u; k < 3u; ++k) {
      if (text[at] != kOpen[k]) continue;
      if (text[length - 1u] != kClose[k]) return 0u;
      for (size_t i = 0u; i < at; ++i) {
        for (size_t b = 0u; b < 3u; ++b) {
          if (text[i] == kOpen[b] || text[i] == kClose[b]) return 0u;
        }
      }
      return at;
    }
  }
  return 0u;
}

// ── page model ─────────────────────────────────────────────────────────────

// One captured character draw (layer pixels).
struct Cell {
  uint32_t text_offset = 0u;  // byte offset in the message text
  uint8_t bytes[2] = {};      // the character as drawn (CP932)
  uint8_t length = 0u;        // 1 or 2
  int32_t x = 0;
  int32_t y = 0;
  int32_t size = 0;           // font size of its op
};

struct LineGlyph {
  uint32_t codepoint = 0u;
  int32_t x = 0;  // design pixels
  int32_t y = 0;
  int32_t w = 0;
  int32_t h = 0;
  uint16_t source_index = kNoSource;
  uint8_t source_length = 0u;
};

inline bool CellPlausible(const Cell& cell) {
  return cell.size > 0 && cell.size <= kMaxCellSide && cell.x >= 0 &&
         cell.y >= 0 && cell.x < kMaxDesignSide && cell.y < kMaxDesignSide &&
         (cell.length == 1u || cell.length == 2u);
}

// A draw of the same character within a couple of pixels of an earlier one
// on the same layer is the same glyph drawn again (outline / shadow pass,
// then the face): it replaces that cell.  Returns the index to replace, or
// `count` when the draw is a new glyph.
inline constexpr int32_t kOverdrawSlack = 2;

inline size_t OverdrawTarget(const Cell* cells, size_t count, const Cell& next) {
  if (cells == nullptr) return count;
  for (size_t i = count; i > 0u; --i) {
    const Cell& cell = cells[i - 1u];
    const int32_t dx = cell.x - next.x;
    const int32_t dy = cell.y - next.y;
    if (cell.length == next.length && cell.bytes[0] == next.bytes[0] &&
        cell.bytes[1] == next.bytes[1] && dx >= -kOverdrawSlack &&
        dx <= kOverdrawSlack && dy >= -kOverdrawSlack && dy <= kOverdrawSlack) {
      return i - 1u;
    }
  }
  return count;
}

// Glyph boxes of a page: a character spans from its pen to the next pen on
// the same row (the engine advances by the drawn width), else its font size;
// the height is the font size.  `codepoints[i]` is cell i's UTF-16 unit and
// `sources[i]` its index in the published line.  Returns the glyph count, or
// 0 when the page cannot be mapped.
inline size_t BuildPageGlyphs(const Cell* cells, size_t count,
                              const uint32_t* codepoints,
                              const uint16_t* sources, int32_t origin_x,
                              int32_t origin_y, LineGlyph* out,
                              size_t capacity) {
  if (cells == nullptr || codepoints == nullptr || sources == nullptr ||
      out == nullptr || count == 0u || count > capacity) {
    return 0u;
  }
  for (size_t i = 0u; i < count; ++i) {
    const Cell& cell = cells[i];
    if (!CellPlausible(cell)) return 0u;
    int32_t w = cell.size;
    if (i + 1u < count && cells[i + 1u].y == cell.y &&
        cells[i + 1u].x > cell.x && cells[i + 1u].x - cell.x <= kMaxCellSide) {
      w = cells[i + 1u].x - cell.x;
    }
    LineGlyph& glyph = out[i];
    glyph.codepoint = codepoints[i];
    glyph.x = origin_x + cell.x;
    glyph.y = origin_y + cell.y;
    glyph.w = w;
    glyph.h = cell.size;
    glyph.source_index = sources[i];
    glyph.source_length = sources[i] == kNoSource ? 0u : 1u;
  }
  return count;
}

// The selected line is matched as the render-order suffix of the page
// (whitespace-insensitive); every character of it must be a glyph of the page.
inline size_t MapSelectedSuffix(LineGlyph* glyphs, size_t count,
                                const wchar_t* selected,
                                size_t selected_count) {
  if (glyphs == nullptr || selected == nullptr || count == 0u ||
      selected_count == 0u || selected_count >= kNoSource) {
    return count;
  }
  auto fail = [glyphs, count]() {
    for (size_t i = 0u; i < count; ++i) {
      glyphs[i].source_index = kNoSource;
      glyphs[i].source_length = 0u;
    }
    return count;
  };
  fail();
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

// `text` is exactly the glyph run (whitespace-insensitive): every glyph is
// consumed by it.  Mapping state in `glyphs` is overwritten.
inline bool GlyphRunIs(LineGlyph* glyphs, size_t count, const wchar_t* text,
                       size_t length) {
  return count != 0u && MapSelectedSuffix(glyphs, count, text, length) == 0u;
}

// Mapped glyphs of a sub-line `line[offset..]` -> indices into `line`.
inline bool ShiftSources(LineGlyph* glyphs, size_t count, size_t offset) {
  if (glyphs == nullptr) return false;
  for (size_t i = 0u; i < count; ++i) {
    if (glyphs[i].source_index == kNoSource) continue;
    const size_t source = glyphs[i].source_index + offset;
    if (source >= kNoSource) return false;
    glyphs[i].source_index = static_cast<uint16_t>(source);
  }
  return true;
}

// How one layer of a page relates to the selected line.
struct LayerFit {
  bool line = false;   // the whole line is its render-order suffix
  bool quote = false;  // line[speaker..] is its render-order suffix
  bool name = false;   // its glyph run is exactly line[0..speaker)
};

struct LineLayerChoice {
  size_t layer = SIZE_MAX;   // SIZE_MAX = none
  size_t source_offset = 0;  // line index of the layer's first mapped glyph
  bool ambiguous = false;
};

// Which layer carries the selected line.  Exactly one layer holding the whole
// line wins.  Failing that, a speaker split (`speaker` from
// SpeakerPrefixCandidate, 0 = none) is accepted only on the engine's own
// structural evidence: exactly one layer drew exactly the prefix and nothing
// else (the name plate) and exactly one other layer holds the quote.  Without
// that evidence nothing is matched (lookup fails closed; the line is never
// cut).
inline LineLayerChoice ChooseLineLayer(const LayerFit* fits, size_t count,
                                       size_t speaker) {
  LineLayerChoice choice;
  if (fits == nullptr) return choice;
  size_t lines = 0u, quotes = 0u, names = 0u;
  size_t line_at = SIZE_MAX, quote_at = SIZE_MAX, name_at = SIZE_MAX;
  auto note = [](bool fit, size_t k, size_t* seen, size_t* at) {
    if (!fit) return;
    ++*seen;
    *at = k;
  };
  for (size_t k = 0u; k < count; ++k) {
    note(fits[k].line, k, &lines, &line_at);
    note(speaker != 0u && fits[k].quote, k, &quotes, &quote_at);
    note(speaker != 0u && fits[k].name, k, &names, &name_at);
  }
  if (lines == 1u) {
    choice.layer = line_at;
    return choice;
  }
  if (lines > 1u) {
    choice.ambiguous = true;
    return choice;
  }
  if (quotes != 1u || names != 1u || quote_at == name_at) {
    choice.ambiguous = quotes > 1u || names > 1u;
    return choice;
  }
  choice.layer = quote_at;
  choice.source_offset = speaker;
  return choice;
}

// ── projection and hit testing ─────────────────────────────────────────────

struct PixelRect {
  int32_t x = 0;
  int32_t y = 0;
  int32_t w = 0;
  int32_t h = 0;
};

inline bool DesignPlausible(int32_t w, int32_t h) {
  return w >= kMinDesignSide && h >= kMinDesignSide && w <= kMaxDesignSide &&
         h <= kMaxDesignSide;
}

inline bool ClientMatchesDesign(int32_t client_w, int32_t client_h,
                                int32_t design_w, int32_t design_h) {
  if (client_w <= 0 || client_h <= 0 || !DesignPlausible(design_w, design_h)) {
    return false;
  }
  const int64_t cross = static_cast<int64_t>(client_w) * design_h -
                        static_cast<int64_t>(client_h) * design_w;
  const int64_t limit = (std::max)(design_w, design_h);
  return cross <= limit && cross >= -limit;
}

inline bool ProjectGlyph(const LineGlyph& glyph, int32_t design_w,
                         int32_t design_h, int32_t physical_w,
                         int32_t physical_h, PixelRect* out) {
  if (out == nullptr || design_w <= 0 || design_h <= 0 || physical_w <= 0 ||
      physical_h <= 0 || glyph.w <= 0 || glyph.h <= 0 || glyph.x < 0 ||
      glyph.y < 0 || glyph.x + glyph.w > design_w ||
      glyph.y + glyph.h > design_h) {
    return false;
  }
  const double sx = static_cast<double>(physical_w) / design_w;
  const double sy = static_cast<double>(physical_h) / design_h;
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

inline bool ClientToDesign(int32_t x, int32_t y, int32_t client_w,
                           int32_t client_h, int32_t design_w,
                           int32_t design_h, int32_t* out_x, int32_t* out_y) {
  if (client_w <= 0 || client_h <= 0 || x < 0 || y < 0 || x >= client_w ||
      y >= client_h || out_x == nullptr || out_y == nullptr) {
    return false;
  }
  *out_x = static_cast<int32_t>(static_cast<int64_t>(x) * design_w / client_w);
  *out_y = static_cast<int32_t>(static_cast<int64_t>(y) * design_h / client_h);
  return true;
}

inline bool HitTestLine(const LineGlyph* glyphs, size_t count, int32_t x,
                        int32_t y, size_t* hit) {
  if (glyphs == nullptr || hit == nullptr) return false;
  size_t found = count;
  for (size_t i = 0u; i < count; ++i) {
    const LineGlyph& glyph = glyphs[i];
    if (glyph.source_index == kNoSource) continue;
    if (x < glyph.x || y < glyph.y || x >= glyph.x + glyph.w ||
        y >= glyph.y + glyph.h) {
      continue;
    }
    if (found != count) return false;
    found = i;
  }
  if (found == count) return false;
  *hit = found;
  return true;
}

// ── engine-sampled click claim ─────────────────────────────────────────────

// A mouse message the system synthesised from touch or pen input carries the
// MI_WP_SIGNATURE (0xFF515700) in its extra info.
inline bool IsPromotedTouch(LPARAM extra_info) {
  return (static_cast<uint32_t>(extra_info) & 0xffffff00u) == 0xff515700u;
}

struct ClaimState {
  bool owned = false;
  bool was_down = false;
};

struct ClaimDecision {
  bool fresh_press = false;  // caller evaluated eligibility for this sample
  bool mask = false;         // clear VK_LBUTTON's high bit in the key table
  bool submit = false;       // queue the resolved glyph for the worker
};

inline bool IsFreshPress(uint8_t raw, const ClaimState& claim) {
  return (raw & kKeyDownBit) != 0u && !claim.was_down && !claim.owned;
}

// A claimed press owns the button until it is up again: every sample in
// between is masked, so the engine sees neither edge.
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

// The window-procedure half of the touch claim.  A claimed promoted-touch
// press swallows its own UP (`*up_pending`).  When that UP never reaches this
// window (the system delivered it elsewhere, or the window lost it), the next
// left DOWN proves the claimed press is over: the stale pending is dropped
// there, so it can never eat the UP of a later, unrelated press.
enum class LeftButtonMessage : uint8_t { kOther = 0, kDown = 1, kUp = 2 };

struct TouchDecision {
  bool evaluate = false;  // a promoted touch press: try to claim it
  bool swallow = false;   // the UP of a claimed touch press
};

inline TouchDecision DecideTouchMessage(LeftButtonMessage message,
                                        bool promoted_touch, bool claim_owned,
                                        bool* up_pending) {
  TouchDecision decision;
  if (up_pending == nullptr) return decision;
  if (message == LeftButtonMessage::kDown) {
    *up_pending = false;
    decision.evaluate = promoted_touch && !claim_owned;
  } else if (message == LeftButtonMessage::kUp) {
    decision.swallow = *up_pending;
    *up_pending = false;
  }
  return decision;
}

// ── published models ───────────────────────────────────────────────────────

struct PublishedLine {
  uint64_t generation = 0u;
  uint64_t text_event = 0u;
  std::wstring line;
};

class PublishedLines {
 public:
  static constexpr size_t kCapacity = 4u;
  void Record(uint64_t generation, uint64_t text_event,
              const std::wstring& line) {
    PublishedLine& slot = slots_[next_++ % kCapacity];
    slot.generation = generation;
    slot.text_event = text_event;
    slot.line = line;
  }
  const PublishedLine* Find(uint64_t generation) const {
    if (generation == 0u) return nullptr;
    for (const PublishedLine& slot : slots_) {
      if (slot.generation == generation && !slot.line.empty()) return &slot;
    }
    return nullptr;
  }

 private:
  std::array<PublishedLine, kCapacity> slots_{};
  size_t next_ = 0u;
};

}  // namespace fushi_voice_hook::yuris_lookup
