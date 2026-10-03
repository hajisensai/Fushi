// FVP (Favorite View Point) message text lane + in-game lookup runtime
// (EngineExactLayout / kLookupGeometryProviderIdFvp).  Engine facts,
// signatures and every decision rule live in fvp_lookup_core.h and are
// unit-tested; this file only binds them to MinHook, Win32, the text lanes and
// the v19 registry.
//
// Threads:
//   * game thread — Print detour: claims the PutGlyph capture for this text
//     object, calls the engine (which lays the whole string out), then copies
//     the CP932 string and the glyph records into a fixed ring.  PutGlyph
//     detour: copies the pen / advance / format fields of one glyph.  Draw
//     detour: when the watched text surface is drawn, copies the draw
//     arguments and the prim / surface fields into a seqlock slot.  No
//     allocation, no IO, no conversion.
//   * message thread — main window procedure detour: a bare WM_LBUTTONDOWN /
//     DBLCLK on a mapped glyph of the current model is swallowed together with
//     its WM_LBUTTONUP, so the engine's input state never sees the click
//     (touch: see DecideMessage in fvp_lookup_core.h).
//   * HookWorker — ProcessFvpLookupTick: parses and converts queued prints,
//     publishes the text lane (one lane per text buffer), keeps the latest
//     mappable page per buffer, watches the selected buffer's surface, builds
//     the model from the last draw (plain visible translation only), matches
//     the selected line, projects to physical client pixels, offers/retires
//     the provider, publishes the model for the message thread and turns
//     queued presses into registry hits.
//
// Fail closed everywhere: an unresolved signature installs nothing, a print
// whose glyph records do not pair one-to-one with its displayed units, a
// surface not drawn recently or drawn with any rotation / scale / UV / 3D
// path, a text object whose pen moved (cleared or printed again), a text
// mismatch, a client with another aspect than the design back buffer or a
// missing native-input admission retires the provider or refuses the click,
// and the click then reaches the game unchanged.  "Drawn recently" and "the
// model is current" are counted in engine events (draws, prints on the
// model's own buffer), never in wall-clock time: a static screen, or an engine
// that stops drawing while a lookup card is foreground, keeps its model, so a
// click on a glyph is not let through to advance the line.

#if defined(_M_IX86)

namespace fvp_lookup = fushi_voice_hook::fvp_lookup;

constexpr uint32_t kFvpEventSlots = 8u;
constexpr uint32_t kFvpModelSlots = 2u;
constexpr uint32_t kFvpSubmitSlots = 8u;
constexpr uint32_t kFvpModelLogBudget = 4096u;
constexpr uint64_t kFvpWindowRetryMs = 500u;
constexpr uint64_t kFvpTextDedupeMs = 500u;

// Adapter-local diagnostic flags (reported through AdapterDiagnostics::flags,
// never through the shared header words).
constexpr uint32_t kFvpFlagSitesResolved = 0x0001u;
constexpr uint32_t kFvpFlagTextHooked = 0x0002u;
constexpr uint32_t kFvpFlagTextObserved = 0x0004u;
constexpr uint32_t kFvpFlagPageMapped = 0x0008u;
constexpr uint32_t kFvpFlagWindowHooked = 0x0010u;
constexpr uint32_t kFvpFlagDrawObserved = 0x0020u;
constexpr uint32_t kFvpFlagGeometryOffered = 0x0040u;
constexpr uint32_t kFvpFlagPressClaimed = 0x0080u;
constexpr uint32_t kFvpFlagHitPublished = 0x0100u;
constexpr uint32_t kFvpFlagVoiceHooked = 0x0200u;
constexpr uint32_t kFvpFlagVoiceCaptured = 0x0800u;
std::atomic<uint32_t> g_fvp_flags{0u};

void NoteFvpFlag(uint32_t flag) {
  g_fvp_flags.fetch_or(flag, std::memory_order_relaxed);
}

struct FvpTextEvent {
  uint64_t tick = 0u;
  uint64_t step = 0u;           // script position (shared with AudioPlay)
  uint64_t epoch = 0u;          // draws counted when it ran (its dispatch)
  uint64_t buffer_prints = 0u;  // prints on its buffer, this one included
  uintptr_t text_object = 0u;
  int32_t buffer = -1;
  int16_t pen_end_x = 0;
  int16_t pen_end_y = 0;
  uint32_t text_bytes = 0u;
  uint32_t glyph_count = 0u;
  bool glyphs_overflow = false;
  uint8_t text[fvp_lookup::kMaxTextBytes + 1u] = {};
  fvp_lookup::GlyphRecord glyphs[fvp_lookup::kMaxGlyphs] = {};
};

struct FvpModelGlyph {
  fvp_lookup::LineGlyph line;
  fvp_lookup::PixelRect rect;  // physical client pixels
};

struct FvpModel {
  uint64_t generation = 0u;
  uint64_t page = 0u;
  uint64_t buffer_prints = 0u;  // prints on its buffer it was built from
  uintptr_t window = 0u;
  uintptr_t text_object = 0u;
  int32_t buffer = -1;
  int16_t pen_end_x = 0;
  int16_t pen_end_y = 0;
  int32_t origin_x = 0;
  int32_t origin_y = 0;
  int32_t design_w = 0;
  int32_t design_h = 0;
  int32_t logical_w = 0;
  int32_t logical_h = 0;
  int32_t physical_w = 0;
  int32_t physical_h = 0;
  uint32_t count = 0u;
  std::array<FvpModelGlyph, fvp_lookup::kMaxUnits> glyphs{};
};

struct FvpSubmit {
  uint64_t generation = 0u;
  uint32_t glyph = 0u;
  fvp_lookup::LineGlyph line;
  fvp_lookup::PixelRect rect;
  int32_t physical_w = 0;
  int32_t physical_h = 0;
};

struct FvpPage {
  bool valid = false;
  uint64_t id = 0u;
  uintptr_t text_object = 0u;
  uint64_t buffer_prints = 0u;
  int16_t pen_end_x = 0;
  int16_t pen_end_y = 0;
  uint64_t text_event = 0u;
  uint64_t lane = 0u;
  uint32_t count = 0u;
  std::array<fvp_lookup::Cell, fvp_lookup::kMaxUnits> cells{};
  std::array<uint32_t, fvp_lookup::kMaxUnits> codepoints{};
  std::array<uint16_t, fvp_lookup::kMaxUnits> sources{};
};

// What the Draw detour publishes for the watched surface.
struct FvpDrawSlot {
  uint64_t tick = 0u;    // 0 = the last read of the surface failed
  uint64_t draws = 0u;   // draw counter at this draw of the surface
  uint64_t period = 0u;  // draws since its previous draw (same surface)
  uintptr_t surface = 0u;
  fvp_lookup::DrawState state;
};

struct FvpLookupRuntime {
  // ── HookWorker-owned ──
  bool resolved = false;
  bool hooks_installed = false;
  bool installed = false;
  fvp_lookup::SiteResult site_result = fvp_lookup::SiteResult::kNotX86;
  bool provider_offered = false;
  fvp_lookup::WindowBindingState window_state;
  uint64_t window_retry_tick = 0u;
  uint64_t processed_event_seq = 0u;
  uint64_t processed_submit_seq = 0u;
  uint64_t next_generation = 0u;
  uint64_t next_page = 0u;
  uint32_t logged_models = 0u;
  uint32_t logged_pages = 0u;
  FvpTextEvent event_copy;
  std::array<FvpPage, fvp_lookup::kTextBufferCount> pages{};
  FvpModel model;
  FvpModel candidate;
  std::wstring model_line;
  uint64_t model_text_event = 0u;
  fvp_lookup::PublishedLines published_lines;
  uint64_t logged_claims = 0u;
  std::array<fvp_lookup::LineGlyph, fvp_lookup::kMaxUnits> scratch{};
  std::array<fvp_lookup::Cell, fvp_lookup::kMaxUnits> cell_scratch{};
  std::wstring last_text;
  uint64_t last_text_thread = 0u;
  uint64_t last_text_tick = 0u;
  uint64_t last_text_event = 0u;

  // ── resolved once, read everywhere ──
  fvp_lookup::Sites sites;
  uintptr_t image_base = 0u;
  HWND window = nullptr;

  // ── message-thread-owned ──
  fvp_lookup::ClaimState claim;
  FvpModel input_model;
  std::array<fvp_lookup::LineGlyph, fvp_lookup::kMaxUnits> input_lines{};

  // ── game thread: the Print → PutGlyph capture (one game thread) ──
  std::atomic<DWORD> capture_thread{0u};
  uintptr_t capture_object = 0u;
  uint32_t capture_count = 0u;
  bool capture_overflow = false;
  fvp_lookup::GlyphRecord capture[fvp_lookup::kMaxGlyphs] = {};

