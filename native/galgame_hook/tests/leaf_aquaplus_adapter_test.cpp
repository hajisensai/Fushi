#ifdef NDEBUG
#undef NDEBUG
#endif
#include <cassert>
#include <cstdint>
#include <cwchar>

#include "../hook/adapters/leaf_aquaplus_profile.h"

int main() {
  using namespace fushi_voice_hook;
  const auto &profile = kWhiteAlbum2LeafAquaplusProfile;
  assert(profile.d3d9_device_pointer_rva == 0x734430u);
  assert(profile.stack_cookie_rva == 0x0d1630u);
  assert(profile.get_async_key_state_iat_rva == 0x0a134cu);
  assert(profile.read_file_iat_rva == 0x0a10a4u);
  assert(profile.embed_leaf_hook_rva == 0x0512bfu);
  assert(profile.input_poller_first_return_rva == 0x04a83eu);
  assert(profile.input_poller_last_return_rva == 0x04a9b4u);
  assert(0x00400000u + profile.input_poller_first_return_rva == 0x0044a83eu);
  assert(0x00400000u + profile.input_poller_last_return_rva == 0x0044a9b4u);
  assert(profile.text_traversal_rva == 0x0462c0u);
  assert(profile.raster_draw_rva == 0x03b590u);
  assert(profile.glyph_dispatch_rva == 0x0460a0u);
  assert(profile.raster_glyph_return_rva == 0x0462b7u);
  assert(profile.raster_parent_return_stack_offset == 0x0cu);
  assert(profile.raster_packed_cp932_stack_offset == 0x110u);
  assert(profile.glyph_single_return_rva == 0x046f72u);
  assert(profile.glyph_double_first_return_rva == 0x0470c2u);
  assert(profile.glyph_double_second_return_rva == 0x047185u);
  assert(profile.quad_draw_return_rva == 0x03dd19u);
  assert(profile.quad_vertex_stride == 0x20u);
  assert(profile.quad_fvf == 0x01c4u);
  assert(profile.alternate_quad_draw_return_rva == 0x03c968u);
  assert(profile.alternate_quad_vertex_stride == 0x28u);
  assert(profile.alternate_quad_fvf == 0x02c4u);
  assert(profile.voice_archive_read_return_rva == 0x059142u);
  assert(0x00400000u + profile.voice_archive_read_return_rva == 0x00459142u);
  const LeafAquaplusGlyphDrawIdentity primary_draw = {
      1u, static_cast<uint32_t>(profile.quad_draw_return_rva),
      profile.quad_vertex_stride, profile.quad_fvf};
  const LeafAquaplusGlyphDrawIdentity alternate_draw = {
      2u, static_cast<uint32_t>(profile.alternate_quad_draw_return_rva),
      profile.alternate_quad_vertex_stride, profile.alternate_quad_fvf};
  const LeafAquaplusGlyphDrawIdentity primary_pair[2] = {primary_draw,
                                                         primary_draw};
  assert(AreLeafAquaplusMatchedGlyphDrawsPrimary(
      primary_pair, 2u, static_cast<uint32_t>(profile.quad_draw_return_rva),
      profile.quad_vertex_stride, profile.quad_fvf));
  assert(!AreLeafAquaplusMatchedGlyphDrawsPrimary(
      &alternate_draw, 1u, static_cast<uint32_t>(profile.quad_draw_return_rva),
      profile.quad_vertex_stride, profile.quad_fvf));
  const LeafAquaplusGlyphDrawIdentity mixed_pair[2] = {primary_draw,
                                                       alternate_draw};
  assert(!AreLeafAquaplusMatchedGlyphDrawsPrimary(
      mixed_pair, 2u, static_cast<uint32_t>(profile.quad_draw_return_rva),
      profile.quad_vertex_stride, profile.quad_fvf));
  LeafAquaplusGlyphDrawIdentity wrong = primary_draw;
  ++wrong.caller_rva;
  assert(!IsLeafAquaplusPrimaryGlyphDraw(
      wrong, static_cast<uint32_t>(profile.quad_draw_return_rva),
      profile.quad_vertex_stride, profile.quad_fvf));
  wrong = primary_draw;
  ++wrong.vertex_stride;
  assert(!IsLeafAquaplusPrimaryGlyphDraw(
      wrong, static_cast<uint32_t>(profile.quad_draw_return_rva),
      profile.quad_vertex_stride, profile.quad_fvf));
  wrong = primary_draw;
  ++wrong.fvf;
  assert(!IsLeafAquaplusPrimaryGlyphDraw(
      wrong, static_cast<uint32_t>(profile.quad_draw_return_rva),
      profile.quad_vertex_stride, profile.quad_fvf));
  assert(MatchesLeafAquaplusProfile(profile, profile.executable_sha256.data(),
                                    profile.executable_sha256.size(),
                                    kLeafAquaplusPeMachineI386));

  auto changed = profile.executable_sha256;
  changed[17] ^= 0x01u;
  assert(!MatchesLeafAquaplusProfile(profile, changed.data(), changed.size(),
                                     kLeafAquaplusPeMachineI386));
  assert(!MatchesLeafAquaplusProfile(profile, profile.executable_sha256.data(),
                                     profile.executable_sha256.size(),
                                     0x8664u));
  assert(!MatchesLeafAquaplusProfile(profile, nullptr, 32u,
                                     kLeafAquaplusPeMachineI386));
  assert(!MatchesLeafAquaplusProfile(profile, profile.executable_sha256.data(),
                                     31u, kLeafAquaplusPeMachineI386));

  assert(FilterLeafAquaplusAsyncKeyState(0x8001u, false) == 0x8001u);
  assert(FilterLeafAquaplusAsyncKeyState(0x8001u, true) == 0u);
  assert(FilterLeafAquaplusAsyncKeyState(0x8000u, true) == 0u);
  assert(FilterLeafAquaplusAsyncKeyState(0x0001u, true) == 0u);
  assert(FilterLeafAquaplusAsyncKeyState(0x0040u, true) == 0x0040u);
  assert(!IsLeafAquaplusTraceForSentence(40u, 1000u, 40u, 1000u));
  assert(!IsLeafAquaplusTraceForSentence(41u, 999u, 40u, 1000u));
  assert(IsLeafAquaplusTraceForSentence(41u, 1000u, 40u, 1000u));
  assert(LeafAquaplusRecentTraceFloor(0u, 2048u) == 0u);
  assert(LeafAquaplusRecentTraceFloor(2048u, 2048u) == 0u);
  assert(LeafAquaplusRecentTraceFloor(2049u, 2048u) == 1u);
  assert(LeafAquaplusRecentTraceFloor(5000u, 2048u) == 2952u);
  assert(LeafAquaplusTraceContinuesTraversal(80u, 2u, 81u, 3u));
  assert(!LeafAquaplusTraceContinuesTraversal(80u, 2u, 82u, 3u));
  assert(!LeafAquaplusTraceContinuesTraversal(80u, 2u, 81u, 2u));
  assert(!LeafAquaplusTraceContinuesTraversal(80u, 2u, 81u, 1u));
  // Unrelated global publications must not advance the selected-line cursor.
  // Only a sequence already classified as a selected target reaches this gate.
  const uint64_t consumed_target_sequence = 40u;
  assert(!LeafAquaplusTargetSequenceIsNewer(consumed_target_sequence,
                                            consumed_target_sequence));
  assert(!LeafAquaplusTargetSequenceIsNewer(consumed_target_sequence - 1u,
                                            consumed_target_sequence));
  assert(LeafAquaplusTargetSequenceIsNewer(consumed_target_sequence + 1u,
                                           consumed_target_sequence));
  using SelectedDisposition = LeafAquaplusSelectedLineEventDisposition;
  assert(ClassifyLeafAquaplusSelectedLineEvent(41u, 40u, true, false, 4u, 1024u,
                                               512u) ==
         SelectedDisposition::kUseUtf16Payload);
  assert(ClassifyLeafAquaplusSelectedLineEvent(41u, 40u, false, false, 4u,
                                               1024u, 512u) ==
         SelectedDisposition::kIgnore);
  assert(ClassifyLeafAquaplusSelectedLineEvent(40u, 40u, true, false, 4u, 1024u,
                                               512u) ==
         SelectedDisposition::kIgnore);
  assert(ClassifyLeafAquaplusSelectedLineEvent(41u, 40u, true, false, 0u, 1024u,
                                               512u) ==
         SelectedDisposition::kInvalidate);
  assert(ClassifyLeafAquaplusSelectedLineEvent(41u, 40u, true, false, 1026u,
                                               1024u, 512u) ==
         SelectedDisposition::kInvalidate);
  assert(ClassifyLeafAquaplusSelectedLineEvent(41u, 40u, true, true, 4u, 1024u,
                                               512u) ==
         SelectedDisposition::kInvalidate);
  assert(ClassifyLeafAquaplusSelectedLineEvent(41u, 40u, true, false, 3u, 1024u,
                                               512u) ==
         SelectedDisposition::kInvalidate);
  assert(!LeafAquaplusConflictingPollerMustConsume(false, false, false, false,
                                                   false));
  assert(LeafAquaplusConflictingPollerMustConsume(true, false, false, false,
                                                  false));
  assert(LeafAquaplusConflictingPollerMustConsume(false, true, false, false,
                                                  false));
  assert(LeafAquaplusConflictingPollerMustConsume(false, false, true, false,
                                                  false));
  assert(LeafAquaplusConflictingPollerMustConsume(false, false, false, true,
                                                  false));
  assert(LeafAquaplusConflictingPollerMustConsume(false, false, false, false,
                                                  true));
  assert(!LeafAquaplusTailRequestIsOrphaned(0u, false));
  assert(!LeafAquaplusTailRequestIsOrphaned(7u, true));
  assert(LeafAquaplusTailRequestIsOrphaned(7u, false));
  LeafAquaplusPackedCp932Bytes cp932;
  assert(UnpackLeafAquaplusCp932(0xa082u, &cp932));
  assert(cp932.count == 2u && cp932.bytes[0] == 0x82u &&
         cp932.bytes[1] == 0xa0u);
  assert(UnpackLeafAquaplusCp932(0xffb1u, &cp932));
  assert(cp932.count == 1u && cp932.bytes[0] == 0xb1u);
  assert(NormalizeLeafAquaplusPackedCp932(0xff41u) == 0x0041u);
  assert(!UnpackLeafAquaplusCp932(0u, &cp932));

  const wchar_t ruby_source[] = L"雪<R菜々美|ななみ>だ";
  wchar_t normalized[32] = {};
  size_t normalized_units = 0;
  assert(NormalizeLeafAquaplusLookupText(
      ruby_source, (sizeof(ruby_source) / sizeof(ruby_source[0])) - 1u,
      normalized, 32u, &normalized_units));
  const wchar_t ruby_base[] = L"雪菜々美だ";
  assert(normalized_units == (sizeof(ruby_base) / sizeof(ruby_base[0])) - 1u);
  assert(std::wmemcmp(normalized, ruby_base, normalized_units) == 0);
  const wchar_t malformed_ruby[] = L"<R雪|ゆき";
  assert(!NormalizeLeafAquaplusLookupText(
      malformed_ruby, (sizeof(malformed_ruby) / sizeof(malformed_ruby[0])) - 1u,
      normalized, 32u, &normalized_units));
  assert(normalized_units == 0u);
  assert(!NormalizeLeafAquaplusLookupText(L"", 0u, normalized, 32u,
                                          &normalized_units));
  assert(normalized_units == 0u);

  const wchar_t exact_text[] = L"同 じ\n長さ";
  uint32_t visible_indices[8] = {};
  size_t visible_count = 0;
  assert(CollectLeafAquaplusVisibleCharMap(exact_text, 6u, visible_indices, 8u,
                                           &visible_count));
  assert(visible_count == 4u && visible_indices[0] == 0u &&
         visible_indices[1] == 2u && visible_indices[2] == 4u &&
         visible_indices[3] == 5u);
  assert(LeafAquaplusDecodedGlyphMatchesText(L'長', exact_text, 6u, 4u));
  assert(!LeafAquaplusDecodedGlyphMatchesText(L'別', exact_text, 6u, 4u));

  LeafAquaplusSampledInputTailState tail;
  auto tail_decision =
      AdvanceLeafAquaplusSampledInputTail(0x101u, 0x1u, 0x1u, 0x0001u, &tail);
  assert(tail_decision.consume && !tail_decision.acknowledge);
  assert(FilterLeafAquaplusAsyncKeyState(0x0001u, tail_decision.consume) == 0u);
  // The popup may already be hidden here; the retained request still drains
  // the engine's next raw-zero sample before host publication can retire.
  tail_decision =
      AdvanceLeafAquaplusSampledInputTail(0x101u, 0x1u, 0x1u, 0u, &tail);
  assert(tail_decision.consume && tail_decision.acknowledge);
  tail_decision =
      AdvanceLeafAquaplusSampledInputTail(0x101u, 0x1u, 0x1u, 0u, &tail);
  assert(tail_decision.consume && !tail_decision.acknowledge);

  LeafAquaplusSampledInputTailState three_button_tail;
  assert(!AdvanceLeafAquaplusSampledInputTail(0x207u, 0x7u, 0x1u, 0x8001u,
                                              &three_button_tail)
              .acknowledge);
  assert(!AdvanceLeafAquaplusSampledInputTail(0x207u, 0x7u, 0x1u, 0u,
                                              &three_button_tail)
              .acknowledge);
  assert(!AdvanceLeafAquaplusSampledInputTail(0x207u, 0x7u, 0x2u, 0u,
                                              &three_button_tail)
              .acknowledge);
  assert(AdvanceLeafAquaplusSampledInputTail(0x207u, 0x7u, 0x4u, 0u,
                                             &three_button_tail)
             .acknowledge);
  assert(!AdvanceLeafAquaplusSampledInputTail(0x209u, 0x1u, 0x1u, 0x0001u,
                                              &three_button_tail)
              .acknowledge);

  LeafAquaplusLookupClickSampleState click;
  auto decision =
      AdvanceLeafAquaplusLookupClickSample(0u, true, false, false, 7u, &click);
  assert(!decision.consume && click.synchronized);
  decision = AdvanceLeafAquaplusLookupClickSample(0x8001u, true, false, true,
                                                  7u, &click);
  assert(decision.begin && decision.consume && !decision.submit);
  assert(click.owner == LeafAquaplusLookupClickOwner::kLookup);
  decision = AdvanceLeafAquaplusLookupClickSample(0x8000u, true, false, true,
                                                  8u, &click);
  assert(decision.consume && !decision.submit);
  decision =
      AdvanceLeafAquaplusLookupClickSample(0u, true, false, true, 8u, &click);
  assert(decision.consume && !decision.submit);
  assert(click.owner == LeafAquaplusLookupClickOwner::kIdle);

  decision = AdvanceLeafAquaplusLookupClickSample(0x8001u, true, false, true,
                                                  8u, &click);
  assert(decision.begin && decision.consume && !decision.submit);
  decision =
      AdvanceLeafAquaplusLookupClickSample(0u, true, false, false, 8u, &click);
  assert(decision.consume && decision.submit);
  decision = AdvanceLeafAquaplusLookupClickSample(0x0001u, true, false, true,
                                                  8u, &click);
  assert(decision.begin && decision.consume && decision.submit);

  decision = AdvanceLeafAquaplusLookupClickSample(0x8001u, true, true, false,
                                                  8u, &click);
  assert(decision.begin && decision.consume && decision.popup_transaction);
  decision =
      AdvanceLeafAquaplusLookupClickSample(0u, true, false, false, 8u, &click);
  assert(decision.consume && !decision.submit && decision.popup_transaction);

  LeafAquaplusLookupShiftState shift;
  // A tap completed while lookup was disabled leaves only GetAsyncKeyState's
  // low bit.  The first sample in the new activation drains but never replays
  // it as a lookup.
  assert(!ConsumeLeafAquaplusLookupShiftSample(0x0001u, 2u, &shift));
  assert(!ConsumeLeafAquaplusLookupShiftSample(0u, 2u, &shift));
  assert(ConsumeLeafAquaplusLookupShiftSample(0x8001u, 2u, &shift));
  assert(!ConsumeLeafAquaplusLookupShiftSample(0x8000u, 2u, &shift));
  assert(!ConsumeLeafAquaplusLookupShiftSample(0u, 2u, &shift));
  assert(ConsumeLeafAquaplusLookupShiftSample(0x0001u, 2u, &shift));

  // Holding Shift across a disable/re-enable boundary seeds last_high_down;
  // only a release followed by a genuinely new press may submit.
  assert(!ConsumeLeafAquaplusLookupShiftSample(0x8000u, 3u, &shift));
  assert(!ConsumeLeafAquaplusLookupShiftSample(0x8000u, 3u, &shift));
  assert(!ConsumeLeafAquaplusLookupShiftSample(0u, 3u, &shift));
  assert(ConsumeLeafAquaplusLookupShiftSample(0x8000u, 3u, &shift));

  LeafAquaplusLookupGlyph glyphs[2] = {
      {100.0f, 500.0f, 140.0f, 540.0f, 3u},
      {140.0f, 500.0f, 180.0f, 540.0f, 4u},
  };
  LeafAquaplusLookupRect rect;
  assert(IsLeafAquaplusGlyphSequenceSpatiallyMonotonic(glyphs, 2u));
  assert(FindLeafAquaplusLookupGlyph(glyphs, 2u, 0, 0, 1280, 720, 2560, 1440,
                                     220, 1020, &rect) == 0);
  assert(rect.x == 200 && rect.y == 1000 && rect.width == 80 &&
         rect.height == 80);
  assert(FindLeafAquaplusLookupGlyph(glyphs, 2u, 0, 0, 1280, 720, 2560, 1440,
                                     300, 1020, &rect) == 1);
  assert(FindLeafAquaplusLookupGlyph(glyphs, 2u, 0, 0, 1280, 720, 2560, 1440,
                                     20, 20, &rect) == -1);
  LeafAquaplusLookupGlyph offset_glyph = {110.0f, 220.0f, 130.0f, 240.0f, 0u};
  assert(FindLeafAquaplusLookupGlyph(&offset_glyph, 1u, 100, 200, 640, 360,
                                     1280, 720, 40, 40, &rect) == 0);
  assert(rect.x == 20 && rect.y == 40 && rect.width == 40 && rect.height == 40);
  return 0;
}
