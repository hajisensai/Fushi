// Malie message segment text lane + in-game lookup runtime
// (EngineExactLayout / kLookupGeometryProviderIdMalie).  Engine facts,
// signatures and decision rules live in malie_lookup_core.h and are
// unit-tested; this file binds them to MinHook, Win32, the text lanes and the
// v19 registry.
//
// Threads:
//   * game thread — segment parser detour: bounded copy of the parsed click
//     unit (raw formatted text) and its glyph count; reveal setter detour on
//     the same thread pairs it with the text node and its glyph range and
//     queues one fixed-size event.  No allocation, no IO.
//   * render thread — RICHTEXT3D draw detour: for the watched node only, a
//     bounded copy of its glyph boxes, translation and parent matrix into a
//     two-slot seqlock when anything changed, plus the last draw tick.
//   * message thread — window procedure detour: a bare WM_LBUTTONDOWN /
//     DBLCLK on a glyph of the current model is swallowed with its
//     WM_LBUTTONUP, so the engine's input dispatcher never sees the click
//     (touch: see DecideMessage in malie_lookup_core.h).
//   * HookWorker — cleans the unit (voice tag, ruby, codes), publishes the
//     text lane, keeps the voice-key -> text-event binding, builds the model
//     against the selected line, offers / retires the provider and turns
//     claimed presses into registry hits.
//
// Fail closed: unresolved sites install nothing; an undrawn node, a
// non-axis-aligned transform, a client without the design aspect, a selected
// line that is not the current unit or a unit whose characters are not all
// glyphs of the node retire the provider, and the click reaches the game.
#if defined(_M_IX86)

typedef int(__cdecl* MalieDrawFn)(void* node, const float* parent);
typedef int32_t(__cdecl* MalieParserFn)(const wchar_t* text, int32_t start,
                                        int32_t* glyphs);
typedef void(__cdecl* MalieRevealFn)(void* node, int32_t start, int32_t end);

constexpr uint32_t kMalieSegmentSlots = 16u;
constexpr uint32_t kMalieSubmitSlots = 8u;
constexpr uint32_t kMalieLogBudget = 4096u;
// The engine draws only while something changes, and slowly while it is not
// foreground (a lookup card is up), so "drawn recently" is not a time: the
// node is stale once the engine drew this many other nodes without it (a few
// dozen frames; one frame draws a handful of nodes).
constexpr uint64_t kMalieDrawStaleCalls = 256u;
constexpr uint64_t kMalieVoiceBindMs = 15000u;
constexpr uint64_t kMalieWindowRetryMs = 500u;
constexpr size_t kMalieVoiceBindings = 16u;

struct MalieSegmentEvent {
  uint64_t tick = 0u;
  uintptr_t node = 0u;
  int32_t start = 0;
  int32_t end = 0;
  uint32_t units = 0u;
  wchar_t raw[malie_lookup::kMaxSegmentUnits] = {};
};

struct MalieGlyphSnapshot {
  uint64_t tick = 0u;  // draw tick of this content
  uintptr_t node = 0u;
  uintptr_t data = 0u;
  int32_t count = 0;
  int32_t reveal_start = 0;
  int32_t reveal_end = 0;
  float translate[3] = {};
  float parent[16] = {};
  uint16_t codes[malie_lookup::kMaxGlyphs] = {};
  int32_t boxes[malie_lookup::kMaxGlyphs][4] = {};
};

struct MalieModel {
  uint64_t generation = 0u;
  uint64_t segment = 0u;
  uintptr_t window = 0u;
  uintptr_t node = 0u;
  int32_t client_w = 0;  // logical client of the window procedure
  int32_t client_h = 0;
  int32_t physical_w = 0;
  int32_t physical_h = 0;
  uint32_t count = 0u;  // line units
  std::array<malie_lookup::PixelRect, malie_lookup::kMaxSegmentUnits> logical{};
  std::array<malie_lookup::PixelRect, malie_lookup::kMaxSegmentUnits> physical{};
};

struct MalieSubmit {
  uint64_t generation = 0u;
  uint32_t unit = 0u;
  malie_lookup::PixelRect rect;  // physical
  int32_t physical_w = 0;
  int32_t physical_h = 0;
};

struct MalieVoiceBinding {
  std::wstring key;
  uint64_t text_event = 0u;
  uint64_t tick = 0u;
};

struct MalieCurrentSegment {
  bool valid = false;
  uint64_t id = 0u;
  uint64_t tick = 0u;
  uint64_t text_event = 0u;
  uintptr_t node = 0u;
  int32_t start = 0;
  int32_t end = 0;
  std::wstring line;
};

struct MalieLookupRuntime {
  // ── HookWorker-owned ──
  bool resolved = false;
  bool installed = false;
  bool provider_offered = false;
  malie_lookup::WindowBindingState window_state;
  uint64_t window_retry_tick = 0u;
  uint64_t processed_segments = 0u;
  uint64_t processed_submit = 0u;
  uint64_t next_generation = 0u;
  uint64_t next_segment = 0u;
  uint32_t logged = 0u;
  uint64_t logged_claims = 0u;
  uint64_t logged_snapshot_segment = 0u;
  int32_t design_w = 0;
  int32_t design_h = 0;
  MalieSegmentEvent event_copy;
  MalieGlyphSnapshot snapshot_copy;
  MalieCurrentSegment current;
  MalieModel model;
  MalieModel candidate;
  std::wstring model_line;
  uint64_t model_text_event = 0u;
  std::array<MalieVoiceBinding, kMalieVoiceBindings> bindings{};
  size_t next_binding = 0u;
  std::wstring last_text;
  uint64_t last_text_tick = 0u;
  uint64_t last_text_event = 0u;

  // ── resolved once ──
  malie_lookup::DrawSites draw;
  malie_lookup::SegmentSites segment;
  uintptr_t design_w_global = 0u;
  uintptr_t design_h_global = 0u;
  uintptr_t image_base = 0u;
  HWND window = nullptr;

  // ── game-thread pending unit (one producer thread: the script thread) ──
  DWORD pending_thread = 0u;
  int32_t pending_glyphs = -1;
  uint32_t pending_units = 0u;
  wchar_t pending_raw[malie_lookup::kMaxSegmentUnits] = {};

  // ── message-thread-owned ──
  malie_lookup::ClaimState claim;
  MalieModel input_model;

