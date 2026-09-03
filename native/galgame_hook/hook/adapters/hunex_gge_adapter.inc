// HUNEX GGE resource-audio adapter.  The engine-generic HFA/HW parser lives
// in hook/hunex_hfa.h; this file only admits a measured title/archive role and
// connects playback-time reads to the common source-Ogg publication outlet.
#include "hunex_gge_profile.h"
#include "hunex_gge_capture_bridge.h"
#include "hunex_gge_selected_text.h"
#include "hunex_gge_lookup_runtime.inc"

bool IsHunexGgeProfileMatched();

#if defined(_M_X64)

using HunexGgeDrawTextFn = void (*)(
    void*, void*, void*, void*, uintptr_t, void*, uint32_t, void*, int32_t,
    int32_t, int32_t, double, uint32_t);
using HunexGgeGlyphFn = void (*)(void*, void*, uint32_t, void*, uint32_t,
                                 uint32_t);
using HunexGgeRenderItemFn = void* (*)(void*, void*, void*, void*);
using HunexGgeSurfaceComposeWrapperFn = uint32_t (*)(
    void*, void*, int32_t, uint32_t, const int32_t*, uint32_t, uint32_t);
using HunexGgeSurfaceComposeFn = uint32_t (*)(
    void*, void*, void*, int32_t, uint32_t, const int32_t*, uint32_t,
    uint32_t);
using HunexGgeSurfaceCompositorFn = uint32_t (*)(
    void*, int32_t, int32_t, const void*, uint32_t, uint32_t);
using HunexGgeTextureUploadFn = uint32_t (*)(void*, uint32_t);
using HunexGgeQuadVertexFn = uint32_t (*)(void*, const float*, const float*,
                                          const int32_t*);
using HunexGgeSpriteDrawFn = uint32_t (*)(void*, void*, void*, uint32_t);
using HunexGgeGetAsyncKeyStateFn = SHORT(WINAPI*)(int);

struct HunexGgeCpuSurfaceIdentity {
  uint32_t words[8] = {};
};

struct HunexGgePendingStoryCompose {
  bool active = false;
  uint64_t story_thread_address = 0u;
  uint64_t raw_text_hash = 0u;
  uint32_t render_thread_id = 0u;
  fushi_voice_hook::hunex_capture_bridge::LogicalRect final_glyph_rect = {};
  HunexGgeCpuSurfaceIdentity final_glyph_surface = {};
  ULONGLONG sealed_tick = 0u;
};

struct HunexGgePendingSurfaceChain {
  bool active = false;
  uint64_t generation = 0u;
  uint64_t story_thread_address = 0u;
  uint64_t raw_text_hash = 0u;
  uint32_t render_thread_id = 0u;
  HunexGgeCpuSurfaceIdentity surface = {};
  uintptr_t texture = 0u;
  uint64_t upload_sequence = 0u;
  ULONGLONG updated_tick = 0u;
};

struct HunexGgePendingQuad {
  bool valid = false;
  uintptr_t vertex_buffer = 0u;
  float xy[8] = {};
  float uv[8] = {};
  int32_t texture_width = 0;
  int32_t texture_height = 0;
  uint64_t sequence = 0u;
  ULONGLONG updated_tick = 0u;
};

struct HunexGgeProjectionEvidence {
  uint64_t generation = 0u;
  uint64_t draw_sequence = 0u;
  uint64_t story_thread_address = 0u;
  uint64_t raw_text_hash = 0u;
  uint64_t texture = 0u;
  uint64_t vertex_buffer = 0u;
  uint64_t device = 0u;
  uint64_t render_target = 0u;
  uint64_t published_tick = 0u;
  uint32_t render_thread_id = 0u;
  HunexGgeCpuSurfaceIdentity surface = {};
  float xy[8] = {};
  float uv[8] = {};
  int32_t viewport_x = 0;
  int32_t viewport_y = 0;
  int32_t viewport_width = 0;
  int32_t viewport_height = 0;
  int32_t backbuffer_width = 0;
  int32_t backbuffer_height = 0;
  int32_t client_width = 0;
  int32_t client_height = 0;
};

struct HunexGgeAtomicProjectionEvidence {
  std::atomic<uint32_t> sequence{0u};
  std::atomic<uint64_t> generation{0u};
  std::atomic<uint64_t> draw_sequence{0u};
  std::atomic<uint64_t> story_thread_address{0u};
  std::atomic<uint64_t> raw_text_hash{0u};
  std::atomic<uint64_t> texture{0u};
  std::atomic<uint64_t> vertex_buffer{0u};
  std::atomic<uint64_t> device{0u};
  std::atomic<uint64_t> render_target{0u};
  std::atomic<uint64_t> published_tick{0u};
  std::atomic<uint32_t> render_thread_id{0u};
  std::array<std::atomic<uint32_t>, 8u> surface_words = {};
  std::array<std::atomic<uint32_t>, 8u> xy_bits = {};
  std::array<std::atomic<uint32_t>, 8u> uv_bits = {};
  std::atomic<int32_t> viewport_x{0};
  std::atomic<int32_t> viewport_y{0};
  std::atomic<int32_t> viewport_width{0};
  std::atomic<int32_t> viewport_height{0};
  std::atomic<int32_t> backbuffer_width{0};
  std::atomic<int32_t> backbuffer_height{0};
  std::atomic<int32_t> client_width{0};
  std::atomic<int32_t> client_height{0};
};

static_assert(std::atomic<uint64_t>::is_always_lock_free,
              "HUNEX projection trace requires lock-free x64 atomics");
using HunexGgeSemanticSubmitFn = int(__fastcall *)(
    void*, void**, uint32_t, int32_t, int32_t, const uint64_t*);

struct HunexGgeRuntimeAnchors {
  uintptr_t module = 0;
  size_t image_size = 0;
  uintptr_t draw = 0;
  uintptr_t glyph = 0;
  uintptr_t render_item = 0;
  uintptr_t body_submit = 0;
  uintptr_t surface_compose_wrapper = 0;
  uintptr_t surface_compose = 0;
  uintptr_t surface_compositor = 0;
  uintptr_t texture_upload = 0;
  uintptr_t quad_vertex = 0;
  uintptr_t sprite_draw = 0;
  uintptr_t key_poller = 0;
  uintptr_t input_pump = 0;
  uintptr_t semantic_submit = 0;
  uintptr_t held_action_mask = 0;
  uintptr_t direct_first_glyph_return = 0;
  uintptr_t direct_second_glyph_return = 0;
  uintptr_t render_item_return = 0;
  uintptr_t body_submit_return = 0;
  uintptr_t surface_compose_zero_first_return = 0;
  uintptr_t surface_compose_zero_second_return = 0;
  uintptr_t surface_compose_first_return = 0;
  uintptr_t surface_compose_second_return = 0;
  uintptr_t surface_compose_final_first_return = 0;
  uintptr_t surface_compose_final_second_return = 0;
  uintptr_t viewport_rect = 0;
  uintptr_t scale_x = 0;
  uintptr_t scale_y = 0;
  uintptr_t generic_key_return = 0;
  uintptr_t left_button_return = 0;
  uintptr_t async_key_state = 0;
};

struct HunexGgeGlyphEvidence {
  bool valid = false;
  uint32_t calls_since_render = 0;
  uint32_t caller_rva = 0;
  uint32_t glyph_ordinal = 0;
  uint32_t utf16_char_index = 0;
  uint32_t scalar_width = 0;
  uint32_t descriptor_words[8] = {};
  uint32_t output_words[28] = {};
};

struct HunexGgeDrawContext {
  bool active = false;
  uint64_t draw_sequence = 0;
  uint64_t text_hash = 0;
  uint32_t text_units = 0;
  uint32_t visible_units = 0;
  fushi_voice_hook::hunex_lookup::GlyphTraceCursor glyph_trace_cursor;
  uint32_t arg7 = 0;
  int32_t x = 0;
  int32_t y = 0;
  int32_t width = 0;
  int32_t alignment_mode = 0;
  bool alignment_mode_read = false;
  HunexGgeGlyphEvidence pending_glyph;
};

struct HunexGgeBodyTraversalFence {
  bool active = false;
  bool raw_text_layout_valid = false;
  uint64_t story_thread_address = 0u;
  uint64_t raw_text_hash = 0u;
  uint32_t raw_text_units = 0u;
  uint32_t last_raw_utf16_index = 0u;
  uint32_t next_visible_glyph_ordinal = 0u;
  fushi_voice_hook::hunex_lookup_core::RawTextLayout raw_text_layout;
};

struct HunexGgeSurfaceComposeContext {
  bool active = false;
  bool wrapper_scope = false;
  bool suppress_compositor = false;
  bool destinations_read = false;
  uint64_t generation = 0u;
  uintptr_t line_this = 0u;
  uint32_t blend = 0u;
  uintptr_t wrapper_destination = 0u;
  uintptr_t wrapper_x_offsets = 0u;
  uint32_t wrapper_layout_selector = 0u;
  uint32_t wrapper_node_filter = 0u;
  HunexGgeCpuSurfaceIdentity original_destination_a = {};
  HunexGgeCpuSurfaceIdentity original_destination_b = {};
  HunexGgePendingStoryCompose diagnostic_story = {};
  HunexGgePendingStoryCompose story = {};
  uint32_t compositor_call_count = 0u;
  uint32_t compositor_descriptor_count = 0u;
  uint32_t story_source_match_count = 0u;
  uint32_t candidate_count = 0u;
  uint32_t final_link_count = 0u;
  HunexGgeCpuSurfaceIdentity candidate_destination = {};
  HunexGgeCpuSurfaceIdentity final_destination = {};
};

HunexGgeRuntimeAnchors g_hunex_gge_anchors;
fushi_voice_hook::hunex_capture_bridge::TraversalCaptureBridge
    g_hunex_gge_capture_bridge;
HunexGgeLookupRuntime g_hunex_gge_lookup_runtime;
HunexGgeDrawTextFn g_orig_hunex_gge_draw_text = nullptr;
HunexGgeGlyphFn g_orig_hunex_gge_glyph = nullptr;
HunexGgeRenderItemFn g_orig_hunex_gge_render_item = nullptr;
HunexGgeSurfaceComposeWrapperFn g_orig_hunex_gge_surface_compose_wrapper =
    nullptr;
HunexGgeSurfaceComposeFn g_orig_hunex_gge_surface_compose = nullptr;
HunexGgeSurfaceCompositorFn g_orig_hunex_gge_surface_compositor = nullptr;
HunexGgeTextureUploadFn g_orig_hunex_gge_texture_upload = nullptr;
HunexGgeQuadVertexFn g_orig_hunex_gge_quad_vertex = nullptr;
HunexGgeSpriteDrawFn g_orig_hunex_gge_sprite_draw = nullptr;
HunexGgeGetAsyncKeyStateFn g_orig_hunex_gge_get_async_key_state = nullptr;
HunexGgeSemanticSubmitFn g_orig_hunex_gge_semantic_submit = nullptr;
volatile LONG g_hunex_gge_trace_scan_state = 0;
volatile LONG g_hunex_gge_trace_hooks_ready = 0;
volatile LONG g_hunex_gge_trace_writer = 0;
volatile LONG64 g_hunex_gge_surface_compose_generation = 0;
std::atomic<uint64_t> g_hunex_gge_texture_upload_sequence{0u};
std::atomic<uint64_t> g_hunex_gge_quad_sequence{0u};
std::atomic<uint64_t> g_hunex_gge_sprite_draw_sequence{0u};
HunexGgeAtomicProjectionEvidence g_hunex_gge_projection_evidence;
// Capture mutation is a worker-owned lifecycle gate. Render detours remain
// trace-capable while it is zero, but cannot touch bridge publication state.
volatile LONG g_hunex_gge_capture_mutation_admitted = 0;
volatile LONG g_hunex_gge_input_trace_state[2][256] = {};
thread_local HunexGgeDrawContext g_hunex_gge_draw_context;
thread_local HunexGgeGlyphEvidence g_hunex_gge_recent_glyph;
thread_local HunexGgeBodyTraversalFence g_hunex_gge_body_traversal_fence;
thread_local HunexGgeSurfaceComposeContext g_hunex_gge_surface_compose_context;
thread_local HunexGgePendingStoryCompose g_hunex_gge_pending_story_compose;
thread_local HunexGgePendingSurfaceChain g_hunex_gge_pending_surface_chain;
thread_local HunexGgePendingQuad g_hunex_gge_pending_quad;

struct HunexGgeProjectionDiagnosticDedup {
  uint64_t story_thread_address = 0u;
  uint64_t raw_text_hash = 0u;
  std::array<uint64_t, 4u> emitted_failures = {};
};

thread_local HunexGgeProjectionDiagnosticDedup
    g_hunex_gge_projection_diagnostic_dedup;

using HunexGgeCaptureQuarantineReason =
    fushi_voice_hook::hunex_capture_bridge::CaptureQuarantineReason;
static_assert(
    static_cast<uint32_t>(HunexGgeCaptureQuarantineReason::kNone) ==
        fushi_voice_hook::kHunexGgeTraceCaptureQuarantineNone,
    "HUNEX capture quarantine reason ABI drifted");
static_assert(
    static_cast<uint32_t>(
        HunexGgeCaptureQuarantineReason::kReentrantCallback) ==
        fushi_voice_hook::kHunexGgeTraceCaptureQuarantineReentrantCallback,
    "HUNEX capture quarantine reason ABI drifted");
static_assert(
    static_cast<uint32_t>(
        HunexGgeCaptureQuarantineReason::kInvalidRenderThreadId) ==
        fushi_voice_hook::
            kHunexGgeTraceCaptureQuarantineInvalidRenderThreadId,
    "HUNEX capture quarantine reason ABI drifted");
static_assert(
    static_cast<uint32_t>(
        HunexGgeCaptureQuarantineReason::kRenderThreadConflict) ==
        fushi_voice_hook::kHunexGgeTraceCaptureQuarantineRenderThreadConflict,
    "HUNEX capture quarantine reason ABI drifted");
static_assert(
    static_cast<uint32_t>(
        HunexGgeCaptureQuarantineReason::kLineIdentityOrFenceInvalid) ==
        fushi_voice_hook::
            kHunexGgeTraceCaptureQuarantineLineIdentityOrFenceInvalid,
    "HUNEX capture quarantine reason ABI drifted");
static_assert(
    static_cast<uint32_t>(
        HunexGgeCaptureQuarantineReason::kSlotSequenceOverflow) ==
        fushi_voice_hook::
            kHunexGgeTraceCaptureQuarantineSlotSequenceOverflow,
    "HUNEX capture quarantine reason ABI drifted");

uint64_t g_hunex_gge_lookup_last_snapshot_epoch = 0u;
uint64_t g_hunex_gge_lookup_last_selected_text_seq = 0u;
uint64_t g_hunex_gge_lookup_last_selected_thread_id = 0u;
uint64_t g_hunex_gge_lookup_last_raw_text_hash = 0u;
uint64_t g_hunex_gge_lookup_last_story_thread_address = 0u;
uint16_t g_hunex_gge_lookup_last_raw_text_units = 0u;
std::array<uint16_t,
           fushi_voice_hook::hunex_capture_bridge::kTextCapacity>
    g_hunex_gge_lookup_last_raw_text = {};

enum HunexGgeLookupWorkerTraceState : LONG {
  kHunexGgeLookupWorkerIdle = 0,
  kHunexGgeLookupWorkerGateClosed = 1,
  kHunexGgeLookupWorkerNoSnapshot = 2,
  kHunexGgeLookupWorkerInvalidViewportOrSnapshot = 3,
  kHunexGgeLookupWorkerSelectedTextRejected = 4,
  kHunexGgeLookupWorkerProjectionRejected = 5,
  kHunexGgeLookupWorkerModelRejected = 6,
  kHunexGgeLookupWorkerGeometryPublished = 7,
  kHunexGgeLookupWorkerGeometryRetained = 8,
};

volatile LONG g_hunex_gge_lookup_worker_trace_state =
    kHunexGgeLookupWorkerIdle;
volatile LONG g_hunex_gge_lookup_worker_selected_failure = 0;

void SetHunexGgeLookupWorkerTraceState(
    HunexGgeLookupWorkerTraceState state,
    fushi_voice_hook::HunexGgeSelectedTextFailure selected_failure =
        fushi_voice_hook::HunexGgeSelectedTextFailure::kNone) {
  InterlockedExchange(&g_hunex_gge_lookup_worker_selected_failure,
                      static_cast<LONG>(selected_failure));
  InterlockedExchange(&g_hunex_gge_lookup_worker_trace_state,
                      static_cast<LONG>(state));
}

void PublishHunexGgeLookupGateDiagnostics(uint32_t gate_mask) {
  auto* trace = &FushiHunexGgeTraceV3;
  InterlockedExchange(
      reinterpret_cast<volatile LONG*>(&trace->lookup_gate_mask),
      static_cast<LONG>(gate_mask));
  InterlockedExchange(
      reinterpret_cast<volatile LONG*>(&trace->capture_quarantine_reason),
      static_cast<LONG>(g_hunex_gge_capture_bridge.quarantine_reason()));
  InterlockedExchange(
      reinterpret_cast<volatile LONG*>(
          &trace->capture_quarantine_bound_thread_id),
      static_cast<LONG>(
          g_hunex_gge_capture_bridge.quarantine_bound_render_thread_id()));
  InterlockedExchange(
      reinterpret_cast<volatile LONG*>(
          &trace->capture_quarantine_conflicting_thread_id),
      static_cast<LONG>(
          g_hunex_gge_capture_bridge.quarantine_conflicting_thread_id()));
}

void StampHunexGgeBodySubmitLookupDiagnostics(
    fushi_voice_hook::HunexGgeTraceEvent* event) {
  if (event == nullptr) return;
  event->lookup_gate_mask = static_cast<uint32_t>(InterlockedCompareExchange(
      reinterpret_cast<volatile LONG*>(
          &FushiHunexGgeTraceV3.lookup_gate_mask),
      0, 0));
  event->capture_quarantine_reason = static_cast<uint32_t>(
      g_hunex_gge_capture_bridge.quarantine_reason());
  event->capture_quarantine_bound_thread_id =
      g_hunex_gge_capture_bridge.quarantine_bound_render_thread_id();
  event->capture_quarantine_conflicting_thread_id =
      g_hunex_gge_capture_bridge.quarantine_conflicting_thread_id();
  if (event->capture_quarantine_reason !=
      fushi_voice_hook::kHunexGgeTraceCaptureQuarantineNone) {
    event->lookup_gate_mask |=
        fushi_voice_hook::kHunexGgeTraceLookupCaptureQuarantined;
  }
}

uint32_t HunexGgeRva(uintptr_t address) {
  const uintptr_t module = g_hunex_gge_anchors.module;
  if (address < module || g_hunex_gge_anchors.image_size == 0u ||
      address - module >= g_hunex_gge_anchors.image_size ||
      address - module > UINT32_MAX) {
    return 0u;
  }
  return static_cast<uint32_t>(address - module);
}

uint64_t ReadStableHunexGgeTextWindowThroughSeq() {
  if (g_header == nullptr)
    return 0u;
  const uint64_t before = fushi_voice_hook::AtomicLoadPreview64(
      &g_header->text_write_count);
  MemoryBarrier();
  const uint64_t after = fushi_voice_hook::AtomicLoadPreview64(
      &g_header->text_write_count);
  return before != 0u && before == after ? after : 0u;
}

bool IsHunexGgeCaptureMutationAdmitted() {
  return !g_stop && g_header != nullptr &&
         fushi_voice_hook::HasLookupRegion(g_header) &&
         g_header->lookup_enabled != 0u &&
         InterlockedCompareExchange(
             &g_hunex_gge_capture_mutation_admitted, 0, 0) != 0 &&
         !g_hunex_gge_capture_bridge.quarantined();
}

void PublishHunexGgeTrace(fushi_voice_hook::HunexGgeTraceEvent event) {
  auto* trace = &FushiHunexGgeTraceV3;
  // The exported v3 event keeps sequence at the front for a fixed cross-arch
  // layout.  Serialize writers without waiting, then advance next_sequence
  // only after the complete slot is visible; a contending renderer/input
  // callback drops diagnostics instead of blocking the game thread.
  if (InterlockedCompareExchange(&g_hunex_gge_trace_writer, 1, 0) != 0) {
    InterlockedIncrement64(
        reinterpret_cast<volatile LONG64*>(&trace->dropped_busy));
    return;
  }
  const uint64_t sequence = static_cast<uint64_t>(
                                InterlockedCompareExchange64(
                                    reinterpret_cast<volatile LONG64*>(
                                        &trace->next_sequence),
                                    0, 0)) +
                            1u;
  auto* slot = &trace->slots[(sequence - 1u) % trace->capacity];
  if (InterlockedCompareExchange(
          reinterpret_cast<volatile LONG*>(&slot->writing), 1, 0) != 0) {
    InterlockedIncrement64(
        reinterpret_cast<volatile LONG64*>(&trace->dropped_busy));
    InterlockedExchange(&g_hunex_gge_trace_writer, 0);
    return;
  }
  event.sequence = sequence;
  event.timestamp_ms = GetTickCount64();
  event.thread_id = GetCurrentThreadId();
  slot->event = event;
  MemoryBarrier();
  InterlockedExchange(reinterpret_cast<volatile LONG*>(&slot->writing), 0);
  InterlockedExchange64(
      reinterpret_cast<volatile LONG64*>(&trace->next_sequence),
      static_cast<LONG64>(sequence));
  InterlockedExchange(&g_hunex_gge_trace_writer, 0);
}

void PublishHunexGgeProjectionDiagnostic(
    fushi_voice_hook::HunexGgeTraceEvent event,
    fushi_voice_hook::HunexGgeProjectionTraceStage stage,
    fushi_voice_hook::HunexGgeProjectionTraceFailure failure) {
  const uint32_t stage_value = static_cast<uint32_t>(stage);
  const int32_t failure_value = static_cast<int32_t>(failure);
  if (event.story_line_base == 0u || event.story_line_hash == 0u ||
      stage_value == 0u || stage_value > 4u || failure_value < 0 ||
      failure_value >= 64) {
    return;
  }
  auto& dedup = g_hunex_gge_projection_diagnostic_dedup;
  if (dedup.story_thread_address != event.story_line_base ||
      dedup.raw_text_hash != event.story_line_hash) {
    dedup = {};
    dedup.story_thread_address = event.story_line_base;
    dedup.raw_text_hash = event.story_line_hash;
  }
  const uint64_t failure_bit = uint64_t{1} << failure_value;
  uint64_t& emitted = dedup.emitted_failures[stage_value - 1u];
  if ((emitted & failure_bit) != 0u) return;
  emitted |= failure_bit;
  event.kind = static_cast<uint32_t>(
      fushi_voice_hook::HunexGgeTraceKind::kProjectionDiagnostic);
  event.arg7 = stage_value;
  event.result = failure_value;
  PublishHunexGgeTrace(event);
}

uint32_t HunexGgeContainingFunctionRva(uintptr_t address) {
  DWORD64 image_base = 0u;
  const PRUNTIME_FUNCTION runtime =
      RtlLookupFunctionEntry(static_cast<DWORD64>(address), &image_base,
                             nullptr);
  if (runtime == nullptr || image_base != g_hunex_gge_anchors.module) {
    return 0u;
  }
  return HunexGgeRva(static_cast<uintptr_t>(image_base) +
                     runtime->BeginAddress);
}

bool CaptureHunexGgeViewportTransform(
    fushi_voice_hook::HunexGgeTraceEvent* event) {
  if (event == nullptr || g_hunex_gge_anchors.viewport_rect == 0u ||
      g_hunex_gge_anchors.scale_x == 0u ||
      g_hunex_gge_anchors.scale_y == 0u) {
    return false;
  }
  bool valid = false;
  __try {
    const RECT rect = *reinterpret_cast<const RECT*>(
        g_hunex_gge_anchors.viewport_rect);
    const float scale_x =
        *reinterpret_cast<const float*>(g_hunex_gge_anchors.scale_x);
    const float scale_y =
        *reinterpret_cast<const float*>(g_hunex_gge_anchors.scale_y);
    const int64_t width = static_cast<int64_t>(rect.right) - rect.left;
    const int64_t height = static_cast<int64_t>(rect.bottom) - rect.top;
    // NaN fails value==value.  The generous scale/extent bounds retain DPI
    // and letterbox evidence while rejecting uninitialised globals.
    if (width > 0 && width <= 32768 && height > 0 && height <= 32768 &&
        scale_x == scale_x && scale_y == scale_y && scale_x > 0.0f &&
        scale_y > 0.0f && scale_x <= 16.0f && scale_y <= 16.0f) {
      event->viewport_left = rect.left;
      event->viewport_top = rect.top;
      event->viewport_right = rect.right;
      event->viewport_bottom = rect.bottom;
      std::memcpy(&event->scale_x_bits, &scale_x,
                  sizeof(event->scale_x_bits));
      std::memcpy(&event->scale_y_bits, &scale_y,
                  sizeof(event->scale_y_bits));
      event->evidence_flags |=
          fushi_voice_hook::kHunexGgeTraceEvidenceViewportTransformRead;
      valid = true;
    }
  } __except (EXCEPTION_EXECUTE_HANDLER) {
    valid = false;
  }
  return valid;
}

bool ReadHunexGgeStoryLine(uintptr_t line_base, uint16_t* copied,
                           size_t copied_capacity, uint32_t* units,
                           uint64_t* hash) {
  if (line_base == 0u || copied == nullptr || units == nullptr ||
      hash == nullptr ||
      copied_capacity <
          fushi_voice_hook::hunex_lookup::kBodySubmitMaxLineUnits) {
    return false;
  }
  *units = 0u;
  *hash = 0u;
  bool terminated = false;
  __try {
    terminated = fushi_voice_hook::hunex_lookup::
        CopyBoundedNullTerminatedUtf16(
            reinterpret_cast<const uint16_t*>(line_base),
            fushi_voice_hook::hunex_lookup::kBodySubmitMaxLineUnits,
            copied, copied_capacity, units);
  } __except (EXCEPTION_EXECUTE_HANDLER) {
    terminated = false;
  }
  if (!terminated) return false;
  *hash = fushi_voice_hook::hunex_lookup::HashUtf16Units(copied, *units);
  return *units != 0u && *hash != 0u;
}

bool CaptureHunexGgeStoryLine(
    uintptr_t line_base, uint16_t* copied, size_t copied_capacity,
    uint32_t* units, uint64_t* hash,
    fushi_voice_hook::HunexGgeTraceEvent* event) {
  if (line_base == 0u || copied == nullptr || units == nullptr ||
      hash == nullptr || event == nullptr) {
    return false;
  }
  // Freeze one bounded line exactly once. Trace identity, grammar analysis and
  // the published bridge snapshot must all consume these same bytes: HUNEX
  // reuses the live line buffer, so a second read is a real TOCTOU boundary.
  if (!ReadHunexGgeStoryLine(line_base, copied, copied_capacity, units,
                             hash)) {
    return false;
  }
  event->story_line_base = static_cast<uint64_t>(line_base);
  event->story_line_hash = *hash;
  event->story_line_units = *units;
  event->evidence_flags |=
      fushi_voice_hook::kHunexGgeTraceEvidenceStoryLineBounded;
  return true;
}

constexpr ULONGLONG kHunexGgeProjectionFreshnessMs = 2000u;
constexpr double kHunexGgeAffineResidualPixels = 0.75;

