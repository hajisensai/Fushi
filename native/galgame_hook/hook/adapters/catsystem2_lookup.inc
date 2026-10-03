// CatSystem2 in-game lookup runtime (EngineExactLayout /
// kLookupGeometryProviderIdCatSystem2).  Engine facts, signatures and every
// decision rule live in catsystem2_lookup_core.h and are unit-tested; this
// file only binds them to MinHook, Win32 and the v19 registry.
//
// Threads:
//   * game thread — three detours, bounded and allocation-free:
//       ClearPage(renderer)        forgets the renderer's page;
//       RenderChar(renderer, rec)  records {code, pen cell} of every revealed
//                                  character (LunaHook keeps the rasteriser
//                                  two calls below; this is a separate
//                                  function);
//       Window::Update             binds the renderer to its scene layer,
//                                  walks the draw-ordered layer list for the
//                                  page's placement and covers, and publishes
//                                  the tracker snapshot when it changed.
//   * message thread — Input::Handle: a bare WM_LBUTTONDOWN / DBLCLK that
//     lands on a mapped glyph of the current model is swallowed together with
//     its WM_LBUTTONUP, so the script never sees the click.
//   * HookWorker — ProcessCatSystem2LookupTick: matches the selected LunaHook
//     line against the visible glyphs of exactly one surface, projects them
//     to physical client pixels, offers/retires the provider, publishes the
//     model the message thread hit-tests against, and turns queued presses
//     into registry hits.
//
// Fail closed everywhere: an unresolved signature installs nothing, a stale
// frame, a text mismatch, an ambiguous surface, a client with another aspect
// than the design screen or a missing native-input admission retires the
// provider or refuses the click, and the click then reaches the game
// unchanged.

#if defined(_M_IX86)

namespace cs2_lookup = fushi_voice_hook::catsystem2_lookup;

constexpr uint32_t kCs2ModelSlots = 2u;
constexpr uint32_t kCs2SubmitSlots = 8u;
constexpr uint64_t kCs2FrameStaleMs = 250u;
constexpr uint32_t kCs2ModelLogBudget = 24u;
constexpr size_t kCs2SnapshotGlyphs = cs2_lookup::kMaxSurfaceGlyphs * 2u;
constexpr size_t kCs2WindowSlots = 4u;

struct Cs2SnapshotSurface {
  uintptr_t renderer = 0u;
  uint32_t first = 0u;
  uint32_t count = 0u;
};

struct Cs2Snapshot {
  uint64_t version = 0u;
  uintptr_t window = 0u;
  int32_t design_w = 0;
  int32_t design_h = 0;
  uint32_t surface_count = 0u;
  std::array<Cs2SnapshotSurface, cs2_lookup::kSurfaceSlots> surfaces{};
  uint32_t glyph_count = 0u;
  std::array<cs2_lookup::LineGlyph, kCs2SnapshotGlyphs> glyphs{};
};

struct Cs2ModelGlyph {
  cs2_lookup::LineGlyph line;
  cs2_lookup::PixelRect rect;  // physical client pixels
};

struct Cs2Model {
  uint64_t generation = 0u;
  uint64_t snapshot_version = 0u;
  uintptr_t window = 0u;
  uintptr_t renderer = 0u;
  int32_t design_w = 0;
  int32_t design_h = 0;
  int32_t logical_w = 0;
  int32_t logical_h = 0;
  int32_t physical_w = 0;
  int32_t physical_h = 0;
  uint32_t count = 0u;
  std::array<Cs2ModelGlyph, cs2_lookup::kMaxSurfaceGlyphs> glyphs{};
};

struct Cs2Submit {
  uint64_t generation = 0u;
  uint32_t glyph = 0u;
};

struct Cs2WindowBinding {
  uintptr_t window_object = 0u;
  uintptr_t renderer = 0u;
  uintptr_t screen = 0u;
  int32_t layer_id = 0;
};

struct Cs2LookupRuntime {
  // ── HookWorker-owned ──
  bool resolved = false;
  bool hooks_installed = false;
  bool installed = false;
  cs2_lookup::SiteResult site_result = cs2_lookup::SiteResult::kNotX86;
  bool provider_offered = false;
  uint64_t processed_submit_seq = 0u;
  uint64_t next_generation = 0u;
  uint32_t logged_models = 0u;
  Cs2Model model;
  std::wstring model_line;
  uint64_t model_text_event = 0u;
  Cs2Snapshot snapshot_copy;
  std::array<cs2_lookup::LineGlyph, cs2_lookup::kMaxSurfaceGlyphs>
      match_scratch{};

  // ── resolved once, read everywhere ──
  cs2_lookup::Sites sites;

  // ── game-thread-owned ──
  cs2_lookup::GlyphTracker tracker;
  uint64_t published_version = UINT64_MAX;
  uintptr_t published_window = 0u;
  int32_t published_design_w = 0;
  int32_t published_design_h = 0;
  Cs2Snapshot building;
  DWORD game_thread = 0u;
  std::array<Cs2WindowBinding, kCs2WindowSlots> windows{};
  std::array<cs2_lookup::LayerNode, cs2_lookup::kMaxLayerNodes> nodes{};

  // ── message-thread-owned ──
  cs2_lookup::ClaimState claim;
  Cs2Model input_model;  // scratch for the press-time model read
  std::array<cs2_lookup::LineGlyph, cs2_lookup::kMaxSurfaceGlyphs>
      input_lines{};

  // ── shared ──
  std::atomic<bool> live{false};
  std::atomic<uint64_t> last_frame_tick{0u};
  std::atomic<uint64_t> latest_version{0u};
  std::array<std::atomic<uint32_t>, 2u> snapshot_seq = {};
  std::array<Cs2Snapshot, 2u> snapshots = {};
  std::atomic<uint32_t> published_snapshot{UINT32_MAX};
  std::array<std::atomic<uint32_t>, kCs2ModelSlots> model_seq = {};
  std::array<Cs2Model, kCs2ModelSlots> models = {};
  std::atomic<uint32_t> published_model{UINT32_MAX};
  std::array<std::atomic<uint64_t>, kCs2SubmitSlots> submit_seq = {};
  std::array<Cs2Submit, kCs2SubmitSlots> submits = {};
  std::atomic<uint64_t> submit_count{0u};
  std::atomic<uint64_t> claimed_presses{0u};
  // Presses that reached Handle and the gate that decided the last one
  // (Cs2PressGate); the worker logs them, the message thread only stores.
  std::atomic<uint32_t> presses_seen{0u};
  std::atomic<uint32_t> last_press_gate{0u};
  // Design point of the last press that reached the hit test and how many
  // clickable rectangles contained it (HitTestLine wants exactly one).
  std::atomic<int32_t> last_press_x{-1};
  std::atomic<int32_t> last_press_y{-1};
  std::atomic<uint32_t> last_press_candidates{0u};
  std::atomic<uint32_t> render_hits{0u};
  std::atomic<uint32_t> update_hits{0u};
  std::atomic<uint32_t> placement_failures{0u};
};

