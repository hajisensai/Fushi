// Release builds keep these assertions live: this executable is a build gate.
#undef NDEBUG

#include "../attached_measured_layout.h"

#include <cassert>
#include <iostream>
#include <string>
#include <vector>

namespace {

namespace measured = fushi::attached_measured_layout;
using measured::ClusterBox;
using measured::Mapping;
using measured::MeasuredGlyph;

bool SameRect(const RECT &left, const RECT &right) {
  return left.left == right.left && left.top == right.top &&
         left.right == right.right && left.bottom == right.bottom;
}

Mapping IdentityMapping(const RECT &client) {
  return Mapping{client, client, client, client};
}

void ExpectDecodeRejected(const std::vector<int32_t> &words,
                          const std::wstring &text, int width, int height,
                          const char *expected) {
  std::vector<MeasuredGlyph> glyphs{MeasuredGlyph{}};
  std::string error;
  assert(!measured::DecodeGlyphs(words.data(), words.size(), text, width,
                                 height, &glyphs, &error));
  assert(error == expected);
  // A rejected snapshot never half-replaces the caller's glyph list.
  assert(glyphs.size() == 1);
}

void TestDecodeAcceptsCompactList() {
  const std::wstring text = L"あい";
  const std::vector<int32_t> words{0, 1, 10, 20, 30, 50,
                                   1, 1, 30, 20, 50, 50};
  std::vector<MeasuredGlyph> glyphs;
  std::string error;
  assert(measured::DecodeGlyphs(words.data(), words.size(), text, 800, 600,
                                &glyphs, &error));
  assert(glyphs.size() == 2);
  assert(glyphs[0].text_position == 0 && glyphs[0].text_length == 1);
  assert(SameRect(glyphs[0].client_rect, RECT{10, 20, 30, 50}));
  assert(glyphs[1].text_position == 1 && glyphs[1].text_length == 1);
  assert(SameRect(glyphs[1].client_rect, RECT{30, 20, 50, 50}));
}

void TestDecodeSurrogatePairs() {
  // U+20BB7 is one code point, two UTF-16 units.
  const std::wstring text = L"\xD842\xDFB7あ";
  std::vector<MeasuredGlyph> glyphs;
  std::string error;
  const std::vector<int32_t> whole{0, 2, 0, 0, 10, 10, 2, 1, 10, 0, 20, 10};
  assert(measured::DecodeGlyphs(whole.data(), whole.size(), text, 100, 100,
                                &glyphs, &error));
  assert(glyphs.size() == 2 && glyphs[0].text_length == 2);
  ExpectDecodeRejected({0, 1, 0, 0, 10, 10}, text, 100, 100,
                       "measured_glyph_splits_surrogate");
  ExpectDecodeRejected({1, 2, 0, 0, 10, 10}, text, 100, 100,
                       "measured_glyph_splits_surrogate");
}

void TestDecodeRejections() {
  const std::wstring text = L"abc";
  ExpectDecodeRejected({0, 1, 0, 0, 10}, text, 100, 100,
                       "measured_glyphs_malformed");
  ExpectDecodeRejected({}, text, 100, 100, "measured_glyphs_empty");
  ExpectDecodeRejected({0, 1, 0, 0, 10, 10}, L"", 100, 100,
                       "measured_glyphs_without_text");
  ExpectDecodeRejected({0, 1, 0, 0, 10, 10}, text, 0, 100,
                       "measured_client_size_invalid");
  ExpectDecodeRejected({-1, 1, 0, 0, 10, 10}, text, 100, 100,
                       "measured_glyph_range_invalid");
  ExpectDecodeRejected({0, 0, 0, 0, 10, 10}, text, 100, 100,
                       "measured_glyph_range_invalid");
  ExpectDecodeRejected({2, 2, 0, 0, 10, 10}, text, 100, 100,
                       "measured_glyph_range_invalid");
  ExpectDecodeRejected({0, 1, 10, 0, 10, 10}, text, 100, 100,
                       "measured_glyph_rect_empty");
  ExpectDecodeRejected({0, 1, 0, 10, 10, 5}, text, 100, 100,
                       "measured_glyph_rect_empty");
  ExpectDecodeRejected({0, 1, -1, 0, 10, 10}, text, 100, 100,
                       "measured_glyph_rect_outside_client");
  ExpectDecodeRejected({0, 1, 90, 90, 101, 100}, text, 100, 100,
                       "measured_glyph_rect_outside_client");
  // More glyphs than UTF-16 units cannot come from a real layout.
  ExpectDecodeRejected({0, 1, 0, 0, 1, 1, 0, 1, 0, 0, 1, 1, 0, 1, 0, 0, 1, 1,
                        0, 1, 0, 0, 1, 1},
                       text, 100, 100, "measured_glyphs_too_many");

  // Empty text with no glyphs is the explicit "no current line" update.
  std::vector<MeasuredGlyph> glyphs{MeasuredGlyph{}};
  std::string error;
  assert(measured::DecodeGlyphs(nullptr, 0, L"", 100, 100, &glyphs, &error));
  assert(glyphs.empty());
  // The rect edge may touch the exclusive client bound.
  const std::vector<int32_t> edge{0, 3, 90, 90, 100, 100};
  assert(measured::DecodeGlyphs(edge.data(), edge.size(), text, 100, 100,
                                &glyphs, &error));
  assert(glyphs.size() == 1);
}

void TestClientSizeMatches() {
  const RECT client{100, 200, 900, 800};
  assert(measured::ClientSizeMatches(800, 600, 0, client));
  // Only the size matters; the measurement is client-relative.
  assert(measured::ClientSizeMatches(800, 600, 0, RECT{-500, 0, 300, 600}));
  assert(!measured::ClientSizeMatches(801, 600, 0, client));
  assert(!measured::ClientSizeMatches(800, 599, 0, client));
  assert(!measured::ClientSizeMatches(0, 0, 0, RECT{0, 0, 0, 0}));
  assert(!measured::ClientSizeMatches(0, 0, 4, RECT{0, 0, 2, 2}));
  // Electron fullscreen at 150%: the live client is one row shorter than the
  // CSS viewport (2560x1440) times the DPR.  Within the declared quantization
  // it is the same layout.
  const RECT electron_fullscreen{0, 0, 3840, 2159};
  assert(!measured::ClientSizeMatches(3840, 2160, 0, electron_fullscreen));
  assert(measured::ClientSizeMatches(3840, 2160, 2, electron_fullscreen));
  assert(measured::ClientSizeMatches(3840, 2158, 1, electron_fullscreen));
  // A menu bar / real reflow (tens of px) is never absorbed, and the declared
  // tolerance is clamped so a bogus producer value cannot widen the band.
  assert(!measured::ClientSizeMatches(3840, 2127, 2, electron_fullscreen));
  assert(!measured::ClientSizeMatches(3840, 2149, 1000, electron_fullscreen));
  assert(measured::ClientSizeMatches(
      3840, 2159 - measured::kMaxClientSizeTolerance, 1000,
      electron_fullscreen));
  assert(!measured::ClientSizeMatches(3840, 2160, -3, electron_fullscreen));
}

void TestIdentityMapping() {
  const RECT client{100, 200, 900, 800};
  const Mapping mapping = IdentityMapping(client);
  RECT local{};
  // Surface covers the whole client: local == client rect.
  assert(measured::MapClientRectToSurfaceLocal(mapping, RECT{10, 20, 30, 50},
                                               client, &local));
  assert(SameRect(local, RECT{10, 20, 30, 50}));
  // A surface placed elsewhere still receives surface-local coordinates.
  const RECT body{150, 250, 400, 400};
  assert(measured::MapClientRectToSurfaceLocal(mapping, RECT{60, 60, 80, 90},
                                               body, &local));
  assert(SameRect(local, RECT{10, 10, 30, 40}));
  // Glyphs fully outside the surface are invisible, not clamped to an edge.
  RECT untouched{1, 2, 3, 4};
  assert(!measured::MapClientRectToSurfaceLocal(
      mapping, RECT{700, 500, 720, 520}, body, &untouched));
  assert(SameRect(untouched, RECT{1, 2, 3, 4}));
}

void TestMagpieMapping() {
  // Source client 800x600 at (0,0) shown 2x inside a letterboxed presentation.
  Mapping mapping;
  mapping.source_client_screen = RECT{0, 0, 800, 600};
  mapping.source_viewport_screen = RECT{0, 0, 800, 600};
  mapping.presentation_client_screen = RECT{0, 0, 1920, 1200};
  mapping.destination_viewport_screen = RECT{160, 0, 1760, 1200};
  RECT local{};
  assert(measured::MapClientRectToSurfaceLocal(
      mapping, RECT{10, 20, 30, 50}, mapping.destination_viewport_screen,
      &local));
  assert(SameRect(local, RECT{20, 40, 60, 100}));

  // Magpie crop: the source viewport skips the first 100 source pixels.
  Mapping cropped = mapping;
  cropped.source_viewport_screen = RECT{100, 0, 900, 600};
  cropped.source_client_screen = RECT{0, 0, 900, 600};
  std::vector<MeasuredGlyph> glyphs{
      MeasuredGlyph{0, 1, RECT{10, 10, 40, 40}},   // inside the cropped band
      MeasuredGlyph{1, 1, RECT{110, 10, 140, 40}}, // visible
  };
  std::vector<ClusterBox> clusters;
  std::string reason;
  assert(measured::BuildClusters(cropped, cropped.destination_viewport_screen,
                                 glyphs, &clusters, &reason));
  assert(clusters.size() == 1);
  assert(clusters[0].text_position == 1 && clusters[0].text_length == 1);
  assert(SameRect(clusters[0].hit_rect, RECT{20, 20, 80, 80}));
  assert(SameRect(clusters[0].hit_rect, clusters[0].visual_rect));
}

void TestBuildClustersRejections() {
  const RECT client{0, 0, 800, 600};
  std::vector<ClusterBox> clusters{ClusterBox{}};
  std::string reason;
  assert(!measured::BuildClusters(IdentityMapping(client), client, {},
                                  &clusters, &reason));
  assert(reason == "measured_glyphs_empty");
  assert(!measured::BuildClusters(Mapping{}, client,
                                  {MeasuredGlyph{0, 1, RECT{0, 0, 5, 5}}},
                                  &clusters, &reason));
  assert(reason == "measured_mapping_invalid");
  const RECT tiny_surface{700, 500, 800, 600};
  assert(!measured::BuildClusters(IdentityMapping(client), tiny_surface,
                                  {MeasuredGlyph{0, 1, RECT{0, 0, 5, 5}}},
                                  &clusters, &reason));
  assert(reason == "measured_clusters_not_visible");
  assert(clusters.size() == 1);

  // No padding: hit_rect is exactly the measured glyph.
  assert(measured::BuildClusters(IdentityMapping(client), client,
                                 {MeasuredGlyph{2, 3, RECT{5, 6, 7, 8}}},
                                 &clusters, &reason));
  assert(reason.empty());
  assert(clusters.size() == 1);
  assert(clusters[0].text_position == 2 && clusters[0].text_length == 3);
  assert(SameRect(clusters[0].hit_rect, RECT{5, 6, 7, 8}));
}

void TestSourceAllowList() {
  assert(measured::IsSupportedSource("tyrano_dom"));
  assert(!measured::IsSupportedSource(""));
  assert(!measured::IsSupportedSource("TyranoDom"));
  assert(!measured::IsSupportedSource("dom"));
}

} // namespace

int main() {
  TestDecodeAcceptsCompactList();
  TestDecodeSurrogatePairs();
  TestDecodeRejections();
  TestClientSizeMatches();
  TestIdentityMapping();
  TestMagpieMapping();
  TestBuildClustersRejections();
  TestSourceAllowList();
  std::cout << "attached measured layout passed\n";
  return 0;
}
