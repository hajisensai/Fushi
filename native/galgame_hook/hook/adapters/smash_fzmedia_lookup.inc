// smash/fzmedia in-game lookup runtime.
//
// Owns three things for the TYPE-MOON "smash" framework titles (KAG text
// layer laid out by TextLayerBase::layoutChar, GLFW30 top-level window):
//   1. the EngineExactLayout / kLookupGeometryProviderIdSmashFzmedia geometry
//      provider: layer-unit glyph cells from smash_fzmedia_adapter.inc are
//      projected to client pixels with the uniform 1920x1080 stage fit plus a
//      host-solved layer origin (PublishLookupLayerLine / ReadLookupLayerOrigin,
//      BUG-2093 channel).  Readiness is fail-closed: no origin, or one inked
//      cell outside the client rect, means no offer;
//   2. click / Shift-hover sensing through a GWLP_WNDPROC subclass of the game
//      window installed from HookWorker (same process, different thread).  A
//      bare left down on a glyph is consumed together with its paired up and
//      queued as a Submit hit; a Shift-move publishes once per (generation,
//      glyph) change and is never consumed;
//   3. v19 shield participation: while a lookup card is visible above the game
//      (bitmap overlay, host direct card, or a shield transaction targeting
//      this HWND) every client-area left down/up is swallowed and the outside
//      dismiss event is raised so closing the card never advances the game.
//      Required/Ready/Window properties follow the sampled-input contract
//      (kSmashFzmediaSampledInputShield*), and generic_input_shield.inc merges
//      the EnginePrivate | Win32Messages surfaces this file owns.
//
// This file is expanded inside dll_main.cpp's anonymous namespace.  The public
// entry points declared in smash_fzmedia_lookup.h live in
// fushi_voice_hook::smash_fzmedia, so the anonymous namespace is closed and
// reopened around their thin definitions at the bottom.
//
// Decision logic (hit mapping, gesture table, origin gating, shield masks) is
// in smash_fzmedia_lookup_core.h and unit-tested; this file only binds it to
// Win32 and IPC.

#if defined(_M_X64)

namespace smash_lookup_core = fushi_voice_hook::smash_fzmedia::lookup_core;

// Defined later in generic_input_shield.inc (same anonymous namespace).
void MarkGenericShieldObserved(uint32_t surface);

static_assert(smash_lookup_core::kShieldSurfaceWin32Messages ==
                  fushi_voice_hook::kLookupShieldSurfaceWin32Messages,
              "smash lookup core surface mirror drifted");
static_assert(smash_lookup_core::kShieldSurfaceEnginePrivate ==
                  fushi_voice_hook::kLookupShieldSurfaceEnginePrivate,
              "smash lookup core surface mirror drifted");

constexpr uint32_t kSmashFzmediaLookupModelSlots = 2u;
constexpr uint32_t kSmashFzmediaLookupSubmitSlots = 8u;
constexpr wchar_t kSmashFzmediaGameWindowClass[] = L"GLFW30";
constexpr wchar_t kSmashFzmediaDirectPopupClass[] = L"FushiGlobalLookupWindow";

// One immutable geometry model: the paragraph plus the projection it was
// validated against.  HookWorker republishes it whenever the paragraph, the
// client size, the origin or the readiness verdict changes; the game thread
// reads it through a two-slot seqlock in the subclass procedure.
struct SmashFzmediaLookupModel {
  fushi_voice_hook::smash_fzmedia::LineSnapshot line;
  fushi_voice_hook::smash_fzmedia::StageProjection projection;
  float origin_x = 0.0f;
  float origin_y = 0.0f;
  int32_t client_w = 0;
  int32_t client_h = 0;
  bool geometry_ready = false;
};

// Game thread → HookWorker: one resolved glyph, already in client pixels.
struct SmashFzmediaLookupSubmit {
  uint64_t generation = 0;
  uint32_t char_index = 0;
  int32_t x = 0;
  int32_t y = 0;
  int32_t w = 0;
  int32_t h = 0;
  int32_t client_w = 0;
  int32_t client_h = 0;
};

struct SmashFzmediaLookupRuntime {
  // ── HookWorker-owned ──
  bool installed = false;
  bool has_line = false;
  bool model_dirty = false;
  fushi_voice_hook::smash_fzmedia::LineSnapshot latest_line;
  SmashFzmediaLookupModel current_model;
  smash_lookup_core::ProjectionEpoch epoch;
  smash_lookup_core::OriginCache origin_cache;
  bool provider_offered = false;
  bool window_class_rejected = false;
  bool subclass_failed = false;
  uint64_t processed_submit_seq = 0;
  HWND property_window = nullptr;
  // A window whose procedure chain someone else took over after us.  Our
  // procedure is still in that chain (forwarding only), so subclassing the
  // same HWND a second time would put the same function twice in the chain
  // and loop forever.  Stay displaced until the window is destroyed.
  HWND displaced_window = nullptr;

