// LucaSystem Win64 in-game lookup runtime (EngineExactLayout /
// kLookupGeometryProviderIdLuca).  Engine facts, signatures and every decision
// rule live in luca_lookup_core.h and are unit-tested; this file binds them to
// MinHook, Win32 and the v19 registry.
//
// Threads:
//   * game thread — layout routine entry: the cText being laid out is added to
//     a fixed set of known text boxes (pointer only; nothing is read there).
//   * game thread — the engine's per-frame GetAsyncKeyState(VK_LBUTTON)
//     sample (reached from the generic input shield's detour, which owns that
//     export): a fresh press on exactly one glyph of the current model is
//     claimed and hidden from the engine from press to release, so the game
//     does not advance; the press becomes a registry hit on the worker.
//   * HookWorker — ProcessLucaLookupTick: finds the one known text box whose
//     glyphs spell the selected line, projects them to physical client
//     pixels, offers / retires the provider, publishes the model for the
//     game thread and turns claimed presses into registry hits.
//
// Fail closed everywhere: an unresolved or field-mismatched layout site
// installs nothing; a text box whose glyphs differ from the line, two text
// boxes that both spell it, a missing design size or native-input admission
// retires the provider or refuses the click, and the click then reaches the
// game unchanged.

#include "luca_x64_lookup_core.h"

#if defined(_M_X64)

namespace luca_geometry64 = fushi_voice_hook::luca_x64;

constexpr uint32_t kLucaKnownTexts = 64u;
constexpr uint32_t kLucaModelSlots = 2u;
constexpr uint32_t kLucaSubmitSlots = 8u;

struct LucaModelGlyph {
  luca::LineGlyph line;      // design rect + source unit
  luca::DesignRect physical; // physical client pixels
};

struct LucaModel {
  uint64_t generation = 0u;
  uint64_t text_event = 0u;
  uintptr_t text_box = 0u;
  uintptr_t window = 0u;
  int32_t design_w = 0;
  int32_t design_h = 0;
  int32_t logical_w = 0;
  int32_t logical_h = 0;
  int32_t physical_w = 0;
  int32_t physical_h = 0;
  uint32_t count = 0u;
  std::array<LucaModelGlyph, luca::kMaxGlyphs> glyphs{};
};

struct LucaSubmit {
  uint64_t generation = 0u;
  uint32_t glyph = 0u;
};

struct LucaLookupRuntime {
  // ── HookWorker-owned ──
  bool resolved = false;
  bool installed = false;
  luca::LayoutSiteResult site_result = luca::LayoutSiteResult::kMissing;
  uint32_t layout_rva = 0u;
  bool provider_offered = false;
  uint64_t next_generation = 0u;
  uint64_t processed_submit = 0u;
  LucaModel model;
  LucaModel candidate;
  std::wstring model_line;
  std::vector<luca::Row> rows;
  std::vector<luca::LineGlyph> mapped;
  uint32_t last_gate = UINT32_MAX;
  luca::ShiftState shift;

  // ── game-thread-owned ──
  luca::ClaimState claim;
  LucaModel input_model;

  // ── shared ──
  std::atomic<bool> live{false};
  std::array<std::atomic<uintptr_t>, kLucaKnownTexts> texts = {};
  std::array<std::atomic<uint32_t>, kLucaModelSlots> model_seq = {};
  std::array<LucaModel, kLucaModelSlots> models = {};
  std::atomic<uint32_t> published_model{UINT32_MAX};
  std::array<std::atomic<uint64_t>, kLucaSubmitSlots> submit_seq = {};
  std::array<LucaSubmit, kLucaSubmitSlots> submits = {};
  std::atomic<uint64_t> submit_count{0u};
  std::atomic<uint32_t> press_reject{0u};
  std::atomic<uint32_t> presses{0u};
};

LucaLookupRuntime g_luca_lookup;
using LucaX64LayoutFn = uintptr_t(__fastcall*)(void* text, uint32_t a, uint8_t b);
LucaX64LayoutFn g_luca_layout_original = nullptr;

// ── game thread: layout routine ───────────────────────────────────────────

