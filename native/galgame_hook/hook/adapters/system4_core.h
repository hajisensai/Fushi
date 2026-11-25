#pragma once

// AliceSoft System 4 (SACT2 HLL generation) engine facts and every decision
// rule of the adapter, free of hooks and globals so the unit tests drive them
// directly.
//
// Measured on 戦国ランス (System40.exe + DLL\Sys42VM.dll 2.2.7 + DLL\SACT2.dll
// 2.1.1, 2026-11-11):
//   * HLL ABI: the VM calls the HLL library SACT2.dll through its named
//     exports, cdecl, every argument one 32-bit stack slot; a string argument
//     is an object whose first virtual (thiscall, no argument) returns the
//     CP932 bytes.
//   * Message text: the VM's MSG instruction handler (a stdcall function of
//     the VM module taking the VM object) reads the message number at the
//     code pointer and the CP932 line from the VM's message table, then runs
//     the game's message function.  One MSG is one display line; the lines
//     of a page arrive back to back.
//   * Drawing: the game's message function then draws the line one character
//     per SP_TextDraw(int sprite, string text, metrics) call, synchronously
//     on the VM thread, at the sprite's text position (SP_GetTextPosX / Y,
//     sprite-local pixels; the call advances X by the glyph).  The metrics
//     object's fourth virtual (thiscall, int 0) returns the raw metrics block
//     whose +0x0c is the font size.  A new page clears the sprite
//     (SP_TextClear) or deletes and recreates it (SP_Delete) before its MSGs.
//   * Placement: SP_GetPosX / Y(sprite) in design pixels, SP_SetPos /
//     SP_SetShow / SP_Delete change it, GetScreenWidth / GetScreenHeight()
//     the design screen.
//   * Input: neither the executable nor any HLL library samples a key or
//     button (no GetAsyncKeyState / GetKeyState / GetKeyboardState import,
//     no touch registration); the left button reaches the engine as window
//     messages only.

#include <windows.h>

#include <algorithm>
#include <cstdint>
#include <cstring>