  // ── shared ──
  std::atomic<bool> live{false};
  std::atomic<uintptr_t> watched_node{0u};
  std::atomic<uint64_t> draw_calls{0u};
  std::atomic<uint64_t> segment_count{0u};
  std::array<std::atomic<uint64_t>, kMalieSegmentSlots> segment_seq = {};
  std::array<MalieSegmentEvent, kMalieSegmentSlots> segments = {};
  std::array<std::atomic<uint32_t>, 2> snapshot_seq = {};
  std::array<MalieGlyphSnapshot, 2> snapshots = {};
  std::atomic<uint32_t> published_snapshot{UINT32_MAX};
  std::atomic<uint64_t> watched_draw_calls{0u};  // draw_calls at its last draw
  std::array<std::atomic<uint32_t>, 2> model_seq = {};
  std::array<MalieModel, 2> models = {};
  std::atomic<uint32_t> published_model{UINT32_MAX};
  std::array<std::atomic<uint64_t>, kMalieSubmitSlots> submit_seq = {};
  std::array<MalieSubmit, kMalieSubmitSlots> submits = {};
  std::atomic<uint64_t> submit_count{0u};
  std::atomic<uint64_t> claimed_presses{0u};
  // Why the last left press was not claimed (message thread writes, worker
  // logs): 1 lookup off, 2 no model, 3 window, 4 newer unit, 5 stale draw,
  // 6 native input not admitted, 7 shield, 8 not foreground, 9 modifiers,
  // 10 client size, 11 no glyph.
  std::atomic<uint32_t> refused_reason{0u};
  std::atomic<uint64_t> refused_presses{0u};
  uint64_t logged_refusals = 0u;  // worker
};

MalieLookupRuntime g_malie_lookup;
MalieDrawFn g_malie_draw_original = nullptr;
MalieParserFn g_malie_parser_original = nullptr;
MalieRevealFn g_malie_reveal_original = nullptr;
// One detour slot per distinct click-window procedure (a recreated or
// replaced click window may come with another procedure of the image).
std::array<WNDPROC, malie_lookup::kMaxWindowProcedures>
    g_malie_wndproc_original{};

void MalieLookupLog(const wchar_t* format, ...) {
  auto& rt = g_malie_lookup;
  if (rt.logged >= kMalieLogBudget) return;
  ++rt.logged;
  wchar_t line[512] = {};
  va_list args;
  va_start(args, format);
  _vsnwprintf_s(line, _TRUNCATE, format, args);
  va_end(args);
  MalieLog(L"%s", line);
}

bool ReadMalieInt(uintptr_t address, int32_t* out) {
  __try {
    *out = *reinterpret_cast<const int32_t*>(address);
    return true;
  } __except (EXCEPTION_EXECUTE_HANDLER) {
    return false;
  }
}

// ── seqlocks ───────────────────────────────────────────────────────────────

template <typename T, size_t N>
void PublishSeq(std::array<std::atomic<uint32_t>, N>& seqs,
                std::array<T, N>& slots, std::atomic<uint32_t>& published,
                const T& value) {
  const uint32_t current = published.load(std::memory_order_acquire);
  const uint32_t slot =
      current >= N ? 0u : static_cast<uint32_t>((current + 1u) % N);
  const uint32_t seq = seqs[slot].load(std::memory_order_relaxed);
  seqs[slot].store(seq | 1u, std::memory_order_release);
  std::atomic_thread_fence(std::memory_order_release);
  std::memcpy(&slots[slot], &value, sizeof(T));
  std::atomic_thread_fence(std::memory_order_release);
  seqs[slot].store((seq | 1u) + 1u, std::memory_order_release);
  published.store(slot, std::memory_order_release);
}

template <typename T, size_t N>
bool ReadSeq(std::array<std::atomic<uint32_t>, N>& seqs,
             std::array<T, N>& slots, std::atomic<uint32_t>& published,
             T* out) {
  const uint32_t slot = published.load(std::memory_order_acquire);
  if (slot >= N) return false;
  const uint32_t before = seqs[slot].load(std::memory_order_acquire);
  if (before == 0u || (before & 1u) != 0u) return false;
  std::atomic_thread_fence(std::memory_order_acquire);
  std::memcpy(out, &slots[slot], sizeof(T));
  std::atomic_thread_fence(std::memory_order_acquire);
  return seqs[slot].load(std::memory_order_acquire) == before &&
         published.load(std::memory_order_acquire) == slot;
}

// ── game thread: segment parser + reveal setter ────────────────────────────

int32_t __cdecl MalieParserDetour(const wchar_t* text, int32_t start,
                                  int32_t* glyphs) {
  const int32_t end = g_malie_parser_original(text, start, glyphs);
  auto& rt = g_malie_lookup;
  if (!rt.live.load(std::memory_order_acquire) || text == nullptr ||
      glyphs == nullptr || end <= start) {
    return end;
  }
  __try {
    const uint32_t units = static_cast<uint32_t>((std::min)(
        static_cast<int64_t>(end) - start,
        static_cast<int64_t>(malie_lookup::kMaxSegmentUnits)));
    memcpy(rt.pending_raw, text + start, units * sizeof(wchar_t));
    rt.pending_units = units;
    rt.pending_glyphs = *glyphs;
    rt.pending_thread = GetCurrentThreadId();
  } __except (EXCEPTION_EXECUTE_HANDLER) {
    rt.pending_glyphs = -1;
  }
  return end;
}

void __cdecl MalieRevealDetour(void* node, int32_t start, int32_t end) {
  g_malie_reveal_original(node, start, end);
  auto& rt = g_malie_lookup;
  if (!rt.live.load(std::memory_order_acquire) || node == nullptr ||
      rt.pending_glyphs < 0 || rt.pending_thread != GetCurrentThreadId()) {
    return;
  }
  const bool matches = end - start == rt.pending_glyphs;
  rt.pending_glyphs = -1;
  if (!matches) return;
  const uint64_t sequence =
      rt.segment_count.fetch_add(1u, std::memory_order_acq_rel) + 1u;
  auto& slot_seq = rt.segment_seq[sequence % kMalieSegmentSlots];
  slot_seq.store(0u, std::memory_order_release);
  std::atomic_thread_fence(std::memory_order_release);
  MalieSegmentEvent& event = rt.segments[sequence % kMalieSegmentSlots];
  event.tick = GetTickCount64();
  event.node = reinterpret_cast<uintptr_t>(node);
  event.start = start;
  event.end = end;
  event.units = rt.pending_units;
  memcpy(event.raw, rt.pending_raw, rt.pending_units * sizeof(wchar_t));
  std::atomic_thread_fence(std::memory_order_release);
  slot_seq.store(sequence, std::memory_order_release);
}

// ── render thread: RICHTEXT3D draw ─────────────────────────────────────────

MalieGlyphSnapshot g_malie_draw_scratch;  // render-thread only

