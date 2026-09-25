// Release builds keep these assertions live: this executable is a build gate.
#undef NDEBUG

#include "../attached_magpie_surface_geometry.h"

#include <cassert>
#include <iostream>

namespace {

using fushi::attached_magpie_surface_geometry::Mapping;
using fushi::attached_magpie_surface_geometry::ClipRectTo;
using fushi::attached_magpie_surface_geometry::MapSourcePointToDestination;
using fushi::attached_magpie_surface_geometry::MapSourceRectToDestination;
using fushi::attached_magpie_surface_geometry::ResolveCursorPoint;
using fushi::attached_magpie_surface_geometry::ResolveCursorTransactionPoint;
using fushi::attached_magpie_surface_geometry::ResolveVisibleBody;
using NormalizedRect = fushi::attached_text_layout::NormalizedRect;

bool SameRect(const RECT &left, const RECT &right) {
  return left.left == right.left && left.top == right.top &&
         left.right == right.right && left.bottom == right.bottom;
}

Mapping IdentityMapping() {
  const RECT client{100, 200, 1100, 1000};
  return Mapping{client, client, client, client};
}

void ExpectBody(const Mapping &mapping, const NormalizedRect &body,
                const RECT &expected) {
  RECT actual{};
  assert(ResolveVisibleBody(mapping, body, &actual));
  assert(SameRect(actual, expected));
}

void ExpectRejected(const Mapping &mapping, const NormalizedRect &body) {
  RECT actual{7, 8, 9, 10};
  assert(!ResolveVisibleBody(mapping, body, &actual));
  assert(SameRect(actual, RECT{7, 8, 9, 10}));
}

}  // namespace