  // ── shared ──
  std::atomic<bool> live{false};
  std::atomic<uint64_t> event_count{0u};
  std::array<std::atomic<uint64_t>, kFvpEventSlots> event_seq = {};
  std::array<FvpTextEvent, kFvpEventSlots> events = {};
  std::array<std::atomic<uint32_t>, kFvpModelSlots> model_seq = {};
  std::array<FvpModel, kFvpModelSlots> models = {};
  std::atomic<uint32_t> published_model{UINT32_MAX};
  std::array<std::atomic<uint64_t>, kFvpSubmitSlots> submit_seq = {};
  std::array<FvpSubmit, kFvpSubmitSlots> submits = {};
  std::atomic<uint64_t> submit_count{0u};
  std::atomic<uint64_t> claimed_presses{0u};
  // Why the last press on the game window was not claimed (diagnostics):
  // 1 off 2 no-model 3 window/stale 4 admission 5 shield 6 foreground
  // 7 modifiers 8 text-object 9 not-drawn 10 client 11 no-glyph.
  std::atomic<uint32_t> refused_presses{0u};
  std::atomic<uint32_t> refused_reason{0u};
  uint32_t logged_refusals = 0u;
  std::atomic<uintptr_t> watched_surface{0u};
  std::atomic<uint32_t> draw_seq{0u};
  FvpDrawSlot draw;
  std::atomic<uint32_t> print_hits{0u};
  // Every primitive the engine draws (the dispatch epoch and the draw-count
  // freshness gate), the script step shared by TextPrint and AudioPlay, and
  // the prints per text buffer.
  std::atomic<uint64_t> draw_calls{0u};
  std::atomic<uint64_t> script_steps{0u};
  fvp_lookup::BufferPrintCounts buffer_prints;
};

FvpLookupRuntime g_fvp_lookup;

// Worker-only history of published lines with their script step and
// dispatch, for binding a voice line to the dialogue print of its dispatch.
constexpr uint32_t kFvpPublishedTextSlots = 16u;
std::array<fvp_lookup::PublishedText, kFvpPublishedTextSlots>
    g_fvp_published_text{};
uint32_t g_fvp_published_text_next = 0u;
using FvpPrintFn = int(__thiscall*)(uintptr_t, const char*);
using FvpPutGlyphFn = int(__thiscall*)(uintptr_t, uintptr_t, uintptr_t, int);
using FvpDrawFn = int(__thiscall*)(uintptr_t, int, int, uintptr_t, uintptr_t);
FvpPrintFn g_fvp_print_original = nullptr;
FvpPutGlyphFn g_fvp_put_glyph_original = nullptr;
FvpDrawFn g_fvp_draw_original = nullptr;
// The engine registers more than one window class: the top-level frame and a
// child that covers the client and receives the mouse.  Each distinct window
// procedure of the frame and its children that lies in the game image gets
// its own detour slot.
constexpr uint32_t kFvpWndProcSlots = 4u;
std::array<WNDPROC, kFvpWndProcSlots> g_fvp_wndproc_original{};

template <typename T>
bool ReadFvpValue(uintptr_t address, T* out) {
  if (address == 0u || out == nullptr) return false;
  __try {
    std::memcpy(out, reinterpret_cast<const void*>(address), sizeof(T));
  } __except (EXCEPTION_EXECUTE_HANDLER) {
    return false;
  }
  return true;
}

// ── two-slot seqlock (model) ───────────────────────────────────────────────

size_t FvpModelBytes(uint32_t count) {
  return offsetof(FvpModel, glyphs) +
         static_cast<size_t>(count) * sizeof(FvpModelGlyph);
}

void PublishFvpModel(const FvpModel& value) {
  auto& rt = g_fvp_lookup;
  const uint32_t current = rt.published_model.load(std::memory_order_acquire);
  const uint32_t slot =
      current >= kFvpModelSlots
          ? 0u
          : static_cast<uint32_t>((current + 1u) % kFvpModelSlots);
  const uint32_t seq = rt.model_seq[slot].load(std::memory_order_relaxed);
  rt.model_seq[slot].store(seq | 1u, std::memory_order_release);
  std::atomic_thread_fence(std::memory_order_release);
  std::memcpy(&rt.models[slot], &value, FvpModelBytes(value.count));
  std::atomic_thread_fence(std::memory_order_release);
  rt.model_seq[slot].store((seq | 1u) + 1u, std::memory_order_release);
  rt.published_model.store(slot, std::memory_order_release);
}

bool ReadFvpModelBytes(FvpModel* out, size_t bytes) {
  auto& rt = g_fvp_lookup;
  const uint32_t slot = rt.published_model.load(std::memory_order_acquire);
  if (out == nullptr || slot >= kFvpModelSlots) return false;
  const uint32_t before = rt.model_seq[slot].load(std::memory_order_acquire);
  if (before == 0u || (before & 1u) != 0u) return false;
  std::atomic_thread_fence(std::memory_order_acquire);
  std::memcpy(out, &rt.models[slot], bytes);
  std::atomic_thread_fence(std::memory_order_acquire);
  return rt.model_seq[slot].load(std::memory_order_acquire) == before &&
         rt.published_model.load(std::memory_order_acquire) == slot;
}

bool ReadFvpModel(FvpModel* out) {
  if (!ReadFvpModelBytes(out, offsetof(FvpModel, glyphs))) return false;
  const uint32_t count = (std::min)(
      out->count, static_cast<uint32_t>(fvp_lookup::kMaxUnits));
  return ReadFvpModelBytes(out, FvpModelBytes(count)) && out->count == count;
}

void InvalidateFvpModel() {
  g_fvp_lookup.published_model.store(UINT32_MAX, std::memory_order_release);
}

// ── game thread: Print / PutGlyph / Draw ───────────────────────────────────

int32_t FvpBufferIndexOf(uintptr_t text_object) {
  auto& rt = g_fvp_lookup;
  uintptr_t vm = 0u;
  if (!ReadFvpValue(rt.image_base + rt.sites.vm_global, &vm) || vm == 0u) {
    return -1;
  }
  uintptr_t objects[fvp_lookup::kTextBufferCount] = {};
  __try {
    std::memcpy(objects,
                reinterpret_cast<const void*>(vm + rt.sites.text_array),
                sizeof(objects));
  } __except (EXCEPTION_EXECUTE_HANDLER) {
    return -1;
  }
  for (uint32_t index = 0u; index < fvp_lookup::kTextBufferCount; ++index) {
    if (objects[index] == text_object) return static_cast<int32_t>(index);
  }
  return -1;
}

void PublishFvpTextEvent(uintptr_t self, const char* text, uint64_t step,
                         uint64_t epoch) {
  auto& rt = g_fvp_lookup;
  const uint64_t sequence =
      rt.event_count.fetch_add(1u, std::memory_order_acq_rel) + 1u;
  auto& slot_seq = rt.event_seq[sequence % kFvpEventSlots];
  slot_seq.store(0u, std::memory_order_release);
  std::atomic_thread_fence(std::memory_order_release);
  FvpTextEvent& event = rt.events[sequence % kFvpEventSlots];
  event.tick = GetTickCount64();
  event.step = step;
  event.epoch = epoch;
  event.text_object = self;
  event.buffer = FvpBufferIndexOf(self);
  // Counted before the slot is published: a press that reads the new count
  // refuses a model built from an earlier print of this buffer.
  event.buffer_prints = rt.buffer_prints.Note(event.buffer);
  event.text_bytes = 0u;
  event.glyph_count = 0u;
  event.glyphs_overflow = rt.capture_overflow;
  bool ok = true;
  __try {
    const auto* bytes = reinterpret_cast<const uint8_t*>(text);
    uint32_t length = 0u;
    while (length < fvp_lookup::kMaxTextBytes && bytes[length] != 0u) {
      event.text[length] = bytes[length];
      ++length;
    }
    event.text[length] = 0u;
    event.text_bytes = length;
    event.pen_end_x = *reinterpret_cast<const int16_t*>(self + rt.sites.pen_x);
    event.pen_end_y = *reinterpret_cast<const int16_t*>(self + rt.sites.pen_y);
  } __except (EXCEPTION_EXECUTE_HANDLER) {
    ok = false;
  }
  if (ok) {
    const uint32_t count = (std::min)(
        rt.capture_count, static_cast<uint32_t>(fvp_lookup::kMaxGlyphs));
    std::memcpy(event.glyphs, rt.capture,
                count * sizeof(fvp_lookup::GlyphRecord));
    event.glyph_count = count;
  } else {
    event.text_bytes = 0u;
  }
  std::atomic_thread_fence(std::memory_order_release);
  slot_seq.store(sequence, std::memory_order_release);
}

int __fastcall FvpPrintDetour(uintptr_t self, uintptr_t, const char* text) {
  auto& rt = g_fvp_lookup;
  const DWORD thread = GetCurrentThreadId();
  DWORD expected = 0u;
  const bool capture =
      rt.live.load(std::memory_order_acquire) && self != 0u &&
      text != nullptr &&
      rt.capture_thread.compare_exchange_strong(expected, thread,
                                                std::memory_order_acq_rel);
  uint64_t step = 0u;
  uint64_t epoch = 0u;
  if (capture) {
    rt.capture_object = self;
    rt.capture_count = 0u;
    rt.capture_overflow = false;
    step = rt.script_steps.fetch_add(1u, std::memory_order_acq_rel) + 1u;
    epoch = rt.draw_calls.load(std::memory_order_acquire);
  }
  const int result = g_fvp_print_original(self, text);
  if (capture) {
    rt.print_hits.fetch_add(1u, std::memory_order_relaxed);
    uint8_t first = 0u;
    if (ReadFvpValue(reinterpret_cast<uintptr_t>(text), &first) && first != 0u) {
      PublishFvpTextEvent(self, text, step, epoch);
    }
    rt.capture_object = 0u;
    rt.capture_thread.store(0u, std::memory_order_release);
  }
  return result;
}