bool ReadMalieGlyphs(uintptr_t node, const float* parent,
                     MalieGlyphSnapshot* out) {
  const auto& s = g_malie_lookup.draw;
  __try {
    const uintptr_t data =
        *reinterpret_cast<const uintptr_t*>(node + s.data_field);
    if (data == 0u) return false;
    const int32_t count = *reinterpret_cast<const int32_t*>(data + s.count);
    if (count < 0 || count > static_cast<int32_t>(malie_lookup::kMaxGlyphs)) {
      return false;
    }
    out->node = node;
    out->data = data;
    out->count = count;
    out->reveal_start = *reinterpret_cast<const int32_t*>(data + s.reveal_start);
    out->reveal_end = *reinterpret_cast<const int32_t*>(data + s.reveal_end);
    memcpy(out->translate, reinterpret_cast<const void*>(data + s.translate),
           sizeof(out->translate));
    memcpy(out->parent, parent, sizeof(out->parent));
    const uintptr_t glyphs =
        *reinterpret_cast<const uintptr_t*>(data + s.glyphs);
    if (count > 0 && glyphs == 0u) return false;
    for (int32_t i = 0; i < count; ++i) {
      const uintptr_t record = glyphs + static_cast<uintptr_t>(i) * s.stride;
      out->codes[i] = *reinterpret_cast<const uint16_t*>(record);
      memcpy(out->boxes[i], reinterpret_cast<const void*>(record + 4), 16);
    }
    return true;
  } __except (EXCEPTION_EXECUTE_HANDLER) {
    return false;
  }
}

bool SameMalieGlyphs(const MalieGlyphSnapshot& a, const MalieGlyphSnapshot& b) {
  return a.node == b.node && a.data == b.data && a.count == b.count &&
         a.reveal_start == b.reveal_start && a.reveal_end == b.reveal_end &&
         memcmp(a.translate, b.translate, sizeof(a.translate)) == 0 &&
         memcmp(a.parent, b.parent, sizeof(a.parent)) == 0 &&
         memcmp(a.codes, b.codes, a.count * sizeof(uint16_t)) == 0 &&
         memcmp(a.boxes, b.boxes, a.count * sizeof(a.boxes[0])) == 0;
}

MalieGlyphSnapshot g_malie_draw_last;  // render-thread only

int __cdecl MalieDrawDetour(void* node, const float* parent) {
  auto& rt = g_malie_lookup;
  rt.draw_calls.fetch_add(1u, std::memory_order_relaxed);
  const uintptr_t watched = rt.watched_node.load(std::memory_order_acquire);
  if (rt.live.load(std::memory_order_acquire) && node != nullptr &&
      parent != nullptr && reinterpret_cast<uintptr_t>(node) == watched) {
    const uint64_t now = GetTickCount64();
    rt.watched_draw_calls.store(rt.draw_calls.load(std::memory_order_relaxed),
                                std::memory_order_release);
    if (ReadMalieGlyphs(watched, parent, &g_malie_draw_scratch) &&
        !SameMalieGlyphs(g_malie_draw_scratch, g_malie_draw_last)) {
      g_malie_draw_scratch.tick = now;
      g_malie_draw_last = g_malie_draw_scratch;
      PublishSeq(rt.snapshot_seq, rt.snapshots, rt.published_snapshot,
                 g_malie_draw_scratch);
    }
  }
  return g_malie_draw_original(node, parent);
}

bool MalieWatchedNodeStale() {
  auto& rt = g_malie_lookup;
  return rt.draw_calls.load(std::memory_order_acquire) -
             rt.watched_draw_calls.load(std::memory_order_acquire) >
         kMalieDrawStaleCalls;
}

// ── message thread: window procedure ───────────────────────────────────────

void QueueMalieSubmit(const MalieSubmit& submit) {
  auto& rt = g_malie_lookup;
  const uint64_t sequence =
      rt.submit_count.load(std::memory_order_acquire) + 1u;
  auto& slot_seq = rt.submit_seq[sequence % kMalieSubmitSlots];
  slot_seq.store(0u, std::memory_order_release);
  std::atomic_thread_fence(std::memory_order_release);
  rt.submits[sequence % kMalieSubmitSlots] = submit;
  std::atomic_thread_fence(std::memory_order_release);
  slot_seq.store(sequence, std::memory_order_release);
  rt.submit_count.store(sequence, std::memory_order_release);
}

bool MalieShieldActive(HWND game) {
  if (IsLookupOverlayInputShieldVisible()) return true;
  if (g_header == nullptr) return false;
  const auto request = fushi_voice_hook::ReadLookupShieldRequest(g_header);
  return request.valid && request.active_buttons != 0u &&
         request.target_hwnd ==
             static_cast<uint64_t>(reinterpret_cast<uintptr_t>(game));
}

bool RefuseMaliePress(uint32_t reason) {
  auto& rt = g_malie_lookup;
  rt.refused_reason.store(reason, std::memory_order_release);
  rt.refused_presses.fetch_add(1u, std::memory_order_acq_rel);
  return false;
}

bool MaliePressEligible(HWND hwnd, WPARAM wparam, LPARAM lparam,
                        MalieSubmit* submit) {
  auto& rt = g_malie_lookup;
  if (!rt.live.load(std::memory_order_acquire) || g_header == nullptr ||
      g_stop || !fushi_voice_hook::HasLookupRegion(g_header) ||
      fushi_voice_hook::AtomicLoadShared32(&g_header->lookup_enabled) == 0u) {
    return RefuseMaliePress(1u);
  }
  MalieModel& model = rt.input_model;
  if (!ReadSeq(rt.model_seq, rt.models, rt.published_model, &model) ||
      model.generation == 0u || model.count == 0u) {
    return RefuseMaliePress(2u);
  }
  if (reinterpret_cast<uintptr_t>(hwnd) != model.window) {
    return RefuseMaliePress(3u);
  }
  // A unit parsed after the model was built: the page may have moved on.
  if (rt.segment_count.load(std::memory_order_acquire) != model.segment) {
    return RefuseMaliePress(4u);
  }
  if (MalieWatchedNodeStale()) return RefuseMaliePress(5u);
  if (!fushi_voice_hook::g_geometry_provider_registry.NativeInputAllowed(
          g_header, fushi_voice_hook::kLookupGeometryProviderEngineExactLayout,
          fushi_voice_hook::kLookupGeometryProviderIdMalie)) {
    return RefuseMaliePress(6u);
  }
  if (MalieShieldActive(hwnd)) return RefuseMaliePress(7u);
  if (GetForegroundWindow() != GetAncestor(hwnd, GA_ROOT)) {
    return RefuseMaliePress(8u);
  }
  if ((wparam & (MK_SHIFT | MK_CONTROL | MK_RBUTTON | MK_MBUTTON)) != 0u ||
      (GetKeyState(VK_MENU) & 0x8000) != 0) {
    return RefuseMaliePress(9u);
  }
  RECT client = {};
  if (!GetClientRect(hwnd, &client) ||
      client.right - client.left != model.client_w ||
      client.bottom - client.top != model.client_h) {
    return RefuseMaliePress(10u);
  }
  const int hit = malie_lookup::HitTest(
      model.logical.data(), model.count,
      static_cast<int16_t>(LOWORD(lparam)), static_cast<int16_t>(HIWORD(lparam)));
  if (hit < 0) return RefuseMaliePress(11u);
  submit->generation = model.generation;
  submit->unit = static_cast<uint32_t>(hit);
  submit->rect = model.physical[static_cast<size_t>(hit)];
  submit->physical_w = model.physical_w;
  submit->physical_h = model.physical_h;
  return true;
}