uint32_t HunexGgeFloatBits(float value) {
  uint32_t bits = 0u;
  std::memcpy(&bits, &value, sizeof(bits));
  return bits;
}

float HunexGgeFloatFromBits(uint32_t bits) {
  float value = 0.0f;
  std::memcpy(&value, &bits, sizeof(value));
  return value;
}

bool IsSaneHunexGgeCpuSurface(const HunexGgeCpuSurfaceIdentity& surface) {
  const uint32_t width = surface.words[1];
  const uint32_t height = surface.words[2];
  const uint64_t pixels = static_cast<uint64_t>(surface.words[4]) |
                          (static_cast<uint64_t>(surface.words[5]) << 32u);
  const int64_t stride = static_cast<int32_t>(surface.words[6]);
  const int64_t absolute_stride = stride < 0 ? -stride : stride;
  return surface.words[0] == 2u && width != 0u && width <= 32768u &&
         height != 0u && height <= 32768u && pixels != 0u && stride != 0 &&
         absolute_stride >= static_cast<int64_t>(width) * 4 &&
         absolute_stride <= (int64_t{1} << 30u);
}

bool ReadHunexGgeCpuSurfaceIdentity(
    const void* descriptor, HunexGgeCpuSurfaceIdentity* output) {
  if (descriptor == nullptr || output == nullptr) return false;
  HunexGgeCpuSurfaceIdentity candidate;
  bool read = false;
  __try {
    std::memcpy(candidate.words, descriptor, sizeof(candidate.words));
    read = true;
  } __except (EXCEPTION_EXECUTE_HANDLER) {
    read = false;
  }
  if (!read || !IsSaneHunexGgeCpuSurface(candidate)) return false;
  *output = candidate;
  return true;
}

bool SameHunexGgeCpuSurface(const HunexGgeCpuSurfaceIdentity& left,
                            const HunexGgeCpuSurfaceIdentity& right) {
  return std::memcmp(left.words, right.words, sizeof(left.words)) == 0;
}

uint32_t CountHunexGgeOriginalSurfaceMatches(
    const HunexGgeSurfaceComposeContext& context,
    const HunexGgeCpuSurfaceIdentity& surface) {
  uint32_t matches = 0u;
  if (SameHunexGgeCpuSurface(context.original_destination_a, surface)) {
    ++matches;
  }
  if (SameHunexGgeCpuSurface(context.original_destination_b, surface)) {
    ++matches;
  }
  return matches;
}

bool IsFreshHunexGgeProjectionTick(ULONGLONG then, ULONGLONG now) {
  return then != 0u && now >= then &&
         now - then <= kHunexGgeProjectionFreshnessMs;
}

HunexGgeSurfaceComposeContext BeginHunexGgeSurfaceComposeContext(
    void* line_this, uint32_t blend, const void* destination_a,
    const void* destination_b, bool wrapper_scope) {
  HunexGgeSurfaceComposeContext context;
  if (line_this == nullptr) return context;
  context.active = true;
  context.wrapper_scope = wrapper_scope;
  context.generation = static_cast<uint64_t>(InterlockedIncrement64(
      &g_hunex_gge_surface_compose_generation));
  context.line_this = reinterpret_cast<uintptr_t>(line_this);
  context.blend = blend;
  context.destinations_read =
      ReadHunexGgeCpuSurfaceIdentity(destination_a,
                                     &context.original_destination_a) &&
      (wrapper_scope ||
       ReadHunexGgeCpuSurfaceIdentity(destination_b,
                                      &context.original_destination_b));
  const ULONGLONG now = GetTickCount64();
  if (g_hunex_gge_pending_story_compose.active) {
    context.diagnostic_story = g_hunex_gge_pending_story_compose;
  }
  if (context.destinations_read && context.diagnostic_story.active &&
      context.diagnostic_story.render_thread_id == GetCurrentThreadId() &&
      IsFreshHunexGgeProjectionTick(
          context.diagnostic_story.sealed_tick, now)) {
    context.story = context.diagnostic_story;
  }
  return context;
}

void CompleteHunexGgeSurfaceComposeContext(
    const HunexGgeSurfaceComposeContext& completed) {
  if (!completed.active) return;
  const ULONGLONG now = GetTickCount64();
  if (!completed.story.active) {
    if (completed.diagnostic_story.active) {
      fushi_voice_hook::HunexGgeTraceEvent event;
      event.draw_sequence = completed.generation;
      event.text_hash = completed.line_this;
      event.draw_arg12_bits = completed.wrapper_destination;
      event.story_line_base =
          completed.diagnostic_story.story_thread_address;
      event.story_line_hash = completed.diagnostic_story.raw_text_hash;
      event.draw_arg13 = completed.blend;
      PublishHunexGgeProjectionDiagnostic(
          event, fushi_voice_hook::HunexGgeProjectionTraceStage::kWrapper,
          IsFreshHunexGgeProjectionTick(
              completed.diagnostic_story.sealed_tick, now)
              ? fushi_voice_hook::HunexGgeProjectionTraceFailure::
                    kWrapperDestinationUnreadable
              : fushi_voice_hook::HunexGgeProjectionTraceFailure::
                    kWrapperStoryExpired);
    }
    return;
  }
  HunexGgeCpuSurfaceIdentity final_surface;
  bool unique_chain = false;
  if (completed.candidate_count == 1u) {
    if (completed.blend == 0u &&
        CountHunexGgeOriginalSurfaceMatches(
            completed, completed.candidate_destination) == 1u) {
      final_surface = completed.candidate_destination;
      unique_chain = true;
    } else if (completed.blend != 0u &&
               completed.final_link_count == 1u &&
               CountHunexGgeOriginalSurfaceMatches(
                   completed, completed.final_destination) == 1u) {
      final_surface = completed.final_destination;
      unique_chain = true;
    }
  }
  if (unique_chain && IsSaneHunexGgeCpuSurface(final_surface)) {
    HunexGgePendingSurfaceChain pending;
    pending.active = true;
    pending.generation = completed.generation;
    pending.story_thread_address = completed.story.story_thread_address;
    pending.raw_text_hash = completed.story.raw_text_hash;
    pending.render_thread_id = completed.story.render_thread_id;
    pending.surface = final_surface;
    pending.updated_tick = now;
    g_hunex_gge_pending_surface_chain = pending;
  }
  fushi_voice_hook::HunexGgeProjectionTraceFailure diagnostic_failure =
      fushi_voice_hook::HunexGgeProjectionTraceFailure::kNone;
  if (completed.compositor_call_count == 0u) {
    diagnostic_failure = fushi_voice_hook::HunexGgeProjectionTraceFailure::
        kCompositorNotObserved;
  } else if (completed.compositor_descriptor_count == 0u) {
    diagnostic_failure = fushi_voice_hook::HunexGgeProjectionTraceFailure::
        kCompositorDescriptorUnreadable;
  } else if (completed.candidate_count == 0u) {
    diagnostic_failure = fushi_voice_hook::HunexGgeProjectionTraceFailure::
        kCompositorStorySurfaceMismatch;
  } else if (completed.candidate_count != 1u) {
    diagnostic_failure = fushi_voice_hook::HunexGgeProjectionTraceFailure::
        kCompositorCandidateAmbiguous;
  } else if (completed.blend == 0u &&
             CountHunexGgeOriginalSurfaceMatches(
                 completed, completed.candidate_destination) != 1u) {
    diagnostic_failure = fushi_voice_hook::HunexGgeProjectionTraceFailure::
        kCompositorDestinationMismatch;
  } else if (completed.blend != 0u && completed.final_link_count == 0u) {
    diagnostic_failure = fushi_voice_hook::HunexGgeProjectionTraceFailure::
        kCompositorFinalLinkMissing;
  } else if (completed.blend != 0u && completed.final_link_count != 1u) {
    diagnostic_failure = fushi_voice_hook::HunexGgeProjectionTraceFailure::
        kCompositorFinalLinkAmbiguous;
  } else if (completed.blend != 0u &&
             CountHunexGgeOriginalSurfaceMatches(
                 completed, completed.final_destination) != 1u) {
    diagnostic_failure = fushi_voice_hook::HunexGgeProjectionTraceFailure::
        kCompositorDestinationMismatch;
  } else if (!unique_chain || !IsSaneHunexGgeCpuSurface(final_surface)) {
    diagnostic_failure = fushi_voice_hook::HunexGgeProjectionTraceFailure::
        kCompositorFinalSurfaceInvalid;
  }
  fushi_voice_hook::HunexGgeTraceEvent diagnostic;
  diagnostic.draw_sequence = completed.generation;
  diagnostic.text_hash = completed.line_this;
  diagnostic.draw_arg12_bits = completed.wrapper_destination;
  diagnostic.story_line_base = completed.story.story_thread_address;
  diagnostic.story_line_hash = completed.story.raw_text_hash;
  diagnostic.text_units = completed.candidate_count;
  diagnostic.visible_units = completed.final_link_count;
  diagnostic.glyph_ordinal = completed.compositor_call_count;
  diagnostic.utf16_char_index = completed.compositor_descriptor_count;
  diagnostic.scalar_width = completed.story_source_match_count;
  diagnostic.draw_arg13 = completed.blend;
  diagnostic.related_caller_rva = HunexGgeRva(
      completed.wrapper_scope ? g_hunex_gge_anchors.surface_compose_wrapper
                              : g_hunex_gge_anchors.surface_compose);
  diagnostic.outer_function_rva =
      HunexGgeRva(g_hunex_gge_anchors.surface_compositor);
  if (completed.compositor_call_count != 0u) {
    diagnostic.evidence_flags |=
        fushi_voice_hook::kHunexGgeTraceEvidenceSurfaceComposeGraph;
  }
  if (completed.destinations_read ||
      completed.compositor_descriptor_count != 0u) {
    diagnostic.evidence_flags |=
        fushi_voice_hook::kHunexGgeTraceEvidenceSurfaceDescriptorsRead;
  }
  std::memcpy(diagnostic.descriptor_words,
              completed.original_destination_a.words,
              sizeof(diagnostic.descriptor_words));
  std::memcpy(diagnostic.output_words,
              completed.original_destination_b.words,
              sizeof(completed.original_destination_b.words));
  PublishHunexGgeProjectionDiagnostic(
      diagnostic,
      fushi_voice_hook::HunexGgeProjectionTraceStage::kCompositor,
      diagnostic_failure);
  if (completed.candidate_count != 0u ||
      !IsFreshHunexGgeProjectionTick(completed.story.sealed_tick, now)) {
    g_hunex_gge_pending_story_compose = {};
  }
}

void PublishHunexGgeProjectionEvidence(
    const HunexGgeProjectionEvidence& evidence) {
  auto& target = g_hunex_gge_projection_evidence;
  uint32_t sequence = target.sequence.load(std::memory_order_acquire);
  if ((sequence & 1u) != 0u ||
      !target.sequence.compare_exchange_strong(
          sequence, sequence + 1u, std::memory_order_acq_rel,
          std::memory_order_acquire)) {
    return;
  }
  target.generation.store(evidence.generation, std::memory_order_relaxed);
  target.draw_sequence.store(evidence.draw_sequence,
                             std::memory_order_relaxed);
  target.story_thread_address.store(evidence.story_thread_address,
                                    std::memory_order_relaxed);
  target.raw_text_hash.store(evidence.raw_text_hash,
                             std::memory_order_relaxed);
  target.texture.store(evidence.texture, std::memory_order_relaxed);
  target.vertex_buffer.store(evidence.vertex_buffer,
                             std::memory_order_relaxed);
  target.device.store(evidence.device, std::memory_order_relaxed);
  target.render_target.store(evidence.render_target,
                             std::memory_order_relaxed);
  target.published_tick.store(evidence.published_tick,
                              std::memory_order_relaxed);
  target.render_thread_id.store(evidence.render_thread_id,
                                std::memory_order_relaxed);
  for (size_t index = 0u; index < 8u; ++index) {
    target.surface_words[index].store(evidence.surface.words[index],
                                      std::memory_order_relaxed);
    target.xy_bits[index].store(HunexGgeFloatBits(evidence.xy[index]),
                                std::memory_order_relaxed);
    target.uv_bits[index].store(HunexGgeFloatBits(evidence.uv[index]),
                                std::memory_order_relaxed);
  }
  target.viewport_x.store(evidence.viewport_x, std::memory_order_relaxed);
  target.viewport_y.store(evidence.viewport_y, std::memory_order_relaxed);
  target.viewport_width.store(evidence.viewport_width,
                              std::memory_order_relaxed);
  target.viewport_height.store(evidence.viewport_height,
                               std::memory_order_relaxed);
  target.backbuffer_width.store(evidence.backbuffer_width,
                                std::memory_order_relaxed);
  target.backbuffer_height.store(evidence.backbuffer_height,
                                 std::memory_order_relaxed);
  target.client_width.store(evidence.client_width, std::memory_order_relaxed);
  target.client_height.store(evidence.client_height,
                             std::memory_order_relaxed);
  target.sequence.store(sequence + 2u, std::memory_order_release);
}

bool ReadHunexGgeProjectionEvidence(HunexGgeProjectionEvidence* output) {
  if (output == nullptr) return false;
  auto& source = g_hunex_gge_projection_evidence;
  for (uint32_t attempt = 0u; attempt < 3u; ++attempt) {
    const uint32_t before = source.sequence.load(std::memory_order_acquire);
    if (before == 0u || (before & 1u) != 0u) return false;
    HunexGgeProjectionEvidence candidate;
    candidate.generation = source.generation.load(std::memory_order_relaxed);
    candidate.draw_sequence =
        source.draw_sequence.load(std::memory_order_relaxed);
    candidate.story_thread_address =
        source.story_thread_address.load(std::memory_order_relaxed);
    candidate.raw_text_hash =
        source.raw_text_hash.load(std::memory_order_relaxed);
    candidate.texture = source.texture.load(std::memory_order_relaxed);
    candidate.vertex_buffer =
        source.vertex_buffer.load(std::memory_order_relaxed);
    candidate.device = source.device.load(std::memory_order_relaxed);
    candidate.render_target =
        source.render_target.load(std::memory_order_relaxed);
    candidate.published_tick =
        source.published_tick.load(std::memory_order_relaxed);
    candidate.render_thread_id =
        source.render_thread_id.load(std::memory_order_relaxed);
    for (size_t index = 0u; index < 8u; ++index) {
      candidate.surface.words[index] =
          source.surface_words[index].load(std::memory_order_relaxed);
      candidate.xy[index] = HunexGgeFloatFromBits(
          source.xy_bits[index].load(std::memory_order_relaxed));
      candidate.uv[index] = HunexGgeFloatFromBits(
          source.uv_bits[index].load(std::memory_order_relaxed));
    }
    candidate.viewport_x =
        source.viewport_x.load(std::memory_order_relaxed);
    candidate.viewport_y =
        source.viewport_y.load(std::memory_order_relaxed);
    candidate.viewport_width =
        source.viewport_width.load(std::memory_order_relaxed);
    candidate.viewport_height =
        source.viewport_height.load(std::memory_order_relaxed);
    candidate.backbuffer_width =
        source.backbuffer_width.load(std::memory_order_relaxed);
    candidate.backbuffer_height =
        source.backbuffer_height.load(std::memory_order_relaxed);
    candidate.client_width =
        source.client_width.load(std::memory_order_relaxed);
    candidate.client_height =
        source.client_height.load(std::memory_order_relaxed);
    const uint32_t after = source.sequence.load(std::memory_order_acquire);
    if (before == after && (after & 1u) == 0u) {
      *output = candidate;
      return true;
    }
  }
  return false;
}

struct HunexGgeAffineProjection {
  double x_u = 0.0;
  double x_v = 0.0;
  double x_c = 0.0;
  double y_u = 0.0;
  double y_v = 0.0;
  double y_c = 0.0;
};

bool SolveHunexGgeAffineProjection(const HunexGgeProjectionEvidence& evidence,
                                   HunexGgeAffineProjection* output) {
  if (output == nullptr) return false;
  constexpr uint32_t kTriples[4][3] = {
      {0u, 1u, 2u}, {0u, 1u, 3u}, {0u, 2u, 3u}, {1u, 2u, 3u}};
  double best_determinant = 0.0;
  uint32_t best = 0u;
  for (uint32_t index = 0u; index < 4u; ++index) {
    const uint32_t i0 = kTriples[index][0];
    const uint32_t i1 = kTriples[index][1];
    const uint32_t i2 = kTriples[index][2];
    const double u10 = evidence.uv[i1 * 2u] - evidence.uv[i0 * 2u];
    const double v10 = evidence.uv[i1 * 2u + 1u] -
                       evidence.uv[i0 * 2u + 1u];
    const double u20 = evidence.uv[i2 * 2u] - evidence.uv[i0 * 2u];
    const double v20 = evidence.uv[i2 * 2u + 1u] -
                       evidence.uv[i0 * 2u + 1u];
    const double determinant = u10 * v20 - u20 * v10;
    if (std::abs(determinant) > std::abs(best_determinant)) {
      best_determinant = determinant;
      best = index;
    }
  }
  if (!std::isfinite(best_determinant) ||
      std::abs(best_determinant) <= 1.0e-8) {
    return false;
  }
  const uint32_t i0 = kTriples[best][0];
  const uint32_t i1 = kTriples[best][1];
  const uint32_t i2 = kTriples[best][2];
  const double u0 = evidence.uv[i0 * 2u];
  const double v0 = evidence.uv[i0 * 2u + 1u];
  const double u10 = evidence.uv[i1 * 2u] - u0;
  const double v10 = evidence.uv[i1 * 2u + 1u] - v0;
  const double u20 = evidence.uv[i2 * 2u] - u0;
  const double v20 = evidence.uv[i2 * 2u + 1u] - v0;
  const double x0 = evidence.xy[i0 * 2u];
  const double y0 = evidence.xy[i0 * 2u + 1u];
  const double x10 = evidence.xy[i1 * 2u] - x0;
  const double y10 = evidence.xy[i1 * 2u + 1u] - y0;
  const double x20 = evidence.xy[i2 * 2u] - x0;
  const double y20 = evidence.xy[i2 * 2u + 1u] - y0;
  HunexGgeAffineProjection candidate;
  candidate.x_u = (x10 * v20 - x20 * v10) / best_determinant;
  candidate.x_v = (u10 * x20 - u20 * x10) / best_determinant;
  candidate.y_u = (y10 * v20 - y20 * v10) / best_determinant;
  candidate.y_v = (u10 * y20 - u20 * y10) / best_determinant;
  candidate.x_c = x0 - candidate.x_u * u0 - candidate.x_v * v0;
  candidate.y_c = y0 - candidate.y_u * u0 - candidate.y_v * v0;
  if (!std::isfinite(candidate.x_u) || !std::isfinite(candidate.x_v) ||
      !std::isfinite(candidate.x_c) || !std::isfinite(candidate.y_u) ||
      !std::isfinite(candidate.y_v) || !std::isfinite(candidate.y_c)) {
    return false;
  }
  for (uint32_t index = 0u; index < 4u; ++index) {
    const double u = evidence.uv[index * 2u];
    const double v = evidence.uv[index * 2u + 1u];
    const double expected_x =
        candidate.x_u * u + candidate.x_v * v + candidate.x_c;
    const double expected_y =
        candidate.y_u * u + candidate.y_v * v + candidate.y_c;
    if (!std::isfinite(u) || !std::isfinite(v) ||
        std::abs(expected_x - evidence.xy[index * 2u]) >
            kHunexGgeAffineResidualPixels ||
        std::abs(expected_y - evidence.xy[index * 2u + 1u]) >
            kHunexGgeAffineResidualPixels) {
      return false;
    }
  }
  *output = candidate;
  return true;
}

bool TransformHunexGgeProjectionToClient(
    const HunexGgeProjectionEvidence& evidence,
    const HunexGgeAffineProjection& transform,
    fushi_voice_hook::hunex_lookup_core::RubyTextProjection* projection) {
  namespace core = fushi_voice_hook::hunex_lookup_core;
  if (projection == nullptr || projection->glyph_count == 0u ||
      !IsSaneHunexGgeCpuSurface(evidence.surface) ||
      evidence.viewport_width <= 0 || evidence.viewport_height <= 0 ||
      evidence.backbuffer_width <= 0 || evidence.backbuffer_height <= 0 ||
      evidence.client_width <= 0 || evidence.client_height <= 0) {
    return false;
  }
  const double source_width = evidence.surface.words[1];
  const double source_height = evidence.surface.words[2];
  double minimum_u = evidence.uv[0];
  double maximum_u = evidence.uv[0];
  double minimum_v = evidence.uv[1];
  double maximum_v = evidence.uv[1];
  for (uint32_t index = 1u; index < 4u; ++index) {
    minimum_u = (std::min)(minimum_u,
                           static_cast<double>(evidence.uv[index * 2u]));
    maximum_u = (std::max)(maximum_u,
                           static_cast<double>(evidence.uv[index * 2u]));
    minimum_v = (std::min)(minimum_v,
                           static_cast<double>(evidence.uv[index * 2u + 1u]));
    maximum_v = (std::max)(maximum_v,
                           static_cast<double>(evidence.uv[index * 2u + 1u]));
  }
  constexpr double kUvTolerance = 1.0e-4;
  const double viewport_left = evidence.viewport_x;
  const double viewport_top = evidence.viewport_y;
  const double viewport_right = viewport_left + evidence.viewport_width;
  const double viewport_bottom = viewport_top + evidence.viewport_height;
  const double client_scale_x =
      static_cast<double>(evidence.client_width) / evidence.backbuffer_width;
  const double client_scale_y =
      static_cast<double>(evidence.client_height) / evidence.backbuffer_height;
  for (uint32_t index = 0u; index < projection->glyph_count; ++index) {
    auto& rect = projection->glyphs[index].logical_bounds;
    if (!core::IsSaneRect(rect) || rect.x < 0 || rect.y < 0 ||
        static_cast<int64_t>(rect.x) + rect.width >
            static_cast<int64_t>(evidence.surface.words[1]) ||
        static_cast<int64_t>(rect.y) + rect.height >
            static_cast<int64_t>(evidence.surface.words[2])) {
      return false;
    }
    const double source_x[4] = {
        static_cast<double>(rect.x),
        static_cast<double>(rect.x + rect.width),
        static_cast<double>(rect.x),
        static_cast<double>(rect.x + rect.width)};
    const double source_y[4] = {
        static_cast<double>(rect.y), static_cast<double>(rect.y),
        static_cast<double>(rect.y + rect.height),
        static_cast<double>(rect.y + rect.height)};
    double client_left = 0.0;
    double client_top = 0.0;
    double client_right = 0.0;
    double client_bottom = 0.0;
    for (uint32_t corner = 0u; corner < 4u; ++corner) {
      const double u = source_x[corner] / source_width;
      const double v = source_y[corner] / source_height;
      if (u < minimum_u - kUvTolerance || u > maximum_u + kUvTolerance ||
          v < minimum_v - kUvTolerance || v > maximum_v + kUvTolerance) {
        return false;
      }
      // The builder emits pre-transformed XYZRHW at pixel_center - 0.5.
      const double target_x =
          transform.x_u * u + transform.x_v * v + transform.x_c + 0.5;
      const double target_y =
          transform.y_u * u + transform.y_v * v + transform.y_c + 0.5;
      if (!std::isfinite(target_x) || !std::isfinite(target_y) ||
          target_x < viewport_left - 1.0 || target_x > viewport_right + 1.0 ||
          target_y < viewport_top - 1.0 ||
          target_y > viewport_bottom + 1.0) {
        return false;
      }
      const double client_x = target_x * client_scale_x;
      const double client_y = target_y * client_scale_y;
      if (corner == 0u) {
        client_left = client_right = client_x;
        client_top = client_bottom = client_y;
      } else {
        client_left = (std::min)(client_left, client_x);
        client_right = (std::max)(client_right, client_x);
        client_top = (std::min)(client_top, client_y);
        client_bottom = (std::max)(client_bottom, client_y);
      }
    }
    int64_t left = static_cast<int64_t>(std::floor(client_left));
    int64_t top = static_cast<int64_t>(std::floor(client_top));
    int64_t right = static_cast<int64_t>(std::ceil(client_right));
    int64_t bottom = static_cast<int64_t>(std::ceil(client_bottom));
    left = (std::max)(int64_t{0}, left);
    top = (std::max)(int64_t{0}, top);
    right = (std::min)(static_cast<int64_t>(evidence.client_width), right);
    bottom = (std::min)(static_cast<int64_t>(evidence.client_height), bottom);
    if (right <= left || bottom <= top) return false;
    rect.x = static_cast<int32_t>(left);
    rect.y = static_cast<int32_t>(top);
    rect.width = static_cast<int32_t>(right - left);
    rect.height = static_cast<int32_t>(bottom - top);
  }
  return true;
}

bool BuildHunexGgeClientProjection(
    const fushi_voice_hook::hunex_capture_bridge::TraversalSnapshot& snapshot,
    int32_t client_width, int32_t client_height,
    fushi_voice_hook::hunex_lookup_core::RubyTextProjection* projection) {
  namespace bridge = fushi_voice_hook::hunex_capture_bridge;
  namespace core = fushi_voice_hook::hunex_lookup_core;
  if (projection == nullptr || snapshot.raw_text_units == 0u ||
      snapshot.raw_text_units > core::kTextCapacity ||
      snapshot.glyph_count == 0u ||
      snapshot.glyph_count > core::kGlyphCapacity) {
    return false;
  }
  std::array<char16_t, core::kTextCapacity> raw_text = {};
  std::array<core::RawGlyph, core::kGlyphCapacity> raw_glyphs = {};
  for (uint32_t index = 0u; index < snapshot.raw_text_units; ++index) {
    raw_text[index] = static_cast<char16_t>(snapshot.raw_text[index]);
  }
  for (uint32_t index = 0u; index < snapshot.glyph_count; ++index) {
    const bridge::GlyphSnapshot& source = snapshot.glyphs[index];
    core::RawGlyph& destination = raw_glyphs[index];
    destination.raw_index = source.raw_utf16_index;
    destination.width = source.consumed_utf16_width;
    destination.scalar = source.scalar;
    destination.logical_bounds = {source.logical_rect.x,
                                  source.logical_rect.y,
                                  source.logical_rect.width,
                                  source.logical_rect.height};
  }
  if (!core::ProjectRubyText(raw_text.data(), snapshot.raw_text_units,
                             raw_glyphs.data(), snapshot.glyph_count,
                             projection)) {
    return false;
  }
  HunexGgeProjectionEvidence evidence;
  if (!ReadHunexGgeProjectionEvidence(&evidence) ||
      evidence.generation == 0u || evidence.draw_sequence == 0u ||
      evidence.texture == 0u ||
      evidence.story_thread_address != snapshot.story_thread_address ||
      evidence.raw_text_hash != snapshot.raw_text_hash ||
      evidence.render_thread_id != snapshot.render_thread_id ||
      evidence.client_width != client_width ||
      evidence.client_height != client_height ||
      !IsFreshHunexGgeProjectionTick(evidence.published_tick,
                                     GetTickCount64())) {
    return false;
  }
  HunexGgeAffineProjection transform;
  return SolveHunexGgeAffineProjection(evidence, &transform) &&
         TransformHunexGgeProjectionToClient(evidence, transform, projection);
}

