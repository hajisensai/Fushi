#pragma once

// Kogado "Hy" engine message text lane: pure, unit-tested half.
//
// Engine facts (x86 Borland C++Builder, register convention eax/edx/ecx then
// stack; read from the 2004 Symphonic Rain executable — the sample only, never
// an identity input):
//   * The engine is built on Kogado's "Hy" runtime library, which the
//     executable exports by its Borland-mangled names (THyRGBText, THyAlpha,
//     THyRGBPanel, ...).  Those exports are the identity.
//   * The script is pre-wrapped: a page is a run of row strings separated by
//     the script's "\n" marker and closed by "\p".  The message window keeps
//     the page as a fixed array of row buffers (STRIDE bytes each, CP932,
//     NUL-terminated) and a row counter; a click clears the array and the
//     counter.  The 4-row adventure window and the 16-row full-screen window
//     are two such arrays inside the same window object.
//   * Each row is shown by one engine function RENDER(win=eax,
//     rows=edx, row=ecx, ...): it clears the row's band (THyAlpha::BoxFill),
//     renders the row through the window's THyRGBText (SetText, TextOutA at
//     0,0 into the object's buffer) and copies the result into the panel
//     layer (THyAlpha::Draw).  The row is already in its buffer when RENDER
//     runs, and the next row is only produced after the previous one finished
//     typing, so rows of one page arrive up to seconds apart.
//   * The first row of a voiced line is the speaker name in 【】; the dialogue
//     follows on the next rows.  A continuation row inside a quote is indented
//     by an ideographic space.
//
// Site resolution is structural (exports, call targets, the RENDER call-site
// shape and the row-address arithmetic of its callers).  No hash, file name or
// title is consulted; anything missing or ambiguous installs nothing.

#include <windows.h>

#include <array>
#include <cstddef>
#include <cstdint>
#include <algorithm>
#include <cstring>
#include <string>
#include <vector>

