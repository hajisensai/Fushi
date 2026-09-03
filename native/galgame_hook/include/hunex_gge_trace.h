#pragma once

#include <cstddef>
#include <cstdint>

namespace fushi_voice_hook {

// Fixed, numeric-only telemetry for the structurally admitted HUNEX/GGE
// renderer and sampled-input paths.  Text spans remain deliberately excluded.
// A structurally admitted story frame may expose only its current raw scalar,
// UTF-16 index, and consumed count so the traversal can be diagnosed without
// exporting the user's game text.
inline constexpr char kHunexGgeTraceExportName[] = "FushiHunexGgeTraceV3";
inline constexpr uint32_t kHunexGgeTraceMagic = 0x33544748u;  // "HGT3"
// v4（BUG-2089）：头部增加四个投影 detour 的调用计数。probe 与 helper 同源构建，
// 版本号不匹配时 probe 直接拒读，不存在跨版本误解释。
inline constexpr uint32_t kHunexGgeTraceVersion = 6u;
inline constexpr uint32_t kHunexGgeTraceCapacity = 512u;

enum class HunexGgeTraceKind : uint32_t {
  kDraw = 1u,
  kGlyphDirectFirst = 2u,
  kGlyphDirectSecond = 3u,
  kInputGeneric = 4u,
  kInputLeftButton = 5u,
  // The admitted draw call graph supplies an exact UTF-16/glyph association.
  kRenderItemCorrelated = 6u,
  // The same render-item helper can be reached by another, not-yet-admitted
  // draw graph.  Numeric caller/position telemetry is intentionally retained
  // so a missing body-text path is observable without enabling lookup.
  kRenderItemUncorrelated = 7u,
  kGlyphUncorrelated = 8u,
  // A structurally admitted TYPEMOON body-render submit wrapper reached the
  // common mover.  The event still carries no text and is not lookup-ready;
  // it only proves the outer renderer function/callsite and item geometry.
  kRenderItemBodyUncorrelated = 9u,
  kSurfaceCompose = 10u,
  kTextureUpload = 11u,
  kSpriteQuad = 12u,
  // One bounded, numeric-only projection-chain checkpoint/failure. The
  // existing event layout carries stage/failure in arg7/result, so adding
  // this kind does not change the exported V3 ABI.
  kProjectionDiagnostic = 13u,
};

enum class HunexGgeProjectionTraceStage : uint32_t {
  kWrapper = 1u,
  kCompositor = 2u,
  kTexture = 3u,
  kSprite = 4u,
  // BUG-2089：worker 侧的投影求解。前四段都在 render 线程的 detour 里，唯独这一段在
  // lookup worker 线程上跑，且此前**整段没有任何诊断**——真机上只表现为
  // kHunexGgeLookupWorkerProjectionRejected 这一个笼统状态，读不出九选一的真实原因。
  kWorker = 5u,
};

// Values are diagnostic only. They identify the first exact story-chain gate
// that rejected a projection without weakening any production correlation.
enum class HunexGgeProjectionTraceFailure : int32_t {
  kNone = 0,
  kWrapperStoryExpired = 1,
  kWrapperDestinationUnreadable = 2,
  kCompositorNotObserved = 3,
  kCompositorDescriptorUnreadable = 4,
  kCompositorStorySurfaceMismatch = 5,
  kCompositorCandidateAmbiguous = 6,
  kCompositorFinalLinkMissing = 7,
  kCompositorFinalLinkAmbiguous = 8,
  kCompositorDestinationMismatch = 9,
  kCompositorFinalSurfaceInvalid = 10,
  kTextureUploadFailed = 11,
  kTextureObjectMissing = 12,
  kSpriteModeRejected = 13,
  kSpriteRenderThreadMismatch = 14,
  kSpriteQuadMissing = 15,
  kSpriteVertexMismatch = 16,
  kSpriteSurfaceExpired = 17,
  kSpriteQuadExpired = 18,
  kSpriteProjectionSizesRejected = 19,
  kSpriteDrawFailed = 20,
  // 21..23 补的是段 3/段 4 的**诊断盲区**：这两段原本在拒绝时直接 return，不发任何
  // 事件，于是真机 trace 里表现为「compositor 成功后就没有下文」，无法分辨是纹理上传
  // 没对上、还是 quad 形状被拒。投影链共 20 个显式失败点却留了 4 个哑口，等于让下一次
  // 真机会话大概率读不出结论（BUG-2087）。复用既有 V3 事件布局，不改导出 ABI。
  kTextureSurfaceMismatch = 21,
  kQuadShapeRejected = 22,
  kQuadVertexBufferMissing = 23,
  kQuadProjectionNotFinite = 24,
  // 25..33 = kWorker 段（BUG-2089）。此前 BuildHunexGgeClientProjection 的每个拒绝点
  // 都是裸 return false，其中「证据身份」更是九个子条件的合取，一旦不成立完全无法分辨
  // 是没有证据、故事身份不符、渲染线程不符、客户区尺寸不符，还是证据过期。
  kWorkerInputShapeRejected = 25,
  kWorkerRubyProjectionRejected = 26,
  // 根本没有可读的投影证据（sprite draw 从未成功发布过）。
  kWorkerEvidenceUnavailable = 27,
  kWorkerEvidenceStoryMismatch = 28,
  kWorkerEvidenceThreadMismatch = 29,
  kWorkerEvidenceClientMismatch = 30,
  kWorkerEvidenceStale = 31,
  kWorkerAffineRejected = 32,
  kWorkerClientTransformRejected = 33,
};

enum HunexGgeTraceScannerStatus : uint32_t {
  kHunexGgeTraceScannerProfileMatched = 0x00000001u,
  kHunexGgeTraceScannerPe64 = 0x00000002u,
  kHunexGgeTraceScannerDrawUnique = 0x00000004u,
  kHunexGgeTraceScannerGlyphUnique = 0x00000008u,
  kHunexGgeTraceScannerInputUnique = 0x00000010u,
  kHunexGgeTraceScannerDrawCallsValid = 0x00000020u,
  kHunexGgeTraceScannerInputCallsValid = 0x00000040u,
  kHunexGgeTraceScannerHooksReady = 0x00000080u,
  kHunexGgeTraceScannerRenderItemCallValid = 0x00000100u,
  kHunexGgeTraceScannerCursorTransformValid = 0x00000200u,
  kHunexGgeTraceScannerBodySubmitValid = 0x00000400u,
  kHunexGgeTraceScannerSurfaceComposeUnique = 0x00000800u,
  kHunexGgeTraceScannerSurfaceComposeCallsValid = 0x00001000u,
  kHunexGgeTraceScannerSurfaceComposeHooksReady = 0x00002000u,
  kHunexGgeTraceScannerProjectionEntriesUnique = 0x00004000u,
  kHunexGgeTraceScannerProjectionGraphValid = 0x00008000u,
  kHunexGgeTraceScannerProjectionHooksReady = 0x00010000u,
};

enum HunexGgeTraceEvidence : uint32_t {
  kHunexGgeTraceEvidenceAlignmentModeRead = 0x00000001u,
  kHunexGgeTraceEvidenceRenderItemPositionRead = 0x00000002u,
  kHunexGgeTraceEvidenceGlyphCallGraphCorrelated = 0x00000004u,
  // A glyph call immediately preceded the helper call on the same thread, but
  // no admitted draw graph proves that both operations belong to one scalar.
  kHunexGgeTraceEvidenceGlyphProximityObserved = 0x00000008u,
  kHunexGgeTraceEvidenceViewportTransformRead = 0x00000010u,
  kHunexGgeTraceEvidenceBodySubmitGraph = 0x00000020u,
  kHunexGgeTraceEvidenceOuterCallerRead = 0x00000040u,
  kHunexGgeTraceEvidenceStoryFrameSlotsRead = 0x00000080u,
  kHunexGgeTraceEvidenceStoryLineBounded = 0x00000100u,
  // Body-render lookup publication diagnostics. These reuse the existing
  // numeric trace event and therefore do not expose story text or widen the
  // exported trace ABI.
  kHunexGgeTraceEvidenceRawTextLayoutValid = 0x00000200u,
  kHunexGgeTraceEvidenceRawTextTokenMatched = 0x00000400u,
  kHunexGgeTraceEvidenceCaptureGlyphAccepted = 0x00000800u,
  kHunexGgeTraceEvidenceCaptureSnapshotPublished = 0x00001000u,
  kHunexGgeTraceEvidenceCaptureQuarantined = 0x00002000u,
  kHunexGgeTraceEvidenceBodyGlyphMetricsMatched = 0x00004000u,
  kHunexGgeTraceEvidenceSurfaceComposeGraph = 0x00008000u,
  kHunexGgeTraceEvidenceSurfaceDescriptorsRead = 0x00010000u,
  kHunexGgeTraceEvidenceTextureIdentityLinked = 0x00020000u,
  kHunexGgeTraceEvidenceQuadIdentityLinked = 0x00040000u,
  kHunexGgeTraceEvidenceProjectionSizesRead = 0x00080000u,
};

// Predicate values sampled by ProcessHunexGgeLookupTick. Positive bits mean
// that the named predicate was true; quarantine/conflict bits intentionally
// describe faults rather than inverted "healthy" states.
enum HunexGgeTraceLookupGate : uint32_t {
  kHunexGgeTraceLookupRequested = 0x00000001u,
  kHunexGgeTraceLookupExactProfileAdmitted = 0x00000002u,
  kHunexGgeTraceLookupInputHookReady = 0x00000004u,
  kHunexGgeTraceLookupShieldReady = 0x00000008u,
  kHunexGgeTraceLookupCaptureQuarantined = 0x00000010u,
  kHunexGgeTraceLookupInputThreadConflict = 0x00000020u,
};

// Numeric mirror of hunex_capture_bridge::CaptureQuarantineReason. This lives
// in the exported trace contract so ring_probe never needs adapter internals.
enum HunexGgeTraceCaptureQuarantineReason : uint32_t {
  kHunexGgeTraceCaptureQuarantineNone = 0u,
  kHunexGgeTraceCaptureQuarantineReentrantCallback = 1u,
  kHunexGgeTraceCaptureQuarantineInvalidRenderThreadId = 2u,
  kHunexGgeTraceCaptureQuarantineRenderThreadConflict = 3u,
  kHunexGgeTraceCaptureQuarantineLineIdentityOrFenceInvalid = 4u,
  kHunexGgeTraceCaptureQuarantineSlotSequenceOverflow = 5u,
};

struct alignas(8) HunexGgeTraceEvent {
  uint64_t sequence = 0;
  uint64_t timestamp_ms = 0;
  uint64_t draw_sequence = 0;
  uint64_t text_hash = 0;
  uint64_t draw_arg12_bits = 0;
  uint32_t kind = 0;
  uint32_t thread_id = 0;
  uint32_t caller_rva = 0;
  uint32_t text_units = 0;
  uint32_t visible_units = 0;
  uint32_t glyph_ordinal = 0;
  uint32_t utf16_char_index = 0;
  uint32_t scalar_width = 0;
  uint32_t arg7 = 0;
  uint32_t draw_arg13 = 0;
  int32_t draw_x = 0;
  int32_t draw_y = 0;
  int32_t draw_width = 0;
  int32_t result = 0;
  uint32_t evidence_flags = 0;
  uint32_t glyph_calls_since_render = 0;
  uint32_t related_caller_rva = 0;
  int32_t render_x = 0;
  int32_t render_y = 0;
  int32_t alignment_mode = 0;
  int32_t viewport_left = 0;
  int32_t viewport_top = 0;
  int32_t viewport_right = 0;
  int32_t viewport_bottom = 0;
  uint32_t scale_x_bits = 0;
  uint32_t scale_y_bits = 0;
  uint32_t outer_caller_rva = 0;
  uint32_t outer_function_rva = 0;
  uint64_t story_line_base = 0;
  uint64_t story_line_hash = 0;
  // Presence only. Exporting the scalar itself would let a trace consumer
  // reconstruct story text from consecutive render events.
  uint32_t story_scalar_present = 0;
  uint32_t story_raw_utf16_index = 0;
  uint32_t story_consumed = 0;
  uint32_t story_line_units = 0;
  uint32_t descriptor_words[8] = {};
  uint32_t output_words[28] = {};
  // Pre-move snapshot of the render item.  The common mover mutates/moves the
  // source, so this bounded numeric window must be copied before original.
  uint32_t render_item_words[28] = {};
  // Current worker gate plus the capture bridge's process-sticky first fault.
  // These are stamped on every body-submit event so the event remains
  // self-explanatory even after the ring header changes on a later tick.
  uint32_t lookup_gate_mask = 0;
  uint32_t capture_quarantine_reason = 0;
  uint32_t capture_quarantine_bound_thread_id = 0;
  uint32_t capture_quarantine_conflicting_thread_id = 0;
};

struct alignas(8) HunexGgeTraceSlot {
  int32_t writing = 0;
  uint32_t reserved = 0;
  HunexGgeTraceEvent event = {};
};

struct alignas(8) HunexGgeTraceBuffer {
  uint32_t magic = kHunexGgeTraceMagic;
  uint32_t version = kHunexGgeTraceVersion;
  uint32_t event_size = sizeof(HunexGgeTraceEvent);
  uint32_t slot_size = sizeof(HunexGgeTraceSlot);
  uint32_t capacity = kHunexGgeTraceCapacity;
  uint32_t scanner_status = 0;
  int64_t next_sequence = 0;
  int64_t dropped_busy = 0;
  int64_t draw_calls = 0;
  int64_t glyph_calls = 0;
  int64_t render_item_calls = 0;
  int64_t input_calls = 0;
  uint32_t module_machine = 0;
  uint32_t draw_match_count = 0;
  uint32_t glyph_match_count = 0;
  uint32_t key_poller_match_count = 0;
  uint32_t input_pump_match_count = 0;
  uint32_t render_item_call_match_count = 0;
  uint32_t body_submit_match_count = 0;
  uint32_t cursor_scale_x_match_count = 0;
  uint32_t cursor_scale_y_match_count = 0;
  uint32_t draw_rva = 0;
  uint32_t glyph_rva = 0;
  uint32_t key_poller_rva = 0;
  uint32_t input_pump_rva = 0;
  uint32_t render_item_rva = 0;
  uint32_t body_submit_rva = 0;
  uint32_t viewport_rect_rva = 0;
  uint32_t scale_x_rva = 0;
  uint32_t scale_y_rva = 0;
  uint32_t generic_return_rva = 0;
  uint32_t left_button_return_rva = 0;
  uint32_t direct_first_glyph_return_rva = 0;
  uint32_t direct_second_glyph_return_rva = 0;
  uint32_t render_item_return_rva = 0;
  uint32_t body_submit_return_rva = 0;
  uint32_t lookup_gate_mask = 0;
  uint32_t capture_quarantine_reason = 0;
  uint32_t capture_quarantine_bound_thread_id = 0;
  uint32_t capture_quarantine_conflicting_thread_id = 0;
  // BUG-2089：投影四段 detour 的**调用计数**。诊断事件只在「能归属到某条语义行」时才
  // 发，因此「零事件」既可能是从没被调用、也可能是调用了但当时没有待定故事行——两者
  // 的排障方向完全相反（前者说明 WoH 的正文走的不是扫描锚点假设的那条渲染路径）。
  // 只有无条件的调用计数能把它们分开。
  int64_t surface_compose_wrapper_calls = 0;
  // v5：wrapper 之外的另两个合成入口也要单独计数。上一轮只数了 wrapper，无法回答
  // 「是整条合成路径都不走，还是只有 wrapper 这一个锚点选错了」——后者的修法要小得多。
  int64_t surface_compose_calls = 0;
  int64_t surface_compositor_calls = 0;
  // v6（BUG-2089 ③）：compositor 实际被调用了，但两个 compose 锚点都零调用，说明
  // compositor 的真实调用者是另一个函数——那个函数才是 WoH 正文的合成入口。这里记下
  // 最多 4 个**互异**的调用返回地址 RVA，直接把「该去哪找锚点」变成可读数字。
  uint32_t compositor_caller_rvas[4] = {};
  uint32_t compositor_caller_rva_count = 0;
  uint32_t compositor_caller_rva_overflow = 0;
  int64_t texture_upload_calls = 0;
  int64_t quad_vertex_calls = 0;
  int64_t sprite_draw_calls = 0;
  HunexGgeTraceSlot slots[kHunexGgeTraceCapacity] = {};
};

static_assert(sizeof(HunexGgeTraceEvent) == 456,
              "HUNEX/GGE trace event ABI drifted");
static_assert(offsetof(HunexGgeTraceEvent, draw_arg12_bits) == 32,
              "HUNEX/GGE draw arg12 trace ABI drifted");
static_assert(offsetof(HunexGgeTraceEvent, caller_rva) == 48,
              "HUNEX/GGE caller trace ABI drifted");
static_assert(offsetof(HunexGgeTraceEvent, glyph_ordinal) == 60,
              "HUNEX/GGE glyph ordinal trace ABI drifted");
static_assert(offsetof(HunexGgeTraceEvent, utf16_char_index) == 64,
              "HUNEX/GGE UTF-16 index trace ABI drifted");
static_assert(offsetof(HunexGgeTraceEvent, draw_arg13) == 76,
              "HUNEX/GGE draw arg13 trace ABI drifted");
static_assert(offsetof(HunexGgeTraceEvent, evidence_flags) == 96,
              "HUNEX/GGE evidence trace ABI drifted");
static_assert(offsetof(HunexGgeTraceEvent, render_x) == 108,
              "HUNEX/GGE render position trace ABI drifted");
static_assert(offsetof(HunexGgeTraceEvent, viewport_left) == 120,
              "HUNEX/GGE viewport trace ABI drifted");
static_assert(offsetof(HunexGgeTraceEvent, outer_caller_rva) == 144,
              "HUNEX/GGE outer caller trace ABI drifted");
static_assert(offsetof(HunexGgeTraceEvent, story_line_base) == 152,
              "HUNEX/GGE story line trace ABI drifted");
static_assert(offsetof(HunexGgeTraceEvent, story_scalar_present) == 168,
              "HUNEX/GGE story frame trace ABI drifted");
static_assert(offsetof(HunexGgeTraceEvent, descriptor_words) == 184,
              "HUNEX/GGE descriptor trace ABI drifted");
static_assert(offsetof(HunexGgeTraceEvent, output_words) == 216,
              "HUNEX/GGE output trace ABI drifted");
static_assert(offsetof(HunexGgeTraceEvent, render_item_words) == 328,
              "HUNEX/GGE render item trace ABI drifted");
static_assert(offsetof(HunexGgeTraceEvent, lookup_gate_mask) == 440,
              "HUNEX/GGE lookup diagnostic trace ABI drifted");
static_assert(sizeof(HunexGgeTraceSlot) == 464,
              "HUNEX/GGE trace slot ABI drifted");
static_assert(offsetof(HunexGgeTraceBuffer, slots) == 256,
              "HUNEX/GGE trace header ABI drifted");

}  // namespace fushi_voice_hook