  // ── shared (HookWorker writes, game thread reads) ──
  std::atomic<HWND> window{nullptr};
  std::atomic<WNDPROC> original_proc{nullptr};
  std::atomic<bool> subclass_live{false};
  std::array<std::atomic<uint32_t>, kSmashFzmediaLookupModelSlots> model_seq =
      {};
  std::array<SmashFzmediaLookupModel, kSmashFzmediaLookupModelSlots> models =
      {};
  std::atomic<uint32_t> published_model{UINT32_MAX};

  // ── shared (game thread writes, HookWorker reads) ──
  std::array<std::atomic<uint64_t>, kSmashFzmediaLookupSubmitSlots>
      submit_seq = {};
  std::array<SmashFzmediaLookupSubmit, kSmashFzmediaLookupSubmitSlots>
      submits = {};
  std::atomic<uint64_t> submit_count{0u};
  std::atomic<bool> observed_win32_transaction{false};
  std::atomic<uint32_t> swallowed_transaction_messages{0u};

  // ── game-thread-owned ──
  smash_lookup_core::MouseGestureState gesture;
};

SmashFzmediaLookupRuntime g_smash_fzmedia_lookup;

// ── model seqlock ───────────────────────────────────────────────────────────

void PublishSmashFzmediaLookupModel(const SmashFzmediaLookupModel& model) {
  auto& rt = g_smash_fzmedia_lookup;
  const uint32_t current = rt.published_model.load(std::memory_order_acquire);
  const uint32_t slot = current >= kSmashFzmediaLookupModelSlots
                            ? 0u
                            : (current + 1u) % kSmashFzmediaLookupModelSlots;
  const uint32_t seq = rt.model_seq[slot].load(std::memory_order_relaxed);
  rt.model_seq[slot].store(seq | 1u, std::memory_order_release);
  std::atomic_thread_fence(std::memory_order_release);
  rt.models[slot] = model;
  std::atomic_thread_fence(std::memory_order_release);
  rt.model_seq[slot].store((seq | 1u) + 1u, std::memory_order_release);
  rt.published_model.store(slot, std::memory_order_release);
}

void InvalidateSmashFzmediaLookupModel() {
  g_smash_fzmedia_lookup.published_model.store(UINT32_MAX,
                                               std::memory_order_release);
}

bool ReadSmashFzmediaLookupModel(SmashFzmediaLookupModel* out) {
  auto& rt = g_smash_fzmedia_lookup;
  if (out == nullptr) return false;
  const uint32_t slot = rt.published_model.load(std::memory_order_acquire);
  if (slot >= kSmashFzmediaLookupModelSlots) return false;
  const uint32_t before = rt.model_seq[slot].load(std::memory_order_acquire);
  if (before == 0u || (before & 1u) != 0u) return false;
  std::atomic_thread_fence(std::memory_order_acquire);
  *out = rt.models[slot];
  std::atomic_thread_fence(std::memory_order_acquire);
  const uint32_t after = rt.model_seq[slot].load(std::memory_order_acquire);
  return before == after &&
         rt.published_model.load(std::memory_order_acquire) == slot;
}

// ── submit ring ─────────────────────────────────────────────────────────────

void QueueSmashFzmediaLookupSubmit(const SmashFzmediaLookupSubmit& submit) {
  auto& rt = g_smash_fzmedia_lookup;
  const uint64_t sequence =
      rt.submit_count.load(std::memory_order_acquire) + 1u;
  auto& slot_seq = rt.submit_seq[sequence % kSmashFzmediaLookupSubmitSlots];
  slot_seq.store(0u, std::memory_order_release);
  std::atomic_thread_fence(std::memory_order_release);
  rt.submits[sequence % kSmashFzmediaLookupSubmitSlots] = submit;
  std::atomic_thread_fence(std::memory_order_release);
  slot_seq.store(sequence, std::memory_order_release);
  rt.submit_count.store(sequence, std::memory_order_release);
}