void RememberLucaText(uintptr_t text) {
  auto& rt = g_luca_lookup;
  for (auto& slot : rt.texts) {
    const uintptr_t value = slot.load(std::memory_order_relaxed);
    if (value == text) return;
    if (value != 0u) continue;
    uintptr_t expected = 0u;
    if (slot.compare_exchange_strong(expected, text,
                                     std::memory_order_acq_rel) ||
        expected == text) {
      return;
    }
  }
}

uintptr_t __fastcall LucaLayoutDetour(void* text, uint32_t a, uint8_t b) {
  if (g_luca_lookup.live.load(std::memory_order_acquire)) {
    RememberLucaText(reinterpret_cast<uintptr_t>(text));
  }
  return g_luca_layout_original(text, a, b);
}

// ── two-slot seqlock (model) ───────────────────────────────────────────────

size_t LucaModelBytes(uint32_t count) {
  return offsetof(LucaModel, glyphs) +
         static_cast<size_t>(count) * sizeof(LucaModelGlyph);
}

void PublishLucaModel(const LucaModel& value) {
  auto& rt = g_luca_lookup;
  const uint32_t current = rt.published_model.load(std::memory_order_acquire);
  const uint32_t slot =
      current >= kLucaModelSlots ? 0u : (current + 1u) % kLucaModelSlots;
  const uint32_t seq = rt.model_seq[slot].load(std::memory_order_relaxed);
  rt.model_seq[slot].store(seq | 1u, std::memory_order_release);
  std::atomic_thread_fence(std::memory_order_release);
  std::memcpy(&rt.models[slot], &value, LucaModelBytes(value.count));
  std::atomic_thread_fence(std::memory_order_release);
  rt.model_seq[slot].store((seq | 1u) + 1u, std::memory_order_release);
  rt.published_model.store(slot, std::memory_order_release);
}

bool ReadLucaModelBytes(LucaModel* out, size_t bytes) {
  auto& rt = g_luca_lookup;
  const uint32_t slot = rt.published_model.load(std::memory_order_acquire);
  if (out == nullptr || slot >= kLucaModelSlots) return false;
  const uint32_t before = rt.model_seq[slot].load(std::memory_order_acquire);
  if (before == 0u || (before & 1u) != 0u) return false;
  std::atomic_thread_fence(std::memory_order_acquire);
  std::memcpy(out, &rt.models[slot], bytes);
  std::atomic_thread_fence(std::memory_order_acquire);
  return rt.model_seq[slot].load(std::memory_order_acquire) == before &&
         rt.published_model.load(std::memory_order_acquire) == slot;
}

bool ReadLucaModel(LucaModel* out) {
  if (!ReadLucaModelBytes(out, offsetof(LucaModel, glyphs))) return false;
  const uint32_t count =
      (std::min)(out->count, static_cast<uint32_t>(luca::kMaxGlyphs));
  return ReadLucaModelBytes(out, LucaModelBytes(count)) && out->count == count;
}

// ── game thread: VK_LBUTTON sample ───────────────────────────────────────

void QueueLucaSubmit(const LucaSubmit& submit) {
  auto& rt = g_luca_lookup;
  const uint64_t sequence =
      rt.submit_count.load(std::memory_order_acquire) + 1u;
  auto& slot_seq = rt.submit_seq[sequence % kLucaSubmitSlots];
  slot_seq.store(0u, std::memory_order_release);
  std::atomic_thread_fence(std::memory_order_release);
  rt.submits[sequence % kLucaSubmitSlots] = submit;
  std::atomic_thread_fence(std::memory_order_release);
  slot_seq.store(sequence, std::memory_order_release);
  rt.submit_count.store(sequence, std::memory_order_release);
}

bool RejectLucaPress(uint32_t reason) {
  g_luca_lookup.press_reject.store(reason, std::memory_order_relaxed);
  return false;
}

bool LucaShieldActive(HWND game) {
  if (IsLookupOverlayInputShieldVisible()) return true;
  if (g_header == nullptr) return false;
  const auto request = fushi_voice_hook::ReadLookupShieldRequest(g_header);
  return request.valid && request.active_buttons != 0u &&
         request.target_hwnd ==
             static_cast<uint64_t>(reinterpret_cast<uintptr_t>(game));
}

