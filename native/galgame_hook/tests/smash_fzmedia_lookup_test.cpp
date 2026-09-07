// Release builds define NDEBUG. Undefine it before every include so these
// assertions remain executable focused test code.
#undef NDEBUG

#include <cassert>
#include <cstdint>
#include <cstdio>
#include <cstring>

#include "smash_fzmedia_lookup_core.h"

namespace smash = fushi_voice_hook::smash_fzmedia;
namespace core = fushi_voice_hook::smash_fzmedia::lookup_core;

namespace {

// Lays `text` out as one row of equal cells starting at (x0, y) in layer
// units, the way the layoutChar detour records them (one cell per UTF-16
// unit, inked unless the unit paints nothing).
smash::LineSnapshot MakeLine(const wchar_t* text, float x0, float y, float w,
                             float h, uint64_t generation = 1u) {
  smash::LineSnapshot line;
  line.generation = generation;
  line.text_event_id = 7u;
  line.font_px = h;
  line.line_pitch = h + 29.0f;
  line.complete = true;
  uint32_t count = 0;
  for (; text[count] != 0 && count < smash::kMaxLineUnits; ++count) {
    line.text[count] = text[count];
    smash::GlyphCell& cell = line.cells[count];
    cell.x = x0 + w * static_cast<float>(count);
    cell.y = y;
    cell.w = w;
    cell.h = h;
    cell.inked = smash::IsNonInkUnit(text[count]) ? 0u : 1u;
  }
  line.unit_count = count;
  return line;
}

void TestLayerLineRequestUsesSyntheticDesignAndMostInkedLine() {
  const smash::StageProjection projection =
      smash::ComputeStageProjection(2126, 1126);
  assert(projection.valid);
  // Measured: 2126x1126 -> s = 1126/1080, synthetic design 2039x1080.
  const smash::LineSnapshot line =
      MakeLine(L"「ふん。なんとなくで", 300.0f, 800.0f, 47.52f, 44.0f);
  const core::LayerLineRequest request =
      core::BuildLayerLineRequest(line, projection);
  assert(request.valid);
  assert(request.design_h == 1080u);
  assert(request.design_w >= 2038u && request.design_w <= 2040u);
  assert(request.glyph_count == 10u);
  assert(request.left == 300);
  assert(request.top == 800);
  assert(request.right == 776);  // ceil(300 + 10 * 47.52)
  assert(request.bottom == 844);

  // Fewer than four inked glyphs has no resolving power for the solver.
  const smash::LineSnapshot short_line =
      MakeLine(L"あい う", 100.0f, 100.0f, 40.0f, 40.0f);
  assert(!core::BuildLayerLineRequest(short_line, projection).valid);
  // Spaces never count as ink.
  const smash::LineSnapshot spaces =
      MakeLine(L"      ", 100.0f, 100.0f, 40.0f, 40.0f);
  assert(!core::BuildLayerLineRequest(spaces, projection).valid);
  // Invalid projection cannot produce a request.
  assert(!core::BuildLayerLineRequest(line, smash::StageProjection()).valid);
  // Two rows: the more inked row wins.
  smash::LineSnapshot two_rows =
      MakeLine(L"あいうえおかきくけこ", 100.0f, 100.0f, 40.0f, 40.0f);
  for (uint32_t i = 6; i < two_rows.unit_count; ++i) {
    two_rows.cells[i].x = 100.0f + 40.0f * static_cast<float>(i - 6);
    two_rows.cells[i].y = 173.0f;
  }
  const core::LayerLineRequest best = core::BuildLayerLineRequest(
      two_rows, smash::ComputeStageProjection(1920, 1080));
  assert(best.valid && best.glyph_count == 6u && best.top == 100 &&
         best.bottom == 140);
}

void TestProjectionEpochAndOriginCache() {
  core::ProjectionEpoch epoch;
  assert(!core::OriginSeqUsable(epoch, 1u));
  assert(core::AdvanceProjectionEpoch(&epoch, 1920u, 1080u, 0u));
  assert(!core::AdvanceProjectionEpoch(&epoch, 1920u, 1080u, 5u));
  assert(epoch.origin_seq_floor == 0u);
  assert(!core::OriginSeqUsable(epoch, 0u));
  assert(core::OriginSeqUsable(epoch, 1u));
  // A resize starts a new epoch; the origin solved for the old size (seq 1)
  // is below the new floor and must be ignored until the host re-solves.
  assert(core::AdvanceProjectionEpoch(&epoch, 2039u, 1080u, 1u));
  assert(!core::OriginSeqUsable(epoch, 1u));
  assert(core::OriginSeqUsable(epoch, 2u));
  assert(!core::AdvanceProjectionEpoch(&epoch, 0u, 1080u, 9u));

  core::OriginCache cache;
  float ox = 0.0f, oy = 0.0f;
  assert(!core::LookupOrigin(cache, 1920u, 1080u, &ox, &oy));
  core::RememberOrigin(&cache, 1920u, 1080u, 12.0f, -8.0f);
  core::RememberOrigin(&cache, 2039u, 1080u, 71.5f, -8.0f);
  assert(core::LookupOrigin(cache, 1920u, 1080u, &ox, &oy) && ox == 12.0f &&
         oy == -8.0f);
  assert(core::LookupOrigin(cache, 2039u, 1080u, &ox, &oy) && ox == 71.5f);
  // Same size updates in place rather than adding a duplicate.
  core::RememberOrigin(&cache, 1920u, 1080u, 13.0f, -9.0f);
  assert(core::LookupOrigin(cache, 1920u, 1080u, &ox, &oy) && ox == 13.0f &&
         oy == -9.0f);
  // Bounded: the fifth distinct size evicts the oldest slot, never grows.
  core::RememberOrigin(&cache, 1000u, 500u, 1.0f, 1.0f);
  core::RememberOrigin(&cache, 1001u, 500u, 1.0f, 1.0f);
  core::RememberOrigin(&cache, 1002u, 500u, 1.0f, 1.0f);
  assert(!core::LookupOrigin(cache, 1920u, 1080u, &ox, &oy));
  assert(core::LookupOrigin(cache, 1002u, 500u, &ox, &oy));
  assert(!core::LookupOrigin(cache, 0u, 500u, &ox, &oy));
}

void TestGeometryReadyFailsClosedOutsideClient() {
  const smash::StageProjection projection =
      smash::ComputeStageProjection(1920, 1080);
  const smash::LineSnapshot line =
      MakeLine(L"あいうえお", 1700.0f, 1000.0f, 40.0f, 40.0f);
  // With origin (0,0) the last cell ends at x=1900 <= 1920: ready.
  assert(core::GeometryReady(line, projection, true, 0.0f, 0.0f, 1920, 1080));
  // 5 px overhang is inside the tolerance.
  assert(core::GeometryReady(line, projection, true, 25.0f, 0.0f, 1920, 1080));
  // 9 px overhang is not.
  assert(!core::GeometryReady(line, projection, true, 29.0f, 0.0f, 1920, 1080));
  // Negative side too.
  assert(!core::GeometryReady(line, projection, true, -1709.0f, 0.0f, 1920,
                              1080));
  assert(!core::GeometryReady(line, projection, true, 0.0f, 49.0f, 1920, 1080));
  // No origin, no readiness, whatever the cells say.
  assert(!core::GeometryReady(line, projection, false, 0.0f, 0.0f, 1920, 1080));
  // An unpublished paragraph (generation 0) is never ready.
  smash::LineSnapshot unpublished = line;
  unpublished.generation = 0u;
  assert(!core::GeometryReady(unpublished, projection, true, 0.0f, 0.0f, 1920,
                              1080));
  // A line with no inked cell has nothing to click.
  const smash::LineSnapshot blank = MakeLine(L"   ", 10.0f, 10.0f, 40.0f, 40.0f);
  assert(!core::GeometryReady(blank, projection, true, 0.0f, 0.0f, 1920, 1080));
  // Invalid projection / client.
  assert(!core::GeometryReady(line, smash::StageProjection(), true, 0.0f, 0.0f,
                              1920, 1080));
  assert(!core::GeometryReady(line, projection, true, 0.0f, 0.0f, 0, 1080));
  // Letterboxed client (2126x1126): scaled cells still fit.
  const smash::StageProjection boxed = smash::ComputeStageProjection(2126, 1126);
  assert(core::GeometryReady(line, boxed, true, 0.0f, 0.0f, 2126, 1126));
}

void TestResolveHitMapsPointToUtf16IndexAndClientRect() {
  const smash::StageProjection projection =
      smash::ComputeStageProjection(1920, 1080);
  const smash::LineSnapshot line =
      MakeLine(L"あい う", 100.0f, 200.0f, 40.0f, 44.0f);
  const float ox = 10.0f, oy = 5.0f;
  // Second glyph spans client x [150, 190), y [205, 249).
  const core::HitGeometry hit =
      core::ResolveHit(line, projection, ox, oy, 160.0f, 210.0f);
  assert(hit.valid && hit.char_index == 1u);
  assert(hit.x == 150 && hit.y == 205 && hit.w == 40 && hit.h == 44);
  // The space cell occupies layout but is not clickable.
  assert(!core::ResolveHit(line, projection, ox, oy, 200.0f, 210.0f).valid);
  // Fourth glyph after the space.
  assert(core::ResolveHit(line, projection, ox, oy, 240.0f, 210.0f).char_index ==
         3u);
  // Outside the row.
  assert(!core::ResolveHit(line, projection, ox, oy, 160.0f, 300.0f).valid);
  assert(!core::ResolveHit(line, projection, ox, oy, 90.0f, 210.0f).valid);
  // Scaled client: same layer point lands at scaled pixels.
  const smash::StageProjection half = smash::ComputeStageProjection(960, 540);
  const core::HitGeometry scaled =
      core::ResolveHit(line, half, 0.0f, 0.0f, 71.0f, 110.0f);
  assert(scaled.valid && scaled.char_index == 1u && scaled.x == 70 &&
         scaled.w == 20 && scaled.h == 22);
}

core::MouseMessageInput Down(bool shield, bool allowed, bool hit,
                             uint64_t generation = 1u, uint32_t index = 0u) {
  core::MouseMessageInput input;
  input.kind = core::MouseMessageKind::kLeftDown;
  input.shield_active = shield;
  input.native_input_allowed = allowed;
  input.hit = hit;
  input.hit_generation = generation;
  input.hit_index = index;
  return input;
}

core::MouseMessageInput Up(bool shield) {
  core::MouseMessageInput input;
  input.kind = core::MouseMessageKind::kLeftUp;
  input.shield_active = shield;
  return input;
}

core::MouseMessageInput Move(bool shift, bool shield, bool allowed, bool hit,
                             uint64_t generation = 1u, uint32_t index = 0u) {
  core::MouseMessageInput input;
  input.kind = core::MouseMessageKind::kMove;
  input.shift = shift;
  input.shield_active = shield;
  input.native_input_allowed = allowed;
  input.hit = hit;
  input.hit_generation = generation;
  input.hit_index = index;
  return input;
}

void TestClickDecisionTable() {
  core::MouseGestureState state;
  // Bare down on a glyph while admitted: consumed, queued, paired up eaten.
  assert(core::HitTestRequired(Down(false, true, false)));
  core::MouseMessageDecision d = core::DecideMouseMessage(Down(false, true, true),
                                                          &state);
  assert(d.swallow && d.submit && !d.request_dismiss);
  d = core::DecideMouseMessage(Up(false), &state);
  assert(d.swallow && !d.submit);
  // The up after a forwarded down is forwarded too.
  d = core::DecideMouseMessage(Up(false), &state);
  assert(!d.swallow);

  // Down on empty space: forwarded to the engine, so is its up.
  d = core::DecideMouseMessage(Down(false, true, false), &state);
  assert(!d.swallow && !d.submit);
  d = core::DecideMouseMessage(Up(false), &state);
  assert(!d.swallow);

  // Host has not admitted native input: never consume, never hit-test.
  assert(!core::HitTestRequired(Down(false, false, false)));
  d = core::DecideMouseMessage(Down(false, false, true), &state);
  assert(!d.swallow && !d.submit);

  // Modifier-qualified downs belong to the engine.
  core::MouseMessageInput shifted = Down(false, true, true);
  shifted.shift = true;
  assert(!core::HitTestRequired(shifted));
  d = core::DecideMouseMessage(shifted, &state);
  assert(!d.swallow && !d.submit);
  core::MouseMessageInput ctrl = Down(false, true, true);
  ctrl.ctrl = true;
  assert(!core::HitTestRequired(ctrl));
  core::MouseMessageInput alt = Down(false, true, true);
  alt.alt = true;
  assert(!core::HitTestRequired(alt));

  // Card open: every left down/up is eaten and the dismiss is requested,
  // regardless of admission or hit.
  assert(!core::HitTestRequired(Down(true, true, false)));
  d = core::DecideMouseMessage(Down(true, true, true), &state);
  assert(d.swallow && d.request_dismiss && !d.submit);
  d = core::DecideMouseMessage(Up(true), &state);
  assert(d.swallow);
  // Card closed between down and up: the paired up is still eaten once.
  d = core::DecideMouseMessage(Down(true, false, false), &state);
  assert(d.swallow && d.request_dismiss);
  d = core::DecideMouseMessage(Up(false), &state);
  assert(d.swallow);
  d = core::DecideMouseMessage(Up(false), &state);
  assert(!d.swallow);
  // An up while the card is open is eaten even without a tracked down.
  d = core::DecideMouseMessage(Up(true), &state);
  assert(d.swallow);

  // Other messages are never touched.
  core::MouseMessageInput other;
  other.kind = core::MouseMessageKind::kOther;
  other.shield_active = true;
  d = core::DecideMouseMessage(other, &state);
  assert(!d.swallow && !d.submit && !d.request_dismiss);
  assert(!core::DecideMouseMessage(Down(false, true, true), nullptr).swallow);
}

void TestShiftHoverDecisionTable() {
  core::MouseGestureState state;
  // Plain move: never swallowed, never hit-tested.
  assert(!core::HitTestRequired(Move(false, false, true, false)));
  core::MouseMessageDecision d =
      core::DecideMouseMessage(Move(false, false, true, true), &state);
  assert(!d.swallow && !d.submit);

  // Shift-move over a glyph publishes once per (generation, index).
  assert(core::HitTestRequired(Move(true, false, true, false)));
  d = core::DecideMouseMessage(Move(true, false, true, true, 1u, 4u), &state);
  assert(!d.swallow && d.submit);
  d = core::DecideMouseMessage(Move(true, false, true, true, 1u, 4u), &state);
  assert(!d.submit);
  d = core::DecideMouseMessage(Move(true, false, true, true, 1u, 5u), &state);
  assert(d.submit);
  // A republished paragraph with the same index is a new lookup.
  d = core::DecideMouseMessage(Move(true, false, true, true, 2u, 5u), &state);
  assert(d.submit);
  // Leaving the glyphs does not republish on the way back to the same one...
  d = core::DecideMouseMessage(Move(true, false, true, false), &state);
  assert(!d.submit);
  d = core::DecideMouseMessage(Move(true, false, true, true, 2u, 5u), &state);
  assert(!d.submit);
  // ...but releasing Shift resets the hover so the next Shift-hover resubmits.
  d = core::DecideMouseMessage(Move(false, false, true, true, 2u, 5u), &state);
  assert(!d.submit);
  d = core::DecideMouseMessage(Move(true, false, true, true, 2u, 5u), &state);
  assert(d.submit);

  // A visible card or a closed admission suppresses hover lookups.
  assert(!core::HitTestRequired(Move(true, true, true, false)));
  d = core::DecideMouseMessage(Move(true, true, true, true, 3u, 0u), &state);
  assert(!d.submit && !d.swallow);
  assert(!core::HitTestRequired(Move(true, false, false, false)));
  d = core::DecideMouseMessage(Move(true, false, false, true, 3u, 0u), &state);
  assert(!d.submit && !d.swallow);
}

void TestShieldMaskReducer() {
  static_assert(core::kOwnedShieldSurfaces == 0x81u,
                "smash owns EnginePrivate | Win32Messages");
  core::ShieldMasks masks = core::ReduceShieldMasks(false, true, true);
  assert(masks.required == 0u && masks.ready == 0u && masks.observed == 0u);
  masks = core::ReduceShieldMasks(true, false, true);
  assert(masks.required == core::kOwnedShieldSurfaces && masks.ready == 0u &&
         masks.observed == 0u);
  masks = core::ReduceShieldMasks(true, true, false);
  assert(masks.required == core::kOwnedShieldSurfaces &&
         masks.ready == core::kOwnedShieldSurfaces && masks.observed == 0u);
  masks = core::ReduceShieldMasks(true, true, true);
  assert(masks.observed == core::kOwnedShieldSurfaces);
}

void TestSharedContractHelpers() {
  const smash::StageProjection p = smash::ComputeStageProjection(1284, 1061);
  // Measured: 1284x1061 -> s = 1284/1920 = 0.66875 (width-bound).
  assert(p.valid && p.scale > 0.6687f && p.scale < 0.6688f);
  assert(p.offset_x == 0.0f && p.offset_y > 169.0f && p.offset_y < 170.0f);
  assert(!smash::ComputeStageProjection(0, 1080).valid);
  assert(smash::QuoteBalanceAfter(L"「ふん。", 4, 0) == 1);
  assert(smash::QuoteBalanceAfter(L"だが」", 3, 1) == 0);
  assert(smash::QuoteBalanceAfter(L"」", 1, 0) == 0);
}

}  // namespace

int main() {
  TestLayerLineRequestUsesSyntheticDesignAndMostInkedLine();
  TestProjectionEpochAndOriginCache();
  TestGeometryReadyFailsClosedOutsideClient();
  TestResolveHitMapsPointToUtf16IndexAndClientRect();
  TestClickDecisionTable();
  TestShiftHoverDecisionTable();
  TestShieldMaskReducer();
  TestSharedContractHelpers();
  std::puts("smash_fzmedia lookup test ok");
  return 0;
}
