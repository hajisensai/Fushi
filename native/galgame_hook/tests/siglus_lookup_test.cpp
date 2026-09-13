#ifdef NDEBUG
#undef NDEBUG
#endif

#include "../hook/adapters/siglus_lookup.h"
#include "../include/voice_hook_ipc.h"

#include <cassert>
#include <cstddef>
#include <cstdint>
#include <vector>

namespace {

using fushi_voice_hook::AppendSiglusLookupGlyphCapture;
using fushi_voice_hook::SiglusLookupGlyphCaptureBuffer;

void Push(char16_t code_unit, int32_t x, int32_t y,
          SiglusLookupGlyphCaptureBuffer *captures, int32_t extent = 40) {
  assert(AppendSiglusLookupGlyphCapture(code_unit, x, y, extent, captures));
}

void TestSplitRedrawLifetime() {
  using namespace fushi_voice_hook;
  const auto& profile = kAnemoiSiglusLookupProfile;
  SiglusLookupGlyphCaptureBuffer captures;
  SiglusLookupLayoutState state;
  Push(u'A', 100, 200, &captures);
  assert(!UpdateSiglusLookupLayout(profile, captures, u"ABC", 3, &state));
  assert(!state.current_valid && !state.line_has_complete_layout);
  SiglusLookupClickSampleState initial_press;
  AdvanceSiglusLookupClickSample(true, false, false, kSiglusLookupNoGlyph,
                                 &initial_press);
  auto edge = AdvanceSiglusLookupClickSample(
      true, true, false, kSiglusLookupNoGlyph, &initial_press);
  assert(!edge.consume && !edge.submit);
  AdvanceSiglusLookupClickSample(true, false, false, kSiglusLookupNoGlyph,
                                 &initial_press);
  Push(u'B', 140, 200, &captures);
  Push(u'C', 180, 200, &captures);
  assert(UpdateSiglusLookupLayout(profile, captures, u"ABC", 3, &state));
  assert(state.current_valid && state.line_has_complete_layout);
  const uint64_t committed_generation = state.generation;
  const uint64_t pressed_epoch = state.snapshot_epoch;
  assert(IsSiglusLookupLayoutSubmissionCurrent(state, committed_generation,
                                                pressed_epoch));

  SiglusLookupClickSampleState held;
  AdvanceSiglusLookupClickSample(true, false, false, 0, &held);
  edge = AdvanceSiglusLookupClickSample(true, true, false, 0, &held);
  assert(edge.consume && edge.begin);
  // The production consumer runs between A and BC of an identical redraw.
  Push(u'A', 100, 200, &captures);
  assert(!UpdateSiglusLookupLayout(profile, captures, u"ABC", 3, &state));
  assert(!state.current_valid && state.line_has_complete_layout);
  assert(state.generation == committed_generation);
  assert(!IsSiglusLookupLayoutSubmissionCurrent(state, committed_generation,
                                                 pressed_epoch));
  auto released_during_gap = held;
  edge = AdvanceSiglusLookupClickSample(true, false, false,
                                        kSiglusLookupNoGlyph,
                                        &released_during_gap);
  // The raw tail stays consumed, but the production publication gate rejects
  // this submit intent because no current click snapshot exists.
  assert(edge.consume && edge.submit);
  assert(!IsSiglusLookupLayoutSubmissionCurrent(state, committed_generation,
                                                 pressed_epoch));
  Push(u'B', 140, 200, &captures);
  Push(u'C', 180, 200, &captures);
  assert(UpdateSiglusLookupLayout(profile, captures, u"ABC", 3, &state));
  assert(state.line_has_complete_layout && state.current_valid);
  assert(state.generation == committed_generation);
  edge = AdvanceSiglusLookupClickSample(true, false, false,
                                        kSiglusLookupNoGlyph, &held);
  assert(edge.consume && edge.submit);
  // Recovery of identical geometry must not revive a pre-gap down payload.
  assert(!IsSiglusLookupLayoutSubmissionCurrent(state, committed_generation,
                                                 pressed_epoch));
  assert(IsSiglusLookupLayoutSubmissionCurrent(state, state.generation,
                                                state.snapshot_epoch));

  const uint64_t before_move = state.generation;
  Push(u'A', 300, 400, &captures);
  assert(!UpdateSiglusLookupLayout(profile, captures, u"ABC", 3, &state));
  assert(state.line_has_complete_layout && !state.current_valid);
  Push(u'B', 340, 400, &captures);
  Push(u'C', 380, 400, &captures);
  assert(UpdateSiglusLookupLayout(profile, captures, u"ABC", 3, &state));
  assert(state.generation == NextSiglusLookupLogicalGeneration(before_move));
  assert(state.geometry.glyphs[0].rect.x == 300);

  // A real sentence change revokes the committed lifetime before rebuilding.
  ResetSiglusLookupLayout(&state);
  Push(u'X', 100, 200, &captures);
  assert(!UpdateSiglusLookupLayout(profile, captures, u"XYZ", 3, &state));
  assert(!state.line_has_complete_layout && !state.current_valid);
  Push(u'Y', 140, 200, &captures);
  Push(u'Z', 180, 200, &captures);
  assert(UpdateSiglusLookupLayout(profile, captures, u"XYZ", 3, &state));
  // The worker uses the same reset on sensor, viewport, HWND or session loss,
  // and discards pre-loss captures. Merely restoring the sensor is not Ready.
  const uint64_t before_loss = state.generation;
  const uint64_t epoch_before_loss = state.snapshot_epoch;
  ResetSiglusLookupLayout(&state);
  ClearSiglusLookupGlyphCapture(&captures);
  assert(!UpdateSiglusLookupLayout(profile, captures, u"XYZ", 3, &state));
  assert(!state.line_has_complete_layout && !state.current_valid);
  assert(!IsSiglusLookupLayoutSubmissionCurrent(state, before_loss,
                                                 epoch_before_loss));
  auto wrong_viewport = profile;
  wrong_viewport.viewport_width = 0;
  assert(!UpdateSiglusLookupLayout(wrong_viewport, captures, u"XYZ", 3, &state));
  assert(!state.line_has_complete_layout);
}

void TestCommittedTextIdentityAcrossWriters() {
  using namespace fushi_voice_hook;
  const uint64_t region_bytes = TextRegionBytes(kTextLaneCount, kTextLaneSlotCount);
  std::vector<uint8_t> mapping(
      static_cast<size_t>(sizeof(SharedHeader) + region_bytes), 0);
  auto* header = reinterpret_cast<SharedHeader*>(mapping.data());
  header->magic = kSharedMagic;
  header->version = kSharedVersion;
  header->text_region_offset = sizeof(SharedHeader);
  header->text_lane_count = kTextLaneCount;
  header->text_lane_slot_count = kTextLaneSlotCount;
  const auto write = [header](uint64_t thread, uint32_t source,
                              uint32_t begin, uint32_t end) {
    TextLaneWrite entry;
    entry.thread_id = thread;
    entry.source_kind = source;
    entry.event_kind = kTextEventLine;
    entry.text = L"ABC";
    entry.byte_len = 3 * sizeof(wchar_t);
    return WriteTextLaneEvent(header, begin, end, entry);
  };
  const uint64_t native_seq = write(101, kTextSourceSiglus,
                                    kNativeThreadPreviewStart, kTextLaneCount);
  const SiglusLookupTextIdentity native{native_seq, 101};
  assert(native_seq == 1);
  // A concurrent writer advances the shared counter before lookup publishes.
  const uint64_t luna_seq = write(202, kTextSourceLuna,
                                  0, kNativeThreadPreviewStart);
  const SiglusLookupTextIdentity luna{luna_seq, 202};
  assert(luna_seq == 2 && header->text_write_count == luna_seq);
  assert(IsSiglusLookupTextIdentityCurrent(native, {native_seq, 101}));
  assert(!IsSiglusLookupTextIdentityCurrent(native,
                                            {header->text_write_count, 101}));
  assert(!IsSiglusLookupTextIdentityCurrent(native, luna));
  assert(!IsSiglusLookupTextIdentityCurrent(native, {native_seq, 202}));
  assert(!IsSiglusLookupTextIdentityCurrent({0, 101}, {0, 101}));
  assert(!IsSiglusLookupTextIdentityCurrent({native_seq, 0}, {native_seq, 0}));
  assert(WriteTextLaneEvent(nullptr, 0, kTextLaneCount, TextLaneWrite{}) == 0);

  // Luna lookup carries the already committed stable slot, not a private
  // sequence and not an event with the same string from another thread.
  const TextSlot* slots[kTextSlotCount] = {};
  const uint32_t found = CollectTextSlotsBySeq(header, slots, kTextSlotCount, 0);
  bool luna_found = false;
  for (uint32_t i = 0; i < found; ++i) {
    if (slots[i]->source_kind == kTextSourceLuna) {
      luna_found = true;
      const SiglusLookupTextIdentity captured{slots[i]->seq, slots[i]->thread_id};
      assert(IsSiglusLookupTextIdentityCurrent(captured, luna));
      assert(!IsSiglusLookupTextIdentityCurrent(captured, native));
    }
  }
  assert(luna_found);

  // The real LOOPERS PLUS failure: layout 20, only committed text event 1.
  SiglusLookupGlyphCaptureBuffer captures;
  Push(u'A', 100, 200, &captures);
  Push(u'B', 140, 200, &captures);
  Push(u'C', 180, 200, &captures);
  SiglusLookupLayoutState layout;
  layout.generation = 19;
  assert(UpdateSiglusLookupLayout(kAnemoiSiglusLookupProfile, captures,
                                   u"ABC", 3, &layout));
  assert(layout.generation == 20 && native.event_id == 1);
  assert(!IsSiglusLookupTextIdentityCurrent({layout.generation, 101}, native));
  const uint64_t repeated_seq = write(101, kTextSourceSiglus,
                                      kNativeThreadPreviewStart, kTextLaneCount);
  assert(repeated_seq > luna_seq);
  const SiglusLookupTextIdentity repeated{repeated_seq, 101};
  assert(!IsSiglusLookupTextIdentityCurrent(native, repeated));
  assert(IsSiglusLookupTextIdentityCurrent(repeated, repeated));
  // Identical text/layout never makes a different occurrence interchangeable.
  assert(UpdateSiglusLookupLayout(kAnemoiSiglusLookupProfile, captures,
                                   u"ABC", 3, &layout));
  assert(layout.generation == 20);
  assert(!IsSiglusLookupTextIdentityCurrent(native, repeated));
}

} // namespace