bool HasFreshHunexGgeProjectionEvidenceForRetain() {
  HunexGgeProjectionEvidence evidence;
  if (!ReadHunexGgeProjectionEvidence(&evidence) ||
      evidence.generation == 0u || evidence.draw_sequence == 0u ||
      evidence.texture == 0u ||
      evidence.story_thread_address !=
          g_hunex_gge_lookup_last_story_thread_address ||
      evidence.raw_text_hash != g_hunex_gge_lookup_last_raw_text_hash ||
      !IsFreshHunexGgeProjectionTick(evidence.published_tick,
                                     GetTickCount64())) {
    return false;
  }
  const HWND game = g_hunex_gge_lookup_runtime.shield_game_window.load(
      std::memory_order_acquire);
  RECT client = {};
  return game != nullptr && IsWindow(game) && GetClientRect(game, &client) &&
         client.right - client.left == evidence.client_width &&
         client.bottom - client.top == evidence.client_height;
}

bool IsSameHunexGgeMatchedRawLine(
    const fushi_voice_hook::hunex_capture_bridge::TraversalSnapshot& snapshot,
    uint64_t selected_thread_id) {
  return selected_thread_id != 0u &&
         selected_thread_id == g_hunex_gge_lookup_last_selected_thread_id &&
         snapshot.story_thread_address ==
             g_hunex_gge_lookup_last_story_thread_address &&
         snapshot.raw_text_hash == g_hunex_gge_lookup_last_raw_text_hash &&
         snapshot.raw_text_units == g_hunex_gge_lookup_last_raw_text_units &&
         std::equal(snapshot.raw_text.begin(),
                    snapshot.raw_text.begin() + snapshot.raw_text_units,
                    g_hunex_gge_lookup_last_raw_text.begin());
}

void RememberHunexGgeMatchedRawLine(
    const fushi_voice_hook::hunex_capture_bridge::TraversalSnapshot& snapshot,
    uint64_t selected_thread_id, uint64_t selected_text_seq) {
  g_hunex_gge_lookup_last_selected_thread_id = selected_thread_id;
  g_hunex_gge_lookup_last_selected_text_seq = selected_text_seq;
  g_hunex_gge_lookup_last_story_thread_address =
      snapshot.story_thread_address;
  g_hunex_gge_lookup_last_raw_text_hash = snapshot.raw_text_hash;
  g_hunex_gge_lookup_last_raw_text_units = snapshot.raw_text_units;
  g_hunex_gge_lookup_last_raw_text.fill(0u);
  std::copy(snapshot.raw_text.begin(),
            snapshot.raw_text.begin() + snapshot.raw_text_units,
            g_hunex_gge_lookup_last_raw_text.begin());
}

void ResetHunexGgeLookupWorkerState() {
  g_hunex_gge_lookup_last_snapshot_epoch = 0u;
  g_hunex_gge_lookup_last_selected_text_seq = 0u;
  g_hunex_gge_lookup_last_selected_thread_id = 0u;
  g_hunex_gge_lookup_last_raw_text_hash = 0u;
  g_hunex_gge_lookup_last_story_thread_address = 0u;
  g_hunex_gge_lookup_last_raw_text_units = 0u;
  g_hunex_gge_lookup_last_raw_text.fill(0u);
}

HunexGgeLookupPointerSample SampleHunexGgeLookupPointer() {
  HunexGgeLookupPointerSample sample;
  const HWND game = g_hunex_gge_lookup_runtime.shield_game_window.load(
      std::memory_order_acquire);
  if (game == nullptr || !IsWindow(game)) return sample;
  POINT screen = {};
  if (!GetCursorPos(&screen)) return sample;
  const HWND point_window = WindowFromPoint(screen);
  POINT client = screen;
  if (!ScreenToClient(game, &client)) return sample;
  sample.client_x = client.x;
  sample.client_y = client.y;
  sample.foreground_game_point =
      GetForegroundWindow() == game && point_window != nullptr &&
      (point_window == game || IsChild(game, point_window));
  return sample;
}

void CopyHunexGgeGlyphEvidence(
    const HunexGgeGlyphEvidence& source,
    fushi_voice_hook::HunexGgeTraceEvent* event) {
  if (event == nullptr || !source.valid) return;
  event->glyph_calls_since_render = source.calls_since_render;
  event->related_caller_rva = source.caller_rva;
  event->glyph_ordinal = source.glyph_ordinal;
  event->utf16_char_index = source.utf16_char_index;
  event->scalar_width = source.scalar_width;
  std::memcpy(event->descriptor_words, source.descriptor_words,
              sizeof(event->descriptor_words));
  std::memcpy(event->output_words, source.output_words,
              sizeof(event->output_words));
}

bool DescribeHunexGgeDrawText(const void* text_object, uint64_t* hash,
                              uint32_t* text_units,
                              uint32_t* visible_units) {
  if (text_object == nullptr || hash == nullptr || text_units == nullptr ||
      visible_units == nullptr) {
    return false;
  }
  bool valid = false;
  __try {
    const auto* object = static_cast<const uint8_t*>(text_object);
    const uint64_t units =
        *reinterpret_cast<const uint64_t*>(object + 0x38u);
    const uint64_t capacity =
        *reinterpret_cast<const uint64_t*>(object + 0x40u);
    const uint32_t visible =
        *reinterpret_cast<const uint32_t*>(object + 0x60u);
    if (units > 0u && units <= 4096u && capacity >= units &&
        capacity <= (1u << 20u) && visible <= 4096u) {
      const wchar_t* text = reinterpret_cast<const wchar_t*>(object + 0x28u);
      if (capacity >= 8u) {
        text = *reinterpret_cast<const wchar_t* const*>(object + 0x28u);
      }
      if (text != nullptr && text[units] == L'\0') {
        uint64_t value = 1469598103934665603ull;
        for (uint64_t index = 0u; index < units; ++index) {
          const uint16_t unit = static_cast<uint16_t>(text[index]);
          value ^= static_cast<uint8_t>(unit & 0xffu);
          value *= 1099511628211ull;
          value ^= static_cast<uint8_t>(unit >> 8u);
          value *= 1099511628211ull;
        }
        *hash = value;
        *text_units = static_cast<uint32_t>(units);
        *visible_units = visible;
        valid = true;
      }
    }
  } __except (EXCEPTION_EXECUTE_HANDLER) {
    valid = false;
  }
  return valid;
}

void Detour_HunexGgeDrawText(
    void* arg1, void* arg2, void* arg3, void* text_object, uintptr_t arg5,
    void* arg6, uint32_t arg7, void* arg8, int32_t x, int32_t y,
    int32_t width, double arg12, uint32_t arg13) {
  const uintptr_t return_address =
      reinterpret_cast<uintptr_t>(_ReturnAddress());
  HunexGgeDrawContext previous = g_hunex_gge_draw_context;
  HunexGgeDrawContext current;
  current.active = DescribeHunexGgeDrawText(
      text_object, &current.text_hash, &current.text_units,
      &current.visible_units);
  current.draw_sequence = static_cast<uint64_t>(InterlockedIncrement64(
      reinterpret_cast<volatile LONG64*>(&FushiHunexGgeTraceV3.draw_calls)));
  current.arg7 = arg7;
  current.x = x;
  current.y = y;
  current.width = width;
  __try {
    if (arg8 != nullptr) {
      current.alignment_mode = *static_cast<const int32_t*>(arg8);
      current.alignment_mode_read = true;
    }
  } __except (EXCEPTION_EXECUTE_HANDLER) {
    current.alignment_mode = 0;
    current.alignment_mode_read = false;
  }
  g_hunex_gge_draw_context = current;
  if (current.active) {
    fushi_voice_hook::HunexGgeTraceEvent event;
    event.kind = static_cast<uint32_t>(
        fushi_voice_hook::HunexGgeTraceKind::kDraw);
    event.draw_sequence = current.draw_sequence;
    event.text_hash = current.text_hash;
    std::memcpy(&event.draw_arg12_bits, &arg12,
                sizeof(event.draw_arg12_bits));
    event.caller_rva = HunexGgeRva(return_address);
    event.text_units = current.text_units;
    event.visible_units = current.visible_units;
    event.arg7 = arg7;
    event.draw_arg13 = arg13;
    event.draw_x = x;
    event.draw_y = y;
    event.draw_width = width;
    event.alignment_mode = current.alignment_mode;
    if (current.alignment_mode_read) {
      event.evidence_flags |=
          fushi_voice_hook::kHunexGgeTraceEvidenceAlignmentModeRead;
    }
    CaptureHunexGgeViewportTransform(&event);
    PublishHunexGgeTrace(event);
  }
  g_orig_hunex_gge_draw_text(arg1, arg2, arg3, text_object, arg5, arg6, arg7,
                             arg8, x, y, width, arg12, arg13);
  g_hunex_gge_draw_context = previous;
}

void Detour_HunexGgeGlyph(void* descriptor, void* output, uint32_t scalar,
                          void* raster, uint32_t arg5, uint32_t arg6) {
  const uintptr_t return_address =
      reinterpret_cast<uintptr_t>(_ReturnAddress());
  g_orig_hunex_gge_glyph(descriptor, output, scalar, raster, arg5, arg6);
  InterlockedIncrement64(reinterpret_cast<volatile LONG64*>(
      &FushiHunexGgeTraceV3.glyph_calls));
  const uint32_t scalar_width = scalar > 0xffffu ? 2u : 1u;

  HunexGgeGlyphEvidence observed;
  observed.valid = true;
  observed.calls_since_render =
      g_hunex_gge_recent_glyph.calls_since_render == UINT32_MAX
          ? UINT32_MAX
          : g_hunex_gge_recent_glyph.calls_since_render + 1u;
  observed.caller_rva = HunexGgeRva(return_address);
  observed.scalar_width = scalar_width;
  bool numeric_read = true;
  __try {
    if (descriptor != nullptr) {
      std::memcpy(observed.descriptor_words, descriptor,
                  sizeof(observed.descriptor_words));
    }
    if (output != nullptr) {
      std::memcpy(observed.output_words, output,
                  sizeof(observed.output_words));
    }
  } __except (EXCEPTION_EXECUTE_HANDLER) {
    numeric_read = false;
  }
  if (!numeric_read) observed.valid = false;
  g_hunex_gge_recent_glyph = observed;

  auto& context = g_hunex_gge_draw_context;
  fushi_voice_hook::HunexGgeTraceKind kind;
  const bool first =
      return_address == g_hunex_gge_anchors.direct_first_glyph_return;
  const bool second =
      return_address == g_hunex_gge_anchors.direct_second_glyph_return;
  if (context.active && first) {
    kind = fushi_voice_hook::HunexGgeTraceKind::kGlyphDirectFirst;
  } else if (context.active && second) {
    kind = fushi_voice_hook::HunexGgeTraceKind::kGlyphDirectSecond;
  } else {
    fushi_voice_hook::HunexGgeTraceEvent event;
    event.kind = static_cast<uint32_t>(
        fushi_voice_hook::HunexGgeTraceKind::kGlyphUncorrelated);
    event.caller_rva = HunexGgeRva(return_address);
    event.scalar_width = scalar_width;
    event.glyph_calls_since_render = observed.calls_since_render;
    if (observed.valid) {
      std::memcpy(event.descriptor_words, observed.descriptor_words,
                  sizeof(event.descriptor_words));
      std::memcpy(event.output_words, observed.output_words,
                  sizeof(event.output_words));
    } else {
      event.result = -1;
    }
    PublishHunexGgeTrace(event);
    return;
  }
  const auto position =
      fushi_voice_hook::hunex_lookup::ObserveGlyphTraceCall(
          &context.glyph_trace_cursor,
          first, scalar_width);
  if (!position.valid) return;
  observed.glyph_ordinal = position.glyph_ordinal;
  observed.utf16_char_index = position.utf16_char_index;
  if (first && observed.valid) {
    observed.calls_since_render = 1u;
    context.pending_glyph = observed;
  } else if (context.pending_glyph.valid &&
             context.pending_glyph.calls_since_render != UINT32_MAX) {
    ++context.pending_glyph.calls_since_render;
  }
  fushi_voice_hook::HunexGgeTraceEvent event;
  event.kind = static_cast<uint32_t>(kind);
  event.draw_sequence = context.draw_sequence;
  event.text_hash = context.text_hash;
  event.caller_rva = HunexGgeRva(return_address);
  event.text_units = context.text_units;
  event.visible_units = context.visible_units;
  event.glyph_ordinal = position.glyph_ordinal;
  event.utf16_char_index = position.utf16_char_index;
  event.scalar_width = scalar_width;
  event.arg7 = context.arg7;
  event.draw_x = context.x;
  event.draw_y = context.y;
  event.draw_width = context.width;
  event.alignment_mode = context.alignment_mode;
  if (context.alignment_mode_read) {
    event.evidence_flags |=
        fushi_voice_hook::kHunexGgeTraceEvidenceAlignmentModeRead;
  }
  if (observed.valid) {
    std::memcpy(event.descriptor_words, observed.descriptor_words,
                sizeof(event.descriptor_words));
    std::memcpy(event.output_words, observed.output_words,
                sizeof(event.output_words));
  } else {
    event.result = -1;
  }
  CaptureHunexGgeViewportTransform(&event);
  PublishHunexGgeTrace(event);
}

void* Detour_HunexGgeRenderItem(void* arg1, void* arg2, void* arg3,
                                void* render_item) {
  const uintptr_t return_address =
      reinterpret_cast<uintptr_t>(_ReturnAddress());
  InterlockedIncrement64(reinterpret_cast<volatile LONG64*>(
      &FushiHunexGgeTraceV3.render_item_calls));

  auto& context = g_hunex_gge_draw_context;
  const bool exact_draw =
      context.active && context.pending_glyph.valid &&
      return_address == g_hunex_gge_anchors.render_item_return;
  const bool body_submit =
      return_address == g_hunex_gge_anchors.body_submit_return;
  // Keep the trace-only path cheap.  Reading the bounded caller frame remains
  // useful diagnostics while lookup is disabled, but freezing and parsing a
  // complete line on every rendered glyph is capture work and must respect the
  // worker-owned admission gate.  Mutation is checked again immediately before
  // bridge publication below in case the lifecycle changes during this call.
  const bool capture_admitted_at_entry =
      body_submit && IsHunexGgeCaptureMutationAdmitted();

  fushi_voice_hook::HunexGgeTraceEvent event;
  fushi_voice_hook::hunex_lookup::BodySubmitCallerFrameDiagnostic
      body_frame;
  std::array<uint16_t,
             fushi_voice_hook::hunex_capture_bridge::kTextCapacity>
      body_raw_text;
  uint32_t body_raw_text_units = 0u;
  uint64_t body_raw_text_hash = 0u;
  uint64_t body_story_thread_address = 0u;
  bool body_frame_ready = false;
  event.kind = static_cast<uint32_t>(
      exact_draw
          ? fushi_voice_hook::HunexGgeTraceKind::kRenderItemCorrelated
          : body_submit
                ? fushi_voice_hook::HunexGgeTraceKind::
                      kRenderItemBodyUncorrelated
                : fushi_voice_hook::HunexGgeTraceKind::
                      kRenderItemUncorrelated);
  event.caller_rva = HunexGgeRva(return_address);
  if (exact_draw) {
    event.draw_sequence = context.draw_sequence;
    event.text_hash = context.text_hash;
    event.text_units = context.text_units;
    event.visible_units = context.visible_units;
    event.arg7 = context.arg7;
    event.draw_x = context.x;
    event.draw_y = context.y;
    event.draw_width = context.width;
    event.alignment_mode = context.alignment_mode;
    if (context.alignment_mode_read) {
      event.evidence_flags |=
          fushi_voice_hook::kHunexGgeTraceEvidenceAlignmentModeRead;
    }
    event.evidence_flags |=
        fushi_voice_hook::kHunexGgeTraceEvidenceGlyphCallGraphCorrelated;
    CopyHunexGgeGlyphEvidence(context.pending_glyph, &event);
  } else if (g_hunex_gge_recent_glyph.valid) {
    event.evidence_flags |=
        fushi_voice_hook::kHunexGgeTraceEvidenceGlyphProximityObserved;
    CopyHunexGgeGlyphEvidence(g_hunex_gge_recent_glyph, &event);
  }

  if (body_submit) {
    event.evidence_flags |=
        fushi_voice_hook::kHunexGgeTraceEvidenceBodySubmitGraph;
    __try {
      // The scanner admitted the wrapper shape and its single call to this
      // mover.  First advance from the mover return slot to the body-wrapper
      // return slot; that wrapper slot, not the mover slot, is measured R.
      const auto* mover_return_slot =
          static_cast<const uint8_t*>(_AddressOfReturnAddress());
      const auto* wrapper_return_slot =
          mover_return_slot +
          fushi_voice_hook::hunex_lookup::
              kBodySubmitWrapperReturnSlotOffset;
      const uintptr_t outer_return =
          *reinterpret_cast<const uintptr_t*>(wrapper_return_slot);
      event.outer_caller_rva = HunexGgeRva(outer_return);
      event.outer_function_rva = HunexGgeContainingFunctionRva(outer_return);
      if (event.outer_caller_rva != 0u &&
          event.outer_function_rva != 0u) {
        event.evidence_flags |=
            fushi_voice_hook::kHunexGgeTraceEvidenceOuterCallerRead;
        fushi_voice_hook::hunex_lookup::
            BodySubmitCallerFrameDiagnostic frame;
        if (fushi_voice_hook::hunex_lookup::
                ReadBodySubmitCallerFrameDiagnostic(
                    wrapper_return_slot,
                    fushi_voice_hook::hunex_lookup::
                        kBodySubmitCallerFrameReadBytes,
                    &frame)) {
          event.story_scalar_present = frame.raw_scalar == 0u ? 0u : 1u;
          event.story_raw_utf16_index = frame.raw_utf16_index;
          event.story_consumed = frame.consumed;
          event.story_line_base = static_cast<uint64_t>(frame.line_base);
          event.evidence_flags |= fushi_voice_hook::
              kHunexGgeTraceEvidenceStoryFrameSlotsRead;
          if (capture_admitted_at_entry && CaptureHunexGgeStoryLine(
                  frame.line_base, body_raw_text.data(),
                  body_raw_text.size(), &body_raw_text_units,
                  &body_raw_text_hash, &event)) {
            body_frame = frame;
            body_story_thread_address =
                g_hunex_gge_anchors.module + event.outer_function_rva;
            // The admitted story-body path is not nested under the generic
            // DrawText entry, so context.draw_sequence is intentionally zero
            // here. Its raw UTF-16 indices are strictly increasing during one
            // traversal and wrap/repeat at the next traversal. Use that
            // measured boundary to freeze one complete body traversal. The
            // global Luna text-event upper fence is intentionally sampled only
            // after the final grammar glyph is accepted: first-glyph sampling
            // has no cross-process happens-before relationship to the injector
            // write that publishes the matching Luna line.
            auto& traversal_fence = g_hunex_gge_body_traversal_fence;
            const bool new_traversal =
                !traversal_fence.active ||
                traversal_fence.story_thread_address !=
                    body_story_thread_address ||
                traversal_fence.raw_text_hash != body_raw_text_hash ||
                traversal_fence.raw_text_units != body_raw_text_units ||
                body_frame.raw_utf16_index <=
                    traversal_fence.last_raw_utf16_index;
            if (new_traversal) {
              traversal_fence = {};
              traversal_fence.active = true;
              traversal_fence.story_thread_address =
                  body_story_thread_address;
              traversal_fence.raw_text_hash = body_raw_text_hash;
              traversal_fence.raw_text_units = body_raw_text_units;
              std::array<char16_t,
                         fushi_voice_hook::hunex_lookup_core::kTextCapacity>
                  parsed_raw_text = {};
              for (uint32_t index = 0u; index < body_raw_text_units; ++index) {
                parsed_raw_text[index] =
                    static_cast<char16_t>(body_raw_text[index]);
              }
              if (fushi_voice_hook::hunex_lookup_core::AnalyzeRawTextLayout(
                      parsed_raw_text.data(), body_raw_text_units,
                      &traversal_fence.raw_text_layout)) {
                traversal_fence.raw_text_layout_valid = true;
              }
            }
            traversal_fence.last_raw_utf16_index =
                body_frame.raw_utf16_index;
            body_frame_ready =
                body_story_thread_address != 0u &&
                traversal_fence.raw_text_layout_valid &&
                traversal_fence.raw_text_layout.visible_glyph_count != 0u;
          }
        }
      } else {
        event.outer_caller_rva = 0u;
        event.outer_function_rva = 0u;
      }
    } __except (EXCEPTION_EXECUTE_HANDLER) {
      event.outer_caller_rva = 0u;
      event.outer_function_rva = 0u;
    }
  }

  bool render_item_read = false;
  __try {
    if (render_item != nullptr) {
      const auto* bytes = static_cast<const uint8_t*>(render_item);
      event.render_x = *reinterpret_cast<const int32_t*>(bytes + 0x10u);
      event.render_y = *reinterpret_cast<const int32_t*>(bytes + 0x14u);
      std::memcpy(event.render_item_words, render_item,
                  sizeof(event.render_item_words));
      event.evidence_flags |=
          fushi_voice_hook::kHunexGgeTraceEvidenceRenderItemPositionRead;
      render_item_read = true;
    }
  } __except (EXCEPTION_EXECUTE_HANDLER) {
    render_item_read = false;
  }
  CaptureHunexGgeViewportTransform(&event);

  if (body_submit && body_frame_ready && render_item_read &&
      IsHunexGgeCaptureMutationAdmitted()) {
    fushi_voice_hook::hunex_lookup::BodyGlyphMetricDiagnostic glyph_metrics;
    if (fushi_voice_hook::hunex_lookup::ReadBodyGlyphMetricDiagnostic(
            event.descriptor_words, _countof(event.descriptor_words),
            event.output_words, _countof(event.output_words),
            body_frame.raw_scalar, body_frame.consumed, event.scalar_width,
            &glyph_metrics)) {
      event.evidence_flags |= fushi_voice_hook::
          kHunexGgeTraceEvidenceBodyGlyphMetricsMatched;
      fushi_voice_hook::hunex_capture_bridge::LogicalRect rect;
      rect.x = event.render_x;
      rect.y = event.render_y;
      rect.width = static_cast<int32_t>(glyph_metrics.bitmap_width);
      rect.height = static_cast<int32_t>(glyph_metrics.bitmap_height);
      auto& traversal_fence = g_hunex_gge_body_traversal_fence;
      uint32_t visible_glyph_ordinal =
          fushi_voice_hook::hunex_capture_bridge::kInvalidVisibleGlyphOrdinal;
      const uint32_t expected_visible_glyph_count =
          traversal_fence.raw_text_layout.visible_glyph_count;
      event.text_units = body_raw_text_units;
      event.visible_units = expected_visible_glyph_count;
      event.utf16_char_index = body_frame.raw_utf16_index;
      event.scalar_width = body_frame.consumed;
      if (traversal_fence.raw_text_layout_valid) {
        event.evidence_flags |= fushi_voice_hook::
            kHunexGgeTraceEvidenceRawTextLayoutValid;
        const uint32_t ordinal =
            traversal_fence.next_visible_glyph_ordinal;
        if (ordinal < expected_visible_glyph_count) {
          const auto& expected =
              traversal_fence.raw_text_layout.visible_glyphs[ordinal];
          if (body_frame.raw_utf16_index == expected.raw_index &&
              body_frame.consumed == expected.width &&
              body_frame.raw_scalar == expected.scalar) {
            visible_glyph_ordinal = ordinal;
            event.evidence_flags |= fushi_voice_hook::
                kHunexGgeTraceEvidenceRawTextTokenMatched;
          } else {
            traversal_fence.raw_text_layout_valid = false;
          }
        } else {
          traversal_fence.raw_text_layout_valid = false;
        }
      }
      event.glyph_ordinal = visible_glyph_ordinal;
      auto capture_outcome =
          g_hunex_gge_capture_bridge.SubmitGlyphWithLine(
          GetCurrentThreadId(), body_frame.raw_utf16_index,
          body_frame.raw_scalar, body_frame.consumed, rect,
          body_raw_text.data(), body_raw_text_units, body_raw_text_hash,
          body_story_thread_address, 0u,
          visible_glyph_ordinal, expected_visible_glyph_count);
      if (capture_outcome.glyph_accepted) {
        event.evidence_flags |= fushi_voice_hook::
            kHunexGgeTraceEvidenceCaptureGlyphAccepted;
        ++traversal_fence.next_visible_glyph_ordinal;
        const bool final_accepted_glyph =
            visible_glyph_ordinal != fushi_voice_hook::hunex_capture_bridge::
                                         kInvalidVisibleGlyphOrdinal &&
            expected_visible_glyph_count != 0u &&
            visible_glyph_ordinal + 1u == expected_visible_glyph_count;
        if (final_accepted_glyph &&
            IsHunexGgeCaptureMutationAdmitted()) {
          const uint64_t stable_text_window_through_seq =
              ReadStableHunexGgeTextWindowThroughSeq();
          const auto seal_outcome =
              g_hunex_gge_capture_bridge.FinalizeExactLineTraversal(
                  GetCurrentThreadId(), stable_text_window_through_seq);
          capture_outcome.snapshot_published =
              seal_outcome.snapshot_published;
          capture_outcome.quarantined =
              capture_outcome.quarantined || seal_outcome.quarantined;
        }
      }
      if (capture_outcome.snapshot_published) {
        event.evidence_flags |= fushi_voice_hook::
            kHunexGgeTraceEvidenceCaptureSnapshotPublished;
        HunexGgePendingStoryCompose pending;
        pending.active = true;
        pending.story_thread_address = body_story_thread_address;
        pending.raw_text_hash = body_raw_text_hash;
        pending.render_thread_id = GetCurrentThreadId();
        pending.final_glyph_rect = rect;
        std::memcpy(pending.final_glyph_surface.words,
                    event.descriptor_words,
                    sizeof(pending.final_glyph_surface.words));
        pending.sealed_tick = GetTickCount64();
        if (pending.story_thread_address != 0u &&
            pending.raw_text_hash != 0u &&
            IsSaneHunexGgeCpuSurface(pending.final_glyph_surface)) {
          g_hunex_gge_pending_story_compose = pending;
        } else {
          g_hunex_gge_pending_story_compose = {};
        }
      }
      if (capture_outcome.quarantined) {
        event.evidence_flags |= fushi_voice_hook::
            kHunexGgeTraceEvidenceCaptureQuarantined;
      }
    }
  }

  // Clear thread-local proximity before original: the mover may re-enter
  // renderer code.  Exact correlation is consumed only by its admitted
  // callsite; unknown helper calls cannot steal the old DrawText association.
  g_hunex_gge_recent_glyph = {};
  if (exact_draw) context.pending_glyph = {};

  // Out-of-image callers and unreadable items are not actionable diagnostic
  // geometry.  Drop them rather than manufacturing a zero-origin event.
  if (event.caller_rva != 0u && render_item_read) {
    if (body_submit) {
      event.result = InterlockedCompareExchange(
          &g_hunex_gge_lookup_worker_trace_state, 0, 0);
      event.draw_arg13 = static_cast<uint32_t>(InterlockedCompareExchange(
          &g_hunex_gge_lookup_worker_selected_failure, 0, 0));
      StampHunexGgeBodySubmitLookupDiagnostics(&event);
    }
    PublishHunexGgeTrace(event);
  }
  return g_orig_hunex_gge_render_item(arg1, arg2, arg3, render_item);
}