template <uint32_t Slot>
LRESULT CALLBACK MalieWndProcDetour(HWND hwnd, UINT message, WPARAM wparam,
                                    LPARAM lparam) {
  auto& rt = g_malie_lookup;
  if (rt.live.load(std::memory_order_acquire) &&
      (malie_lookup::NeedsEligibility(message) || message == WM_LBUTTONUP)) {
    bool eligible = false;
    MalieSubmit submit;
    if (malie_lookup::NeedsEligibility(message)) {
      __try {
        eligible = MaliePressEligible(hwnd, wparam, lparam, &submit);
      } __except (EXCEPTION_EXECUTE_HANDLER) {
        eligible = false;
      }
    }
    const auto decision = malie_lookup::DecideMessage(message, eligible, &rt.claim);
    if (decision.submit) {
      QueueMalieSubmit(submit);
      rt.claimed_presses.fetch_add(1u, std::memory_order_relaxed);
    }
    if (decision.swallow) return 0;
  }
  return g_malie_wndproc_original[Slot](hwnd, message, wparam, lparam);
}

constexpr std::array<WNDPROC, malie_lookup::kMaxWindowProcedures>
    kMalieWndProcDetours = {&MalieWndProcDetour<0u>, &MalieWndProcDetour<1u>,
                            &MalieWndProcDetour<2u>, &MalieWndProcDetour<3u>};

// ── HookWorker ─────────────────────────────────────────────────────────────

// "ScreenWidth"/"ScreenHeight": the profile read whose result the engine
// stores into its design-size global (`push lit ... call ... mov [G],eax`).
uintptr_t ResolveMalieDesignGlobal(
    const ::fushi_voice_hook::exact_lookup::LoadedPeImage& image,
    const wchar_t* key) {
  namespace mio = ::fushi_voice_hook::malie_io;
  const auto literals = mio::FindWideLiteral(image, key);
  uintptr_t found = 0u;
  for (size_t literal : literals) {
    const uint32_t absolute =
        static_cast<uint32_t>(mio::AbsoluteBase(image) + literal);
    for (size_t s = 0u; s < image.section_count; ++s) {
      const auto& section = image.sections[s];
      if ((section.characteristics & IMAGE_SCN_MEM_EXECUTE) == 0u) continue;
      for (size_t at = 0u; at + 5u <= section.size; ++at) {
        if (section.bytes[at] != 0x68u ||
            mio::Load32(section.bytes + at + 1u) != absolute) {
          continue;
        }
        // push lit; push section; call; [push ...;] mov [G],eax (a3 G32):
        // the first store after the read's own call.
        size_t call = 0u;
        for (size_t k = at + 5u; k + 5u <= section.size && k <= at + 0x10u;
             ++k) {
          if (section.bytes[k] == 0xe8u) {
            call = k;
            break;
          }
        }
        if (call == 0u) continue;
        for (size_t k = call + 5u; k + 5u <= section.size && k <= call + 0x20u;
             ++k) {
          if (section.bytes[k] != 0xa3u) continue;
          size_t rva = 0u;
          if (!mio::AbsoluteToRva(image, mio::Load32(section.bytes + k + 1u),
                                  &rva)) {
            break;
          }
          const auto* data = mio::SectionAt(image, rva, 4u);
          if (data == nullptr ||
              (data->characteristics & IMAGE_SCN_MEM_WRITE) == 0u) {
            break;
          }
          const uintptr_t global = reinterpret_cast<uintptr_t>(image.base) + rva;
          if (found != 0u && found != global) return 0u;  // ambiguous
          found = global;
          break;
        }
      }
    }
  }
  return found;
}

bool InstallMalieLookup() {
  auto& rt = g_malie_lookup;
  if (rt.installed) {
    rt.claim = malie_lookup::ClaimState();
    rt.live.store(true, std::memory_order_release);
    return true;
  }
  if (rt.resolved) return false;
  // Not resolved until the identity matched: an image that was not ready
  // (still unpacking) is measured again later and may match then.
  if (!fushi_voice_hook::MatchesMalieProfile(nullptr)) return false;
  rt.resolved = true;
  ::fushi_voice_hook::exact_lookup::LoadedPeImage image;
  const HMODULE module = GetModuleHandleW(nullptr);
  if (!::fushi_voice_hook::exact_lookup::OpenLoadedPeImage(module, &image)) {
    return false;
  }
  const auto draw = malie_lookup::ResolveDraw(image, &rt.draw);
  const auto segment = draw == malie_lookup::DrawResult::kResolved
                           ? malie_lookup::ResolveSegment(image, rt.draw,
                                                          &rt.segment)
                           : malie_lookup::SegmentResult::kNoReveal;
  rt.design_w_global = ResolveMalieDesignGlobal(image, L"ScreenWidth");
  rt.design_h_global = ResolveMalieDesignGlobal(image, L"ScreenHeight");
  rt.image_base = reinterpret_cast<uintptr_t>(image.base);
  if (draw != malie_lookup::DrawResult::kResolved ||
      segment != malie_lookup::SegmentResult::kResolved) {
    MalieLookupLog(L"lookup: sites unresolved draw=%lu segment=%lu",
                   static_cast<unsigned long>(draw),
                   static_cast<unsigned long>(segment));
    return false;
  }
  rt.claim = malie_lookup::ClaimState();
  rt.live.store(true, std::memory_order_release);
  const bool hooked =
      InstallMalieHook(reinterpret_cast<void*>(rt.segment.parser),
                       reinterpret_cast<void*>(&MalieParserDetour),
                       reinterpret_cast<void**>(&g_malie_parser_original)) &&
      InstallMalieHook(reinterpret_cast<void*>(rt.segment.reveal),
                       reinterpret_cast<void*>(&MalieRevealDetour),
                       reinterpret_cast<void**>(&g_malie_reveal_original)) &&
      InstallMalieHook(reinterpret_cast<void*>(rt.draw.draw),
                       reinterpret_cast<void*>(&MalieDrawDetour),
                       reinterpret_cast<void**>(&g_malie_draw_original));
  rt.installed = hooked;
  if (!hooked) rt.live.store(false, std::memory_order_release);
  const auto& s = rt.draw;
  MalieLookupLog(
      L"lookup: draw=+0x%lx parser=+0x%lx reveal=+0x%lx data=0x%x "
      L"glyphs=0x%x count=0x%x stride=0x%x reveal=0x%x translate=0x%x "
      L"design=+0x%lx,+0x%lx hooks=%d",
      static_cast<unsigned long>(s.draw - rt.image_base),
      static_cast<unsigned long>(rt.segment.parser - rt.image_base),
      static_cast<unsigned long>(rt.segment.reveal - rt.image_base),
      s.data_field, s.glyphs, s.count, s.stride, s.reveal_start, s.translate,
      static_cast<unsigned long>(rt.design_w_global ? rt.design_w_global - rt.image_base : 0u),
      static_cast<unsigned long>(rt.design_h_global ? rt.design_h_global - rt.image_base : 0u),
      hooked ? 1 : 0);
  if (rt.installed && g_header != nullptr) {
    fushi_voice_hook::AtomicOrShared32(
        &g_header->lookup_diag, fushi_voice_hook::kLookupDiagSensorInstalled);
  }
  return rt.installed;
}

