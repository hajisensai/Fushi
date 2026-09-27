// Unity (Mono runtime) in-game lookup runtime (EngineExactLayout /
// kLookupGeometryProviderIdUnityMono).  Engine facts, signatures and every
// decision rule live in unity_mono_lookup_core.h and are unit-tested; this
// file only binds them to MinHook, Win32, the Mono embedding API and the v19
// registry.
//
// Threads (Unity runs its player loop and its window procedure on one main
// thread):
//   * main thread, Message.FixedUpdate detour — after the framework placed
//     and revealed its glyph objects, samples every glyph through Unity's own
//     internal calls (active in hierarchy, renderer enabled, renderer world
//     bounds -> Camera.main WorldToScreenPoint, layer vs culling mask, scene
//     vs active scene) plus a bounded copy of Message.LastMes, and publishes
//     the snapshot when its fingerprint changed.  No allocation of our own,
//     no IO, no logging.
//   * main thread, Fungus SayDialog.LateUpdate detour (framework 2, instead
//     of FixedUpdate) — samples the dialog's UGUI story Text: its generator's
//     per-unit layout (UICharInfo / UILineInfo) of exactly the string it
//     shows, projected through the text transform and the root canvas, each
//     glyph tagged with its index in the tag-stripped text and hidden inside
//     an alpha-0 <color> span (the Writer's read-ahead).
//   * main thread, UnityWndClass window procedure (GWLP_WNDPROC subclass
//     installed from HookWorker) — a bare WM_LBUTTONDOWN / DBLCLK that lands
//     on a mapped glyph of the current model is swallowed together with its
//     WM_LBUTTONUP, so Unity's input manager never records the click.
//   * HookWorker — ProcessUnityMonoLookupTick: matches the selected text line
//     against LastMes of exactly one fresh Message instance, proves the
//     rendered structure equals that text, projects the visible glyphs to
//     physical client pixels, offers/retires the provider, publishes the
//     model the window procedure hit-tests against, and turns queued presses
//     into registry hits.
//
// Fail closed everywhere: an unresolved site installs nothing; a stale frame,
// a text mismatch, an ambiguous instance, a Unity screen that is not the
// client, a missing native-input admission or an open card retires the
// provider or refuses the click, and the click then reaches the game
// unchanged.

namespace umono_lookup = fushi_voice_hook::unity_mono_lookup;

constexpr uint32_t kUmModelSlots = 2u;
constexpr uint32_t kUmSubmitSlots = 8u;
constexpr uint64_t kUmFrameStaleMs = 250u;
constexpr uint64_t kUmSampleSpacingMs = 40u;
constexpr uint32_t kUmModelLogBudget = 24u;
constexpr wchar_t kUmGameWindowClass[] = L"UnityWndClass";

// Why the last sample of an instance produced no usable glyphs.
enum UmSampleFailure : uint32_t {
  kUmSampleOk = 0u,
  kUmSampleNoCamera = 1u,
  kUmSampleCameraTarget = 2u,
  kUmSampleNoText = 3u,
  kUmSampleTooLarge = 4u,
  kUmSampleFault = 5u,
  kUmSampleBadList = 6u,
  // Fungus / UGUI only.
  kUmSampleLayoutStale = 7u,   // generator laid out another string (1 frame)
  kUmSampleRichText = 8u,      // unclosed '<' or over-long raw string
  kUmSampleCanvas = 9u,        // no canvas, or a World Space root canvas
  kUmSampleFont = 10u,         // not a dynamic font (pixels-per-unit unknown)
  kUmSampleLayoutMismatch = 11u,  // UICharInfo count != raw units + 1
};

// Which framework produced an instance snapshot.
constexpr uint8_t kUmFrameworkMessage = 1u;  // Message.Mes per-glyph TextMesh
constexpr uint8_t kUmFrameworkFungus = 2u;   // Fungus SayDialog on UGUI Text

struct UmInstanceSnapshot {
  uintptr_t instance = 0u;
  uintptr_t text_object = 0u;  // the string object the glyphs were laid out from
  // Where that string lives (owner object + field offset): Message.LastMes,
  // or the Fungus story Text's m_Text.  A press re-reads it.
  uintptr_t text_owner = 0u;
  uint32_t text_offset = 0u;
  uint8_t framework = 0u;
  uint32_t failure = kUmSampleOk;
  int32_t screen_w = 0;
  int32_t screen_h = 0;
  uint32_t units = 0u;
  uint32_t lines = 0u;
  uint32_t glyph_count = 0u;
  uint32_t visible_count = 0u;
  std::array<uint16_t, umono_lookup::kMaxRenderedLines> line_glyphs{};
  std::array<wchar_t, umono_lookup::kMaxLineUnits> text{};
  std::array<umono_lookup::GlyphCell, umono_lookup::kMaxGlyphs> cells{};
  // Fungus: each glyph's index in `text` (framework 1 derives it from
  // line_glyphs instead).
  std::array<uint16_t, umono_lookup::kMaxGlyphs> sources{};
};

struct UmSnapshot {
  uint64_t version = 0u;
  std::array<UmInstanceSnapshot, umono_lookup::kInstanceSlots> instances{};
};

struct UmModelGlyph {
  umono_lookup::GlyphCell cell;  // Unity screen pixels
  umono_lookup::PixelRect rect;  // physical client pixels
  uint16_t source = umono_lookup::kNoSource;
};

struct UmModel {
  uint64_t generation = 0u;
  uint64_t snapshot_version = 0u;
  uintptr_t window = 0u;
  uintptr_t instance = 0u;
  uintptr_t text_object = 0u;
  uintptr_t text_owner = 0u;
  uint32_t text_offset = 0u;
  uint32_t slot = 0u;
  int32_t screen_w = 0;
  int32_t screen_h = 0;
  int32_t physical_w = 0;
  int32_t physical_h = 0;
  uint32_t count = 0u;
  std::array<UmModelGlyph, umono_lookup::kMaxGlyphs> glyphs{};
};

struct UmSubmit {
  uint64_t generation = 0u;
  uint32_t glyph = 0u;
};

struct UnityMonoLookupRuntime {
  // ── HookWorker-owned ──
  bool resolved = false;
  bool hooks_installed = false;
  bool installed = false;
  umono_lookup::SiteResolution site_result;
  bool provider_offered = false;
  uint64_t processed_submit_seq = 0u;
  uint64_t next_generation = 0u;
  uint32_t logged_models = 0u;
  UmModel model;
  std::wstring model_line;
  uint64_t model_text_event = 0u;
  UmSnapshot snapshot_copy;
  std::array<uint16_t, umono_lookup::kMaxGlyphs> source_scratch{};

  // ── resolved once, read everywhere ──
  uint8_t framework = 0u;  // kUmFramework*; 0 until a framework resolved
  umono_lookup::FungusSiteResolution fungus_result;
  umono_lookup::FungusSites fungus;
  umono_lookup::Sites sites;
  int (*string_length)(void*) = nullptr;
  const wchar_t* (*string_chars)(void*) = nullptr;
  uintptr_t (*array_length)(void*) = nullptr;
  char* (*array_addr)(void*, int32_t, uintptr_t) = nullptr;
  std::atomic<DWORD> main_thread{0u};

  // ── main-thread-owned ──
  umono_lookup::RichTextMap rich_text;  // Fungus sampler scratch
  UmSnapshot building;
  std::array<uint64_t, umono_lookup::kInstanceSlots> fingerprints{};
  std::array<uint64_t, umono_lookup::kInstanceSlots> last_sample_ms{};
  umono_lookup::ClaimState claim;
  UmModel input_model;  // scratch for the press-time model read

  // ── shared ──
  std::atomic<bool> live{false};
  std::array<std::atomic<uintptr_t>, umono_lookup::kInstanceSlots>
      slot_instance{};
  std::array<std::atomic<uint64_t>, umono_lookup::kInstanceSlots> slot_tick{};
  std::atomic<uint64_t> latest_version{0u};
  std::array<std::atomic<uint32_t>, 2u> snapshot_seq = {};
  std::array<UmSnapshot, 2u> snapshots = {};
  std::atomic<uint32_t> published_snapshot{UINT32_MAX};
  std::array<std::atomic<uint32_t>, kUmModelSlots> model_seq = {};
  std::array<UmModel, kUmModelSlots> models = {};
  std::atomic<uint32_t> published_model{UINT32_MAX};
  std::array<std::atomic<uint64_t>, kUmSubmitSlots> submit_seq = {};
  std::array<UmSubmit, kUmSubmitSlots> submits = {};
  std::atomic<uint64_t> submit_count{0u};
  std::atomic<uint64_t> claimed_presses{0u};
  std::atomic<uint32_t> fixed_hits{0u};
  std::atomic<uint32_t> sample_faults{0u};
  std::atomic<HWND> window{nullptr};
  std::atomic<WNDPROC> original_proc{nullptr};
  std::atomic<bool> subclass_live{false};
};