Cs2LookupRuntime g_cs2_lookup;
using Cs2ClearFn = int(__thiscall*)(uintptr_t);
using Cs2RenderFn = int(__thiscall*)(uintptr_t, uintptr_t);
using Cs2RenderTargetFn = int(__thiscall*)(uintptr_t, uintptr_t, uintptr_t);
using Cs2UpdateFn = int(__thiscall*)(uintptr_t, uintptr_t, uintptr_t);
using Cs2InputFn = LRESULT(__stdcall*)(uintptr_t, HWND, UINT, WPARAM, LPARAM);
using Cs2InputExtraFn = LRESULT(__stdcall*)(uintptr_t, HWND, UINT, WPARAM,
                                            LPARAM, uintptr_t);
Cs2ClearFn g_cs2_clear_original = nullptr;
Cs2RenderFn g_cs2_render_original = nullptr;
Cs2RenderTargetFn g_cs2_render_target_original = nullptr;
Cs2UpdateFn g_cs2_update_original = nullptr;
Cs2InputFn g_cs2_input_original = nullptr;
Cs2InputExtraFn g_cs2_input_extra_original = nullptr;

// ── two-slot seqlocks ──────────────────────────────────────────────────────

template <typename T, size_t Slots>
void PublishCs2Slot(std::array<std::atomic<uint32_t>, Slots>& seqs,
                    std::array<T, Slots>& slots,
                    std::atomic<uint32_t>& published, const T& value,
                    size_t bytes) {
  const uint32_t current = published.load(std::memory_order_acquire);
  const uint32_t slot =
      current >= Slots ? 0u : static_cast<uint32_t>((current + 1u) % Slots);
  const uint32_t seq = seqs[slot].load(std::memory_order_relaxed);
  seqs[slot].store(seq | 1u, std::memory_order_release);
  std::atomic_thread_fence(std::memory_order_release);
  std::memcpy(&slots[slot], &value, bytes);
  std::atomic_thread_fence(std::memory_order_release);
  seqs[slot].store((seq | 1u) + 1u, std::memory_order_release);
  published.store(slot, std::memory_order_release);
}

template <typename T, size_t Slots>
bool ReadCs2Slot(const std::array<std::atomic<uint32_t>, Slots>& seqs,
                 const std::array<T, Slots>& slots,
                 const std::atomic<uint32_t>& published, T* out,
                 size_t bytes) {
  const uint32_t slot = published.load(std::memory_order_acquire);
  if (out == nullptr || slot >= Slots) return false;
  const uint32_t before = seqs[slot].load(std::memory_order_acquire);
  if (before == 0u || (before & 1u) != 0u) return false;
  std::atomic_thread_fence(std::memory_order_acquire);
  std::memcpy(out, &slots[slot], bytes);
  std::atomic_thread_fence(std::memory_order_acquire);
  return seqs[slot].load(std::memory_order_acquire) == before &&
         published.load(std::memory_order_acquire) == slot;
}

size_t Cs2SnapshotBytes(uint32_t glyphs) {
  return offsetof(Cs2Snapshot, glyphs) +
         static_cast<size_t>(glyphs) * sizeof(cs2_lookup::LineGlyph);
}

size_t Cs2ModelBytes(uint32_t count) {
  return offsetof(Cs2Model, glyphs) +
         static_cast<size_t>(count) * sizeof(Cs2ModelGlyph);
}

bool ReadCs2Model(Cs2Model* out) {
  auto& rt = g_cs2_lookup;
  if (!ReadCs2Slot(rt.model_seq, rt.models, rt.published_model, out,
                   offsetof(Cs2Model, glyphs))) {
    return false;
  }
  const uint32_t count = (std::min)(
      out->count, static_cast<uint32_t>(cs2_lookup::kMaxSurfaceGlyphs));
  return ReadCs2Slot(rt.model_seq, rt.models, rt.published_model, out,
                     Cs2ModelBytes(count)) &&
         out->count == count;
}

bool ReadCs2Snapshot(Cs2Snapshot* out) {
  auto& rt = g_cs2_lookup;
  if (!ReadCs2Slot(rt.snapshot_seq, rt.snapshots, rt.published_snapshot, out,
                   offsetof(Cs2Snapshot, glyphs))) {
    return false;
  }
  const uint32_t count = (std::min)(
      out->glyph_count, static_cast<uint32_t>(kCs2SnapshotGlyphs));
  return ReadCs2Slot(rt.snapshot_seq, rt.snapshots, rt.published_snapshot, out,
                     Cs2SnapshotBytes(count)) &&
         out->glyph_count == count;
}

void InvalidateCs2Model() {
  g_cs2_lookup.published_model.store(UINT32_MAX, std::memory_order_release);
}

template <typename T>
bool ReadCs2Value(uintptr_t address, T* out) {
  if (address == 0u || out == nullptr) return false;
  __try {
    std::memcpy(out, reinterpret_cast<const void*>(address), sizeof(T));
  } __except (EXCEPTION_EXECUTE_HANDLER) {
    return false;
  }
  return true;
}

// ── game-thread detours ────────────────────────────────────────────────────

bool Cs2OnGameThread() {
  auto& rt = g_cs2_lookup;
  return rt.live.load(std::memory_order_acquire) && rt.game_thread != 0u &&
         GetCurrentThreadId() == rt.game_thread;
}

int __fastcall Cs2ClearDetour(uintptr_t renderer, uintptr_t) {
  const int result = g_cs2_clear_original(renderer);
  if (Cs2OnGameThread()) g_cs2_lookup.tracker.ClearPage(renderer);
  return result;
}

// One rendered record of `renderer`'s page (bounded copy, game thread).
void RecordCs2Render(uintptr_t renderer, uintptr_t record) {
  auto& rt = g_cs2_lookup;
  rt.render_hits.fetch_add(1u, std::memory_order_relaxed);
  if (!Cs2OnGameThread()) return;
  uint8_t bytes[cs2_lookup::kRecordBytes] = {};
  int32_t page_w = 0, page_h = 0;
  if (!ReadCs2Value(record, &bytes) ||
      !ReadCs2Value(renderer + cs2_lookup::kRendererPageWidthOffset, &page_w) ||
      !ReadCs2Value(renderer + cs2_lookup::kRendererPageHeightOffset,
                    &page_h)) {
    return;
  }
  uint16_t code = 0u;
  int32_t x = 0, y = 0, advance = 0, size = 0;
  std::memcpy(&code, bytes + cs2_lookup::kRecordCodeOffset, sizeof(code));
  std::memcpy(&x, bytes + cs2_lookup::kRecordXOffset, sizeof(x));
  std::memcpy(&y, bytes + cs2_lookup::kRecordYOffset, sizeof(y));
  std::memcpy(&advance, bytes + cs2_lookup::kRecordAdvanceOffset,
              sizeof(advance));
  std::memcpy(&size, bytes + cs2_lookup::kRecordSizeOffset, sizeof(size));
  rt.tracker.RecordGlyph(renderer, page_w, page_h, code, x, y, advance, size);
}

int __fastcall Cs2RenderDetour(uintptr_t renderer, uintptr_t,
                               uintptr_t record) {
  const int result = g_cs2_render_original(renderer, record);
  RecordCs2Render(renderer, record);
  return result;
}