uint64_t PublishMalieTextLine(const std::wstring& text, uintptr_t node,
                              uint64_t tick) {
  auto& rt = g_malie_lookup;
  if (!g_capture_enabled || g_header == nullptr || g_text_base == nullptr ||
      !g_text_cs_ready || text.empty() ||
      text.size() * sizeof(wchar_t) > fushi_voice_hook::kTextSlotBytes) {
    return 0u;
  }
  constexpr wchar_t kHookCode[] = L"ENGINE:MALIE:message_segment";
  constexpr char kHookName[] = "Malie exact";
  const uint64_t thread_id = fushi_voice_hook::NativeTextThreadIdFrom(
      rt.draw.draw - rt.image_base, kHookCode, kHookName);
  if (text == rt.last_text && tick - rt.last_text_tick <= 500u) {
    return rt.last_text_event;
  }
  fushi_voice_hook::TextLaneWrite write;
  write.thread_id = thread_id;
  write.thread_address = node;
  write.thread_context = node;
  write.process_id = GetCurrentProcessId();
  write.source_kind = fushi_voice_hook::kTextSourceMalie;
  write.is_utf8 = 0;
  write.text = text.data();
  write.byte_len = static_cast<uint32_t>(text.size() * sizeof(wchar_t));
  write.hook_name = kHookName;
  write.hook_code = kHookCode;
  EnterCriticalSection(&g_text_cs);
  const uint64_t event = fushi_voice_hook::WriteTextLaneEvent(
      g_header, fushi_voice_hook::kNativeThreadPreviewStart,
      fushi_voice_hook::kTextLaneCount, write);
  LeaveCriticalSection(&g_text_cs);
  if (event == 0u) return 0u;
  rt.last_text = text;
  rt.last_text_tick = tick;
  rt.last_text_event = event;
  return event;
}

// The text event of the latest unit that carried this voice tag.
uint64_t MalieTextEventForVoice(const std::wstring& key, uint64_t tick) {
  auto& rt = g_malie_lookup;
  uint64_t best = 0u;
  uint64_t best_tick = 0u;
  for (const auto& binding : rt.bindings) {
    if (binding.text_event == 0u || binding.key != key ||
        binding.tick > tick + kMalieVoiceBindMs ||
        tick > binding.tick + kMalieVoiceBindMs) {
      continue;
    }
    if (binding.tick >= best_tick) {
      best = binding.text_event;
      best_tick = binding.tick;
    }
  }
  return best;
}

void ProcessMalieSegment(const MalieSegmentEvent& event) {
  auto& rt = g_malie_lookup;
  malie_lookup::Segment segment;
  if (!malie_lookup::CleanSegment(event.raw, event.units, &segment)) return;
  const uint64_t text_event =
      PublishMalieTextLine(segment.line, event.node, event.tick);
  if (!segment.voice.empty() && text_event != 0u) {
    auto& binding = rt.bindings[rt.next_binding++ % kMalieVoiceBindings];
    binding.key = malie_lookup::VoiceKey(segment.voice);
    binding.text_event = text_event;
    binding.tick = event.tick;
  }
  rt.current.valid = !segment.markup && text_event != 0u;
  rt.current.id = ++rt.next_segment;
  rt.current.tick = event.tick;
  rt.current.text_event = text_event;
  rt.current.node = event.node;
  rt.current.start = event.start;
  rt.current.end = event.end;
  rt.current.line = segment.line;
  rt.watched_node.store(event.node, std::memory_order_release);
  MalieLookupLog(L"segment node=%08lx glyphs=%d..%d units=%u line=%u voice=%d "
                 L"markup=%d event=%llu",
                 static_cast<unsigned long>(event.node), event.start,
                 event.end, event.units,
                 static_cast<unsigned>(segment.line.size()),
                 segment.voice.empty() ? 0 : 1, segment.markup ? 1 : 0,
                 static_cast<unsigned long long>(text_event));
}

void DrainMalieSegments() {
  auto& rt = g_malie_lookup;
  const uint64_t latest = rt.segment_count.load(std::memory_order_acquire);
  if (latest == rt.processed_segments) return;
  uint64_t next = rt.processed_segments + 1u;
  if (latest - rt.processed_segments > kMalieSegmentSlots) {
    next = latest - kMalieSegmentSlots + 1u;
  }
  for (; next <= latest; ++next) {
    auto& slot_seq = rt.segment_seq[next % kMalieSegmentSlots];
    if (slot_seq.load(std::memory_order_acquire) != next) break;
    std::atomic_thread_fence(std::memory_order_acquire);
    std::memcpy(&rt.event_copy, &rt.segments[next % kMalieSegmentSlots],
                sizeof(MalieSegmentEvent));
    std::atomic_thread_fence(std::memory_order_acquire);
    rt.processed_segments = next;
    if (slot_seq.load(std::memory_order_acquire) != next) continue;
    ProcessMalieSegment(rt.event_copy);
  }
}

// The window whose procedure receives the clicks: the game's window that
// lies under the main window's client and has its procedure in the image
// (the frame forwards; the client child dispatches).  Re-evaluated whenever
// the bound window is gone or hidden; a rejection holds only for the window
// and procedure it was made for (malie_lookup_core.h DecideWindowStep).
bool CollectMalieWindowCandidate(malie_lookup::WindowCandidate* candidate,
                                 HWND* main_window) {
  auto& rt = g_malie_lookup;
  *candidate = malie_lookup::WindowCandidate();
  const HWND main = fushi_voice_hook::FindGameMainWindow();
  *main_window = main;
  if (main == nullptr) return true;  // not created yet
  RECT client = {};
  if (!GetClientRect(main, &client)) return true;
  POINT center = {(client.right - client.left) / 2,
                  (client.bottom - client.top) / 2};
  HWND target = ChildWindowFromPointEx(main, center, CWP_SKIPINVISIBLE);
  if (target == nullptr) target = main;
  ::fushi_voice_hook::exact_lookup::LoadedPeImage image;
  if (!::fushi_voice_hook::exact_lookup::OpenLoadedPeImage(
          reinterpret_cast<HMODULE>(rt.image_base), &image)) {
    return false;
  }
  const uintptr_t procedure =
      static_cast<uintptr_t>(GetWindowLongPtrW(target, GWLP_WNDPROC));
  candidate->window = reinterpret_cast<uintptr_t>(target);
  candidate->procedure = procedure;
  candidate->in_image =
      procedure >= rt.image_base &&
      ::fushi_voice_hook::malie_io::ExecutableAt(image, procedure - rt.image_base,
                                                 16u);
  return true;
}