// The glyph of `model` under the cursor, read in the game window's logical
// client pixels.  Returns 0 on exactly one hit, otherwise the reject reason
// (4 no cursor, 5 cursor off the window or client resized, 6 projection,
// 7 no single glyph).  No allocation, no IO: also runs on the game thread.
uint32_t HitLucaGlyphAtCursor(const LucaModel& model, HWND game,
                              uint32_t* glyph) {
  POINT cursor = {};
  RECT client = {};
  if (!GetCursorPos(&cursor)) return 4u;
  const HWND under = WindowFromPoint(cursor);
  if ((under != game && !IsChild(game, under)) ||
      !ScreenToClient(game, &cursor) || !GetClientRect(game, &client) ||
      client.right - client.left != model.logical_w ||
      client.bottom - client.top != model.logical_h) {
    return 5u;
  }
  luca::Projection projection;
  int32_t x = 0, y = 0;
  if (!luca::MakeProjection(model.design_w, model.design_h, model.logical_w,
                            model.logical_h, &projection) ||
      !luca::ClientToDesign(cursor.x, cursor.y, projection, model.design_w,
                            model.design_h, &x, &y)) {
    return 6u;
  }
  luca::LineGlyph lines[luca::kMaxGlyphs];
  for (uint32_t i = 0; i < model.count; ++i) lines[i] = model.glyphs[i].line;
  size_t hit = 0u;
  if (!luca::HitTestGlyphs(lines, model.count, x, y, &hit)) return 7u;
  *glyph = static_cast<uint32_t>(hit);
  return 0u;
}

// A fresh engine-sampled press: may it become a lookup?  Only a bare left
// press on exactly one glyph of the current model, in the foreground game
// window, with the host's native-input admission applied and no card
// shielding the game.
bool LucaPressEligible(LucaSubmit* submit) {
  auto& rt = g_luca_lookup;
  if (g_header == nullptr || g_stop ||
      !fushi_voice_hook::HasLookupRegion(g_header) ||
      fushi_voice_hook::AtomicLoadShared32(&g_header->lookup_enabled) == 0u) {
    return RejectLucaPress(1u);
  }
  LucaModel& model = rt.input_model;
  if (!ReadLucaModel(&model) || model.generation == 0u || model.count == 0u) {
    return RejectLucaPress(2u);
  }
  const HWND game = reinterpret_cast<HWND>(model.window);
  if (game == nullptr ||
      !fushi_voice_hook::g_geometry_provider_registry.NativeInputAllowed(
          g_header, fushi_voice_hook::kLookupGeometryProviderEngineExactLayout,
          fushi_voice_hook::kLookupGeometryProviderIdLuca) ||
      LucaShieldActive(game) || GetForegroundWindow() != game ||
      (GetKeyState(VK_SHIFT) & 0x8000) != 0 ||
      (GetKeyState(VK_CONTROL) & 0x8000) != 0 ||
      (GetKeyState(VK_MENU) & 0x8000) != 0) {
    return RejectLucaPress(3u);
  }
  uint32_t glyph = 0u;
  const uint32_t reject = HitLucaGlyphAtCursor(model, game, &glyph);
  if (reject != 0u) return RejectLucaPress(reject);
  submit->generation = model.generation;
  submit->glyph = glyph;
  return true;
}

// Called by the generic input shield's GetAsyncKeyState detour for every
// VK_LBUTTON sample, before the host-shield filter.  Only samples taken by
// the engine's own code (the return address lies in the main image) take
// part in the claim.  Returns true when the sample was masked.
bool FilterLucaLeftButtonSample(int16_t* state, uintptr_t return_address) {
  auto& rt = g_luca_lookup;
  if (state == nullptr || !rt.live.load(std::memory_order_acquire) ||
      return_address < g_luca.image_base ||
      return_address - g_luca.image_base >= g_luca.image_size) {
    return false;
  }
  const uint16_t raw = static_cast<uint16_t>(*state);
  LucaSubmit submit;
  bool eligible = false;
  __try {
    if (luca::IsFreshPress(raw, rt.claim)) {
      rt.presses.fetch_add(1u, std::memory_order_relaxed);
      eligible = LucaPressEligible(&submit);
      if (eligible) RejectLucaPress(0u);
    }
  } __except (EXCEPTION_EXECUTE_HANDLER) {
    eligible = false;
  }
  const luca::ClaimDecision decision =
      luca::DecideLeftButtonSample(raw, eligible, &rt.claim);
  if (decision.submit) QueueLucaSubmit(submit);
  if (!decision.mask) return false;
  *state = static_cast<int16_t>(
      raw & ~(luca::kAsyncDown | luca::kAsyncPressedSince));
  return true;
}