bool ReadLatestSmashFzmediaLookupSubmit(SmashFzmediaLookupSubmit* out,
                                        uint64_t* out_seq) {
  auto& rt = g_smash_fzmedia_lookup;
  const uint64_t sequence = rt.submit_count.load(std::memory_order_acquire);
  if (sequence == 0u || sequence == rt.processed_submit_seq) return false;
  rt.processed_submit_seq = sequence;
  auto& slot_seq = rt.submit_seq[sequence % kSmashFzmediaLookupSubmitSlots];
  if (slot_seq.load(std::memory_order_acquire) != sequence) return false;
  std::atomic_thread_fence(std::memory_order_acquire);
  *out = rt.submits[sequence % kSmashFzmediaLookupSubmitSlots];
  std::atomic_thread_fence(std::memory_order_acquire);
  if (slot_seq.load(std::memory_order_acquire) != sequence) return false;
  *out_seq = sequence;
  return true;
}

// ── shield helpers (game thread + HookWorker) ───────────────────────────────

HWND GetValidPublishedSmashFzmediaShieldPopup(HWND game) {
  if (game == nullptr || !IsWindow(game) ||
      reinterpret_cast<uintptr_t>(GetPropW(
          game,
          fushi_voice_hook::kSmashFzmediaSampledInputShieldReadyProperty)) !=
          fushi_voice_hook::kSmashFzmediaSampledInputShieldReadyValue) {
    return nullptr;
  }
  const HWND popup = reinterpret_cast<HWND>(GetPropW(
      game, fushi_voice_hook::kSmashFzmediaSampledInputShieldWindowProperty));
  if (popup == nullptr || !IsWindow(popup) ||
      GetWindow(popup, GW_OWNER) != game) {
    return nullptr;
  }
  wchar_t class_name[64] = {};
  if (GetClassNameW(popup, class_name,
                    static_cast<int>(std::size(class_name))) <= 0 ||
      lstrcmpW(class_name, kSmashFzmediaDirectPopupClass) != 0) {
    return nullptr;
  }
  return popup;
}

bool SmashFzmediaLookupShieldRequestTargets(HWND game) {
  if (g_header == nullptr || game == nullptr) return false;
  const auto request = fushi_voice_hook::ReadLookupShieldRequest(g_header);
  return request.valid && request.active_buttons != 0u &&
         request.target_hwnd ==
             static_cast<uint64_t>(reinterpret_cast<uintptr_t>(game));
}

// A card is open above this window when any of the three routes says so:
// the injected bitmap overlay, the host direct card published through the
// Window property, or a live v19 down/up transaction targeting this HWND.
bool SmashFzmediaLookupShieldActive(HWND game) {
  return IsLookupOverlayInputShieldVisible() ||
         GetValidPublishedSmashFzmediaShieldPopup(game) != nullptr ||
         SmashFzmediaLookupShieldRequestTargets(game);
}

// ── subclass window procedure (game thread) ─────────────────────────────────

bool SmashFzmediaLookupHitTest(int client_x, int client_y,
                               SmashFzmediaLookupSubmit* out) {
  SmashFzmediaLookupModel model;
  if (!ReadSmashFzmediaLookupModel(&model) || !model.geometry_ready) {
    return false;
  }
  const smash_lookup_core::HitGeometry hit = smash_lookup_core::ResolveHit(
      model.line, model.projection, model.origin_x, model.origin_y,
      static_cast<float>(client_x), static_cast<float>(client_y));
  if (!hit.valid) return false;
  out->generation = model.line.generation;
  out->char_index = hit.char_index;
  out->x = hit.x;
  out->y = hit.y;
  out->w = hit.w;
  out->h = hit.h;
  out->client_w = model.client_w;
  out->client_h = model.client_h;
  return true;
}

LRESULT CALLBACK SmashFzmediaLookupWindowProc(HWND hwnd, UINT message,
                                              WPARAM wparam, LPARAM lparam);

LRESULT CallSmashFzmediaOriginalProc(HWND hwnd, UINT message, WPARAM wparam,
                                     LPARAM lparam) {
  const WNDPROC original =
      g_smash_fzmedia_lookup.original_proc.load(std::memory_order_acquire);
  if (original == nullptr) return DefWindowProcW(hwnd, message, wparam, lparam);
  return CallWindowProcW(original, hwnd, message, wparam, lparam);
}

