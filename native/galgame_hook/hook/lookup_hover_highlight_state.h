#pragma once

// The request side of the shared hover-highlight window
// (lookup_overlay_window.inc), with an owner.
//
// The window is one per process, while every engine adapter's lookup tick
// runs in every game and clears the highlight on each tick it does not put a
// frame up.  Without an owner one adapter's clear blanks another engine's
// frame every tick (seen as flicker on SoftPal under the Siglus tick).  A
// request records its owner (the adapter's lookup geometry provider id); a
// clear takes the frame down only while that owner holds it.
//
// Any thread requests / clears; the UI thread reads the fields and applies
// them when `generation` moved.

#include <windows.h>

#include <cstdint>

namespace fushi_voice_hook {

struct HoverHighlightRequest {
  volatile LONG owner = 0;  // provider id of the frame up, 0 = none
  volatile LONG visible = 0;
  volatile LONG x = 0;
  volatile LONG y = 0;
  volatile LONG w = 0;
  volatile LONG h = 0;
  // +1 on every change; the UI thread moves the window only when it moved.
  volatile LONG generation = 0;
};

inline LONG LoadHoverField(volatile LONG* field) {
  return InterlockedCompareExchange(field, 0, 0);
}

// `owner` puts its frame up (or keeps it).  Owner 0 is not an owner.
inline void RequestHoverHighlight(HoverHighlightRequest* r, uint32_t owner,
                                  int32_t x, int32_t y, int32_t w, int32_t h) {
  if (owner == 0u) return;
  const LONG id = static_cast<LONG>(owner);
  const bool same = LoadHoverField(&r->visible) != 0 &&
                    LoadHoverField(&r->owner) == id &&
                    LoadHoverField(&r->x) == x && LoadHoverField(&r->y) == y &&
                    LoadHoverField(&r->w) == w && LoadHoverField(&r->h) == h;
  if (same) return;
  InterlockedExchange(&r->owner, id);
  InterlockedExchange(&r->x, x);
  InterlockedExchange(&r->y, y);
  InterlockedExchange(&r->w, w);
  InterlockedExchange(&r->h, h);
  InterlockedExchange(&r->visible, 1);
  InterlockedIncrement(&r->generation);
}

// `owner` takes its frame down; a frame another owner put up stays.  True
// when this call took a frame down.
inline bool ClearHoverHighlight(HoverHighlightRequest* r, uint32_t owner) {
  if (owner == 0u) return false;
  const LONG id = static_cast<LONG>(owner);
  if (InterlockedCompareExchange(&r->owner, 0, id) != id) return false;
  if (InterlockedExchange(&r->visible, 0) != 0) {
    InterlockedIncrement(&r->generation);
    return true;
  }
  return false;
}

}  // namespace fushi_voice_hook