// ── HookWorker ─────────────────────────────────────────────────────────────

bool ReadLucaBytes(uintptr_t address, void* out, size_t bytes) {
  if (address == 0u || out == nullptr) return false;
  __try {
    std::memcpy(out, reinterpret_cast<const void*>(address), bytes);
  } __except (EXCEPTION_EXECUTE_HANDLER) {
    return false;
  }
  return true;
}

template <typename T>
bool ReadLucaValue(uintptr_t address, T* out) {
  return ReadLucaBytes(address, out, sizeof(T));
}

// The text box's visible rows, in ring order from its head.
bool ReadLucaTextRows(uintptr_t text, std::vector<luca::Row>* rows,
                      int32_t* origin_x, int32_t* origin_y) {
  int32_t capacity = 0, count = 0, head = 0;
  uintptr_t ring = 0u;
  if (!ReadLucaValue(text + luca_geometry64::kTextRowCapacity, &capacity) ||
      !ReadLucaValue(text + luca_geometry64::kTextRowCount, &count) ||
      !ReadLucaValue(text + luca_geometry64::kTextRowHead, &head) ||
      !ReadLucaValue(text + luca_geometry64::kTextRows, &ring) ||
      !ReadLucaValue(text + luca_geometry64::kTextOriginX, origin_x) ||
      !ReadLucaValue(text + luca_geometry64::kTextOriginY, origin_y) || ring == 0u ||
      capacity <= 0 || capacity > static_cast<int32_t>(luca::kMaxRows) ||
      count <= 0 || count > capacity || head < 0 || head >= capacity) {
    return false;
  }
  rows->resize(static_cast<size_t>(count));
  for (int32_t i = 0; i < count; ++i) {
    const uintptr_t row =
        ring + static_cast<uintptr_t>((head + i) % capacity) * luca_geometry64::kRowStride;
    uint16_t records = 0u;
    uintptr_t array = 0u;
    luca::Row& out = (*rows)[static_cast<size_t>(i)];
    int16_t row_x = 0;
    float row_y = 0.0f;
    int32_t delta_x = 0, delta_y = 0;
    if (!ReadLucaValue(row + luca_geometry64::kRowRecordCount, &records) ||
        !ReadLucaValue(row + luca_geometry64::kRowOffsetY, &out.offset_y) ||
        !ReadLucaValue(row + luca_geometry64::kRowRecords, &array) ||
        records > luca::kMaxRowRecords || (records != 0u && array == 0u) ||
        !ReadLucaValue(row + luca_geometry64::kRowOriginX, &row_x) ||
        !ReadLucaValue(row + luca_geometry64::kRowOriginY, &row_y) ||
        !luca_geometry64::NormalizeRowOrigin(row_x, row_y, out.offset_y,
                                           *origin_x, *origin_y, &delta_x,
                                           &delta_y)) {
      return false;
    }
    out.offset_y = delta_y;
    out.records.resize(records);
    uint8_t raw[luca_geometry64::kRecordStride] = {};
    for (uint16_t r = 0; r < records; ++r) {
      if (!ReadLucaBytes(array + uintptr_t{r} * luca_geometry64::kRecordStride, raw,
                         sizeof(raw))) {
        return false;
      }
      luca::GlyphRecord& g = out.records[r];
      std::memcpy(&g.unit, raw + luca_geometry64::kRecordUnit, sizeof(g.unit));
      std::memcpy(&g.x, raw + luca_geometry64::kRecordX, sizeof(g.x));
      std::memcpy(&g.w, raw + luca_geometry64::kRecordW, sizeof(g.w));
      std::memcpy(&g.h, raw + luca_geometry64::kRecordH, sizeof(g.h));
      const int32_t adjusted_x = static_cast<int32_t>(g.x) + delta_x;
      if (adjusted_x < INT16_MIN || adjusted_x > INT16_MAX) return false;
      g.x = static_cast<int16_t>(adjusted_x);
    }
  }
  return true;
}