UnityMonoLookupRuntime g_um_lookup;
using UmFixedUpdateFn = void(FUSHI_MONO_MANAGED_CALL*)(void*);
UmFixedUpdateFn g_um_fixed_update_original = nullptr;
// Fungus: SayDialog.LateUpdate (same managed shape: instance, no argument).
UmFixedUpdateFn g_um_late_update_original = nullptr;

// ── two-slot seqlocks ──────────────────────────────────────────────────────

template <typename T, size_t Slots>
void PublishUmSlot(std::array<std::atomic<uint32_t>, Slots>& seqs,
                   std::array<T, Slots>& slots,
                   std::atomic<uint32_t>& published, const T& value) {
  const uint32_t current = published.load(std::memory_order_acquire);
  const uint32_t slot =
      current >= Slots ? 0u : static_cast<uint32_t>((current + 1u) % Slots);
  const uint32_t seq = seqs[slot].load(std::memory_order_relaxed);
  seqs[slot].store(seq | 1u, std::memory_order_release);
  std::atomic_thread_fence(std::memory_order_release);
  std::memcpy(&slots[slot], &value, sizeof(T));
  std::atomic_thread_fence(std::memory_order_release);
  seqs[slot].store((seq | 1u) + 1u, std::memory_order_release);
  published.store(slot, std::memory_order_release);
}

template <typename T, size_t Slots>
bool ReadUmSlot(const std::array<std::atomic<uint32_t>, Slots>& seqs,
                const std::array<T, Slots>& slots,
                const std::atomic<uint32_t>& published, T* out) {
  const uint32_t slot = published.load(std::memory_order_acquire);
  if (out == nullptr || slot >= Slots) return false;
  const uint32_t before = seqs[slot].load(std::memory_order_acquire);
  if (before == 0u || (before & 1u) != 0u) return false;
  std::atomic_thread_fence(std::memory_order_acquire);
  std::memcpy(out, &slots[slot], sizeof(T));
  std::atomic_thread_fence(std::memory_order_acquire);
  return seqs[slot].load(std::memory_order_acquire) == before &&
         published.load(std::memory_order_acquire) == slot;
}

void InvalidateUmModel() {
  g_um_lookup.published_model.store(UINT32_MAX, std::memory_order_release);
}

template <typename T>
bool ReadUmValue(uintptr_t address, T* out) {
  if (address == 0u || out == nullptr) return false;
  __try {
    std::memcpy(out, reinterpret_cast<const void*>(address), sizeof(T));
  } __except (EXCEPTION_EXECUTE_HANDLER) {
    return false;
  }
  return true;
}

// ── main thread: glyph sampling ─────────────────────────────────────────────

bool UmObjectAlive(uintptr_t object) {
  uintptr_t cached = 0u;
  return object != 0u &&
         ReadUmValue(object + g_um_lookup.sites.cached_ptr_offset, &cached) &&
         cached != 0u;
}

// Reads List`1 {_items, _size}; returns the element count (bounded) and the
// backing array.
bool ReadUmList(uintptr_t list, uintptr_t* items, uint32_t* size,
                uint32_t bound) {
  auto& rt = g_um_lookup;
  int32_t count = 0;
  if (list == 0u || !ReadUmValue(list + rt.sites.list_items_offset, items) ||
      !ReadUmValue(list + rt.sites.list_size_offset, &count) || *items == 0u ||
      count < 0 || static_cast<uint32_t>(count) > bound ||
      rt.array_length(reinterpret_cast<void*>(*items)) <
          static_cast<uintptr_t>(count)) {
    return false;
  }
  *size = static_cast<uint32_t>(count);
  return true;
}

uintptr_t UmArrayElement(uintptr_t array, uint32_t index) {
  uintptr_t value = 0u;
  const char* address = g_um_lookup.array_addr(
      reinterpret_cast<void*>(array), static_cast<int32_t>(sizeof(void*)),
      index);
  return ReadUmValue(reinterpret_cast<uintptr_t>(address), &value) ? value
                                                                   : 0u;
}

// One glyph object -> its cell.  Engine calls only on objects whose native
// peer is alive (a destroyed object would raise a managed exception through
// this native frame).
void SampleUmGlyph(uintptr_t object, void* camera, bool orthographic,
                   int32_t mask, int32_t active_scene,
                   umono_lookup::GlyphCell* cell) {
  const auto& s = g_um_lookup.sites;
  using umono_lookup::Icall;
  *cell = umono_lookup::GlyphCell();
  if (!UmObjectAlive(object)) return;
  void* go = reinterpret_cast<void*>(object);
  const bool active =
      s.Get<umono_lookup::IcallInstanceBoolFn>(Icall::kGameObjectActive)(go);
  if (!active) return;
  void* renderer = s.Get<umono_lookup::IcallGetComponentFn>(
      Icall::kGameObjectGetComponent)(go, s.renderer_type);
  if (!UmObjectAlive(reinterpret_cast<uintptr_t>(renderer))) return;
  const bool enabled =
      s.Get<umono_lookup::IcallInstanceBoolFn>(Icall::kRendererEnabled)(
          renderer);
  int32_t scene = 0;
  s.Get<umono_lookup::IcallInstanceOutFn>(Icall::kGameObjectScene)(go, &scene);
  const int32_t layer =
      s.Get<umono_lookup::IcallInstanceIntFn>(Icall::kGameObjectLayer)(go);
  if (!umono_lookup::GlyphVisible(active, enabled, scene, active_scene, layer,
                                  mask)) {
    return;
  }
  umono_lookup::Bounds bounds;
  s.Get<umono_lookup::IcallInstanceOutFn>(Icall::kRendererBounds)(renderer,
                                                                   &bounds);
  const umono_lookup::Vec3 low = {bounds.center.x - bounds.extents.x,
                                  bounds.center.y - bounds.extents.y,
                                  bounds.center.z};
  const umono_lookup::Vec3 high = {bounds.center.x + bounds.extents.x,
                                   bounds.center.y + bounds.extents.y,
                                   bounds.center.z};
  umono_lookup::Vec3 a, b;
  const auto to_screen = s.Get<umono_lookup::IcallWorldToScreenFn>(
      Icall::kCameraWorldToScreen);
  to_screen(camera, &low, umono_lookup::kMonoEye, &a);
  to_screen(camera, &high, umono_lookup::kMonoEye, &b);
  if (umono_lookup::CellFromScreenCorners(a, b, orthographic, cell)) {
    cell->visible = 1u;
  }
}

// Fills `out` from the Message instance.  POD only (runs under __try).
uint32_t SampleUmInstance(uintptr_t self, UmInstanceSnapshot* out) {
  auto& rt = g_um_lookup;
  const auto& s = rt.sites;
  using umono_lookup::Icall;
  out->instance = self;
  out->framework = kUmFrameworkMessage;
  out->text_owner = self;
  out->text_offset = s.last_mes_offset;
  out->text_object = 0u;
  out->units = 0u;
  out->lines = 0u;
  out->glyph_count = 0u;
  out->visible_count = 0u;
  void* camera = s.Get<umono_lookup::IcallObjectFn>(Icall::kCameraMain)();
  if (!UmObjectAlive(reinterpret_cast<uintptr_t>(camera))) {
    return kUmSampleNoCamera;
  }
  if (s.Get<umono_lookup::IcallInstanceObjectFn>(Icall::kCameraTargetTexture)(
          camera) != nullptr) {
    return kUmSampleCameraTarget;  // renders into a texture, not the screen
  }
  const int32_t mask =
      s.Get<umono_lookup::IcallInstanceIntFn>(Icall::kCameraCullingMask)(
          camera);
  const bool orthographic =
      s.Get<umono_lookup::IcallInstanceBoolFn>(Icall::kCameraOrthographic)(
          camera);
  out->screen_w =
      s.Get<umono_lookup::IcallStaticIntFn>(Icall::kScreenWidth)();
  out->screen_h =
      s.Get<umono_lookup::IcallStaticIntFn>(Icall::kScreenHeight)();
  int32_t active_scene = 0;
  s.Get<umono_lookup::IcallStaticOutFn>(Icall::kActiveScene)(&active_scene);

  uintptr_t text = 0u, sprites = 0u;
  if (!ReadUmValue(self + s.last_mes_offset, &text) ||
      !ReadUmValue(self + s.message_sprite_offset, &sprites) || text == 0u) {
    return kUmSampleNoText;
  }
  const int length = rt.string_length(reinterpret_cast<void*>(text));
  const wchar_t* chars = rt.string_chars(reinterpret_cast<void*>(text));
  if (length <= 0 || chars == nullptr) return kUmSampleNoText;
  if (static_cast<size_t>(length) > umono_lookup::kMaxLineUnits) {
    return kUmSampleTooLarge;
  }
  std::memcpy(out->text.data(), chars,
              static_cast<size_t>(length) * sizeof(wchar_t));
  out->units = static_cast<uint32_t>(length);
  out->text_object = text;

  uintptr_t lines_array = 0u;
  uint32_t lines = 0u;
  if (!ReadUmList(sprites, &lines_array, &lines,
                  static_cast<uint32_t>(umono_lookup::kMaxRenderedLines))) {
    return kUmSampleBadList;
  }
  for (uint32_t line = 0u; line < lines; ++line) {
    uintptr_t glyphs_array = 0u;
    uint32_t glyphs = 0u;
    const uint32_t room =
        static_cast<uint32_t>(umono_lookup::kMaxGlyphs) - out->glyph_count;
    if (!ReadUmList(UmArrayElement(lines_array, line), &glyphs_array, &glyphs,
                    room)) {
      return kUmSampleBadList;
    }
    out->line_glyphs[line] = static_cast<uint16_t>(glyphs);
    for (uint32_t index = 0u; index < glyphs; ++index) {
      umono_lookup::GlyphCell& cell = out->cells[out->glyph_count++];
      SampleUmGlyph(UmArrayElement(glyphs_array, index), camera, orthographic,
                    mask, active_scene, &cell);
      if (cell.visible != 0u) ++out->visible_count;
    }
  }
  out->lines = lines;
  return kUmSampleOk;
}