// Targeted-render layout: the target is one of the renderer's two page
// images (text fade draws into the second one and swaps them afterwards);
// both carry the same on-screen page, anything else is not text.
int __fastcall Cs2RenderTargetDetour(uintptr_t renderer, uintptr_t,
                                     uintptr_t record, uintptr_t target) {
  const int result = g_cs2_render_target_original(renderer, record, target);
  uintptr_t page = 0u, work_page = 0u;
  if (ReadCs2Value(renderer + cs2_lookup::kRendererImageOffset, &page) &&
      ReadCs2Value(renderer + cs2_lookup::kRendererWorkImageOffset,
                   &work_page) &&
      cs2_lookup::IsRendererPage(target, page, work_page)) {
    RecordCs2Render(renderer, record);
  }
  return result;
}

// Reads the draw-ordered layer list of the screen object into rt.nodes.
size_t ReadCs2LayerNodes(uintptr_t screen) {
  auto& rt = g_cs2_lookup;
  const cs2_lookup::SceneWalk& walk = rt.sites.walk;
  uintptr_t scene = 0u, list = 0u, head = 0u, node = 0u;
  if (!ReadCs2Value(screen + cs2_lookup::kScreenSceneOffset, &scene) ||
      !ReadCs2Value(scene + walk.list_offset, &list) ||
      !ReadCs2Value(list + walk.head_offset, &head) ||
      !ReadCs2Value(head + cs2_lookup::kNodeNextOffset, &node)) {
    return 0u;
  }
  size_t count = 0u;
  while (node != 0u && node != head) {
    if (count >= rt.nodes.size()) return 0u;  // unbounded list: refuse
    cs2_lookup::LayerNode& out = rt.nodes[count++];
    out = cs2_lookup::LayerNode();
    int32_t visible = 0;
    uintptr_t layer = node + cs2_lookup::kNodeLayerOffset;
    uintptr_t sprite = 0u, next = 0u;
    if (!ReadCs2Value(node + cs2_lookup::kNodeNextOffset, &next) ||
        (walk.layer_by_pointer &&
         (!ReadCs2Value(node + cs2_lookup::kNodeLayerOffset, &layer) ||
          layer == 0u)) ||
        !ReadCs2Value(layer + cs2_lookup::kLayerIdOffset, &out.id) ||
        !ReadCs2Value(layer + cs2_lookup::kLayerVisibleOffset, &visible) ||
        !ReadCs2Value(layer + cs2_lookup::kLayerSpriteOffset, &sprite)) {
      return 0u;
    }
    out.visible = visible != 0;
    if (sprite != 0u) {
      uint8_t bytes[cs2_lookup::kSpriteBytes] = {};
      if (!ReadCs2Value(sprite, &bytes)) return 0u;
      std::memcpy(&out.x, bytes + cs2_lookup::kSpriteXOffset, sizeof(float));
      std::memcpy(&out.y, bytes + cs2_lookup::kSpriteYOffset, sizeof(float));
      std::memcpy(&out.w, bytes + cs2_lookup::kSpriteWidthOffset,
                  sizeof(float));
      std::memcpy(&out.h, bytes + cs2_lookup::kSpriteHeightOffset,
                  sizeof(float));
      std::memcpy(out.box, bytes + cs2_lookup::kSpriteBoxOffset,
                  sizeof(out.box));
      out.has_sprite = true;
    }
    node = next;
  }
  return node == head ? count : 0u;
}

// Publishes the visible glyphs of every placed surface when the tracker (or
// the screen) changed since the last publication.
void PublishCs2Snapshot(uintptr_t window, int32_t design_w,
                        int32_t design_h) {
  auto& rt = g_cs2_lookup;
  const uint64_t version = rt.tracker.version();
  if (version == rt.published_version && window == rt.published_window &&
      design_w == rt.published_design_w && design_h == rt.published_design_h) {
    return;
  }
  rt.published_version = version;
  rt.published_window = window;
  rt.published_design_w = design_w;
  rt.published_design_h = design_h;
  Cs2Snapshot& snapshot = rt.building;
  snapshot.version = version;
  snapshot.window = window;
  snapshot.design_w = design_w;
  snapshot.design_h = design_h;
  snapshot.surface_count = 0u;
  snapshot.glyph_count = 0u;
  for (const auto& slot : rt.tracker.slots()) {
    if (slot.renderer == 0u) continue;
    const size_t room = kCs2SnapshotGlyphs - snapshot.glyph_count;
    const size_t count = cs2_lookup::CollectVisibleGlyphs(
        slot, snapshot.glyphs.data() + snapshot.glyph_count, room);
    if (count == 0u) continue;
    Cs2SnapshotSurface& surface = snapshot.surfaces[snapshot.surface_count++];
    surface.renderer = slot.renderer;
    surface.first = snapshot.glyph_count;
    surface.count = static_cast<uint32_t>(count);
    snapshot.glyph_count += static_cast<uint32_t>(count);
  }
  PublishCs2Slot(rt.snapshot_seq, rt.snapshots, rt.published_snapshot,
                 snapshot, Cs2SnapshotBytes(snapshot.glyph_count));
  rt.latest_version.store(version, std::memory_order_release);
}

void ObserveCs2Window(uintptr_t window_object) {
  auto& rt = g_cs2_lookup;
  uintptr_t renderer = 0u, screen = 0u;
  int32_t layer_id = 0;
  if (!ReadCs2Value(window_object + cs2_lookup::kWindowRendererOffset,
                    &renderer) ||
      !ReadCs2Value(window_object + cs2_lookup::kWindowScreenOffset, &screen) ||
      !ReadCs2Value(window_object + cs2_lookup::kWindowLayerIdOffset,
                    &layer_id) ||
      renderer == 0u || screen == 0u) {
    return;
  }
  // Remember the window (bounded table; the oldest entry is replaced).
  Cs2WindowBinding* binding = nullptr;
  for (auto& entry : rt.windows) {
    if (entry.window_object == window_object) binding = &entry;
  }
  if (binding == nullptr) {
    for (auto& entry : rt.windows) {
      if (entry.window_object == 0u) {
        binding = &entry;
        break;
      }
    }
  }
  if (binding == nullptr) binding = &rt.windows[0];
  binding->window_object = window_object;
  binding->renderer = renderer;
  binding->screen = screen;
  binding->layer_id = layer_id;
  rt.tracker.Bind(renderer, layer_id);

  const cs2_lookup::SurfaceRecord* slot = nullptr;
  for (const auto& candidate : rt.tracker.slots()) {
    if (candidate.renderer == renderer) slot = &candidate;
  }
  cs2_lookup::Placement placement;
  if (slot != nullptr) {
    const size_t count = ReadCs2LayerNodes(screen);
    placement = cs2_lookup::ResolvePlacement(rt.nodes.data(), count, layer_id,
                                             slot->page_w, slot->page_h);
    if (!placement.valid) {
      rt.placement_failures.fetch_add(1u, std::memory_order_relaxed);
    }
    rt.tracker.SetPlacement(renderer, placement);
  }

  uintptr_t window = 0u;
  int32_t w = 0, h = 0, mirror_w = 0, mirror_h = 0, design_w = 0,
          design_h = 0;
  if (!ReadCs2Value(screen + cs2_lookup::kScreenWindowOffset, &window) ||
      !ReadCs2Value(screen + cs2_lookup::kScreenWidthOffset, &w) ||
      !ReadCs2Value(screen + cs2_lookup::kScreenHeightOffset, &h) ||
      !ReadCs2Value(screen + cs2_lookup::kScreenWidthMirrorOffset, &mirror_w) ||
      !ReadCs2Value(screen + cs2_lookup::kScreenHeightMirrorOffset,
                    &mirror_h) ||
      !cs2_lookup::DesignSize(w, h, mirror_w, mirror_h, &design_w,
                              &design_h)) {
    window = 0u;
    design_w = 0;
    design_h = 0;
  }
  PublishCs2Snapshot(window, design_w, design_h);
}