int __fastcall FvpPutGlyphDetour(uintptr_t self, uintptr_t, uintptr_t format,
                                 uintptr_t glyph, int ruby) {
  auto& rt = g_fvp_lookup;
  if (rt.capture_thread.load(std::memory_order_acquire) ==
          GetCurrentThreadId() &&
      rt.capture_object == self) {
    if (rt.capture_count >= fvp_lookup::kMaxGlyphs) {
      rt.capture_overflow = true;
    } else {
      fvp_lookup::GlyphRecord& record = rt.capture[rt.capture_count];
      bool ok = true;
      __try {
        record.ruby = static_cast<uint8_t>(ruby & 0xff) != 0u ? 1u : 0u;
        record.pen_x =
            *reinterpret_cast<const int16_t*>(self + rt.sites.pen_x);
        record.pen_y =
            *reinterpret_cast<const int16_t*>(self + rt.sites.pen_y);
        record.advance = *reinterpret_cast<const int32_t*>(
            glyph + rt.sites.glyph_advance);
        record.size = *reinterpret_cast<const uint8_t*>(format + 2u);
        record.ruby_size = *reinterpret_cast<const uint8_t*>(format + 4u);
        record.ruby_mode = *reinterpret_cast<const uint8_t*>(format + 0x14u);
        record.ruby_gap = *reinterpret_cast<const int16_t*>(format + 0x24u);
      } __except (EXCEPTION_EXECUTE_HANDLER) {
        ok = false;
      }
      if (ok) {
        ++rt.capture_count;
      } else {
        rt.capture_overflow = true;
      }
    }
  }
  return g_fvp_put_glyph_original(self, format, glyph, ruby);
}

int __fastcall FvpDrawDetour(uintptr_t self, uintptr_t, int ox, int oy,
                             uintptr_t prim, uintptr_t surface) {
  auto& rt = g_fvp_lookup;
  const uint64_t draws =
      rt.draw_calls.fetch_add(1u, std::memory_order_acq_rel) + 1u;
  const uintptr_t watched = rt.watched_surface.load(std::memory_order_acquire);
  if (watched != 0u && surface == watched && prim != 0u &&
      rt.live.load(std::memory_order_acquire)) {
    const uint32_t seq = rt.draw_seq.load(std::memory_order_relaxed);
    rt.draw_seq.store(seq | 1u, std::memory_order_release);
    std::atomic_thread_fence(std::memory_order_release);
    FvpDrawSlot& slot = rt.draw;
    // The render thread is the slot's only writer.
    slot.period = slot.surface == surface && slot.draws != 0u &&
                          draws > slot.draws
                      ? draws - slot.draws
                      : 0u;
    slot.draws = draws;
    bool ok = true;
    __try {
      const auto& s = rt.sites;
      slot.tick = GetTickCount64();
      slot.surface = surface;
      slot.state.ox = ox;
      slot.state.oy = oy;
      slot.state.prim_x = *reinterpret_cast<const int16_t*>(prim + s.prim_x);
      slot.state.prim_y = *reinterpret_cast<const int16_t*>(prim + s.prim_y);
      slot.state.flags = *reinterpret_cast<const uint8_t*>(prim + 6u);
      slot.state.alpha = *reinterpret_cast<const uint8_t*>(prim + 7u);
      slot.state.rotation =
          *reinterpret_cast<const uint16_t*>(prim + s.prim_rotation);
      slot.state.scale_x =
          *reinterpret_cast<const int16_t*>(prim + s.prim_scale_x);
      slot.state.scale_y =
          *reinterpret_cast<const int16_t*>(prim + s.prim_scale_y);
      slot.state.ready =
          *reinterpret_cast<const uint8_t*>(surface + s.surface_ready);
      std::memcpy(slot.state.surface_origin,
                  reinterpret_cast<const void*>(surface + s.surface_origin_x -
                                                4u),
                  sizeof(slot.state.surface_origin));
    } __except (EXCEPTION_EXECUTE_HANDLER) {
      ok = false;
    }
    if (!ok) slot.tick = 0u;
    std::atomic_thread_fence(std::memory_order_release);
    rt.draw_seq.store((seq | 1u) + 1u, std::memory_order_release);
  }
  return g_fvp_draw_original(self, ox, oy, prim, surface);
}

bool ReadFvpDraw(FvpDrawSlot* out) {
  auto& rt = g_fvp_lookup;
  const uint32_t before = rt.draw_seq.load(std::memory_order_acquire);
  if (before == 0u || (before & 1u) != 0u) return false;
  std::atomic_thread_fence(std::memory_order_acquire);
  std::memcpy(out, &rt.draw, sizeof(*out));
  std::atomic_thread_fence(std::memory_order_acquire);
  return rt.draw_seq.load(std::memory_order_acquire) == before;
}

// The watched surface is still on screen (draw-count gate, see
// WatchedSurfaceDrawn) as a plain visible translation; returns where its pixel
// (0,0) lands on the design back buffer.
bool FvpDrawnOrigin(uintptr_t surface, int32_t* x, int32_t* y) {
  FvpDrawSlot draw;
  if (!ReadFvpDraw(&draw) || draw.surface != surface || draw.tick == 0u ||
      !fvp_lookup::WatchedSurfaceDrawn(
          g_fvp_lookup.draw_calls.load(std::memory_order_acquire), draw.draws,
          draw.period)) {
    return false;
  }
  return fvp_lookup::DrawOrigin(draw.state, x, y);
}

// The text object still shows what the page was built from: it is still the
// buffer's object and its pen has not moved since that print.
bool FvpTextObjectUnchanged(uintptr_t text_object, int32_t buffer,
                            int16_t pen_x, int16_t pen_y) {
  auto& rt = g_fvp_lookup;
  int16_t x = 0, y = 0;
  return buffer >= 0 && FvpBufferIndexOf(text_object) == buffer &&
         ReadFvpValue(text_object + rt.sites.pen_x, &x) &&
         ReadFvpValue(text_object + rt.sites.pen_y, &y) && x == pen_x &&
         y == pen_y;
}

// ── message thread: main window procedure ─────────────────────────────────

void QueueFvpSubmit(const FvpSubmit& submit) {
  auto& rt = g_fvp_lookup;
  const uint64_t sequence =
      rt.submit_count.load(std::memory_order_acquire) + 1u;
  auto& slot_seq = rt.submit_seq[sequence % kFvpSubmitSlots];
  slot_seq.store(0u, std::memory_order_release);
  std::atomic_thread_fence(std::memory_order_release);
  rt.submits[sequence % kFvpSubmitSlots] = submit;
  std::atomic_thread_fence(std::memory_order_release);
  slot_seq.store(sequence, std::memory_order_release);
  rt.submit_count.store(sequence, std::memory_order_release);
}

bool FvpShieldActive(HWND game) {
  if (IsLookupOverlayInputShieldVisible()) return true;
  if (g_header == nullptr) return false;
  const auto request = fushi_voice_hook::ReadLookupShieldRequest(g_header);
  return request.valid && request.active_buttons != 0u &&
         request.target_hwnd ==
             static_cast<uint64_t>(reinterpret_cast<uintptr_t>(game));
}

// A left press delivered to the engine's window procedure: may it become a
// lookup?  Only a bare press on exactly one mapped glyph of the current model,
// in the foreground game window, with the host's native-input admission
// applied, no card shielding the game, the text object unchanged and its
// surface still drawn at the model's origin.
bool FvpRefusePress(uint32_t reason) {
  g_fvp_lookup.refused_reason.store(reason, std::memory_order_relaxed);
  g_fvp_lookup.refused_presses.fetch_add(1u, std::memory_order_relaxed);
  return false;
}