// ── main thread: Fungus SayDialog on a UGUI Text ────────────────────────────

bool UmAlive(uintptr_t object, uint32_t cached_ptr_offset) {
  uintptr_t cached = 0u;
  return object != 0u && ReadUmValue(object + cached_ptr_offset, &cached) &&
         cached != 0u;
}

// Reads List`1 {_items, _size} with explicit offsets (List<UICharInfo> and
// List<UILineInfo> are different instantiations, each with its own layout).
bool ReadUmTypedList(uintptr_t list, uint32_t items_offset,
                     uint32_t size_offset, uint32_t bound, uintptr_t* items,
                     uint32_t* size) {
  int32_t count = 0;
  if (list == 0u || !ReadUmValue(list + items_offset, items) ||
      !ReadUmValue(list + size_offset, &count) || *items == 0u || count < 0 ||
      static_cast<uint32_t>(count) > bound ||
      g_um_lookup.array_length(reinterpret_cast<void*>(*items)) <
          static_cast<uintptr_t>(count)) {
    return false;
  }
  *size = static_cast<uint32_t>(count);
  return true;
}

// Fills `out` from one SayDialog.  POD + engine reads only (runs under
// __try); the only engine writes are the generator's own character / line
// lists, which UGUI's `characters` / `lines` getters fill the same way.
uint32_t SampleUmFungus(uintptr_t dialog, UmInstanceSnapshot* out) {
  auto& rt = g_um_lookup;
  const auto& f = rt.fungus;
  using umono_lookup::FungusIcall;
  out->instance = dialog;
  out->framework = kUmFrameworkFungus;
  out->text_owner = 0u;
  out->text_offset = f.text_string_offset;
  out->text_object = 0u;
  out->units = 0u;
  out->lines = 0u;
  out->glyph_count = 0u;
  out->visible_count = 0u;
  uintptr_t story = 0u, text = 0u, generator = 0u, laid_out = 0u;
  if (!ReadUmValue(dialog + f.story_text_offset, &story) ||
      !UmAlive(story, f.cached_ptr_offset) ||
      !ReadUmValue(story + f.text_string_offset, &text) || text == 0u) {
    return kUmSampleNoText;
  }
  out->text_owner = story;
  if (!ReadUmValue(story + f.text_cache_offset, &generator) ||
      generator == 0u ||
      !ReadUmValue(generator + f.generator_last_offset, &laid_out)) {
    return kUmSampleBadList;
  }
  // The layout lags the assignment by a frame while the Writer types.
  if (laid_out != text) return kUmSampleLayoutStale;
  const int raw_length = rt.string_length(reinterpret_cast<void*>(text));
  const wchar_t* raw = rt.string_chars(reinterpret_cast<void*>(text));
  if (raw_length <= 0 || raw == nullptr) return kUmSampleNoText;
  if (static_cast<size_t>(raw_length) > umono_lookup::kMaxLineUnits) {
    return kUmSampleTooLarge;
  }
  umono_lookup::RichTextMap& map = rt.rich_text;
  if (!umono_lookup::ParseRichText(raw, static_cast<size_t>(raw_length),
                                   &map)) {
    return kUmSampleRichText;
  }
  std::memcpy(out->text.data(), map.plain.data(),
              map.plain_length * sizeof(wchar_t));
  out->units = static_cast<uint32_t>(map.plain_length);

  void* story_object = reinterpret_cast<void*>(story);
  const bool active_and_enabled =
      f.Get<umono_lookup::IcallInstanceBoolFn>(
          FungusIcall::kBehaviourActiveAndEnabled)(story_object);
  uintptr_t renderer = 0u;
  bool culled = true;
  float inherited_alpha = 0.0f;
  if (ReadUmValue(story + f.graphic_renderer_offset, &renderer) &&
      UmAlive(renderer, f.cached_ptr_offset)) {
    void* renderer_object = reinterpret_cast<void*>(renderer);
    culled = f.Get<umono_lookup::IcallInstanceBoolFn>(
        FungusIcall::kCanvasRendererCull)(renderer_object);
    inherited_alpha = f.Get<umono_lookup::IcallInstanceFloatFn>(
        FungusIcall::kCanvasRendererInheritedAlpha)(renderer_object);
  }
  float color_alpha = 0.0f;
  ReadUmValue(story + f.graphic_color_alpha_offset, &color_alpha);
  const bool readable = umono_lookup::FungusTextReadable(
      active_and_enabled, culled, inherited_alpha, color_alpha);

  uintptr_t canvas = 0u;
  if (!ReadUmValue(story + f.graphic_canvas_offset, &canvas) ||
      !UmAlive(canvas, f.cached_ptr_offset)) {
    return kUmSampleCanvas;
  }
  void* root = f.Get<umono_lookup::IcallInstanceObjectFn>(
      FungusIcall::kCanvasRoot)(reinterpret_cast<void*>(canvas));
  if (!UmAlive(reinterpret_cast<uintptr_t>(root), f.cached_ptr_offset)) {
    return kUmSampleCanvas;
  }
  const int32_t mode = f.Get<umono_lookup::IcallInstanceIntFn>(
      FungusIcall::kCanvasRenderMode)(root);
  void* camera = nullptr;
  if (mode == umono_lookup::kRenderModeScreenSpaceCamera) {
    camera = f.Get<umono_lookup::IcallInstanceObjectFn>(
        FungusIcall::kCanvasWorldCamera)(root);
    // Screen Space - Camera without a camera renders as an overlay.
    if (!UmAlive(reinterpret_cast<uintptr_t>(camera), f.cached_ptr_offset)) {
      camera = nullptr;
    } else if (f.Get<umono_lookup::IcallInstanceObjectFn>(
                   FungusIcall::kCameraTargetTexture)(camera) != nullptr) {
      return kUmSampleCameraTarget;
    }
  } else if (mode != umono_lookup::kRenderModeScreenSpaceOverlay) {
    return kUmSampleCanvas;
  }
  uintptr_t font_data = 0u, font = 0u;
  if (!ReadUmValue(story + f.font_data_offset, &font_data) ||
      font_data == 0u ||
      !ReadUmValue(font_data + f.font_data_font_offset, &font) ||
      !UmAlive(font, f.cached_ptr_offset) ||
      !f.Get<umono_lookup::IcallInstanceBoolFn>(FungusIcall::kFontDynamic)(
          reinterpret_cast<void*>(font))) {
    return kUmSampleFont;
  }
  // Text.pixelsPerUnit of a dynamic font: the nearest canvas' scale factor.
  const float pixels_per_unit = f.Get<umono_lookup::IcallInstanceFloatFn>(
      FungusIcall::kCanvasScaleFactor)(reinterpret_cast<void*>(canvas));
  out->screen_w = f.Get<umono_lookup::IcallStaticIntFn>(
      FungusIcall::kScreenWidth)();
  out->screen_h = f.Get<umono_lookup::IcallStaticIntFn>(
      FungusIcall::kScreenHeight)();

  uintptr_t chars_list = 0u, lines_list = 0u;
  if (!ReadUmValue(generator + f.generator_chars_offset, &chars_list) ||
      !ReadUmValue(generator + f.generator_lines_offset, &lines_list) ||
      chars_list == 0u || lines_list == 0u) {
    return kUmSampleBadList;
  }
  void* generator_object = reinterpret_cast<void*>(generator);
  f.Get<umono_lookup::IcallInstanceArgFn>(FungusIcall::kGeneratorCharacters)(
      generator_object, reinterpret_cast<void*>(chars_list));
  f.Get<umono_lookup::IcallInstanceArgFn>(FungusIcall::kGeneratorLines)(
      generator_object, reinterpret_cast<void*>(lines_list));
  uintptr_t char_items = 0u, line_items = 0u;
  uint32_t char_count = 0u, line_count = 0u;
  if (!ReadUmTypedList(chars_list, f.char_list_items_offset,
                       f.char_list_size_offset,
                       static_cast<uint32_t>(umono_lookup::kMaxLineUnits) + 1u,
                       &char_items, &char_count) ||
      !ReadUmTypedList(lines_list, f.line_list_items_offset,
                       f.line_list_size_offset,
                       static_cast<uint32_t>(umono_lookup::kMaxRenderedLines),
                       &line_items, &line_count) ||
      line_count == 0u) {
    return kUmSampleBadList;
  }
  // One UICharInfo per raw unit plus the terminator, or the layout is not
  // the one of this string.
  if (char_count != static_cast<uint32_t>(raw_length) + 1u) {
    return kUmSampleLayoutMismatch;
  }
  const char* char_base = rt.array_addr(
      reinterpret_cast<void*>(char_items),
      static_cast<int32_t>(f.char_stride), 0u);
  const char* line_base = rt.array_addr(
      reinterpret_cast<void*>(line_items),
      static_cast<int32_t>(f.line_stride), 0u);
  if (char_base == nullptr || line_base == nullptr) return kUmSampleBadList;
  int32_t line_starts[umono_lookup::kMaxRenderedLines] = {};
  int32_t line_heights[umono_lookup::kMaxRenderedLines] = {};
  float line_tops[umono_lookup::kMaxRenderedLines] = {};
  for (uint32_t k = 0u; k < line_count; ++k) {
    const char* line = line_base + static_cast<size_t>(k) * f.line_stride;
    std::memcpy(&line_starts[k], line + f.line_start_offset, sizeof(int32_t));
    std::memcpy(&line_heights[k], line + f.line_height_offset,
                sizeof(int32_t));
    std::memcpy(&line_tops[k], line + f.line_top_offset, sizeof(float));
  }
  umono_lookup::Matrix4 to_world;
  void* transform = f.Get<umono_lookup::IcallInstanceObjectFn>(
      FungusIcall::kComponentTransform)(story_object);
  if (!UmAlive(reinterpret_cast<uintptr_t>(transform), f.cached_ptr_offset)) {
    return kUmSampleCanvas;
  }
  f.Get<umono_lookup::IcallInstanceOutFn>(FungusIcall::kTransformLocalToWorld)(
      transform, &to_world);
  const auto to_screen = f.Get<umono_lookup::IcallWorldToScreenFn>(
      FungusIcall::kCameraWorldToScreen);

  for (int32_t i = 0; i < raw_length; ++i) {
    const uint16_t source = map.raw_to_plain[static_cast<size_t>(i)];
    if (source == umono_lookup::kRawTag || raw[i] == L'\n' ||
        raw[i] == L'\r') {
      continue;
    }
    float cursor_x = 0.0f, width = 0.0f;
    const char* info = char_base + static_cast<size_t>(i) * f.char_stride;
    std::memcpy(&cursor_x, info + f.char_cursor_offset, sizeof(float));
    std::memcpy(&width, info + f.char_width_offset, sizeof(float));
    size_t line = 0u;
    umono_lookup::LocalCell local;
    if (!umono_lookup::LineOfUnit(line_starts, line_count,
                                  static_cast<size_t>(i), &line) ||
        !umono_lookup::GeneratorCell(cursor_x, width, line_tops[line],
                                     line_heights[line], pixels_per_unit,
                                     &local)) {
      continue;  // zero-width unit: nothing drawn, nothing to hit
    }
    if (out->glyph_count >= umono_lookup::kMaxGlyphs) return kUmSampleTooLarge;
    umono_lookup::Vec3 a = umono_lookup::TransformPoint(to_world, local.x0,
                                                        local.y0);
    umono_lookup::Vec3 b = umono_lookup::TransformPoint(to_world, local.x1,
                                                        local.y1);
    if (camera != nullptr) {
      umono_lookup::Vec3 sa, sb;
      to_screen(camera, &a, umono_lookup::kMonoEye, &sa);
      to_screen(camera, &b, umono_lookup::kMonoEye, &sb);
      a = sa;
      b = sb;
    }
    umono_lookup::GlyphCell& cell = out->cells[out->glyph_count];
    cell = umono_lookup::GlyphCell();
    // An overlay canvas has no view depth; a camera canvas sits in front of
    // its camera at the plane distance.
    if (umono_lookup::CellFromScreenCorners(a, b, camera == nullptr, &cell) &&
        readable && map.hidden[static_cast<size_t>(i)] == 0u) {
      cell.visible = 1u;
      ++out->visible_count;
    }
    out->sources[out->glyph_count] = source;
    ++out->glyph_count;
  }
  out->text_object = text;
  return kUmSampleOk;
}

