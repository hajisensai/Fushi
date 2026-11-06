// CI builds with --config Release, where MSVC defines NDEBUG and compiles
// bare assert() out entirely. Undefine it before any include or this test is
// green no matter what it checks. Guard: tests/assert_liveness_guard_test.py
#undef NDEBUG

#include <cassert>

#include "../hook/lookup_hover_highlight_state.h"

namespace hv = fushi_voice_hook;

int main() {
  constexpr uint32_t kSiglus = 6u;
  constexpr uint32_t kSoftpal = 29u;

  // Every adapter's tick runs in every game and clears when it has no frame:
  // another adapter's clear must not blank the frame that is up.
  {
    hv::HoverHighlightRequest r;
    hv::RequestHoverHighlight(&r, kSoftpal, 10, 20, 30, 40);
    const LONG generation = r.generation;
    assert(r.visible == 1 && r.owner == static_cast<LONG>(kSoftpal));
    assert(!hv::ClearHoverHighlight(&r, kSiglus));
    assert(r.visible == 1 && r.generation == generation);
    // The same frame again moves nothing (no per-tick window churn).
    hv::RequestHoverHighlight(&r, kSoftpal, 10, 20, 30, 40);
    assert(r.generation == generation);
    // The owner takes it down.
    assert(hv::ClearHoverHighlight(&r, kSoftpal));
    assert(r.visible == 0 && r.owner == 0 && r.generation == generation + 1);
    assert(!hv::ClearHoverHighlight(&r, kSoftpal));
  }
  // A frame another engine put over ours makes it theirs: our stale clear
  // leaves it alone.
  {
    hv::HoverHighlightRequest r;
    hv::RequestHoverHighlight(&r, kSiglus, 1, 2, 3, 4);
    hv::RequestHoverHighlight(&r, kSoftpal, 5, 6, 7, 8);
    assert(!hv::ClearHoverHighlight(&r, kSiglus));
    assert(r.visible == 1 && r.x == 5);
    // The same rectangle from another owner is a change of owner.
    hv::RequestHoverHighlight(&r, kSiglus, 5, 6, 7, 8);
    assert(r.owner == static_cast<LONG>(kSiglus));
    assert(hv::ClearHoverHighlight(&r, kSiglus) && r.visible == 0);
  }
  // Owner 0 is nobody.
  {
    hv::HoverHighlightRequest r;
    hv::RequestHoverHighlight(&r, 0u, 1, 2, 3, 4);
    assert(r.visible == 0 && r.generation == 0);
    assert(!hv::ClearHoverHighlight(&r, 0u));
  }
  return 0;
}