bool FvpPressEligible(HWND hwnd, WPARAM wparam, LPARAM lparam,
                      FvpSubmit* submit) {
  auto& rt = g_fvp_lookup;
  if (!rt.live.load(std::memory_order_acquire) || g_header == nullptr ||
      g_stop || !fushi_voice_hook::HasLookupRegion(g_header) ||
      fushi_voice_hook::AtomicLoadShared32(&g_header->lookup_enabled) == 0u) {
    return FvpRefusePress(1u);
  }
  FvpModel& model = rt.input_model;
  if (!ReadFvpModel(&model) || model.generation == 0u || model.count == 0u) {
    return FvpRefusePress(2u);
  }
  int32_t origin_x = 0, origin_y = 0;
  const HWND frame = reinterpret_cast<HWND>(model.window);
  // Only a newer print on the model's own text buffer makes it stale; a HUD
  // or name-plate buffer printing does not.
  if ((hwnd != frame && !IsChild(frame, hwnd)) ||
      rt.buffer_prints.Of(model.buffer) != model.buffer_prints) {
    return FvpRefusePress(3u);
  }
  if (!fushi_voice_hook::g_geometry_provider_registry.NativeInputAllowed(
          g_header, fushi_voice_hook::kLookupGeometryProviderEngineExactLayout,
          fushi_voice_hook::kLookupGeometryProviderIdFvp)) {
    return FvpRefusePress(4u);
  }
  if (FvpShieldActive(hwnd)) return FvpRefusePress(5u);
  if (GetForegroundWindow() != frame) return FvpRefusePress(6u);
  if ((wparam & (MK_SHIFT | MK_CONTROL | MK_RBUTTON | MK_MBUTTON)) != 0u ||
      (GetKeyState(VK_MENU) & 0x8000) != 0) {
    return FvpRefusePress(7u);
  }
  if (!FvpTextObjectUnchanged(model.text_object, model.buffer,
                              model.pen_end_x, model.pen_end_y)) {
    return FvpRefusePress(8u);
  }
  if (!FvpDrawnOrigin(model.text_object + rt.sites.surface_offset, &origin_x,
                      &origin_y) ||
      origin_x != model.origin_x || origin_y != model.origin_y) {
    return FvpRefusePress(9u);
  }
  RECT client = {};
  if (!GetClientRect(frame, &client) ||
      client.right - client.left != model.logical_w ||
      client.bottom - client.top != model.logical_h) {
    return FvpRefusePress(10u);
  }
  // The press is in the receiving window's client pixels; the model is the
  // frame's.
  POINT point = {static_cast<int16_t>(LOWORD(lparam)),
                 static_cast<int16_t>(HIWORD(lparam))};
  if (hwnd != frame) MapWindowPoints(hwnd, frame, &point, 1u);
  int32_t x = 0, y = 0;
  if (!fvp_lookup::ClientToDesign(point.x, point.y,
                                  model.logical_w, model.logical_h,
                                  model.design_w, model.design_h, &x, &y)) {
    return FvpRefusePress(11u);
  }
  auto& lines = rt.input_lines;
  for (uint32_t index = 0u; index < model.count; ++index) {
    lines[index] = model.glyphs[index].line;
  }
  size_t hit = 0u;
  if (!fvp_lookup::HitTestLine(lines.data(), model.count, x, y, &hit)) {
    return FvpRefusePress(11u);
  }
  submit->generation = model.generation;
  submit->glyph = static_cast<uint32_t>(hit);
  submit->line = model.glyphs[hit].line;
  submit->rect = model.glyphs[hit].rect;
  submit->physical_w = model.physical_w;
  submit->physical_h = model.physical_h;
  return true;
}

template <uint32_t Slot>
LRESULT CALLBACK FvpWndProcDetour(HWND hwnd, UINT message, WPARAM wparam,
                                  LPARAM lparam) {
  auto& rt = g_fvp_lookup;
  if (rt.live.load(std::memory_order_acquire) &&
      (fvp_lookup::NeedsEligibility(message) ||
       message == fvp_lookup::kMessageLeftUp)) {
    bool eligible = false;
    FvpSubmit submit;
    if (fvp_lookup::NeedsEligibility(message)) {
      __try {
        eligible = FvpPressEligible(hwnd, wparam, lparam, &submit);
      } __except (EXCEPTION_EXECUTE_HANDLER) {
        eligible = false;
      }
    }
    const auto decision =
        fvp_lookup::DecideMessage(message, eligible, &rt.claim);
    if (decision.submit) {
      QueueFvpSubmit(submit);
      rt.claimed_presses.fetch_add(1u, std::memory_order_relaxed);
    }
    if (decision.swallow) return 0;
  }
  return g_fvp_wndproc_original[Slot](hwnd, message, wparam, lparam);
}

constexpr std::array<WNDPROC, kFvpWndProcSlots> kFvpWndProcDetours = {
    &FvpWndProcDetour<0u>, &FvpWndProcDetour<1u>, &FvpWndProcDetour<2u>,
    &FvpWndProcDetour<3u>};

// ── HookWorker ─────────────────────────────────────────────────────────────

// Worker-only, bounded diagnostics in %TEMP%\fushi_galhook.log.  Never logs
// dialogue text.
void FvpLookupLog(const wchar_t* format, ...) {
  wchar_t line[512] = {};
  va_list args;
  va_start(args, format);
  _vsnwprintf_s(line, _TRUNCATE, format, args);
  va_end(args);
  wchar_t path[MAX_PATH] = {};
  const DWORD length = GetTempPathW(MAX_PATH, path);
  if (length == 0 || length >= MAX_PATH - 20) return;
  wcscat_s(path, L"fushi_galhook.log");
  HANDLE file = g_orig_CreateFileW(path, FILE_APPEND_DATA, FILE_SHARE_READ,
                                   nullptr, OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL,
                                   nullptr);
  if (file == INVALID_HANDLE_VALUE) return;
  SYSTEMTIME now = {};
  GetLocalTime(&now);
  wchar_t stamped[640] = {};
  _snwprintf_s(stamped, _TRUNCATE, L"%02u:%02u:%02u.%03u pid=%lu %s\r\n",
               now.wHour, now.wMinute, now.wSecond, now.wMilliseconds,
               GetCurrentProcessId(), line);
  char utf8[1920] = {};
  const int bytes = WideCharToMultiByte(CP_UTF8, 0, stamped, -1, utf8,
                                        sizeof(utf8), nullptr, nullptr);
  if (bytes > 1) {
    DWORD written = 0;
    WriteFile(file, utf8, static_cast<DWORD>(bytes - 1), &written, nullptr);
  }
  g_orig_CloseHandle(file);
}

// One MinHook transaction per target; a target someone else already hooked
// installs none.
bool InstallFvpHook(void* target, void* detour, void** original) {
  if (!g_cs_ready || target == nullptr) return false;
  EnterCriticalSection(&g_cs);
  bool ok = g_hooked_count + 1 <= 64;
  for (int i = 0; ok && i < g_hooked_count; ++i) {
    ok = g_hooked_fns[i] != target;
  }
  bool created = false;
  if (ok) {
    created = MH_CreateHook(target, detour, original) == MH_OK;
    ok = created && MH_QueueEnableHook(target) == MH_OK &&
         MH_ApplyQueued() == MH_OK;
  }
  if (ok) {
    g_hooked_fns[g_hooked_count++] = target;
  } else {
    if (created) MH_RemoveHook(target);
    *original = nullptr;
  }
  LeaveCriticalSection(&g_cs);
  return ok;
}

bool InstallFvpLookup() {
  auto& rt = g_fvp_lookup;
  if (rt.installed) return true;
  if (rt.resolved) {
    if (!rt.hooks_installed) return false;
    rt.claim = fvp_lookup::ClaimState();
    rt.live.store(true, std::memory_order_release);
    rt.installed = true;
    return true;
  }
  rt.resolved = true;
  LARGE_INTEGER frequency = {}, started = {}, finished = {};
  QueryPerformanceFrequency(&frequency);
  QueryPerformanceCounter(&started);
  fushi_voice_hook::exact_lookup::LoadedPeImage image;
  if (!fushi_voice_hook::exact_lookup::OpenLoadedPeImage(
          GetModuleHandleW(nullptr), &image)) {
    rt.site_result = fvp_lookup::SiteResult::kNotX86;
  } else {
    rt.site_result = fvp_lookup::ResolveSites(image, &rt.sites);
  }
  QueryPerformanceCounter(&finished);
  const double scan_ms =
      frequency.QuadPart > 0
          ? 1000.0 * static_cast<double>(finished.QuadPart - started.QuadPart) /
                static_cast<double>(frequency.QuadPart)
          : 0.0;
  if (rt.site_result != fvp_lookup::SiteResult::kResolved) {
    FvpLookupLog(L"fvp-lookup: sites unresolved result=%u scan=%.1fms",
                 static_cast<unsigned>(rt.site_result), scan_ms);
    return false;
  }
  NoteFvpFlag(kFvpFlagSitesResolved);
  rt.image_base = reinterpret_cast<uintptr_t>(image.base);
  rt.claim = fvp_lookup::ClaimState();
  // Detours read `live` before touching any state; publish the state first.
  rt.live.store(true, std::memory_order_release);
  const auto at = [&rt](uintptr_t rva) {
    return reinterpret_cast<void*>(rt.image_base + rva);
  };
  // PutGlyph and Draw first: a Print detour that runs before its PutGlyph
  // detour would publish a print without glyphs (fail-closed, but noisy).
  const bool glyph = InstallFvpHook(
      at(rt.sites.put_glyph), reinterpret_cast<void*>(&FvpPutGlyphDetour),
      reinterpret_cast<void**>(&g_fvp_put_glyph_original));
  const bool draw =
      glyph && InstallFvpHook(at(rt.sites.draw),
                              reinterpret_cast<void*>(&FvpDrawDetour),
                              reinterpret_cast<void**>(&g_fvp_draw_original));
  const bool print =
      draw && InstallFvpHook(at(rt.sites.print),
                             reinterpret_cast<void*>(&FvpPrintDetour),
                             reinterpret_cast<void**>(&g_fvp_print_original));
  // A partial install stays inert: the installed detours forward unchanged
  // while `live` is false.
  rt.hooks_installed = glyph && draw && print;
  rt.installed = rt.hooks_installed;
  if (!rt.hooks_installed) rt.live.store(false, std::memory_order_release);
  if (rt.installed) NoteFvpFlag(kFvpFlagTextHooked);
  FvpLookupLog(
      L"fvp-lookup: sites print=+0x%lx glyph=+0x%lx draw=+0x%lx vm=+0x%lx "
      L"array=0x%x field=0x%x surface=0x%x pen=0x%x adv=0x%x design=0x%x,0x%x "
      L"hooks=%d/%d/%d scan=%.1fms",
      static_cast<unsigned long>(rt.sites.print),
      static_cast<unsigned long>(rt.sites.put_glyph),
      static_cast<unsigned long>(rt.sites.draw),
      static_cast<unsigned long>(rt.sites.vm_global), rt.sites.text_array,
      rt.sites.prim_text_field, rt.sites.surface_offset, rt.sites.pen_x,
      rt.sites.glyph_advance, rt.sites.design_w, rt.sites.design_h,
      print ? 1 : 0, glyph ? 1 : 0, draw ? 1 : 0, scan_ms);
  if (rt.installed && g_header != nullptr) {
    fushi_voice_hook::AtomicOrShared32(
        &g_header->lookup_diag, fushi_voice_hook::kLookupDiagSensorInstalled);
  }
  return rt.installed;
}