uint32_t Detour_HunexGgeSurfaceComposeWrapper(
    void* line_this, void* destination, int32_t y_base, uint32_t blend,
    const int32_t* x_offsets, uint32_t layout_selector,
    uint32_t node_filter) {
  const HunexGgeSurfaceComposeContext previous =
      g_hunex_gge_surface_compose_context;
  HunexGgeSurfaceComposeContext current;
  if (!previous.active) {
    current = BeginHunexGgeSurfaceComposeContext(
        line_this, blend, destination, nullptr, true);
    current.wrapper_destination = reinterpret_cast<uintptr_t>(destination);
    current.wrapper_x_offsets = reinterpret_cast<uintptr_t>(x_offsets);
    current.wrapper_layout_selector = layout_selector;
    current.wrapper_node_filter = node_filter;
  } else {
    // An unexpected nested wrapper must not borrow the outer line. Keep an
    // active suppression scope so a nested full composer cannot start a new
    // correlation of its own before the outer wrapper resumes.
    current.active = true;
    current.suppress_compositor = true;
  }
  g_hunex_gge_surface_compose_context = current;
  const uint32_t result = g_orig_hunex_gge_surface_compose_wrapper(
      line_this, destination, y_base, blend, x_offsets, layout_selector,
      node_filter);
  const HunexGgeSurfaceComposeContext completed =
      g_hunex_gge_surface_compose_context;
  if (!previous.active) CompleteHunexGgeSurfaceComposeContext(completed);
  g_hunex_gge_surface_compose_context = previous;
  return result;
}

uint32_t Detour_HunexGgeSurfaceCompose(
    void* line_this, void* destination_b, void* destination_a,
    int32_t y_base, uint32_t blend, const int32_t* x_offsets,
    uint32_t layout_selector, uint32_t node_filter) {
  const HunexGgeSurfaceComposeContext previous =
      g_hunex_gge_surface_compose_context;
  // The admitted wrapper's non-zero path is the one legitimate nested entry:
  // its compositor calls must accumulate in the wrapper-owned scope, and the
  // wrapper alone finalizes/restores that scope.
  if (previous.active && previous.wrapper_scope &&
      !previous.suppress_compositor && previous.blend != 0u &&
      previous.line_this == reinterpret_cast<uintptr_t>(line_this) &&
      destination_a == destination_b &&
      previous.wrapper_destination ==
          reinterpret_cast<uintptr_t>(destination_a) &&
      static_cast<uint32_t>(y_base) == previous.blend &&
      blend == previous.blend &&
      previous.wrapper_x_offsets == reinterpret_cast<uintptr_t>(x_offsets) &&
      previous.wrapper_layout_selector == layout_selector &&
      previous.wrapper_node_filter == node_filter) {
    return g_orig_hunex_gge_surface_compose(
        line_this, destination_b, destination_a, y_base, blend, x_offsets,
        layout_selector, node_filter);
  }

  HunexGgeSurfaceComposeContext current;
  if (!previous.active) {
    current = BeginHunexGgeSurfaceComposeContext(
        line_this, blend, destination_a, destination_b, false);
  } else {
    // All other nesting is ambiguous and stays fail-closed, including an
    // impossible zero-mode wrapper -> full-composer edge.
    current.active = true;
    current.suppress_compositor = true;
  }
  g_hunex_gge_surface_compose_context = current;
  const uint32_t result = g_orig_hunex_gge_surface_compose(
      line_this, destination_b, destination_a, y_base, blend, x_offsets,
      layout_selector, node_filter);
  const HunexGgeSurfaceComposeContext completed =
      g_hunex_gge_surface_compose_context;
  if (!previous.active) CompleteHunexGgeSurfaceComposeContext(completed);
  g_hunex_gge_surface_compose_context = previous;
  return result;
}

uint32_t Detour_HunexGgeSurfaceCompositor(
    void* destination, int32_t destination_x, int32_t destination_y,
    const void* source, uint32_t mode, uint32_t alpha) {
  const uintptr_t return_address =
      reinterpret_cast<uintptr_t>(_ReturnAddress());
  auto& context = g_hunex_gge_surface_compose_context;
  uint32_t ordinal = 0u;
  bool zero_mode = false;
  if (context.active && !context.suppress_compositor &&
      context.wrapper_scope && context.blend == 0u &&
      return_address ==
          g_hunex_gge_anchors.surface_compose_zero_first_return) {
    ordinal = 1u;
    zero_mode = true;
  } else if (context.active && !context.suppress_compositor &&
             context.wrapper_scope && context.blend == 0u &&
             return_address ==
                 g_hunex_gge_anchors.surface_compose_zero_second_return) {
    ordinal = 2u;
    zero_mode = true;
  } else if (context.active && !context.suppress_compositor &&
             (!context.wrapper_scope || context.blend != 0u) &&
             return_address ==
                 g_hunex_gge_anchors.surface_compose_first_return) {
    ordinal = 1u;
  } else if (context.active && !context.suppress_compositor &&
             (!context.wrapper_scope || context.blend != 0u) &&
             return_address ==
                 g_hunex_gge_anchors.surface_compose_second_return) {
    ordinal = 2u;
  } else if (context.active && !context.suppress_compositor &&
             (!context.wrapper_scope || context.blend != 0u) &&
             return_address ==
                 g_hunex_gge_anchors.surface_compose_final_first_return) {
    ordinal = 3u;
  } else if (context.active && !context.suppress_compositor &&
             (!context.wrapper_scope || context.blend != 0u) &&
             return_address ==
                 g_hunex_gge_anchors.surface_compose_final_second_return) {
    ordinal = 4u;
  }
  if (ordinal != 0u) {
    ++context.compositor_call_count;
  }

  fushi_voice_hook::HunexGgeTraceEvent event;
  bool descriptors_read = false;
  if (ordinal != 0u && destination != nullptr && source != nullptr) {
    event.kind = static_cast<uint32_t>(
        fushi_voice_hook::HunexGgeTraceKind::kSurfaceCompose);
    event.draw_sequence = context.generation;
    event.text_hash = reinterpret_cast<uintptr_t>(destination);
    event.draw_arg12_bits = reinterpret_cast<uintptr_t>(source);
    event.caller_rva = HunexGgeRva(return_address);
    event.glyph_ordinal = ordinal;
    event.render_x = destination_x;
    event.render_y = destination_y;
    event.story_line_base = context.line_this;
    event.related_caller_rva = HunexGgeRva(
        zero_mode ? g_hunex_gge_anchors.surface_compose_wrapper
                  : g_hunex_gge_anchors.surface_compose);
    event.outer_function_rva =
        HunexGgeRva(g_hunex_gge_anchors.surface_compositor);
    event.arg7 = mode;
    event.draw_arg13 = alpha;
    event.evidence_flags =
        fushi_voice_hook::kHunexGgeTraceEvidenceSurfaceComposeGraph;
    HunexGgeCpuSurfaceIdentity destination_identity;
    HunexGgeCpuSurfaceIdentity source_identity;
    descriptors_read = ReadHunexGgeCpuSurfaceIdentity(
                           destination, &destination_identity) &&
                       ReadHunexGgeCpuSurfaceIdentity(source,
                                                      &source_identity);
    if (descriptors_read) {
      ++context.compositor_descriptor_count;
      std::memcpy(event.descriptor_words, destination_identity.words,
                  sizeof(event.descriptor_words));
      std::memcpy(event.output_words, source_identity.words,
                  sizeof(destination_identity.words));
      event.evidence_flags |= fushi_voice_hook::
          kHunexGgeTraceEvidenceSurfaceDescriptorsRead;
      if (context.story.active && ordinal <= 2u &&
          SameHunexGgeCpuSurface(source_identity,
                                 context.story.final_glyph_surface) &&
          destination_x == context.story.final_glyph_rect.x &&
          destination_y == context.story.final_glyph_rect.y) {
        ++context.story_source_match_count;
        ++context.candidate_count;
        context.candidate_destination = destination_identity;
      } else if (context.story.active && ordinal >= 3u &&
                 destination_x == 0 && destination_y == 0 &&
                 context.candidate_count == 1u &&
                 SameHunexGgeCpuSurface(
                     source_identity, context.candidate_destination) &&
                 CountHunexGgeOriginalSurfaceMatches(
                     context, destination_identity) == 1u) {
        ++context.final_link_count;
        context.final_destination = destination_identity;
      }
    }
  }

  const uint32_t result = g_orig_hunex_gge_surface_compositor(
      destination, destination_x, destination_y, source, mode, alpha);
  if (ordinal != 0u) {
    event.result = static_cast<int32_t>(result);
    PublishHunexGgeTrace(event);
  }
  return result;
}

uint32_t Detour_HunexGgeTextureUpload(void* wrapper, uint32_t flags) {
  HunexGgeCpuSurfaceIdentity upload_surface;
  const void* descriptor = nullptr;
  bool descriptor_read = false;
  __try {
    if (wrapper != nullptr) {
      const auto* bytes = static_cast<const uint8_t*>(wrapper);
      descriptor = *reinterpret_cast<const void* const*>(bytes + 0xd8u);
      if (descriptor == nullptr) descriptor = bytes + 0x84u;
    }
  } __except (EXCEPTION_EXECUTE_HANDLER) {
    descriptor = nullptr;
  }
  descriptor_read =
      ReadHunexGgeCpuSurfaceIdentity(descriptor, &upload_surface);
  const uint32_t result = g_orig_hunex_gge_texture_upload(wrapper, flags);

  auto& pending = g_hunex_gge_pending_surface_chain;
  const ULONGLONG now = GetTickCount64();
  const bool exact_surface =
      descriptor_read && pending.active &&
      pending.render_thread_id == GetCurrentThreadId() &&
      IsFreshHunexGgeProjectionTick(pending.updated_tick, now) &&
      SameHunexGgeCpuSurface(upload_surface, pending.surface);
  if (!exact_surface) {
    return result;
  }
  const auto publish_texture_failure =
      [&](fushi_voice_hook::HunexGgeProjectionTraceFailure failure,
          uintptr_t texture) {
        fushi_voice_hook::HunexGgeTraceEvent event;
        event.draw_sequence = pending.generation;
        event.text_hash = reinterpret_cast<uintptr_t>(wrapper);
        event.draw_arg12_bits = texture;
        event.story_line_base = pending.story_thread_address;
        event.story_line_hash = pending.raw_text_hash;
        event.render_x = static_cast<int32_t>(pending.surface.words[1]);
        event.render_y = static_cast<int32_t>(pending.surface.words[2]);
        event.glyph_ordinal = flags;
        event.draw_arg13 = result;
        event.evidence_flags =
            fushi_voice_hook::kHunexGgeTraceEvidenceSurfaceComposeGraph |
            fushi_voice_hook::kHunexGgeTraceEvidenceSurfaceDescriptorsRead;
        std::memcpy(event.descriptor_words, pending.surface.words,
                    sizeof(event.descriptor_words));
        PublishHunexGgeProjectionDiagnostic(
            event,
            fushi_voice_hook::HunexGgeProjectionTraceStage::kTexture,
            failure);
      };
  if (FAILED(static_cast<HRESULT>(result))) {
    publish_texture_failure(
        fushi_voice_hook::HunexGgeProjectionTraceFailure::
            kTextureUploadFailed,
        0u);
    return result;
  }
  uintptr_t texture = 0u;
  __try {
    texture = reinterpret_cast<uintptr_t>(
        *reinterpret_cast<void**>(static_cast<uint8_t*>(wrapper) + 0xc8u));
  } __except (EXCEPTION_EXECUTE_HANDLER) {
    texture = 0u;
  }
  if (texture == 0u) {
    publish_texture_failure(
        fushi_voice_hook::HunexGgeProjectionTraceFailure::
            kTextureObjectMissing,
        0u);
    return result;
  }
  pending.texture = texture;
  pending.upload_sequence =
      g_hunex_gge_texture_upload_sequence.fetch_add(
          1u, std::memory_order_relaxed) +
      1u;
  pending.updated_tick = now;

  fushi_voice_hook::HunexGgeTraceEvent event;
  event.kind = static_cast<uint32_t>(
      fushi_voice_hook::HunexGgeTraceKind::kTextureUpload);
  event.draw_sequence = pending.generation;
  event.text_hash = reinterpret_cast<uintptr_t>(wrapper);
  event.draw_arg12_bits = texture;
  event.story_line_base = pending.story_thread_address;
  event.story_line_hash = pending.raw_text_hash;
  event.render_x = static_cast<int32_t>(pending.surface.words[1]);
  event.render_y = static_cast<int32_t>(pending.surface.words[2]);
  event.arg7 = flags;
  event.result = static_cast<int32_t>(result);
  event.evidence_flags =
      fushi_voice_hook::kHunexGgeTraceEvidenceSurfaceComposeGraph |
      fushi_voice_hook::kHunexGgeTraceEvidenceSurfaceDescriptorsRead |
      fushi_voice_hook::kHunexGgeTraceEvidenceTextureIdentityLinked;
  std::memcpy(event.descriptor_words, pending.surface.words,
              sizeof(event.descriptor_words));
  PublishHunexGgeTrace(event);
  return result;
}

uint32_t Detour_HunexGgeQuadVertex(void* manager, const float* xy,
                                  const float* uv_pixels,
                                  const int32_t* texture_dimensions) {
  float input_xy[8] = {};
  float input_uv[8] = {};
  int32_t dimensions[2] = {};
  float offset_x = 0.0f;
  float offset_y = 0.0f;
  int32_t mode = 0;
  bool inputs_read = false;
  __try {
    if (manager != nullptr && xy != nullptr && uv_pixels != nullptr &&
        texture_dimensions != nullptr) {
      std::memcpy(input_xy, xy, sizeof(input_xy));
      std::memcpy(input_uv, uv_pixels, sizeof(input_uv));
      dimensions[0] = texture_dimensions[0];
      dimensions[1] = texture_dimensions[1];
      const auto* bytes = static_cast<const uint8_t*>(manager);
      mode = *reinterpret_cast<const int32_t*>(bytes + 0x18u);
      offset_x = *reinterpret_cast<const float*>(bytes + 0x264u);
      offset_y = *reinterpret_cast<const float*>(bytes + 0x268u);
      inputs_read = true;
    }
  } __except (EXCEPTION_EXECUTE_HANDLER) {
    inputs_read = false;
  }
  const uint32_t result = g_orig_hunex_gge_quad_vertex(
      manager, xy, uv_pixels, texture_dimensions);
  if (result != 4u || !inputs_read || mode != 1 || dimensions[0] <= 0 ||
      dimensions[0] > 32768 || dimensions[1] <= 0 ||
      dimensions[1] > 32768 || !std::isfinite(offset_x) ||
      !std::isfinite(offset_y)) {
    g_hunex_gge_pending_quad = {};
    return result;
  }
  uintptr_t vertex_buffer = 0u;
  __try {
    const auto* bytes = static_cast<const uint8_t*>(manager);
    vertex_buffer = reinterpret_cast<uintptr_t>(
        *reinterpret_cast<void* const*>(bytes + 0x1d0u));
    if (vertex_buffer == 0u) {
      vertex_buffer = reinterpret_cast<uintptr_t>(
          *reinterpret_cast<void* const*>(bytes + 0x170u));
    }
    if (vertex_buffer == 0u) {
      vertex_buffer = reinterpret_cast<uintptr_t>(
          *reinterpret_cast<void* const*>(bytes + 0x10u));
    }
  } __except (EXCEPTION_EXECUTE_HANDLER) {
    vertex_buffer = 0u;
  }
  if (vertex_buffer == 0u) {
    g_hunex_gge_pending_quad = {};
    return result;
  }
  HunexGgePendingQuad pending;
  pending.valid = true;
  pending.vertex_buffer = vertex_buffer;
  pending.texture_width = dimensions[0];
  pending.texture_height = dimensions[1];
  pending.sequence =
      g_hunex_gge_quad_sequence.fetch_add(1u, std::memory_order_relaxed) + 1u;
  pending.updated_tick = GetTickCount64();
  for (size_t index = 0u; index < 4u; ++index) {
    const float final_x = input_xy[index * 2u] - 0.5f + offset_x;
    const float final_y = input_xy[index * 2u + 1u] - 0.5f + offset_y;
    const float normalized_u = input_uv[index * 2u] / dimensions[0];
    const float normalized_v = input_uv[index * 2u + 1u] / dimensions[1];
    if (!std::isfinite(final_x) || !std::isfinite(final_y) ||
        !std::isfinite(normalized_u) || !std::isfinite(normalized_v)) {
      g_hunex_gge_pending_quad = {};
      return result;
    }
    pending.xy[index * 2u] = final_x;
    pending.xy[index * 2u + 1u] = final_y;
    pending.uv[index * 2u] = normalized_u;
    pending.uv[index * 2u + 1u] = normalized_v;
  }
  g_hunex_gge_pending_quad = pending;
  return result;
}

bool CaptureHunexGgeD3DProjectionSizes(
    void* renderer, void* texture,
    const HunexGgePendingSurfaceChain& surface_chain,
    const HunexGgePendingQuad& quad, HunexGgeProjectionEvidence* output) {
  if (renderer == nullptr || texture == nullptr || output == nullptr) {
    return false;
  }
  IDirect3DDevice9* device = nullptr;
  IDirect3DSurface9* render_target = nullptr;
  IDirect3DSurface9* backbuffer = nullptr;
  D3DVIEWPORT9 viewport = {};
  D3DSURFACE_DESC texture_desc = {};
  D3DSURFACE_DESC render_target_desc = {};
  D3DSURFACE_DESC backbuffer_desc = {};
  bool d3d_read = false;
  __try {
    device = *reinterpret_cast<IDirect3DDevice9**>(
        static_cast<uint8_t*>(renderer) + 0x20u);
    auto* d3d_texture = static_cast<IDirect3DTexture9*>(texture);
    if (device != nullptr &&
        SUCCEEDED(d3d_texture->GetLevelDesc(0u, &texture_desc)) &&
        SUCCEEDED(device->GetViewport(&viewport)) &&
        SUCCEEDED(device->GetRenderTarget(0u, &render_target)) &&
        render_target != nullptr &&
        SUCCEEDED(render_target->GetDesc(&render_target_desc)) &&
        SUCCEEDED(device->GetBackBuffer(
            0u, 0u, D3DBACKBUFFER_TYPE_MONO, &backbuffer)) &&
        backbuffer != nullptr &&
        SUCCEEDED(backbuffer->GetDesc(&backbuffer_desc))) {
      d3d_read = true;
    }
  } __except (EXCEPTION_EXECUTE_HANDLER) {
    d3d_read = false;
  }
  if (backbuffer != nullptr) {
    __try {
      backbuffer->Release();
    } __except (EXCEPTION_EXECUTE_HANDLER) {
    }
  }
  if (render_target != nullptr) {
    __try {
      render_target->Release();
    } __except (EXCEPTION_EXECUTE_HANDLER) {
    }
  }
  if (!d3d_read || render_target != backbuffer ||
      texture_desc.Width != surface_chain.surface.words[1] ||
      texture_desc.Height != surface_chain.surface.words[2] ||
      texture_desc.Width != static_cast<UINT>(quad.texture_width) ||
      texture_desc.Height != static_cast<UINT>(quad.texture_height) ||
      render_target_desc.Width != backbuffer_desc.Width ||
      render_target_desc.Height != backbuffer_desc.Height ||
      viewport.Width == 0u || viewport.Height == 0u ||
      viewport.X > render_target_desc.Width ||
      viewport.Y > render_target_desc.Height ||
      viewport.Width > render_target_desc.Width - viewport.X ||
      viewport.Height > render_target_desc.Height - viewport.Y ||
      backbuffer_desc.Width == 0u || backbuffer_desc.Width > 32768u ||
      backbuffer_desc.Height == 0u || backbuffer_desc.Height > 32768u) {
    return false;
  }
  const HWND game = g_hunex_gge_lookup_runtime.shield_game_window.load(
      std::memory_order_acquire);
  RECT client = {};
  if (game == nullptr || !IsWindow(game) || !GetClientRect(game, &client)) {
    return false;
  }
  const int32_t client_width = client.right - client.left;
  const int32_t client_height = client.bottom - client.top;
  if (client_width <= 0 || client_width > 32768 || client_height <= 0 ||
      client_height > 32768) {
    return false;
  }
  HunexGgeProjectionEvidence evidence;
  evidence.generation = surface_chain.generation;
  evidence.story_thread_address = surface_chain.story_thread_address;
  evidence.raw_text_hash = surface_chain.raw_text_hash;
  evidence.texture = reinterpret_cast<uintptr_t>(texture);
  evidence.vertex_buffer = quad.vertex_buffer;
  evidence.device = reinterpret_cast<uintptr_t>(device);
  evidence.render_target = reinterpret_cast<uintptr_t>(render_target);
  evidence.published_tick = GetTickCount64();
  evidence.render_thread_id = surface_chain.render_thread_id;
  evidence.surface = surface_chain.surface;
  std::memcpy(evidence.xy, quad.xy, sizeof(evidence.xy));
  std::memcpy(evidence.uv, quad.uv, sizeof(evidence.uv));
  evidence.viewport_x = static_cast<int32_t>(viewport.X);
  evidence.viewport_y = static_cast<int32_t>(viewport.Y);
  evidence.viewport_width = static_cast<int32_t>(viewport.Width);
  evidence.viewport_height = static_cast<int32_t>(viewport.Height);
  evidence.backbuffer_width = static_cast<int32_t>(backbuffer_desc.Width);
  evidence.backbuffer_height = static_cast<int32_t>(backbuffer_desc.Height);
  evidence.client_width = client_width;
  evidence.client_height = client_height;
  *output = evidence;
  return true;
}

uint32_t Detour_HunexGgeSpriteDraw(void* renderer, void* texture,
                                   void* vertex_buffer, uint32_t mode) {
  const uint64_t draw_sequence =
      g_hunex_gge_sprite_draw_sequence.fetch_add(
          1u, std::memory_order_relaxed) +
      1u;
  auto& surface_chain = g_hunex_gge_pending_surface_chain;
  auto& quad = g_hunex_gge_pending_quad;
  const ULONGLONG now = GetTickCount64();
  HunexGgeProjectionEvidence evidence;
  const bool linked_surface_texture =
      surface_chain.active && surface_chain.texture != 0u &&
      surface_chain.texture == reinterpret_cast<uintptr_t>(texture);
  bool exact_chain = false;
  fushi_voice_hook::HunexGgeProjectionTraceFailure diagnostic_failure =
      fushi_voice_hook::HunexGgeProjectionTraceFailure::kNone;
  if (linked_surface_texture) {
    if (mode != 1u) {
      diagnostic_failure = fushi_voice_hook::HunexGgeProjectionTraceFailure::
          kSpriteModeRejected;
    } else if (surface_chain.render_thread_id != GetCurrentThreadId()) {
      diagnostic_failure = fushi_voice_hook::HunexGgeProjectionTraceFailure::
          kSpriteRenderThreadMismatch;
    } else if (!IsFreshHunexGgeProjectionTick(surface_chain.updated_tick,
                                              now)) {
      diagnostic_failure = fushi_voice_hook::HunexGgeProjectionTraceFailure::
          kSpriteSurfaceExpired;
    } else if (!quad.valid) {
      diagnostic_failure = fushi_voice_hook::HunexGgeProjectionTraceFailure::
          kSpriteQuadMissing;
    } else if (quad.vertex_buffer !=
               reinterpret_cast<uintptr_t>(vertex_buffer)) {
      diagnostic_failure = fushi_voice_hook::HunexGgeProjectionTraceFailure::
          kSpriteVertexMismatch;
    } else if (!IsFreshHunexGgeProjectionTick(quad.updated_tick, now)) {
      diagnostic_failure = fushi_voice_hook::HunexGgeProjectionTraceFailure::
          kSpriteQuadExpired;
    } else if (!CaptureHunexGgeD3DProjectionSizes(
                   renderer, texture, surface_chain, quad, &evidence)) {
      diagnostic_failure = fushi_voice_hook::HunexGgeProjectionTraceFailure::
          kSpriteProjectionSizesRejected;
    } else {
      exact_chain = true;
    }
  }
  const uint32_t result =
      g_orig_hunex_gge_sprite_draw(renderer, texture, vertex_buffer, mode);
  if (linked_surface_texture &&
      (!exact_chain || FAILED(static_cast<HRESULT>(result)))) {
    fushi_voice_hook::HunexGgeTraceEvent diagnostic;
    diagnostic.draw_sequence = surface_chain.generation;
    diagnostic.text_hash = reinterpret_cast<uintptr_t>(texture);
    diagnostic.draw_arg12_bits = reinterpret_cast<uintptr_t>(vertex_buffer);
    diagnostic.story_line_base = surface_chain.story_thread_address;
    diagnostic.story_line_hash = surface_chain.raw_text_hash;
    diagnostic.glyph_ordinal = mode;
    diagnostic.draw_width = static_cast<int32_t>(result);
    diagnostic.draw_arg13 = static_cast<uint32_t>(draw_sequence);
    diagnostic.render_x = static_cast<int32_t>(surface_chain.surface.words[1]);
    diagnostic.render_y = static_cast<int32_t>(surface_chain.surface.words[2]);
    diagnostic.evidence_flags =
        fushi_voice_hook::kHunexGgeTraceEvidenceSurfaceComposeGraph |
        fushi_voice_hook::kHunexGgeTraceEvidenceSurfaceDescriptorsRead |
        fushi_voice_hook::kHunexGgeTraceEvidenceTextureIdentityLinked;
    if (quad.valid &&
        quad.vertex_buffer == reinterpret_cast<uintptr_t>(vertex_buffer)) {
      diagnostic.evidence_flags |=
          fushi_voice_hook::kHunexGgeTraceEvidenceQuadIdentityLinked;
    }
    if (exact_chain) {
      diagnostic.evidence_flags |=
          fushi_voice_hook::kHunexGgeTraceEvidenceProjectionSizesRead;
    }
    std::memcpy(diagnostic.descriptor_words, surface_chain.surface.words,
                sizeof(diagnostic.descriptor_words));
    if (quad.valid) {
      for (size_t index = 0u; index < 8u; ++index) {
        diagnostic.output_words[index] = HunexGgeFloatBits(quad.xy[index]);
        diagnostic.output_words[index + 8u] =
            HunexGgeFloatBits(quad.uv[index]);
      }
    }
    PublishHunexGgeProjectionDiagnostic(
        diagnostic, fushi_voice_hook::HunexGgeProjectionTraceStage::kSprite,
        exact_chain
            ? fushi_voice_hook::HunexGgeProjectionTraceFailure::
                  kSpriteDrawFailed
            : diagnostic_failure);
  }
  if (exact_chain && SUCCEEDED(static_cast<HRESULT>(result))) {
    evidence.draw_sequence = draw_sequence;
    PublishHunexGgeProjectionEvidence(evidence);
    fushi_voice_hook::HunexGgeTraceEvent event;
    event.kind = static_cast<uint32_t>(
        fushi_voice_hook::HunexGgeTraceKind::kSpriteQuad);
    event.draw_sequence = evidence.generation;
    event.text_hash = evidence.texture;
    event.draw_arg12_bits = evidence.vertex_buffer;
    event.story_line_base = evidence.story_thread_address;
    event.story_line_hash = evidence.raw_text_hash;
    event.render_x = static_cast<int32_t>(evidence.surface.words[1]);
    event.render_y = static_cast<int32_t>(evidence.surface.words[2]);
    event.viewport_left = evidence.viewport_x;
    event.viewport_top = evidence.viewport_y;
    event.viewport_right = evidence.viewport_x + evidence.viewport_width;
    event.viewport_bottom = evidence.viewport_y + evidence.viewport_height;
    event.arg7 = mode;
    event.draw_arg13 = static_cast<uint32_t>(draw_sequence);
    event.result = static_cast<int32_t>(result);
    event.evidence_flags =
        fushi_voice_hook::kHunexGgeTraceEvidenceSurfaceComposeGraph |
        fushi_voice_hook::kHunexGgeTraceEvidenceSurfaceDescriptorsRead |
        fushi_voice_hook::kHunexGgeTraceEvidenceTextureIdentityLinked |
        fushi_voice_hook::kHunexGgeTraceEvidenceQuadIdentityLinked |
        fushi_voice_hook::kHunexGgeTraceEvidenceProjectionSizesRead;
    std::memcpy(event.descriptor_words, evidence.surface.words,
                sizeof(event.descriptor_words));
    for (size_t index = 0u; index < 8u; ++index) {
      event.output_words[index] = HunexGgeFloatBits(evidence.xy[index]);
      event.output_words[index + 8u] = HunexGgeFloatBits(evidence.uv[index]);
    }
    event.output_words[16] = static_cast<uint32_t>(evidence.viewport_x);
    event.output_words[17] = static_cast<uint32_t>(evidence.viewport_y);
    event.output_words[18] = static_cast<uint32_t>(evidence.viewport_width);
    event.output_words[19] = static_cast<uint32_t>(evidence.viewport_height);
    event.output_words[20] = static_cast<uint32_t>(evidence.backbuffer_width);
    event.output_words[21] = static_cast<uint32_t>(evidence.backbuffer_height);
    event.output_words[22] = static_cast<uint32_t>(evidence.client_width);
    event.output_words[23] = static_cast<uint32_t>(evidence.client_height);
    event.output_words[24] = static_cast<uint32_t>(evidence.device);
    event.output_words[25] = static_cast<uint32_t>(evidence.device >> 32u);
    event.output_words[26] = static_cast<uint32_t>(evidence.render_target);
    event.output_words[27] =
        static_cast<uint32_t>(evidence.render_target >> 32u);
    PublishHunexGgeTrace(event);
  }
  return result;
}