using UmSampler = uint32_t (*)(uintptr_t, UmInstanceSnapshot*);

uint32_t SampleUmGuarded(UmSampler sampler, uintptr_t self,
                         UmInstanceSnapshot* out) {
  __try {
    return sampler(self, out);
  } __except (EXCEPTION_EXECUTE_HANDLER) {
    out->glyph_count = 0u;
    out->visible_count = 0u;
    return kUmSampleFault;
  }
}

uint64_t UmInstanceFingerprint(const UmInstanceSnapshot& instance) {
  uint64_t hash = umono_lookup::kFingerprintSeed;
  hash = umono_lookup::Fingerprint(hash, &instance.text_object,
                                   sizeof(instance.text_object));
  hash = umono_lookup::Fingerprint(hash, &instance.failure,
                                   sizeof(instance.failure));
  hash = umono_lookup::Fingerprint(hash, &instance.screen_w,
                                   2u * sizeof(int32_t));
  hash = umono_lookup::Fingerprint(hash, &instance.units,
                                   sizeof(instance.units));
  hash = umono_lookup::Fingerprint(
      hash, instance.text.data(), instance.units * sizeof(wchar_t));
  hash = umono_lookup::Fingerprint(
      hash, instance.line_glyphs.data(), instance.lines * sizeof(uint16_t));
  for (uint32_t i = 0u; i < instance.glyph_count; ++i) {
    const auto& cell = instance.cells[i];
    hash = umono_lookup::Fingerprint(hash, &cell.x0, 4u * sizeof(float));
    hash = umono_lookup::Fingerprint(hash, &cell.visible, 1u);
    hash = umono_lookup::Fingerprint(hash, &instance.sources[i],
                                     sizeof(uint16_t));
  }
  return hash;
}

// Per-frame sampling of one framework instance (main thread).  A new string
// (`current_text` differs from the last sample's) is sampled at once;
// otherwise the reveal is followed at the sampling spacing.
void UmSampleFrame(uintptr_t instance, bool text_known, uintptr_t current_text,
                   UmSampler sampler) {
  auto& rt = g_um_lookup;
  const uint64_t now = GetTickCount64();
  // Slot of this instance; a slot whose instance stopped updating for a
  // second is reused.
  size_t slot = umono_lookup::kInstanceSlots;
  for (size_t i = 0; i < umono_lookup::kInstanceSlots; ++i) {
    if (rt.slot_instance[i].load(std::memory_order_relaxed) == instance) {
      slot = i;
      break;
    }
  }
  if (slot == umono_lookup::kInstanceSlots) {
    for (size_t i = 0; i < umono_lookup::kInstanceSlots; ++i) {
      const uint64_t tick = rt.slot_tick[i].load(std::memory_order_relaxed);
      if (rt.slot_instance[i].load(std::memory_order_relaxed) == 0u ||
          now - tick > 1000u) {
        slot = i;
        break;
      }
    }
    if (slot == umono_lookup::kInstanceSlots) return;
    rt.slot_instance[slot].store(instance, std::memory_order_release);
    rt.last_sample_ms[slot] = 0u;
    rt.fingerprints[slot] = 0u;
  }
  UmInstanceSnapshot& target = rt.building.instances[slot];
  const bool text_changed = !text_known ||
                            current_text != target.text_object ||
                            target.instance != instance;
  if (!text_changed && now - rt.last_sample_ms[slot] < kUmSampleSpacingMs) {
    rt.slot_tick[slot].store(now, std::memory_order_release);
    return;
  }
  rt.last_sample_ms[slot] = now;
  target.failure = SampleUmGuarded(sampler, instance, &target);
  if (target.failure == kUmSampleFault) {
    rt.sample_faults.fetch_add(1u, std::memory_order_relaxed);
  }
  const uint64_t fingerprint = UmInstanceFingerprint(target);
  if (fingerprint != rt.fingerprints[slot]) {
    rt.fingerprints[slot] = fingerprint;
    rt.building.version = rt.latest_version.load(std::memory_order_relaxed) + 1u;
    PublishUmSlot(rt.snapshot_seq, rt.snapshots, rt.published_snapshot,
                  rt.building);
    rt.latest_version.store(rt.building.version, std::memory_order_release);
  }
  rt.slot_tick[slot].store(now, std::memory_order_release);
}