LRESULT CALLBACK SmashFzmediaLookupWindowProc(HWND hwnd, UINT message,
                                              WPARAM wparam, LPARAM lparam) {
  auto& rt = g_smash_fzmedia_lookup;
  if (message == WM_NCDESTROY) {
    // The window is going away underneath us; HookWorker notices the cleared
    // handle and drops the provider.  Nothing to restore any more.
    rt.subclass_live.store(false, std::memory_order_release);
    rt.window.store(nullptr, std::memory_order_release);
    InvalidateSmashFzmediaLookupModel();
    return CallSmashFzmediaOriginalProc(hwnd, message, wparam, lparam);
  }
  smash_lookup_core::MouseMessageInput input;
  switch (message) {
    case WM_LBUTTONDOWN:
    case WM_LBUTTONDBLCLK:
      input.kind = smash_lookup_core::MouseMessageKind::kLeftDown;
      break;
    case WM_LBUTTONUP:
      input.kind = smash_lookup_core::MouseMessageKind::kLeftUp;
      break;
    case WM_MOUSEMOVE:
      input.kind = smash_lookup_core::MouseMessageKind::kMove;
      break;
    default:
      return CallSmashFzmediaOriginalProc(hwnd, message, wparam, lparam);
  }
  if (!rt.subclass_live.load(std::memory_order_acquire) ||
      rt.window.load(std::memory_order_acquire) != hwnd) {
    return CallSmashFzmediaOriginalProc(hwnd, message, wparam, lparam);
  }
  input.shift = (GetKeyState(VK_SHIFT) & 0x8000) != 0;
  input.ctrl = (GetKeyState(VK_CONTROL) & 0x8000) != 0;
  input.alt = (GetKeyState(VK_MENU) & 0x8000) != 0;
  input.shield_active = SmashFzmediaLookupShieldActive(hwnd);
  input.native_input_allowed =
      g_header != nullptr &&
      fushi_voice_hook::g_geometry_provider_registry.NativeInputAllowed(
          g_header, fushi_voice_hook::kLookupGeometryProviderEngineExactLayout,
          fushi_voice_hook::kLookupGeometryProviderIdSmashFzmedia);
  SmashFzmediaLookupSubmit candidate;
  if (smash_lookup_core::HitTestRequired(input) &&
      SmashFzmediaLookupHitTest(GET_X_LPARAM(lparam), GET_Y_LPARAM(lparam),
                                &candidate)) {
    input.hit = true;
    input.hit_generation = candidate.generation;
    input.hit_index = candidate.char_index;
  }
  const smash_lookup_core::MouseMessageDecision decision =
      smash_lookup_core::DecideMouseMessage(input, &rt.gesture);
  if (decision.submit) QueueSmashFzmediaLookupSubmit(candidate);
  if (decision.request_dismiss) RequestLookupOverlayOutsideDismiss();
  if (!decision.swallow) {
    return CallSmashFzmediaOriginalProc(hwnd, message, wparam, lparam);
  }
  if (input.shield_active) {
    rt.observed_win32_transaction.store(true, std::memory_order_release);
    rt.swallowed_transaction_messages.fetch_add(1u, std::memory_order_relaxed);
    MarkGenericShieldObserved(smash_lookup_core::kOwnedShieldSurfaces);
  }
  return 0;
}

// ── window binding (HookWorker) ─────────────────────────────────────────────

HWND FindSmashFzmediaGameWindow() {
  auto& rt = g_smash_fzmedia_lookup;
  const HWND candidate = FindGameMainWindow();
  if (candidate == nullptr) return nullptr;
  wchar_t class_name[64] = {};
  if (GetClassNameW(candidate, class_name,
                    static_cast<int>(std::size(class_name))) <= 0 ||
      lstrcmpW(class_name, kSmashFzmediaGameWindowClass) != 0) {
    rt.window_class_rejected = true;
    return nullptr;
  }
  rt.window_class_rejected = false;
  return candidate;
}

bool SmashFzmediaSubclassOwnsWindow(HWND window) {
  return window != nullptr && IsWindow(window) &&
         GetWindowLongPtrW(window, GWLP_WNDPROC) ==
             reinterpret_cast<LONG_PTR>(&SmashFzmediaLookupWindowProc);
}

bool InstallSmashFzmediaSubclass(HWND window) {
  auto& rt = g_smash_fzmedia_lookup;
  DWORD pid = 0;
  if (window == nullptr || !IsWindow(window) ||
      GetWindowThreadProcessId(window, &pid) == 0 ||
      pid != GetCurrentProcessId()) {
    return false;
  }
  SetLastError(0);
  const LONG_PTR previous = GetWindowLongPtrW(window, GWLP_WNDPROC);
  if (previous == 0) return false;
  if (previous == reinterpret_cast<LONG_PTR>(&SmashFzmediaLookupWindowProc)) {
    return false;  // already ours; the caller lost track of it
  }
  // The game thread can enter the procedure the instant the swap lands, so
  // every field it reads is published before SetWindowLongPtrW.
  rt.original_proc.store(reinterpret_cast<WNDPROC>(previous),
                         std::memory_order_release);
  rt.gesture = smash_lookup_core::MouseGestureState();
  rt.window.store(window, std::memory_order_release);
  SetLastError(0);
  const LONG_PTR swapped = SetWindowLongPtrW(
      window, GWLP_WNDPROC,
      reinterpret_cast<LONG_PTR>(&SmashFzmediaLookupWindowProc));
  if (swapped == 0 && GetLastError() != 0) {
    rt.window.store(nullptr, std::memory_order_release);
    return false;
  }
  if (swapped != previous) {
    // Someone re-subclassed between our read and our write.  Chain to what
    // was actually there so no procedure is lost.
    rt.original_proc.store(reinterpret_cast<WNDPROC>(swapped),
                           std::memory_order_release);
  }
  rt.subclass_live.store(true, std::memory_order_release);
  return true;
}