int main() {
  using namespace fushi_voice_hook;
  TestSplitRedrawLifetime();
  TestCommittedTextIdentityAcrossWriters();

  assert(IsSiglusLookupResolutionPending(0));
  assert(IsSiglusLookupResolutionPending(2));
  assert(!IsSiglusLookupResolutionPending(1));
  assert(!IsSiglusLookupResolutionPending(-1));

  const auto &profile = kAnemoiSiglusLookupProfile;
  assert(profile.pe_machine == kSiglusLookupPeMachineI386);
  assert(profile.text_feed == SiglusLookupTextFeed::kNativeEcxTextUnion);
  assert(profile.input_message_rva == 0x2C1AC0u);
  assert(profile.main_input_message_return_rva == 0x2B393Fu);
  assert(profile.pointer_bits == 32u);
  assert(profile.glyph_layout_rva == 0x1EC1C0u);
  assert(profile.dialogue_glyph_return_rva == 0x1EDC5Cu);
  assert(profile.exact_text_rva == 0x25C880u);
  assert(profile.exact_text_return_rva == 0x25A650u);
  assert(profile.get_key_state_return_rva == 0x2C16C3u);
  assert(profile.viewport_width == 1920 && profile.viewport_height == 1080);
  assert(MatchesSiglusLookupProfile(profile, profile.executable_sha256.data(),
                                    profile.executable_sha256.size(),
                                    kSiglusLookupPeMachineI386));
  assert(MatchesSiglusLookupProfile(profile, profile.runtime_view_sha256.data(),
                                    profile.runtime_view_sha256.size(),
                                    kSiglusLookupPeMachineI386));
  auto wrong_hash = profile.executable_sha256;
  wrong_hash[17] ^= 0x80u;
  assert(!MatchesSiglusLookupProfile(profile, wrong_hash.data(),
                                     wrong_hash.size(),
                                     kSiglusLookupPeMachineI386));
  assert(!MatchesSiglusLookupProfile(profile, profile.executable_sha256.data(),
                                     profile.executable_sha256.size(),
                                     0x8664u));
  assert(!MatchesSiglusLookupProfile(profile, nullptr, 0,
                                     kSiglusLookupPeMachineI386));

  const auto &sprb_profile =
      kSummerPocketsReflectionBlueSiglusLookupProfile;
  assert(sprb_profile.pe_machine == kSiglusLookupPeMachineI386);
  assert(sprb_profile.pointer_bits == 32u);
  assert(sprb_profile.text_feed == SiglusLookupTextFeed::kLunaScenarioLane);
  assert(sprb_profile.glyph_layout_rva == 0x1DC690u);
  assert(sprb_profile.dialogue_glyph_return_rva == 0x1DE25Cu);
  assert(sprb_profile.exact_text_rva == 0x1DECF0u);
  assert(sprb_profile.exact_text_return_rva == 0u);
  assert(sprb_profile.get_key_state_return_rva == 0x2B3D63u);
  assert(sprb_profile.input_message_rva == 0x2B3EE0u);
  assert(sprb_profile.main_input_message_return_rva == 0x2A8247u);
  assert(sprb_profile.viewport_width == 1920 &&
         sprb_profile.viewport_height == 1080);
  assert(MatchesSiglusLookupProfile(
      sprb_profile, sprb_profile.executable_sha256.data(),
      sprb_profile.executable_sha256.size(), kSiglusLookupPeMachineI386));
  assert(FindSiglusLookupProfile(profile.executable_sha256.data(),
                                 profile.executable_sha256.size(),
                                 kSiglusLookupPeMachineI386) == &profile);
  assert(FindSiglusLookupProfile(profile.runtime_view_sha256.data(),
                                 profile.runtime_view_sha256.size(),
                                 kSiglusLookupPeMachineI386) == &profile);
  assert(FindSiglusLookupProfile(sprb_profile.executable_sha256.data(),
                                 sprb_profile.executable_sha256.size(),
                                 kSiglusLookupPeMachineI386) == &sprb_profile);

  // Hashes never cross profile boundaries, and family/architecture identity
  // cannot admit an unknown binary.
  assert(!MatchesSiglusLookupProfile(
      profile, sprb_profile.executable_sha256.data(),
      sprb_profile.executable_sha256.size(), kSiglusLookupPeMachineI386));
  assert(!MatchesSiglusLookupProfile(
      sprb_profile, profile.executable_sha256.data(),
      profile.executable_sha256.size(), kSiglusLookupPeMachineI386));
  assert(FindSiglusLookupProfile(sprb_profile.executable_sha256.data(),
                                 sprb_profile.executable_sha256.size(),
                                 0x8664u) == nullptr);
  auto unknown_hash = sprb_profile.executable_sha256;
  unknown_hash[0] ^= 0x01u;
  assert(FindSiglusLookupProfile(unknown_hash.data(), unknown_hash.size(),
                                 kSiglusLookupPeMachineI386) == nullptr);
  assert(FindSiglusLookupProfile(nullptr, 0, kSiglusLookupPeMachineI386) ==
         nullptr);

  // Native ECX/TextUnion requires its admitted return callsite. The Luna
  // Scenario lane does not, but still requires its own exact feed RVA.
  auto invalid_native_feed = profile;
  invalid_native_feed.exact_text_return_rva = 0;
  assert(!MatchesSiglusLookupProfile(
      invalid_native_feed, invalid_native_feed.executable_sha256.data(),
      invalid_native_feed.executable_sha256.size(),
      kSiglusLookupPeMachineI386));
  auto invalid_luna_feed = sprb_profile;
  invalid_luna_feed.exact_text_rva = 0;
  assert(!MatchesSiglusLookupProfile(
      invalid_luna_feed, invalid_luna_feed.executable_sha256.data(),
      invalid_luna_feed.executable_sha256.size(),
      kSiglusLookupPeMachineI386));
  auto unknown_text_feed = sprb_profile;
  unknown_text_feed.text_feed = static_cast<SiglusLookupTextFeed>(0);
  assert(!MatchesSiglusLookupProfile(
      unknown_text_feed, unknown_text_feed.executable_sha256.data(),
      unknown_text_feed.executable_sha256.size(),
      kSiglusLookupPeMachineI386));

  SiglusLookupGlyphCaptureBuffer captures;
  // An older unrelated renderer fragment must not make a partial match pass.
  Push(u'メ', 10, 10, &captures);
  Push(u'ニ', 50, 10, &captures);
  Push(u'ュ', 90, 10, &captures);

  // Exact UTF-16 line: full-width and half-width glyphs share two visual rows.
  // Renderer capture contains no CR/LF glyph, while char_index still points
  // into the original string (the second row therefore starts at index 5).
  constexpr char16_t kLine[] = u"全A角\r\n半BC";
  Push(u'全', 100, 200, &captures);
  Push(u'A', 140, 200, &captures); // A advances 20 (half width).
  Push(u'角', 160, 200, &captures);
  Push(u'半', 100, 250, &captures);
  Push(u'B', 140, 250, &captures); // B advances 20 (half width).
  Push(u'C', 160, 250, &captures);

  SiglusLookupGeometry geometry;
  assert(BuildSiglusLookupGeometry(profile, captures, kLine,
                                   std::size(kLine) - 1u, &geometry));
  assert(geometry.viewport_width == 1920 && geometry.viewport_height == 1080);
  assert(geometry.glyph_count == 6u);
  assert(geometry.glyphs[0].char_index == 0u);
  assert(geometry.glyphs[2].char_index == 2u);
  assert(geometry.glyphs[3].char_index == 5u);
  assert(geometry.glyphs[0].visual_line == 0u);
  assert(geometry.glyphs[3].visual_line == 1u);
  assert(geometry.glyphs[0].rect.width == 40);
  assert(geometry.glyphs[1].rect.width == 20);
  assert(geometry.glyphs[3].rect.width == 40);
  assert(geometry.glyphs[4].rect.width == 20);
  // Row spacing is 50, but the engine's measured glyph extent is 40.
  assert(geometry.glyphs[0].rect.height == 40);
  assert(geometry.glyphs[5].rect.height == 40);

  SiglusLookupGlyphRect hit;
  assert(FindSiglusLookupGlyph(geometry, 145, 210, &hit) == 1);
  assert(hit.code_unit == u'A' && hit.char_index == 1u);
  assert(FindSiglusLookupGlyph(geometry, 100, 251, &hit) == 3);
  assert(hit.code_unit == u'半' && hit.char_index == 5u);
  assert(FindSiglusLookupGlyph(geometry, 20, 20, &hit) == -1);

  // Redraws can leave more than one complete copy in the ring. Geometry must
  // bind to the newest exact copy, not a stale occurrence with the same text.
  SiglusLookupGlyphCaptureBuffer repeated;
  constexpr char16_t kRepeated[] = u"同文";
  Push(u'同', 10, 20, &repeated);
  Push(u'文', 50, 20, &repeated);
  Push(u'同', 500, 600, &repeated);
  Push(u'文', 540, 600, &repeated);
  size_t matched_end = 0;
  assert(BuildSiglusLookupGeometry(profile, repeated, kRepeated,
                                   std::size(kRepeated) - 1u, &geometry,
                                   &matched_end));
  assert(matched_end == repeated.count);
  assert(geometry.glyphs[0].rect.x == 500 && geometry.glyphs[0].rect.y == 600);
  // Once the next frame starts, an older complete copy may still be found,
  // but production must observe that it is no longer the newest full layout.
  Push(u'同', 700, 800, &repeated);
  assert(BuildSiglusLookupGeometry(profile, repeated, kRepeated,
                                   std::size(kRepeated) - 1u, &geometry,
                                   &matched_end));
  assert(matched_end < repeated.count);

  // Matching is exact and contiguous: a changed code unit and an interleaved
  // renderer event are both rejected rather than normalized or guessed.
  constexpr char16_t kWrongLine[] = u"全A隅\r\n半BC";
  assert(!BuildSiglusLookupGeometry(profile, captures, kWrongLine,
                                    std::size(kWrongLine) - 1u, &geometry));
  SiglusLookupGlyphCaptureBuffer interleaved;
  Push(u'全', 100, 200, &interleaved);
  Push(u'A', 140, 200, &interleaved);
  Push(u'別', 150, 200, &interleaved);
  Push(u'角', 160, 200, &interleaved);
  Push(u'半', 100, 250, &interleaved);
  Push(u'B', 140, 250, &interleaved);
  Push(u'C', 160, 250, &interleaved);
  assert(!BuildSiglusLookupGeometry(profile, interleaved, kLine,
                                    std::size(kLine) - 1u, &geometry));

  // An automatic wrap has no newline code unit. The x reset/y change still
  // starts a new visual row, and single-row fallback height uses the median
  // horizontal advance when no row spacing exists.
  SiglusLookupGlyphCaptureBuffer wrapped;
  constexpr char16_t kWrapped[] = u"日本語A";
  Push(u'日', 300, 400, &wrapped);
  Push(u'本', 340, 400, &wrapped);
  Push(u'語', 300, 448, &wrapped);
  Push(u'A', 340, 448, &wrapped);
  assert(BuildSiglusLookupGeometry(profile, wrapped, kWrapped,
                                   std::size(kWrapped) - 1u, &geometry));
  assert(geometry.glyphs[1].visual_line == 0u);
  assert(geometry.glyphs[2].visual_line == 1u);
  assert(geometry.glyphs[0].rect.height == 40);

  SiglusLookupGlyphCaptureBuffer single_row;
  constexpr char16_t kSingleRow[] = u"ABCD";
  Push(u'A', 20, 30, &single_row);
  Push(u'B', 40, 30, &single_row);
  Push(u'C', 80, 30, &single_row);
  Push(u'D', 120, 30, &single_row);
  assert(BuildSiglusLookupGeometry(profile, single_row, kSingleRow,
                                   std::size(kSingleRow) - 1u, &geometry));
  assert(geometry.glyphs[0].rect.width == 20);
  assert(geometry.glyphs[1].rect.width == 40);
  assert(geometry.glyphs[0].rect.height == 40); // measured glyph extent.

  // Runtime PMv2 evidence for the exact target: design (410,848,38,38) maps
  // into a 2232x1255 physical client. An external DPI-unaware observer sees
  // half those dimensions, so direct raw-coordinate comparison would miss.
  SiglusLookupRect physical;
  assert(ScaleSiglusLookupRectToClient(profile, {410, 848, 38, 38}, 2232, 1255,
                                       &physical));
  assert(physical.x == 477 && physical.y == 985);
  assert(physical.width == 44 && physical.height == 44);

  // Fixed-capacity capture discards only the oldest entries. A newest exact
  // suffix remains available without allocating in the callback path.
  SiglusLookupGlyphCaptureBuffer bounded;
  for (size_t index = 0; index < kSiglusLookupCaptureCapacity + 17u; ++index) {
    Push(u'雑', static_cast<int32_t>(index % 100u), 10, &bounded);
  }
  assert(bounded.count == kSiglusLookupCaptureCapacity);
  Push(u'新', 100, 100, &bounded);
  Push(u'行', 140, 100, &bounded);
  constexpr char16_t kNewest[] = u"新行";
  assert(BuildSiglusLookupGeometry(profile, bounded, kNewest,
                                   std::size(kNewest) - 1u, &geometry));
  assert(geometry.glyph_count == 2u && geometry.glyphs[0].char_index == 0u);
  assert(!AppendSiglusLookupGlyphCapture(u'\n', 0, 0, 40, &bounded));

  SiglusLookupClickSampleState click;
  // Installation while physically held passes through until a real up.
  auto decision = AdvanceSiglusLookupClickSample(true, true, false, 2u, &click);
  assert(!decision.consume && !click.synchronized);
  decision = AdvanceSiglusLookupClickSample(true, false, false, kSiglusLookupNoGlyph,
                                            &click);
  assert(!decision.consume && click.synchronized);

  // A miss remains pass-through even if the cursor later becomes a hit while
  // the same physical press is held.
  decision =
      AdvanceSiglusLookupClickSample(true, true, false, kSiglusLookupNoGlyph, &click);
  assert(!decision.consume &&
         click.owner == SiglusLookupClickOwner::kPassThrough);
  decision = AdvanceSiglusLookupClickSample(true, true, false, 4u, &click);
  assert(!decision.consume);
  decision = AdvanceSiglusLookupClickSample(true, false, false, 4u, &click);
  assert(!decision.consume && !decision.submit &&
         click.owner == SiglusLookupClickOwner::kIdle);

  // A fresh hit consumes down/hold/up and submits the glyph owned at down.
  decision = AdvanceSiglusLookupClickSample(true, true, false, 3u, &click);
  assert(decision.consume && decision.begin && !decision.submit &&
         decision.glyph_index == 3u);
  assert(FilterSiglusLookupGetKeyState(static_cast<int16_t>(0x8001u),
                                       decision.consume) == 1);
  decision = AdvanceSiglusLookupClickSample(true, true, true, 5u, &click);
  assert(decision.consume && !decision.begin && !decision.submit &&
         !decision.popup_transaction && decision.glyph_index == 3u);
  decision = AdvanceSiglusLookupClickSample(true, false, false, kSiglusLookupNoGlyph,
                                            &click);
  assert(decision.consume && decision.submit && decision.glyph_index == 3u);

  // Popup ownership also latches through physical up after the popup closes,
  // but it never turns into a word submission.
  decision =
      AdvanceSiglusLookupClickSample(true, true, true, kSiglusLookupNoGlyph, &click);
  assert(decision.consume && decision.begin && decision.popup_transaction);
  decision =
      AdvanceSiglusLookupClickSample(true, true, false, kSiglusLookupNoGlyph, &click);
  assert(decision.consume && decision.popup_transaction && !decision.submit);
  decision = AdvanceSiglusLookupClickSample(true, false, false, kSiglusLookupNoGlyph,
                                            &click);
  assert(decision.consume && decision.popup_transaction && !decision.submit);
  assert(click.owner == SiglusLookupClickOwner::kIdle);
  assert(FilterSiglusLookupGetKeyState(static_cast<int16_t>(0x8001u), false) ==
         static_cast<int16_t>(0x8001u));

  // The independent main-window message sink must never receive either edge
  // of an admitted lookup click. Misses remain ordinary game input.
  auto message_decision = DecideSiglusLookupMouseMessage(true,
      kSiglusLookupWmLeftButtonDown, false, true, false);
  assert(message_decision.consume && message_decision.next_latched);
  message_decision = DecideSiglusLookupMouseMessage(true,
      kSiglusLookupWmLeftButtonUp, false, false, message_decision.next_latched);
  assert(message_decision.consume && !message_decision.next_latched);
  message_decision = DecideSiglusLookupMouseMessage(true,
      kSiglusLookupWmLeftButtonDown, false, false, false);
  assert(!message_decision.consume && !message_decision.next_latched);

  // Popup dismissal and a double-click's second transaction are also held to
  // their matching up even if visibility changes in between.
  message_decision = DecideSiglusLookupMouseMessage(true,
      kSiglusLookupWmLeftButtonDown, true, false, false);
  assert(message_decision.consume && message_decision.next_latched);
  message_decision = DecideSiglusLookupMouseMessage(true,
      kSiglusLookupWmLeftButtonUp, false, false, message_decision.next_latched);
  assert(message_decision.consume && !message_decision.next_latched);
  message_decision = DecideSiglusLookupMouseMessage(true,
      kSiglusLookupWmLeftButtonDoubleClick, false, true, false);
  assert(message_decision.consume && message_decision.next_latched);
  message_decision = DecideSiglusLookupMouseMessage(true,
      kSiglusLookupWmLeftButtonUp, false, false, message_decision.next_latched);
  assert(message_decision.consume && !message_decision.next_latched);

  // A down that reached the engine must have its up reach the engine too, even
  // if the popup opened in between on the worker tick. Otherwise Siglus keeps a
  // left button that never comes back up.
  message_decision = DecideSiglusLookupMouseMessage(true,
      kSiglusLookupWmLeftButtonDown, false, false, false);
  assert(!message_decision.consume && !message_decision.next_latched);
  message_decision = DecideSiglusLookupMouseMessage(true,
      kSiglusLookupWmLeftButtonUp, true, false, message_decision.next_latched);
  assert(!message_decision.consume && !message_decision.next_latched);

  // A lost up (alt-tab, WM_CANCELMODE, drag out of the window) must not turn the
  // latch into a permanent left-button sink: the next down is judged on its own
  // merits and republishes the latch from scratch.
  message_decision = DecideSiglusLookupMouseMessage(true,
      kSiglusLookupWmLeftButtonDown, false, false, true);
  assert(!message_decision.consume && !message_decision.next_latched);
  message_decision = DecideSiglusLookupMouseMessage(true,
      kSiglusLookupWmLeftButtonUp, false, false, message_decision.next_latched);
  assert(!message_decision.consume && !message_decision.next_latched);
  message_decision = DecideSiglusLookupMouseMessage(true,
      kSiglusLookupWmLeftButtonDoubleClick, false, false, true);
  assert(!message_decision.consume && !message_decision.next_latched);

  // A valid glyph does not grant semantic input permission. This models
  // attachedOnly, an unapplied allow, deny, and a different active provider.
  SiglusLookupClickSampleState denied_click;
  decision = AdvanceSiglusLookupClickSample(
      false, false, false, kSiglusLookupNoGlyph, &denied_click);
  decision = AdvanceSiglusLookupClickSample(
      false, true, false, 3u, &denied_click);
  assert(!decision.consume && !decision.submit &&
         denied_click.owner == SiglusLookupClickOwner::kPassThrough);
  // Allow arriving during an already passed-through press cannot steal it.
  decision = AdvanceSiglusLookupClickSample(
      true, true, false, 3u, &denied_click);
  assert(!decision.consume && !decision.submit);
  decision = AdvanceSiglusLookupClickSample(
      true, false, false, 3u, &denied_click);
  assert(!decision.consume && !decision.submit);

  decision = AdvanceSiglusLookupClickSample(
      true, true, false, 3u, &denied_click);
  assert(decision.consume && decision.begin);
  // Revocation after an owned down cancels the submission, never its tail.
  decision = AdvanceSiglusLookupClickSample(
      false, true, false, 3u, &denied_click);
  assert(decision.consume && !decision.submit);
  decision = AdvanceSiglusLookupClickSample(
      false, false, false, 3u, &denied_click);
  assert(decision.consume && !decision.submit &&
         denied_click.owner == SiglusLookupClickOwner::kIdle);
  decision = AdvanceSiglusLookupClickSample(
      false, true, false, 3u, &denied_click);
  assert(!decision.consume);
  AdvanceSiglusLookupClickSample(
      false, false, false, 3u, &denied_click);
  // A committed popup remains protected even if native glyph input is denied.
  decision = AdvanceSiglusLookupClickSample(
      false, true, true, kSiglusLookupNoGlyph, &denied_click);
  assert(decision.consume && decision.popup_transaction);
  decision = AdvanceSiglusLookupClickSample(
      false, false, false, kSiglusLookupNoGlyph, &denied_click);
  assert(decision.consume && !decision.submit &&
         denied_click.owner == SiglusLookupClickOwner::kIdle);

  message_decision = DecideSiglusLookupMouseMessage(
      false, kSiglusLookupWmLeftButtonDown, false, true, false);
  assert(!message_decision.consume && !message_decision.next_latched);
  message_decision = DecideSiglusLookupMouseMessage(
      true, kSiglusLookupWmLeftButtonUp, false, true,
      message_decision.next_latched);
  assert(!message_decision.consume);
  message_decision = DecideSiglusLookupMouseMessage(
      true, kSiglusLookupWmLeftButtonDown, false, true, false);
  assert(message_decision.consume && message_decision.next_latched);
  message_decision = DecideSiglusLookupMouseMessage(
      false, kSiglusLookupWmLeftButtonUp, false, false,
      message_decision.next_latched);
  assert(message_decision.consume && !message_decision.next_latched);
  message_decision = DecideSiglusLookupMouseMessage(
      false, kSiglusLookupWmLeftButtonDoubleClick, false, true, true);
  assert(!message_decision.consume && !message_decision.next_latched);
  message_decision = DecideSiglusLookupMouseMessage(
      false, kSiglusLookupWmLeftButtonDown, true, false, false);
  assert(message_decision.consume && message_decision.next_latched);
  message_decision = DecideSiglusLookupMouseMessage(
      false, kSiglusLookupWmLeftButtonUp, false, false,
      message_decision.next_latched);
  assert(message_decision.consume && !message_decision.next_latched);

  bool last_shift_down = false;
  assert(!ConsumeSiglusLookupShiftSample(0x0000u, &last_shift_down));
  assert(ConsumeSiglusLookupShiftSample(0x8001u, &last_shift_down));
  assert(last_shift_down);
  assert(!ConsumeSiglusLookupShiftSample(0x8000u, &last_shift_down));
  assert(!ConsumeSiglusLookupShiftSample(0x0000u, &last_shift_down));
  assert(!last_shift_down);
  // A full tap between polls is still a single rising edge via the low bit.
  assert(ConsumeSiglusLookupShiftSample(0x0001u, &last_shift_down));
  assert(!last_shift_down);
  assert(!ConsumeSiglusLookupShiftSample(0x0000u, nullptr));

  // Renderer events may repeat every frame. A production generation is stable
  // for identical text+geometry and only advances for a real logical layout
  // change. The down payload must also retain the exact client transform.
  const SiglusLookupGeometry stable_geometry = geometry;
  assert(SameSiglusLookupGeometry(stable_geometry, geometry));
  auto moved_geometry = geometry;
  assert(moved_geometry.glyph_count != 0);
  ++moved_geometry.glyphs[0].rect.x;
  assert(!SameSiglusLookupGeometry(stable_geometry, moved_geometry));
  assert(NextSiglusLookupLogicalGeneration(0) == 1);
  assert(NextSiglusLookupLogicalGeneration(UINT64_MAX) == 1);
  const SiglusLookupClientSnapshot stable_client = {
      0x1234u, -1920, 40, 1920, 1080};
  assert(MatchesSiglusLookupGenerationAndClient(7, stable_client, 7,
                                                stable_client));
  auto resized_client = stable_client;
  ++resized_client.width;
  assert(!MatchesSiglusLookupGenerationAndClient(7, stable_client, 7,
                                                 resized_client));
  assert(!MatchesSiglusLookupGenerationAndClient(7, stable_client, 8,
                                                 stable_client));

  SiglusLookupProfile legacy = kAnemoiSiglusLookupProfile;
  for (unsigned families = 0; families < 16; ++families) {
    assert(HasUniqueSiglusLookupFamily((families & 1) != 0, (families & 2) != 0,
                                      (families & 4) != 0, (families & 8) != 0) ==
           (families == 1 || families == 2 || families == 4 || families == 8));
  }
  legacy.glyph_abi = SiglusGlyphLayoutAbi::kStackSixteenArguments;
  legacy.viewport_width = 1280;
  legacy.viewport_height = 720;
  SiglusLookupEngineView actual_view{0x123400, {10, 20, 2560, 720}};
  SiglusLookupRect projected;
  assert(ProjectSiglusLookupRect(legacy, actual_view, {240, 560, 30, 30},
                                3000, 1000, &projected));
  assert(projected.x == 490 && projected.y == 580 &&
         projected.width == 60 && projected.height == 30);
  actual_view.viewport = {-250, -570, 1280, 720};
  assert(ProjectSiglusLookupRect(legacy, actual_view, {240, 560, 30, 30},
                                3000, 1000, &projected));
  assert(projected.x == 0 && projected.y == 0 &&
         projected.width == 20 && projected.height == 20);
  actual_view.viewport = {INT32_MAX, 0, INT32_MAX, INT32_MAX};
  assert(!ProjectSiglusLookupRect(legacy, actual_view, {240, 560, 30, 30},
                                 3000, 1000, &projected));
  assert(projected.width == 0);
  actual_view.viewport = {0, 0, 1280, 720};
  assert(!ProjectSiglusLookupRect(legacy, actual_view, {1279, 0, 30, 30},
                                 3000, 1000, &projected));
  assert(!ProjectSiglusLookupRect(legacy, {}, {240, 560, 30, 30},
                                 3000, 1000, &projected));
  assert(!ProjectSiglusLookupRect(kAnemoiSiglusLookupProfile, actual_view,
                                 {240, 560, 30, 30}, 3000, 1000, &projected));

  auto eightarg = legacy;
  eightarg.glyph_abi = SiglusGlyphLayoutAbi::kEcxEightArguments;
  assert(!ProjectSiglusLookupRect(eightarg, actual_view, {285,572,26,26},
                                 1280,720,&projected));
  actual_view.occurrence = 7;
  assert(ProjectSiglusLookupRect(eightarg, actual_view, {285,572,26,26},
                                1280,720,&projected));
  assert(projected.x == 285 && projected.y == 572 && projected.width == 26);
  // Engine viewport is in client logical pixels; DPI conversion is downstream.
  actual_view.viewport = {40,20,960,540};
  assert(ProjectSiglusLookupRect(eightarg, actual_view, {284,572,28,28},
                                1280,720,&projected));
  assert(projected.x == 253 && projected.y == 449 &&
         projected.width == 21 && projected.height == 21);
  auto next_view = actual_view;
  ++next_view.occurrence;
  assert(!SameSiglusLookupEngineView(actual_view, next_view));

  return 0;
}