int main() {
  ExpectBody(IdentityMapping(), NormalizedRect{0.1, 0.25, 0.4, 0.5},
             RECT{200, 400, 600, 800});

  const Mapping cropped{
      RECT{0, 0, 1000, 1000},
      RECT{100, 100, 900, 900},
      RECT{200, 100, 1800, 1700},
      RECT{400, 300, 1600, 1500},
  };
  // The source body is mapped through the cropped source viewport and then
  // clipped to DestRect; it is not stretched from the complete client.
  ExpectBody(cropped, NormalizedRect{0.0, 0.0, 0.2, 0.2},
             RECT{400, 300, 550, 450});
  ExpectBody(cropped, NormalizedRect{0.05, 0.05, 0.2, 0.2},
             RECT{400, 300, 625, 525});

  // Runtime clusters are built in source-body pixels, then transformed and
  // clipped by the same mapping as the body itself.
  RECT mapped_cluster{};
  assert(MapSourceRectToDestination(cropped, RECT{0, 0, 200, 200},
                                    &mapped_cluster));
  assert(SameRect(mapped_cluster, RECT{250, 150, 550, 450}));
  RECT clipped_cluster{};
  assert(ClipRectTo(mapped_cluster, cropped.destination_viewport_screen,
                    &clipped_cluster));
  assert(SameRect(clipped_cluster, RECT{400, 300, 550, 450}));
  assert(!MapSourceRectToDestination(cropped, RECT{-1, 0, 200, 200},
                                     &mapped_cluster));

  // A negative-origin source monitor and unequal x/y scaling must preserve
  // both axes independently; presentation pixels do not use the source DPI.
  const Mapping anisotropic{
      RECT{-1200, -300, -200, 500}, RECT{-1100, -200, -300, 400},
      RECT{0, 0, 1920, 1080}, RECT{100, 50, 1700, 950}};
  assert(MapSourceRectToDestination(anisotropic,
                                    RECT{-1000, 0, -800, 100}, &mapped_cluster));
  assert(SameRect(mapped_cluster, RECT{300, 350, 700, 500}));

  // A body wholly outside SrcRect cannot produce a catch surface.
  ExpectRejected(cropped, NormalizedRect{0.0, 0.0, 0.05, 0.05});

  Mapping source_outside = cropped;
  source_outside.source_viewport_screen = RECT{-1, 100, 900, 900};
  ExpectRejected(source_outside, NormalizedRect{0.1, 0.1, 0.2, 0.2});

  // Round13 live data: the old GetClientRect + two ClientToScreen calls
  // reported the DPI-unaware source client as {952,474,3276,1783}, while
  // Magpie and GetWindowInfo.rcClient both reported {952,474,3278,1783}.
  // The corrected physical client must contain Magpie's published viewport;
  // strict containment still rejects the old rectangle.
  const RECT round13_source_client{952, 474, 3278, 1783};
  const RECT round13_source_viewport{952, 474, 3278, 1783};
  Mapping round13_mapping{round13_source_client, round13_source_viewport,
                          RECT{0, 0, 3840, 2160}, RECT{1, 0, 3839, 2160}};
  assert(fushi::attached_magpie_surface_geometry::RectContainedIn(
      round13_mapping.source_viewport_screen,
      round13_mapping.source_client_screen));
  assert(fushi::attached_magpie_surface_geometry::IsMappingValid(
      round13_mapping));
  RECT round13_mapped_destination{};
  assert(MapSourceRectToDestination(round13_mapping,
                                    round13_source_viewport,
                                    &round13_mapped_destination));
  assert(SameRect(round13_mapped_destination,
                  round13_mapping.destination_viewport_screen));
  Mapping round13_old_mapping = round13_mapping;
  round13_old_mapping.source_client_screen = RECT{952, 474, 3276, 1783};
  assert(!fushi::attached_magpie_surface_geometry::RectContainedIn(
      round13_old_mapping.source_viewport_screen,
      round13_old_mapping.source_client_screen));
  assert(!fushi::attached_magpie_surface_geometry::IsMappingValid(
      round13_old_mapping));

  Mapping destination_outside = cropped;
  destination_outside.destination_viewport_screen = RECT{400, 300, 1801, 1500};
  ExpectRejected(destination_outside, NormalizedRect{0.1, 0.1, 0.2, 0.2});

  Mapping degenerate = cropped;
  degenerate.source_viewport_screen = RECT{100, 100, 100, 900};
  ExpectRejected(degenerate, NormalizedRect{0.1, 0.1, 0.2, 0.2});
  ExpectRejected(cropped, NormalizedRect{0.0, 0.0, 0.0, 0.2});

  // Cursor mapping follows Magpie's first/last-pixel rule, including both
  // endpoints.  This is the live round-14 mapping and cursor sample.
  const Mapping round14_mapping{
      RECT{0, 0, 4000, 2000}, RECT{1001, 292, 3327, 1601},
      RECT{0, 0, 3840, 2160}, RECT{1, 0, 3839, 2160}};
  POINT mapped_point{};
  assert(MapSourcePointToDestination(round14_mapping, POINT{1001, 292},
                                     &mapped_point));
  assert(mapped_point.x == 1 && mapped_point.y == 0);
  assert(MapSourcePointToDestination(round14_mapping, POINT{3326, 1600},
                                     &mapped_point));
  assert(mapped_point.x == 3838 && mapped_point.y == 2159);
  assert(MapSourcePointToDestination(round14_mapping, POINT{3089, 367},
                                     &mapped_point));
  assert(mapped_point.x == 3447 && mapped_point.y == 124);

  // Round the non-negative delta before adding a negative destination origin.
  // Rounding the absolute coordinate would produce -3 here instead of
  // Magpie's -5 + lround(2.5) == -2.
  const Mapping negative_destination{
      RECT{0, 0, 5, 5}, RECT{0, 0, 5, 5}, RECT{-20, -20, 20, 20},
      RECT{-5, -5, 6, 6}};
  assert(MapSourcePointToDestination(negative_destination, POINT{1, 1},
                                     &mapped_point));
  assert(mapped_point.x == -2 && mapped_point.y == -2);

  // Outside the published viewport the cursor keeps a one-to-one offset from
  // the corresponding viewport edge instead of extending the scale.
  const Mapping viewport_offset{
      RECT{0, 0, 300, 300}, RECT{100, 100, 200, 200},
      RECT{900, 900, 1300, 1300}, RECT{1000, 1000, 1200, 1200}};
  assert(MapSourcePointToDestination(viewport_offset, POINT{90, 210},
                                     &mapped_point));
  assert(mapped_point.x == 990 && mapped_point.y == 1210);

  // A physical point can fall in one destination glyph while its captured
  // source mapping falls in another.  The snapshot's selected space decides
  // the hit; it must never try both rectangles and accept whichever matches.
  const POINT physical_cursor{3089, 367};
  const RECT raw_glyph{3075, 350, 3105, 385};
  const RECT mapped_glyph{3435, 110, 3460, 140};
  POINT resolved_cursor{};
  assert(ResolveCursorPoint(nullptr, false, physical_cursor,
                            &resolved_cursor));
  assert(PtInRect(&raw_glyph, resolved_cursor) != FALSE);
  assert(PtInRect(&mapped_glyph, resolved_cursor) == FALSE);
  assert(ResolveCursorPoint(&round14_mapping, true, physical_cursor,
                            &resolved_cursor));
  assert(PtInRect(&raw_glyph, resolved_cursor) == FALSE);
  assert(PtInRect(&mapped_glyph, resolved_cursor) != FALSE);

  // Once a Magpie snapshot has been admitted, leaving capture mode invalidates
  // both a fresh hit and the up side of an already admitted down/up pair.
  assert(!ResolveCursorPoint(&round14_mapping, false, physical_cursor,
                             &resolved_cursor));
  assert(ResolveCursorTransactionPoint(&round14_mapping, true, true,
                                       physical_cursor, &resolved_cursor));
  assert(!ResolveCursorTransactionPoint(&round14_mapping, true, false,
                                        physical_cursor, &resolved_cursor));
  assert(!ResolveCursorTransactionPoint(nullptr, true, false, physical_cursor,
                                        &resolved_cursor));

  std::cout << "attached Magpie surface geometry passed\n";
  return 0;
}