int __fastcall Cs2UpdateDetour(uintptr_t window_object, uintptr_t,
                               uintptr_t a1, uintptr_t a2) {
  const int result = g_cs2_update_original(window_object, a1, a2);
  auto& rt = g_cs2_lookup;
  rt.update_hits.fetch_add(1u, std::memory_order_relaxed);
  if (!rt.live.load(std::memory_order_acquire)) return result;
  if (rt.game_thread == 0u) rt.game_thread = GetCurrentThreadId();
  if (GetCurrentThreadId() != rt.game_thread) return result;
  rt.last_frame_tick.store(GetTickCount64(), std::memory_order_release);
  ObserveCs2Window(window_object);
  return result;
}

// ── message-thread input ───────────────────────────────────────────────────

void QueueCs2Submit(const Cs2Submit& submit) {
  auto& rt = g_cs2_lookup;
  const uint64_t sequence =
      rt.submit_count.load(std::memory_order_acquire) + 1u;
  auto& slot_seq = rt.submit_seq[sequence % kCs2SubmitSlots];
  slot_seq.store(0u, std::memory_order_release);
  std::atomic_thread_fence(std::memory_order_release);
  rt.submits[sequence % kCs2SubmitSlots] = submit;
  std::atomic_thread_fence(std::memory_order_release);
  slot_seq.store(sequence, std::memory_order_release);
  rt.submit_count.store(sequence, std::memory_order_release);
}

bool Cs2ShieldActive(HWND game) {
  if (IsLookupOverlayInputShieldVisible()) return true;
  if (g_header == nullptr) return false;
  const auto request = fushi_voice_hook::ReadLookupShieldRequest(g_header);
  return request.valid && request.active_buttons != 0u &&
         request.target_hwnd ==
             static_cast<uint64_t>(reinterpret_cast<uintptr_t>(game));
}

// A left press delivered to the engine's input handler: may it become a
// lookup?  Only a bare press on exactly one mapped glyph of the current
// model, in the foreground game window, with the host's native-input
// admission applied, no card shielding the game, and nothing on screen
// changed since the model was built.
// Which gate decided a press (diagnostics only; order = check order).
enum class Cs2PressGate : uint32_t {
  kEligible = 0u,
  kLookupOff,
  kNoModel,
  kOtherWindow,
  kFrameStale,
  kVersionStale,
  kInputNotAllowed,
  kShield,
  kNotForeground,
  kModifier,
  kClientSize,
  kOutsideDesign,
  kMiss,
};

Cs2PressGate Cs2PressGateFor(HWND hwnd, WPARAM wparam, LPARAM lparam,
                             Cs2Submit* submit) {
  auto& rt = g_cs2_lookup;
  if (!rt.live.load(std::memory_order_acquire) || g_header == nullptr ||
      g_stop || !fushi_voice_hook::HasLookupRegion(g_header) ||
      fushi_voice_hook::AtomicLoadShared32(&g_header->lookup_enabled) == 0u) {
    return Cs2PressGate::kLookupOff;
  }
  Cs2Model& model = rt.input_model;
  if (!ReadCs2Model(&model) || model.generation == 0u || model.count == 0u) {
    return Cs2PressGate::kNoModel;
  }
  if (reinterpret_cast<uintptr_t>(hwnd) != model.window) {
    return Cs2PressGate::kOtherWindow;
  }
  const uint64_t now = GetTickCount64();
  const uint64_t frame = rt.last_frame_tick.load(std::memory_order_acquire);
  if (frame == 0u || now < frame || now - frame > kCs2FrameStaleMs) {
    return Cs2PressGate::kFrameStale;
  }
  if (rt.latest_version.load(std::memory_order_acquire) !=
      model.snapshot_version) {
    return Cs2PressGate::kVersionStale;
  }
  if (!fushi_voice_hook::g_geometry_provider_registry.NativeInputAllowed(
          g_header, fushi_voice_hook::kLookupGeometryProviderEngineExactLayout,
          fushi_voice_hook::kLookupGeometryProviderIdCatSystem2)) {
    return Cs2PressGate::kInputNotAllowed;
  }
  if (Cs2ShieldActive(hwnd)) return Cs2PressGate::kShield;
  if (GetForegroundWindow() != hwnd) return Cs2PressGate::kNotForeground;
  if ((wparam & (MK_SHIFT | MK_CONTROL | MK_RBUTTON | MK_MBUTTON)) != 0u ||
      (GetKeyState(VK_MENU) & 0x8000) != 0) {
    return Cs2PressGate::kModifier;
  }
  // On the window's own thread lparam and GetClientRect are the logical
  // client pixels the model measured under the window's DPI awareness.
  RECT client = {};
  if (!GetClientRect(hwnd, &client) ||
      client.right - client.left != model.logical_w ||
      client.bottom - client.top != model.logical_h) {
    return Cs2PressGate::kClientSize;
  }
  int32_t x = 0, y = 0;
  if (!cs2_lookup::ClientToDesign(
          static_cast<int16_t>(LOWORD(lparam)),
          static_cast<int16_t>(HIWORD(lparam)), model.logical_w,
          model.logical_h, model.design_w, model.design_h, &x, &y)) {
    return Cs2PressGate::kOutsideDesign;
  }
  auto& lines = rt.input_lines;
  uint32_t candidates = 0u;
  for (uint32_t index = 0u; index < model.count; ++index) {
    lines[index] = model.glyphs[index].line;
    const cs2_lookup::IntRect& r = lines[index].hit;
    if (!r.Empty() && x >= r.x0 && y >= r.y0 && x < r.x1 && y < r.y1) {
      ++candidates;
    }
  }
  rt.last_press_x.store(x, std::memory_order_relaxed);
  rt.last_press_y.store(y, std::memory_order_relaxed);
  rt.last_press_candidates.store(candidates, std::memory_order_relaxed);
  size_t hit = 0u;
  if (!cs2_lookup::HitTestLine(lines.data(), model.count, x, y, &hit)) {
    return Cs2PressGate::kMiss;
  }
  submit->generation = model.generation;
  submit->glyph = static_cast<uint32_t>(hit);
  return Cs2PressGate::kEligible;
}

bool Cs2PressEligible(HWND hwnd, WPARAM wparam, LPARAM lparam,
                      Cs2Submit* submit) {
  auto& rt = g_cs2_lookup;
  const Cs2PressGate gate = Cs2PressGateFor(hwnd, wparam, lparam, submit);
  rt.last_press_gate.store(static_cast<uint32_t>(gate),
                           std::memory_order_relaxed);
  rt.presses_seen.fetch_add(1u, std::memory_order_release);
  return gate == Cs2PressGate::kEligible;
}


