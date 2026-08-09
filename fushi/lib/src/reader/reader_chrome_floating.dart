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

import 'package:flutter/painting.dart';

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

/// BUG-379 / BUG-1343 / BUG-1381：**独立 HTML 文档**（歌词模式 [LyricsModeHtml]、
/// spread 整页图）的 WebView 四周留白，是「阅读器页给独立文档留多少空间」的唯一真相源。
///
/// 为什么独立文档要 Flutter 侧留白、正文不用：正文经 `_applyChromeInsets` 把预留高
/// 下发给 `window.fushiReader`，由页内 CSS 收缩 body；独立 HTML 没有这个桥，
/// `_applyChromeInsets` 对它整体 early-return，于是只能由 Flutter 侧收缩视口本身。
///
///  * **底部**（BUG-379）：歌词 WebView 原本 `Positioned.fill` 铺满全屏，底栏
///    （`_buildAudiobookBar`，bottom:0）盖在其上，歌词文档级 CSS 滚动条沿整屏高度绘制，
///    底部一段被画进底栏区域 → 看上去像「进度条跑进底栏」。留 [bottomReserve] 后视口
///    不再与底栏重叠。[chromeOccupiesLayout] 就是底栏的占位条件
///    （`_hasEverLoaded && _showChrome`，与 [bottomChromeReserve] 同一门控），
///    [bottomReserve] 已含悬浮态恒 0 的语义（悬浮不占正文位置）。
///    spread 不需要底部留白：它没有文档级滚动条，底栏叠在整页图上是既有可接受形态。
///  * **顶部**（BUG-1343）：macOS 顶部 DragToMoveArea 叠在 WebView 之上，独立文档若不
///    缩进，首行歌词 / 整页图会落到拖拽区下面且无法交互。[titlebarInset] 在非 macOS 恒 0。
///
/// 返回 [EdgeInsets.zero] 表示「无需任何留白」，调用方据此跳过 `Padding` 包装。
EdgeInsets independentDocumentInsets({
  required bool lyricsMode,
  required bool spreadDocumentLoaded,
  required bool chromeOccupiesLayout,
  required double bottomReserve,
  required double titlebarInset,
}) {
  final bool independentDocument = lyricsMode || spreadDocumentLoaded;
  return EdgeInsets.only(
    top: independentDocument ? titlebarInset : 0,
    bottom: lyricsMode && chromeOccupiesLayout ? bottomReserve : 0,
  );
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
/// 既有门控。与 [topProgressVisible] 同构，是「底栏此刻可见吗」的唯一真相源
/// （`_bottomBarShouldPaint` 委托到这里，BUG-1195）。
///
/// [readerVnBlankTapAction] 读取同一个 [transientVisible] 真值，保证“本次是在唤栏”
/// 与“本次可以推进”不会漂成两个同时发生的动作。
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
  /// 挤压态底栏被收起（`_showChrome == false`）：只把底栏展开，**不翻页**。
  ///
  /// 挤压态展开会改预留高 → `_applyChromeInsets` 触发 reflow 与重锚；同一下再叠一次
  /// `_paginate` 的 caret 重锚就是两套重锚打架。而且挤压态是**持久开关**：展开一次之后
  /// 就一直在，这笔「少翻一页」的代价一个阅读会话只付一次，不是每屏都付。
  expandChrome,

  /// 悬浮底栏已自动收起：只唤出底栏，不推进。
  revealChrome,

  /// 悬浮态且底栏已经可见：推进到下一屏，同时重新武装自动收起计时。
  ///
  /// 悬浮态显隐不改预留高（悬浮恒 0，见 `_handleFloatingChromeReveal` 处注释），纯显隐
  /// 不重锚，所以同一下里翻页 + 唤栏互不干扰。
  advanceAndRevealChrome,

  /// 底栏本来就常驻可见（挤压态且已展开）：只推进到下一屏。
  advance,
}

/// BUG-1195 / BUG-1245：VN 模式空白点击的分派。
///
/// 根因回顾：VN 是唯一把「点空白」绑成翻页的 view-mode，而点空白同时是触屏**唯一**
/// 能唤出控制栏的手势（分页/连续模式的 `onTapEmpty` → `_handleFloatingChromeReveal`
/// / `_toggleChrome`）。`tap_empty_hide_chrome` 默认 true ⇒ 底栏是悬浮态、几秒后自动
/// 收起，于是 VN 下底栏一收起就再也叫不回来：点文字=查词、点空白=翻页，没有第三条路。
///
/// BUG-1245 的用户验收把交互边界说清楚：当空白点击的可见结果是“底栏出来”，这一击
/// 不能同时推进，否则用户只是想操作菜单却丢了当前句。故悬浮态必须读
/// [transientVisible]：隐藏→[ReaderVnBlankTapAction.revealChrome]，可见才推进。
/// 滑动、键盘等翻屏入口不经这里，仍可单击推进；这只是把一次点击收敛成一个主动作。
///
/// 挤压态（[chromeExpanded] 为 false）例外，不在这一下翻页，理由见
/// [ReaderVnBlankTapAction.expandChrome]。VN 的滑动翻页不经此路径，用户永远不会被卡在
/// 「翻不动页」的状态。
///
ReaderVnBlankTapAction readerVnBlankTapAction({
  required bool chromeExpanded,
  required bool bottomBarFloating,
  required bool transientVisible,
}) {
  if (!chromeExpanded) return ReaderVnBlankTapAction.expandChrome;
  if (bottomBarFloating && !transientVisible) {
    return ReaderVnBlankTapAction.revealChrome;
  }
  if (bottomBarFloating) {
    return ReaderVnBlankTapAction.advanceAndRevealChrome;
  }
  return ReaderVnBlankTapAction.advance;
}

/// 执行 VN 空白点击决策。把“隐藏时只 reveal、可见时 reveal+advance”的组合收敛为
/// 可行为测试的生产分派器，避免页面 switch 与纯谓词各自漂移。
void dispatchReaderVnBlankTapAction(
  ReaderVnBlankTapAction action, {
  required void Function() expandChrome,
  required void Function() revealChrome,
  required void Function() advance,
}) {
  switch (action) {
    case ReaderVnBlankTapAction.expandChrome:
      expandChrome();
    case ReaderVnBlankTapAction.revealChrome:
      revealChrome();
    case ReaderVnBlankTapAction.advanceAndRevealChrome:
      revealChrome();
      advance();
    case ReaderVnBlankTapAction.advance:
      advance();
  }
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