bool ReadFvpDesignSize(int32_t* w, int32_t* h) {
  auto& rt = g_fvp_lookup;
  uintptr_t vm = 0u;
  return ReadFvpValue(rt.image_base + rt.sites.vm_global, &vm) && vm != 0u &&
         ReadFvpValue(vm + rt.sites.design_w, w) &&
         ReadFvpValue(vm + rt.sites.design_h, h) &&
         fvp_lookup::DesignPlausible(*w, *h);
}

constexpr wchar_t kFvpHookCode[] = L"ENGINE:FVP:text_print";
constexpr char kFvpHookName[] = "FVP exact";

uint64_t FvpLaneId(int32_t buffer) {
  return fushi_voice_hook::NativeTextThreadIdFrom(
      static_cast<uint64_t>(buffer) + 1u, kFvpHookCode, kFvpHookName);
}

uint64_t PublishFvpTextLine(const std::wstring& text, int32_t buffer,
                            uintptr_t address, uint64_t tick, uint64_t step,
                            uint64_t epoch) {
  auto& rt = g_fvp_lookup;
  if (!g_capture_enabled || g_header == nullptr || g_text_base == nullptr ||
      !g_text_cs_ready || text.empty() ||
      text.size() * sizeof(wchar_t) > fushi_voice_hook::kTextSlotBytes) {
    return 0u;
  }
  const uint64_t thread_id = FvpLaneId(buffer);
  // A repeat of the same line on the same lane within the window is a
  // re-print (repaint), not a new line.
  if (thread_id == rt.last_text_thread && text == rt.last_text &&
      tick - rt.last_text_tick <= kFvpTextDedupeMs) {
    return rt.last_text_event;
  }
  fushi_voice_hook::TextLaneWrite write;
  write.thread_id = thread_id;
  write.thread_address = address;
  write.thread_context = static_cast<uint64_t>(buffer);
  write.process_id = GetCurrentProcessId();
  write.source_kind = fushi_voice_hook::kTextSourceFvp;
  write.is_utf8 = 0;
  write.text = text.data();
  write.byte_len = static_cast<uint32_t>(text.size() * sizeof(wchar_t));
  write.hook_name = kFvpHookName;
  write.hook_code = kFvpHookCode;
  EnterCriticalSection(&g_text_cs);
  const uint64_t event = fushi_voice_hook::WriteTextLaneEvent(
      g_header, fushi_voice_hook::kNativeThreadPreviewStart,
      fushi_voice_hook::kTextLaneCount, write);
  LeaveCriticalSection(&g_text_cs);
  if (event == 0u) return 0u;
  NoteFvpFlag(kFvpFlagTextObserved);
  g_fvp_published_text[g_fvp_published_text_next++ % kFvpPublishedTextSlots] =
      {event, thread_id, tick, step, epoch};
  // An exact engine producer is live: the GDI glyph fallback yields (FVP
  // rasterises every glyph through GetGlyphOutlineA).
  g_header->luna_active = 1;
  rt.last_text = text;
  rt.last_text_thread = thread_id;
  rt.last_text_tick = tick;
  rt.last_text_event = event;
  return event;
}

// Converts one queued print; publishes it on its buffer's lane and, when its
// glyph records pair one-to-one with the displayed units, makes it the
// buffer's current page.  A newer print on the same buffer replaces the page
// (fail closed).
void ProcessFvpTextEvent(const FvpTextEvent& event) {
  auto& rt = g_fvp_lookup;
  if (event.text_bytes == 0u || event.buffer < 0 ||
      event.buffer >= static_cast<int32_t>(fvp_lookup::kTextBufferCount)) {
    return;
  }
  const fvp_lookup::ParsedLine parsed =
      fvp_lookup::ParseLine(event.text, event.text_bytes);
  std::wstring text;
  std::array<uint32_t, fvp_lookup::kMaxUnits> codepoints{};
  std::array<uint16_t, fvp_lookup::kMaxUnits> sources{};
  bool mappable = !parsed.malformed && !parsed.truncated;
  uint32_t text_unit = 0u;
  for (uint32_t index = 0u; index < parsed.count; ++index) {
    const fvp_lookup::TextUnit& unit = parsed.units[index];
    if (unit.ruby) continue;
    wchar_t wide[4] = {};
    const int converted = MultiByteToWideChar(
        932, MB_ERR_INVALID_CHARS,
        reinterpret_cast<const char*>(event.text + unit.offset), unit.length,
        wide, 4);
    if (converted != 1) {
      mappable = false;
      if (converted > 0) text.append(wide, static_cast<size_t>(converted));
      ++text_unit;
      continue;
    }
    codepoints[text_unit] = wide[0];
    sources[text_unit] = static_cast<uint16_t>(text.size());
    text.push_back(wide[0]);
    ++text_unit;
  }
  if (text.empty()) return;
  const uint64_t text_event =
      PublishFvpTextLine(text, event.buffer, event.text_object, event.tick,
                         event.step, event.epoch);

  FvpPage& page = rt.pages[static_cast<size_t>(event.buffer)];
  page.valid = false;
  const size_t cells =
      mappable && !event.glyphs_overflow
          ? fvp_lookup::PairLineGlyphs(parsed, event.glyphs, event.glyph_count,
                                       rt.cell_scratch.data(),
                                       rt.cell_scratch.size())
          : 0u;
  if (cells == 0u || cells != parsed.text_units || text_event == 0u) {
    if (rt.logged_pages < kFvpModelLogBudget) {
      ++rt.logged_pages;
      FvpLookupLog(
          L"fvp-lookup: print unmapped buffer=%d units=%u text=%u ruby=%u "
          L"glyphs=%u overflow=%d malformed=%d event=%llu",
          event.buffer, parsed.count, parsed.text_units, parsed.ruby_units,
          event.glyph_count, event.glyphs_overflow ? 1 : 0,
          parsed.malformed ? 1 : 0, static_cast<unsigned long long>(text_event));
    }
    return;
  }
  if (rt.logged_pages < kFvpModelLogBudget) {
    ++rt.logged_pages;
    const auto& c0 = rt.cell_scratch[0];
    FvpLookupLog(
        L"fvp-lookup: print buffer=%d units=%u text=%u ruby=%u first=%d,%d "
        L"%dx%d pen_end=%d,%d event=%llu",
        event.buffer, parsed.count, parsed.text_units, parsed.ruby_units,
        c0.x, c0.y, c0.w, c0.h, event.pen_end_x, event.pen_end_y,
        static_cast<unsigned long long>(text_event));
  }
  NoteFvpFlag(kFvpFlagPageMapped);
  page.valid = true;
  page.id = ++rt.next_page;
  page.text_object = event.text_object;
  page.buffer_prints = event.buffer_prints;
  page.pen_end_x = event.pen_end_x;
  page.pen_end_y = event.pen_end_y;
  page.text_event = text_event;
  page.lane = FvpLaneId(event.buffer);
  page.count = static_cast<uint32_t>(cells);
  std::copy_n(rt.cell_scratch.begin(), cells, page.cells.begin());
  page.codepoints = codepoints;
  page.sources = sources;
}

void DrainFvpTextEvents() {
  auto& rt = g_fvp_lookup;
  const uint64_t latest = rt.event_count.load(std::memory_order_acquire);
  if (latest == rt.processed_event_seq) return;
  uint64_t next = rt.processed_event_seq + 1u;
  if (latest - rt.processed_event_seq > kFvpEventSlots) {
    next = latest - kFvpEventSlots + 1u;  // overrun: oldest prints are lost
  }
  for (; next <= latest; ++next) {
    auto& slot_seq = rt.event_seq[next % kFvpEventSlots];
    if (slot_seq.load(std::memory_order_acquire) != next) break;  // in flight
    std::atomic_thread_fence(std::memory_order_acquire);
    std::memcpy(&rt.event_copy, &rt.events[next % kFvpEventSlots],
                sizeof(FvpTextEvent));
    std::atomic_thread_fence(std::memory_order_acquire);
    rt.processed_event_seq = next;
    if (slot_seq.load(std::memory_order_acquire) != next) continue;  // torn
    ProcessFvpTextEvent(rt.event_copy);
  }
}