struct LucaDpiScope {
  explicit LucaDpiScope(DPI_AWARENESS_CONTEXT context)
      : previous(SetThreadDpiAwarenessContext(context)) {}
  ~LucaDpiScope() {
    if (previous != nullptr) SetThreadDpiAwarenessContext(previous);
  }
  DPI_AWARENESS_CONTEXT previous;
};

// Gate ids for the bounded log (one line per change).
enum : uint32_t {
  kLucaGateOffered = 0,
  kLucaGateDisabled,
  kLucaGateNoLine,
  kLucaGateNoWindow,
  kLucaGateNoTextBox,
  kLucaGateAmbiguous,
  kLucaGateProjection,
  kLucaGateOfferRejected,
};

void RetireLucaLookup() {
  auto& rt = g_luca_lookup;
  rt.published_model.store(UINT32_MAX, std::memory_order_release);
  rt.model.generation = 0u;
  rt.model.count = 0u;
  rt.model_line.clear();
  if (!rt.provider_offered) return;
  rt.provider_offered = false;
  if (g_header != nullptr) {
    fushi_voice_hook::g_geometry_provider_registry.Retire(
        g_header, fushi_voice_hook::kLookupGeometryProviderEngineExactLayout,
        fushi_voice_hook::kLookupGeometryProviderIdLuca);
  }
}

void NoteLucaGate(uint32_t gate) {
  auto& rt = g_luca_lookup;
  if (gate == rt.last_gate) return;
  rt.last_gate = gate;
  static const wchar_t* const kNames[] = {
      L"offered",   L"lookup-disabled", L"no-selected-line", L"no-window",
      L"no-text-box", L"ambiguous-text-box", L"projection", L"offer-rejected"};
  LucaLog(L"luca-lookup: gate=%s", gate < 8u ? kNames[gate] : L"?");
}

