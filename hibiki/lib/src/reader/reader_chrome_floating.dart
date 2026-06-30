/// TODO-975: pure helpers for the collapsible / floating reader chrome model.
///
/// Two orthogonal chrome surfaces — the top reading-progress strip and the
/// bottom control bar — each render in one of two modes:
///
///  * **挤压 (squeeze)**: the surface reserves layout height that is fed to the
///    WebView / caret / focus-ring / popup as a chrome inset. The铁律 is that
///    the visual height equals the reserved height (same source), so the body
///    text never sits under the chrome.
///  * **悬浮 (floating)**: the surface reserves ZERO height and is painted as a
///    [Positioned] overlay on top of the body. It is hidden by default, revealed
///    by a tap, and auto-hidden after [autoHideChromeMillis]. Because the reserve
///    never changes while floating, revealing/hiding it needs no re-anchor.
///
/// These functions are the single source of truth for "how much height does the
/// chrome reserve" and "is the chrome painted right now", kept standalone (not
/// part-of the reader page) so they are unit-testable without the full page and
/// reused by the reader chrome + its guards.
library;

/// Clamps a stored auto-hide duration (milliseconds) into a sane range. `0` is
/// not allowed (the surface would vanish instantly on reveal); the slider min is
/// 1s and max 10s. Non-finite / out-of-range values degrade to the 3s default.
int normalizeAutoHideChromeMillis(int value) {
  const int min = 1000;
  const int max = 10000;
  if (value < min || value > max) {
    return value.clamp(min, max);
  }
  return value;
}

/// Default auto-hide duration: 3 seconds (TODO-975 decision #1).
const int kDefaultAutoHideChromeMillis = 3000;

/// Reserved height (logical px) for the top progress strip.
///
///  * Progress disabled / not yet measured (`showTopProgress == false`) -> 0,
///    which is requirement A: turning the top progress OFF reclaims the 18px the
///    strip used to keep reserved unconditionally.
///  * Floating -> 0 (the strip paints over the body).
///  * Squeeze + shown -> [infoStripHeight] (the historical `_infoFontSize*1.5`).
double topProgressReserve({
  required bool showTopProgress,
  required bool floating,
  required double infoStripHeight,
}) {
  if (!showTopProgress || floating) return 0;
  return infoStripHeight;
}

/// Reserved height (logical px) for the bottom control bar's *content row*
/// (excludes the system bottom inset, which the caller adds separately).
///
///  * Bar not occupying layout (`barOccupiesLayout == false`) -> 0. This mirrors
///    the existing `_hasEverLoaded && _showChrome` gate.
///  * Floating -> 0 (the bar paints over the body).
///  * Squeeze + occupying -> [chromeHeight] (the scaled bar height).
double bottomChromeReserve({
  required bool barOccupiesLayout,
  required bool floating,
  required double chromeHeight,
}) {
  if (!barOccupiesLayout || floating) return 0;
  return chromeHeight;
}

/// Whether the top progress strip should be painted right now.
///
/// In squeeze mode it follows [showTopProgress] (the historical behavior). In
/// floating mode it is additionally gated on [transientVisible] (revealed by a
/// tap, hidden again by the auto-hide timer).
bool topProgressVisible({
  required bool showTopProgress,
  required bool floating,
  required bool transientVisible,
}) {
  if (!showTopProgress) return false;
  if (!floating) return true;
  return transientVisible;
}