// The main window: the one visible top-level ANSI window of this process whose
// window procedure lies in the game image's code, with every distinct in-image
// procedure of the frame and its descendants (the client-covering child
// receives the mouse).  `identity` names the window set seen (0 = none yet):
// a rejection holds only for that set, so a splash window that goes away or
// a window destroyed and recreated is evaluated again.
struct FvpWindowSearch {
  uintptr_t base = 0u;
  fushi_voice_hook::exact_lookup::LoadedPeImage image;
  HWND window = nullptr;
  uintptr_t procedure = 0u;
  uintptr_t window_xor = 0u;
  uint32_t matches = 0u;
};

struct FvpWindowChildren {
  const FvpWindowSearch* search = nullptr;
  fvp_lookup::WindowCandidate* candidate = nullptr;
  bool overflow = false;
};

bool FvpInImageProcedure(const FvpWindowSearch& search, uintptr_t procedure) {
  return procedure >= search.base &&
         fvp_lookup::IsExecutableRva(search.image, procedure - search.base,
                                     16u);
}

BOOL CALLBACK FvpCollectTopWindow(HWND hwnd, LPARAM context) {
  auto* s = reinterpret_cast<FvpWindowSearch*>(context);
  DWORD pid = 0;
  GetWindowThreadProcessId(hwnd, &pid);
  if (pid != GetCurrentProcessId() || !IsWindowVisible(hwnd) ||
      IsWindowUnicode(hwnd)) {
    return TRUE;
  }
  const uintptr_t procedure =
      static_cast<uintptr_t>(GetWindowLongPtrA(hwnd, GWLP_WNDPROC));
  if (!FvpInImageProcedure(*s, procedure)) return TRUE;
  ++s->matches;
  s->window = hwnd;
  s->procedure = procedure;
  s->window_xor ^= reinterpret_cast<uintptr_t>(hwnd);
  return TRUE;
}

BOOL CALLBACK FvpCollectChildProcedure(HWND hwnd, LPARAM context) {
  auto* c = reinterpret_cast<FvpWindowChildren*>(context);
  if (IsWindowUnicode(hwnd)) return TRUE;
  const uintptr_t procedure =
      static_cast<uintptr_t>(GetWindowLongPtrA(hwnd, GWLP_WNDPROC));
  if (!FvpInImageProcedure(*c->search, procedure)) return TRUE;
  fvp_lookup::WindowCandidate& candidate = *c->candidate;
  for (uint32_t k = 0u; k < candidate.procedure_count; ++k) {
    if (candidate.procedures[k] == procedure) return TRUE;
  }
  if (candidate.procedure_count >= fvp_lookup::kMaxWindowProcedures) {
    c->overflow = true;
    return FALSE;
  }
  candidate.procedures[candidate.procedure_count++] = procedure;
  return TRUE;
}

bool CollectFvpWindowCandidate(fvp_lookup::WindowCandidate* candidate) {
  FvpWindowSearch search;
  search.base = g_fvp_lookup.image_base;
  if (!fushi_voice_hook::exact_lookup::OpenLoadedPeImage(
          reinterpret_cast<HMODULE>(search.base), &search.image)) {
    return false;
  }
  EnumWindows(&FvpCollectTopWindow, reinterpret_cast<LPARAM>(&search));
  *candidate = fvp_lookup::WindowCandidate();
  if (search.matches == 0u) return true;  // not created yet
  candidate->identity =
      (static_cast<uint64_t>(search.window_xor) << 8) ^ search.matches;
  if (search.matches != 1u) return true;  // ambiguous: not acceptable
  candidate->window = reinterpret_cast<uintptr_t>(search.window);
  candidate->procedures[candidate->procedure_count++] = search.procedure;
  FvpWindowChildren children;
  children.search = &search;
  children.candidate = candidate;
  EnumChildWindows(search.window, &FvpCollectChildProcedure,
                   reinterpret_cast<LPARAM>(&children));
  candidate->acceptable = !children.overflow;
  return true;
}

// Hooks the candidate's procedures that are not hooked yet, each into the
// next free detour slot.  A procedure hooked once stays hooked.
bool HookFvpWindowProcedures(const fvp_lookup::WindowCandidate& candidate) {
  auto& state = g_fvp_lookup.window_state;
  for (uint32_t k = 0u; k < candidate.procedure_count; ++k) {
    const uintptr_t procedure = candidate.procedures[k];
    if (fvp_lookup::WindowProcedureHooked(state, procedure)) continue;
    const uint32_t slot = state.hooked_count;
    if (slot >= kFvpWndProcSlots) return false;
    const bool hooked = InstallFvpHook(
        reinterpret_cast<void*>(procedure),
        reinterpret_cast<void*>(kFvpWndProcDetours[slot]),
        reinterpret_cast<void**>(&g_fvp_wndproc_original[slot]));
    FvpLookupLog(L"fvp-lookup: window procedure %u +0x%lx hooked=%d", slot,
                 static_cast<unsigned long>(procedure -
                                            g_fvp_lookup.image_base),
                 hooked ? 1 : 0);
    if (!hooked) return false;
    state.hooked[state.hooked_count++] = procedure;
  }
  return true;
}

void TryHookFvpWindow() {
  auto& rt = g_fvp_lookup;
  auto& state = rt.window_state;
  const HWND bound = reinterpret_cast<HWND>(state.bound);
  DWORD pid = 0u;
  state.bound_alive = bound != nullptr && IsWindow(bound) &&
                      GetWindowThreadProcessId(bound, &pid) != 0u &&
                      pid == GetCurrentProcessId();
  if (fvp_lookup::DecideWindowStep(fvp_lookup::WindowCandidate(), state) ==
      fvp_lookup::WindowStep::kKeep) {
    return;
  }
  if (state.bound != 0u) {
    FvpLookupLog(L"fvp-lookup: bound window gone, re-evaluating");
    state.bound = 0u;
    rt.window = nullptr;
  }
  const uint64_t now = GetTickCount64();
  if (rt.window_retry_tick != 0u &&
      now - rt.window_retry_tick < kFvpWindowRetryMs) {
    return;
  }
  rt.window_retry_tick = now;
  fvp_lookup::WindowCandidate candidate;
  if (!CollectFvpWindowCandidate(&candidate)) return;
  switch (fvp_lookup::DecideWindowStep(candidate, state)) {
    case fvp_lookup::WindowStep::kKeep:
    case fvp_lookup::WindowStep::kWait:
      return;
    case fvp_lookup::WindowStep::kReject:
      state.rejected_identity = candidate.identity;
      FvpLookupLog(L"fvp-lookup: window set rejected (acceptable=%d procs=%u)",
                   candidate.acceptable ? 1 : 0, candidate.procedure_count);
      return;
    case fvp_lookup::WindowStep::kHook:
      if (!HookFvpWindowProcedures(candidate)) {
        state.rejected_identity = candidate.identity;
        return;
      }
      break;
    case fvp_lookup::WindowStep::kBind:
      break;
  }
  state.bound = candidate.window;
  state.bound_alive = true;
  rt.window = reinterpret_cast<HWND>(candidate.window);
  NoteFvpFlag(kFvpFlagWindowHooked);
  FvpLookupLog(L"fvp-lookup: window bound procs=%u hooked=%u",
               candidate.procedure_count, state.hooked_count);
}

void RetireFvpLookup() {
  auto& rt = g_fvp_lookup;
  InvalidateFvpModel();
  rt.model.generation = 0u;
  rt.model.count = 0u;
  rt.model_line.clear();
  rt.model_text_event = 0u;
  if (!rt.provider_offered) return;
  rt.provider_offered = false;
  if (g_header != nullptr) {
    fushi_voice_hook::g_geometry_provider_registry.Retire(
        g_header, fushi_voice_hook::kLookupGeometryProviderEngineExactLayout,
        fushi_voice_hook::kLookupGeometryProviderIdFvp);
  }
}

struct FvpDpiScope {
  explicit FvpDpiScope(DPI_AWARENESS_CONTEXT context)
      : previous(SetThreadDpiAwarenessContext(context)) {}
  ~FvpDpiScope() {
    if (previous != nullptr) SetThreadDpiAwarenessContext(previous);
  }
  DPI_AWARENESS_CONTEXT previous;
};

// Diagnostic detail of the last model-build failure (worker only).
struct FvpModelFailure {
  // 1 window 2 dpi 3 text object 4 not drawn 5 design 6 aspect 7 no match
  // 8 projection
  uint32_t step = 0u;
  int32_t a = 0, b = 0, c = 0, d = 0;
};
FvpModelFailure g_fvp_model_failure;