// Message-thread claim shared by both Handle shapes: true = swallow.
bool Cs2ClaimSwallows(HWND hwnd, UINT message, WPARAM wparam, LPARAM lparam) {
  auto& rt = g_cs2_lookup;
  if (!rt.live.load(std::memory_order_acquire) ||
      (!cs2_lookup::NeedsEligibility(message) &&
       message != cs2_lookup::kMessageLeftUp)) {
    return false;
  }
  bool eligible = false;
  Cs2Submit submit;
  if (cs2_lookup::NeedsEligibility(message)) {
    __try {
      eligible = Cs2PressEligible(hwnd, wparam, lparam, &submit);
    } __except (EXCEPTION_EXECUTE_HANDLER) {
      eligible = false;
    }
  }
  const auto decision = cs2_lookup::DecideMessage(message, eligible, &rt.claim);
  if (decision.submit) {
    QueueCs2Submit(submit);
    rt.claimed_presses.fetch_add(1u, std::memory_order_relaxed);
  }
  return decision.swallow;
}

LRESULT __stdcall Cs2InputDetour(uintptr_t input, HWND hwnd, UINT message,
                                 WPARAM wparam, LPARAM lparam) {
  if (Cs2ClaimSwallows(hwnd, message, wparam, lparam)) return 0;
  return g_cs2_input_original(input, hwnd, message, wparam, lparam);
}

// Targeted-render layout: Handle takes one more stack argument (`ret 0x18`);
// it is forwarded untouched.
LRESULT __stdcall Cs2InputExtraDetour(uintptr_t input, HWND hwnd,
                                      UINT message, WPARAM wparam,
                                      LPARAM lparam, uintptr_t extra) {
  if (Cs2ClaimSwallows(hwnd, message, wparam, lparam)) return 0;
  return g_cs2_input_extra_original(input, hwnd, message, wparam, lparam,
                                    extra);
}

// ── HookWorker ─────────────────────────────────────────────────────────────