// The one known text box whose glyphs spell `line`.  Two boxes spelling it is
// ambiguous and builds nothing.
bool BuildLucaModel(const std::wstring& line, uint64_t event, HWND game,
                    LucaModel* model, uint32_t* gate) {
  auto& rt = g_luca_lookup;
  uintptr_t chosen = 0u;
  std::vector<luca::LineGlyph> chosen_glyphs;
  for (auto& slot : rt.texts) {
    const uintptr_t text = slot.load(std::memory_order_acquire);
    if (text == 0u) continue;
    int32_t origin_x = 0, origin_y = 0;
    if (!ReadLucaTextRows(text, &rt.rows, &origin_x, &origin_y) ||
        !luca::MapRowsToLine(rt.rows.data(), rt.rows.size(), origin_x,
                             origin_y, line, &rt.mapped)) {
      continue;
    }
    if (chosen != 0u) {
      *gate = kLucaGateAmbiguous;
      return false;
    }
    chosen = text;
    chosen_glyphs = rt.mapped;
  }
  if (chosen == 0u || chosen_glyphs.size() > luca::kMaxGlyphs) {
    *gate = kLucaGateNoTextBox;
    return false;
  }
  RECT logical = {};
  RECT physical = {};
  {
    const DPI_AWARENESS_CONTEXT window_context =
        GetWindowDpiAwarenessContext(game);
    if (window_context == nullptr) {
      *gate = kLucaGateProjection;
      return false;
    }
    LucaDpiScope own(window_context);
    if (own.previous == nullptr || !GetClientRect(game, &logical)) {
      *gate = kLucaGateProjection;
      return false;
    }
  }
  {
    LucaDpiScope aware(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
    if (aware.previous == nullptr || !GetClientRect(game, &physical)) {
      *gate = kLucaGateProjection;
      return false;
    }
  }
  model->text_event = event;
  model->text_box = chosen;
  model->window = reinterpret_cast<uintptr_t>(game);
  model->design_w = g_luca.design_w;
  model->design_h = g_luca.design_h;
  model->logical_w = logical.right - logical.left;
  model->logical_h = logical.bottom - logical.top;
  model->physical_w = physical.right - physical.left;
  model->physical_h = physical.bottom - physical.top;
  luca::Projection projection;
  if (!luca::MakeProjection(model->design_w, model->design_h,
                            model->physical_w, model->physical_h,
                            &projection)) {
    *gate = kLucaGateProjection;
    return false;
  }
  model->count = static_cast<uint32_t>(chosen_glyphs.size());
  for (uint32_t i = 0; i < model->count; ++i) {
    model->glyphs[i].line = chosen_glyphs[i];
    model->glyphs[i].physical =
        luca::ProjectRect(chosen_glyphs[i].rect, projection);
  }
  return true;
}

bool SameLucaGeometry(const LucaModel& a, const LucaModel& b) {
  if (a.text_event != b.text_event || a.text_box != b.text_box ||
      a.window != b.window || a.logical_w != b.logical_w ||
      a.logical_h != b.logical_h || a.physical_w != b.physical_w ||
      a.physical_h != b.physical_h || a.count != b.count) {
    return false;
  }
  for (uint32_t i = 0; i < a.count; ++i) {
    const auto& l = a.glyphs[i];
    const auto& r = b.glyphs[i];
    if (l.line.source_index != r.line.source_index ||
        l.physical.x != r.physical.x || l.physical.y != r.physical.y ||
        l.physical.w != r.physical.w || l.physical.h != r.physical.h) {
      return false;
    }
  }
  return true;
}

void PublishLucaLookupHit(const LucaSubmit& submit) {
  auto& rt = g_luca_lookup;
  const LucaModel& model = rt.model;
  if (g_header == nullptr || submit.generation != model.generation ||
      submit.glyph >= model.count) {
    LucaLog(L"luca-lookup: hit dropped gen=%llu (model gen=%llu)",
            static_cast<unsigned long long>(submit.generation),
            static_cast<unsigned long long>(model.generation));
    return;
  }
  const std::wstring& line = rt.model_line;
  const LucaModelGlyph& glyph = model.glyphs[submit.glyph];
  const uint32_t units = static_cast<uint32_t>(line.size());
  const uint32_t source_length = fushi_voice_hook::LookupUtf16SourceLength(
      line.data(), units, glyph.line.source_index);
  const int required =
      WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, line.data(),
                          static_cast<int>(units), nullptr, 0, nullptr,
                          nullptr);
  char utf8[fushi_voice_hook::kLookupLineBytes] = {};
  if (source_length == 0u || required <= 0 ||
      static_cast<uint32_t>(required) > fushi_voice_hook::kLookupLineBytes ||
      WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, line.data(),
                          static_cast<int>(units), utf8, required, nullptr,
                          nullptr) != required) {
    LucaLog(L"luca-lookup: hit dropped (line encoding)");
    return;
  }
  fushi_voice_hook::LookupGeometryHitPublication publication;
  publication.provider_kind =
      fushi_voice_hook::kLookupGeometryProviderEngineExactLayout;
  publication.provider_id = fushi_voice_hook::kLookupGeometryProviderIdLuca;
  publication.char_index = glyph.line.source_index;
  publication.source_length = source_length;
  publication.char_count = units;
  publication.coordinate_space =
      fushi_voice_hook::kLookupCoordinateSpaceClientPhysicalPixels;
  publication.writing_mode = fushi_voice_hook::kLookupWritingModeHorizontal;
  publication.text_generation = model.text_event;
  publication.geometry_generation = model.generation;
  publication.glyph_x = glyph.physical.x;
  publication.glyph_y = glyph.physical.y;
  publication.glyph_w = glyph.physical.w;
  publication.glyph_h = glyph.physical.h;
  publication.view_w = model.physical_w;
  publication.view_h = model.physical_h;
  publication.flags = fushi_voice_hook::kLookupHitFlagSubmit;
  publication.line_utf8 = reinterpret_cast<const uint8_t*>(utf8);
  publication.line_bytes = static_cast<uint32_t>(required);
  const bool published =
      fushi_voice_hook::g_geometry_provider_registry.PublishHit(g_header,
                                                                publication);
  LucaLog(L"luca-lookup: hit gen=%llu glyph=%u char=%u+%u rect=%d,%d %dx%d "
          L"view=%dx%d published=%d",
          static_cast<unsigned long long>(model.generation), submit.glyph,
          glyph.line.source_index, source_length, glyph.physical.x,
          glyph.physical.y, glyph.physical.w, glyph.physical.h,
          model.physical_w, model.physical_h, published ? 1 : 0);
}