int __fastcall Detour_HunexGgeSemanticSubmit(
    void* input_manager, void** out_capture, uint32_t engine_active,
    int32_t transformed_x, int32_t transformed_y,
    const uint64_t* edge_mask) {
  // The semantic submitter consumes the poller's exact edge mask before the
  // engine establishes manager +0x68 mouse capture.  Read both masks as one
  // fail-open observation; malformed structural state must never invent or
  // suppress host input.
  uint64_t exact_edge_mask = 0u;
  uint64_t exact_held_mask = 0u;
  bool exact_sample_valid = false;
  if (edge_mask != nullptr && g_hunex_gge_anchors.held_action_mask != 0u) {
    __try {
      exact_edge_mask = *edge_mask;
      exact_held_mask = *reinterpret_cast<volatile const uint64_t*>(
          g_hunex_gge_anchors.held_action_mask);
      exact_sample_valid = true;
    } __except (EXCEPTION_EXECUTE_HANDLER) {
      exact_sample_valid = false;
    }
  }
  if (!exact_sample_valid) {
    return g_orig_hunex_gge_semantic_submit(
        input_manager, out_capture, engine_active, transformed_x,
        transformed_y, edge_mask);
  }

  namespace core = fushi_voice_hook::hunex_lookup_core;
  uint16_t sampled_raw = 0u;
  if ((exact_held_mask & 0x1u) != 0u) sampled_raw |= 0x8000u;
  if ((exact_edge_mask & 0x1u) != 0u) sampled_raw |= 0x0001u;

  const bool popup_visible = IsLookupOverlayInputShieldVisible();
  const HunexGgeLookupPointerSample pointer_sample =
      SampleHunexGgeLookupPointer();
  const bool native_lookup_allowed =
      engine_active != 0u &&
      fushi_voice_hook::g_geometry_provider_registry.NativeInputAllowed(
          g_header,
          fushi_voice_hook::kLookupGeometryProviderEngineExactLayout,
          fushi_voice_hook::kLookupGeometryProviderIdHunexGge);
  const HunexGgeLookupSampleResult lookup_result =
      SampleHunexGgeLookupLeftButton(
          &g_hunex_gge_lookup_runtime, GetCurrentThreadId(), sampled_raw,
          pointer_sample, popup_visible, native_lookup_allowed);

  if (lookup_result.popup_transaction &&
      pointer_sample.foreground_game_point &&
      (sampled_raw & core::kAsyncPressedMask) != 0u) {
    (void)RequestLookupOverlayOutsideDismiss();
  }
  if (lookup_result.thread_conflict && g_header != nullptr) {
    InterlockedOr(reinterpret_cast<volatile LONG*>(&g_header->lookup_diag),
                  static_cast<LONG>(
                      fushi_voice_hook::kLookupDiagSensorFault));
  }

  const bool raw_active =
      (sampled_raw & core::kAsyncPressedMask) != 0u;
  if (lookup_result.consume && raw_active) {
    g_hunex_gge_lookup_runtime.sampled_input_latched_buttons.fetch_or(
        0x1u, std::memory_order_acq_rel);
  }
  const bool transaction_latched =
      (g_hunex_gge_lookup_runtime.sampled_input_latched_buttons.load(
           std::memory_order_acquire) &
       0x1u) != 0u;
  const bool consume_semantic_left =
      lookup_result.consume || transaction_latched;
  if (!raw_active) {
    g_hunex_gge_lookup_runtime.sampled_input_latched_buttons.fetch_and(
        static_cast<uint8_t>(~0x1u), std::memory_order_acq_rel);
  }

  // A miss keeps the original pointer and every bit verbatim.  An owned lookup
  // or popup transaction clears only semantic left action bit zero; all other
  // keyboard/mouse actions and the original return value remain host-owned.
  if (!consume_semantic_left) {
    return g_orig_hunex_gge_semantic_submit(
        input_manager, out_capture, engine_active, transformed_x,
        transformed_y, edge_mask);
  }
  const uint64_t filtered_edge_mask = exact_edge_mask & ~uint64_t{0x1u};
  return g_orig_hunex_gge_semantic_submit(
      input_manager, out_capture, engine_active, transformed_x, transformed_y,
      &filtered_edge_mask);
}

SHORT WINAPI Detour_HunexGgeGetAsyncKeyState(int virtual_key) {
  const SHORT original_raw = g_orig_hunex_gge_get_async_key_state(virtual_key);
  uint16_t sampled_raw = static_cast<uint16_t>(original_raw);
  const uintptr_t return_address =
      reinterpret_cast<uintptr_t>(_ReturnAddress());
  fushi_voice_hook::HunexGgeTraceKind kind =
      fushi_voice_hook::HunexGgeTraceKind::kInputGeneric;
  bool recognized_caller = true;
  if (return_address == g_hunex_gge_anchors.generic_key_return) {
    kind = fushi_voice_hook::HunexGgeTraceKind::kInputGeneric;
  } else if (return_address == g_hunex_gge_anchors.left_button_return) {
    kind = fushi_voice_hook::HunexGgeTraceKind::kInputLeftButton;
  } else {
    recognized_caller = false;
  }
  const bool admitted_lookup_sample =
      recognized_caller &&
      kind == fushi_voice_hook::HunexGgeTraceKind::kInputGeneric &&
      (virtual_key == VK_SHIFT || virtual_key == VK_RBUTTON ||
       virtual_key == VK_MBUTTON);
  HunexGgeLookupSampleResult lookup_result;
  lookup_result.filtered_state = sampled_raw;
  const bool bitmap_popup_visible = IsLookupOverlayInputShieldVisible();
  // One sampled-input callback owns one pointer observation.  Re-reading the
  // foreground HWND/cursor later in the same callback can cross a focus or
  // WindowFromPoint transition and disagree about whether this physical click
  // belongs to the game.  SGRE/Leaf/Siglus apply the same game-point gate
  // before requesting a bitmap popup outside-dismiss.
  const HunexGgeLookupPointerSample pointer_sample =
      admitted_lookup_sample
          ? SampleHunexGgeLookupPointer()
          : HunexGgeLookupPointerSample{};
  if (admitted_lookup_sample) {
    const bool native_lookup_allowed =
        fushi_voice_hook::g_geometry_provider_registry.NativeInputAllowed(
            g_header,
            fushi_voice_hook::kLookupGeometryProviderEngineExactLayout,
            fushi_voice_hook::kLookupGeometryProviderIdHunexGge);
    lookup_result = HandleHunexGgeGetAsyncKeyState(
        &g_hunex_gge_lookup_runtime, virtual_key, GetCurrentThreadId(),
        sampled_raw, pointer_sample,
        bitmap_popup_visible, native_lookup_allowed);
    if (lookup_result.popup_transaction && bitmap_popup_visible &&
        pointer_sample.foreground_game_point &&
        (sampled_raw &
         fushi_voice_hook::hunex_lookup_core::kAsyncPressedMask) != 0u) {
      (void)RequestLookupOverlayOutsideDismiss();
    }
    if (lookup_result.thread_conflict && g_header != nullptr) {
      InterlockedOr(reinterpret_cast<volatile LONG*>(&g_header->lookup_diag),
                    static_cast<LONG>(
                        fushi_voice_hook::kLookupDiagSensorFault));
    }
  }
  if (recognized_caller) {
    InterlockedIncrement64(reinterpret_cast<volatile LONG64*>(
        &FushiHunexGgeTraceV3.input_calls));
  }
  if (recognized_caller &&
      (virtual_key == VK_LBUTTON || virtual_key == VK_SHIFT ||
       kind == fushi_voice_hook::HunexGgeTraceKind::kInputLeftButton)) {
    if (virtual_key >= 0 && virtual_key < 256) {
      const size_t kind_index =
          kind == fushi_voice_hook::HunexGgeTraceKind::kInputGeneric ? 0u
                                                                    : 1u;
      const LONG encoded = static_cast<LONG>(
          fushi_voice_hook::hunex_lookup::EncodeInputTraceState(original_raw));
      const LONG previous = InterlockedExchange(
          &g_hunex_gge_input_trace_state[kind_index][virtual_key], encoded);
      if (fushi_voice_hook::hunex_lookup::IsInputTraceStateChange(
              static_cast<uint32_t>(previous), original_raw)) {
        fushi_voice_hook::HunexGgeTraceEvent event;
        event.kind = static_cast<uint32_t>(kind);
        event.caller_rva = HunexGgeRva(return_address);
        event.arg7 = static_cast<uint32_t>(virtual_key);
        event.result = static_cast<int32_t>(original_raw);
        PublishHunexGgeTrace(event);
      }
    }
  }
  uint16_t filtered = admitted_lookup_sample
                          ? lookup_result.filtered_state
                          : sampled_raw;
  if (virtual_key == VK_LBUTTON) {
    namespace core = fushi_voice_hook::hunex_lookup_core;
    const uint16_t raw_bits = sampled_raw;
    const bool raw_active = (raw_bits & core::kAsyncPressedMask) != 0u;
    bool consume = lookup_result.consume ||
                   HunexGgeUnknownLeftButtonMustConsume(
                       &g_hunex_gge_lookup_runtime, raw_bits,
                       bitmap_popup_visible);
    if (consume && raw_active) {
      g_hunex_gge_lookup_runtime.sampled_input_latched_buttons.fetch_or(
          0x1u, std::memory_order_acq_rel);
    }
    consume = consume ||
              (g_hunex_gge_lookup_runtime.sampled_input_latched_buttons.load(
                   std::memory_order_acquire) &
               0x1u) != 0u;
    filtered = core::FilterAsyncKeyState(raw_bits, consume);
    if (!raw_active) {
      g_hunex_gge_lookup_runtime.sampled_input_latched_buttons.fetch_and(
          static_cast<uint8_t>(~0x1u), std::memory_order_acq_rel);
    }
  }
  return static_cast<SHORT>(filtered);
}

bool HunexGgeReadChainedUnwindParent(
    const RUNTIME_FUNCTION& runtime, uintptr_t expected_module,
    RUNTIME_FUNCTION* parent) {
  if (expected_module == 0u || parent == nullptr ||
      runtime.UnwindData == 0u) {
    return false;
  }

  // x64 UNWIND_INFO starts with four bytes, followed by CountOfCodes
  // two-byte UNWIND_CODE entries rounded up to an even entry count.  A
  // chained record is the three-DWORD RUNTIME_FUNCTION immediately after
  // those codes.  Parse the byte layout explicitly: the Windows SDK does not
  // expose UNWIND_INFO consistently to every compiler used by the helper.
  __try {
    const auto* unwind = reinterpret_cast<const uint8_t*>(
        expected_module + static_cast<uintptr_t>(runtime.UnwindData));
    const uint8_t version = static_cast<uint8_t>(unwind[0] & 0x07u);
    const uint8_t flags = static_cast<uint8_t>(unwind[0] >> 3u);
    if (version != 1u || (flags & UNW_FLAG_CHAININFO) == 0u) return false;
    const size_t unwind_code_count = unwind[2];
    const size_t aligned_code_count = (unwind_code_count + 1u) & ~size_t{1u};
    const auto* chained = reinterpret_cast<const RUNTIME_FUNCTION*>(
        unwind + 4u + aligned_code_count * 2u);
    *parent = *chained;
  } __except (EXCEPTION_EXECUTE_HANDLER) {
    return false;
  }
  return parent->EndAddress > parent->BeginAddress;
}

bool GetHunexGgeFunctionSpan(const uint8_t* expected_entry,
                             uintptr_t expected_module, size_t maximum_bytes,
                             const uint8_t** span, size_t* span_bytes) {
  if (expected_entry == nullptr || expected_module == 0u || span == nullptr ||
      span_bytes == nullptr || maximum_bytes == 0u) {
    return false;
  }
  DWORD64 image_base = 0u;
  const PRUNTIME_FUNCTION runtime = RtlLookupFunctionEntry(
      reinterpret_cast<DWORD64>(expected_entry), &image_base, nullptr);
  if (runtime == nullptr || image_base != expected_module ||
      image_base + runtime->BeginAddress !=
          reinterpret_cast<uintptr_t>(expected_entry) ||
      runtime->EndAddress <= runtime->BeginAddress) {
    return false;
  }
  // MSVC may split one logical function into adjacent RUNTIME_FUNCTION
  // fragments.  The later fragments carry UNW_FLAG_CHAININFO and name an
  // earlier fragment (or the root) as their parent.  WoH's texture uploader
  // and quad builder both use this form; treating only the first fragment as
  // the function made their structural body checks fail before any lookup or
  // input hook could be installed.
  constexpr size_t kMaximumChainedFragments = 32u;
  RUNTIME_FUNCTION accepted[kMaximumChainedFragments] = {};
  accepted[0] = *runtime;
  size_t accepted_count = 1u;
  DWORD logical_end = runtime->EndAddress;
  const DWORD root_begin = runtime->BeginAddress;

  while (accepted_count < kMaximumChainedFragments &&
         static_cast<size_t>(logical_end - root_begin) < maximum_bytes) {
    DWORD64 next_image_base = 0u;
    const PRUNTIME_FUNCTION next = RtlLookupFunctionEntry(
        image_base + logical_end, &next_image_base, nullptr);
    if (next == nullptr || next_image_base != image_base ||
        next->BeginAddress != logical_end ||
        next->EndAddress <= next->BeginAddress ||
        static_cast<size_t>(next->EndAddress - root_begin) > maximum_bytes) {
      break;
    }

    RUNTIME_FUNCTION parent = {};
    if (!HunexGgeReadChainedUnwindParent(*next, expected_module, &parent)) {
      break;
    }
    bool belongs_to_function = false;
    for (size_t index = 0u; index < accepted_count; ++index) {
      if (accepted[index].BeginAddress == parent.BeginAddress &&
          accepted[index].EndAddress == parent.EndAddress &&
          accepted[index].UnwindData == parent.UnwindData) {
        belongs_to_function = true;
        break;
      }
    }
    if (!belongs_to_function) break;

    accepted[accepted_count++] = *next;
    logical_end = next->EndAddress;
  }

  const size_t function_bytes =
      static_cast<size_t>(logical_end - root_begin);
  *span = expected_entry;
  *span_bytes = (std::min)(function_bytes, maximum_bytes);
  return *span_bytes > 0u;
}

bool HunexGgeImageContains(uintptr_t module, size_t image_size,
                           uintptr_t address, size_t bytes) {
  if (module == 0u || image_size == 0u || address < module ||
      address - module >= image_size || bytes > image_size) {
    return false;
  }
  return bytes <= image_size - static_cast<size_t>(address - module);
}