void TeardownSmashFzmediaSubclass() {
  auto& rt = g_smash_fzmedia_lookup;
  rt.subclass_live.store(false, std::memory_order_release);
  const HWND window = rt.window.exchange(nullptr, std::memory_order_acq_rel);
  InvalidateSmashFzmediaLookupModel();
  if (window == nullptr || !IsWindow(window)) return;
  const WNDPROC original = rt.original_proc.load(std::memory_order_acquire);
  if (original != nullptr && SmashFzmediaSubclassOwnsWindow(window)) {
    SetWindowLongPtrW(window, GWLP_WNDPROC,
                      reinterpret_cast<LONG_PTR>(original));
  }
  // original_proc intentionally stays set: an in-flight call on the game
  // thread may still chain through it after the restore.
}

// ── shield contract properties (HookWorker) ─────────────────────────────────

void RevokeSmashFzmediaShieldProperties(fushi_voice_hook::SharedHeader* header,
                                        bool remove_required) {
  auto& rt = g_smash_fzmedia_lookup;
  const HWND game = rt.property_window;
  if (game != nullptr && IsWindow(game)) {
    RemovePropW(game,
                fushi_voice_hook::kSmashFzmediaSampledInputShieldReadyProperty);
    RemovePropW(
        game, fushi_voice_hook::kSmashFzmediaSampledInputShieldWindowProperty);
    if (remove_required) {
      RemovePropW(
          game,
          fushi_voice_hook::kSmashFzmediaSampledInputShieldRequiredProperty);
    }
  }
  if (remove_required) rt.property_window = nullptr;
  if (header != nullptr) {
    InterlockedAnd(reinterpret_cast<volatile LONG*>(&header->lookup_diag),
                   static_cast<LONG>(
                       ~fushi_voice_hook::kLookupDiagSampledInputShieldReady));
  }
}

bool MaintainSmashFzmediaShieldProperties(
    fushi_voice_hook::SharedHeader* header, HWND game, bool subclass_live) {
  auto& rt = g_smash_fzmedia_lookup;
  if (game == nullptr || !IsWindow(game)) {
    RevokeSmashFzmediaShieldProperties(header, true);
    return false;
  }
  if (rt.property_window != game) {
    RevokeSmashFzmediaShieldProperties(header, true);
    rt.property_window = game;
  }
  if (reinterpret_cast<uintptr_t>(GetPropW(
          game,
          fushi_voice_hook::kSmashFzmediaSampledInputShieldRequiredProperty)) !=
          fushi_voice_hook::kSmashFzmediaSampledInputShieldRequiredValue &&
      !SetPropW(
          game,
          fushi_voice_hook::kSmashFzmediaSampledInputShieldRequiredProperty,
          reinterpret_cast<HANDLE>(
              fushi_voice_hook::kSmashFzmediaSampledInputShieldRequiredValue))) {
    RevokeSmashFzmediaShieldProperties(header, false);
    return false;
  }
  if (!subclass_live) {
    RevokeSmashFzmediaShieldProperties(header, false);
    return false;
  }
  if (reinterpret_cast<uintptr_t>(GetPropW(
          game,
          fushi_voice_hook::kSmashFzmediaSampledInputShieldReadyProperty)) !=
          fushi_voice_hook::kSmashFzmediaSampledInputShieldReadyValue &&
      !SetPropW(
          game, fushi_voice_hook::kSmashFzmediaSampledInputShieldReadyProperty,
          reinterpret_cast<HANDLE>(
              fushi_voice_hook::kSmashFzmediaSampledInputShieldReadyValue))) {
    RevokeSmashFzmediaShieldProperties(header, false);
    return false;
  }
  if (header != nullptr) {
    InterlockedOr(reinterpret_cast<volatile LONG*>(&header->lookup_diag),
                  static_cast<LONG>(
                      fushi_voice_hook::kLookupDiagSampledInputShieldReady));
  }
  return true;
}