namespace fushi_voice_hook {
namespace system4 {

// ── identity ───────────────────────────────────────────────────────────────

// The SACT2 HLL surface the adapter binds.  A module exporting all of them is
// the engine's sprite/text library; names alone, never a file name or hash.
constexpr const char* kRequiredExports[] = {
    "SP_TextDraw",    "SP_TextClear",   "SP_GetTextPosX", "SP_GetTextPosY",
    "SP_GetPosX",     "SP_GetPosY",     "SP_GetShow",     "SP_SetShow",
    "SP_SetPos",      "SP_Delete",      "GetScreenWidth", "GetScreenHeight",
};
constexpr size_t kRequiredExportCount =
    sizeof(kRequiredExports) / sizeof(kRequiredExports[0]);

// A module image laid out by section (a loaded module or a test image).
struct ExportView {
  const uint8_t* bytes = nullptr;
  size_t size = 0u;
  uint32_t export_rva = 0u;
  uint32_t export_size = 0u;
};

inline bool ExportNameAt(const ExportView& view, uint32_t rva,
                         const char* name) {
  const size_t length = std::strlen(name);
  if (rva >= view.size || length + 1u > view.size - rva) return false;
  return std::memcmp(view.bytes + rva, name, length + 1u) == 0;
}

// The RVA of an exported function by name, 0 when absent.
inline uint32_t FindExportRva(const ExportView& view, const char* name) {
  if (view.bytes == nullptr || view.export_rva == 0u ||
      view.export_rva >= view.size ||
      sizeof(IMAGE_EXPORT_DIRECTORY) > view.size - view.export_rva) {
    return 0u;
  }
  IMAGE_EXPORT_DIRECTORY dir;
  std::memcpy(&dir, view.bytes + view.export_rva, sizeof(dir));
  if (dir.NumberOfNames > 0x10000u || dir.AddressOfNames >= view.size ||
      dir.AddressOfNameOrdinals >= view.size ||
      dir.AddressOfFunctions >= view.size ||
      static_cast<size_t>(dir.NumberOfNames) * 4u >
          view.size - dir.AddressOfNames ||
      static_cast<size_t>(dir.NumberOfNames) * 2u >
          view.size - dir.AddressOfNameOrdinals) {
    return 0u;
  }
  for (uint32_t i = 0u; i < dir.NumberOfNames; ++i) {
    uint32_t name_rva = 0u;
    std::memcpy(&name_rva, view.bytes + dir.AddressOfNames + i * 4u, 4u);
    if (!ExportNameAt(view, name_rva, name)) continue;
    uint16_t ordinal = 0u;
    std::memcpy(&ordinal, view.bytes + dir.AddressOfNameOrdinals + i * 2u, 2u);
    if (ordinal >= dir.NumberOfFunctions ||
        static_cast<size_t>(ordinal) * 4u + 4u >
            view.size - dir.AddressOfFunctions) {
      return 0u;
    }
    uint32_t function = 0u;
    std::memcpy(&function, view.bytes + dir.AddressOfFunctions + ordinal * 4u,
                4u);
    // A forwarder points back into the export directory: not code.
    if (function >= view.export_rva &&
        function < view.export_rva + view.export_size) {
      return 0u;
    }
    return function < view.size ? function : 0u;
  }
  return 0u;
}

inline bool HasSact2Exports(const ExportView& view) {
  for (const char* name : kRequiredExports) {
    if (FindExportRva(view, name) == 0u) return false;
  }
  return true;
}

// ── the VM's MSG handler ───────────────────────────────────────────────────
//
// Located structurally in the VM module: the handler reports a message number
// outside the table with its own diagnostic, 「存在しない文字列データー%d：
// 命令コード【 CallMessage 】」, so the one function pushing that string is
// the handler.  The VM object offsets it uses are decoded from its own code
// (template below); any byte that differs installs nothing.

// CP932 「存在しない文字列データー」 and 「：命令コード【 CallMessage 】」.
constexpr uint8_t kMsgDiagPrefix[] = {
    0x91, 0xb6, 0x8d, 0xdd, 0x82, 0xb5, 0x82, 0xc8, 0x82, 0xa2, 0x95, 0xb6,
    0x8e, 0x9a, 0x97, 0xf1, 0x83, 0x66, 0x81, 0x5b, 0x83, 0x5e, 0x81, 0x5b};
constexpr uint8_t kMsgDiagSuffix[] = {
    0x81, 0x46, 0x96, 0xbd, 0x97, 0xdf, 0x83, 0x52, 0x81, 0x5b,
    0x83, 0x68, 0x81, 0x79, 0x20, 0x43, 0x61, 0x6c, 0x6c, 0x4d,
    0x65, 0x73, 0x73, 0x61, 0x67, 0x65, 0x20, 0x81, 0x7a};

// A module image addressed by RVA (a loaded module or a test image).
struct ImageView {
  const uint8_t* bytes = nullptr;
  size_t size = 0u;
  uint32_t image_base = 0u;  // the VA the image's absolute operands use
};

// The RVA of the NUL-terminated diagnostic 「<prefix>%d<suffix>」, 0 if none.
inline uint32_t FindMsgDiagString(const ImageView& view) {
  const size_t prefix = sizeof(kMsgDiagPrefix);
  const size_t suffix = sizeof(kMsgDiagSuffix);
  const size_t total = prefix + 2u + suffix + 1u;
  if (view.bytes == nullptr || view.size < total) return 0u;
  for (size_t i = 0u; i + total <= view.size; ++i) {
    if (view.bytes[i] != kMsgDiagPrefix[0] ||
        std::memcmp(view.bytes + i, kMsgDiagPrefix, prefix) != 0 ||
        view.bytes[i + prefix] != '%' || view.bytes[i + prefix + 1u] != 'd' ||
        std::memcmp(view.bytes + i + prefix + 2u, kMsgDiagSuffix, suffix) !=
            0 ||
        view.bytes[i + total - 1u] != 0u) {
      continue;
    }
    // A string, not the tail of a longer one.
    if (i != 0u && view.bytes[i - 1u] != 0u) continue;
    return static_cast<uint32_t>(i);
  }
  return 0u;
}

// The RVA of the only `push imm32` of `va`; 0 when none or more than one.
inline uint32_t FindUniquePush(const ImageView& view, uint32_t va) {
  uint32_t found = 0u;
  for (size_t i = 0u; i + 5u <= view.size; ++i) {
    if (view.bytes[i] != 0x68u) continue;
    uint32_t operand = 0u;
    std::memcpy(&operand, view.bytes + i + 1u, 4u);
    if (operand != va) continue;
    if (found != 0u) return 0u;
    found = static_cast<uint32_t>(i);
  }
  return found;
}

// What the handler reads off the VM object (byte offsets into it).
struct MsgLayout {
  uint32_t handler_rva = 0u;
  uint32_t code_ptr = 0u;     // int* : the instruction operand (message no.)
  uint32_t code_end = 0u;     // end of the code
  uint32_t msg_func = 0u;     // int : the game's message function, < 0 none
  uint32_t table_begin = 0u;  // 16-byte entries; entry + 4 is the char*
  uint32_t table_end = 0u;
};

constexpr uint32_t kMsgEntryBytes = 16u;
constexpr uint32_t kMsgEntryTextOffset = 4u;

// `pattern` against `bytes`; 0x100 in the pattern is any byte.
inline bool MatchTemplate(const uint8_t* bytes, size_t avail,
                          const uint16_t* pattern, size_t length) {
  if (length > avail) return false;
  for (size_t i = 0u; i < length; ++i) {
    if (pattern[i] != 0x100u && bytes[i] != pattern[i]) return false;
  }
  return true;
}

inline uint32_t ReadU32(const uint8_t* p) {
  uint32_t v = 0u;
  std::memcpy(&v, p, 4u);
  return v;
}

constexpr uint16_t kAny = 0x100u;

// The handler prologue up to its message-function test (2.2.7):
//   mov eax,fs:[0]; push -1; push <scope>; push eax; mov fs:[0],esp;
//   sub esp,18h; push ebp; mov ebp,[esp+2Ch]      ; the VM object
//   mov eax,[ebp+CODE]; test eax,eax; jz; lea ecx,[eax+4];
//   cmp ecx,[ebp+END]; ja; push ebx; mov ebx,[eax]; mov eax,[ebp+MSGF]
constexpr uint16_t kHandlerTemplate[] = {
    0x64, 0xa1, 0x00, 0x00, 0x00, 0x00,              // +00
    0x6a, 0xff, 0x68, kAny, kAny, kAny, kAny,        // +06
    0x50, 0x64, 0x89, 0x25, 0x00, 0x00, 0x00, 0x00,  // +0d
    0x83, 0xec, kAny, 0x55, 0x8b, 0x6c, 0x24, kAny,  // +15
    0x8b, 0x85, kAny, kAny, kAny, kAny,              // +1d CODE
    0x85, 0xc0, 0x74, kAny, 0x8d, 0x48, 0x04,        // +23
    0x3b, 0x8d, kAny, kAny, kAny, kAny,              // +2a END
    0x77, kAny, 0x53, 0x8b, 0x18,                    // +30
    0x8b, 0x85, kAny, kAny, kAny, kAny,              // +35 MSGF
};
constexpr size_t kHandlerCodeAt = 0x1f;
constexpr size_t kHandlerEndAt = 0x2c;
constexpr size_t kHandlerMsgfAt = 0x37;
constexpr size_t kHandlerFrameAt = 0x17;  // sub esp, N
constexpr size_t kHandlerArgAt = 0x1c;    // [esp+N]: the VM argument

// The table lookup call: lea edi,[ebp+HOLDER] ... mov esi,edi; call <get>
// where <get> starts test eax,eax; jl; mov edx,[esi+VEC]; ... mov ecx,
// [esi+VEC+4] (begin / end of a vector of 16-byte entries).
constexpr uint16_t kGetTemplate[] = {0x85, 0xc0, 0x7c, kAny, 0x8b,
                                     0x56, kAny, 0x85, 0xd2, 0x75,
                                     kAny, 0x33, 0xc9, 0xeb, kAny,
                                     0x8b, 0x4e, kAny, 0x2b, 0xca,
                                     0xc1, 0xf9, 0x04};

constexpr uint32_t kHandlerScan = 0x400u;

inline bool DecodeMsgHandler(const ImageView& view, MsgLayout* out) {
  const uint32_t text = FindMsgDiagString(view);
  if (text == 0u) return false;
  const uint32_t push = FindUniquePush(view, view.image_base + text);
  if (push == 0u) return false;
  // The handler entry: the nearest prologue before the push.
  const uint32_t lowest = push > kHandlerScan ? push - kHandlerScan : 0u;
  uint32_t start = 0u;
  bool have = false;
  for (uint32_t at = push; at-- > lowest;) {
    if (MatchTemplate(view.bytes + at, view.size - at, kHandlerTemplate,
                      sizeof(kHandlerTemplate) / sizeof(kHandlerTemplate[0]))) {
      start = at;
      have = true;
      break;
    }
  }
  if (!have) return false;
  const uint8_t* fn = view.bytes + start;
  // The VM argument is the first stack argument: 3 pushes of the SEH frame,
  // the locals and ebp above the return address.
  if (fn[kHandlerArgAt] != 12u + fn[kHandlerFrameAt] + 4u + 4u) return false;
  MsgLayout layout;
  layout.handler_rva = start;
  layout.code_ptr = ReadU32(fn + kHandlerCodeAt);
  layout.code_end = ReadU32(fn + kHandlerEndAt);
  layout.msg_func = ReadU32(fn + kHandlerMsgfAt);
  // lea edi,[ebp+HOLDER] then mov esi,edi; call <get>, between the prologue
  // and the push.
  bool table = false;
  for (uint32_t at = start + sizeof(kHandlerTemplate) / 2u;
       at + 3u <= push && !table; ++at) {
    const uint8_t* p = view.bytes + at;
    // push edi; lea edi,[ebp+HOLDER]
    if (p[-1] != 0x57u || p[0] != 0x8du || p[1] != 0x7du) continue;
    const uint32_t holder = p[2];
    for (uint32_t c = at + 3u; c + 7u <= push; ++c) {
      const uint8_t* q = view.bytes + c;
      if (q[0] != 0x8bu || q[1] != 0xf7u || q[2] != 0xe8u) continue;
      const int32_t rel = static_cast<int32_t>(ReadU32(q + 3));
      const int64_t target = static_cast<int64_t>(c) + 7 + rel;
      if (target < 0 || static_cast<uint64_t>(target) >= view.size) break;
      const uint8_t* get = view.bytes + target;
      if (!MatchTemplate(get, view.size - static_cast<size_t>(target),
                         kGetTemplate,
                         sizeof(kGetTemplate) / sizeof(kGetTemplate[0])) ||
          get[0x11] != static_cast<uint8_t>(get[6] + 4u)) {
        break;
      }
      layout.table_begin = holder + get[6];
      layout.table_end = layout.table_begin + 4u;
      table = true;
      break;
    }
  }
  if (!table || layout.code_ptr == 0u || layout.code_ptr > 0x10000u ||
      layout.code_end > 0x10000u || layout.msg_func > 0x10000u) {
    return false;
  }
  *out = layout;
  return true;
}

// ── CP932 ──────────────────────────────────────────────────────────────────

inline bool IsCp932LeadByte(uint8_t c) {
  return (c >= 0x81u && c <= 0x9fu) || (c >= 0xe0u && c <= 0xfcu);
}

inline uint32_t Cp932CharLength(const char* bytes, uint32_t length) {
  if (length == 0u) return 0u;
  const uint8_t c = static_cast<uint8_t>(bytes[0]);
  if (c < 0x20u) return 0u;  // a control byte is not text
  const uint32_t width = IsCp932LeadByte(c) ? 2u : 1u;
  return width <= length ? width : 0u;
}

// ── page groups ────────────────────────────────────────────────────────────
//
// The MSG lines of one page form a group.  The draws that follow are matched
// to the group's characters one by one, in order, on one sprite; a group whose
// every character was matched carries its glyph geometry.  A group ends when
// its last character is drawn, when the next MSG comes after its draws began,
// or when its sprite is cleared / deleted; it is then committed (its text
// always, its geometry only when complete).

constexpr uint32_t kMaxGroupBytes = 1024u;
constexpr uint32_t kMaxGroupChars = 384u;
constexpr uint32_t kMaxGroupLines = 16u;

// One character of a group, sprite-local pixels.
struct GroupGlyph {
  int32_t x = 0;
  int32_t y = 0;
  int32_t w = 0;
  int32_t h = 0;
};

struct Group {
  uint32_t bytes_len = 0u;
  char bytes[kMaxGroupBytes] = {};
  uint32_t line_count = 0u;
  uint32_t char_count = 0u;
  uint16_t char_start[kMaxGroupChars] = {};
  uint8_t char_len[kMaxGroupChars] = {};
  uint32_t matched = 0u;
  int32_t sprite = 0;  // the sprite drawing it, 0 before the first match
  bool broken = false;  // a draw on that sprite did not match
  GroupGlyph glyphs[kMaxGroupChars] = {};
};

inline void ResetGroup(Group* g) {
  g->bytes_len = 0u;
  g->line_count = 0u;
  g->char_count = 0u;
  g->matched = 0u;
  g->sprite = 0;
  g->broken = false;
}

inline bool GroupStarted(const Group& g) { return g.matched > 0u || g.broken; }
inline bool GroupComplete(const Group& g) {
  return g.char_count > 0u && g.matched == g.char_count && !g.broken;
}

enum class MessageResult : uint32_t {
  kAppended = 0,
  kCommitFirst = 1,  // commit the current group, reset it, then append
  kRejected = 2,     // not clean CP932 text: nothing appended
};

// A MSG line.  The caller commits and resets on kCommitFirst and calls again.
inline MessageResult OnMessage(Group* g, const char* bytes, uint32_t length) {
  if (GroupStarted(*g)) return MessageResult::kCommitFirst;
  if (length == 0u) return MessageResult::kRejected;
  uint32_t chars = 0u;
  for (uint32_t i = 0u; i < length;) {
    const uint32_t width = Cp932CharLength(bytes + i, length - i);
    if (width == 0u) return MessageResult::kRejected;
    i += width;
    ++chars;
  }
  if (g->char_count > 0u &&
      (g->bytes_len + length > kMaxGroupBytes ||
       g->char_count + chars > kMaxGroupChars ||
       g->line_count >= kMaxGroupLines)) {
    return MessageResult::kCommitFirst;
  }
  if (length > kMaxGroupBytes || chars > kMaxGroupChars) {
    return MessageResult::kRejected;
  }
  for (uint32_t i = 0u; i < length;) {
    const uint32_t width = Cp932CharLength(bytes + i, length - i);
    g->char_start[g->char_count] = static_cast<uint16_t>(g->bytes_len + i);
    g->char_len[g->char_count] = static_cast<uint8_t>(width);
    ++g->char_count;
    i += width;
  }
  std::memcpy(g->bytes + g->bytes_len, bytes, length);
  g->bytes_len += length;
  ++g->line_count;
  return MessageResult::kAppended;
}

enum class DrawResult : uint32_t {
  kIgnored = 0,   // not this group's (another sprite, or no group)
  kMatched = 1,
  kComplete = 2,  // matched its last character: commit
  kBroken = 3,    // on the group's sprite but not its next character
};

inline DrawResult OnDraw(Group* g, int32_t sprite, const char* bytes,
                         uint32_t length, const GroupGlyph& glyph) {
  if (g->char_count == 0u || g->matched >= g->char_count || g->broken) {
    return DrawResult::kIgnored;
  }
  if (g->sprite != 0 && sprite != g->sprite) return DrawResult::kIgnored;
  const uint32_t at = g->matched;
  const bool same = length == g->char_len[at] &&
                    std::memcmp(bytes, g->bytes + g->char_start[at], length) ==
                        0;
  if (!same) {
    // Before the first match a draw elsewhere (a name plate) is not ours.
    if (g->sprite == 0) return DrawResult::kIgnored;
    g->broken = true;
    return DrawResult::kBroken;
  }
  g->sprite = sprite;
  g->glyphs[at] = glyph;
  ++g->matched;
  return g->matched == g->char_count ? DrawResult::kComplete
                                     : DrawResult::kMatched;
}

// SP_TextClear / SP_Delete of `sprite`: true when the group is committed.
inline bool OnSpriteCleared(const Group& g, int32_t sprite) {
  return g.char_count > 0u && g.sprite != 0 && g.sprite == sprite;
}

// The glyph a draw covered: the text position before and after it (sprite
// pixels) and the font size.  An advance that is not to the right (a
// wrap) or larger than two cells falls back to the font size.
inline GroupGlyph GlyphFromDraw(int32_t x_before, int32_t y_before,
                                int32_t x_after, int32_t font_size) {
  GroupGlyph g;
  g.x = x_before;
  g.y = y_before;
  const int32_t advance = x_after - x_before;
  g.w = advance > 0 && advance <= font_size * 2 ? advance : font_size;
  g.h = font_size;
  return g;
}

inline bool FontSizePlausible(int32_t size) { return size >= 6 && size <= 256; }

// ── placement ──────────────────────────────────────────────────────────────

constexpr int32_t kMinDesignSide = 320;
constexpr int32_t kMaxDesignSide = 8192;

inline bool DesignPlausible(int32_t w, int32_t h) {
  return w >= kMinDesignSide && h >= kMinDesignSide / 2 &&
         w <= kMaxDesignSide && h <= kMaxDesignSide;
}

// The design screen over a client.  The engine stretches it over the window
// (measured windowed: client = design); a client of another aspect ratio
// (letterboxed full screen, unmeasured) is refused rather than guessed.
struct Viewport {
  double scale_x = 0.0;
  double scale_y = 0.0;
};

inline bool ComputeViewport(int32_t design_w, int32_t design_h,
                            int32_t client_w, int32_t client_h,
                            Viewport* out) {
  if (!DesignPlausible(design_w, design_h) || client_w <= 0 || client_h <= 0) {
    return false;
  }
  const int64_t cross = static_cast<int64_t>(client_w) * design_h -
                        static_cast<int64_t>(client_h) * design_w;
  // 1% of the client's own extent.
  const int64_t tolerance = static_cast<int64_t>(client_w) * design_h / 100;
  if (cross > tolerance || -cross > tolerance) return false;
  out->scale_x = static_cast<double>(client_w) / design_w;
  out->scale_y = static_cast<double>(client_h) / design_h;
  return true;
}

struct PixelRect {
  int32_t x = 0;
  int32_t y = 0;
  int32_t w = 0;
  int32_t h = 0;
};

inline bool DesignRectToClient(const Viewport& v, double x, double y, double w,
                               double h, PixelRect* out) {
  if (v.scale_x <= 0.0 || v.scale_y <= 0.0 || w <= 0.0 || h <= 0.0) {
    return false;
  }
  const double left = x * v.scale_x;
  const double top = y * v.scale_y;
  const double right = (x + w) * v.scale_x;
  const double bottom = (y + h) * v.scale_y;
  out->x = static_cast<int32_t>(left + 0.5);
  out->y = static_cast<int32_t>(top + 0.5);
  out->w = (std::max)(1, static_cast<int32_t>(right + 0.5) - out->x);
  out->h = (std::max)(1, static_cast<int32_t>(bottom + 0.5) - out->y);
  return true;
}

inline bool ClientPointToDesign(const Viewport& v, int32_t x, int32_t y,
                                double* dx, double* dy) {
  if (v.scale_x <= 0.0 || v.scale_y <= 0.0) return false;
  *dx = (x + 0.5) / v.scale_x;
  *dy = (y + 0.5) / v.scale_y;
  return true;
}

// One character of a published page: sprite-local pixels and its UTF-16
// place in the page text.
struct PageGlyph {
  int32_t x = 0;
  int32_t y = 0;
  int32_t w = 0;
  int32_t h = 0;
  uint16_t source_index = 0u;
  uint16_t source_length = 0u;
};

// The glyph under a design point; the page sits at origin (design pixels).
inline bool HitTestPage(const PageGlyph* glyphs, size_t count, double origin_x,
                        double origin_y, double x, double y, size_t* hit) {
  for (size_t i = 0u; i < count; ++i) {
    const PageGlyph& g = glyphs[i];
    const double left = origin_x + g.x;
    const double top = origin_y + g.y;
    if (x >= left && x < left + g.w && y >= top && y < top + g.h) {
      *hit = i;
      return true;
    }
  }
  return false;
}

// The looked-up term [start, start + length) of the page text as one design
// rectangle: the glyphs of the row its first character is on.
inline bool TermRect(const PageGlyph* glyphs, size_t count, uint32_t start,
                     uint32_t length, int32_t* x, int32_t* y, int32_t* w,
                     int32_t* h) {
  if (length == 0u) return false;
  const uint64_t end = static_cast<uint64_t>(start) + length;
  bool found = false;
  int32_t row = 0, left = 0, top = 0, right = 0, bottom = 0;
  for (size_t i = 0u; i < count; ++i) {
    const PageGlyph& g = glyphs[i];
    if (static_cast<uint32_t>(g.source_index) + g.source_length <= start ||
        g.source_index >= end) {
      continue;
    }
    if (!found) {
      found = true;
      row = g.y;
      left = g.x;
      top = g.y;
      right = g.x + g.w;
      bottom = g.y + g.h;
      continue;
    }
    if (g.y != row) break;
    left = (std::min)(left, g.x);
    top = (std::min)(top, g.y);
    right = (std::max)(right, g.x + g.w);
    bottom = (std::max)(bottom, g.y + g.h);
  }
  if (!found) return false;
  *x = left;
  *y = top;
  *w = right - left;
  *h = bottom - top;
  return true;
}

// ── event ring ─────────────────────────────────────────────────────────────

struct RingCursor {
  uint64_t next = 1u;
  bool lost = false;
};

// Where the consumer resumes: after `processed`, unless the producers lapped
// the ring (then at the oldest slot still intact).
inline RingCursor RingStart(uint64_t processed, uint64_t latest,
                            uint32_t slots) {
  RingCursor c;
  c.next = processed + 1u;
  if (latest > processed && latest - processed > slots) {
    c.next = latest - slots + 1u;
    c.lost = true;
  }
  return c;
}

inline bool RingSlotReady(uint64_t committed, uint64_t next) {
  return committed == next;
}

// ── input claim ────────────────────────────────────────────────────────────
//
// A left press on a glyph becomes a lookup and never reaches the engine.  The
// engine sees the button through window messages only (a touch tap arrives as
// the mouse messages Windows promotes from it), so the decision is taken at
// WM_LBUTTONDOWN (or DBLCLK) and the matching WM_LBUTTONUP follows it: the
// engine never sees half of a claimed press.

enum class ButtonMessage : uint32_t { kOther = 0, kDown = 1, kUp = 2 };

struct PressState {
  bool up_pending = false;  // swallow the next WM_LBUTTONUP
};

struct MessageDecision {
  bool evaluate = false;  // a press: caller decides, then ResolvePress
  bool swallow = false;
};

inline MessageDecision DecideMessage(PressState* s, ButtonMessage kind) {
  MessageDecision d;
  if (kind == ButtonMessage::kDown) {
    // Every press is decided on its own (an unmatched up of an earlier claim
    // never leaks into the next press).
    s->up_pending = false;
    d.evaluate = true;
    return d;
  }
  if (kind == ButtonMessage::kUp && s->up_pending) {
    s->up_pending = false;
    d.swallow = true;
  }
  return d;
}

// After the evaluation of a press; true when it is claimed (swallowed).
inline bool ResolvePress(PressState* s, bool claimed) {
  s->up_pending = claimed;
  return claimed;
}

}  // namespace system4
}  // namespace fushi_voice_hook