bool ScanHunexGgeRuntimeAnchors() {
  // install() is reachable both from the worker poll and module-load
  // notifications.  Give exactly one caller ownership of the scan; a caller
  // observing state 2 simply retries on the next poll instead of racing the
  // anchor/trace publication below.
  const LONG cached =
      InterlockedCompareExchange(&g_hunex_gge_trace_scan_state, 2, 0);
  if (cached != 0) return cached == 1;
  auto* trace = &FushiHunexGgeTraceV3;
  trace->scanner_status |=
      fushi_voice_hook::kHunexGgeTraceScannerProfileMatched;
  HMODULE module = GetModuleHandleW(nullptr);
  if (module == nullptr) {
    InterlockedExchange(&g_hunex_gge_trace_scan_state, -1);
    return false;
  }

  const uint8_t* draw = nullptr;
  const uint8_t* glyph = nullptr;
  constexpr size_t kMaximumBodySubmitCandidates = 8u;
  const uint8_t* body_submit_candidates[kMaximumBodySubmitCandidates] = {};
  size_t body_submit_candidate_count = 0u;
  const uint8_t* surface_compose_wrapper = nullptr;
  const uint8_t* surface_compose = nullptr;
  const uint8_t* texture_upload = nullptr;
  const uint8_t* quad_vertex = nullptr;
  const uint8_t* sprite_draw = nullptr;
  const uint8_t* key_poller = nullptr;
  const uint8_t* input_pump = nullptr;
  const uint8_t* semantic_submit = nullptr;
  uint32_t draw_count = 0u;
  uint32_t glyph_count = 0u;
  uint32_t body_submit_count = 0u;
  uint32_t surface_compose_wrapper_count = 0u;
  uint32_t surface_compose_count = 0u;
  uint32_t texture_upload_count = 0u;
  uint32_t quad_vertex_count = 0u;
  uint32_t sprite_draw_count = 0u;
  uint32_t key_poller_count = 0u;
  uint32_t input_pump_count = 0u;
  uint32_t semantic_submit_count = 0u;
  uint16_t machine = 0u;
  size_t image_size = 0u;
  bool pe_valid = false;
  __try {
    const auto* dos = reinterpret_cast<const IMAGE_DOS_HEADER*>(module);
    if (dos->e_magic == IMAGE_DOS_SIGNATURE) {
      const auto* nt = reinterpret_cast<const IMAGE_NT_HEADERS*>(
          reinterpret_cast<const uint8_t*>(module) + dos->e_lfanew);
      if (nt->Signature == IMAGE_NT_SIGNATURE &&
          nt->OptionalHeader.Magic == IMAGE_NT_OPTIONAL_HDR64_MAGIC &&
          nt->FileHeader.Machine == IMAGE_FILE_MACHINE_AMD64) {
        pe_valid = true;
        machine = nt->FileHeader.Machine;
        image_size = nt->OptionalHeader.SizeOfImage;
        const IMAGE_SECTION_HEADER* sections = IMAGE_FIRST_SECTION(nt);
        for (uint16_t index = 0u; index < nt->FileHeader.NumberOfSections;
             ++index) {
          if ((sections[index].Characteristics & IMAGE_SCN_MEM_EXECUTE) == 0u ||
              sections[index].Misc.VirtualSize == 0u) {
            continue;
          }
          const auto* section = reinterpret_cast<const uint8_t*>(module) +
                                sections[index].VirtualAddress;
          const size_t bytes = sections[index].Misc.VirtualSize;
          const auto draw_match =
              fushi_voice_hook::hunex_lookup::FindUniqueMaskedPattern(
                  section, bytes,
                  fushi_voice_hook::hunex_lookup::kDrawEntryPattern);
          const auto glyph_match =
              fushi_voice_hook::hunex_lookup::FindUniqueMaskedPattern(
                  section, bytes,
                  fushi_voice_hook::hunex_lookup::kGlyphEntryPattern);
          const auto poller_match =
              fushi_voice_hook::hunex_lookup::FindUniqueMaskedPattern(
                  section, bytes,
                  fushi_voice_hook::hunex_lookup::kKeyPollerEntryPattern);
          const auto pump_match =
              fushi_voice_hook::hunex_lookup::FindUniqueMaskedPattern(
                  section, bytes,
                  fushi_voice_hook::hunex_lookup::kInputPumpEntryPattern);
          const auto semantic_submit_match =
              fushi_voice_hook::hunex_lookup::FindUniqueMaskedPattern(
                  section, bytes,
                  fushi_voice_hook::hunex_lookup::
                      kSemanticSubmitEntryPattern);
          const auto surface_compose_match =
              fushi_voice_hook::hunex_lookup::FindUniqueMaskedPattern(
                  section, bytes,
                  fushi_voice_hook::hunex_lookup::
                      kSurfaceComposeEntryPattern);
          const auto surface_compose_wrapper_match =
              fushi_voice_hook::hunex_lookup::FindUniqueMaskedPattern(
                  section, bytes,
                  fushi_voice_hook::hunex_lookup::
                      kSurfaceComposeWrapperEntryPattern);
          const auto texture_upload_match =
              fushi_voice_hook::hunex_lookup::FindUniqueMaskedPattern(
                  section, bytes,
                  fushi_voice_hook::hunex_lookup::
                      kTextureUploadEntryPattern);
          const auto quad_vertex_match =
              fushi_voice_hook::hunex_lookup::FindUniqueMaskedPattern(
                  section, bytes,
                  fushi_voice_hook::hunex_lookup::kQuadVertexEntryPattern);
          const auto sprite_draw_match =
              fushi_voice_hook::hunex_lookup::FindUniqueMaskedPattern(
                  section, bytes,
                  fushi_voice_hook::hunex_lookup::kSpriteDrawEntryPattern);
          if (draw_match.count == 1u && draw_count == 0u)
            draw = section + draw_match.offset;
          if (glyph_match.count == 1u && glyph_count == 0u)
            glyph = section + glyph_match.offset;
          if (bytes >=
              fushi_voice_hook::hunex_lookup::kBodySubmitEntryPattern.size) {
            for (size_t offset = 0u;
                 offset <= bytes -
                               fushi_voice_hook::hunex_lookup::
                                   kBodySubmitEntryPattern.size;
                 ++offset) {
              if (!fushi_voice_hook::hunex_lookup::MatchesMaskedPattern(
                      section + offset,
                      fushi_voice_hook::hunex_lookup::
                          kBodySubmitEntryPattern)) {
                continue;
              }
              if (body_submit_candidate_count <
                  kMaximumBodySubmitCandidates) {
                body_submit_candidates[body_submit_candidate_count] =
                    section + offset;
              }
              ++body_submit_candidate_count;
              ++body_submit_count;
            }
          }
          if (poller_match.count == 1u && key_poller_count == 0u)
            key_poller = section + poller_match.offset;
          if (pump_match.count == 1u && input_pump_count == 0u)
            input_pump = section + pump_match.offset;
          if (semantic_submit_match.count == 1u &&
              semantic_submit_count == 0u) {
            semantic_submit = section + semantic_submit_match.offset;
          }
          if (surface_compose_match.count == 1u &&
              surface_compose_count == 0u) {
            surface_compose = section + surface_compose_match.offset;
          }
          if (surface_compose_wrapper_match.count == 1u &&
              surface_compose_wrapper_count == 0u) {
            surface_compose_wrapper =
                section + surface_compose_wrapper_match.offset;
          }
          if (texture_upload_match.count == 1u &&
              texture_upload_count == 0u) {
            texture_upload = section + texture_upload_match.offset;
          }
          if (quad_vertex_match.count == 1u && quad_vertex_count == 0u) {
            quad_vertex = section + quad_vertex_match.offset;
          }
          if (sprite_draw_match.count == 1u && sprite_draw_count == 0u) {
            sprite_draw = section + sprite_draw_match.offset;
          }
          draw_count += draw_match.count;
          glyph_count += glyph_match.count;
          key_poller_count += poller_match.count;
          input_pump_count += pump_match.count;
          semantic_submit_count += semantic_submit_match.count;
          surface_compose_wrapper_count +=
              surface_compose_wrapper_match.count;
          surface_compose_count += surface_compose_match.count;
          texture_upload_count += texture_upload_match.count;
          quad_vertex_count += quad_vertex_match.count;
          sprite_draw_count += sprite_draw_match.count;
        }
      }
    }
  } __except (EXCEPTION_EXECUTE_HANDLER) {
    pe_valid = false;
  }
  trace->module_machine = machine;
  trace->draw_match_count = draw_count;
  trace->glyph_match_count = glyph_count;
  trace->body_submit_match_count = body_submit_count;
  trace->key_poller_match_count = key_poller_count;
  trace->input_pump_match_count = input_pump_count;
  if (surface_compose_wrapper_count == 1u &&
      surface_compose_count == 1u) {
    trace->scanner_status |=
        fushi_voice_hook::kHunexGgeTraceScannerSurfaceComposeUnique;
  }
  const bool projection_entries_unique =
      texture_upload_count == 1u && quad_vertex_count == 1u &&
      sprite_draw_count == 1u && texture_upload != nullptr &&
      quad_vertex != nullptr && sprite_draw != nullptr;
  if (projection_entries_unique) {
    trace->scanner_status |=
        fushi_voice_hook::kHunexGgeTraceScannerProjectionEntriesUnique;
  }
  if (!pe_valid || image_size == 0u || draw_count != 1u ||
      glyph_count != 1u || body_submit_count == 0u ||
      body_submit_candidate_count > kMaximumBodySubmitCandidates ||
      key_poller_count != 1u || input_pump_count != 1u ||
      semantic_submit_count != 1u || draw == nullptr || glyph == nullptr ||
      key_poller == nullptr || input_pump == nullptr ||
      semantic_submit == nullptr) {
    InterlockedExchange(&g_hunex_gge_trace_scan_state, -1);
    return false;
  }
  trace->scanner_status |=
      fushi_voice_hook::kHunexGgeTraceScannerPe64 |
      fushi_voice_hook::kHunexGgeTraceScannerDrawUnique |
      fushi_voice_hook::kHunexGgeTraceScannerGlyphUnique |
      fushi_voice_hook::kHunexGgeTraceScannerInputUnique;

  const uint8_t* draw_span = nullptr;
  const uint8_t* poller_span = nullptr;
  const uint8_t* poller_held_mask_span = nullptr;
  const uint8_t* pump_span = nullptr;
  size_t draw_bytes = 0u;
  size_t poller_bytes = 0u;
  size_t poller_held_mask_bytes = 0u;
  size_t pump_bytes = 0u;
  const uintptr_t module_address = reinterpret_cast<uintptr_t>(module);
  if (!GetHunexGgeFunctionSpan(
          draw, module_address,
          fushi_voice_hook::hunex_lookup::kDrawScanBytes, &draw_span,
          &draw_bytes) ||
      !GetHunexGgeFunctionSpan(
          key_poller, module_address,
          fushi_voice_hook::hunex_lookup::kKeyPollerScanBytes, &poller_span,
          &poller_bytes) ||
      !GetHunexGgeFunctionSpan(
          key_poller, module_address,
          fushi_voice_hook::hunex_lookup::kKeyPollerHeldMaskScanBytes,
          &poller_held_mask_span, &poller_held_mask_bytes) ||
      !GetHunexGgeFunctionSpan(
          input_pump, module_address,
          fushi_voice_hook::hunex_lookup::kInputPumpScanBytes, &pump_span,
          &pump_bytes)) {
    InterlockedExchange(&g_hunex_gge_trace_scan_state, -1);
    return false;
  }

  const auto first_glyph =
      fushi_voice_hook::hunex_lookup::FindUniqueMaskedPattern(
          draw_span, draw_bytes,
          fushi_voice_hook::hunex_lookup::kDrawFirstGlyphCallPattern);
  const auto second_glyph =
      fushi_voice_hook::hunex_lookup::FindUniqueMaskedPattern(
          draw_span, draw_bytes,
          fushi_voice_hook::hunex_lookup::kDrawSecondGlyphCallPattern);
  const auto render_item_call =
      fushi_voice_hook::hunex_lookup::FindUniqueMaskedPattern(
          draw_span, draw_bytes,
          fushi_voice_hook::hunex_lookup::kDrawRenderItemCallPattern);
  uintptr_t first_glyph_target = 0u;
  uintptr_t first_glyph_return = 0u;
  uintptr_t second_glyph_target = 0u;
  uintptr_t second_glyph_return = 0u;
  uintptr_t raw_first_return = 0u;
  uintptr_t raw_second_return = 0u;
  uintptr_t render_item_target = 0u;
  uintptr_t render_item_return = 0u;
  const uint32_t raw_glyph_calls =
      fushi_voice_hook::hunex_lookup::FindRel32CallReturnsToTarget(
          draw_span, draw_bytes, reinterpret_cast<uintptr_t>(glyph),
          &raw_first_return, &raw_second_return);
  const bool draw_graph_valid =
      first_glyph.count == 1u && second_glyph.count == 1u &&
      fushi_voice_hook::hunex_lookup::DecodeRel32CallTarget(
          draw_span + first_glyph.offset +
              fushi_voice_hook::hunex_lookup::kDrawFirstGlyphCallOffset,
          &first_glyph_target, &first_glyph_return) &&
      fushi_voice_hook::hunex_lookup::DecodeRel32CallTarget(
          draw_span + second_glyph.offset +
              fushi_voice_hook::hunex_lookup::kDrawSecondGlyphCallOffset,
          &second_glyph_target, &second_glyph_return) &&
      first_glyph_target == reinterpret_cast<uintptr_t>(glyph) &&
      second_glyph_target == reinterpret_cast<uintptr_t>(glyph) &&
      raw_glyph_calls == 2u && raw_first_return == first_glyph_return &&
      raw_second_return == second_glyph_return;

  uintptr_t raw_render_item_return = 0u;
  const bool render_item_call_decoded =
      render_item_call.count == 1u &&
      fushi_voice_hook::hunex_lookup::DecodeRel32CallTarget(
          draw_span + render_item_call.offset +
              fushi_voice_hook::hunex_lookup::kDrawRenderItemCallOffset,
          &render_item_target, &render_item_return) &&
      HunexGgeImageContains(module_address, image_size, render_item_target,
                            sizeof(fushi_voice_hook::hunex_lookup::
                                       kRenderItemEntryBytes));
  const uint8_t* render_item_span = nullptr;
  size_t render_item_bytes = 0u;
  const bool render_item_graph_valid =
      render_item_call_decoded &&
      fushi_voice_hook::hunex_lookup::MatchesMaskedPattern(
          reinterpret_cast<const uint8_t*>(render_item_target),
          fushi_voice_hook::hunex_lookup::kRenderItemEntryPattern) &&
      GetHunexGgeFunctionSpan(
          reinterpret_cast<const uint8_t*>(render_item_target),
          module_address, fushi_voice_hook::hunex_lookup::kRenderItemScanBytes,
          &render_item_span, &render_item_bytes) &&
      fushi_voice_hook::hunex_lookup::FindRel32CallReturnsToTarget(
          draw_span, draw_bytes, render_item_target, &raw_render_item_return,
          nullptr) == 1u &&
      raw_render_item_return == render_item_return;

  const uint8_t* body_submit = nullptr;
  uintptr_t body_submit_return = 0u;
  uint32_t body_submit_graph_matches = 0u;
  if (render_item_graph_valid) {
    for (size_t index = 0u; index < body_submit_candidate_count; ++index) {
      const uint8_t* candidate_span = nullptr;
      size_t candidate_bytes = 0u;
      if (!GetHunexGgeFunctionSpan(
              body_submit_candidates[index], module_address,
              fushi_voice_hook::hunex_lookup::kRenderItemScanBytes,
              &candidate_span, &candidate_bytes) ||
          candidate_bytes <
              fushi_voice_hook::hunex_lookup::kBodySubmitCallOffset + 5u) {
        continue;
      }
      uintptr_t candidate_target = 0u;
      uintptr_t candidate_return = 0u;
      uintptr_t raw_candidate_return = 0u;
      if (!fushi_voice_hook::hunex_lookup::DecodeRel32CallTarget(
              candidate_span +
                  fushi_voice_hook::hunex_lookup::kBodySubmitCallOffset,
              &candidate_target, &candidate_return) ||
          candidate_target != render_item_target ||
          fushi_voice_hook::hunex_lookup::FindRel32CallReturnsToTarget(
              candidate_span, candidate_bytes, render_item_target,
              &raw_candidate_return, nullptr) != 1u ||
          raw_candidate_return != candidate_return) {
        continue;
      }
      ++body_submit_graph_matches;
      if (body_submit_graph_matches == 1u) {
        body_submit = body_submit_candidates[index];
        body_submit_return = candidate_return;
      }
    }
  }
  const bool body_submit_graph_valid =
      body_submit_graph_matches == 1u && body_submit != nullptr;
  trace->render_item_call_match_count = render_item_call.count;

  const uint8_t* surface_compose_span = nullptr;
  size_t surface_compose_bytes = 0u;
  uintptr_t surface_compositor_target = 0u;
  uintptr_t surface_compose_first_return = 0u;
  uintptr_t surface_compose_second_return = 0u;
  uintptr_t surface_compose_final_first_return = 0u;
  uintptr_t surface_compose_final_second_return = 0u;
  bool surface_compose_inner_graph_valid = false;
  if (surface_compose_count == 1u && surface_compose != nullptr &&
      GetHunexGgeFunctionSpan(
          surface_compose, module_address,
          fushi_voice_hook::hunex_lookup::kSurfaceComposeScanBytes,
          &surface_compose_span, &surface_compose_bytes)) {
    const auto first_compose_call =
        fushi_voice_hook::hunex_lookup::FindUniqueMaskedPattern(
            surface_compose_span, surface_compose_bytes,
            fushi_voice_hook::hunex_lookup::
                kSurfaceComposeFirstCallPattern);
    const auto second_compose_call =
        fushi_voice_hook::hunex_lookup::FindUniqueMaskedPattern(
            surface_compose_span, surface_compose_bytes,
            fushi_voice_hook::hunex_lookup::
                kSurfaceComposeSecondCallPattern);
    const auto final_first_compose_call =
        fushi_voice_hook::hunex_lookup::FindUniqueMaskedPattern(
            surface_compose_span, surface_compose_bytes,
            fushi_voice_hook::hunex_lookup::
                kSurfaceComposeFinalFirstCallPattern);
    const auto final_second_compose_call =
        fushi_voice_hook::hunex_lookup::FindUniqueMaskedPattern(
            surface_compose_span, surface_compose_bytes,
            fushi_voice_hook::hunex_lookup::
                kSurfaceComposeFinalSecondCallPattern);
    uintptr_t second_target = 0u;
    uintptr_t final_first_target = 0u;
    uintptr_t final_second_target = 0u;
    uintptr_t raw_first_return = 0u;
    uintptr_t raw_second_return = 0u;
    const bool calls_decoded =
        first_compose_call.count == 1u &&
        second_compose_call.count == 1u &&
        second_compose_call.offset == first_compose_call.offset + 0x3du &&
        fushi_voice_hook::hunex_lookup::DecodeRel32CallTarget(
            surface_compose_span + first_compose_call.offset +
                fushi_voice_hook::hunex_lookup::
                    kSurfaceComposeCallOffset,
            &surface_compositor_target,
            &surface_compose_first_return) &&
        fushi_voice_hook::hunex_lookup::DecodeRel32CallTarget(
            surface_compose_span + second_compose_call.offset +
                fushi_voice_hook::hunex_lookup::
                    kSurfaceComposeCallOffset,
            &second_target, &surface_compose_second_return) &&
        second_target == surface_compositor_target &&
        final_first_compose_call.count == 1u &&
        final_second_compose_call.count == 1u &&
        fushi_voice_hook::hunex_lookup::DecodeRel32CallTarget(
            surface_compose_span + final_first_compose_call.offset +
                fushi_voice_hook::hunex_lookup::
                    kSurfaceComposeFinalFirstCallOffset,
            &final_first_target, &surface_compose_final_first_return) &&
        fushi_voice_hook::hunex_lookup::DecodeRel32CallTarget(
            surface_compose_span + final_second_compose_call.offset +
                fushi_voice_hook::hunex_lookup::
                    kSurfaceComposeFinalSecondCallOffset,
            &final_second_target, &surface_compose_final_second_return) &&
        final_first_target == surface_compositor_target &&
        final_second_target == surface_compositor_target;
    surface_compose_inner_graph_valid =
        calls_decoded &&
        HunexGgeImageContains(
            module_address, image_size, surface_compositor_target,
            sizeof(fushi_voice_hook::hunex_lookup::
                       kSurfaceCompositorEntryBytes)) &&
        fushi_voice_hook::hunex_lookup::MatchesMaskedPattern(
            reinterpret_cast<const uint8_t*>(surface_compositor_target),
            fushi_voice_hook::hunex_lookup::
                kSurfaceCompositorEntryPattern) &&
        fushi_voice_hook::hunex_lookup::FindRel32CallReturnsToTarget(
            surface_compose_span, surface_compose_bytes,
            surface_compositor_target, &raw_first_return,
            &raw_second_return) == 4u &&
        raw_first_return == surface_compose_first_return &&
        raw_second_return == surface_compose_second_return;
  }
  const uint8_t* surface_compose_wrapper_span = nullptr;
  size_t surface_compose_wrapper_bytes = 0u;
  uintptr_t surface_compose_zero_first_return = 0u;
  uintptr_t surface_compose_zero_second_return = 0u;
  bool surface_compose_wrapper_graph_valid = false;
  if (surface_compose_inner_graph_valid &&
      surface_compose_wrapper_count == 1u &&
      surface_compose_wrapper != nullptr &&
      GetHunexGgeFunctionSpan(
          surface_compose_wrapper, module_address,
          fushi_voice_hook::hunex_lookup::kSurfaceComposeWrapperScanBytes,
          &surface_compose_wrapper_span, &surface_compose_wrapper_bytes)) {
    const auto inner_call =
        fushi_voice_hook::hunex_lookup::FindUniqueMaskedPattern(
            surface_compose_wrapper_span, surface_compose_wrapper_bytes,
            fushi_voice_hook::hunex_lookup::
                kSurfaceComposeWrapperInnerCallPattern);
    const auto zero_first_call =
        fushi_voice_hook::hunex_lookup::FindUniqueMaskedPattern(
            surface_compose_wrapper_span, surface_compose_wrapper_bytes,
            fushi_voice_hook::hunex_lookup::
                kSurfaceComposeWrapperZeroFirstCallPattern);
    const auto zero_second_call =
        fushi_voice_hook::hunex_lookup::FindUniqueMaskedPattern(
            surface_compose_wrapper_span, surface_compose_wrapper_bytes,
            fushi_voice_hook::hunex_lookup::
                kSurfaceComposeWrapperZeroSecondCallPattern);
    uintptr_t wrapper_inner_target = 0u;
    uintptr_t wrapper_inner_return = 0u;
    uintptr_t zero_first_target = 0u;
    uintptr_t zero_second_target = 0u;
    uintptr_t raw_inner_return = 0u;
    uintptr_t raw_zero_first_return = 0u;
    uintptr_t raw_zero_second_return = 0u;
    const bool wrapper_calls_decoded =
        inner_call.count == 1u && zero_first_call.count == 1u &&
        zero_second_call.count == 1u &&
        inner_call.offset < zero_first_call.offset &&
        zero_second_call.offset == zero_first_call.offset + 0x39u &&
        fushi_voice_hook::hunex_lookup::DecodeRel32CallTarget(
            surface_compose_wrapper_span + inner_call.offset +
                fushi_voice_hook::hunex_lookup::
                    kSurfaceComposeWrapperInnerCallOffset,
            &wrapper_inner_target, &wrapper_inner_return) &&
        fushi_voice_hook::hunex_lookup::DecodeRel32CallTarget(
            surface_compose_wrapper_span + zero_first_call.offset +
                fushi_voice_hook::hunex_lookup::
                    kSurfaceComposeWrapperZeroCallOffset,
            &zero_first_target, &surface_compose_zero_first_return) &&
        fushi_voice_hook::hunex_lookup::DecodeRel32CallTarget(
            surface_compose_wrapper_span + zero_second_call.offset +
                fushi_voice_hook::hunex_lookup::
                    kSurfaceComposeWrapperZeroCallOffset,
            &zero_second_target, &surface_compose_zero_second_return) &&
        wrapper_inner_target == reinterpret_cast<uintptr_t>(surface_compose) &&
        zero_first_target == surface_compositor_target &&
        zero_second_target == surface_compositor_target;
    surface_compose_wrapper_graph_valid =
        wrapper_calls_decoded &&
        fushi_voice_hook::hunex_lookup::FindRel32CallReturnsToTarget(
            surface_compose_wrapper_span, surface_compose_wrapper_bytes,
            reinterpret_cast<uintptr_t>(surface_compose), &raw_inner_return,
            nullptr) == 1u &&
        raw_inner_return == wrapper_inner_return &&
        fushi_voice_hook::hunex_lookup::FindRel32CallReturnsToTarget(
            surface_compose_wrapper_span, surface_compose_wrapper_bytes,
            surface_compositor_target, &raw_zero_first_return,
            &raw_zero_second_return) == 2u &&
        raw_zero_first_return == surface_compose_zero_first_return &&
        raw_zero_second_return == surface_compose_zero_second_return;
  }
  const bool surface_compose_graph_valid =
      surface_compose_inner_graph_valid &&
      surface_compose_wrapper_graph_valid;
  if (surface_compose_graph_valid) {
    trace->scanner_status |=
        fushi_voice_hook::kHunexGgeTraceScannerSurfaceComposeCallsValid;
  }

  bool projection_graph_valid = false;
  if (projection_entries_unique) {
    const uint8_t* upload_span = nullptr;
    const uint8_t* quad_span = nullptr;
    const uint8_t* sprite_span = nullptr;
    size_t upload_bytes = 0u;
    size_t quad_bytes = 0u;
    size_t sprite_bytes = 0u;
    projection_graph_valid =
        GetHunexGgeFunctionSpan(
            texture_upload, module_address,
            fushi_voice_hook::hunex_lookup::kTextureUploadScanBytes,
            &upload_span, &upload_bytes) &&
        GetHunexGgeFunctionSpan(
            quad_vertex, module_address,
            fushi_voice_hook::hunex_lookup::kQuadVertexScanBytes,
            &quad_span, &quad_bytes) &&
        GetHunexGgeFunctionSpan(
            sprite_draw, module_address,
            fushi_voice_hook::hunex_lookup::kSpriteDrawScanBytes,
            &sprite_span, &sprite_bytes) &&
        fushi_voice_hook::hunex_lookup::FindUniqueMaskedPattern(
            upload_span, upload_bytes,
            fushi_voice_hook::hunex_lookup::kTextureUploadCommitPattern)
                .count == 1u &&
        fushi_voice_hook::hunex_lookup::FindUniqueMaskedPattern(
            quad_span, quad_bytes,
            fushi_voice_hook::hunex_lookup::kQuadVertexBodyPattern)
                .count == 1u &&
        fushi_voice_hook::hunex_lookup::FindUniqueMaskedPattern(
            sprite_span, sprite_bytes,
            fushi_voice_hook::hunex_lookup::kSpriteDrawBodyPattern)
                .count == 1u;
  }
  if (projection_graph_valid) {
    trace->scanner_status |=
        fushi_voice_hook::kHunexGgeTraceScannerProjectionGraphValid;
  }

  const auto generic =
      fushi_voice_hook::hunex_lookup::FindUniqueMaskedPattern(
          poller_span, poller_bytes,
          fushi_voice_hook::hunex_lookup::kGenericKeyPollPattern);
  const auto pump_to_poller =
      fushi_voice_hook::hunex_lookup::FindUniqueMaskedPattern(
          pump_span, pump_bytes,
          fushi_voice_hook::hunex_lookup::kPumpCallsPollerPattern);
  const auto semantic_submit_call =
      fushi_voice_hook::hunex_lookup::FindUniqueMaskedPattern(
          pump_span, pump_bytes,
          fushi_voice_hook::hunex_lookup::
              kPumpSemanticSubmitCallPattern);
  const auto poller_held_mask_store =
      fushi_voice_hook::hunex_lookup::FindUniqueMaskedPattern(
          poller_held_mask_span, poller_held_mask_bytes,
          fushi_voice_hook::hunex_lookup::
              kKeyPollerStoresHeldMaskPattern);
  const auto pump_held_mask_load =
      fushi_voice_hook::hunex_lookup::FindUniqueMaskedPattern(
          pump_span, pump_bytes,
          fushi_voice_hook::hunex_lookup::kPumpLoadsHeldMaskPattern);
  const auto cursor_pair =
      fushi_voice_hook::hunex_lookup::FindUniqueMaskedPattern(
          pump_span, pump_bytes,
          fushi_voice_hook::hunex_lookup::kCursorPairPattern);
  const auto cursor_scale_x =
      fushi_voice_hook::hunex_lookup::FindUniqueMaskedPattern(
          pump_span, pump_bytes,
          fushi_voice_hook::hunex_lookup::kCursorViewportScaleXPattern);
  const auto cursor_scale_y =
      fushi_voice_hook::hunex_lookup::FindUniqueMaskedPattern(
          pump_span, pump_bytes,
          fushi_voice_hook::hunex_lookup::kCursorScaleYPattern);
  const auto left_button =
      fushi_voice_hook::hunex_lookup::FindUniqueMaskedPattern(
          pump_span, pump_bytes,
          fushi_voice_hook::hunex_lookup::kLeftButtonPollPattern);
  uintptr_t pump_target = 0u;
  uintptr_t pump_return = 0u;
  uintptr_t ignored_return = 0u;
  const uint32_t raw_poller_calls =
      fushi_voice_hook::hunex_lookup::FindRel32CallReturnsToTarget(
          pump_span, pump_bytes, reinterpret_cast<uintptr_t>(key_poller),
          &pump_return, &ignored_return);
  uintptr_t generic_slot = 0u;
  uintptr_t left_button_slot = 0u;
  uintptr_t cursor_position_slot = 0u;
  uintptr_t screen_to_client_slot = 0u;
  uintptr_t generic_return = 0u;
  uintptr_t left_button_return = 0u;
  uintptr_t viewport_rect = 0u;
  uintptr_t scale_x = 0u;
  uintptr_t scale_y = 0u;
  uintptr_t semantic_submit_target = 0u;
  uintptr_t semantic_submit_return = 0u;
  uintptr_t raw_semantic_submit_return = 0u;
  uintptr_t held_mask_from_poller = 0u;
  uintptr_t held_mask_from_pump = 0u;
  const uint32_t raw_semantic_submit_calls =
      fushi_voice_hook::hunex_lookup::FindRel32CallReturnsToTarget(
          pump_span, pump_bytes,
          reinterpret_cast<uintptr_t>(semantic_submit),
          &raw_semantic_submit_return, nullptr);
  const bool semantic_input_graph_valid =
      semantic_submit_call.count == 1u &&
      poller_held_mask_store.count == 1u &&
      pump_held_mask_load.count == 1u && left_button.count == 1u &&
      semantic_submit_call.offset < left_button.offset &&
      fushi_voice_hook::hunex_lookup::DecodeRel32CallTarget(
          pump_span + semantic_submit_call.offset +
              fushi_voice_hook::hunex_lookup::
                  kPumpSemanticSubmitCallOffset,
          &semantic_submit_target, &semantic_submit_return) &&
      semantic_submit_target ==
          reinterpret_cast<uintptr_t>(semantic_submit) &&
      raw_semantic_submit_calls == 1u &&
      raw_semantic_submit_return == semantic_submit_return &&
      fushi_voice_hook::hunex_lookup::DecodeRipRelativeAddress(
          poller_held_mask_span + poller_held_mask_store.offset +
              fushi_voice_hook::hunex_lookup::
                  kKeyPollerHeldMaskStoreInstructionOffset,
          fushi_voice_hook::hunex_lookup::kHeldMaskDisplacementOffset,
          fushi_voice_hook::hunex_lookup::kHeldMaskInstructionBytes,
          &held_mask_from_poller) &&
      fushi_voice_hook::hunex_lookup::DecodeRipRelativeAddress(
          pump_span + pump_held_mask_load.offset +
              fushi_voice_hook::hunex_lookup::
                  kPumpHeldMaskLoadInstructionOffset,
          fushi_voice_hook::hunex_lookup::kHeldMaskDisplacementOffset,
          fushi_voice_hook::hunex_lookup::kHeldMaskInstructionBytes,
          &held_mask_from_pump) &&
      held_mask_from_poller == held_mask_from_pump &&
      HunexGgeImageContains(module_address, image_size,
                            held_mask_from_poller, sizeof(uint64_t));
  const bool input_shapes_valid =
      generic.count == 1u && pump_to_poller.count == 1u &&
      cursor_pair.count == 1u && left_button.count == 1u &&
      semantic_input_graph_valid &&
      fushi_voice_hook::hunex_lookup::DecodeRel32CallTarget(
          pump_span + pump_to_poller.offset +
              fushi_voice_hook::hunex_lookup::kPumpCallsPollerCallOffset,
          &pump_target, nullptr) &&
      pump_target == reinterpret_cast<uintptr_t>(key_poller) &&
      raw_poller_calls == 1u && pump_return != 0u &&
      fushi_voice_hook::hunex_lookup::DecodeRipIndirectCallSlot(
          poller_span + generic.offset +
              fushi_voice_hook::hunex_lookup::kGenericKeyPollCallOffset,
          &generic_slot, &generic_return) &&
      fushi_voice_hook::hunex_lookup::DecodeRipIndirectCallSlot(
          pump_span + left_button.offset +
              fushi_voice_hook::hunex_lookup::kLeftButtonPollCallOffset,
          &left_button_slot, &left_button_return) &&
      fushi_voice_hook::hunex_lookup::DecodeRipIndirectCallSlot(
          pump_span + cursor_pair.offset +
              fushi_voice_hook::hunex_lookup::kCursorGetPositionCallOffset,
          &cursor_position_slot, nullptr) &&
      fushi_voice_hook::hunex_lookup::DecodeRipIndirectCallSlot(
          pump_span + cursor_pair.offset +
              fushi_voice_hook::hunex_lookup::kCursorScreenToClientCallOffset,
          &screen_to_client_slot, nullptr) &&
      generic_slot == left_button_slot;
  const bool cursor_transform_valid =
      cursor_scale_x.count == 1u && cursor_scale_y.count == 1u &&
      cursor_scale_y.offset ==
          cursor_scale_x.offset +
              fushi_voice_hook::hunex_lookup::kCursorScaleYRelativeOffset &&
      fushi_voice_hook::hunex_lookup::DecodeRipRelativeAddress(
          pump_span + cursor_scale_x.offset,
          fushi_voice_hook::hunex_lookup::
              kCursorViewportDisplacementOffset,
          fushi_voice_hook::hunex_lookup::kCursorViewportInstructionBytes,
          &viewport_rect) &&
      fushi_voice_hook::hunex_lookup::DecodeRipRelativeAddress(
          pump_span + cursor_scale_x.offset +
              fushi_voice_hook::hunex_lookup::
                  kCursorScaleXInstructionOffset,
          fushi_voice_hook::hunex_lookup::kCursorScaleXDisplacementOffset,
          fushi_voice_hook::hunex_lookup::kCursorScaleInstructionBytes,
          &scale_x) &&
      fushi_voice_hook::hunex_lookup::DecodeRipRelativeAddress(
          pump_span + cursor_scale_y.offset +
              fushi_voice_hook::hunex_lookup::
                  kCursorScaleYInstructionOffset,
          fushi_voice_hook::hunex_lookup::kCursorScaleYDisplacementOffset,
          fushi_voice_hook::hunex_lookup::kCursorScaleInstructionBytes,
          &scale_y) &&
      scale_y == scale_x + sizeof(float) &&
      HunexGgeImageContains(module_address, image_size, viewport_rect,
                            sizeof(RECT)) &&
      HunexGgeImageContains(module_address, image_size, scale_x,
                            sizeof(float)) &&
      HunexGgeImageContains(module_address, image_size, scale_y,
                            sizeof(float));
  trace->cursor_scale_x_match_count = cursor_scale_x.count;
  trace->cursor_scale_y_match_count = cursor_scale_y.count;

  uintptr_t imported_async_key_state = 0u;
  uintptr_t imported_cursor_position = 0u;
  uintptr_t imported_screen_to_client = 0u;
  __try {
    if (input_shapes_valid) {
      imported_async_key_state = reinterpret_cast<uintptr_t>(
          *reinterpret_cast<void**>(generic_slot));
      imported_cursor_position = reinterpret_cast<uintptr_t>(
          *reinterpret_cast<void**>(cursor_position_slot));
      imported_screen_to_client = reinterpret_cast<uintptr_t>(
          *reinterpret_cast<void**>(screen_to_client_slot));
    }
  } __except (EXCEPTION_EXECUTE_HANDLER) {
    imported_async_key_state = 0u;
    imported_cursor_position = 0u;
    imported_screen_to_client = 0u;
  }
  HMODULE user32 = GetModuleHandleW(L"user32.dll");
  const uintptr_t exported_async_key_state = reinterpret_cast<uintptr_t>(
      user32 == nullptr ? nullptr
                        : GetProcAddress(user32, "GetAsyncKeyState"));
  const uintptr_t exported_cursor_position = reinterpret_cast<uintptr_t>(
      user32 == nullptr ? nullptr : GetProcAddress(user32, "GetCursorPos"));
  const uintptr_t exported_screen_to_client = reinterpret_cast<uintptr_t>(
      user32 == nullptr ? nullptr
                        : GetProcAddress(user32, "ScreenToClient"));
  if (!draw_graph_valid || !render_item_graph_valid ||
      !body_submit_graph_valid || !input_shapes_valid ||
      !cursor_transform_valid ||
      imported_async_key_state == 0u ||
      imported_async_key_state != exported_async_key_state ||
      imported_cursor_position != exported_cursor_position ||
      imported_screen_to_client != exported_screen_to_client) {
    InterlockedExchange(&g_hunex_gge_trace_scan_state, -1);
    return false;
  }

  trace->scanner_status |=
      fushi_voice_hook::kHunexGgeTraceScannerDrawCallsValid |
      fushi_voice_hook::kHunexGgeTraceScannerInputCallsValid |
      fushi_voice_hook::kHunexGgeTraceScannerRenderItemCallValid |
      fushi_voice_hook::kHunexGgeTraceScannerCursorTransformValid |
      fushi_voice_hook::kHunexGgeTraceScannerBodySubmitValid;
  g_hunex_gge_anchors.module = module_address;
  g_hunex_gge_anchors.image_size = image_size;
  g_hunex_gge_anchors.draw = reinterpret_cast<uintptr_t>(draw);
  g_hunex_gge_anchors.glyph = reinterpret_cast<uintptr_t>(glyph);
  g_hunex_gge_anchors.render_item = render_item_target;
  g_hunex_gge_anchors.body_submit =
      reinterpret_cast<uintptr_t>(body_submit);
  if (surface_compose_graph_valid) {
    g_hunex_gge_anchors.surface_compose_wrapper =
        reinterpret_cast<uintptr_t>(surface_compose_wrapper);
    g_hunex_gge_anchors.surface_compose =
        reinterpret_cast<uintptr_t>(surface_compose);
    g_hunex_gge_anchors.surface_compositor = surface_compositor_target;
    g_hunex_gge_anchors.surface_compose_zero_first_return =
        surface_compose_zero_first_return;
    g_hunex_gge_anchors.surface_compose_zero_second_return =
        surface_compose_zero_second_return;
    g_hunex_gge_anchors.surface_compose_first_return =
        surface_compose_first_return;
    g_hunex_gge_anchors.surface_compose_second_return =
        surface_compose_second_return;
    g_hunex_gge_anchors.surface_compose_final_first_return =
        surface_compose_final_first_return;
    g_hunex_gge_anchors.surface_compose_final_second_return =
        surface_compose_final_second_return;
  }
  if (projection_graph_valid) {
    g_hunex_gge_anchors.texture_upload =
        reinterpret_cast<uintptr_t>(texture_upload);
    g_hunex_gge_anchors.quad_vertex =
        reinterpret_cast<uintptr_t>(quad_vertex);
    g_hunex_gge_anchors.sprite_draw =
        reinterpret_cast<uintptr_t>(sprite_draw);
  }
  g_hunex_gge_anchors.key_poller = reinterpret_cast<uintptr_t>(key_poller);
  g_hunex_gge_anchors.input_pump = reinterpret_cast<uintptr_t>(input_pump);
  g_hunex_gge_anchors.semantic_submit =
      reinterpret_cast<uintptr_t>(semantic_submit);
  g_hunex_gge_anchors.held_action_mask = held_mask_from_poller;
  g_hunex_gge_anchors.direct_first_glyph_return = first_glyph_return;
  g_hunex_gge_anchors.direct_second_glyph_return = second_glyph_return;
  g_hunex_gge_anchors.render_item_return = render_item_return;
  g_hunex_gge_anchors.body_submit_return = body_submit_return;
  g_hunex_gge_anchors.viewport_rect = viewport_rect;
  g_hunex_gge_anchors.scale_x = scale_x;
  g_hunex_gge_anchors.scale_y = scale_y;
  g_hunex_gge_anchors.generic_key_return = generic_return;
  g_hunex_gge_anchors.left_button_return = left_button_return;
  g_hunex_gge_anchors.async_key_state = imported_async_key_state;
  trace->draw_rva = HunexGgeRva(g_hunex_gge_anchors.draw);
  trace->glyph_rva = HunexGgeRva(g_hunex_gge_anchors.glyph);
  trace->render_item_rva = HunexGgeRva(g_hunex_gge_anchors.render_item);
  trace->body_submit_rva = HunexGgeRva(g_hunex_gge_anchors.body_submit);
  trace->key_poller_rva = HunexGgeRva(g_hunex_gge_anchors.key_poller);
  trace->input_pump_rva = HunexGgeRva(g_hunex_gge_anchors.input_pump);
  trace->viewport_rect_rva = HunexGgeRva(viewport_rect);
  trace->scale_x_rva = HunexGgeRva(scale_x);
  trace->scale_y_rva = HunexGgeRva(scale_y);
  trace->generic_return_rva = HunexGgeRva(generic_return);
  trace->left_button_return_rva = HunexGgeRva(left_button_return);
  trace->direct_first_glyph_return_rva = HunexGgeRva(first_glyph_return);
  trace->direct_second_glyph_return_rva = HunexGgeRva(second_glyph_return);
  trace->render_item_return_rva = HunexGgeRva(render_item_return);
  trace->body_submit_return_rva = HunexGgeRva(body_submit_return);
  InterlockedExchange(&g_hunex_gge_trace_scan_state, 1);
  return true;
}