void FUSHI_MONO_MANAGED_CALL UmFixedUpdateDetour(void* self) {
  g_um_fixed_update_original(self);
  auto& rt = g_um_lookup;
  rt.fixed_hits.fetch_add(1u, std::memory_order_relaxed);
  if (!rt.live.load(std::memory_order_acquire) || self == nullptr ||
      GetCurrentThreadId() != rt.main_thread.load(std::memory_order_acquire)) {
    return;
  }
  const uintptr_t instance = reinterpret_cast<uintptr_t>(self);
  uintptr_t text = 0u;
  const bool known = ReadUmValue(instance + rt.sites.last_mes_offset, &text);
  UmSampleFrame(instance, known, text, &SampleUmInstance);
}

// Fungus: after SayDialog.LateUpdate (the Writer assigned this frame's text).
void FUSHI_MONO_MANAGED_CALL UmFungusLateUpdateDetour(void* self) {
  g_um_late_update_original(self);
  auto& rt = g_um_lookup;
  rt.fixed_hits.fetch_add(1u, std::memory_order_relaxed);
  if (!rt.live.load(std::memory_order_acquire) || self == nullptr ||
      GetCurrentThreadId() != rt.main_thread.load(std::memory_order_acquire)) {
    return;
  }
  const uintptr_t dialog = reinterpret_cast<uintptr_t>(self);
  uintptr_t story = 0u, text = 0u;
  const bool known =
      ReadUmValue(dialog + rt.fungus.story_text_offset, &story) &&
      story != 0u && ReadUmValue(story + rt.fungus.text_string_offset, &text);
  UmSampleFrame(dialog, known, text, &SampleUmFungus);
}

// ── main thread: window procedure ───────────────────────────────────────────

void QueueUmSubmit(const UmSubmit& submit) {
  auto& rt = g_um_lookup;
  const uint64_t sequence =
      rt.submit_count.load(std::memory_order_acquire) + 1u;
  auto& slot_seq = rt.submit_seq[sequence % kUmSubmitSlots];
  slot_seq.store(0u, std::memory_order_release);
  std::atomic_thread_fence(std::memory_order_release);
  rt.submits[sequence % kUmSubmitSlots] = submit;
  std::atomic_thread_fence(std::memory_order_release);
  slot_seq.store(sequence, std::memory_order_release);
  rt.submit_count.store(sequence, std::memory_order_release);
}

bool UmShieldActive(HWND game) {
  if (IsLookupOverlayInputShieldVisible()) return true;
  if (g_header == nullptr) return false;
  const auto request = fushi_voice_hook::ReadLookupShieldRequest(g_header);
  return request.valid && request.active_buttons != 0u &&
         request.target_hwnd ==
             static_cast<uint64_t>(reinterpret_cast<uintptr_t>(game));
}

// A left press delivered to the Unity window: may it become a lookup?  Only
// a bare press on exactly one mapped glyph of the current model, in the
// foreground game window, with the host's native-input admission applied, no
// card shielding the game, nothing sampled as changed since the model was
// built and the model's message still showing the same text.
bool UmPressEligible(HWND hwnd, WPARAM wparam, LPARAM lparam,
                     UmSubmit* submit) {
  auto& rt = g_um_lookup;
  if (!rt.live.load(std::memory_order_acquire) || g_header == nullptr ||
      g_stop || !fushi_voice_hook::HasLookupRegion(g_header) ||
      fushi_voice_hook::AtomicLoadShared32(&g_header->lookup_enabled) == 0u) {
    return false;
  }
  UmModel& model = rt.input_model;
  if (!ReadUmSlot(rt.model_seq, rt.models, rt.published_model, &model) ||
      model.generation == 0u || model.count == 0u ||
      model.slot >= umono_lookup::kInstanceSlots) {
    return false;
  }
  const uint64_t now = GetTickCount64();
  const uint64_t tick =
      rt.slot_tick[model.slot].load(std::memory_order_acquire);
  uintptr_t text = 0u;
  if (reinterpret_cast<uintptr_t>(hwnd) != model.window || tick == 0u ||
      now < tick || now - tick > kUmFrameStaleMs ||
      rt.slot_instance[model.slot].load(std::memory_order_acquire) !=
          model.instance ||
      rt.latest_version.load(std::memory_order_acquire) !=
          model.snapshot_version ||
      model.text_owner == 0u ||
      !ReadUmValue(model.text_owner + model.text_offset, &text) ||
      text != model.text_object ||
      !fushi_voice_hook::g_geometry_provider_registry.NativeInputAllowed(
          g_header, fushi_voice_hook::kLookupGeometryProviderEngineExactLayout,
          fushi_voice_hook::kLookupGeometryProviderIdUnityMono) ||
      UmShieldActive(hwnd) || GetForegroundWindow() != hwnd ||
      (wparam & (MK_SHIFT | MK_CONTROL | MK_RBUTTON | MK_MBUTTON)) != 0u ||
      (GetKeyState(VK_MENU) & 0x8000) != 0) {
    return false;
  }
  // lparam and GetClientRect here are in the window's own DPI context, the
  // grid Unity's Screen reports.
  RECT client = {};
  if (!GetClientRect(hwnd, &client) ||
      client.right - client.left != model.screen_w ||
      client.bottom - client.top != model.screen_h) {
    return false;
  }
  float x = 0.0f, y = 0.0f;
  if (!umono_lookup::ClientToScreenPoint(
          static_cast<int16_t>(LOWORD(lparam)),
          static_cast<int16_t>(HIWORD(lparam)), model.screen_w,
          model.screen_h, &x, &y)) {
    return false;
  }
  std::array<umono_lookup::GlyphCell, umono_lookup::kMaxGlyphs> cells;
  std::array<uint16_t, umono_lookup::kMaxGlyphs> sources;
  for (uint32_t index = 0u; index < model.count; ++index) {
    cells[index] = model.glyphs[index].cell;
    sources[index] = model.glyphs[index].source;
  }
  size_t hit = 0u;
  if (!umono_lookup::HitTestCells(cells.data(), sources.data(), model.count, x,
                                  y, &hit)) {
    return false;
  }
  submit->generation = model.generation;
  submit->glyph = static_cast<uint32_t>(hit);
  return true;
}

LRESULT CallUmOriginalProc(HWND hwnd, UINT message, WPARAM wparam,
                           LPARAM lparam) {
  const WNDPROC original =
      g_um_lookup.original_proc.load(std::memory_order_acquire);
  if (original == nullptr) return DefWindowProcW(hwnd, message, wparam, lparam);
  return CallWindowProcW(original, hwnd, message, wparam, lparam);
}

bool UmPressEligibleGuarded(HWND hwnd, WPARAM wparam, LPARAM lparam,
                            UmSubmit* submit) {
  __try {
    return UmPressEligible(hwnd, wparam, lparam, submit);
  } __except (EXCEPTION_EXECUTE_HANDLER) {
    return false;
  }
}

LRESULT CALLBACK UmLookupWindowProc(HWND hwnd, UINT message, WPARAM wparam,
                                    LPARAM lparam) {
  auto& rt = g_um_lookup;
  if (message == WM_NCDESTROY) {
    // The window goes away; HookWorker notices and re-binds to its successor.
    rt.subclass_live.store(false, std::memory_order_release);
    rt.window.store(nullptr, std::memory_order_release);
    InvalidateUmModel();
    return CallUmOriginalProc(hwnd, message, wparam, lparam);
  }
  if (rt.subclass_live.load(std::memory_order_acquire) &&
      rt.window.load(std::memory_order_acquire) == hwnd &&
      (umono_lookup::NeedsEligibility(message) ||
       message == umono_lookup::kMessageLeftUp)) {
    bool eligible = false;
    UmSubmit submit;
    if (umono_lookup::NeedsEligibility(message)) {
      eligible = UmPressEligibleGuarded(hwnd, wparam, lparam, &submit);
    }
    const auto decision =
        umono_lookup::DecideMessage(message, eligible, &rt.claim);
    if (decision.submit) {
      QueueUmSubmit(submit);
      rt.claimed_presses.fetch_add(1u, std::memory_order_relaxed);
    }
    if (decision.swallow) return 0;
  }
  return CallUmOriginalProc(hwnd, message, wparam, lparam);
}