namespace fushi_voice_hook::kogado_hy {

inline constexpr char kExportSetText[] =
    "@THyRGBText@SetText$qqr17System@AnsiString";
inline constexpr char kExportBoxFill[] = "@THyAlpha@BoxFill$qqriiiiuc";
inline constexpr char kExportDraw[] = "@THyAlpha@Draw$qqriip8THyAlphaiiii";

inline constexpr uint32_t kMinStride = 16u;
inline constexpr uint32_t kMaxStride = 256u;
inline constexpr uint32_t kMaxRows = 16u;
inline constexpr uint32_t kMaxPageBytes = kMaxRows * kMaxStride;
inline constexpr uint32_t kMaxRenderCandidates = 8u;
inline constexpr uint32_t kMaxRenderCallers = 16u;
// How far a RENDER caller's row-address arithmetic may sit before the call.
inline constexpr uint32_t kCallerWindow = 0x120u;
// How far BoxFill may sit before SetText inside RENDER, Draw after it.
inline constexpr uint32_t kRenderPrefixWindow = 0x80u;
inline constexpr uint32_t kRenderSuffixWindow = 0x60u;
// How far WAIT's mode branch may sit after its entry.
inline constexpr uint32_t kWaitEntryWindow = 0x40u;

// ── image view ─────────────────────────────────────────────────────────────

// A PE32 image laid out by section: bytes at RVA 0.., absolute operands are
// relative to `va_base`.
struct ImageView {
  const uint8_t* bytes = nullptr;
  size_t size = 0u;
  uint32_t va_base = 0u;
  uint32_t export_rva = 0u;
  uint32_t export_size = 0u;
  struct Range {
    uint32_t begin = 0u;
    uint32_t end = 0u;
  };
  std::array<Range, 8> code{};
  size_t code_count = 0u;
};

inline uint8_t U8(const ImageView& image, uint32_t rva) {
  return rva < image.size ? image.bytes[rva] : 0u;
}

inline uint32_t U32(const ImageView& image, uint32_t rva) {
  if (rva > image.size || image.size - rva < 4u) return 0u;
  uint32_t v = 0u;
  std::memcpy(&v, image.bytes + rva, 4u);
  return v;
}

inline bool InCode(const ImageView& image, uint32_t rva, uint32_t bytes) {
  for (size_t i = 0u; i < image.code_count; ++i) {
    const auto& r = image.code[i];
    if (rva >= r.begin && rva <= r.end && bytes <= r.end - rva) return true;
  }
  return false;
}

// Rel32 call at `rva` (E8) and its target RVA.
inline bool CallTarget(const ImageView& image, uint32_t rva, uint32_t* target) {
  if (!InCode(image, rva, 5u) || U8(image, rva) != 0xe8u) return false;
  const int64_t t = static_cast<int64_t>(rva) + 5 +
                    static_cast<int32_t>(U32(image, rva + 1u));
  if (t < 0 || t >= static_cast<int64_t>(image.size)) return false;
  *target = static_cast<uint32_t>(t);
  return true;
}

// Exact-name export lookup; 0 when absent, ambiguous or forwarded.
inline uint32_t FindExport(const ImageView& image, const char* name) {
  if (image.export_rva == 0u ||
      image.export_size < sizeof(IMAGE_EXPORT_DIRECTORY) ||
      image.export_rva > image.size ||
      image.size - image.export_rva < sizeof(IMAGE_EXPORT_DIRECTORY)) {
    return 0u;
  }
  IMAGE_EXPORT_DIRECTORY dir = {};
  std::memcpy(&dir, image.bytes + image.export_rva, sizeof(dir));
  if (dir.NumberOfNames > 65536u || dir.NumberOfFunctions > 65536u) return 0u;
  const size_t name_len = std::strlen(name);
  uint32_t found = 0u;
  uint32_t count = 0u;
  for (uint32_t i = 0u; i < dir.NumberOfNames; ++i) {
    const uint32_t name_rva = U32(image, dir.AddressOfNames + i * 4u);
    if (name_rva == 0u || name_rva > image.size ||
        image.size - name_rva < name_len + 1u ||
        std::memcmp(image.bytes + name_rva, name, name_len + 1u) != 0) {
      continue;
    }
    if (dir.AddressOfNameOrdinals + i * 2u + 2u > image.size) return 0u;
    uint16_t ordinal = 0u;
    std::memcpy(&ordinal, image.bytes + dir.AddressOfNameOrdinals + i * 2u, 2u);
    if (ordinal >= dir.NumberOfFunctions) return 0u;
    const uint32_t function = U32(image, dir.AddressOfFunctions + ordinal * 4u);
    if (function >= image.export_rva &&
        function < image.export_rva + image.export_size) {
      return 0u;  // forwarded: no local code
    }
    found = function;
    ++count;
  }
  return count == 1u && InCode(image, found, 1u) ? found : 0u;
}

// ── tiny decoders for the instruction forms the resolver reads ─────────────

// `lea r,[b+r*s]` (8D /r, mod=00, rm=100, SIB index=r, base!=ebp): r = b+r*s.
// With `b` holding the original value v and r==v before the chain, each step
// maps the multiplier m to 1+m*s.
struct LeaScale {
  uint8_t reg = 0u;
  uint8_t base = 0u;
  uint8_t scale = 0u;  // 2, 4 or 8
};

inline bool DecodeLeaScale(const ImageView& image, uint32_t rva,
                           LeaScale* out) {
  if (U8(image, rva) != 0x8du) return false;
  const uint8_t m = U8(image, rva + 1u);
  const uint8_t sib = U8(image, rva + 2u);
  if ((m >> 6) != 0u || (m & 7u) != 4u) return false;
  const uint8_t reg = static_cast<uint8_t>((m >> 3) & 7u);
  const uint8_t index = static_cast<uint8_t>((sib >> 3) & 7u);
  const uint8_t base = static_cast<uint8_t>(sib & 7u);
  const uint8_t ss = static_cast<uint8_t>(sib >> 6);
  if (index != reg || base == 5u || base == reg || ss == 0u) return false;
  out->reg = reg;
  out->base = base;
  out->scale = static_cast<uint8_t>(1u << ss);
  return true;
}

// `mov r32,[reg+disp32]` (8B, mod=10, rm != esp): an object field load.
struct FieldLoad {
  uint8_t reg = 0u;
  uint32_t disp = 0u;
};

inline bool DecodeFieldLoad(const ImageView& image, uint32_t rva,
                            FieldLoad* out) {
  if (U8(image, rva) != 0x8bu) return false;
  const uint8_t m = U8(image, rva + 1u);
  if ((m >> 6) != 2u || (m & 7u) == 4u) return false;
  out->reg = static_cast<uint8_t>((m >> 3) & 7u);
  out->disp = U32(image, rva + 2u);
  return true;
}

// The row-address arithmetic of a page-buffer user, for the row the object
// is at (its row counter field C):
//   mov R,[obj+C]; ...; mov B,R; lea R,[B+R*s1]; lea R,[B+R*s2]; ...
//   ... add R,<object>; add R,BASE      (81 C0+R imm32)
// Returns the stride (product of the chain), BASE and C when a chain of at
// least two LEAs is preceded, within 16 bytes, by the counter load into R or
// B and followed, within 16 bytes, by `add R,imm32`.
struct RowAddress {
  uint32_t stride = 0u;
  uint32_t base = 0u;
  uint32_t counter = 0u;
};

inline bool DecodeRowAddress(const ImageView& image, uint32_t rva,
                             RowAddress* out) {
  LeaScale first;
  if (!DecodeLeaScale(image, rva, &first)) return false;
  uint32_t counter = 0u;
  for (uint32_t back = 6u; back <= 16u && back <= rva && counter == 0u;
       ++back) {
    FieldLoad load;
    if (DecodeFieldLoad(image, rva - back, &load) &&
        (load.reg == first.reg || load.reg == first.base)) {
      counter = load.disp;
    }
  }
  if (counter == 0u) return false;
  uint32_t multiplier = 1u;
  uint32_t at = rva;
  uint32_t steps = 0u;
  LeaScale step;
  while (steps < 4u && DecodeLeaScale(image, at, &step) &&
         step.reg == first.reg && step.base == first.base) {
    multiplier = 1u + multiplier * step.scale;
    at += 3u;
    ++steps;
  }
  if (steps < 2u) return false;
  for (uint32_t k = at; k < at + 16u; ++k) {
    if (U8(image, k) == 0x81u && U8(image, k + 1u) == (0xc0u | first.reg)) {
      out->stride = multiplier;
      out->base = U32(image, k + 2u);
      out->counter = counter;
      return true;
    }
  }
  return false;
}

// `lea edx,[reg+disp32]` (8D 90+reg disp32, reg != esp): the row array base
// handed to RENDER.
inline bool DecodeLeaEdxDisp32(const ImageView& image, uint32_t rva,
                               uint32_t* disp) {
  if (U8(image, rva) != 0x8du) return false;
  const uint8_t m = U8(image, rva + 1u);
  if ((m >> 6) != 2u || ((m >> 3) & 7u) != 2u || (m & 7u) == 4u) return false;
  *disp = U32(image, rva + 2u);
  return true;
}

// ── site resolution ────────────────────────────────────────────────────────

enum class SiteResult : uint32_t {
  kResolved = 0,
  kNoExports = 1,         // not a Hy-library executable
  kNoRenderer = 2,        // no function draws a row through SetText
  kNoMessageRenderer = 3, // no renderer is fed by a row-indexed page buffer
  kAmbiguous = 4,         // more than one message renderer
  kBadPrologue = 5,       // RENDER does not start with a hookable frame
};

struct Sites {
  uint32_t render = 0u;        // RVA of RENDER
  uint32_t text_object = 0u;   // offset of the window's THyRGBText
  uint32_t stride = 0u;        // bytes per row buffer
  uint32_t callers = 0u;       // RENDER call sites (all proven)
  std::array<uint32_t, 4> bases{};  // distinct row-array offsets seen
  uint32_t base_count = 0u;
  std::array<uint32_t, kMaxRenderCallers> render_calls{};
};

// Borland frame prologue: push ebp; mov ebp,esp; add esp,-imm8 (55 8B EC 83 C4).
inline bool HasFramePrologue(const ImageView& image, uint32_t rva) {
  return U8(image, rva) == 0x55u && U8(image, rva + 1u) == 0x8bu &&
         U8(image, rva + 2u) == 0xecu && U8(image, rva + 3u) == 0x83u &&
         U8(image, rva + 4u) == 0xc4u;
}

// Nearest frame prologue at or before `rva` within `window` bytes.
inline uint32_t EnclosingFunction(const ImageView& image, uint32_t rva,
                                  uint32_t window) {
  for (uint32_t back = 0u; back <= window && back <= rva; ++back) {
    if (HasFramePrologue(image, rva - back)) return rva - back;
  }
  return 0u;
}

inline bool CallsWithin(const ImageView& image, uint32_t begin, uint32_t end,
                        uint32_t target) {
  for (uint32_t k = begin; k + 5u <= end; ++k) {
    uint32_t t = 0u;
    if (CallTarget(image, k, &t) && t == target) return true;
  }
  return false;
}

// A RENDER call site is proven when the call is handed a row array
// (`lea edx,[reg+BASE]` within 0x30 bytes before it), the same caller
// computes that row array's row address with the same BASE from the object's
// row counter C before it, and the row handed to RENDER is loaded from that
// same counter (`mov ecx|eax,[reg+C]` within 0x30 bytes before the call).
// A window whose row comes from an argument (the song lyric box) is no page
// of the script's message.
inline bool ProveCallSite(const ImageView& image, uint32_t call, Sites* sites) {
  uint32_t base = 0u;
  bool handed = false;
  for (uint32_t back = 6u; back <= 0x30u && back <= call; ++back) {
    if (DecodeLeaEdxDisp32(image, call - back, &base)) {
      handed = true;
      break;
    }
  }
  if (!handed) return false;
  const uint32_t from = call > kCallerWindow ? call - kCallerWindow : 0u;
  for (uint32_t k = from; k < call; ++k) {
    RowAddress row;
    if (!DecodeRowAddress(image, k, &row) || row.base != base) continue;
    if (row.stride < kMinStride || row.stride > kMaxStride) continue;
    bool counted = false;
    for (uint32_t back = 6u; back <= 0x30u && back <= call && !counted;
         ++back) {
      FieldLoad load;
      counted = DecodeFieldLoad(image, call - back, &load) &&
                (load.reg == 0u || load.reg == 1u) && load.disp == row.counter;
    }
    if (!counted) continue;
    if (sites->stride != 0u && sites->stride != row.stride) return false;
    sites->stride = row.stride;
    bool seen = false;
    for (uint32_t i = 0u; i < sites->base_count; ++i) {
      seen = seen || sites->bases[i] == base;
    }
    if (!seen && sites->base_count < sites->bases.size()) {
      sites->bases[sites->base_count++] = base;
    }
    return true;
  }
  return false;
}

inline SiteResult ResolveSites(const ImageView& image, Sites* out) {
  *out = Sites();
  const uint32_t set_text = FindExport(image, kExportSetText);
  const uint32_t box_fill = FindExport(image, kExportBoxFill);
  const uint32_t draw = FindExport(image, kExportDraw);
  if (set_text == 0u || box_fill == 0u || draw == 0u) {
    return SiteResult::kNoExports;
  }
  // Renderers: `mov eax,[eax+T]; call SetText` with BoxFill before it and
  // Draw after it inside the same function.
  std::array<Sites, kMaxRenderCandidates> candidates{};
  uint32_t candidate_count = 0u;
  bool any_renderer = false;
  for (size_t r = 0u; r < image.code_count; ++r) {
    for (uint32_t k = image.code[r].begin; k + 5u <= image.code[r].end; ++k) {
      uint32_t target = 0u;
      if (!CallTarget(image, k, &target) || target != set_text || k < 6u) {
        continue;
      }
      if (U8(image, k - 6u) != 0x8bu || U8(image, k - 5u) != 0x80u) continue;
      const uint32_t function =
          EnclosingFunction(image, k, kRenderPrefixWindow);
      if (function == 0u || !CallsWithin(image, function, k, box_fill) ||
          !CallsWithin(image, k + 5u, k + 5u + kRenderSuffixWindow, draw)) {
        continue;
      }
      any_renderer = true;
      bool duplicate = false;
      for (uint32_t i = 0u; i < candidate_count; ++i) {
        duplicate = duplicate || candidates[i].render == function;
      }
      if (duplicate) continue;
      if (candidate_count >= candidates.size()) return SiteResult::kAmbiguous;
      candidates[candidate_count].render = function;
      candidates[candidate_count].text_object = U32(image, k - 4u);
      ++candidate_count;
    }
  }
  if (!any_renderer) return SiteResult::kNoRenderer;
  // The message renderer: every call site is fed by a row-indexed page buffer.
  uint32_t accepted = 0u;
  for (uint32_t i = 0u; i < candidate_count; ++i) {
    Sites& c = candidates[i];
    bool all = true;
    for (size_t r = 0u; all && r < image.code_count; ++r) {
      for (uint32_t k = image.code[r].begin; all && k + 5u <= image.code[r].end;
           ++k) {
        uint32_t target = 0u;
        if (!CallTarget(image, k, &target) || target != c.render) continue;
        if (c.callers >= kMaxRenderCallers || !ProveCallSite(image, k, &c)) {
          all = false;
        } else {
          c.render_calls[c.callers++] = k;
        }
      }
    }
    if (!all || c.callers == 0u) continue;
    if (accepted != 0u) {
      *out = Sites();
      return SiteResult::kAmbiguous;
    }
    *out = c;
    accepted = 1u;
  }
  if (accepted == 0u) return SiteResult::kNoMessageRenderer;
  if (!HasFramePrologue(image, out->render)) {
    *out = Sites();
    return SiteResult::kBadPrologue;
  }
  return SiteResult::kResolved;
}

// ── the click wait ─────────────────────────────────────────────────────────
//
// The script's click wait runs one game method WAIT (eax = the game object):
// it tells the message window, in either window mode, to show the click-wait
// cursor:
//   mov r8,[MODE]; test r8,r8; je B
//   mov dl,1; mov eax,[ebx+WIN]; call <full-screen wait>; jmp E
//   B: mov dl,1; mov eax,[ebx+WIN]; call <adventure wait>
// MODE and WIN are the ones SHOWMSG (the caller of the window's row fillers)
// reads to pick the fill method.  A click unit ends at WAIT; the next row the
// window renders opens the next unit (the full-screen window keeps the
// previous units of its page on screen).

enum class WaitResult : uint32_t {
  kResolved = 0,
  kNoShowMessage = 1,  // no row-filler call site reads the window and mode
  kNoWait = 2,         // no function shows the wait cursor in both modes
  kAmbiguous = 3,
  kNoEntry = 4,        // the wait shape is not inside a called function
};

struct WaitSite {
  uint32_t wait = 0u;           // RVA of WAIT's entry
  uint32_t window_offset = 0u;  // WIN: the game object's message window
  uint32_t mode_global = 0u;    // MODE: absolute VA of the window-mode byte
};

// `mov al,[moffs32]` (A0) or `mov r8,[disp32]` (8A, mod=00, rm=101).
inline bool DecodeModeByteLoad(const ImageView& image, uint32_t rva,
                               uint32_t* va, uint32_t* length) {
  if (U8(image, rva) == 0xa0u) {
    *va = U32(image, rva + 1u);
    *length = 5u;
    return true;
  }
  if (U8(image, rva) == 0x8au && (U8(image, rva + 1u) & 0xc7u) == 0x05u) {
    *va = U32(image, rva + 2u);
    *length = 6u;
    return true;
  }
  return false;
}

// `mov eax,[ebx+disp8|disp32]` (8B 43 d8 / 8B 83 d32).
inline bool DecodeEaxFromEbx(const ImageView& image, uint32_t rva,
                             uint32_t* disp, uint32_t* length) {
  if (U8(image, rva) != 0x8bu) return false;
  if (U8(image, rva + 1u) == 0x43u) {
    *disp = U8(image, rva + 2u);
    *length = 3u;
    return true;
  }
  if (U8(image, rva + 1u) == 0x83u) {
    *disp = U32(image, rva + 2u);
    *length = 6u;
    return true;
  }
  return false;
}

// `mov dl,1; mov eax,[ebx+WIN]; call X` at rva; returns the bytes consumed.
inline uint32_t MatchWindowCall(const ImageView& image, uint32_t rva,
                                uint32_t window_offset) {
  if (U8(image, rva) != 0xb2u || U8(image, rva + 1u) != 0x01u) return 0u;
  uint32_t disp = 0u, length = 0u;
  if (!DecodeEaxFromEbx(image, rva + 2u, &disp, &length) ||
      disp != window_offset) {
    return 0u;
  }
  uint32_t target = 0u;
  if (!CallTarget(image, rva + 2u + length, &target)) return 0u;
  return 2u + length + 5u;
}

inline WaitResult ResolveWait(const ImageView& image, const Sites& sites,
                              WaitSite* out) {
  *out = WaitSite();
  // Row fillers: the functions that call RENDER.
  std::array<uint32_t, kMaxRenderCallers> fillers{};
  uint32_t filler_count = 0u;
  for (uint32_t i = 0u; i < sites.callers; ++i) {
    const uint32_t f =
        EnclosingFunction(image, sites.render_calls[i], kCallerWindow * 2u);
    bool seen = f == 0u;
    for (uint32_t j = 0u; j < filler_count; ++j) seen = seen || fillers[j] == f;
    if (!seen) fillers[filler_count++] = f;
  }
  // SHOWMSG: a filler call site `mov eax,[ebx+WIN]` right before the call and
  // a mode byte load before that.  Every such site must agree.
  uint32_t window_offset = 0u, mode_global = 0u;
  bool found = false;
  // Every E8 target once (WAIT's entry is among them).
  std::vector<uint32_t> targets;
  for (size_t r = 0u; r < image.code_count; ++r) {
    for (uint32_t k = image.code[r].begin; k + 5u <= image.code[r].end; ++k) {
      uint32_t t = 0u;
      if (!CallTarget(image, k, &t)) continue;
      if (InCode(image, t, 1u)) targets.push_back(t);
      bool is_filler = false;
      for (uint32_t j = 0u; j < filler_count; ++j) {
        is_filler = is_filler || fillers[j] == t;
      }
      if (!is_filler || k < 0x40u) continue;
      uint32_t win = 0u;
      bool has_win = false;
      for (uint32_t back = 3u; back <= 12u && !has_win; ++back) {
        uint32_t length = 0u;
        has_win = DecodeEaxFromEbx(image, k - back, &win, &length) &&
                  length <= back;
      }
      uint32_t mode = 0u;
      bool has_mode = false;
      for (uint32_t back = 5u; back <= 0x40u && !has_mode; ++back) {
        uint32_t length = 0u;
        has_mode = DecodeModeByteLoad(image, k - back, &mode, &length);
      }
      if (!has_win || !has_mode) continue;
      if (found && (win != window_offset || mode != mode_global)) {
        return WaitResult::kAmbiguous;
      }
      window_offset = win;
      mode_global = mode;
      found = true;
    }
  }
  if (!found) return WaitResult::kNoShowMessage;
  std::sort(targets.begin(), targets.end());
  // WAIT's body shape.  The window's restore path shows the cursor with the
  // same shape deep inside a long state function; WAIT is a short method whose
  // shape sits right after its entry (the nearest called address within
  // kWaitEntryWindow bytes before it).  Exactly one shape may have an entry.
  uint32_t entry = 0u;
  uint32_t entries = 0u;
  bool any_shape = false;
  for (size_t r = 0u; r < image.code_count; ++r) {
    for (uint32_t k = image.code[r].begin; k + 32u <= image.code[r].end; ++k) {
      uint32_t va = 0u, length = 0u;
      if (!DecodeModeByteLoad(image, k, &va, &length) || va != mode_global) {
        continue;
      }
      uint32_t at = k + length;
      if (U8(image, at) != 0x84u) continue;  // test r8,r8
      at += 2u;
      if (U8(image, at) != 0x74u) continue;  // je B
      const uint32_t branch = at + 2u + U8(image, at + 1u);
      at += 2u;
      const uint32_t first = MatchWindowCall(image, at, window_offset);
      if (first == 0u) continue;
      at += first;
      if (U8(image, at) != 0xebu || at + 2u != branch) continue;  // jmp E
      if (MatchWindowCall(image, branch, window_offset) == 0u) continue;
      any_shape = true;
      for (uint32_t back = 0u; back <= kWaitEntryWindow && back <= k; ++back) {
        if (std::binary_search(targets.begin(), targets.end(), k - back)) {
          entry = k - back;
          ++entries;
          break;
        }
      }
    }
  }
  if (!any_shape) return WaitResult::kNoWait;
  if (entries == 0u) return WaitResult::kNoEntry;
  if (entries > 1u) return WaitResult::kAmbiguous;
  out->wait = entry;
  out->window_offset = window_offset;
  out->mode_global = mode_global;
  return WaitResult::kResolved;
}

// ── page text ──────────────────────────────────────────────────────────────

inline bool IsCp932Lead(uint8_t b) {
  return (b >= 0x81u && b <= 0x9fu) || (b >= 0xe0u && b <= 0xfcu);
}

inline bool IsCp932Trail(uint8_t b) {
  return b >= 0x40u && b <= 0xfcu && b != 0x7fu;
}

// Length of the row text in a row buffer (up to the NUL), or SIZE_MAX when
// the buffer is not clean CP932 display text (control byte, broken pair, no
// terminator inside the stride).
inline size_t RowLength(const uint8_t* row, uint32_t stride) {
  for (size_t i = 0u; i < stride;) {
    const uint8_t b = row[i];
    if (b == 0u) return i;
    if (b < 0x20u || b == 0x7fu) return SIZE_MAX;
    if (IsCp932Lead(b)) {
      if (i + 1u >= stride || !IsCp932Trail(row[i + 1u])) return SIZE_MAX;
      i += 2u;
    } else {
      ++i;
    }
  }
  return SIZE_MAX;
}

inline constexpr uint8_t kNameOpen[2] = {0x81u, 0x79u};   // 【
inline constexpr uint8_t kNameClose[2] = {0x81u, 0x7au};  // 】
inline constexpr uint8_t kIdeographicSpace[2] = {0x81u, 0x40u};  // U+3000

// A row that is exactly one 【...】 group: the speaker name.
inline bool IsSpeakerRow(const uint8_t* row, size_t length) {
  if (length < 4u || std::memcmp(row, kNameOpen, 2u) != 0 ||
      std::memcmp(row + length - 2u, kNameClose, 2u) != 0) {
    return false;
  }
  for (size_t i = 2u; i + 2u < length;) {
    if (std::memcmp(row + i, kNameOpen, 2u) == 0 ||
        std::memcmp(row + i, kNameClose, 2u) == 0) {
      return false;
    }
    i += IsCp932Lead(row[i]) ? 2u : 1u;
  }
  return true;
}

enum class PageResult : uint32_t {
  kText = 0,       // `text` holds the page's dialogue so far
  kNameOnly = 1,   // only the speaker row is up yet
  kRejected = 2,   // a row is not clean text
};

// The click unit so far, rows first_row..last_row of a row array, as one
// CP932 string: the speaker row (the unit's first row in 【】) is dropped,
// rows are joined without a separator (the script wraps by width, not by
// word) and a continuation row's leading ideographic spaces (the quote
// indent) are dropped.  An empty row (a blank line between paragraphs) adds
// nothing.
inline PageResult ComposePage(const uint8_t* rows, uint32_t stride,
                              uint32_t first_row, uint32_t last_row,
                              std::string* text, bool* has_speaker) {
  text->clear();
  *has_speaker = false;
  if (stride < kMinStride || stride > kMaxStride || last_row >= kMaxRows ||
      first_row > last_row) {
    return PageResult::kRejected;
  }
  for (uint32_t r = first_row; r <= last_row; ++r) {
    const uint8_t* row = rows + static_cast<size_t>(r) * stride;
    const size_t length = RowLength(row, stride);
    if (length == SIZE_MAX) return PageResult::kRejected;
    if (r == first_row && IsSpeakerRow(row, length)) {
      *has_speaker = true;
      continue;
    }
    size_t start = 0u;
    if (!text->empty()) {
      while (start + 2u <= length &&
             std::memcmp(row + start, kIdeographicSpace, 2u) == 0) {
        start += 2u;
      }
    }
    text->append(reinterpret_cast<const char*>(row + start), length - start);
  }
  return text->empty() && *has_speaker ? PageResult::kNameOnly
                                       : PageResult::kText;
}

// ── in-game lookup: geometry sites ─────────────────────────────────────────
//
// Where a row sits: RENDER clears the row's band and copies the rendered row
// into the panel layer at (0, row * PITCH), WIDTH x HEIGHT:
//   shl r,imm8; lea r,[r+r*s]                 PITCH = (1 << imm8) * (1 + s)
//   push WIDTH (68 imm32); push HEIGHT (6A imm8); ...; call THyAlpha::Draw
// The row is MS Gothic at HEIGHT pixels: a CP932 byte is HEIGHT / 2 wide.
// The panel: every RENDER call site that shows a row on screen is followed by
// `mov eax,[ebx+P]; call THyRGBPanel::SetModify` for the panel of the row
// array it was handed.  A panel's position is its own offset plus its
// parents' (the exported THyRGBPanel::ClientToScreen walks
// `mov ebx,[eax+X]; add [edx],ebx; mov ebx,[eax+Y]; add [ecx],ebx;
// mov esi,[eax+PARENT]`), and THyRGBPanel::SetVisible reads its shown flag
// first (`mov cl,[eax+V]`).

inline constexpr char kExportSetModify[] = "@THyRGBPanel@SetModify$qqrv";
inline constexpr char kExportClientToScreen[] =
    "@THyRGBPanel@ClientToScreen$qqrrit1";
inline constexpr char kExportSetVisible[] = "@THyRGBPanel@SetVisible$qqro";

inline constexpr uint32_t kMaxPanelChain = 16u;
inline constexpr int32_t kMinDesignSide = 64;
inline constexpr int32_t kMaxDesignSide = 8192;
inline constexpr uint16_t kNoSource = 0xffffu;

struct LookupSites {
  uint32_t row_pitch = 0u;
  uint32_t row_width = 0u;
  uint32_t row_height = 0u;
  uint32_t panel_x = 0u;
  uint32_t panel_y = 0u;
  uint32_t panel_parent = 0u;
  uint32_t panel_shown = 0u;
  std::array<uint32_t, 4> array_base{};
  std::array<uint32_t, 4> array_panel{};
  uint32_t array_count = 0u;
};

enum class LookupSiteResult : uint32_t {
  kResolved = 0,
  kNoPanelExports = 1,
  kNoRowLayout = 2,
  kNoPanelFields = 3,
  kNoArrayPanel = 4,
  kAmbiguous = 5,
};

// The panel of the row array `base`, or 0.
inline uint32_t ArrayPanel(const LookupSites& sites, uint32_t base) {
  for (uint32_t i = 0u; i < sites.array_count; ++i) {
    if (sites.array_base[i] == base) return sites.array_panel[i];
  }
  return 0u;
}

inline LookupSiteResult ResolveLookupSites(const ImageView& image,
                                           const Sites& sites,
                                           LookupSites* out) {
  *out = LookupSites();
  const uint32_t set_modify = FindExport(image, kExportSetModify);
  const uint32_t client_to_screen = FindExport(image, kExportClientToScreen);
  const uint32_t set_visible = FindExport(image, kExportSetVisible);
  const uint32_t draw = FindExport(image, kExportDraw);
  if (set_modify == 0u || client_to_screen == 0u || set_visible == 0u ||
      draw == 0u || sites.render == 0u) {
    return LookupSiteResult::kNoPanelExports;
  }
  // Row layout inside RENDER (up to its Draw call).
  uint32_t draw_call = 0u;
  for (uint32_t k = sites.render; k < sites.render + 0x100u; ++k) {
    uint32_t t = 0u;
    if (CallTarget(image, k, &t) && t == draw) {
      draw_call = k;
      break;
    }
  }
  if (draw_call == 0u) return LookupSiteResult::kNoRowLayout;
  for (uint32_t k = sites.render; k + 6u <= draw_call; ++k) {
    // shl r,imm8 (C1 /4, mod=11) then lea r,[r+r*s] (8D, SIB base=index=r).
    const uint8_t m = U8(image, k + 1u);
    if (U8(image, k) != 0xc1u || (m & 0xf8u) != 0xe0u) continue;
    const uint8_t reg = static_cast<uint8_t>(m & 7u);
    const uint8_t shift = U8(image, k + 2u);
    for (uint32_t j = k + 3u; j < k + 12u && j + 3u <= draw_call; ++j) {
      if (U8(image, j) != 0x8du) continue;
      const uint8_t lm = U8(image, j + 1u);
      const uint8_t sib = U8(image, j + 2u);
      if ((lm >> 6) != 0u || (lm & 7u) != 4u ||
          ((lm >> 3) & 7u) != reg || (sib & 7u) != reg ||
          ((sib >> 3) & 7u) != reg || (sib >> 6) == 0u || shift > 8u) {
        continue;
      }
      out->row_pitch = (1u << shift) * (1u + (1u << (sib >> 6)));
      break;
    }
    if (out->row_pitch != 0u) break;
  }
  for (uint32_t back = 7u; back <= 0x18u && back <= draw_call; ++back) {
    const uint32_t k = draw_call - back;
    if (U8(image, k) == 0x68u && U8(image, k + 5u) == 0x6au) {
      out->row_width = U32(image, k + 1u);
      out->row_height = U8(image, k + 6u);
      break;
    }
  }
  if (out->row_pitch == 0u || out->row_height < 8u ||
      out->row_height > out->row_pitch || out->row_height % 2u != 0u ||
      out->row_width < out->row_height ||
      out->row_width / (out->row_height / 2u) > sites.stride) {
    *out = LookupSites();
    return LookupSiteResult::kNoRowLayout;
  }
  // Panel fields from the exported panel methods.
  {
    uint32_t k = client_to_screen;
    while (k < client_to_screen + 4u && U8(image, k) != 0x8bu) ++k;
    if (U8(image, k) != 0x8bu || U8(image, k + 1u) != 0x58u ||
        U8(image, k + 3u) != 0x01u || U8(image, k + 5u) != 0x8bu ||
        U8(image, k + 6u) != 0x58u || U8(image, k + 8u) != 0x01u ||
        U8(image, k + 10u) != 0x8bu || U8(image, k + 11u) != 0x70u) {
      *out = LookupSites();
      return LookupSiteResult::kNoPanelFields;
    }
    out->panel_x = U8(image, k + 2u);
    out->panel_y = U8(image, k + 7u);
    out->panel_parent = U8(image, k + 12u);
  }
  if (U8(image, set_visible) != 0x8au || U8(image, set_visible + 1u) != 0x48u) {
    *out = LookupSites();
    return LookupSiteResult::kNoPanelFields;
  }
  out->panel_shown = U8(image, set_visible + 2u);
  // Each row array's panel.
  for (uint32_t i = 0u; i < sites.callers; ++i) {
    const uint32_t call = sites.render_calls[i];
    uint32_t base = 0u;
    bool handed = false;
    for (uint32_t back = 6u; back <= 0x30u && back <= call && !handed;
         ++back) {
      handed = DecodeLeaEdxDisp32(image, call - back, &base);
    }
    uint32_t panel = 0u, length = 0u, t = 0u;
    if (!handed ||
        !DecodeEaxFromEbx(image, call + 5u, &panel, &length) ||
        !CallTarget(image, call + 5u + length, &t) || t != set_modify) {
      continue;
    }
    const uint32_t known = ArrayPanel(*out, base);
    if (known != 0u && known != panel) {
      *out = LookupSites();
      return LookupSiteResult::kAmbiguous;
    }
    if (known == 0u && out->array_count < out->array_base.size()) {
      out->array_base[out->array_count] = base;
      out->array_panel[out->array_count] = panel;
      ++out->array_count;
    }
  }
  for (uint32_t i = 0u; i < sites.base_count; ++i) {
    if (ArrayPanel(*out, sites.bases[i]) == 0u) {
      *out = LookupSites();
      return LookupSiteResult::kNoArrayPanel;
    }
  }
  return LookupSiteResult::kResolved;
}

// ── in-game lookup: unit glyphs ────────────────────────────────────────────

// A glyph of the unit, in the panel's pixels, with its UTF-16 unit index in
// the published line (every CP932 character is one UTF-16 unit).
struct UnitGlyph {
  int32_t x = 0;
  int32_t y = 0;
  int32_t w = 0;
  int32_t h = 0;
  uint16_t source_index = kNoSource;
};

inline constexpr size_t kMaxUnitGlyphs = kMaxRows * kMaxStride;

// The glyphs of the unit the published line came from, exactly in the order
// ComposePage joined them (speaker row and continuation indent skipped).
// Returns the glyph count, or 0 when the rows are not clean text.
inline size_t BuildUnitGlyphs(const uint8_t* rows, uint32_t stride,
                              uint32_t first_row, uint32_t last_row,
                              const LookupSites& layout, UnitGlyph* out,
                              size_t capacity) {
  if (stride < kMinStride || stride > kMaxStride || last_row >= kMaxRows ||
      first_row > last_row || layout.row_height == 0u) {
    return 0u;
  }
  const int32_t byte_w = static_cast<int32_t>(layout.row_height / 2u);
  size_t count = 0u;
  uint32_t source = 0u;
  for (uint32_t r = first_row; r <= last_row; ++r) {
    const uint8_t* row = rows + static_cast<size_t>(r) * stride;
    const size_t length = RowLength(row, stride);
    if (length == SIZE_MAX) return 0u;
    if (r == first_row && IsSpeakerRow(row, length)) continue;
    size_t start = 0u;
    if (source != 0u) {
      while (start + 2u <= length &&
             std::memcmp(row + start, kIdeographicSpace, 2u) == 0) {
        start += 2u;
      }
    }
    for (size_t b = start; b < length;) {
      const size_t bytes = IsCp932Lead(row[b]) ? 2u : 1u;
      if (count >= capacity || source >= kNoSource) return 0u;
      UnitGlyph& g = out[count++];
      g.x = static_cast<int32_t>(b) * byte_w;
      g.y = static_cast<int32_t>((r * layout.row_pitch));
      g.w = static_cast<int32_t>(bytes) * byte_w;
      g.h = static_cast<int32_t>(layout.row_height);
      g.source_index = static_cast<uint16_t>(source++);
      if (g.x + g.w > static_cast<int32_t>(layout.row_width)) return 0u;
      b += bytes;
    }
  }
  return count;
}

// ── projection, hit testing, click claim ───────────────────────────────────

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

// A design-pixel rect onto a client of physical_w x physical_h that shows the
// whole design screen (a stretched DPI-unaware window or a full screen).
inline bool ProjectRect(int32_t x, int32_t y, int32_t w, int32_t h,
                        int32_t design_w, int32_t design_h, int32_t physical_w,
                        int32_t physical_h, PixelRect* out) {
  if (out == nullptr || !DesignPlausible(design_w, design_h) ||
      physical_w <= 0 || physical_h <= 0 || w <= 0 || h <= 0 || x < 0 ||
      y < 0 || x + w > design_w || y + h > design_h) {
    return false;
  }
  const double sx = static_cast<double>(physical_w) / design_w;
  const double sy = static_cast<double>(physical_h) / design_h;
  const int32_t x0 = static_cast<int32_t>(x * sx);
  const int32_t y0 = static_cast<int32_t>(y * sy);
  const double right = (x + w) * sx;
  const double bottom = (y + h) * sy;
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

// The one glyph under a design-pixel point (glyph boxes offset by the
// panel's origin), or false when none or the point is ambiguous.
inline bool HitTestGlyphs(const UnitGlyph* glyphs, size_t count,
                          int32_t origin_x, int32_t origin_y, int32_t x,
                          int32_t y, size_t* hit) {
  if (glyphs == nullptr || hit == nullptr) return false;
  size_t found = count;
  for (size_t i = 0u; i < count; ++i) {
    const UnitGlyph& g = glyphs[i];
    const int32_t gx = origin_x + g.x;
    const int32_t gy = origin_y + g.y;
    if (x < gx || y < gy || x >= gx + g.w || y >= gy + g.h) continue;
    if (found != count) return false;
    found = i;
  }
  if (found == count) return false;
  *hit = found;
  return true;
}

// The engine reads clicks only as window messages (no key-state polling), so
// the claim lives in the game window's procedure, for mouse and promoted
// touch alike: a press on a glyph is swallowed together with its own UP.
// When that UP never arrives, the next DOWN drops the stale claim, so it can
// never eat the UP of a later, unrelated press.
enum class ButtonMessage : uint8_t { kOther = 0, kDown = 1, kUp = 2 };

struct ClaimDecision {
  bool evaluate = false;  // a DOWN: test it against the model
  bool swallow = false;   // the UP of a claimed press
};

inline ClaimDecision DecideButtonMessage(ButtonMessage message,
                                         bool* up_pending) {
  ClaimDecision decision;
  if (up_pending == nullptr) return decision;
  if (message == ButtonMessage::kDown) {
    *up_pending = false;
    decision.evaluate = true;
  } else if (message == ButtonMessage::kUp) {
    decision.swallow = *up_pending;
    *up_pending = false;
  }
  return decision;
}

}  // namespace fushi_voice_hook::kogado_hy