struct HunexGgeHookSpec {
  void* target = nullptr;
  void* detour = nullptr;
  void** original = nullptr;
};

bool InstallHunexGgeHookGroup(HunexGgeHookSpec* hooks, size_t hook_count) {
  if (hooks == nullptr || hook_count == 0u || !g_cs_ready) return false;
  bool installed = false;
  EnterCriticalSection(&g_cs);
  size_t created_count = 0u;
  size_t enabled_count = 0u;
  bool preflight_valid =
      g_hooked_count >= 0 && g_hooked_count <= 64 &&
      hook_count <= static_cast<size_t>(64 - g_hooked_count);
  for (size_t index = 0u; preflight_valid && index < hook_count; ++index) {
    const auto& hook = hooks[index];
    preflight_valid = hook.target != nullptr && hook.detour != nullptr &&
                      hook.original != nullptr && *hook.original == nullptr;
    for (size_t other = 0u; preflight_valid && other < index; ++other) {
      if (hooks[other].target == hook.target) preflight_valid = false;
    }
    for (int tracked = 0; preflight_valid && tracked < g_hooked_count;
         ++tracked) {
      // The global target-only registry cannot prove detour ownership or
      // recover the matching trampoline. Refuse the entire group rather than
      // treating an unrelated tracked target as this adapter's original.
      if (g_hooked_fns[tracked] == hook.target) preflight_valid = false;
    }
  }
  if (preflight_valid) {
    while (created_count < hook_count) {
      auto& hook = hooks[created_count];
      const MH_STATUS created =
          MH_CreateHook(hook.target, hook.detour, hook.original);
      if (created != MH_OK || *hook.original == nullptr) {
        // Even a nominally successful create is unusable without a proven
        // trampoline. Remove it immediately because created_count deliberately
        // covers only complete entries.
        if (created == MH_OK) {
          (void)MH_RemoveHook(hook.target);
        }
        *hook.original = nullptr;
        break;
      }
      ++created_count;
    }
    if (created_count == hook_count) {
      for (; enabled_count < hook_count; ++enabled_count) {
        if (MH_EnableHook(hooks[enabled_count].target) != MH_OK) break;
      }
      if (enabled_count == hook_count) {
        for (size_t index = 0u; index < hook_count; ++index) {
          g_hooked_fns[g_hooked_count++] = hooks[index].target;
        }
        installed = true;
      }
    }
  }
  if (!installed) {
    // Disable every hook we created, including the target whose enable may
    // have returned an unexpected already-enabled status, before removing any
    // trampoline. This keeps a failed required group strictly all-or-nothing.
    for (size_t index = 0u; index < created_count; ++index) {
      (void)MH_DisableHook(hooks[index].target);
    }
    while (created_count > 0u) {
      --created_count;
      (void)MH_RemoveHook(hooks[created_count].target);
      if (hooks[created_count].original != nullptr) {
        *hooks[created_count].original = nullptr;
      }
    }
  }
  LeaveCriticalSection(&g_cs);
  return installed;
}

bool TryHookHunexGgeRuntimeTrace() {
  if (!IsHunexGgeProfileMatched() || !ScanHunexGgeRuntimeAnchors()) {
    return false;
  }
  if (InterlockedCompareExchange(&g_hunex_gge_trace_hooks_ready, 0, 0) != 0) {
    return true;
  }
  // Geometry and input ownership are one contract. Create every hook first,
  // enable only after all trampolines exist, and roll the complete group back
  // on any failure. This also rejects a target owned by the legacy global
  // target-only registry, whose detour/trampoline identity cannot be proven.
  if (g_hunex_gge_anchors.surface_compose_wrapper == 0u ||
      g_hunex_gge_anchors.surface_compose == 0u ||
      g_hunex_gge_anchors.surface_compositor == 0u ||
      g_hunex_gge_anchors.texture_upload == 0u ||
      g_hunex_gge_anchors.quad_vertex == 0u ||
      g_hunex_gge_anchors.sprite_draw == 0u) {
    return false;
  }
  HunexGgeHookSpec hooks[] = {
      {reinterpret_cast<void*>(g_hunex_gge_anchors.semantic_submit),
       reinterpret_cast<void*>(&Detour_HunexGgeSemanticSubmit),
       reinterpret_cast<void**>(&g_orig_hunex_gge_semantic_submit)},
      {reinterpret_cast<void*>(g_hunex_gge_anchors.async_key_state),
       reinterpret_cast<void*>(&Detour_HunexGgeGetAsyncKeyState),
       reinterpret_cast<void**>(&g_orig_hunex_gge_get_async_key_state)},
      {reinterpret_cast<void*>(g_hunex_gge_anchors.glyph),
       reinterpret_cast<void*>(&Detour_HunexGgeGlyph),
       reinterpret_cast<void**>(&g_orig_hunex_gge_glyph)},
      {reinterpret_cast<void*>(g_hunex_gge_anchors.render_item),
       reinterpret_cast<void*>(&Detour_HunexGgeRenderItem),
       reinterpret_cast<void**>(&g_orig_hunex_gge_render_item)},
      {reinterpret_cast<void*>(g_hunex_gge_anchors.draw),
       reinterpret_cast<void*>(&Detour_HunexGgeDrawText),
       reinterpret_cast<void**>(&g_orig_hunex_gge_draw_text)},
      {reinterpret_cast<void*>(g_hunex_gge_anchors.surface_compositor),
       reinterpret_cast<void*>(&Detour_HunexGgeSurfaceCompositor),
       reinterpret_cast<void**>(&g_orig_hunex_gge_surface_compositor)},
      {reinterpret_cast<void*>(g_hunex_gge_anchors.surface_compose_wrapper),
       reinterpret_cast<void*>(&Detour_HunexGgeSurfaceComposeWrapper),
       reinterpret_cast<void**>(
           &g_orig_hunex_gge_surface_compose_wrapper)},
      {reinterpret_cast<void*>(g_hunex_gge_anchors.surface_compose),
       reinterpret_cast<void*>(&Detour_HunexGgeSurfaceCompose),
       reinterpret_cast<void**>(&g_orig_hunex_gge_surface_compose)},
      {reinterpret_cast<void*>(g_hunex_gge_anchors.sprite_draw),
       reinterpret_cast<void*>(&Detour_HunexGgeSpriteDraw),
       reinterpret_cast<void**>(&g_orig_hunex_gge_sprite_draw)},
      {reinterpret_cast<void*>(g_hunex_gge_anchors.quad_vertex),
       reinterpret_cast<void*>(&Detour_HunexGgeQuadVertex),
       reinterpret_cast<void**>(&g_orig_hunex_gge_quad_vertex)},
      {reinterpret_cast<void*>(g_hunex_gge_anchors.texture_upload),
       reinterpret_cast<void*>(&Detour_HunexGgeTextureUpload),
       reinterpret_cast<void**>(&g_orig_hunex_gge_texture_upload)},
  };
  if (!InstallHunexGgeHookGroup(hooks, _countof(hooks))) {
    return false;
  }
  FushiHunexGgeTraceV3.scanner_status |=
      fushi_voice_hook::kHunexGgeTraceScannerSurfaceComposeHooksReady |
      fushi_voice_hook::kHunexGgeTraceScannerProjectionHooksReady;
  FushiHunexGgeTraceV3.scanner_status |=
      fushi_voice_hook::kHunexGgeTraceScannerHooksReady;
  InterlockedExchange(&g_hunex_gge_trace_hooks_ready, 1);
  return true;
}

#else

bool TryHookHunexGgeRuntimeTrace() { return false; }

#endif  // _M_X64

constexpr size_t kHunexVoicePathChars = 32768u;
constexpr int kHunexVoiceHandleSlots = 16;
constexpr int kHunexVoiceTaskSlots = 32;

struct HunexVoiceFileIdentity {
  DWORD volume_serial = 0;
  DWORD file_index_high = 0;
  DWORD file_index_low = 0;
  uint64_t file_bytes = 0;
  uint64_t last_write = 0;
};

struct HunexVoiceRange {
  uint64_t offset = 0;
  uint32_t size = 0;
  uint32_t id = 0;
};

struct HunexVoiceArchive {
  wchar_t path[kHunexVoicePathChars] = {};
  HunexVoiceFileIdentity identity;
  HunexVoiceRange* ranges = nullptr;
  uint32_t range_count = 0;
};

// 无锁句柄表（tracked_handle_table.h）：Forget 走 CloseHandle detour，不得进 g_cs（BUG-2046）。
struct HunexVoiceHandle {
  HANDLE handle = INVALID_HANDLE_VALUE;
  volatile LONG seq = 0;
  uint32_t archive_index = 0;
};

// The shared file callback may only copy these fixed scalars. HFA index/range access,
// source-file reopening, complete HW/Ogg validation and disk publication all
// remain on HookWorker in ProcessHunexVoiceTask.
struct HunexVoiceTask {
  volatile LONG state = 0;  // 0=free, 1=producing, 2=pending, 3=consuming
  uint64_t tick_ms = 0;
  uint64_t offset = 0;
  uint32_t read_bytes = 0;
  uint32_t archive_index = 0;
  uint32_t generation = 0;
  uint8_t prefix[4] = {};
};

struct HunexVoiceArchiveStamp {
  bool present = false;
  uint64_t bytes = 0;
  uint64_t written = 0;

  bool operator==(const HunexVoiceArchiveStamp& other) const {
    return present == other.present && bytes == other.bytes &&
           written == other.written;
  }
};

HunexVoiceArchive g_hunex_voice_archive;
HunexVoiceHandle g_hunex_voice_handles[kHunexVoiceHandleSlots];
HunexVoiceTask g_hunex_voice_tasks[kHunexVoiceTaskSlots];
volatile LONG g_hunex_voice_archive_count = 0;
volatile LONG g_hunex_voice_enabled = 0;
volatile LONG g_hunex_voice_generation = 1;
HunexVoiceArchiveStamp g_hunex_voice_load_stamp;
bool g_hunex_voice_load_attempted = false;
uint32_t g_hunex_voice_last_range = UINT32_MAX;
uint64_t g_hunex_voice_last_tick = 0;

bool ReadHunexVoiceFileIdentity(HANDLE file, HunexVoiceFileIdentity* out) {
  if (file == INVALID_HANDLE_VALUE || out == nullptr) return false;
  BY_HANDLE_FILE_INFORMATION info = {};
  if (!GetFileInformationByHandle(file, &info)) return false;
  out->volume_serial = info.dwVolumeSerialNumber;
  out->file_index_high = info.nFileIndexHigh;
  out->file_index_low = info.nFileIndexLow;
  out->file_bytes = (static_cast<uint64_t>(info.nFileSizeHigh) << 32u) |
                    static_cast<uint64_t>(info.nFileSizeLow);
  out->last_write =
      (static_cast<uint64_t>(info.ftLastWriteTime.dwHighDateTime) << 32u) |
      static_cast<uint64_t>(info.ftLastWriteTime.dwLowDateTime);
  return out->file_bytes != 0u;
}

bool SameHunexVoiceFileIdentity(const HunexVoiceFileIdentity& left,
                                const HunexVoiceFileIdentity& right) {
  return left.volume_serial == right.volume_serial &&
         left.file_index_high == right.file_index_high &&
         left.file_index_low == right.file_index_low &&
         left.file_bytes == right.file_bytes &&
         left.last_write == right.last_write;
}

bool IsHunexHwName(const char* name) {
  if (name == nullptr) return false;
  const size_t chars = strlen(name);
  return chars >= 3u && name[chars - 3u] == '.' &&
         (name[chars - 2u] == 'h' || name[chars - 2u] == 'H') &&
         (name[chars - 1u] == 'w' || name[chars - 1u] == 'W');
}

bool IsHunexGgeProfileMatched() {
  wchar_t executable[kHunexVoicePathChars] = {};
  const DWORD chars = GetModuleFileNameW(
      nullptr, executable, static_cast<DWORD>(std::size(executable)));
  return chars > 0u && chars < std::size(executable) &&
         fushi_voice_hook::MatchesHunexGgeTitleProfile(executable);
}

bool BuildHunexVoiceArchivePath(wchar_t* out, size_t out_chars) {
  if (out == nullptr || out_chars == 0u) return false;
  const DWORD chars = GetModuleFileNameW(
      nullptr, out, static_cast<DWORD>(out_chars));
  if (chars == 0u || chars >= out_chars) return false;
  wchar_t* slash = wcsrchr(out, L'\\');
  if (slash == nullptr) return false;
  slash[1] = 0;
  return wcscat_s(out, out_chars,
                  fushi_voice_hook::kHunexGgeMahoyoVoiceArchiveName) == 0;
}

void StampHunexVoiceArchivePath(const wchar_t* path,
                                HunexVoiceArchiveStamp* out) {
  if (out == nullptr) return;
  *out = {};
  WIN32_FILE_ATTRIBUTE_DATA data = {};
  if (path == nullptr ||
      !GetFileAttributesExW(path, GetFileExInfoStandard, &data) ||
      (data.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) != 0u) {
    return;
  }
  out->present = true;
  out->bytes = (static_cast<uint64_t>(data.nFileSizeHigh) << 32u) |
               static_cast<uint64_t>(data.nFileSizeLow);
  out->written =
      (static_cast<uint64_t>(data.ftLastWriteTime.dwHighDateTime) << 32u) |
      static_cast<uint64_t>(data.ftLastWriteTime.dwLowDateTime);
}

bool ReadHunexVoiceMember(HANDLE file, const HunexVoiceRange& range,
                          uint8_t** member) {
  if (file == INVALID_HANDLE_VALUE || member == nullptr || range.size == 0u ||
      range.size > fushi_voice_hook::hunex::kMaxHunexHwBytes) {
    return false;
  }
  *member = static_cast<uint8_t*>(malloc(range.size));
  if (*member == nullptr) return false;
  LARGE_INTEGER at = {};
  at.QuadPart = range.offset;
  if (!SetFilePointerEx(file, at, nullptr, FILE_BEGIN) ||
      !ReadExact(file, *member, range.size)) {
    free(*member);
    *member = nullptr;
    return false;
  }
  return true;
}