void DrainLucaSubmits() {
  auto& rt = g_luca_lookup;
  const uint64_t latest = rt.submit_count.load(std::memory_order_acquire);
  if (latest == 0u || latest == rt.processed_submit) return;
  rt.processed_submit = latest;
  auto& slot_seq = rt.submit_seq[latest % kLucaSubmitSlots];
  if (slot_seq.load(std::memory_order_acquire) != latest) return;
  std::atomic_thread_fence(std::memory_order_acquire);
  const LucaSubmit submit = rt.submits[latest % kLucaSubmitSlots];
  std::atomic_thread_fence(std::memory_order_acquire);
  if (slot_seq.load(std::memory_order_acquire) != latest) return;
  PublishLucaLookupHit(submit);
}

// Shift over a glyph looks it up, like the click but without touching the
// engine's input: Shift is sampled on every worker tick (so a press made while
// no line was offered is consumed, not replayed later), never masked, and a
// press is published only when the game is foreground under the cursor and no
// card shields it (a Shift inside a card belongs to the card).
void ProcessLucaShiftLookup(HWND game) {
  auto& rt = g_luca_lookup;
  if (rt.model.generation == 0u || rt.model.count == 0u ||
      GetForegroundWindow() != game || LucaShieldActive(game) ||
      (GetKeyState(VK_CONTROL) & 0x8000) != 0 ||
      (GetKeyState(VK_MENU) & 0x8000) != 0) {
    LucaLog(L"luca-lookup: shift refused (gate)");
    return;
  }
  uint32_t glyph = 0u;
  const uint32_t reject = HitLucaGlyphAtCursor(rt.model, game, &glyph);
  if (reject != 0u) {
    LucaLog(L"luca-lookup: shift refused reject=%u", reject);
    return;
  }
  LucaSubmit submit;
  submit.generation = rt.model.generation;
  submit.glyph = glyph;
  PublishLucaLookupHit(submit);
}

void ProcessLucaLookupTick() {
  auto& rt = g_luca_lookup;
  if (!rt.installed) return;
  if (g_stop || g_header == nullptr ||
      !fushi_voice_hook::HasLookupRegion(g_header) ||
      fushi_voice_hook::AtomicLoadShared32(&g_header->lookup_enabled) == 0u) {
    NoteLucaGate(kLucaGateDisabled);
    luca::ResetShiftState(&rt.shift);
    RetireLucaLookup();
    return;
  }
  fushi_voice_hook::AtomicOrShared32(
      &g_header->lookup_diag, fushi_voice_hook::kLookupDiagSensorInstalled);
  const bool shift_press = luca::ConsumeShiftSample(
      static_cast<uint16_t>(GetAsyncKeyState(VK_SHIFT)), &rt.shift);
  {
    static uint32_t logged_presses = 0u;
    const uint32_t presses = rt.presses.load(std::memory_order_relaxed);
    if (presses != logged_presses) {
      logged_presses = presses;
      LucaLog(L"luca-lookup: fresh press %u reject=%u", presses,
              rt.press_reject.load(std::memory_order_relaxed));
    }
  }
  DrainLucaSubmits();
  const HWND game = fushi_voice_hook::FindGameMainWindow();
  if (game == nullptr) {
    NoteLucaGate(kLucaGateNoWindow);
    RetireLucaLookup();
    return;
  }
  std::wstring line;
  uint64_t event = 0u;
  uint64_t thread = 0u;
  if (!fushi_voice_hook::ReadSelectedLookupText(g_header, &line, &event,
                                                &thread, luca::kMaxGlyphs)) {
    NoteLucaGate(kLucaGateNoLine);
    RetireLucaLookup();
    return;
  }
  uint32_t gate = kLucaGateOffered;
  LucaModel& built = rt.candidate;
  if (!BuildLucaModel(line, event, game, &built, &gate)) {
    NoteLucaGate(gate);
    RetireLucaLookup();
    return;
  }
  if (rt.model.generation == 0u || rt.model_line != line ||
      !SameLucaGeometry(rt.model, built)) {
    built.generation = ++rt.next_generation;
    rt.model = built;
    rt.model_line = line;
    PublishLucaModel(rt.model);
    const auto& first = rt.model.glyphs[0];
    LucaLog(L"luca-lookup: model gen=%llu event=%llu glyphs=%u first=%d,%d "
            L"%dx%d (design %d,%d) view=%dx%d client=%dx%d design=%dx%d",
            static_cast<unsigned long long>(rt.model.generation),
            static_cast<unsigned long long>(event), rt.model.count,
            first.physical.x, first.physical.y, first.physical.w,
            first.physical.h, first.line.rect.x, first.line.rect.y,
            rt.model.physical_w, rt.model.physical_h, rt.model.logical_w,
            rt.model.logical_h, rt.model.design_w, rt.model.design_h);
  }
  if (fushi_voice_hook::g_geometry_provider_registry.OfferReady(
          g_header, fushi_voice_hook::kLookupGeometryProviderEngineExactLayout,
          fushi_voice_hook::kLookupGeometryProviderIdLuca)) {
    rt.provider_offered = true;
    fushi_voice_hook::AtomicOrShared32(
        &g_header->lookup_diag, fushi_voice_hook::kLookupDiagGeometryObserved);
    NoteLucaGate(kLucaGateOffered);
  } else {
    NoteLucaGate(kLucaGateOfferRejected);
    RetireLucaLookup();
    return;
  }
  if (shift_press) ProcessLucaShiftLookup(game);
}