// ── geometry model refresh (HookWorker) ─────────────────────────────────────

void RetireSmashFzmediaProvider(fushi_voice_hook::SharedHeader* header) {
  auto& rt = g_smash_fzmedia_lookup;
  if (!rt.provider_offered) return;
  rt.provider_offered = false;
  fushi_voice_hook::g_geometry_provider_registry.Retire(
      header, fushi_voice_hook::kLookupGeometryProviderEngineExactLayout,
      fushi_voice_hook::kLookupGeometryProviderIdSmashFzmedia);
}

// Returns true when the current paragraph projects completely inside the
// client area with a host-solved origin, i.e. the provider may offer ready.
bool RefreshSmashFzmediaLookupModel(fushi_voice_hook::SharedHeader* header,
                                    HWND window) {
  namespace smash = fushi_voice_hook::smash_fzmedia;
  auto& rt = g_smash_fzmedia_lookup;
  RECT client = {};
  if (!GetClientRect(window, &client)) return false;
  const int32_t client_w = client.right - client.left;
  const int32_t client_h = client.bottom - client.top;
  const smash::StageProjection projection =
      smash::ComputeStageProjection(client_w, client_h);
  if (!projection.valid) return false;

  const smash_lookup_core::LayerLineRequest request =
      smash_lookup_core::BuildLayerLineRequest(rt.latest_line, projection);
  const uint32_t design_w =
      smash_lookup_core::RoundToDesignUnit(projection.synthetic_design_w);
  const uint32_t design_h =
      smash_lookup_core::RoundToDesignUnit(projection.synthetic_design_h);
  if (design_w == 0u || design_h == 0u) return false;

  const uint32_t origin_seq_before =
      fushi_voice_hook::AtomicLoadShared32(&header->lookup_layer_origin_seq);
  smash_lookup_core::AdvanceProjectionEpoch(&rt.epoch, design_w, design_h,
                                            origin_seq_before);
  if (request.valid) {
    // The helper only bumps the line seq when the payload changed, so calling
    // it every poll is free in steady state.
    fushi_voice_hook::PublishLookupLayerLine(
        header, request.design_w, request.design_h, request.glyph_count,
        request.left, request.top, request.right, request.bottom);
  }

  int32_t host_x = 0, host_y = 0;
  if (fushi_voice_hook::ReadLookupLayerOrigin(header, &host_x, &host_y)) {
    const uint32_t origin_seq_after =
        fushi_voice_hook::AtomicLoadShared32(&header->lookup_layer_origin_seq);
    if (origin_seq_after == origin_seq_before &&
        smash_lookup_core::OriginSeqUsable(rt.epoch, origin_seq_after)) {
      smash_lookup_core::RememberOrigin(&rt.origin_cache, design_w, design_h,
                                        static_cast<float>(host_x),
                                        static_cast<float>(host_y));
    }
  }
  float origin_x = 0.0f, origin_y = 0.0f;
  const bool origin_known = smash_lookup_core::LookupOrigin(
      rt.origin_cache, design_w, design_h, &origin_x, &origin_y);
  const bool ready = smash_lookup_core::GeometryReady(
      rt.latest_line, projection, origin_known, origin_x, origin_y, client_w,
      client_h);

  const SmashFzmediaLookupModel& previous = rt.current_model;
  const bool changed =
      rt.model_dirty ||
      previous.line.generation != rt.latest_line.generation ||
      previous.client_w != client_w || previous.client_h != client_h ||
      previous.origin_x != origin_x || previous.origin_y != origin_y ||
      previous.geometry_ready != ready;
  if (changed) {
    rt.current_model.line = rt.latest_line;
    rt.current_model.projection = projection;
    rt.current_model.origin_x = origin_x;
    rt.current_model.origin_y = origin_y;
    rt.current_model.client_w = client_w;
    rt.current_model.client_h = client_h;
    rt.current_model.geometry_ready = ready;
    PublishSmashFzmediaLookupModel(rt.current_model);
    rt.model_dirty = false;
  }
  return ready;
}

// ── hit publication (HookWorker) ────────────────────────────────────────────