bool FailFvpModel(uint32_t step, int32_t a = 0, int32_t b = 0, int32_t c = 0,
                  int32_t d = 0) {
  g_fvp_model_failure = {step, a, b, c, d};
  return false;
}

bool BuildFvpModel(const FvpPage& page, int32_t buffer,
                   const std::wstring& line, FvpModel* model,
                   uint32_t* first_glyph) {
  auto& rt = g_fvp_lookup;
  const HWND game = rt.window;
  DWORD pid = 0;
  if (game == nullptr || !IsWindow(game) ||
      GetWindowThreadProcessId(game, &pid) == 0 ||
      pid != GetCurrentProcessId() || !IsWindowVisible(game) ||
      IsIconic(game)) {
    return FailFvpModel(1u);
  }
  // "Logical" is what the window's own thread sees (lparam and GetClientRect
  // in the window procedure).
  RECT logical = {};
  RECT physical = {};
  {
    const DPI_AWARENESS_CONTEXT window_context =
        GetWindowDpiAwarenessContext(game);
    if (window_context == nullptr) return FailFvpModel(2u);
    FvpDpiScope own(window_context);
    if (own.previous == nullptr || !GetClientRect(game, &logical)) {
      return FailFvpModel(2u);
    }
  }
  {
    FvpDpiScope aware(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
    if (aware.previous == nullptr || !GetClientRect(game, &physical)) {
      return FailFvpModel(2u);
    }
  }
  if (!FvpTextObjectUnchanged(page.text_object, buffer, page.pen_end_x,
                              page.pen_end_y)) {
    return FailFvpModel(3u);
  }
  int32_t origin_x = 0, origin_y = 0;
  if (!FvpDrawnOrigin(page.text_object + rt.sites.surface_offset, &origin_x,
                      &origin_y)) {
    FvpDrawSlot draw;
    const bool read = ReadFvpDraw(&draw);
    return FailFvpModel(4u, read ? draw.state.alpha : -1,
                        read ? draw.state.flags : -1,
                        read ? static_cast<int32_t>(
                                   g_fvp_lookup.draw_calls.load() - draw.draws)
                             : -1,
                        read ? draw.state.rotation : -1);
  }
  NoteFvpFlag(kFvpFlagDrawObserved);
  int32_t design_w = 0, design_h = 0;
  if (!ReadFvpDesignSize(&design_w, &design_h)) return FailFvpModel(5u);
  const int32_t logical_w = logical.right - logical.left;
  const int32_t logical_h = logical.bottom - logical.top;
  const int32_t physical_w = physical.right - physical.left;
  const int32_t physical_h = physical.bottom - physical.top;
  if (!fvp_lookup::ClientMatchesDesign(logical_w, logical_h, design_w,
                                       design_h) ||
      !fvp_lookup::ClientMatchesDesign(physical_w, physical_h, design_w,
                                       design_h)) {
    return FailFvpModel(6u, design_w, design_h, logical_w, logical_h);
  }
  auto& glyphs = rt.scratch;
  const size_t count = fvp_lookup::BuildPageGlyphs(
      page.cells.data(), page.count, page.codepoints.data(),
      page.sources.data(), origin_x, origin_y, glyphs.data(), glyphs.size());
  if (count == 0u) return FailFvpModel(7u, 0, static_cast<int32_t>(page.count));
  const size_t first = fvp_lookup::MapSelectedSuffix(glyphs.data(), count,
                                                     line.data(), line.size());
  if (first >= count) {
    return FailFvpModel(7u, 1, static_cast<int32_t>(count),
                        static_cast<int32_t>(line.size()));
  }
  model->page = page.id;
  model->buffer_prints = page.buffer_prints;
  model->window = reinterpret_cast<uintptr_t>(game);
  model->text_object = page.text_object;
  model->buffer = buffer;
  model->pen_end_x = page.pen_end_x;
  model->pen_end_y = page.pen_end_y;
  model->origin_x = origin_x;
  model->origin_y = origin_y;
  model->design_w = design_w;
  model->design_h = design_h;
  model->logical_w = logical_w;
  model->logical_h = logical_h;
  model->physical_w = physical_w;
  model->physical_h = physical_h;
  model->count = 0u;
  for (size_t index = first; index < count; ++index) {
    const auto& glyph = glyphs[index];
    if (glyph.source_index == fvp_lookup::kNoSource) continue;
    FvpModelGlyph& out = model->glyphs[model->count];
    // Every mapped glyph must project into the client: a partially visible
    // line is not a line the user can be looking at.
    if (!fvp_lookup::ProjectCell(glyph, design_w, design_h, physical_w,
                                 physical_h, &out.rect)) {
      return FailFvpModel(8u, glyph.x, glyph.y, physical_w, physical_h);
    }
    out.line = glyph;
    ++model->count;
  }
  *first_glyph = static_cast<uint32_t>(first);
  return model->count != 0u;
}

bool SameFvpModelGeometry(const FvpModel& left, const FvpModel& right) {
  if (left.page != right.page || left.buffer_prints != right.buffer_prints ||
      left.window != right.window || left.text_object != right.text_object ||
      left.origin_x != right.origin_x || left.origin_y != right.origin_y ||
      left.design_w != right.design_w || left.design_h != right.design_h ||
      left.logical_w != right.logical_w ||
      left.logical_h != right.logical_h ||
      left.physical_w != right.physical_w ||
      left.physical_h != right.physical_h || left.count != right.count) {
    return false;
  }
  for (uint32_t index = 0u; index < left.count; ++index) {
    const auto& a = left.glyphs[index];
    const auto& b = right.glyphs[index];
    if (a.rect.x != b.rect.x || a.rect.y != b.rect.y || a.rect.w != b.rect.w ||
        a.rect.h != b.rect.h || a.line.source_index != b.line.source_index) {
      return false;
    }
  }
  return true;
}

bool FailFvpHit(const FvpSubmit& submit, const wchar_t* reason) {
  FvpLookupLog(L"fvp-lookup: hit dropped gen=%llu glyph=%u reason=%s",
               static_cast<unsigned long long>(submit.generation),
               submit.glyph, reason);
  return false;
}

bool PublishFvpLookupHit(const FvpSubmit& submit) {
  auto& rt = g_fvp_lookup;
  if (g_header == nullptr || submit.generation == 0u) {
    return FailFvpHit(submit, L"no-header");
  }
  const fvp_lookup::PublishedLine* record =
      rt.published_lines.Find(submit.generation);
  if (record == nullptr) return FailFvpHit(submit, L"model-gone");
  const std::wstring& model_line = record->line;
  const size_t units = model_line.size();
  if (submit.line.source_index == fvp_lookup::kNoSource ||
      submit.line.source_length == 0u || submit.line.source_index >= units ||
      submit.line.source_length > units - submit.line.source_index ||
      fushi_voice_hook::LookupUtf16SourceLength(
          model_line.data(), static_cast<uint32_t>(units),
          submit.line.source_index) != submit.line.source_length) {
    return FailFvpHit(submit, L"source-range");
  }
  const int required = WideCharToMultiByte(
      CP_UTF8, WC_ERR_INVALID_CHARS, model_line.data(), static_cast<int>(units),
      nullptr, 0, nullptr, nullptr);
  if (required <= 0 ||
      static_cast<uint32_t>(required) > fushi_voice_hook::kLookupLineBytes) {
    return FailFvpHit(submit, L"line-bytes");
  }
  char utf8[fushi_voice_hook::kLookupLineBytes] = {};
  if (WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, model_line.data(),
                          static_cast<int>(units), utf8, required, nullptr,
                          nullptr) != required) {
    return FailFvpHit(submit, L"utf8");
  }
  fushi_voice_hook::LookupGeometryHitPublication publication;
  publication.provider_kind =
      fushi_voice_hook::kLookupGeometryProviderEngineExactLayout;
  publication.provider_id = fushi_voice_hook::kLookupGeometryProviderIdFvp;
  publication.char_index = submit.line.source_index;
  publication.source_length = submit.line.source_length;
  publication.char_count = static_cast<uint32_t>(units);
  publication.coordinate_space =
      fushi_voice_hook::kLookupCoordinateSpaceClientPhysicalPixels;
  publication.writing_mode = fushi_voice_hook::kLookupWritingModeHorizontal;
  publication.text_generation = record->text_event;
  publication.geometry_generation = submit.generation;
  publication.glyph_x = submit.rect.x;
  publication.glyph_y = submit.rect.y;
  publication.glyph_w = submit.rect.w;
  publication.glyph_h = submit.rect.h;
  publication.view_w = submit.physical_w;
  publication.view_h = submit.physical_h;
  publication.flags = fushi_voice_hook::kLookupHitFlagSubmit;
  publication.line_utf8 = reinterpret_cast<const uint8_t*>(utf8);
  publication.line_bytes = static_cast<uint32_t>(required);
  const bool published =
      fushi_voice_hook::g_geometry_provider_registry.PublishHit(g_header,
                                                                publication);
  if (published) NoteFvpFlag(kFvpFlagHitPublished);
  FvpLookupLog(
      L"fvp-lookup: hit gen=%llu glyph=%u char=%u+%u rect=%d,%d %dx%d "
      L"design=%d,%d %dx%d view=%dx%d published=%d",
      static_cast<unsigned long long>(submit.generation), submit.glyph,
      submit.line.source_index, submit.line.source_length, submit.rect.x,
      submit.rect.y, submit.rect.w, submit.rect.h, submit.line.x,
      submit.line.y, submit.line.w, submit.line.h, submit.physical_w,
      submit.physical_h, published ? 1 : 0);
  return published;
}