// Resolved together with the text sites, from the same hydrated image.
bool InstallLucaLookup(const luca::CodeSpan* spans, size_t span_count) {
  auto& rt = g_luca_lookup;
  if (rt.installed) {
    rt.live.store(true, std::memory_order_release);
    return true;
  }
  if (rt.resolved) return false;
  rt.resolved = true;
  luca_geometry64::LayoutSites sites;
  rt.site_result = luca_geometry64::ResolveLayoutSite(spans, span_count, &sites);
  rt.layout_rva = sites.layout;
  if (rt.site_result != luca::LayoutSiteResult::kResolved) {
    LucaLog(L"luca-lookup: layout site result=%u",
            static_cast<unsigned>(rt.site_result));
    return false;
  }
  // The draw routine itself consumes these adjacent engine globals. Win64
  // builds need not ship the x86 system.cnf boot configuration.
  if (g_luca.image_size < sizeof(int32_t) ||
      sites.design_width > g_luca.image_size - sizeof(int32_t) ||
      sites.design_height > g_luca.image_size - sizeof(int32_t) ||
      !ReadLucaValue(g_luca.image_base + sites.design_width, &g_luca.design_w) ||
      !ReadLucaValue(g_luca.image_base + sites.design_height, &g_luca.design_h) ||
      g_luca.design_w <= 0 || g_luca.design_w > luca::kMaxDesignSide ||
      g_luca.design_h <= 0 || g_luca.design_h > luca::kMaxDesignSide) {
    LucaLog(L"luca-lookup: engine design size rejected");
    return false;
  }
  rt.live.store(true, std::memory_order_release);
  const bool hooked =
      HookFn(reinterpret_cast<void*>(g_luca.image_base + rt.layout_rva),
             reinterpret_cast<void*>(&LucaLayoutDetour),
             reinterpret_cast<void**>(&g_luca_layout_original));
  rt.installed = hooked;
  if (!hooked) rt.live.store(false, std::memory_order_release);
  LucaLog(L"luca-lookup: layout=+0x%lx design=%dx%d hooks=%d",
          static_cast<unsigned long>(rt.layout_rva), g_luca.design_w,
          g_luca.design_h, hooked ? 1 : 0);
  if (rt.installed && g_header != nullptr) {
    fushi_voice_hook::AtomicOrShared32(
        &g_header->lookup_diag, fushi_voice_hook::kLookupDiagSensorInstalled);
  }
  return rt.installed;
}

void ShutdownLucaLookup() {
  auto& rt = g_luca_lookup;
  rt.live.store(false, std::memory_order_release);
  rt.claim = luca::ClaimState();
  RetireLucaLookup();
}

bool LucaLookupSensorInstalled() { return g_luca_lookup.installed; }
bool LucaLookupSitesRejected() {
  return g_luca_lookup.resolved && !g_luca_lookup.installed;
}

#endif  // _M_X64
