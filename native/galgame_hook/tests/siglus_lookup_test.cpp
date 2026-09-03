#ifdef NDEBUG
#undef NDEBUG
#endif

#include "../hook/adapters/siglus_lookup.h"

#include <cassert>
#include <cstddef>
#include <cstdint>

namespace {

using fushi_voice_hook::AppendSiglusLookupGlyphCapture;
using fushi_voice_hook::SiglusLookupGlyphCaptureBuffer;

void Push(char16_t code_unit, int32_t x, int32_t y,
          SiglusLookupGlyphCaptureBuffer *captures, int32_t extent = 40) {
  assert(AppendSiglusLookupGlyphCapture(code_unit, x, y, extent, captures));
}

} // namespace

int main() {
  using namespace fushi_voice_hook;

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
  auto decision = AdvanceSiglusLookupClickSample(true, false, 2u, &click);
  assert(!decision.consume && !click.synchronized);
  decision = AdvanceSiglusLookupClickSample(false, false, kSiglusLookupNoGlyph,
                                            &click);
  assert(!decision.consume && click.synchronized);

  // A miss remains pass-through even if the cursor later becomes a hit while
  // the same physical press is held.
  decision =
      AdvanceSiglusLookupClickSample(true, false, kSiglusLookupNoGlyph, &click);
  assert(!decision.consume &&
         click.owner == SiglusLookupClickOwner::kPassThrough);
  decision = AdvanceSiglusLookupClickSample(true, false, 4u, &click);
  assert(!decision.consume);
  decision = AdvanceSiglusLookupClickSample(false, false, 4u, &click);
  assert(!decision.consume && !decision.submit &&
         click.owner == SiglusLookupClickOwner::kIdle);

  // A fresh hit consumes down/hold/up and submits the glyph owned at down.
  decision = AdvanceSiglusLookupClickSample(true, false, 3u, &click);
  assert(decision.consume && decision.begin && !decision.submit &&
         decision.glyph_index == 3u);
  assert(FilterSiglusLookupGetKeyState(static_cast<int16_t>(0x8001u),
                                       decision.consume) == 1);
  decision = AdvanceSiglusLookupClickSample(true, true, 5u, &click);
  assert(decision.consume && !decision.begin && !decision.submit &&
         !decision.popup_transaction && decision.glyph_index == 3u);
  decision = AdvanceSiglusLookupClickSample(false, false, kSiglusLookupNoGlyph,
                                            &click);
  assert(decision.consume && decision.submit && decision.glyph_index == 3u);

  // Popup ownership also latches through physical up after the popup closes,
  // but it never turns into a word submission.
  decision =
      AdvanceSiglusLookupClickSample(true, true, kSiglusLookupNoGlyph, &click);
  assert(decision.consume && decision.begin && decision.popup_transaction);
  decision =
      AdvanceSiglusLookupClickSample(true, false, kSiglusLookupNoGlyph, &click);
  assert(decision.consume && decision.popup_transaction && !decision.submit);
  decision = AdvanceSiglusLookupClickSample(false, false, kSiglusLookupNoGlyph,
                                            &click);
  assert(decision.consume && decision.popup_transaction && !decision.submit);
  assert(click.owner == SiglusLookupClickOwner::kIdle);
  assert(FilterSiglusLookupGetKeyState(static_cast<int16_t>(0x8001u), false) ==
         static_cast<int16_t>(0x8001u));

  // The independent main-window message sink must never receive either edge
  // of an admitted lookup click. Misses remain ordinary game input.
  auto message_decision = DecideSiglusLookupMouseMessage(
      kSiglusLookupWmLeftButtonDown, false, true, false);
  assert(message_decision.consume && message_decision.next_latched);
  message_decision = DecideSiglusLookupMouseMessage(
      kSiglusLookupWmLeftButtonUp, false, false, message_decision.next_latched);
  assert(message_decision.consume && !message_decision.next_latched);
  message_decision = DecideSiglusLookupMouseMessage(
      kSiglusLookupWmLeftButtonDown, false, false, false);
  assert(!message_decision.consume && !message_decision.next_latched);

  // Popup dismissal and a double-click's second transaction are also held to
  // their matching up even if visibility changes in between.
  message_decision = DecideSiglusLookupMouseMessage(
      kSiglusLookupWmLeftButtonDown, true, false, false);
  assert(message_decision.consume && message_decision.next_latched);
  message_decision = DecideSiglusLookupMouseMessage(
      kSiglusLookupWmLeftButtonUp, false, false, message_decision.next_latched);
  assert(message_decision.consume && !message_decision.next_latched);
  message_decision = DecideSiglusLookupMouseMessage(
      kSiglusLookupWmLeftButtonDoubleClick, false, true, false);
  assert(message_decision.consume && message_decision.next_latched);
  message_decision = DecideSiglusLookupMouseMessage(
      kSiglusLookupWmLeftButtonUp, false, false, message_decision.next_latched);
  assert(message_decision.consume && !message_decision.next_latched);

  // A down that reached the engine must have its up reach the engine too, even
  // if the popup opened in between on the worker tick. Otherwise Siglus keeps a
  // left button that never comes back up.
  message_decision = DecideSiglusLookupMouseMessage(
      kSiglusLookupWmLeftButtonDown, false, false, false);
  assert(!message_decision.consume && !message_decision.next_latched);
  message_decision = DecideSiglusLookupMouseMessage(
      kSiglusLookupWmLeftButtonUp, true, false, message_decision.next_latched);
  assert(!message_decision.consume && !message_decision.next_latched);

  // A lost up (alt-tab, WM_CANCELMODE, drag out of the window) must not turn the
  // latch into a permanent left-button sink: the next down is judged on its own
  // merits and republishes the latch from scratch.
  message_decision = DecideSiglusLookupMouseMessage(
      kSiglusLookupWmLeftButtonDown, false, false, true);
  assert(!message_decision.consume && !message_decision.next_latched);
  message_decision = DecideSiglusLookupMouseMessage(
      kSiglusLookupWmLeftButtonUp, false, false, message_decision.next_latched);
  assert(!message_decision.consume && !message_decision.next_latched);
  message_decision = DecideSiglusLookupMouseMessage(
      kSiglusLookupWmLeftButtonDoubleClick, false, false, true);
  assert(!message_decision.consume && !message_decision.next_latched);

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

  return 0;
}