bool LoadHunexVoiceArchive(const wchar_t* path, HunexVoiceArchive* out) {
  if (path == nullptr || out == nullptr ||
      !fushi_voice_hook::IsHunexGgeVoiceArchivePath(path) ||
      g_orig_CreateFileW == nullptr || g_orig_ReadFile == nullptr ||
      g_orig_CloseHandle == nullptr) {
    return false;
  }
  HANDLE file = g_orig_CreateFileW(
      path, GENERIC_READ,
      FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, nullptr,
      OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
  if (file == INVALID_HANDLE_VALUE) return false;

  HunexVoiceFileIdentity identity;
  uint8_t header[fushi_voice_hook::hunex::kHunexHfaHeaderBytes] = {};
  uint8_t* index = nullptr;
  HunexVoiceRange* ranges = nullptr;
  uint32_t range_count = 0u;
  fushi_voice_hook::hunex::HunexHfaArchiveInfo info;
  bool valid = ReadHunexVoiceFileIdentity(file, &identity) &&
               ReadExact(file, header, sizeof(header)) &&
               memcmp(header, fushi_voice_hook::hunex::kHunexHfaMagic,
                      sizeof(fushi_voice_hook::hunex::kHunexHfaMagic) - 1u) ==
                   0;
  uint64_t index_bytes = 0u;
  if (valid) {
    const uint32_t count =
        fushi_voice_hook::hunex::ReadHunexLe32(header + 12u);
    index_bytes =
        fushi_voice_hook::hunex::kHunexHfaHeaderBytes +
        static_cast<uint64_t>(count) *
            fushi_voice_hook::hunex::kHunexHfaRecordBytes;
    valid = count > 0u &&
            count <= fushi_voice_hook::hunex::kMaxHunexHfaEntries &&
            index_bytes <= identity.file_bytes && index_bytes <= UINT32_MAX;
  }
  if (valid) {
    index = static_cast<uint8_t*>(malloc(static_cast<size_t>(index_bytes)));
    valid = index != nullptr;
    if (valid) {
      memcpy(index, header, sizeof(header));
      valid = ReadExact(file, index + sizeof(header),
                        static_cast<uint32_t>(index_bytes - sizeof(header))) &&
              fushi_voice_hook::hunex::ParseHunexHfaIndex(
                  index, static_cast<size_t>(index_bytes), identity.file_bytes,
                  &info);
    }
  }
  if (valid) {
    ranges = static_cast<HunexVoiceRange*>(
        malloc(static_cast<size_t>(info.count) * sizeof(HunexVoiceRange)));
    valid = ranges != nullptr;
    for (uint32_t id = 0u; valid && id < info.count; ++id) {
      fushi_voice_hook::hunex::HunexHfaEntry entry;
      valid = fushi_voice_hook::hunex::ReadHunexHfaEntryAtIndex(
          index, static_cast<size_t>(index_bytes), identity.file_bytes, id,
          &entry);
      if (!valid) break;
      if (!IsHunexHwName(entry.name)) continue;
      ranges[range_count++] = {entry.absolute_offset, entry.size, entry.id};
    }
    valid = valid && range_count > 0u;
  }
  if (valid) {
    std::sort(ranges, ranges + range_count,
              [](const HunexVoiceRange& left, const HunexVoiceRange& right) {
                return left.offset < right.offset;
              });
    uint8_t* member = nullptr;
    fushi_voice_hook::hunex::HunexHwOggInfo hw;
    valid = ReadHunexVoiceMember(file, ranges[0], &member) &&
            fushi_voice_hook::hunex::ParseHunexHwOgg(
                member, ranges[0].size, &hw);
    free(member);
  }
  if (valid) {
    wcsncpy_s(out->path, path, _TRUNCATE);
    out->identity = identity;
    out->ranges = ranges;
    out->range_count = range_count;
    ranges = nullptr;
  }
  free(ranges);
  free(index);
  g_orig_CloseHandle(file);
  return valid;
}

bool LoadHunexVoiceArchives() {
  if (InterlockedCompareExchange(&g_hunex_voice_archive_count, 0, 0) > 0) {
    return true;
  }
  if (!IsHunexGgeProfileMatched()) return false;
  wchar_t path[kHunexVoicePathChars] = {};
  if (!BuildHunexVoiceArchivePath(path, std::size(path))) return false;
  HunexVoiceArchiveStamp stamp;
  StampHunexVoiceArchivePath(path, &stamp);
  if (g_hunex_voice_load_attempted && stamp == g_hunex_voice_load_stamp) {
    return false;
  }
  g_hunex_voice_load_attempted = true;
  g_hunex_voice_load_stamp = stamp;
  if (!stamp.present || !LoadHunexVoiceArchive(path, &g_hunex_voice_archive)) {
    return false;
  }
  MemoryBarrier();
  InterlockedExchange(&g_hunex_voice_archive_count, 1);
  return true;
}

int FindHunexVoiceArchive(const HunexVoiceFileIdentity& identity) {
  if (InterlockedCompareExchange(&g_hunex_voice_archive_count, 0, 0) != 1) {
    return -1;
  }
  return SameHunexVoiceFileIdentity(g_hunex_voice_archive.identity, identity)
             ? 0
             : -1;
}

void RememberHunexVoiceHfa(HANDLE handle, const wchar_t* path) {
  if (InterlockedCompareExchange(&g_hunex_voice_enabled, 0, 0) == 0 ||
      handle == INVALID_HANDLE_VALUE ||
      !fushi_voice_hook::IsHunexGgeVoiceArchivePath(path)) {
    return;
  }
  HunexVoiceFileIdentity identity;
  if (!ReadHunexVoiceFileIdentity(handle, &identity)) return;
  const int archive_index = FindHunexVoiceArchive(identity);
  if (archive_index < 0) return;

  if (fushi_voice_hook::RememberTrackedHandle(
          g_hunex_voice_handles, handle,
          [archive_index](HunexVoiceHandle& slot) {
            slot.archive_index = static_cast<uint32_t>(archive_index);
          })) {
    SetXAudioDiagnostic(fushi_voice_hook::kXAudioDiagHunexHfaHandleTracked);
  }
}

bool CopyHunexVoiceArchiveIndex(HANDLE handle, uint32_t* archive_index) {
  if (archive_index == nullptr) return false;
  return fushi_voice_hook::ReadTrackedHandle(
      g_hunex_voice_handles, handle,
      [archive_index](const HunexVoiceHandle& slot) {
        *archive_index = slot.archive_index;
      });
}

void ForgetHunexVoiceHfa(HANDLE handle) {
  fushi_voice_hook::ForgetTrackedHandle(g_hunex_voice_handles, handle);
}

bool QueueHunexVoice(uint32_t archive_index, uint64_t offset,
                     uint32_t read_bytes, const uint8_t prefix[4],
                     uint64_t tick_ms) {
  if (prefix == nullptr) return false;
  const uint32_t generation = static_cast<uint32_t>(
      InterlockedCompareExchange(&g_hunex_voice_generation, 0, 0));
  for (int index = 0; index < kHunexVoiceTaskSlots; ++index) {
    const LONG state =
        InterlockedCompareExchange(&g_hunex_voice_tasks[index].state, 0, 0);
    if (state >= 2 && g_hunex_voice_tasks[index].generation == generation &&
        g_hunex_voice_tasks[index].archive_index == archive_index &&
        g_hunex_voice_tasks[index].offset == offset) {
      return true;
    }
  }
  for (int index = 0; index < kHunexVoiceTaskSlots; ++index) {
    if (InterlockedCompareExchange(&g_hunex_voice_tasks[index].state, 1, 0) !=
        0) {
      continue;
    }
    HunexVoiceTask* task = &g_hunex_voice_tasks[index];
    task->tick_ms = tick_ms;
    task->offset = offset;
    task->read_bytes = read_bytes;
    task->archive_index = archive_index;
    task->generation = generation;
    memcpy(task->prefix, prefix, sizeof(task->prefix));
    MemoryBarrier();
    InterlockedExchange(&task->state, 2);
    return true;
  }
  return false;
}

void ObserveHunexVoiceHfaRead(HANDLE file, const void* buffer, DWORD done,
                              LPOVERLAPPED overlapped) {
  if (InterlockedCompareExchange(&g_hunex_voice_enabled, 0, 0) == 0 ||
      buffer == nullptr || done < 4u || overlapped != nullptr) {
    return;
  }
  uint8_t prefix[4] = {};
  __try {
    memcpy(prefix, buffer, sizeof(prefix));
  } __except (EXCEPTION_EXECUTE_HANDLER) {
    return;
  }
  if (fushi_voice_hook::hunex::ReadHunexLe32(prefix) !=
          fushi_voice_hook::hunex::kHunexHwHeaderBytes &&
      memcmp(prefix, "OggS", 4u) != 0) {
    return;
  }

  uint32_t archive_index = 0u;
  if (!CopyHunexVoiceArchiveIndex(file, &archive_index)) {
    wchar_t path[kHunexVoicePathChars] = {};
    const DWORD chars = GetFinalPathNameByHandleW(
        file, path, static_cast<DWORD>(std::size(path)), FILE_NAME_NORMALIZED);
    if (chars == 0u || chars >= std::size(path) ||
        !fushi_voice_hook::IsHunexGgeVoiceArchivePath(path)) {
      return;
    }
    RememberHunexVoiceHfa(file, path);
    if (!CopyHunexVoiceArchiveIndex(file, &archive_index)) return;
  }
  SetXAudioDiagnostic(fushi_voice_hook::kXAudioDiagHunexHfaReadObserved);

  LARGE_INTEGER zero = {};
  LARGE_INTEGER current = {};
  if (!SetFilePointerEx(file, zero, &current, FILE_CURRENT) ||
      current.QuadPart < done) {
    SetXAudioDiagnostic(fushi_voice_hook::kXAudioDiagHunexHfaTaskRejected);
    return;
  }
  const uint64_t start = static_cast<uint64_t>(current.QuadPart) - done;
  const bool queued = QueueHunexVoice(archive_index, start, done, prefix,
                                      GetTickCount64());
  SetXAudioDiagnostic(queued
                          ? fushi_voice_hook::kXAudioDiagHunexHfaVoiceQueued
                          : fushi_voice_hook::kXAudioDiagHunexHfaTaskRejected);
}

bool FindHunexVoiceRange(const HunexVoiceArchive& archive,
                         const HunexVoiceTask& task, uint32_t* range_index,
                         bool* payload_start) {
  if (archive.ranges == nullptr || range_index == nullptr ||
      payload_start == nullptr || task.read_bytes < 4u) {
    return false;
  }
  uint64_t member_offset = task.offset;
  bool payload = false;
  if (memcmp(task.prefix, "OggS", 4u) == 0) {
    if (task.offset < fushi_voice_hook::hunex::kHunexHwHeaderBytes) {
      return false;
    }
    member_offset -= fushi_voice_hook::hunex::kHunexHwHeaderBytes;
    payload = true;
  } else if (fushi_voice_hook::hunex::ReadHunexLe32(task.prefix) !=
             fushi_voice_hook::hunex::kHunexHwHeaderBytes) {
    return false;
  }

  uint32_t first = 0u;
  uint32_t last = archive.range_count;
  while (first < last) {
    const uint32_t middle = first + (last - first) / 2u;
    if (member_offset < archive.ranges[middle].offset) {
      last = middle;
    } else if (member_offset > archive.ranges[middle].offset) {
      first = middle + 1u;
    } else {
      if (archive.ranges[middle].size <=
          fushi_voice_hook::hunex::kHunexHwHeaderBytes) {
        return false;
      }
      const uint32_t available =
          payload
              ? archive.ranges[middle].size -
                    fushi_voice_hook::hunex::kHunexHwHeaderBytes
              : archive.ranges[middle].size;
      if (task.read_bytes > available) {
        return false;
      }
      *range_index = middle;
      *payload_start = payload;
      return true;
    }
  }
  return false;
}

void ProcessHunexVoiceTask(HunexVoiceTask* task) {
  const uint32_t generation = static_cast<uint32_t>(
      InterlockedCompareExchange(&g_hunex_voice_generation, 0, 0));
  if (task == nullptr || task->generation != generation ||
      task->archive_index != 0u ||
      InterlockedCompareExchange(&g_hunex_voice_archive_count, 0, 0) != 1) {
    SetXAudioDiagnostic(fushi_voice_hook::kXAudioDiagHunexHfaTaskRejected);
    return;
  }
  const HunexVoiceArchive& archive = g_hunex_voice_archive;
  uint32_t range_index = 0u;
  bool payload_start = false;
  if (!FindHunexVoiceRange(archive, *task, &range_index, &payload_start) ||
      range_index >= archive.range_count) {
    SetXAudioDiagnostic(fushi_voice_hook::kXAudioDiagHunexHfaTaskRejected);
    return;
  }
  (void)payload_start;
  if (range_index == g_hunex_voice_last_range &&
      task->tick_ms >= g_hunex_voice_last_tick &&
      task->tick_ms - g_hunex_voice_last_tick <= 2000u) {
    return;
  }

  HANDLE file = g_orig_CreateFileW(
      archive.path, GENERIC_READ,
      FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, nullptr,
      OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
  if (file == INVALID_HANDLE_VALUE) {
    SetXAudioDiagnostic(fushi_voice_hook::kXAudioDiagHunexHfaTaskRejected);
    return;
  }
  const HunexVoiceRange range = archive.ranges[range_index];
  HunexVoiceFileIdentity identity;
  uint8_t* member = nullptr;
  fushi_voice_hook::hunex::HunexHwOggInfo hw;
  bool valid = ReadHunexVoiceFileIdentity(file, &identity) &&
               SameHunexVoiceFileIdentity(identity, archive.identity) &&
               ReadHunexVoiceMember(file, range, &member) &&
               fushi_voice_hook::hunex::ParseHunexHwOgg(member, range.size,
                                                        &hw);
  if (valid) {
    wchar_t storage_name[64] = {};
    swprintf_s(storage_name, L"hunex-%u.ogg", range.id);
    valid = WriteVoiceOggAt(member + hw.payload_offset, hw.payload_bytes,
                            storage_name, task->tick_ms);
  }
  if (valid) {
    g_hunex_voice_last_range = range_index;
    g_hunex_voice_last_tick = task->tick_ms;
    SetXAudioDiagnostic(
        fushi_voice_hook::kXAudioDiagGameResourcePublished);
  } else {
    SetXAudioDiagnostic(fushi_voice_hook::kXAudioDiagHunexHfaTaskRejected);
  }
  free(member);
  g_orig_CloseHandle(file);
}

void ProcessHunexVoiceTasks() {
  for (int index = 0; index < kHunexVoiceTaskSlots; ++index) {
    if (InterlockedCompareExchange(&g_hunex_voice_tasks[index].state, 3, 2) ==
        2) {
      ProcessHunexVoiceTask(&g_hunex_voice_tasks[index]);
      InterlockedExchange(&g_hunex_voice_tasks[index].state, 0);
    }
  }
}

bool TryHookHunexGgeResourceAudio() {
  if (!IsHunexGgeProfileMatched()) return false;
  if (InterlockedCompareExchange(&g_hunex_voice_enabled, 0, 0) != 0) {
    return true;
  }
  if (!TryHookSiglusOvk() || !LoadHunexVoiceArchives()) return false;
  InterlockedExchange(&g_hunex_voice_enabled, 1);
  SetXAudioDiagnostic(fushi_voice_hook::kXAudioDiagHunexHfaHooksReady);
  return true;
}

void StopHunexGgeResourceAudio() {
  InterlockedExchange(&g_hunex_voice_enabled, 0);
  InterlockedIncrement(&g_hunex_voice_generation);
  fushi_voice_hook::ClearTrackedHandles(g_hunex_voice_handles);
  InterlockedExchange(&g_hunex_voice_archive_count, 0);
  HunexVoiceRange* ranges = g_hunex_voice_archive.ranges;
  g_hunex_voice_archive = {};
  free(ranges);
  for (int index = 0; index < kHunexVoiceTaskSlots; ++index) {
    InterlockedExchange(&g_hunex_voice_tasks[index].state, 0);
  }
  g_hunex_voice_load_attempted = false;
  g_hunex_voice_load_stamp = {};
  g_hunex_voice_last_range = UINT32_MAX;
  g_hunex_voice_last_tick = 0u;
}

#if defined(_M_X64)

void DisableHunexGgeLookupRuntime(bool reset_worker_state) {
  if (g_header != nullptr) {
    fushi_voice_hook::g_geometry_provider_registry.Retire(
        g_header,
        fushi_voice_hook::kLookupGeometryProviderEngineExactLayout,
        fushi_voice_hook::kLookupGeometryProviderIdHunexGge);
  }
  SetHunexGgeLookupRuntimeEnabled(&g_hunex_gge_lookup_runtime, false);
  InvalidateHunexGgeLookupModel(&g_hunex_gge_lookup_runtime);
  if (reset_worker_state) ResetHunexGgeLookupWorkerState();
}

struct HunexGgeSnapshotSelection {
  uint64_t selected_text_seq = 0u;
  uint64_t latest_strict_selected_line_seq = 0u;
  fushi_voice_hook::HunexGgeSelectedTextFailure failure =
      fushi_voice_hook::HunexGgeSelectedTextFailure::kNone;
};

HunexGgeSnapshotSelection MatchHunexGgeSnapshotToSelectedText(
    const fushi_voice_hook::hunex_capture_bridge::TraversalSnapshot& snapshot,
    uint64_t selected_thread_id) {
  HunexGgeSnapshotSelection outcome;
  const auto read_selected_text =
      [&](uint64_t window_after_seq, uint64_t window_through_seq) {
    fushi_voice_hook::HunexGgeSelectedTextRequest request;
    request.header = g_header;
    request.mapped_bytes = g_mapped_view_bytes;
    request.current_process_id = GetCurrentProcessId();
    request.exact_selected_thread_id = selected_thread_id;
    request.exact_thread_address = snapshot.story_thread_address;
    request.window_after_seq = window_after_seq;
    request.window_through_seq = window_through_seq;
    request.exact_raw_tagged_text =
        reinterpret_cast<const wchar_t*>(snapshot.raw_text.data());
    request.exact_raw_tagged_text_units = snapshot.raw_text_units;
    return fushi_voice_hook::ReadHunexGgeSelectedLunaText(request);
  };

  fushi_voice_hook::HunexGgeSelectedTextResult selected = {};
  bool selected_read_attempted = false;
  if (selected_thread_id != 0u &&
      snapshot.text_window_through_seq >
          g_hunex_gge_lookup_last_selected_text_seq) {
    selected = read_selected_text(
        g_hunex_gge_lookup_last_selected_text_seq,
        snapshot.text_window_through_seq);
    outcome.latest_strict_selected_line_seq =
        selected.latest_strict_selected_line_seq;
    selected_read_attempted = true;
  }

  // WoH seals the renderer traversal before Luna publishes the same line.
  // Inspect one stable post-render window as well, but retain the exact raw
  // bytes/thread-address requirements so prefetched or toolbar text cannot
  // become the selected story model.
  if (selected.disposition !=
      fushi_voice_hook::HunexGgeSelectedTextDisposition::kUseExactMatch) {
    const uint64_t deferred_after_seq =
        snapshot.text_window_through_seq >
                g_hunex_gge_lookup_last_selected_text_seq
            ? snapshot.text_window_through_seq
            : g_hunex_gge_lookup_last_selected_text_seq;
    const uint64_t deferred_through_seq =
        ReadStableHunexGgeTextWindowThroughSeq();
    if (selected_thread_id != 0u &&
        deferred_through_seq > deferred_after_seq) {
      selected = read_selected_text(deferred_after_seq, deferred_through_seq);
      outcome.latest_strict_selected_line_seq = (std::max)(
          outcome.latest_strict_selected_line_seq,
          selected.latest_strict_selected_line_seq);
      selected_read_attempted = true;
    }
  }

  if (selected_read_attempted) {
    outcome.failure = selected.failure;
    if (selected.disposition ==
            fushi_voice_hook::HunexGgeSelectedTextDisposition::
                kUseExactMatch &&
        selected.matched_seq != 0u) {
      outcome.selected_text_seq = selected.matched_seq;
      return outcome;
    }
  }

  // A renderer redraw can legitimately have no new Luna event. Reuse the
  // semantic generation only for the exact bytes/function/selected lane that
  // were previously admitted.
  if (IsSameHunexGgeMatchedRawLine(snapshot, selected_thread_id)) {
    outcome.selected_text_seq = g_hunex_gge_lookup_last_selected_text_seq;
  }
  return outcome;
}

bool RetainHunexGgeLookupModel(uint64_t selected_thread_id,
                               uint64_t latest_strict_selected_line_seq) {
  if (selected_thread_id == 0u ||
      selected_thread_id != g_hunex_gge_lookup_last_selected_thread_id ||
      g_hunex_gge_lookup_last_selected_text_seq == 0u ||
      latest_strict_selected_line_seq >
          g_hunex_gge_lookup_last_selected_text_seq ||
      !HasFreshHunexGgeProjectionEvidenceForRetain() ||
      g_hunex_gge_lookup_runtime.published_model_slot.load(
          std::memory_order_acquire) >= kHunexGgeLookupModelSlots) {
    return false;
  }
  if (!fushi_voice_hook::g_geometry_provider_registry.OfferReady(
          g_header,
          fushi_voice_hook::kLookupGeometryProviderEngineExactLayout,
          fushi_voice_hook::kLookupGeometryProviderIdHunexGge)) {
    return false;
  }
  SetHunexGgeLookupRuntimeEnabled(&g_hunex_gge_lookup_runtime, true);
  (void)TickHunexGgeLookupRuntime(&g_hunex_gge_lookup_runtime, g_header);
  return true;
}

bool PrepareHunexGgeCaptureForLookup(bool capture_requested) {
  // Lifecycle state machine:
  //   disabled -> mutation gate closed;
  //   rising edge -> gate remains closed while Reset() retries;
  //   quiescent reset -> gate opens for admitted render callbacks;
  //   real capture quarantine -> gate stays closed until adapter teardown.
  if (!capture_requested) {
    InterlockedExchange(&g_hunex_gge_capture_mutation_admitted, 0);
    return false;
  }
  if (InterlockedCompareExchange(
          &g_hunex_gge_capture_mutation_admitted, 0, 0) != 0) {
    return true;
  }
  if (g_hunex_gge_capture_bridge.quarantined()) {
    return false;
  }
  if (!g_hunex_gge_capture_bridge.Reset()) {
    // A still-running callback from the previous enabled interval owns the
    // bridge. Leave mutation closed and retry on the next worker tick.
    return false;
  }
  ResetHunexGgeLookupWorkerState();
  InterlockedExchange(&g_hunex_gge_capture_mutation_admitted, 1);
  return true;
}

void ProcessHunexGgeLookupTick() {
  const bool lookup_requested =
      !g_stop && g_header != nullptr &&
      fushi_voice_hook::HasLookupRegion(g_header) &&
      g_header->lookup_enabled != 0u;
  const bool exact_profile_admitted =
      IsHunexGgeProfileMatched() &&
      InterlockedCompareExchange(&g_hunex_gge_trace_scan_state, 0, 0) == 1;
  const bool capture_mutation_admitted = PrepareHunexGgeCaptureForLookup(
      lookup_requested && exact_profile_admitted);
  const bool input_hook_ready =
      InterlockedCompareExchange(&g_hunex_gge_trace_hooks_ready, 0, 0) != 0 &&
      g_orig_hunex_gge_get_async_key_state != nullptr;
  const bool capture_quarantined = g_hunex_gge_capture_bridge.quarantined();
  if (capture_quarantined) {
    InterlockedExchange(&g_hunex_gge_capture_mutation_admitted, 0);
  }
  const bool input_thread_conflict =
      g_hunex_gge_lookup_runtime.click_state.thread_conflict.load(
          std::memory_order_acquire) ||
      g_hunex_gge_lookup_runtime.shift_state.thread_conflict.load(
          std::memory_order_acquire) ||
      g_hunex_gge_lookup_runtime.tail_thread_conflict.load(
          std::memory_order_acquire);
  if ((capture_quarantined || input_thread_conflict) && g_header != nullptr) {
    InterlockedOr(reinterpret_cast<volatile LONG*>(&g_header->lookup_diag),
                  static_cast<LONG>(
                      fushi_voice_hook::kLookupDiagSensorFault));
  }
  const HWND game = lookup_requested ? FindGameMainWindow() : nullptr;
  const bool shield_ready = MaintainHunexGgeSampledInputShield(
      &g_hunex_gge_lookup_runtime, g_header, game,
      lookup_requested && exact_profile_admitted,
      input_hook_ready && !input_thread_conflict);
  uint32_t lookup_gate_mask = 0u;
  if (lookup_requested) {
    lookup_gate_mask |= fushi_voice_hook::kHunexGgeTraceLookupRequested;
  }
  if (exact_profile_admitted) {
    lookup_gate_mask |=
        fushi_voice_hook::kHunexGgeTraceLookupExactProfileAdmitted;
  }
  if (input_hook_ready) {
    lookup_gate_mask |= fushi_voice_hook::kHunexGgeTraceLookupInputHookReady;
  }
  if (shield_ready) {
    lookup_gate_mask |= fushi_voice_hook::kHunexGgeTraceLookupShieldReady;
  }
  if (capture_quarantined) {
    lookup_gate_mask |=
        fushi_voice_hook::kHunexGgeTraceLookupCaptureQuarantined;
  }
  if (input_thread_conflict) {
    lookup_gate_mask |=
        fushi_voice_hook::kHunexGgeTraceLookupInputThreadConflict;
  }
  PublishHunexGgeLookupGateDiagnostics(lookup_gate_mask);
  if (!lookup_requested || !capture_mutation_admitted ||
      !exact_profile_admitted || !input_hook_ready || !shield_ready ||
      capture_quarantined || input_thread_conflict) {
    SetHunexGgeLookupWorkerTraceState(kHunexGgeLookupWorkerGateClosed);
    DisableHunexGgeLookupRuntime(!lookup_requested);
    if (input_thread_conflict) {
      // Contention invalidates only the current sampled interval. The runtime
      // and sampled-input shield are closed for this tick; a quiescent reset
      // lets the exact callsite recover on the next tick instead of poisoning
      // the process for the remainder of its lifetime.
      (void)ResetHunexGgeInputSampleStates(&g_hunex_gge_lookup_runtime);
    }
    return;
  }

  InterlockedOr(reinterpret_cast<volatile LONG*>(&g_header->lookup_diag),
                static_cast<LONG>(
                    fushi_voice_hook::kLookupDiagSensorInstalled));

  const uint64_t selected_thread_id =
      fushi_voice_hook::SelectedTextThreadId(g_header);

  // The newest body-wrapper traversal is often the top toolbar, not the
  // selected story sentence. Enumerate every stable recent slot and bind in
  // the safe direction used by Leaf: selected semantic line -> exact recent
  // geometry candidate. Never weaken exact raw/thread/function matching.
  fushi_voice_hook::hunex_capture_bridge::TraversalSnapshot snapshot;
  HunexGgeSnapshotSelection snapshot_selection;
  bool any_snapshot = false;
  bool matched_snapshot = false;
  uint32_t newest_rejected_epoch = 0u;
  fushi_voice_hook::HunexGgeSelectedTextFailure newest_failure =
      fushi_voice_hook::HunexGgeSelectedTextFailure::kNone;
  uint64_t newest_selected_line_seq = 0u;
  for (uint32_t slot_index = 0u;
       slot_index <
       fushi_voice_hook::hunex_capture_bridge::kSnapshotSlotCount;
       ++slot_index) {
    fushi_voice_hook::hunex_capture_bridge::TraversalSnapshot candidate;
    if (!g_hunex_gge_capture_bridge.ReadSealedSlot(slot_index, &candidate)) {
      continue;
    }
    any_snapshot = true;
    if (candidate.story_thread_address == 0u ||
        candidate.text_window_through_seq == 0u ||
        candidate.raw_text_units == 0u) {
      continue;
    }
    const HunexGgeSnapshotSelection candidate_selection =
        MatchHunexGgeSnapshotToSelectedText(candidate, selected_thread_id);
    newest_selected_line_seq = (std::max)(
        newest_selected_line_seq,
        candidate_selection.latest_strict_selected_line_seq);
    if (candidate_selection.selected_text_seq != 0u) {
      if (!matched_snapshot || candidate.epoch > snapshot.epoch) {
        snapshot = candidate;
        snapshot_selection = candidate_selection;
        matched_snapshot = true;
      }
    } else if (candidate.epoch >= newest_rejected_epoch) {
      newest_rejected_epoch = candidate.epoch;
      newest_failure = candidate_selection.failure;
    }
  }

  if (!matched_snapshot) {
    SetHunexGgeLookupWorkerTraceState(
        any_snapshot ? kHunexGgeLookupWorkerSelectedTextRejected
                     : kHunexGgeLookupWorkerNoSnapshot,
        newest_failure);
    // Unrelated toolbar/body surfaces must not revoke an already exact-bound
    // story model. The model is retained only while the selected Luna lane is
    // unchanged; a newly exact-matched story snapshot replaces it below.
    if (RetainHunexGgeLookupModel(selected_thread_id,
                                  newest_selected_line_seq)) {
      SetHunexGgeLookupWorkerTraceState(
          kHunexGgeLookupWorkerGeometryRetained, newest_failure);
      return;
    }
    DisableHunexGgeLookupRuntime(false);
    return;
  }

  if (snapshot.epoch == g_hunex_gge_lookup_last_snapshot_epoch &&
      selected_thread_id ==
          g_hunex_gge_lookup_last_selected_thread_id &&
      snapshot_selection.selected_text_seq ==
          g_hunex_gge_lookup_last_selected_text_seq &&
      RetainHunexGgeLookupModel(selected_thread_id,
                                newest_selected_line_seq)) {
    return;
  }

  RECT client = {};
  if (!GetClientRect(game, &client)) {
    SetHunexGgeLookupWorkerTraceState(
        kHunexGgeLookupWorkerInvalidViewportOrSnapshot);
    DisableHunexGgeLookupRuntime(false);
    return;
  }
  const int32_t client_width = client.right - client.left;
  const int32_t client_height = client.bottom - client.top;
  if (client_width <= 0 || client_height <= 0 ||
      snapshot.story_thread_address == 0u ||
      snapshot.text_window_through_seq == 0u ||
      snapshot.raw_text_units == 0u) {
    SetHunexGgeLookupWorkerTraceState(
        kHunexGgeLookupWorkerInvalidViewportOrSnapshot);
    DisableHunexGgeLookupRuntime(false);
    return;
  }

  const uint64_t selected_text_seq = snapshot_selection.selected_text_seq;

  fushi_voice_hook::hunex_lookup_core::RubyTextProjection projection;
  if (!BuildHunexGgeClientProjection(snapshot, client_width, client_height,
                                     &projection)) {
    SetHunexGgeLookupWorkerTraceState(
        kHunexGgeLookupWorkerProjectionRejected);
    DisableHunexGgeLookupRuntime(false);
    return;
  }
  HunexGgeLookupModelInput model;
  // Renderer traversals redraw the same sentence every frame. The click
  // transaction must survive those redraws, so its semantic epoch is the
  // exact selected Luna event, not the per-traversal bridge epoch.
  model.capture_epoch = selected_text_seq;
  model.selected_text_seq = selected_text_seq;
  model.render_thread_id = snapshot.render_thread_id;
  model.client_width = client_width;
  model.client_height = client_height;
  model.client_projection = &projection;
  if (!PublishHunexGgeLookupModel(&g_hunex_gge_lookup_runtime, model)) {
    SetHunexGgeLookupWorkerTraceState(kHunexGgeLookupWorkerModelRejected);
    DisableHunexGgeLookupRuntime(false);
    return;
  }
  if (!fushi_voice_hook::g_geometry_provider_registry.OfferReady(
          g_header,
          fushi_voice_hook::kLookupGeometryProviderEngineExactLayout,
          fushi_voice_hook::kLookupGeometryProviderIdHunexGge)) {
    SetHunexGgeLookupWorkerTraceState(kHunexGgeLookupWorkerGateClosed);
    DisableHunexGgeLookupRuntime(false);
    return;
  }
  InterlockedOr(reinterpret_cast<volatile LONG*>(&g_header->lookup_diag),
                static_cast<LONG>(
                    fushi_voice_hook::kLookupDiagGeometryObserved));
  RememberHunexGgeMatchedRawLine(snapshot, selected_thread_id,
                                 selected_text_seq);
  SetHunexGgeLookupWorkerTraceState(
      kHunexGgeLookupWorkerGeometryPublished);
  g_hunex_gge_lookup_last_snapshot_epoch = snapshot.epoch;
  SetHunexGgeLookupRuntimeEnabled(&g_hunex_gge_lookup_runtime, true);
  (void)TickHunexGgeLookupRuntime(&g_hunex_gge_lookup_runtime, g_header);
}

#else

void ProcessHunexGgeLookupTick() {}

#endif  // _M_X64

class HunexGgeAdapter final : public fushi_voice_hook::EngineAdapter {
 public:
  const char* id() const override { return "hunex_gge"; }
  bool probe() const override { return IsHunexGgeProfileMatched(); }
  bool install() override {
#if defined(_M_X64)
    if (!capture_bridge_initialized_) {
      InterlockedExchange(&g_hunex_gge_capture_mutation_admitted, 0);
      capture_bridge_initialized_ = g_hunex_gge_capture_bridge.Reset();
      ResetHunexGgeLookupWorkerState();
    }
    if (!capture_bridge_initialized_) {
      // The draw detours publish into this bridge. Never advertise a complete
      // text/lookup sensor when its publication storage cannot be reset.
      const bool resource_audio_ready = TryHookHunexGgeResourceAudio();
      installed_ = resource_audio_ready || installed_;
      return installed_;
    }
#endif
    const bool trace_ready = TryHookHunexGgeRuntimeTrace();
    const bool resource_audio_ready = TryHookHunexGgeResourceAudio();
    installed_ = trace_ready || resource_audio_ready || installed_;
    return installed_;
  }
  void ProcessPendingEvents() {
    install();
    ProcessHunexVoiceTasks();
    ProcessHunexGgeLookupTick();
  }
  fushi_voice_hook::AdapterCapability capabilities() const override {
    return fushi_voice_hook::AdapterCapability::kText |
           fushi_voice_hook::AdapterCapability::kResourceAudio;
  }
  fushi_voice_hook::LookupAdmissionReport lookupAdmission() const override {
    fushi_voice_hook::LookupAdmissionReport report;
#if defined(_M_X64)
    const bool scanner_admitted =
        InterlockedCompareExchange(&g_hunex_gge_trace_scan_state, 0, 0) == 1;
    const bool hooks_ready =
        InterlockedCompareExchange(&g_hunex_gge_trace_hooks_ready, 0, 0) != 0 &&
        g_orig_hunex_gge_get_async_key_state != nullptr &&
        !g_hunex_gge_capture_bridge.quarantined();
    report.state = scanner_admitted && hooks_ready
                       ? fushi_voice_hook::kLookupAdmissionSensorInstalled
                       : fushi_voice_hook::kLookupAdmissionIdentityAccepted;
#else
    report.state = fushi_voice_hook::kLookupAdmissionEngineUnsupported;
#endif
    return report;
  }
  bool lookup_sensor_available() const {
#if defined(_M_X64)
    return IsHunexGgeProfileMatched() &&
           InterlockedCompareExchange(&g_hunex_gge_trace_scan_state, 0, 0) ==
               1 &&
           InterlockedCompareExchange(&g_hunex_gge_trace_hooks_ready, 0, 0) !=
               0 &&
           g_orig_hunex_gge_get_async_key_state != nullptr &&
           !g_hunex_gge_capture_bridge.quarantined();
#else
    return false;
#endif
  }
  void onModuleLoaded(const wchar_t*) override { install(); }
  void shutdown() override {
    StopHunexGgeResourceAudio();
#if defined(_M_X64)
    if (g_header != nullptr) {
      fushi_voice_hook::g_geometry_provider_registry.Retire(
          g_header,
          fushi_voice_hook::kLookupGeometryProviderEngineExactLayout,
          fushi_voice_hook::kLookupGeometryProviderIdHunexGge);
    }
    ShutdownHunexGgeLookupRuntime(&g_hunex_gge_lookup_runtime, g_header);
    InterlockedExchange(&g_hunex_gge_capture_mutation_admitted, 0);
    (void)g_hunex_gge_capture_bridge.Reset();
    ResetHunexGgeLookupWorkerState();
    capture_bridge_initialized_ = false;
#endif
    installed_ = false;
  }
  fushi_voice_hook::AdapterDiagnostics diagnostics() const override {
    return {id(), probe(), installed_,
            g_header == nullptr ? 0u : g_header->xaudio_diagnostics};
  }

 private:
  bool installed_ = false;
  bool capture_bridge_initialized_ = false;
};
