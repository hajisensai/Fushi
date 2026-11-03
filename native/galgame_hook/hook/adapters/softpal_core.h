#pragma once

// SoftPal ADV System (Pal.dll) engine facts and every decision rule of the
// adapter, free of hooks and globals so the unit tests drive them directly.
//
// Measured on three Pal.dll generations (2014 / 2015 / 2026, 262 to 369
// exports, all cdecl; the executable resolves them with GetProcAddress):
//   * Text: the game's layout routine locks a text sprite
//     (PalSpriteLock(sprite, &w, &h) -> pixel buffer), draws the page one
//     glyph at a time (PalFontDrawText(buffer, glyph, x, y, buffer_w,
//     buffer_h, ...), sprite-local pixels, the size from the global
//     PalFontGetFontSize()) and unlocks it.  A speaker plate is drawn on its
//     own sprite immediately before the body, in the same engine step: no
//     PalSpriteSetPos between the two transactions, while every frame calls
//     it for every sprite.  Transactions without glyphs (the per-frame
//     typewriter reveal of the 2014 / 2026 generations) change no text.
//   * Voice: PalSoundLoad(name, type, ...), type 1 = voice, in the same
//     engine step right after the body it speaks.
//   * Archives: "PAC " + u32 0 + u32 count, the index at 0x804 with 0x28-byte
//     entries (0x20 name, u32 size, u32 offset); payloads are stored as is.
//   * Placement: PalSpriteSetPos(sprite, float x, float y, z) in design
//     pixels; PalGetSystemParameters copies the system block whose +0x04 is
//     the keep-aspect flag and +0x38 / +0x3c the design size.
//   * Input: Pal samples the mouse buttons with GetAsyncKeyState (and, in
//     the 2026 generation, GetKeyState) every frame, not from window
//     messages alone.

#include <windows.h>

#include <algorithm>
#include <cstdint>
#include <cstring>
#include <string>
#include <vector>

