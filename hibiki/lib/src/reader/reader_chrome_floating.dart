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

/// Font size (logical px) of the top progress pill text (historical `12`).
const double kTopProgressFontSize = 12;

/// Vertical padding (logical px) on EACH side of the frosted pill's content,
/// added by BUG-547 / TODO-1136 (the `EdgeInsets.symmetric(vertical: …)` in
/// `_buildTopProgressBar`). Shared here so the reserved strip height below and
/// the pill both read the SAME constant — the frosted layer added this padding
/// but the old reserve never counted it, so the taller pill sat over the first
/// body line in squeeze mode (BUG-470-adjacent overlap, all platforms).
const double kTopProgressPillVerticalPadding = 3;

/// Reserved strip height (logical px) for the top progress pill in squeeze mode.
///
/// Must be ≥ the pill's rendered height so the body text never sits under it
/// (the 铁律 in this file's header). The pill's height = a text line box +
/// [kTopProgressPillVerticalPadding] on both sides:
///  * `kTopProgressFontSize * 1.5` is the historical line-box estimate (a real
///    font's ascent+descent overflow the em box by ~1.17–1.4×; 1.5 keeps slack).
///  * `+ 2 * kTopProgressPillVerticalPadding` counts the frosted pill padding
///    that BUG-547 added but forgot to reserve for.
const double kTopProgressStripHeight =
    kTopProgressFontSize * 1.5 + 2 * kTopProgressPillVerticalPadding;

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

/// Whether the bottom control bar should be painted right now.
///
/// 挤压态随 [chromeExpanded]（`_showChrome`）；悬浮态额外受 [transientVisible]
/// 门控（点击唤出、计时自动收起）。[hasEverLoaded] 是首次冷加载完成前不画底栏的
/// 既有门控。与 [topProgressVisible] 同构，是「底栏此刻可见吗」的唯一真相源，
/// 同时被 [readerVnBlankTapAction] 复用（BUG-1195）。
bool bottomBarVisible({
  required bool hasEverLoaded,
  required bool chromeExpanded,
  required bool floating,
  required bool transientVisible,
}) {
  if (!hasEverLoaded || !chromeExpanded) return false;
  if (!floating) return true;
  return transientVisible;
}

/// BUG-1195：视觉小说（VN）模式下一次「空白点击」的归宿。
enum ReaderVnBlankTapAction {
  /// 挤压态底栏被收起（`_showChrome == false`）：先把底栏展开。
  expandChrome,

  /// 悬浮态底栏已收起：先唤出（并武装自动收起）。
  revealFloatingChrome,

  /// 底栏此刻可见：本次空白点击才推进到下一屏。
  advance,
}

/// BUG-1195：VN 模式空白点击的分派——**唤出控制栏优先于翻页**。
///
/// 根因回顾：VN 是唯一把「点空白」绑成翻页的 view-mode，而点空白同时是触屏**唯一**
/// 能唤出控制栏的手势（分页/连续模式的 `onTapEmpty` → `_handleFloatingChromeReveal`
/// / `_toggleChrome`）。`tap_empty_hide_chrome` 默认 true ⇒ 底栏是悬浮态、几秒后自动
/// 收起，于是 VN 下底栏一收起就再也叫不回来：点文字=查词、点空白=翻页，没有第三条路。
///
/// 消除这个特例的办法不是再加一个「菜单专用热区」（那是给坐标发明魔数），而是给同一个
/// 信号定优先级：**控制栏不可见时，这一下先把它叫出来；可见时才翻页**。与仓库既有语义
/// 同款——防剧透图「揭开优先」（先揭开、再长按才出菜单）、歌词模式点空白无条件唤出底栏
/// （「歌词没有别的唤出途径，绝不能被它关死」）。VN 的滑动翻页不经此路径，所以用户永远
/// 不会被卡在「翻不动页」的状态。
///
/// 参数与 [bottomBarVisible] 同源（`hasEverLoaded` 在此恒真：能点到 VN 屏就说明内容
/// 已就绪），故三态判定与底栏实际绘制条件逐条对齐，不会出现「判为可见但没画出来」。
ReaderVnBlankTapAction readerVnBlankTapAction({
  required bool chromeExpanded,
  required bool bottomBarFloating,
  required bool transientVisible,
}) {
  if (!chromeExpanded) return ReaderVnBlankTapAction.expandChrome;
  if (bottomBarFloating && !transientVisible) {
    return ReaderVnBlankTapAction.revealFloatingChrome;
  }
  return ReaderVnBlankTapAction.advance;
}

/// Whether the top progress pill paints a frosted-glass (BackdropFilter blur +
/// translucent fill) background behind its text — single source of truth for
/// `_buildTopProgressBar`'s pill branch.
///
/// BUG-887: the frost only makes sense when [floating] — there the pill is a
/// [Positioned] overlay genuinely on top of the body text, so a complex/light
/// background needs the frost for legibility. In squeeze mode the strip reserves
/// its own height and the body is pushed BELOW it, so the pill sits over the
/// body's blank top margin (the theme background), not over text; a frost there
/// is pointless and reads as a blurred rectangle hugging the first body line
/// (worst on glyphs with a stroke at the very top, e.g. 「一」「ー」). So squeeze
/// mode renders plain text with no blur and no fill.
bool topProgressUsesFrostedGlass({required bool floating}) => floating;

/// Whether the frosted pill actually runs its [BackdropFilter] blur this frame.
///
/// BUG-969: [BackdropFilter] re-samples the backdrop and re-runs the gaussian
/// blur on EVERY rasterized frame — even when nothing in the pill changed. With
/// the reader quick-settings sheet open ([obscured]), the pill sits dimmed
/// under the modal scrim where the blur is visually indistinguishable from the
/// plain translucent fill, yet every scroll frame of the sheet still pays the
/// saveLayer + blur readback — measurable at 120Hz. So while obscured the pill
/// keeps its translucent fill (shape/legibility unchanged) but skips the blur.
bool topProgressPillShowsBlur({
  required bool floating,
  required bool obscured,
}) =>
    topProgressUsesFrostedGlass(floating: floating) && !obscured;