bool ReadLatestFvpSubmit(FvpSubmit* out) {
  auto& rt = g_fvp_lookup;
  const uint64_t sequence = rt.submit_count.load(std::memory_order_acquire);
  if (sequence == 0u || sequence == rt.processed_submit_seq) return false;
  rt.processed_submit_seq = sequence;
  auto& slot_seq = rt.submit_seq[sequence % kFvpSubmitSlots];
  if (slot_seq.load(std::memory_order_acquire) != sequence) return false;
  std::atomic_thread_fence(std::memory_order_acquire);
  *out = rt.submits[sequence % kFvpSubmitSlots];
  std::atomic_thread_fence(std::memory_order_acquire);
  return slot_seq.load(std::memory_order_acquire) == sequence;
}

// Why the last tick retired (0 = offered).  Logged once per change.
void NoteFvpRetire(uint32_t reason) {
  static uint32_t last = UINT32_MAX;
  static uint32_t budget = kFvpModelLogBudget;
  const uint32_t key =
      reason == 4u ? 100u + g_fvp_model_failure.step : reason;
  if (key == last || budget == 0u) return;
  last = key;
  --budget;
  static const wchar_t* const kNames[] = {
      L"offered",          L"lookup-disabled", L"no-page",
      L"no-selected-text", L"model-unbuilt",   L"offer-rejected",
      L"no-window"};
  if (reason == 4u) {
    const auto& f = g_fvp_model_failure;
    FvpLookupLog(L"fvp-lookup: gate=%s step=%u %d,%d,%d,%d prints=%u",
                 kNames[reason], f.step, f.a, f.b, f.c, f.d,
                 g_fvp_lookup.print_hits.load());
    return;
  }
  FvpLookupLog(L"fvp-lookup: gate=%s", reason < 7u ? kNames[reason] : L"?");
}

void ProcessFvpLookupTick() {
  auto& rt = g_fvp_lookup;
  if (!rt.installed) return;
  // The text lane does not depend on the lookup switch.
  DrainFvpTextEvents();
  if (g_stop || g_header == nullptr ||
      !fushi_voice_hook::HasLookupRegion(g_header) ||
      fushi_voice_hook::AtomicLoadShared32(&g_header->lookup_enabled) == 0u) {
    NoteFvpRetire(1u);
    rt.watched_surface.store(0u, std::memory_order_release);
    RetireFvpLookup();
    return;
  }
  fushi_voice_hook::AtomicOrShared32(
      &g_header->lookup_diag, fushi_voice_hook::kLookupDiagSensorInstalled);
  // A press the window procedure already swallowed is published (or its drop
  // logged) whatever the gates below say now: the game never saw it.
  const uint64_t claims = rt.claimed_presses.load(std::memory_order_acquire);
  if (claims != rt.logged_claims) {
    rt.logged_claims = claims;
    NoteFvpFlag(kFvpFlagPressClaimed);
    FvpLookupLog(L"fvp-lookup: press claimed total=%llu",
                 static_cast<unsigned long long>(claims));
  }
  const uint32_t refusals = rt.refused_presses.load(std::memory_order_acquire);
  if (refusals != rt.logged_refusals) {
    rt.logged_refusals = refusals;
    FvpLookupLog(L"fvp-lookup: press refused total=%u reason=%u", refusals,
                 rt.refused_reason.load(std::memory_order_relaxed));
  }
  FvpSubmit submit;
  if (ReadLatestFvpSubmit(&submit)) (void)PublishFvpLookupHit(submit);
  TryHookFvpWindow();
  if (rt.window_state.bound == 0u) {
    NoteFvpRetire(6u);
    RetireFvpLookup();
    return;
  }
  std::wstring line;
  uint64_t event = 0u;
  uint64_t thread = 0u;
  if (!fushi_voice_hook::ReadSelectedLookupText(
          g_header, &line, &event, &thread, fvp_lookup::kMaxUnits)) {
    NoteFvpRetire(3u);
    rt.watched_surface.store(0u, std::memory_order_release);
    RetireFvpLookup();
    return;
  }
  // The selected lane names the text buffer whose page is mapped.
  int32_t buffer = -1;
  for (uint32_t index = 0u; index < fvp_lookup::kTextBufferCount; ++index) {
    if (rt.pages[index].valid && rt.pages[index].lane == thread) {
      buffer = static_cast<int32_t>(index);
      break;
    }
  }
  if (buffer < 0) {
    NoteFvpRetire(2u);
    rt.watched_surface.store(0u, std::memory_order_release);
    RetireFvpLookup();
    return;
  }
  const FvpPage& page = rt.pages[static_cast<size_t>(buffer)];
  rt.watched_surface.store(page.text_object + rt.sites.surface_offset,
                           std::memory_order_release);
  FvpModel& built = rt.candidate;
  uint32_t first_glyph = 0u;
  if (!BuildFvpModel(page, buffer, line, &built, &first_glyph)) {
    NoteFvpRetire(4u);
    RetireFvpLookup();
    return;
  }
  const bool same = rt.model.generation != 0u && rt.model_text_event == event &&
                    rt.model_line == line &&
                    SameFvpModelGeometry(rt.model, built);
  if (!same) {
    built.generation = ++rt.next_generation;
    rt.model = built;
    rt.model_line = line;
    rt.model_text_event = event;
    rt.published_lines.Record(rt.model.generation, event, line);
    PublishFvpModel(rt.model);
    if (rt.logged_models < kFvpModelLogBudget) {
      ++rt.logged_models;
      const auto& first = rt.model.glyphs[0];
      const auto& last = rt.model.glyphs[rt.model.count - 1u];
      FvpLookupLog(
          L"fvp-lookup: model gen=%llu event=%llu buffer=%d units=%u "
          L"glyphs=%u skipped=%u origin=%d,%d first=%d,%d %dx%d (design "
          L"%d,%d) last=%d,%d %dx%d view=%dx%d client=%dx%d design=%dx%d",
          static_cast<unsigned long long>(rt.model.generation),
          static_cast<unsigned long long>(event), buffer,
          static_cast<unsigned>(line.size()), rt.model.count, first_glyph,
          rt.model.origin_x, rt.model.origin_y, first.rect.x, first.rect.y,
          first.rect.w, first.rect.h, first.line.x, first.line.y, last.rect.x,
          last.rect.y, last.rect.w, last.rect.h, rt.model.physical_w,
          rt.model.physical_h, rt.model.logical_w, rt.model.logical_h,
          rt.model.design_w, rt.model.design_h);
    }
  }
  if (fushi_voice_hook::g_geometry_provider_registry.OfferReady(
          g_header, fushi_voice_hook::kLookupGeometryProviderEngineExactLayout,
          fushi_voice_hook::kLookupGeometryProviderIdFvp)) {
    if (!rt.provider_offered) {
      FvpLookupLog(L"fvp-lookup: OfferReady gen=%llu glyphs=%u",
                   static_cast<unsigned long long>(rt.model.generation),
                   rt.model.count);
    }
    rt.provider_offered = true;
    NoteFvpFlag(kFvpFlagGeometryOffered);
    fushi_voice_hook::AtomicOrShared32(
        &g_header->lookup_diag, fushi_voice_hook::kLookupDiagGeometryObserved);
    NoteFvpRetire(0u);
  } else {
    NoteFvpRetire(5u);
    RetireFvpLookup();
    return;
  }
}

void ShutdownFvpLookup() {
  auto& rt = g_fvp_lookup;
  // The detours stay chained (MinHook owns them for the process lifetime);
  // clearing `live` turns each into a pure forwarder and drops any claim.
  rt.live.store(false, std::memory_order_release);
  rt.watched_surface.store(0u, std::memory_order_release);
  rt.claim = fvp_lookup::ClaimState();
  for (auto& page : rt.pages) page.valid = false;
  RetireFvpLookup();
  rt.installed = false;
}

bool FvpLookupSensorInstalled() { return g_fvp_lookup.installed; }
bool FvpLookupSitesRejected() {
  return g_fvp_lookup.resolved && !g_fvp_lookup.hooks_installed;
}
bool FvpLookupSitesResolved() {
  return g_fvp_lookup.resolved &&
         g_fvp_lookup.site_result == fvp_lookup::SiteResult::kResolved;
}

#else  // !_M_IX86

std::atomic<uint32_t> g_fvp_flags{0u};
void NoteFvpFlag(uint32_t flag) {
  g_fvp_flags.fetch_or(flag, std::memory_order_relaxed);
}
void FvpLookupLog(const wchar_t*, ...) {}
bool InstallFvpLookup() { return false; }
void ProcessFvpLookupTick() {}
void ShutdownFvpLookup() {}
bool FvpLookupSensorInstalled() { return false; }
bool FvpLookupSitesRejected() { return false; }

#endif  // _M_IX86