namespace fushi_voice_hook {
namespace softpal {

// ── identity ───────────────────────────────────────────────────────────────

// The Pal runtime surface the adapter binds.  A module exporting all of
// them is the engine; names alone, never a file name or hash.
constexpr const char* kRequiredExports[] = {
    "PalSpriteLock",      "PalSpriteUnlock",       "PalFontDrawText",
    "PalFontGetFontSize", "PalSpriteSetPos",       "PalSpriteViewCtrl",
    "PalSpriteRelease",   "PalSoundLoad",          "PalGetWindowHandle",
    "PalGetSystemParameters",
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

inline bool HasPalExports(const ExportView& view) {
  for (const char* name : kRequiredExports) {
    if (FindExportRva(view, name) == 0u) return false;
  }
  return true;
}

// ── archives ───────────────────────────────────────────────────────────────

constexpr uint32_t kPacIndexOffset = 0x804u;
constexpr uint32_t kPacEntryBytes = 0x28u;
constexpr uint32_t kPacNameBytes = 0x20u;
constexpr uint32_t kPacMaxEntries = 1u << 20;

struct PacEntry {
  std::string name;  // upper-case ASCII
  uint32_t offset = 0u;
  uint32_t size = 0u;
};

// The entry count from the first 12 bytes of an archive.
inline bool ParsePacHeader(const uint8_t* bytes, size_t length,
                           uint32_t* count) {
  if (bytes == nullptr || length < 12u || std::memcmp(bytes, "PAC ", 4) != 0) {
    return false;
  }
  uint32_t value = 0u;
  std::memcpy(&value, bytes + 8, 4u);
  if (value == 0u || value > kPacMaxEntries) return false;
  *count = value;
  return true;
}

inline char UpperAscii(char c) {
  return c >= 'a' && c <= 'z' ? static_cast<char>(c - 'a' + 'A') : c;
}

// The archive key of a requested resource: its base name, upper-case (the
// index stores "VO01_1001.OGG", the script asks for "VO01_1001.ogg").
inline std::string NormalizeResourceName(const char* name, size_t limit) {
  std::string out;
  if (name == nullptr) return out;
  for (size_t i = 0u; i < limit && name[i] != '\0'; ++i) {
    const char c = name[i];
    if (c == '\\' || c == '/') {
      out.clear();
      continue;
    }
    out.push_back(UpperAscii(c));
  }
  return out;
}

// Index entries (`count` x 0x28 bytes read from kPacIndexOffset).  Any entry
// that is not a printable name inside the archive rejects the whole index.
inline bool ParsePacIndex(const uint8_t* index, size_t length, uint32_t count,
                          uint64_t file_size, std::vector<PacEntry>* out) {
  if (index == nullptr || out == nullptr || count == 0u ||
      count > kPacMaxEntries ||
      length < static_cast<size_t>(count) * kPacEntryBytes) {
    return false;
  }
  const uint64_t data_start =
      kPacIndexOffset + static_cast<uint64_t>(count) * kPacEntryBytes;
  if (data_start > file_size) return false;
  out->clear();
  out->reserve(count);
  for (uint32_t i = 0u; i < count; ++i) {
    const uint8_t* entry = index + static_cast<size_t>(i) * kPacEntryBytes;
    size_t name_length = 0u;
    while (name_length < kPacNameBytes && entry[name_length] != 0u) {
      const uint8_t c = entry[name_length];
      if (c < 0x20u || c >= 0x7fu) return false;
      ++name_length;
    }
    if (name_length == 0u || name_length == kPacNameBytes) return false;
    PacEntry parsed;
    std::memcpy(&parsed.size, entry + kPacNameBytes, 4u);
    std::memcpy(&parsed.offset, entry + kPacNameBytes + 4u, 4u);
    if (parsed.offset < data_start ||
        static_cast<uint64_t>(parsed.offset) + parsed.size > file_size) {
      return false;
    }
    parsed.name = NormalizeResourceName(
        reinterpret_cast<const char*>(entry), name_length);
    out->push_back(std::move(parsed));
  }
  return true;
}

inline const PacEntry* FindPacEntry(const std::vector<PacEntry>& entries,
                                    const std::string& key) {
  for (const PacEntry& entry : entries) {
    if (entry.name == key) return &entry;
  }
  return nullptr;
}

inline bool IsOggPayload(const uint8_t* bytes, size_t length) {
  return bytes != nullptr && length >= 4u && std::memcmp(bytes, "OggS", 4) == 0;
}

// ── pages ──────────────────────────────────────────────────────────────────

constexpr uint32_t kMaxGlyphBytes = 8u;
constexpr uint32_t kMaxPageGlyphs = 384u;

// One PalFontDrawText call: the CP932 string and where it went.
struct GlyphDraw {
  int32_t x = 0;
  int32_t y = 0;
  int32_t font_size = 0;
  uint8_t length = 0u;
  // The string ran past kMaxGlyphBytes: `bytes` holds only its head.
  bool truncated = false;
  char bytes[kMaxGlyphBytes] = {};
};

// The string of one PalFontDrawText call into `draw` (NUL-terminated source).
// A string longer than the cell keeps its head and is marked truncated: ruby
// arrives as one string (2026: 「Ｍａｔｕｒｅ」, 12 bytes) and is dropped as
// an annotation anyway, so it must not cost the page.
inline bool CopyDrawString(const char* source, GlyphDraw* draw) {
  uint32_t length = 0u;
  while (length + 1u < kMaxGlyphBytes && source[length] != '\0') {
    draw->bytes[length] = source[length];
    ++length;
  }
  draw->length = static_cast<uint8_t>(length);
  draw->truncated = source[length] != '\0';
  return length > 0u;
}

// One character of a composed page, sprite-local pixels.
struct PageGlyph {
  int32_t x = 0;
  int32_t y = 0;
  int32_t w = 0;
  int32_t h = 0;
  uint16_t source_index = 0u;  // UTF-16 index in the page text
  uint16_t source_length = 0u;
};

enum class PageResult : uint32_t {
  kComposed = 0,
  kEmpty = 1,     // nothing but annotation glyphs
  kRejected = 2,  // not clean CP932 text
};

inline bool IsCp932LeadByte(uint8_t c) {
  return (c >= 0x81u && c <= 0x9fu) || (c >= 0xe0u && c <= 0xfcu);
}

// Byte length of the CP932 characters of `bytes`, 0 on a broken sequence.
inline uint32_t SplitCp932(const char* bytes, uint32_t length,
                           uint32_t* starts, uint32_t capacity) {
  uint32_t count = 0u;
  for (uint32_t i = 0u; i < length;) {
    const uint8_t c = static_cast<uint8_t>(bytes[i]);
    const uint32_t width = IsCp932LeadByte(c) ? 2u : 1u;
    if (i + width > length || count >= capacity) return 0u;
    starts[count++] = i;
    i += width;
  }
  return count;
}

// The page text and per-character cells of one text transaction.
//
// Glyphs drawn markedly smaller than the page's text size are annotations
// the source carries (ruby over a word): kept out of the text, which is the
// body as read.  A glyph string of several characters is laid out at even
// steps of its width.
inline PageResult ComposePage(const GlyphDraw* draws, size_t count,
                              std::wstring* text,
                              std::vector<PageGlyph>* glyphs) {
  text->clear();
  glyphs->clear();
  if (draws == nullptr || count == 0u) return PageResult::kEmpty;
  int32_t body_size = 0;
  for (size_t i = 0u; i < count; ++i) {
    body_size = (std::max)(body_size, draws[i].font_size);
  }
  if (body_size <= 0 || body_size > 512) return PageResult::kRejected;
  for (size_t i = 0u; i < count; ++i) {
    const GlyphDraw& draw = draws[i];
    if (draw.length == 0u || draw.length > kMaxGlyphBytes) {
      return PageResult::kRejected;
    }
    // Annotation: under 70% of the body size.
    if (draw.font_size * 10 < body_size * 7) continue;
    // Body text whose string did not fit: the page cannot be told.
    if (draw.truncated) return PageResult::kRejected;
    uint32_t starts[kMaxGlyphBytes] = {};
    const uint32_t chars =
        SplitCp932(draw.bytes, draw.length, starts, kMaxGlyphBytes);
    if (chars == 0u) return PageResult::kRejected;
    // The cell of the whole string: up to the next glyph on the same row.
    int32_t width = 0;
    const uint32_t dbcs_units =
        static_cast<uint32_t>(draw.length) - chars;  // lead bytes
    width = static_cast<int32_t>((chars - dbcs_units) * draw.font_size / 2 +
                                 dbcs_units * draw.font_size);
    for (size_t j = i + 1u; j < count; ++j) {
      if (draws[j].font_size * 10 < body_size * 7) continue;
      if (draws[j].y == draw.y && draws[j].x > draw.x &&
          draws[j].x - draw.x <= width * 2) {
        width = draws[j].x - draw.x;
      }
      break;
    }
    if (width <= 0) return PageResult::kRejected;
    for (uint32_t c = 0u; c < chars; ++c) {
      const uint32_t end = c + 1u < chars ? starts[c + 1u] : draw.length;
      wchar_t units[4] = {};
      const int produced = MultiByteToWideChar(
          932, MB_ERR_INVALID_CHARS, draw.bytes + starts[c],
          static_cast<int>(end - starts[c]), units, 4);
      if (produced <= 0) return PageResult::kRejected;
      for (int u = 0; u < produced; ++u) {
        if (units[u] < 0x20 || units[u] == 0x7f) return PageResult::kRejected;
      }
      if (text->size() + static_cast<size_t>(produced) > 0xffffu ||
          glyphs->size() >= kMaxPageGlyphs) {
        return PageResult::kRejected;
      }
      PageGlyph glyph;
      glyph.x = draw.x + width * static_cast<int32_t>(c) /
                             static_cast<int32_t>(chars);
      glyph.y = draw.y;
      glyph.w = width / static_cast<int32_t>(chars);
      glyph.h = draw.font_size;
      glyph.source_index = static_cast<uint16_t>(text->size());
      glyph.source_length = static_cast<uint16_t>(produced);
      if (glyph.w <= 0) return PageResult::kRejected;
      text->append(units, static_cast<size_t>(produced));
      glyphs->push_back(glyph);
    }
  }
  return text->empty() ? PageResult::kEmpty : PageResult::kComposed;
}

// ── step rules ─────────────────────────────────────────────────────────────

// A text transaction followed, in the same engine step (no sprite placement
// in between), by one on another sprite is that page's speaker plate.
inline bool IsSpeakerLabel(uintptr_t sprite, uintptr_t next_sprite,
                           uint32_t setpos_between) {
  return sprite != 0u && next_sprite != 0u && sprite != next_sprite &&
         setpos_between == 0u;
}

constexpr uint32_t kSoundTypeVoice = 1u;

// A voice belongs to the page published in the same engine step.
inline bool VoicePairsWithPage(uint32_t sound_type, bool has_page,
                               uint32_t setpos_since_page) {
  return sound_type == kSoundTypeVoice && has_page && setpos_since_page == 0u;
}

// ── placement ──────────────────────────────────────────────────────────────

constexpr int32_t kMinDesignSide = 320;
constexpr int32_t kMaxDesignSide = 8192;

inline bool DesignPlausible(int32_t w, int32_t h) {
  return w >= kMinDesignSide && h >= kMinDesignSide / 2 &&
         w <= kMaxDesignSide && h <= kMaxDesignSide;
}

// The design screen shown on a client: stretched over it, or (keep-aspect)
// fitted and centred.
struct Viewport {
  double x = 0.0;
  double y = 0.0;
  double scale_x = 0.0;
  double scale_y = 0.0;
};

inline bool ComputeViewport(int32_t design_w, int32_t design_h,
                            int32_t client_w, int32_t client_h,
                            bool keep_aspect, Viewport* out) {
  if (!DesignPlausible(design_w, design_h) || client_w <= 0 || client_h <= 0) {
    return false;
  }
  Viewport v;
  v.scale_x = static_cast<double>(client_w) / design_w;
  v.scale_y = static_cast<double>(client_h) / design_h;
  if (keep_aspect) {
    const double s = (std::min)(v.scale_x, v.scale_y);
    v.scale_x = v.scale_y = s;
    v.x = (client_w - design_w * s) / 2.0;
    v.y = (client_h - design_h * s) / 2.0;
  }
  *out = v;
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
  const double left = v.x + x * v.scale_x;
  const double top = v.y + y * v.scale_y;
  const double right = v.x + (x + w) * v.scale_x;
  const double bottom = v.y + (y + h) * v.scale_y;
  out->x = static_cast<int32_t>(left + 0.5);
  out->y = static_cast<int32_t>(top + 0.5);
  out->w = (std::max)(1, static_cast<int32_t>(right + 0.5) - out->x);
  out->h = (std::max)(1, static_cast<int32_t>(bottom + 0.5) - out->y);
  return true;
}

inline bool ClientPointToDesign(const Viewport& v, int32_t x, int32_t y,
                                double* dx, double* dy) {
  if (v.scale_x <= 0.0 || v.scale_y <= 0.0) return false;
  *dx = (x + 0.5 - v.x) / v.scale_x;
  *dy = (y + 0.5 - v.y) / v.scale_y;
  return true;
}

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

// ── input claim ────────────────────────────────────────────────────────────
//
// A left press on a glyph becomes a lookup and never reaches the engine.  The
// engine sees a press two ways: its per-frame GetAsyncKeyState sample and the
// window messages.  Whichever sees the press first decides it; the other
// follows that decision, so the engine never sees half of a claimed press.

struct PressState {
  bool decided = false;        // this press was evaluated
  bool claimed = false;        // ... and is a lookup: hidden from the engine
  bool down_message = false;   // its WM_LBUTTONDOWN went by
  bool up_pending = false;     // swallow the next WM_LBUTTONUP
};

enum class SampleAction : uint32_t {
  kPass = 0,      // real state to the engine
  kMask = 1,      // report the button up
  kEvaluate = 2,  // first sight of a press: caller decides, then ResolvePress
};

// The engine samples the left button; `down` is the real state.
inline SampleAction DecideSample(PressState* s, bool down) {
  if (!down) {
    // Released: the next press is a new one.  A WM_LBUTTONUP still queued for
    // a claimed press stays swallowed.
    s->decided = false;
    s->claimed = false;
    s->down_message = false;
    return SampleAction::kPass;
  }
  if (s->claimed) return SampleAction::kMask;
  if (s->decided) return SampleAction::kPass;
  return SampleAction::kEvaluate;
}

inline void ResolvePress(PressState* s, bool claimed) {
  s->decided = true;
  s->claimed = claimed;
}

enum class ButtonMessage : uint32_t { kOther = 0, kDown = 1, kUp = 2 };

struct MessageDecision {
  bool evaluate = false;  // first sight of a press: caller decides
  bool swallow = false;
};

inline MessageDecision DecideMessage(PressState* s, ButtonMessage kind) {
  MessageDecision d;
  if (kind == ButtonMessage::kDown) {
    if (s->decided && !s->down_message) {
      // The sample saw this press first: follow its decision.
      s->down_message = true;
      if (s->claimed) {
        s->up_pending = true;
        d.swallow = true;
      }
      return d;
    }
    // A press no sample saw (sub-frame touch tap, or the engine is not
    // sampling) or the next press after one the messages decided.
    s->decided = false;
    s->claimed = false;
    s->down_message = true;
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

// After a message-side evaluation.
inline bool ResolveMessagePress(PressState* s, bool claimed) {
  s->decided = true;
  s->claimed = claimed;
  s->up_pending = claimed;
  return claimed;
}

// ── touch claim ────────────────────────────────────────────────────────────
//
// Pal versions that register their window for touch take a tap from WM_TOUCH
// itself (the contact's down sets the engine's button state), before the
// mouse messages Windows promotes from it arrive.  The contact is decided at
// its WM_TOUCH down; a claimed contact's WM_TOUCH messages are swallowed
// until its up, and the promoted press follows the touch decision instead of
// being evaluated again (one lookup per tap).

enum class TouchEvent : uint32_t { kDown = 0, kMove = 1, kUp = 2 };

struct TouchState {
  bool active = false;             // a contact is being tracked
  uint32_t id = 0;                 // ... this one
  bool claimed = false;            // ... and it is a lookup
  bool promotion_pending = false;  // its promoted mouse press is to come
  bool promotion_claimed = false;
};

struct TouchDecision {
  bool evaluate = false;  // a new contact: caller decides, then ResolveTouch
  bool swallow = false;   // hide this input from the engine
};

inline TouchDecision DecideTouch(TouchState* t, uint32_t id, TouchEvent ev) {
  TouchDecision d;
  if (ev == TouchEvent::kDown && !(t->active && t->id != id)) {
    t->active = true;
    t->id = id;
    t->claimed = false;
    d.evaluate = true;
    return d;
  }
  if (!t->active) return d;
  // Further fingers while a claimed contact is down stay hidden with it.
  d.swallow = t->claimed;
  if (ev == TouchEvent::kUp && t->id == id) {
    t->active = false;
  }
  return d;
}

// After a touch-side evaluation.  The engine's own sample of the promoted
// press follows the same decision.
inline bool ResolveTouch(TouchState* t, PressState* s, bool claimed) {
  t->claimed = claimed;
  t->promotion_pending = true;
  t->promotion_claimed = claimed;
  s->decided = true;
  s->claimed = claimed;
  s->down_message = false;
  return claimed;
}

// A promoted WM_LBUTTONDOWN (touch or pen signature): when a touch decision
// is waiting for it, apply that decision instead of evaluating.  True when
// consumed; `swallow` says whether the message is hidden.
inline bool TakeTouchPromotion(TouchState* t, PressState* s, bool* swallow) {
  if (!t->promotion_pending) return false;
  t->promotion_pending = false;
  s->decided = true;
  s->claimed = t->promotion_claimed;
  s->down_message = true;
  s->up_pending = t->promotion_claimed;
  *swallow = t->promotion_claimed;
  return true;
}

// GetMessageExtraInfo() of a mouse message Windows promoted from touch / pen.
inline bool IsPromotedPointerMessage(uintptr_t extra) {
  return (static_cast<uint32_t>(extra) & 0xFFFFFF00u) == 0xFF515700u;
}

}  // namespace softpal
}  // namespace fushi_voice_hook