bool PublishSmashFzmediaLookupHit(fushi_voice_hook::SharedHeader* header,
                                  const SmashFzmediaLookupSubmit& submit) {
  auto& rt = g_smash_fzmedia_lookup;
  const SmashFzmediaLookupModel& model = rt.current_model;
  if (!model.geometry_ready || submit.generation == 0u ||
      submit.generation != model.line.generation ||
      submit.client_w != model.client_w || submit.client_h != model.client_h ||
      submit.char_index >= model.line.unit_count) {
    return false;
  }
  const wchar_t* text = model.line.text;
  const uint32_t units = model.line.unit_count;
  const uint32_t source_length = fushi_voice_hook::LookupUtf16SourceLength(
      text, units, submit.char_index);
  if (source_length == 0u) return false;
  const int required = WideCharToMultiByte(
      CP_UTF8, WC_ERR_INVALID_CHARS, text, static_cast<int>(units), nullptr, 0,
      nullptr, nullptr);
  if (required <= 0 ||
      static_cast<uint32_t>(required) > fushi_voice_hook::kLookupLineBytes) {
    return false;
  }
  char utf8[fushi_voice_hook::kLookupLineBytes] = {};
  if (WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, text,
                          static_cast<int>(units), utf8, required, nullptr,
                          nullptr) != required) {
    return false;
  }
  fushi_voice_hook::LookupGeometryHitPublication publication;
  publication.provider_kind =
      fushi_voice_hook::kLookupGeometryProviderEngineExactLayout;
  publication.provider_id =
      fushi_voice_hook::kLookupGeometryProviderIdSmashFzmedia;
  publication.char_index = submit.char_index;
  publication.source_length = source_length;
  publication.char_count = units;
  publication.coordinate_space =
      fushi_voice_hook::kLookupCoordinateSpaceClientPhysicalPixels;
  publication.writing_mode = fushi_voice_hook::kLookupWritingModeHorizontal;
  // The paragraph generation is both the semantic and the layout generation:
  // the adapter republishes cells and text together, never one without the
  // other, so a hit can never pair an old cell array with a newer line.
  publication.text_generation = submit.generation;
  publication.geometry_generation = submit.generation;
  publication.glyph_x = submit.x;
  publication.glyph_y = submit.y;
  publication.glyph_w = submit.w;
  publication.glyph_h = submit.h;
  publication.view_w = submit.client_w;
  publication.view_h = submit.client_h;
  publication.flags = fushi_voice_hook::kLookupHitFlagSubmit;
  publication.line_utf8 = reinterpret_cast<const uint8_t*>(utf8);
  publication.line_bytes = static_cast<uint32_t>(required);
  return fushi_voice_hook::g_geometry_provider_registry.PublishHit(header,
                                                                   publication);
}

// ── lifecycle (HookWorker) ──────────────────────────────────────────────────

bool SmashFzmediaLookupInstallImpl(fushi_voice_hook::SharedHeader* header) {
  auto& rt = g_smash_fzmedia_lookup;
  if (header == nullptr || !fushi_voice_hook::HasLookupRegion(header)) {
    return false;
  }
  if (rt.installed) return true;
  rt.installed = true;
  rt.has_line = false;
  rt.model_dirty = false;
  rt.latest_line = fushi_voice_hook::smash_fzmedia::LineSnapshot();
  rt.current_model = SmashFzmediaLookupModel();
  rt.epoch = smash_lookup_core::ProjectionEpoch();
  rt.origin_cache = smash_lookup_core::OriginCache();
  rt.provider_offered = false;
  rt.window_class_rejected = false;
  rt.subclass_failed = false;
  rt.processed_submit_seq = rt.submit_count.load(std::memory_order_acquire);
  rt.observed_win32_transaction.store(false, std::memory_order_release);
  // displaced_window deliberately survives reinstall: the stale chain entry
  // does too.  The window may not exist yet (early injection); LookupPoll
  // binds it.
  return true;
}

void SmashFzmediaLookupShutdownImpl(fushi_voice_hook::SharedHeader* header) {
  auto& rt = g_smash_fzmedia_lookup;
  if (!rt.installed) return;
  RetireSmashFzmediaProvider(header);
  TeardownSmashFzmediaSubclass();
  RevokeSmashFzmediaShieldProperties(header, true);
  rt.installed = false;
  rt.has_line = false;
  rt.model_dirty = false;
  rt.current_model = SmashFzmediaLookupModel();
  rt.processed_submit_seq = rt.submit_count.load(std::memory_order_acquire);
}