// Worker-only, bounded diagnostics in %TEMP%\fushi_galhook.log.  Never logs
// dialogue text.
void Cs2LookupLog(const wchar_t* format, ...) {
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

// Creates the four detours first and enables them in one MinHook
// transaction.  All or nothing: a target someone else already hooked, or any
// MinHook failure, installs none.
bool InstallCs2HooksBatched(const cs2_lookup::Sites& sites) {
  struct Site {
    void* target;
    void* detour;
    void** original;
  };
  const Site plan[] = {
      {reinterpret_cast<void*>(sites.clear_page),
       reinterpret_cast<void*>(&Cs2ClearDetour),
       reinterpret_cast<void**>(&g_cs2_clear_original)},
      sites.render_stack_args == cs2_lookup::kRenderTStackArgs
          ? Site{reinterpret_cast<void*>(sites.render_char),
                 reinterpret_cast<void*>(&Cs2RenderTargetDetour),
                 reinterpret_cast<void**>(&g_cs2_render_target_original)}
          : Site{reinterpret_cast<void*>(sites.render_char),
                 reinterpret_cast<void*>(&Cs2RenderDetour),
                 reinterpret_cast<void**>(&g_cs2_render_original)},
      {reinterpret_cast<void*>(sites.window_update),
       reinterpret_cast<void*>(&Cs2UpdateDetour),
       reinterpret_cast<void**>(&g_cs2_update_original)},
      sites.input_stack_args == cs2_lookup::kInputTStackArgs
          ? Site{reinterpret_cast<void*>(sites.input_handler),
                 reinterpret_cast<void*>(&Cs2InputExtraDetour),
                 reinterpret_cast<void**>(&g_cs2_input_extra_original)}
          : Site{reinterpret_cast<void*>(sites.input_handler),
                 reinterpret_cast<void*>(&Cs2InputDetour),
                 reinterpret_cast<void**>(&g_cs2_input_original)},
  };
  constexpr int kSites = static_cast<int>(sizeof(plan) / sizeof(plan[0]));
  if (!g_cs_ready ||
      (sites.render_stack_args != 1u &&
       sites.render_stack_args != cs2_lookup::kRenderTStackArgs) ||
      (sites.input_stack_args != cs2_lookup::kInputStackArgs &&
       sites.input_stack_args != cs2_lookup::kInputTStackArgs)) {
    return false;
  }
  EnterCriticalSection(&g_cs);
  bool ok = g_hooked_count + kSites <= 64;
  for (int i = 0; ok && i < g_hooked_count; ++i) {
    for (const Site& site : plan) ok = ok && g_hooked_fns[i] != site.target;
  }
  int created = 0;
  for (; ok && created < kSites; ++created) {
    const Site& site = plan[created];
    if (site.target == nullptr ||
        MH_CreateHook(site.target, site.detour, site.original) != MH_OK) {
      ok = false;
      break;
    }
  }
  for (int i = 0; ok && i < kSites; ++i) {
    ok = MH_QueueEnableHook(plan[i].target) == MH_OK;
  }
  ok = ok && MH_ApplyQueued() == MH_OK;
  if (ok) {
    for (const Site& site : plan) g_hooked_fns[g_hooked_count++] = site.target;
  } else {
    for (int i = 0; i < created; ++i) MH_RemoveHook(plan[i].target);
    for (const Site& site : plan) *site.original = nullptr;
  }
  LeaveCriticalSection(&g_cs);
  return ok;
}

bool InstallCatSystem2Lookup() {
  auto& rt = g_cs2_lookup;
  if (rt.installed) return true;
  if (rt.resolved) {
    // Re-install after a shutdown: the detours are still chained and only
    // need to start recording again.  A rejected image stays rejected.
    if (!rt.hooks_installed) return false;
    rt.claim = cs2_lookup::ClaimState();
    rt.live.store(true, std::memory_order_release);
    rt.installed = true;
    return true;
  }
  rt.resolved = true;
  LARGE_INTEGER frequency = {}, started = {}, finished = {};
  QueryPerformanceFrequency(&frequency);
  QueryPerformanceCounter(&started);
  fushi_voice_hook::exact_lookup::LoadedPeImage image;
  cs2_lookup::ImportSlots imports;
  if (!fushi_voice_hook::exact_lookup::OpenLoadedPeImage(
          GetModuleHandleW(nullptr), &image)) {
    rt.site_result = cs2_lookup::SiteResult::kPageMissing;
  } else {
    imports.get_glyph_outline =
        cs2_lookup::FindImportSlotRva(image, "gdi32.dll", "GetGlyphOutlineA");
    imports.set_capture =
        cs2_lookup::FindImportSlotRva(image, "user32.dll", "SetCapture");
    imports.release_capture =
        cs2_lookup::FindImportSlotRva(image, "user32.dll", "ReleaseCapture");
    imports.window_from_point =
        cs2_lookup::FindImportSlotRva(image, "user32.dll", "WindowFromPoint");
    imports.get_foreground_window = cs2_lookup::FindImportSlotRva(
        image, "user32.dll", "GetForegroundWindow");
    rt.site_result = cs2_lookup::ResolveSites(image, imports, &rt.sites);
  }
  QueryPerformanceCounter(&finished);
  const double scan_ms =
      frequency.QuadPart > 0
          ? 1000.0 * static_cast<double>(finished.QuadPart - started.QuadPart) /
                static_cast<double>(frequency.QuadPart)
          : 0.0;
  if (rt.site_result != cs2_lookup::SiteResult::kResolved) {
    Cs2LookupLog(L"catsystem2-lookup: sites unresolved result=%u scan=%.1fms",
                 static_cast<unsigned>(rt.site_result), scan_ms);
    return false;
  }
  const uintptr_t base = reinterpret_cast<uintptr_t>(image.base);
  rt.tracker.Clear();
  rt.published_version = UINT64_MAX;
  rt.claim = cs2_lookup::ClaimState();
  rt.game_thread = 0u;
  // Detours read `live` before touching any state; publish the state first.
  rt.live.store(true, std::memory_order_release);
  const bool hooked = InstallCs2HooksBatched(rt.sites);
  rt.hooks_installed = hooked;
  rt.installed = hooked;
  if (!rt.installed) rt.live.store(false, std::memory_order_release);
  Cs2LookupLog(
      L"catsystem2-lookup: sites variant=%u clear=+0x%lx render=+0x%lx "
      L"update=+0x%lx input=+0x%lx charimage=+0x%lx raster=+0x%lx hooks=%d "
      L"scan=%.1fms",
      static_cast<unsigned>(rt.sites.variant),
      static_cast<unsigned long>(rt.sites.clear_page - base),
      static_cast<unsigned long>(rt.sites.render_char - base),
      static_cast<unsigned long>(rt.sites.window_update - base),
      static_cast<unsigned long>(rt.sites.input_handler - base),
      static_cast<unsigned long>(rt.sites.char_image - base),
      static_cast<unsigned long>(rt.sites.rasteriser - base), hooked ? 1 : 0,
      scan_ms);
  if (rt.installed && g_header != nullptr) {
    fushi_voice_hook::AtomicOrShared32(
        &g_header->lookup_diag, fushi_voice_hook::kLookupDiagSensorInstalled);
  }
  return rt.installed;
}

void RetireCs2Lookup() {
  auto& rt = g_cs2_lookup;
  InvalidateCs2Model();
  rt.model.generation = 0u;
  rt.model.count = 0u;
  rt.model_line.clear();
  rt.model_text_event = 0u;
  if (!rt.provider_offered) return;
  rt.provider_offered = false;
  if (g_header != nullptr) {
    fushi_voice_hook::g_geometry_provider_registry.Retire(
        g_header, fushi_voice_hook::kLookupGeometryProviderEngineExactLayout,
        fushi_voice_hook::kLookupGeometryProviderIdCatSystem2);
  }
}

struct Cs2DpiScope {
  explicit Cs2DpiScope(DPI_AWARENESS_CONTEXT context)
      : previous(SetThreadDpiAwarenessContext(context)) {}
  ~Cs2DpiScope() {
    if (previous != nullptr) SetThreadDpiAwarenessContext(previous);
  }
  DPI_AWARENESS_CONTEXT previous;
};

// Diagnostic detail of the last model-build failure (worker only).
struct Cs2ModelFailure {
  // 1 window 2 dpi 3 client aspect 4 no match 5 ambiguous 6 projection
  uint32_t step = 0u;
  int32_t a = 0, b = 0, c = 0, d = 0;
};
Cs2ModelFailure g_cs2_model_failure;

bool FailCs2Model(uint32_t step, int32_t a = 0, int32_t b = 0, int32_t c = 0,
                  int32_t d = 0) {
  g_cs2_model_failure = {step, a, b, c, d};
  return false;
}

// Builds the candidate model from the newest snapshot and the selected line.
bool BuildCs2Model(const Cs2Snapshot& snapshot, const std::wstring& line,
                   Cs2Model* model, uint32_t* first_glyph) {
  auto& rt = g_cs2_lookup;
  const HWND game =
      reinterpret_cast<HWND>(static_cast<uintptr_t>(snapshot.window));
  DWORD pid = 0;
  if (game == nullptr || !IsWindow(game) ||
      GetWindowThreadProcessId(game, &pid) == 0 ||
      pid != GetCurrentProcessId() || !IsWindowVisible(game) ||
      IsIconic(game)) {
    return FailCs2Model(1u);
  }
  // "Logical" is what the window's own thread sees (lparam and GetClientRect
  // in Handle): measured under the window's DPI awareness.  Older builds are
  // DPI-unaware, later ones declare awareness themselves.
  RECT logical = {};
  RECT physical = {};
  {
    const DPI_AWARENESS_CONTEXT window_context =
        GetWindowDpiAwarenessContext(game);
    if (window_context == nullptr) return FailCs2Model(2u);
    Cs2DpiScope own(window_context);
    if (own.previous == nullptr || !GetClientRect(game, &logical)) {
      return FailCs2Model(2u);
    }
  }
  {
    Cs2DpiScope aware(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
    if (aware.previous == nullptr || !GetClientRect(game, &physical)) {
      return FailCs2Model(2u);
    }
  }
  const int32_t logical_w = logical.right - logical.left;
  const int32_t logical_h = logical.bottom - logical.top;
  const int32_t physical_w = physical.right - physical.left;
  const int32_t physical_h = physical.bottom - physical.top;
  // The back buffer is stretched over the whole client: any other aspect
  // means letterboxing or a transient size, not a projection we can prove.
  if (!cs2_lookup::ClientMatchesDesign(logical_w, logical_h, snapshot.design_w,
                                       snapshot.design_h) ||
      !cs2_lookup::ClientMatchesDesign(physical_w, physical_h,
                                       snapshot.design_w, snapshot.design_h)) {
    return FailCs2Model(3u, snapshot.design_w, snapshot.design_h, logical_w,
                        logical_h);
  }

  // Exactly one surface's visible glyphs must end with the line; a spoken
  // line's trailing speaker tag is on the name layer, so the text page ends
  // with its body (a prefix of the line: source indices stay valid).
  const Cs2SnapshotSurface* matched = nullptr;
  size_t matched_first = 0u;
  size_t matched_units = line.size();
  const size_t body = cs2_lookup::SpeakerTagStart(line.data(), line.size());
  for (const size_t units : {line.size(), body}) {
    if (matched != nullptr || (units == body && body == line.size())) break;
    for (uint32_t index = 0u; index < snapshot.surface_count; ++index) {
      const Cs2SnapshotSurface& surface = snapshot.surfaces[index];
      if (surface.count == 0u || surface.first > snapshot.glyph_count ||
          surface.count > snapshot.glyph_count - surface.first ||
          surface.count > rt.match_scratch.size()) {
        continue;
      }
      std::copy_n(snapshot.glyphs.data() + surface.first, surface.count,
                  rt.match_scratch.data());
      const size_t first = cs2_lookup::MapSelectedSuffix(
          rt.match_scratch.data(), surface.count, line.data(), units);
      if (first >= surface.count) continue;
      if (matched != nullptr) return FailCs2Model(5u);  // ambiguous
      matched = &surface;
      matched_first = first;
      matched_units = units;
    }
  }
  if (matched == nullptr) {
    return FailCs2Model(4u, static_cast<int32_t>(snapshot.surface_count),
                        static_cast<int32_t>(snapshot.glyph_count),
                        static_cast<int32_t>(line.size()),
                        static_cast<int32_t>(body));
  }
  std::copy_n(snapshot.glyphs.data() + matched->first, matched->count,
              rt.match_scratch.data());
  cs2_lookup::MapSelectedSuffix(rt.match_scratch.data(), matched->count,
                                line.data(), matched_units);

  model->snapshot_version = snapshot.version;
  model->window = snapshot.window;
  model->renderer = matched->renderer;
  model->design_w = snapshot.design_w;
  model->design_h = snapshot.design_h;
  model->logical_w = logical_w;
  model->logical_h = logical_h;
  model->physical_w = physical_w;
  model->physical_h = physical_h;
  model->count = 0u;
  for (size_t index = matched_first; index < matched->count; ++index) {
    const auto& glyph = rt.match_scratch[index];
    if (glyph.source_index == cs2_lookup::kNoSource) continue;
    Cs2ModelGlyph& out = model->glyphs[model->count];
    // Every mapped glyph must project into the client: a partially visible
    // line is not a line the user can be looking at.
    if (!cs2_lookup::ProjectCell(glyph, snapshot.design_w, snapshot.design_h,
                                 physical_w, physical_h, &out.rect)) {
      return FailCs2Model(6u, glyph.x, glyph.y, physical_w, physical_h);
    }
    out.line = glyph;
    ++model->count;
  }
  *first_glyph = static_cast<uint32_t>(matched_first);
  return model->count != 0u;
}

bool SameCs2ModelGeometry(const Cs2Model& left, const Cs2Model& right) {
  if (left.window != right.window || left.renderer != right.renderer ||
      left.snapshot_version != right.snapshot_version ||
      left.design_w != right.design_w || left.design_h != right.design_h ||
      left.logical_w != right.logical_w || left.logical_h != right.logical_h ||
      left.physical_w != right.physical_w ||
      left.physical_h != right.physical_h || left.count != right.count) {
    return false;
  }
  for (uint32_t index = 0u; index < left.count; ++index) {
    const auto& a = left.glyphs[index];
    const auto& b = right.glyphs[index];
    if (a.rect.x != b.rect.x || a.rect.y != b.rect.y || a.rect.w != b.rect.w ||
        a.rect.h != b.rect.h || a.line.x != b.line.x || a.line.y != b.line.y ||
        a.line.hit.x0 != b.line.hit.x0 || a.line.hit.y0 != b.line.hit.y0 ||
        a.line.hit.x1 != b.line.hit.x1 || a.line.hit.y1 != b.line.hit.y1 ||
        a.line.source_index != b.line.source_index ||
        a.line.source_length != b.line.source_length) {
      return false;
    }
  }
  return true;
}

bool PublishCs2LookupHit(const Cs2Submit& submit) {
  auto& rt = g_cs2_lookup;
  const Cs2Model& model = rt.model;
  if (g_header == nullptr || submit.generation == 0u ||
      submit.generation != model.generation || submit.glyph >= model.count ||
      rt.model_line.empty()) {
    return false;
  }
  const auto& glyph = model.glyphs[submit.glyph];
  const size_t units = rt.model_line.size();
  if (glyph.line.source_index == cs2_lookup::kNoSource ||
      glyph.line.source_length == 0u || glyph.line.source_index >= units ||
      glyph.line.source_length > units - glyph.line.source_index ||
      fushi_voice_hook::LookupUtf16SourceLength(
          rt.model_line.data(), static_cast<uint32_t>(units),
          glyph.line.source_index) != glyph.line.source_length) {
    return false;
  }
  const int required = WideCharToMultiByte(
      CP_UTF8, WC_ERR_INVALID_CHARS, rt.model_line.data(),
      static_cast<int>(units), nullptr, 0, nullptr, nullptr);
  if (required <= 0 ||
      static_cast<uint32_t>(required) > fushi_voice_hook::kLookupLineBytes) {
    return false;
  }
  char utf8[fushi_voice_hook::kLookupLineBytes] = {};
  if (WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, rt.model_line.data(),
                          static_cast<int>(units), utf8, required, nullptr,
                          nullptr) != required) {
    return false;
  }
  fushi_voice_hook::LookupGeometryHitPublication publication;
  publication.provider_kind =
      fushi_voice_hook::kLookupGeometryProviderEngineExactLayout;
  publication.provider_id =
      fushi_voice_hook::kLookupGeometryProviderIdCatSystem2;
  publication.char_index = glyph.line.source_index;
  publication.source_length = glyph.line.source_length;
  publication.char_count = static_cast<uint32_t>(units);
  publication.coordinate_space =
      fushi_voice_hook::kLookupCoordinateSpaceClientPhysicalPixels;
  publication.writing_mode = fushi_voice_hook::kLookupWritingModeHorizontal;
  publication.text_generation = rt.model_text_event;
  publication.geometry_generation = model.generation;
  publication.glyph_x = glyph.rect.x;
  publication.glyph_y = glyph.rect.y;
  publication.glyph_w = glyph.rect.w;
  publication.glyph_h = glyph.rect.h;
  publication.view_w = model.physical_w;
  publication.view_h = model.physical_h;
  publication.flags = fushi_voice_hook::kLookupHitFlagSubmit;
  publication.line_utf8 = reinterpret_cast<const uint8_t*>(utf8);
  publication.line_bytes = static_cast<uint32_t>(required);
  const bool published =
      fushi_voice_hook::g_geometry_provider_registry.PublishHit(g_header,
                                                                publication);
  Cs2LookupLog(
      L"catsystem2-lookup: hit gen=%llu glyph=%u char=%u+%u rect=%d,%d %dx%d "
      L"design=%d,%d %dx%d view=%dx%d published=%d",
      static_cast<unsigned long long>(model.generation), submit.glyph,
      glyph.line.source_index, glyph.line.source_length, glyph.rect.x,
      glyph.rect.y, glyph.rect.w, glyph.rect.h, glyph.line.x, glyph.line.y,
      glyph.line.w, glyph.line.h, model.physical_w, model.physical_h,
      published ? 1 : 0);
  return published;
}

bool ReadLatestCs2Submit(Cs2Submit* out) {
  auto& rt = g_cs2_lookup;
  const uint64_t sequence = rt.submit_count.load(std::memory_order_acquire);
  if (sequence == 0u || sequence == rt.processed_submit_seq) return false;
  rt.processed_submit_seq = sequence;
  auto& slot_seq = rt.submit_seq[sequence % kCs2SubmitSlots];
  if (slot_seq.load(std::memory_order_acquire) != sequence) return false;
  std::atomic_thread_fence(std::memory_order_acquire);
  *out = rt.submits[sequence % kCs2SubmitSlots];
  std::atomic_thread_fence(std::memory_order_acquire);
  return slot_seq.load(std::memory_order_acquire) == sequence;
}

// Worker: one line per new press so a press without a card names its gate.
void NoteCs2Presses() {
  static uint32_t logged = 0u;
  static uint32_t budget = 64u;
  auto& rt = g_cs2_lookup;
  const uint32_t seen = rt.presses_seen.load(std::memory_order_acquire);
  if (seen == logged || budget == 0u) return;
  logged = seen;
  --budget;
  static const wchar_t* const kGates[] = {
      L"eligible", L"lookup-off", L"no-model", L"other-window",
      L"frame-stale", L"version-stale", L"input-not-allowed", L"shield",
      L"not-foreground", L"modifier", L"client-size", L"outside-design",
      L"miss"};
  const uint32_t gate = rt.last_press_gate.load(std::memory_order_relaxed);
  Cs2LookupLog(
      L"catsystem2-lookup: press seen=%u gate=%s claimed=%llu design=%d,%d "
      L"candidates=%u",
      seen, gate < 13u ? kGates[gate] : L"?",
      static_cast<unsigned long long>(rt.claimed_presses.load()),
      rt.last_press_x.load(std::memory_order_relaxed),
      rt.last_press_y.load(std::memory_order_relaxed),
      rt.last_press_candidates.load(std::memory_order_relaxed));
}

// Why the last tick retired (0 = offered).  Logged once per change so a
// silent provider always says which gate it is waiting on.
void NoteCs2Retire(uint32_t reason) {
  static uint32_t last = UINT32_MAX;
  static uint32_t budget = 32u;
  const uint32_t key = reason == 4u ? 100u + g_cs2_model_failure.step : reason;
  if (key == last || budget == 0u) return;
  last = key;
  --budget;
  static const wchar_t* const kNames[] = {
      L"offered", L"lookup-disabled", L"frame-stale", L"no-selected-text",
      L"model-unbuilt", L"offer-rejected"};
  auto& rt = g_cs2_lookup;
  if (reason == 4u || reason == 2u) {
    const auto& f = g_cs2_model_failure;
    const auto& t = rt.tracker.stats();
    Cs2LookupLog(
        L"catsystem2-lookup: gate=%s step=%u %d,%d,%d,%d render=%u update=%u "
        L"rec=%u args=%u bounds=%u clear=%u reset=%u placefail=%u last=%d,%d "
        L"page=%dx%d size=%d",
        kNames[reason], reason == 4u ? f.step : 0u, f.a, f.b, f.c, f.d,
        rt.render_hits.load(), rt.update_hits.load(), t.recorded,
        t.rejected_args, t.rejected_bounds, t.page_clears, t.page_resets,
        rt.placement_failures.load(), t.last_x, t.last_y, t.last_w, t.last_h,
        t.last_size);
    return;
  }
  Cs2LookupLog(L"catsystem2-lookup: gate=%s",
               reason < 6u ? kNames[reason] : L"?");
}

void ProcessCatSystem2LookupTick() {
  auto& rt = g_cs2_lookup;
  if (!rt.installed) return;
  NoteCs2Presses();
  if (g_stop || g_header == nullptr ||
      !fushi_voice_hook::HasLookupRegion(g_header) ||
      fushi_voice_hook::AtomicLoadShared32(&g_header->lookup_enabled) == 0u) {
    NoteCs2Retire(1u);
    RetireCs2Lookup();
    return;
  }
  fushi_voice_hook::AtomicOrShared32(
      &g_header->lookup_diag, fushi_voice_hook::kLookupDiagSensorInstalled);

  // The message window updates every frame while the game runs; a silent
  // window is a suspended, minimised or dying game, or no window at all.
  const uint64_t now = GetTickCount64();
  const uint64_t frame = rt.last_frame_tick.load(std::memory_order_acquire);
  Cs2Snapshot& snapshot = rt.snapshot_copy;
  if (frame == 0u || now < frame || now - frame > kCs2FrameStaleMs ||
      !ReadCs2Snapshot(&snapshot)) {
    NoteCs2Retire(2u);
    RetireCs2Lookup();
    return;
  }

  std::wstring line;
  uint64_t event = 0u;
  uint64_t thread = 0u;
  if (!fushi_voice_hook::ReadSelectedLookupText(
          g_header, &line, &event, &thread, cs2_lookup::kMaxSurfaceGlyphs)) {
    NoteCs2Retire(3u);
    RetireCs2Lookup();
    return;
  }
  Cs2Model candidate;
  uint32_t first_glyph = 0u;
  if (!BuildCs2Model(snapshot, line, &candidate, &first_glyph)) {
    NoteCs2Retire(4u);
    RetireCs2Lookup();
    return;
  }

  const bool same = rt.model.generation != 0u && rt.model_text_event == event &&
                    rt.model_line == line &&
                    SameCs2ModelGeometry(rt.model, candidate);
  if (!same) {
    candidate.generation = ++rt.next_generation;
    rt.model = candidate;
    rt.model_line = line;
    rt.model_text_event = event;
    PublishCs2Slot(rt.model_seq, rt.models, rt.published_model, rt.model,
                   Cs2ModelBytes(rt.model.count));
    if (rt.logged_models < kCs2ModelLogBudget) {
      ++rt.logged_models;
      const auto& first = rt.model.glyphs[0];
      const auto& last = rt.model.glyphs[rt.model.count - 1u];
      uint32_t clickable = 0u;
      for (uint32_t index = 0u; index < rt.model.count; ++index) {
        if (!rt.model.glyphs[index].line.hit.Empty()) ++clickable;
      }
      const auto& hit = first.line.hit;
      Cs2LookupLog(
          L"catsystem2-lookup: model gen=%llu event=%llu units=%u glyphs=%u "
          L"clickable=%u first_hit=%d,%d-%d,%d "
          L"skipped=%u first=%d,%d %dx%d (design %d,%d) last=%d,%d %dx%d "
          L"view=%dx%d client=%dx%d design=%dx%d",
          static_cast<unsigned long long>(rt.model.generation),
          static_cast<unsigned long long>(event),
          static_cast<unsigned>(line.size()), rt.model.count, clickable,
          hit.x0, hit.y0, hit.x1, hit.y1, first_glyph,
          first.rect.x, first.rect.y, first.rect.w, first.rect.h, first.line.x,
          first.line.y, last.rect.x, last.rect.y, last.rect.w, last.rect.h,
          rt.model.physical_w, rt.model.physical_h, rt.model.logical_w,
          rt.model.logical_h, rt.model.design_w, rt.model.design_h);
    }
  }
  if (fushi_voice_hook::g_geometry_provider_registry.OfferReady(
          g_header, fushi_voice_hook::kLookupGeometryProviderEngineExactLayout,
          fushi_voice_hook::kLookupGeometryProviderIdCatSystem2)) {
    if (!rt.provider_offered) {
      Cs2LookupLog(L"catsystem2-lookup: OfferReady gen=%llu glyphs=%u",
                   static_cast<unsigned long long>(rt.model.generation),
                   rt.model.count);
    }
    rt.provider_offered = true;
    fushi_voice_hook::AtomicOrShared32(
        &g_header->lookup_diag, fushi_voice_hook::kLookupDiagGeometryObserved);
    NoteCs2Retire(0u);
  } else {
    NoteCs2Retire(5u);
    RetireCs2Lookup();
    return;
  }

  Cs2Submit submit;
  if (ReadLatestCs2Submit(&submit)) (void)PublishCs2LookupHit(submit);
}

void ShutdownCatSystem2Lookup() {
  auto& rt = g_cs2_lookup;
  // The detours stay chained (MinHook owns them for the process lifetime);
  // clearing `live` turns each into a pure forwarder and drops any claim.
  rt.live.store(false, std::memory_order_release);
  rt.claim = cs2_lookup::ClaimState();
  RetireCs2Lookup();
  rt.installed = false;
}

bool CatSystem2LookupSensorInstalled() { return g_cs2_lookup.installed; }
bool CatSystem2LookupSitesRejected() {
  return g_cs2_lookup.resolved && !g_cs2_lookup.hooks_installed;
}

#else  // !_M_IX86

bool InstallCatSystem2Lookup() { return false; }
void ProcessCatSystem2LookupTick() {}
void ShutdownCatSystem2Lookup() {}
bool CatSystem2LookupSensorInstalled() { return false; }
bool CatSystem2LookupSitesRejected() { return false; }

#endif  // _M_IX86