// ── HookWorker ─────────────────────────────────────────────────────────────

// Worker-only, bounded diagnostics in %TEMP%\fushi_galhook.log.  Never logs
// dialogue text.
void UmLookupLog(const wchar_t* format, ...) {
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

HWND FindUmGameWindow() {
  const HWND candidate = fushi_voice_hook::FindGameMainWindow();
  if (candidate == nullptr) return nullptr;
  wchar_t class_name[64] = {};
  if (GetClassNameW(candidate, class_name,
                    static_cast<int>(std::size(class_name))) <= 0 ||
      lstrcmpW(class_name, kUmGameWindowClass) != 0) {
    return nullptr;
  }
  return candidate;
}

bool InstallUmSubclass(HWND window) {
  auto& rt = g_um_lookup;
  DWORD pid = 0;
  if (window == nullptr || !IsWindow(window) ||
      GetWindowThreadProcessId(window, &pid) == 0 ||
      pid != GetCurrentProcessId()) {
    return false;
  }
  SetLastError(0);
  const LONG_PTR previous = GetWindowLongPtrW(window, GWLP_WNDPROC);
  if (previous == 0) return false;
  if (previous == reinterpret_cast<LONG_PTR>(&UmLookupWindowProc)) {
    rt.window.store(window, std::memory_order_release);
    rt.subclass_live.store(true, std::memory_order_release);
    return true;
  }
  // The main thread can enter the procedure the instant the swap lands, so
  // every field it reads is published before SetWindowLongPtrW.
  rt.original_proc.store(reinterpret_cast<WNDPROC>(previous),
                         std::memory_order_release);
  rt.window.store(window, std::memory_order_release);
  SetLastError(0);
  const LONG_PTR swapped = SetWindowLongPtrW(
      window, GWLP_WNDPROC, reinterpret_cast<LONG_PTR>(&UmLookupWindowProc));
  if (swapped == 0 && GetLastError() != 0) {
    rt.window.store(nullptr, std::memory_order_release);
    return false;
  }
  if (swapped != previous) {
    rt.original_proc.store(reinterpret_cast<WNDPROC>(swapped),
                           std::memory_order_release);
  }
  rt.subclass_live.store(true, std::memory_order_release);
  return true;
}

void TeardownUmSubclass() {
  auto& rt = g_um_lookup;
  rt.subclass_live.store(false, std::memory_order_release);
  const HWND window = rt.window.exchange(nullptr, std::memory_order_acq_rel);
  InvalidateUmModel();
  if (window == nullptr || !IsWindow(window)) return;
  const WNDPROC original = rt.original_proc.load(std::memory_order_acquire);
  if (original != nullptr &&
      GetWindowLongPtrW(window, GWLP_WNDPROC) ==
          reinterpret_cast<LONG_PTR>(&UmLookupWindowProc)) {
    SetWindowLongPtrW(window, GWLP_WNDPROC,
                      reinterpret_cast<LONG_PTR>(original));
  }
  // original_proc stays set: an in-flight call may still chain through it.
}

fushi_voice_hook::unity_mono_lookup::MonoLookupApi LoadUnityMonoLookupApi(
    HMODULE runtime) {
  fushi_voice_hook::unity_mono_lookup::MonoLookupApi api;
  LoadMonoExport(runtime, "mono_class_get_field_from_name",
                 &api.class_get_field_from_name);
  LoadMonoExport(runtime, "mono_field_get_offset", &api.field_get_offset);
  LoadMonoExport(runtime, "mono_field_get_type", &api.field_get_type);
  LoadMonoExport(runtime, "mono_class_from_mono_type",
                 &api.class_from_mono_type);
  LoadMonoExport(runtime, "mono_class_get_element_class",
                 &api.class_get_element_class);
  LoadMonoExport(runtime, "mono_lookup_internal_call",
                 &api.lookup_internal_call);
  LoadMonoExport(runtime, "mono_method_get_flags", &api.method_get_flags);
  LoadMonoExport(runtime, "mono_class_get_type", &api.class_get_type);
  LoadMonoExport(runtime, "mono_type_get_object", &api.type_get_object);
  LoadMonoExport(runtime, "mono_gchandle_new", &api.gchandle_new);
  LoadMonoExport(runtime, "mono_type_is_byref", &api.type_is_byref);
  LoadMonoExport(runtime, "mono_array_length", &api.array_length);
  LoadMonoExport(runtime, "mono_array_addr_with_size",
                 &api.array_addr_with_size);
  return api;
}

// Called on HookWorker inside the text path's attach scope, after the text
// plan admitted the per-glyph message framework.  Resolves every site; the
// detour itself is installed by InstallUnityMonoLookupHooks after detach.
void* ResolveUnityMonoLookup(
    const fushi_voice_hook::MonoEmbeddingApi& api, HMODULE runtime,
    void* domain) {
  auto& rt = g_um_lookup;
  if (rt.resolved) return nullptr;
  rt.resolved = true;
  const auto lookup_api = LoadUnityMonoLookupApi(runtime);
  rt.site_result =
      umono_lookup::ResolveSites(api, lookup_api, domain, &rt.sites);
  if (rt.site_result.result != umono_lookup::SiteResult::kResolved) {
    return nullptr;
  }
  rt.framework = kUmFrameworkMessage;
  rt.string_length = api.string_length;
  rt.string_chars = api.string_chars;
  rt.array_length = lookup_api.array_length;
  rt.array_addr = lookup_api.array_addr_with_size;
  return api.compile_method(rt.sites.fixed_update);
}

// Fungus: same contract as ResolveUnityMonoLookup (HookWorker, inside the
// text path's attach scope, after the plan admitted SayDialog.DoSay).
// Returns the JIT entry of SayDialog.LateUpdate (nullptr: rejected).
void* ResolveUnityMonoFungusLookup(
    const fushi_voice_hook::MonoEmbeddingApi& api, HMODULE runtime) {
  auto& rt = g_um_lookup;
  if (rt.resolved) return nullptr;
  rt.resolved = true;
  const auto lookup_api = LoadUnityMonoLookupApi(runtime);
  umono_lookup::MonoValueSizeApi sizes;
  LoadMonoExport(runtime, "mono_class_value_size", &sizes.class_value_size);
  rt.fungus_result =
      umono_lookup::ResolveFungusSites(api, lookup_api, sizes, &rt.fungus);
  if (rt.fungus_result.result != umono_lookup::FungusSiteResult::kResolved) {
    return nullptr;
  }
  rt.framework = kUmFrameworkFungus;
  rt.string_length = api.string_length;
  rt.string_chars = api.string_chars;
  rt.array_length = lookup_api.array_length;
  rt.array_addr = lookup_api.array_addr_with_size;
  return api.compile_method(rt.fungus.late_update);
}

// After detach: hook the framework's per-frame sampling point and go live.
// `code` is the JIT entry ResolveUnityMonoLookup / ResolveUnityMonoFungusLookup
// returned (nullptr: rejected).
bool InstallUnityMonoLookupHooks(void* code) {
  auto& rt = g_um_lookup;
  if (code == nullptr) {
    // Only the attempted framework's result moved off its default.
    UmLookupLog(L"unity-mono-lookup: gate=sites-unresolved message=%u/%d "
                L"fungus=%u/%d",
                static_cast<unsigned>(rt.site_result.result),
                rt.site_result.missing_icall,
                static_cast<unsigned>(rt.fungus_result.result),
                rt.fungus_result.missing_icall);
    return false;
  }
  const HWND window = FindUmGameWindow();
  const DWORD main_thread =
      window == nullptr ? 0u : GetWindowThreadProcessId(window, nullptr);
  if (main_thread == 0u) {
    UmLookupLog(L"unity-mono-lookup: no UnityWndClass main window");
    rt.site_result.result = umono_lookup::SiteResult::kApiIncomplete;
    return false;
  }
  rt.main_thread.store(main_thread, std::memory_order_release);
  rt.claim = umono_lookup::ClaimState();
  // The detour reads `live` before touching any state; publish state first.
  rt.live.store(true, std::memory_order_release);
  const bool fungus = rt.framework == kUmFrameworkFungus;
  const bool hooked =
      fungus ? HookFn(code, reinterpret_cast<void*>(&UmFungusLateUpdateDetour),
                      reinterpret_cast<void**>(&g_um_late_update_original))
             : HookFn(code, reinterpret_cast<void*>(&UmFixedUpdateDetour),
                      reinterpret_cast<void**>(&g_um_fixed_update_original));
  rt.hooks_installed = hooked;
  rt.installed = hooked;
  if (!hooked) rt.live.store(false, std::memory_order_release);
  if (fungus) {
    const auto& f = rt.fungus;
    UmLookupLog(
        L"unity-mono-lookup: fungus sites late=%p story=+%u text=+%u "
        L"cache=+%u canvas=+%u renderer=+%u alpha=+%u chars=+%u/%u "
        L"lines=+%u/%u main=%lu hooks=%d",
        code, f.story_text_offset, f.text_string_offset, f.text_cache_offset,
        f.graphic_canvas_offset, f.graphic_renderer_offset,
        f.graphic_color_alpha_offset, f.generator_chars_offset, f.char_stride,
        f.generator_lines_offset, f.line_stride, main_thread, hooked ? 1 : 0);
  } else {
    UmLookupLog(
        L"unity-mono-lookup: sites fixed=%p sprite=+%u lastmes=+%u items=+%u "
        L"size=+%u cached=+%u main=%lu hooks=%d",
        code, rt.sites.message_sprite_offset, rt.sites.last_mes_offset,
        rt.sites.list_items_offset, rt.sites.list_size_offset,
        rt.sites.cached_ptr_offset, main_thread, hooked ? 1 : 0);
  }
  if (rt.installed && g_header != nullptr) {
    fushi_voice_hook::AtomicOrShared32(
        &g_header->lookup_diag, fushi_voice_hook::kLookupDiagSensorInstalled);
  }
  return rt.installed;
}

void RetireUmLookup() {
  auto& rt = g_um_lookup;
  InvalidateUmModel();
  rt.model.generation = 0u;
  rt.model.count = 0u;
  rt.model_line.clear();
  rt.model_text_event = 0u;
  if (!rt.provider_offered) return;
  rt.provider_offered = false;
  if (g_header != nullptr) {
    fushi_voice_hook::g_geometry_provider_registry.Retire(
        g_header, fushi_voice_hook::kLookupGeometryProviderEngineExactLayout,
        fushi_voice_hook::kLookupGeometryProviderIdUnityMono);
  }
}

struct UmDpiScope {
  explicit UmDpiScope(DPI_AWARENESS_CONTEXT context)
      : previous(SetThreadDpiAwarenessContext(context)) {}
  ~UmDpiScope() {
    if (previous != nullptr) SetThreadDpiAwarenessContext(previous);
  }
  DPI_AWARENESS_CONTEXT previous;
};

// Diagnostic detail of the last model-build failure (worker only).
struct UmModelFailure {
  // 1 no fresh instance 2 no instance shows the line 3 ambiguous
  // 4 structure/text mismatch 5 sample failure 6 window 7 screen != client
  // 8 projection 9 nothing visible
  uint32_t step = 0u;
  int32_t a = 0, b = 0, c = 0, d = 0;
};
UmModelFailure g_um_model_failure;

bool FailUmModel(uint32_t step, int32_t a = 0, int32_t b = 0, int32_t c = 0,
                 int32_t d = 0) {
  g_um_model_failure = {step, a, b, c, d};
  return false;
}

bool BuildUmModel(const UmSnapshot& snapshot, const std::wstring& line,
                  HWND game, UmModel* model) {
  auto& rt = g_um_lookup;
  const uint64_t now = GetTickCount64();
  // Exactly one fresh instance must show the selected line.
  size_t matched = umono_lookup::kInstanceSlots;
  uint32_t fresh = 0u;
  for (size_t slot = 0; slot < umono_lookup::kInstanceSlots; ++slot) {
    const UmInstanceSnapshot& instance = snapshot.instances[slot];
    const uint64_t tick = rt.slot_tick[slot].load(std::memory_order_acquire);
    if (instance.instance == 0u ||
        rt.slot_instance[slot].load(std::memory_order_acquire) !=
            instance.instance ||
        tick == 0u || now < tick || now - tick > kUmFrameStaleMs) {
      continue;
    }
    ++fresh;
    if (instance.units != line.size() ||
        std::memcmp(instance.text.data(), line.data(),
                    line.size() * sizeof(wchar_t)) != 0) {
      continue;
    }
    if (matched != umono_lookup::kInstanceSlots) return FailUmModel(3u);
    matched = slot;
  }
  if (fresh == 0u) return FailUmModel(1u);
  if (matched == umono_lookup::kInstanceSlots) {
    return FailUmModel(2u, static_cast<int32_t>(fresh),
                       static_cast<int32_t>(line.size()));
  }
  const UmInstanceSnapshot& instance = snapshot.instances[matched];
  if (instance.failure != kUmSampleOk) {
    return FailUmModel(5u, static_cast<int32_t>(instance.failure));
  }
  // The rendered structure must agree with the text it claims to show:
  // framework 1 proves it line by line; the Fungus sampler recorded each
  // glyph's text index and those must address drawn units in order.
  bool mapped = false;
  if (instance.framework == kUmFrameworkMessage) {
    mapped = umono_lookup::MapGlyphsToText(
        instance.text.data(), instance.units, instance.line_glyphs.data(),
        instance.lines, rt.source_scratch.data(), instance.glyph_count);
  } else if (instance.framework == kUmFrameworkFungus &&
             umono_lookup::ValidateGlyphSources(
                 instance.text.data(), instance.units, instance.sources.data(),
                 instance.glyph_count)) {
    std::memcpy(rt.source_scratch.data(), instance.sources.data(),
                instance.glyph_count * sizeof(uint16_t));
    mapped = true;
  }
  if (!mapped) {
    return FailUmModel(4u, static_cast<int32_t>(instance.lines),
                       static_cast<int32_t>(instance.glyph_count),
                       static_cast<int32_t>(instance.units),
                       static_cast<int32_t>(instance.framework));
  }
  DWORD pid = 0;
  if (game == nullptr || !IsWindow(game) ||
      GetWindowThreadProcessId(game, &pid) == 0 ||
      pid != GetCurrentProcessId() || !IsWindowVisible(game) ||
      IsIconic(game)) {
    return FailUmModel(6u);
  }
  RECT logical = {};
  RECT physical = {};
  {
    UmDpiScope own(GetWindowDpiAwarenessContext(game));
    if (own.previous == nullptr || !GetClientRect(game, &logical)) {
      return FailUmModel(6u, 1);
    }
  }
  {
    UmDpiScope aware(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
    if (aware.previous == nullptr || !GetClientRect(game, &physical)) {
      return FailUmModel(6u, 2);
    }
  }
  const int32_t logical_w = logical.right - logical.left;
  const int32_t logical_h = logical.bottom - logical.top;
  // Unity's screen grid must be the client in the window's own DPI context;
  // anything else (a render resolution below a fullscreen client) is a
  // projection we cannot prove.
  if (logical_w != instance.screen_w || logical_h != instance.screen_h) {
    return FailUmModel(7u, instance.screen_w, instance.screen_h, logical_w,
                       logical_h);
  }
  model->snapshot_version = snapshot.version;
  model->window = reinterpret_cast<uintptr_t>(game);
  model->instance = instance.instance;
  model->text_object = instance.text_object;
  model->text_owner = instance.text_owner;
  model->text_offset = instance.text_offset;
  model->slot = static_cast<uint32_t>(matched);
  model->screen_w = instance.screen_w;
  model->screen_h = instance.screen_h;
  model->physical_w = physical.right - physical.left;
  model->physical_h = physical.bottom - physical.top;
  model->count = 0u;
  for (uint32_t index = 0u; index < instance.glyph_count; ++index) {
    const auto& cell = instance.cells[index];
    if (!cell.visible) continue;
    UmModelGlyph& out = model->glyphs[model->count];
    // Every visible glyph must project into the client: a partially visible
    // message is not one the user can be reading.
    if (!umono_lookup::ProjectCell(cell, instance.screen_w, instance.screen_h,
                                   model->physical_w, model->physical_h,
                                   &out.rect)) {
      return FailUmModel(8u, static_cast<int32_t>(cell.x0),
                         static_cast<int32_t>(cell.y0), model->physical_w,
                         model->physical_h);
    }
    out.cell = cell;
    out.source = rt.source_scratch[index];
    ++model->count;
  }
  if (model->count == 0u) {
    return FailUmModel(9u, static_cast<int32_t>(instance.glyph_count),
                       static_cast<int32_t>(instance.visible_count),
                       instance.screen_w, instance.screen_h);
  }
  return true;
}

bool SameUmModelGeometry(const UmModel& left, const UmModel& right) {
  if (left.window != right.window || left.instance != right.instance ||
      left.text_object != right.text_object ||
      left.snapshot_version != right.snapshot_version ||
      left.screen_w != right.screen_w || left.screen_h != right.screen_h ||
      left.physical_w != right.physical_w ||
      left.physical_h != right.physical_h || left.count != right.count) {
    return false;
  }
  for (uint32_t index = 0u; index < left.count; ++index) {
    const auto& a = left.glyphs[index];
    const auto& b = right.glyphs[index];
    if (a.rect.x != b.rect.x || a.rect.y != b.rect.y || a.rect.w != b.rect.w ||
        a.rect.h != b.rect.h || a.source != b.source) {
      return false;
    }
  }
  return true;
}

bool PublishUmLookupHit(const UmSubmit& submit) {
  auto& rt = g_um_lookup;
  const UmModel& model = rt.model;
  if (g_header == nullptr || submit.generation == 0u ||
      submit.generation != model.generation || submit.glyph >= model.count ||
      rt.model_line.empty()) {
    return false;
  }
  const auto& glyph = model.glyphs[submit.glyph];
  const size_t units = rt.model_line.size();
  if (glyph.source == umono_lookup::kNoSource || glyph.source >= units ||
      fushi_voice_hook::LookupUtf16SourceLength(
          rt.model_line.data(), static_cast<uint32_t>(units), glyph.source) !=
          1u) {
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
  publication.provider_id = fushi_voice_hook::kLookupGeometryProviderIdUnityMono;
  publication.char_index = glyph.source;
  publication.source_length = 1u;
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
  UmLookupLog(
      L"unity-mono-lookup: hit gen=%llu glyph=%u char=%u/%u rect=%d,%d %dx%d "
      L"screen=%.1f,%.1f-%.1f,%.1f view=%dx%d published=%d",
      static_cast<unsigned long long>(model.generation), submit.glyph,
      static_cast<unsigned>(glyph.source), static_cast<unsigned>(units),
      glyph.rect.x, glyph.rect.y, glyph.rect.w, glyph.rect.h, glyph.cell.x0,
      glyph.cell.y0, glyph.cell.x1, glyph.cell.y1, model.physical_w,
      model.physical_h, published ? 1 : 0);
  return published;
}

bool ReadLatestUmSubmit(UmSubmit* out) {
  auto& rt = g_um_lookup;
  const uint64_t sequence = rt.submit_count.load(std::memory_order_acquire);
  if (sequence == 0u || sequence == rt.processed_submit_seq) return false;
  rt.processed_submit_seq = sequence;
  auto& slot_seq = rt.submit_seq[sequence % kUmSubmitSlots];
  if (slot_seq.load(std::memory_order_acquire) != sequence) return false;
  std::atomic_thread_fence(std::memory_order_acquire);
  *out = rt.submits[sequence % kUmSubmitSlots];
  std::atomic_thread_fence(std::memory_order_acquire);
  return slot_seq.load(std::memory_order_acquire) == sequence;
}

// Why the last tick retired (0 = offered).  Logged once per change so a
// silent provider always says which gate it is waiting on.
void NoteUmRetire(uint32_t reason) {
  static uint32_t last = UINT32_MAX;
  static uint32_t budget = 48u;
  const uint32_t key = reason == 5u ? 100u + g_um_model_failure.step : reason;
  if (key == last || budget == 0u) return;
  last = key;
  --budget;
  static const wchar_t* const kNames[] = {
      L"offered",          L"lookup-disabled", L"no-window",
      L"no-snapshot",      L"no-selected-text", L"model-unbuilt",
      L"offer-rejected"};
  auto& rt = g_um_lookup;
  const auto& f = g_um_model_failure;
  UmLookupLog(
      L"unity-mono-lookup: gate=%s step=%u %d,%d,%d,%d fixed=%u faults=%u "
      L"version=%llu subclass=%d",
      reason < 7u ? kNames[reason] : L"?", reason == 5u ? f.step : 0u, f.a,
      f.b, f.c, f.d, rt.fixed_hits.load(), rt.sample_faults.load(),
      static_cast<unsigned long long>(rt.latest_version.load()),
      rt.subclass_live.load() ? 1 : 0);
}

void ProcessUnityMonoLookupTick() {
  auto& rt = g_um_lookup;
  if (!rt.installed) return;
  if (g_stop || g_header == nullptr ||
      !fushi_voice_hook::HasLookupRegion(g_header) ||
      fushi_voice_hook::AtomicLoadShared32(&g_header->lookup_enabled) == 0u) {
    NoteUmRetire(1u);
    RetireUmLookup();
    return;
  }
  fushi_voice_hook::AtomicOrShared32(
      &g_header->lookup_diag, fushi_voice_hook::kLookupDiagSensorInstalled);

  // The click claim lives in the game window's procedure; (re)bind it to the
  // current Unity window (a fullscreen toggle can recreate it).
  HWND game = rt.window.load(std::memory_order_acquire);
  if (!rt.subclass_live.load(std::memory_order_acquire) || game == nullptr ||
      !IsWindow(game)) {
    game = FindUmGameWindow();
    if (game == nullptr || !InstallUmSubclass(game)) {
      NoteUmRetire(2u);
      RetireUmLookup();
      return;
    }
    rt.claim = umono_lookup::ClaimState();
  }

  UmSnapshot& snapshot = rt.snapshot_copy;
  if (!ReadUmSlot(rt.snapshot_seq, rt.snapshots, rt.published_snapshot,
                  &snapshot)) {
    NoteUmRetire(3u);
    RetireUmLookup();
    return;
  }
  std::wstring line;
  uint64_t event = 0u;
  uint64_t thread = 0u;
  if (!fushi_voice_hook::ReadSelectedLookupText(
          g_header, &line, &event, &thread, umono_lookup::kMaxLineUnits)) {
    NoteUmRetire(4u);
    RetireUmLookup();
    return;
  }
  UmModel candidate;
  if (!BuildUmModel(snapshot, line, game, &candidate)) {
    NoteUmRetire(5u);
    RetireUmLookup();
    return;
  }
  const bool same = rt.model.generation != 0u && rt.model_text_event == event &&
                    rt.model_line == line &&
                    SameUmModelGeometry(rt.model, candidate);
  if (!same) {
    candidate.generation = ++rt.next_generation;
    rt.model = candidate;
    rt.model_line = line;
    rt.model_text_event = event;
    PublishUmSlot(rt.model_seq, rt.models, rt.published_model, rt.model);
    if (rt.logged_models < kUmModelLogBudget) {
      ++rt.logged_models;
      const auto& first = rt.model.glyphs[0];
      const auto& last = rt.model.glyphs[rt.model.count - 1u];
      UmLookupLog(
          L"unity-mono-lookup: model gen=%llu event=%llu units=%u glyphs=%u "
          L"first=%d,%d %dx%d (char %u) last=%d,%d %dx%d (char %u) "
          L"view=%dx%d screen=%dx%d",
          static_cast<unsigned long long>(rt.model.generation),
          static_cast<unsigned long long>(event),
          static_cast<unsigned>(line.size()), rt.model.count, first.rect.x,
          first.rect.y, first.rect.w, first.rect.h,
          static_cast<unsigned>(first.source), last.rect.x, last.rect.y,
          last.rect.w, last.rect.h, static_cast<unsigned>(last.source),
          rt.model.physical_w, rt.model.physical_h, rt.model.screen_w,
          rt.model.screen_h);
    }
  }
  if (fushi_voice_hook::g_geometry_provider_registry.OfferReady(
          g_header, fushi_voice_hook::kLookupGeometryProviderEngineExactLayout,
          fushi_voice_hook::kLookupGeometryProviderIdUnityMono)) {
    if (!rt.provider_offered) {
      UmLookupLog(L"unity-mono-lookup: OfferReady gen=%llu glyphs=%u",
                  static_cast<unsigned long long>(rt.model.generation),
                  rt.model.count);
    }
    rt.provider_offered = true;
    fushi_voice_hook::AtomicOrShared32(
        &g_header->lookup_diag, fushi_voice_hook::kLookupDiagGeometryObserved);
    NoteUmRetire(0u);
  } else {
    NoteUmRetire(6u);
    RetireUmLookup();
    return;
  }

  UmSubmit submit;
  if (ReadLatestUmSubmit(&submit)) (void)PublishUmLookupHit(submit);
}

void ShutdownUnityMonoLookup() {
  auto& rt = g_um_lookup;
  // The FixedUpdate detour stays chained (MinHook owns it for the process
  // lifetime); clearing `live` turns it into a pure forwarder.  The window
  // procedure is restored.
  rt.live.store(false, std::memory_order_release);
  TeardownUmSubclass();
  rt.claim = umono_lookup::ClaimState();
  RetireUmLookup();
  rt.installed = false;
}

// Re-install after a shutdown: the detour is still chained and only needs to
// start sampling again.  A rejected build stays rejected.
bool ReinstallUnityMonoLookup() {
  auto& rt = g_um_lookup;
  if (rt.installed) return true;
  if (!rt.hooks_installed) return false;
  rt.claim = umono_lookup::ClaimState();
  rt.live.store(true, std::memory_order_release);
  rt.installed = true;
  return true;
}

bool UnityMonoLookupSensorInstalled() { return g_um_lookup.installed; }
bool UnityMonoLookupSitesRejected() {
  return g_um_lookup.resolved && !g_um_lookup.hooks_installed;
}