void SmashFzmediaLookupPollImpl(fushi_voice_hook::SharedHeader* header,
                                uint64_t /*now_ms*/) {
  auto& rt = g_smash_fzmedia_lookup;
  if (!rt.installed || header == nullptr ||
      !fushi_voice_hook::HasLookupRegion(header)) {
    return;
  }

  HWND window = rt.window.load(std::memory_order_acquire);
  if (window != nullptr && !IsWindow(window)) {
    TeardownSmashFzmediaSubclass();
    window = nullptr;
  }
  if (rt.displaced_window != nullptr && !IsWindow(rt.displaced_window)) {
    rt.displaced_window = nullptr;
  }
  if (window == nullptr) {
    const HWND candidate = FindSmashFzmediaGameWindow();
    if (candidate != nullptr && candidate != rt.displaced_window) {
      rt.subclass_failed = !InstallSmashFzmediaSubclass(candidate);
      window = rt.window.load(std::memory_order_acquire);
    }
  }
  const bool subclass_live =
      window != nullptr && rt.subclass_live.load(std::memory_order_acquire) &&
      SmashFzmediaSubclassOwnsWindow(window);
  if (window != nullptr && !subclass_live) {
    // Someone else replaced the procedure after us: our shield no longer
    // sees the messages.  Drop the offer, stop claiming Ready and never
    // re-enter this window's chain (see displaced_window).
    rt.displaced_window = window;
    TeardownSmashFzmediaSubclass();
    window = nullptr;
  }
  const bool shield_ready = MaintainSmashFzmediaShieldProperties(
      header, window, subclass_live);
  if (shield_ready && header != nullptr) {
    fushi_voice_hook::AtomicOrShared32(
        &header->lookup_diag, fushi_voice_hook::kLookupDiagSensorInstalled);
  }

  bool ready = false;
  if (subclass_live && rt.has_line &&
      fushi_voice_hook::AtomicLoadShared32(&header->lookup_enabled) != 0u) {
    ready = RefreshSmashFzmediaLookupModel(header, window);
  } else if (rt.current_model.geometry_ready) {
    rt.current_model.geometry_ready = false;
    InvalidateSmashFzmediaLookupModel();
  }

  if (ready) {
    if (fushi_voice_hook::g_geometry_provider_registry.OfferReady(
            g_header, fushi_voice_hook::kLookupGeometryProviderEngineExactLayout,
            fushi_voice_hook::kLookupGeometryProviderIdSmashFzmedia)) {
      rt.provider_offered = true;
      fushi_voice_hook::AtomicOrShared32(
          &header->lookup_diag,
          fushi_voice_hook::kLookupDiagGeometryObserved);
    } else {
      ready = false;
    }
  }
  if (!ready) RetireSmashFzmediaProvider(header);

  SmashFzmediaLookupSubmit submit;
  uint64_t submit_seq = 0u;
  if (ReadLatestSmashFzmediaLookupSubmit(&submit, &submit_seq) && ready) {
    (void)PublishSmashFzmediaLookupHit(header, submit);
  }
}

void SmashFzmediaLookupPublishSnapshotImpl(
    const fushi_voice_hook::smash_fzmedia::LineSnapshot& snapshot) {
  auto& rt = g_smash_fzmedia_lookup;
  if (!rt.installed) return;
  rt.latest_line = snapshot;
  rt.has_line = snapshot.generation != 0u && snapshot.unit_count != 0u &&
                snapshot.unit_count <=
                    fushi_voice_hook::smash_fzmedia::kMaxLineUnits;
  rt.model_dirty = true;
}

#else  // !_M_X64

bool SmashFzmediaLookupInstallImpl(fushi_voice_hook::SharedHeader*) {
  return false;
}
void SmashFzmediaLookupShutdownImpl(fushi_voice_hook::SharedHeader*) {}
void SmashFzmediaLookupPollImpl(fushi_voice_hook::SharedHeader*, uint64_t) {}
void SmashFzmediaLookupPublishSnapshotImpl(
    const fushi_voice_hook::smash_fzmedia::LineSnapshot&) {}

#endif  // _M_X64

// The declarations in smash_fzmedia_lookup.h live in
// fushi_voice_hook::smash_fzmedia; definitions must appear in an enclosing
// namespace, so step out of dll_main.cpp's anonymous namespace for them and
// step back in afterwards.  The anonymous helpers above remain visible here
// through the implicit using-directive.
}  // namespace

namespace fushi_voice_hook {
namespace smash_fzmedia {

bool LookupInstall(SharedHeader* header) {
  return SmashFzmediaLookupInstallImpl(header);
}

void LookupShutdown(SharedHeader* header) {
  SmashFzmediaLookupShutdownImpl(header);
}

void LookupPoll(SharedHeader* header, uint64_t now_ms) {
  SmashFzmediaLookupPollImpl(header, now_ms);
}

void LookupPublishSnapshot(const LineSnapshot& snapshot) {
  SmashFzmediaLookupPublishSnapshotImpl(snapshot);
}

}  // namespace smash_fzmedia
}  // namespace fushi_voice_hook

namespace {