void TryHookMalieWindow() {
  auto& rt = g_malie_lookup;
  auto& state = rt.window_state;
  const HWND bound = reinterpret_cast<HWND>(state.bound);
  state.bound_alive = bound != nullptr && IsWindow(bound) &&
                      IsWindowVisible(bound);
  if (malie_lookup::DecideWindowStep(malie_lookup::WindowCandidate(), state) ==
      malie_lookup::WindowStep::kKeep) {
    return;
  }
  if (state.bound != 0u) {
    MalieLookupLog(L"lookup: click window gone or hidden, re-evaluating");
    state.bound = 0u;
    rt.window = nullptr;
  }
  const uint64_t now = GetTickCount64();
  if (rt.window_retry_tick != 0u && now - rt.window_retry_tick < kMalieWindowRetryMs) {
    return;
  }
  rt.window_retry_tick = now;
  malie_lookup::WindowCandidate candidate;
  HWND main = nullptr;
  if (!CollectMalieWindowCandidate(&candidate, &main)) return;
  const auto step = malie_lookup::DecideWindowStep(candidate, state);
  if (step == malie_lookup::WindowStep::kKeep ||
      step == malie_lookup::WindowStep::kWait) {
    return;
  }
  if (step == malie_lookup::WindowStep::kReject) {
    state.rejected_window = candidate.window;
    state.rejected_procedure = candidate.procedure;
    MalieLookupLog(L"lookup: click window rejected in_image=%d hooked=%u",
                   candidate.in_image ? 1 : 0, state.hooked_count);
    return;
  }
  if (step == malie_lookup::WindowStep::kHook) {
    const uint32_t slot = state.hooked_count;
    const bool hooked = InstallMalieHook(
        reinterpret_cast<void*>(candidate.procedure),
        reinterpret_cast<void*>(kMalieWndProcDetours[slot]),
        reinterpret_cast<void**>(&g_malie_wndproc_original[slot]));
    MalieLookupLog(L"lookup: click window procedure %u +0x%lx hooked=%d", slot,
                   static_cast<unsigned long>(candidate.procedure -
                                              rt.image_base),
                   hooked ? 1 : 0);
    if (!hooked) {
      state.rejected_window = candidate.window;
      state.rejected_procedure = candidate.procedure;
      return;
    }
    state.hooked[state.hooked_count++] = candidate.procedure;
  }
  state.bound = candidate.window;
  state.bound_alive = true;
  rt.window = reinterpret_cast<HWND>(candidate.window);
  RECT child = {};
  GetWindowRect(rt.window, &child);
  POINT origin = {child.left, child.top};
  ScreenToClient(main, &origin);
  MalieLookupLog(L"lookup: click window %s bound procedure=+0x%lx "
                 L"origin=%ld,%ld",
                 rt.window == main ? L"main" : L"child",
                 static_cast<unsigned long>(candidate.procedure - rt.image_base),
                 origin.x, origin.y);
}

void RetireMalieLookup() {
  auto& rt = g_malie_lookup;
  rt.published_model.store(UINT32_MAX, std::memory_order_release);
  rt.model.generation = 0u;
  rt.model.count = 0u;
  rt.model_line.clear();
  rt.model_text_event = 0u;
  if (!rt.provider_offered) return;
  rt.provider_offered = false;
  if (g_header != nullptr) {
    fushi_voice_hook::g_geometry_provider_registry.Retire(
        g_header, fushi_voice_hook::kLookupGeometryProviderEngineExactLayout,
        fushi_voice_hook::kLookupGeometryProviderIdMalie);
  }
}

struct MalieDpiScope {
  explicit MalieDpiScope(DPI_AWARENESS_CONTEXT context)
      : previous(SetThreadDpiAwarenessContext(context)) {}
  ~MalieDpiScope() {
    if (previous != nullptr) SetThreadDpiAwarenessContext(previous);
  }
  DPI_AWARENESS_CONTEXT previous;
};

uint32_t g_malie_model_failure = 0u;
int32_t g_malie_failure_detail[4] = {};

bool FailMalieModel(uint32_t step, int32_t a = 0, int32_t b = 0, int32_t c = 0,
                    int32_t d = 0) {
  g_malie_model_failure = step;
  g_malie_failure_detail[0] = a;
  g_malie_failure_detail[1] = b;
  g_malie_failure_detail[2] = c;
  g_malie_failure_detail[3] = d;
  return false;
}

// 1 window 2 dpi 3 snapshot 4 stale draw 5 design 6 aspect 7 transform
// 8 mapping 9 projection
bool BuildMalieModel(const std::wstring& line, MalieModel* model) {
  auto& rt = g_malie_lookup;
  const HWND window = rt.window;
  if (window == nullptr || !IsWindow(window) || !IsWindowVisible(window) ||
      IsIconic(GetAncestor(window, GA_ROOT))) {
    return FailMalieModel(1u);
  }
  RECT logical = {};
  RECT physical = {};
  {
    const DPI_AWARENESS_CONTEXT context = GetWindowDpiAwarenessContext(window);
    if (context == nullptr) return FailMalieModel(2u);
    MalieDpiScope own(context);
    if (own.previous == nullptr || !GetClientRect(window, &logical)) {
      return FailMalieModel(2u);
    }
  }
  {
    MalieDpiScope aware(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
    if (aware.previous == nullptr || !GetClientRect(window, &physical)) {
      return FailMalieModel(2u);
    }
  }
  MalieGlyphSnapshot& snap = rt.snapshot_copy;
  if (!ReadSeq(rt.snapshot_seq, rt.snapshots, rt.published_snapshot, &snap) ||
      snap.node != rt.current.node) {
    return FailMalieModel(3u);
  }
  if (rt.logged_snapshot_segment != rt.current.id) {
    rt.logged_snapshot_segment = rt.current.id;
    const int32_t g = rt.current.start < snap.count ? rt.current.start : 0;
    MalieLookupLog(L"snapshot n=%d reveal=%d..%d t=%.1f,%.1f,%.1f "
                   L"p=[%.3f %.3f %.3f %.3f | %.1f %.1f] box[%d]=%d,%d,%d,%d",
                   snap.count, snap.reveal_start, snap.reveal_end,
                   snap.translate[0], snap.translate[1], snap.translate[2],
                   snap.parent[0], snap.parent[1], snap.parent[4],
                   snap.parent[5], snap.parent[12], snap.parent[13], g,
                   snap.boxes[g][0], snap.boxes[g][1], snap.boxes[g][2],
                   snap.boxes[g][3]);
  }
  if (MalieWatchedNodeStale()) {
    return FailMalieModel(4u);
  }
  int32_t design_w = 0, design_h = 0;
  if (rt.design_w_global == 0u || rt.design_h_global == 0u ||
      !ReadMalieInt(rt.design_w_global, &design_w) ||
      !ReadMalieInt(rt.design_h_global, &design_h) || design_w < 64 ||
      design_h < 64 || design_w > 8192 || design_h > 8192) {
    return FailMalieModel(5u, design_w, design_h);
  }
  const int32_t logical_w = logical.right - logical.left;
  const int32_t logical_h = logical.bottom - logical.top;
  const int32_t physical_w = physical.right - physical.left;
  const int32_t physical_h = physical.bottom - physical.top;
  bool covers_monitor = true;
  {
    MONITORINFO monitor = {sizeof(monitor)};
    RECT screen = physical;
    MalieDpiScope aware(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
    if (aware.previous != nullptr &&
        MapWindowPoints(window, nullptr, reinterpret_cast<POINT*>(&screen),
                        2) != 0 &&
        GetMonitorInfoW(MonitorFromWindow(window, MONITOR_DEFAULTTONEAREST),
                        &monitor)) {
      covers_monitor = screen.left <= monitor.rcMonitor.left &&
                       screen.top <= monitor.rcMonitor.top &&
                       screen.right >= monitor.rcMonitor.right &&
                       screen.bottom >= monitor.rcMonitor.bottom;
    }
  }
  if (!malie_lookup::ClientScaleAdmitted(logical_w, logical_h, design_w,
                                         design_h, covers_monitor) ||
      !malie_lookup::ClientScaleAdmitted(physical_w, physical_h, design_w,
                                         design_h, covers_monitor)) {
    return FailMalieModel(6u, design_w, design_h, logical_w, logical_h);
  }
  malie_lookup::Affine world;
  if (!malie_lookup::ComposeWorld(snap.translate, snap.parent, &world)) {
    return FailMalieModel(7u);
  }
  const int32_t start = rt.current.start;
  const int32_t end = rt.current.end;
  if (start < 0 || end <= start || end > snap.count ||
      snap.reveal_end < end) {
    return FailMalieModel(8u, start, end, snap.count, snap.reveal_end);
  }
  uint16_t glyph_of_unit[malie_lookup::kMaxSegmentUnits] = {};
  if (line.size() > malie_lookup::kMaxSegmentUnits ||
      !malie_lookup::MapLine(snap.codes, static_cast<size_t>(start),
                             static_cast<size_t>(end - start), line,
                             glyph_of_unit)) {
    return FailMalieModel(8u, start, end, static_cast<int32_t>(line.size()), -1);
  }
  model->segment = rt.segment_count.load(std::memory_order_acquire);
  model->window = reinterpret_cast<uintptr_t>(window);
  model->node = snap.node;
  model->client_w = logical_w;
  model->client_h = logical_h;
  model->physical_w = physical_w;
  model->physical_h = physical_h;
  model->count = static_cast<uint32_t>(line.size());
  for (size_t unit = 0u; unit < line.size(); ++unit) {
    model->logical[unit] = {};
    model->physical[unit] = {};
    const uint16_t glyph = glyph_of_unit[unit];
    if (glyph == malie_lookup::kNoGlyph) continue;
    malie_lookup::DesignRect design;
    if (!malie_lookup::GlyphDesignRect(world, snap.boxes[glyph], &design) ||
        !malie_lookup::ProjectDesign(design, design_w, design_h, logical_w,
                                     logical_h, &model->logical[unit]) ||
        !malie_lookup::ProjectDesign(design, design_w, design_h, physical_w,
                                     physical_h, &model->physical[unit])) {
      return FailMalieModel(9u, snap.boxes[glyph][0], snap.boxes[glyph][1],
                            static_cast<int32_t>(world.dx),
                            static_cast<int32_t>(world.dy));
    }
  }
  return true;
}

bool SameMalieModel(const MalieModel& a, const MalieModel& b) {
  if (a.segment != b.segment || a.window != b.window || a.node != b.node ||
      a.client_w != b.client_w || a.client_h != b.client_h ||
      a.physical_w != b.physical_w || a.physical_h != b.physical_h ||
      a.count != b.count) {
    return false;
  }
  for (uint32_t i = 0u; i < a.count; ++i) {
    const auto& l = a.physical[i];
    const auto& r = b.physical[i];
    if (l.x != r.x || l.y != r.y || l.w != r.w || l.h != r.h) return false;
  }
  return true;
}

bool ReadLatestMalieSubmit(MalieSubmit* out) {
  auto& rt = g_malie_lookup;
  const uint64_t sequence = rt.submit_count.load(std::memory_order_acquire);
  if (sequence == 0u || sequence == rt.processed_submit) return false;
  rt.processed_submit = sequence;
  auto& slot_seq = rt.submit_seq[sequence % kMalieSubmitSlots];
  if (slot_seq.load(std::memory_order_acquire) != sequence) return false;
  std::atomic_thread_fence(std::memory_order_acquire);
  *out = rt.submits[sequence % kMalieSubmitSlots];
  std::atomic_thread_fence(std::memory_order_acquire);
  return slot_seq.load(std::memory_order_acquire) == sequence;
}

struct MaliePublishedLine {
  uint64_t generation = 0u;
  uint64_t text_event = 0u;
  std::wstring line;
};
std::array<MaliePublishedLine, 4> g_malie_published_lines{};
size_t g_malie_published_next = 0u;

bool PublishMalieLookupHit(const MalieSubmit& submit) {
  if (g_header == nullptr || submit.generation == 0u) return false;
  const MaliePublishedLine* record = nullptr;
  for (const auto& slot : g_malie_published_lines) {
    if (slot.generation == submit.generation && !slot.line.empty()) {
      record = &slot;
    }
  }
  if (record == nullptr) {
    MalieLookupLog(L"lookup: hit dropped gen=%llu reason=model-gone",
                   static_cast<unsigned long long>(submit.generation));
    return false;
  }
  const std::wstring& line = record->line;
  const uint32_t units = static_cast<uint32_t>(line.size());
  if (submit.unit >= units) return false;
  const uint32_t length = fushi_voice_hook::LookupUtf16SourceLength(
      line.data(), units, submit.unit);
  const int required = WideCharToMultiByte(
      CP_UTF8, WC_ERR_INVALID_CHARS, line.data(), static_cast<int>(units),
      nullptr, 0, nullptr, nullptr);
  if (length == 0u || required <= 0 ||
      static_cast<uint32_t>(required) > fushi_voice_hook::kLookupLineBytes) {
    return false;
  }
  char utf8[fushi_voice_hook::kLookupLineBytes] = {};
  if (WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, line.data(),
                          static_cast<int>(units), utf8, required, nullptr,
                          nullptr) != required) {
    return false;
  }
  fushi_voice_hook::LookupGeometryHitPublication publication;
  publication.provider_kind =
      fushi_voice_hook::kLookupGeometryProviderEngineExactLayout;
  publication.provider_id = fushi_voice_hook::kLookupGeometryProviderIdMalie;
  publication.char_index = submit.unit;
  publication.source_length = length;
  publication.char_count = units;
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
  MalieLookupLog(L"lookup: hit gen=%llu unit=%u+%u rect=%d,%d %dx%d view=%dx%d "
                 L"published=%d",
                 static_cast<unsigned long long>(submit.generation), submit.unit,
                 length, submit.rect.x, submit.rect.y, submit.rect.w,
                 submit.rect.h, submit.physical_w, submit.physical_h,
                 published ? 1 : 0);
  return published;
}

void NoteMalieRetire(uint32_t reason) {
  static uint32_t last = UINT32_MAX;
  const uint32_t key = reason == 4u ? 100u + g_malie_model_failure : reason;
  if (key == last) return;
  last = key;
  static const wchar_t* const kNames[] = {
      L"offered",        L"lookup-disabled", L"no-segment", L"no-selected-text",
      L"model-unbuilt",  L"offer-rejected",  L"no-window",  L"other-line"};
  if (reason == 4u) {
    MalieLookupLog(L"lookup: gate=model-unbuilt step=%u %d,%d,%d,%d draws=%llu",
                   g_malie_model_failure, g_malie_failure_detail[0],
                   g_malie_failure_detail[1], g_malie_failure_detail[2],
                   g_malie_failure_detail[3],
                   static_cast<unsigned long long>(
                       g_malie_lookup.draw_calls.load()));
    return;
  }
  MalieLookupLog(L"lookup: gate=%s", reason < 8u ? kNames[reason] : L"?");
}

void ProcessMalieLookupTick() {
  auto& rt = g_malie_lookup;
  if (!rt.installed) return;
  DrainMalieSegments();  // the text lane does not depend on the lookup switch
  if (g_stop || g_header == nullptr ||
      !fushi_voice_hook::HasLookupRegion(g_header) ||
      fushi_voice_hook::AtomicLoadShared32(&g_header->lookup_enabled) == 0u) {
    NoteMalieRetire(1u);
    RetireMalieLookup();
    return;
  }
  fushi_voice_hook::AtomicOrShared32(
      &g_header->lookup_diag, fushi_voice_hook::kLookupDiagSensorInstalled);
  const uint64_t claims = rt.claimed_presses.load(std::memory_order_acquire);
  if (claims != rt.logged_claims) {
    rt.logged_claims = claims;
    MalieLookupLog(L"lookup: press claimed total=%llu",
                   static_cast<unsigned long long>(claims));
  }
  const uint64_t refusals = rt.refused_presses.load(std::memory_order_acquire);
  if (refusals != rt.logged_refusals) {
    rt.logged_refusals = refusals;
    MalieLookupLog(L"lookup: press refused total=%llu reason=%u",
                   static_cast<unsigned long long>(refusals),
                   rt.refused_reason.load(std::memory_order_acquire));
  }
  MalieSubmit submit;
  if (ReadLatestMalieSubmit(&submit)) (void)PublishMalieLookupHit(submit);
  TryHookMalieWindow();
  if (rt.window_state.bound == 0u) {
    NoteMalieRetire(6u);
    RetireMalieLookup();
    return;
  }
  if (!rt.current.valid) {
    NoteMalieRetire(2u);
    RetireMalieLookup();
    return;
  }
  std::wstring line;
  uint64_t event = 0u;
  uint64_t thread = 0u;
  if (!fushi_voice_hook::ReadSelectedLookupText(
          g_header, &line, &event, &thread, malie_lookup::kMaxSegmentUnits)) {
    NoteMalieRetire(3u);
    RetireMalieLookup();
    return;
  }
  // The selected line must be the current click unit (exact text).
  if (line != rt.current.line) {
    NoteMalieRetire(7u);
    RetireMalieLookup();
    return;
  }
  MalieModel& built = rt.candidate;
  if (!BuildMalieModel(line, &built)) {
    NoteMalieRetire(4u);
    RetireMalieLookup();
    return;
  }
  const bool same = rt.model.generation != 0u && rt.model_text_event == event &&
                    rt.model_line == line && SameMalieModel(rt.model, built);
  if (!same) {
    built.generation = ++rt.next_generation;
    rt.model = built;
    rt.model_line = line;
    rt.model_text_event = event;
    auto& record = g_malie_published_lines[g_malie_published_next++ % 4u];
    record.generation = rt.model.generation;
    record.text_event = event;
    record.line = line;
    PublishSeq(rt.model_seq, rt.models, rt.published_model, rt.model);
    const auto& first = rt.model.physical[0];
    const auto& last = rt.model.physical[rt.model.count - 1u];
    MalieLookupLog(L"lookup: model gen=%llu units=%u first=%d,%d %dx%d "
                   L"last=%d,%d %dx%d client=%dx%d physical=%dx%d",
                   static_cast<unsigned long long>(rt.model.generation),
                   rt.model.count, first.x, first.y, first.w, first.h, last.x,
                   last.y, last.w, last.h, rt.model.client_w,
                   rt.model.client_h, rt.model.physical_w,
                   rt.model.physical_h);
  }
  if (fushi_voice_hook::g_geometry_provider_registry.OfferReady(
          g_header, fushi_voice_hook::kLookupGeometryProviderEngineExactLayout,
          fushi_voice_hook::kLookupGeometryProviderIdMalie)) {
    rt.provider_offered = true;
    fushi_voice_hook::AtomicOrShared32(
        &g_header->lookup_diag, fushi_voice_hook::kLookupDiagGeometryObserved);
    NoteMalieRetire(0u);
  } else {
    NoteMalieRetire(5u);
    RetireMalieLookup();
  }
}

void ShutdownMalieLookup() {
  auto& rt = g_malie_lookup;
  rt.live.store(false, std::memory_order_release);
  rt.claim = malie_lookup::ClaimState();
  rt.current.valid = false;
  RetireMalieLookup();
}

#else  // !_M_IX86

bool InstallMalieLookup() { return false; }
void ProcessMalieLookupTick() {}
void ShutdownMalieLookup() {}
uint64_t MalieTextEventForVoice(const std::wstring&, uint64_t) { return 0u; }

#endif  // _M_IX86
