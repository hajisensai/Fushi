// TODO-617 global lookup overlay — render-script builder.
//
// Mirrors dictionary_popup_webview._pushResults so the bare-WebView2 overlay
// applies the SAME configuration the in-app popup does: theme/ColorScheme
// colours, content zoom (appUiScale + dictionary font size), pitch/frequency
// dedup, collapse/hidden dictionary filtering, custom CSS, gaiji embedding, the
// no-results message, plus lookupEntries/kanjiResults. Produces one JS string
// the native side ExecuteScripts, ending in renderPopup().
//
// Theme is read from the global navigator context (AppModel.navigatorKey), so
// no BuildContext needs to be threaded from the (UI-less) controller.

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:hibiki/src/models/app_model.dart';
import 'package:hibiki/src/pages/implementations/popup_settings_injection.dart';
import 'package:hibiki_dictionary/hibiki_dictionary.dart';
import 'package:hibiki/src/lookup/global_lookup_layout.dart';
import 'package:hibiki/src/lookup/global_lookup_stack.dart';
import 'package:hibiki/src/reader/popup_swipe_close_script.dart';

// TODO-867 P3c — buildOverlayRenderScript (the single-frame TOP-LEVEL direct
// renderPopup path) is RETIRED. The top-level WebView2 document is now
// global_lookup_host.html (a bare iframe host with zero popup.js instance), so
// nothing can call window.renderPopup() at the top level. The single-frame
// lookup is stack depth 1: it renders through buildStackRenderScript ->
// window.__globalLookupHost.renderStack, exactly like a nested card, using
// buildFrameSettingsJs below for its per-frame settings body. The off-screen
// self-measure / top-pull gesture wiring that used to live here moves to the
// host (P3c阶段 D/E); per-frame settings keep their own theme/zoom/entries.

/// Builds the per-frame settings JS body for ONE lookup card (TODO-867 P3b
/// nested stack). TODO-895: this now delegates to the SINGLE source of truth
/// [buildPopupSettingsJs] (shared with the in-app popup _pushResults) with
/// [PopupSettingsOptions.globalLookup] = true, then appends the host reset hooks
/// + renderPopup() this per-frame realm needs. Sharing the body keeps the
/// app-outside window in lock-step with the in-app popup (dictionary font, zoom
/// clamp, autoExpandDictionaries, all window.* flags) so the two can never drift
/// again. It deliberately omits the in-app load-more / instant-scroll wiring —
/// those belong to the in-app popup, not to an iframe inside the host shell.
///
/// The string is meant to be eval'd INSIDE a frame's contentWindow by
/// global_lookup_host.js injectContent, so every `window.` / `document.`
/// reference targets that frame's own realm.
String buildFrameSettingsJs({
  required BuildContext context,
  required AppModel appModel,
  required DictionarySearchResult result,
  String sentence = '',
  double cardBgAlpha = 1.0,
  bool panelRoot = false,
  int sentenceHitStart = -1,
  int sentenceHitLength = 0,
  bool sentenceOnly = false,
}) {
  final String settingsJs = buildPopupSettingsJs(
    appModel: appModel,
    theme: Theme.of(context),
    result: result,
    options: const PopupSettingsOptions(globalLookup: true),
  );
  // spec 2026-07-10 §6 — 半透明卡背景变量。面板路径传用户值（且仅当 Win11
  // acrylic backdrop 可用），瞬态窗恒 1.0；in-app 路径不经此处。**恒注入**当前
  // 值（审查修正：面板 WebView 常驻不重建，若 1.0 时不注入，从 0.85 调回 100%
  // 后 documentElement 上的旧 0.85 残留、面板停在半透明）。同一 alpha 下
  // settingsJs 跨渲染字节稳定（host 以 settingsJs 变更为重渲判据）。
  final String cardBgAlphaLine =
      "document.documentElement.style.setProperty('--hibiki-card-bg-alpha', "
      "'${cardBgAlpha.toStringAsFixed(2)}');\n";
  // TODO-1231 P1 — `window.__hasChildPopup` is DELIBERATELY NOT part of this body
  // anymore. The flag flips whenever a child card opens/closes on top of THIS
  // frame, but everything else in the body (theme/zoom/entries/sentence) is
  // invariant across that. Baking the flag in (TODO-1067 子4) made the parent's
  // settingsJs change on every nested open/close, so global_lookup_host.js
  // re-eval'd the WHOLE body — which ends in renderPopup() = a full card DOM
  // teardown+rebuild (scroll lost, favorite/duplicate/audio probes re-fired):
  // the visible "父弹窗闪烁". The flag now rides its OWN per-frame descriptor
  // channel (see buildStackRenderScript -> host applyHasChildPopup), so the body
  // stays byte-identical and the host can SKIP the re-render. This mirrors the
  // in-app _setHasChildPopupJs, which is likewise a lone evaluateJavascript,
  // never part of _pushResults. BUG-434 behaviour (parent-card tap closes the
  // child) is preserved — popup.js reads the flag live at click time.
  //
  // TODO-1067 (子2) — inject the shared top-pull swipe-close JS
  // (kPopupTopPullReleaseJs) into the overlay iframe too. It was only injected on
  // the in-app popup path; the overlay iframe never received it, so the desktop
  // "swipe down to close" gesture was dead in the app-external window. The JS
  // self-guards against double-install (window.__hoshiTopPullInstalled) and
  // reports through flutter_inappwebview.callHandler('topPullReleased'), which
  // the controller already gates on the enableSwipeToClose preference.
  // 真机第 4 轮 — 仅面板 root 注入选词区标记 + 引擎命中区间（码点下标；
  // popup.js 句子条据此走 panelSentenceLookup 原地更新语义并整词高亮）。
  // 非面板帧（瞬态窗 / 嵌套子卡）恒为空串：同一帧同一结果下 settingsJs 跨
  // 渲染字节稳定（host 以 settingsJs 变更为重渲判据），面板语义永不外溢。
  final String panelRootLines = panelRoot
      ? 'window.__globalLookupPanelRoot = true;\n'
          '    window.__globalLookupSentenceHit = '
          '{start: $sentenceHitStart, length: $sentenceHitLength};\n'
      : '';
  // 剪切板「关自动查词」纯文字态：面板只显示句子横幅（逐字可点），不显示词典结果。
  // 传入的是空结果（无 entries），popup.js 会渲染句子横幅 + 一块「No results」提示；
  // 这里在 renderPopup 之后就地摘掉那块提示节点，达成「只剩文字」。仅面板 root、仅
  // sentenceOnly 时注入，故自动查词路径 settingsJs 逐字节不变（host 以此判重渲）。
  // 走 app 侧渲染脚本而非改 popup.js，避开浏览器扩展三镜像 + content.css 重生成。
  final String sentenceOnlyLine = sentenceOnly
      ? 'var __hibikiNoRes = document.querySelector(".no-results"); '
          'if (__hibikiNoRes) __hibikiNoRes.remove();\n'
      : '';
  return '''
    $settingsJs
    $kPopupTopPullReleaseJs
    $cardBgAlphaLine
    if (window.resetSentenceContextMirror) window.resetSentenceContextMirror();
    if (window.resetSelectedDictionaries) window.resetSelectedDictionaries();
    window.__globalLookupSentence = ${jsonEncode(sentence)};
    $panelRootLines
    window.renderPopup && window.renderPopup();
    $sentenceOnlyLine
''';
}

/// One stacked lookup card as the host script expects it (TODO-867 P3b/P3c).
/// [frame] supplies the stack identity/linkage (id, parentIndex); [result]
/// supplies the per-frame entries; [anchorRect] is the screen-space CSS px
/// anchor (the cursor for the root, the clicked word for a child) the card
/// cascades off of via [computeFrameRect]; [isVertical] selects the vertical-
/// writing (left/right) cascade. anchorRect null falls back to the placeholder
/// fan-out offset ([kGlobalLookupCascadeStep]).
class GlobalLookupFramePayload {
  const GlobalLookupFramePayload({
    required this.frame,
    required this.result,
    this.anchorRect,
    this.isVertical = false,
    this.sentence = '',
    this.sentenceOnly = false,
  });

  final GlobalLookupFrame frame;
  final DictionarySearchResult result;

  /// 剪切板「关自动查词」纯文字态：只渲染句子横幅、摘掉「No results」结果块。
  /// 仅面板 root 帧有意义（子卡/瞬态窗恒 false）。
  final bool sentenceOnly;

  /// TODO-1030 M0 — the current sentence to show as a context banner in this
  /// card (only the ROOT frame carries it; empty = no banner). Body text stays
  /// inside the frame realm and is never logged.
  final String sentence;

  /// Screen-space CSS px anchor rect (selection / clicked word). Null when the
  /// caller has no anchor yet (placeholder cascade offset is used instead).
  final Rect? anchorRect;

  /// Vertical-writing book (the cascade goes left/right instead of up/down).
  final bool isVertical;
}

/// TODO-938 — resolves the cascade vertical-writing flag for a global-lookup
/// stack from the active reader's [ReaderSettings.writingMode]. The
/// bare-WebView2 overlay can pop up over ANY foreground app, so there may be no
/// active reader (no book open) — in that case [writingMode] is null and we
/// fall back to false (horizontal cascade), exactly as before. When a
/// vertical-writing book IS the last-active reader, nested lookup cards cascade
/// left/right instead of up/down, matching the in-app reader's own判据
/// ([ReaderContentStyles] uses the same `writingMode.startsWith('vertical')`).
/// This is the ONE field the app-outside path still hardcoded; everything else
/// (theme/zoom/font/flags) already flows through the shared
/// [buildPopupSettingsJs] (TODO-895).
bool isVerticalFromWritingMode(String? writingMode) =>
    writingMode?.startsWith('vertical') ?? false;

/// Deterministic placeholder cascade offset (CSS px) per stack depth, used ONLY
/// when a frame has no real [GlobalLookupFramePayload.anchorRect] yet (defensive
/// fallback). With a real anchor the geometry comes from [computeFrameRect].
const double kGlobalLookupCascadeStep = 28.0;

/// TODO-867 P3c E1 — the off-screen measurement window is sized to the cascade
/// LAYOUT BOUNDS = card size × these factors (window-local CSS px), giving a
/// nested child room to cascade beside the root during measurement before D2's
/// union bbox trims the window to the real extent. Tuned conservatively; the
/// real-device fit is the user's call (the bbox is the authoritative final size).
const double kGlobalLookupLayoutBoundsWidthFactor = 2.4;
const double kGlobalLookupLayoutBoundsHeightFactor = 2.0;

/// TODO-1095 — the STABLE root frame id reused across hotkey lookups. Before
/// this, every hotkey lookup minted a fresh `frame-N` id, so the host tore the
/// root popup.html iframe down (removeMissing) and rebuilt it (createRecord ->
/// async iframe load -> injectContent), re-paying the cold per-lookup iframe
/// cost the TODO-1079 top-level prewarm could not cover. Keeping the root id
/// constant lets the host REUSE the already-loaded root iframe and just re-inject
/// the new card's settingsJs (re-render in place), so the card is warm on the
/// second lookup onward. Nested child frames keep their own monotonic ids (they
/// are genuinely added/removed), so only the root/card layer is pinned.
const String kGlobalLookupRootFrameId = 'global-lookup-root';

/// TODO-1095 — builds the host `beginLookup(rootId)` prelude script prepended to
/// each fresh root render (see [GlobalLookupController]). It tells the host a NEW
/// hotkey lookup is starting so it (a) clears the union-bbox de-dup key
/// (lastBBoxKey) — the reveal-driving overlaySize of the new card is otherwise
/// suppressed when its bbox equals the previous lookup's — and (b) RE-GATES the
/// reused root shell's content-ready flag so the reveal waits for the NEW card's
/// popupRendered instead of inheriting the previous lookup's already-satisfied
/// gate (the mislevelled-ready root cause: reveal fired before the fresh iframe
/// card actually rendered = "audio plays but the popup is blank/absent"). Inert
/// when the host is not installed (guarded, mirroring buildStackRenderScript).
String buildBeginLookupScript(String rootId) {
  final String encodedId = jsonEncode(rootId);
  return 'window.__globalLookupHost && '
      'window.__globalLookupHost.beginLookup($encodedId);';
}

/// TODO-1190 — builds the host `highlightFrame(frameIndex, count)` script that
/// marks the searched word inside a PARENT frame's popup.js realm after a nested
/// lookup (parity with the in-app popup, which highlights the clicked word in
/// the parent card via [DictionaryPopupWebView.highlightSelection]). [frameIndex]
/// is the parent's insertion-order stack depth (0 = root); [count] is the matched
/// char count ([lookupHighlightCharCount]). Inert when the host is not installed
/// (guarded) and a no-op host-side on a bad index / non-positive count.
String buildHighlightFrameScript(int frameIndex, int count) {
  return 'window.__globalLookupHost && '
      'window.__globalLookupHost.highlightFrame($frameIndex, $count);';
}

/// Builds the full stack render script for the host (TODO-867 P3b/P3c).
/// Serialises every frame into the `{ popups: [...] }` payload
/// global_lookup_host.js renderStack consumes, then calls
/// window.__globalLookupHost.renderStack(...).
///
/// Each popup carries: id, parentIndex, a real cascade `frame` rect
/// (left/top/width/height, CSS px) computed from the payload's anchorRect via
/// [computeFrameRect], and a `settingsJs` string (this frame's own
/// buildFrameSettingsJs body, run inside its iframe realm). The single-frame
/// overlay path was retired in commit-2 (the top-level document is now
/// global_lookup_host.html); a single frame is stack depth 1 rendered the SAME
/// way as a nested card through renderStack — this is the only render path.
///
/// [screenWidth]/[screenHeight] and [maxWidth]/[maxHeight] are CSS / logical px
/// (NOT physical — see global_lookup_layout coordinate rule): the dpr boundary
/// is the C++ window geometry, never this layout math.
String buildStackRenderScript({
  required BuildContext context,
  required AppModel appModel,
  required List<GlobalLookupFramePayload> payloads,
  required double screenWidth,
  required double screenHeight,
  required double maxWidth,
  required double maxHeight,
  Offset selectionScreenOffset = Offset.zero,
  double originFloorLeft = 0,
  double originFloorTop = 0,
  // spec 2026-07-10 — 'panel' = 常驻剪贴板面板（root 撑满固定视口、host 短路
  // measureAndReport）。默认 'cascade' 时 payload 不带 layoutMode 键，瞬态窗
  // 载荷与改动前逐字节相同（Never break userspace）。
  String layoutMode = 'cascade',
  double cardBgAlpha = 1.0,
  // 真机第 4 轮 — 面板选词区的引擎命中区间（码点下标），只作用于面板 root
  // 帧的 settingsJs；cascade 模式忽略。
  int sentenceHitStart = -1,
  int sentenceHitLength = 0,
  // 阶段三 — 面板栏「悬停显示」(peek)：仅面板模式携带，host 据此收起/常显面板栏。
  bool peek = false,
}) {
  // TODO-867 P3c F2 — the host shell (.global-lookup-frame-shell) is built in the
  // TOP-LEVEL host document, which carries no data-theme of its own (the theme
  // vars live INSIDE each iframe). So the shell's dark/light border variant can't
  // read a CSS var; stamp the resolved brightness onto each popup descriptor and
  // host.js sets data-theme on the shell.
  final String shellTheme =
      Theme.of(context).brightness == Brightness.dark ? 'dark' : 'light';
  // TODO-1231（BUG-583/670 续）——根卡（anchorless 分支）的工作区钳位偏移。根卡是
  // 级联里唯一不经 computeFrameRect clamp 的卡；reserve-to-edge 地板把 C++ 的窗口
  // 右/下 clamp 变成 no-op 后，光标靠屏右/下时根卡越出工作区被窗口边裁掉（「弹窗
  // 直接生成在窗口外面」）。这里用与子卡同语义的 clamp 把根卡钳回工作区；偏移恒
  // >= -cursorWork（= 地板），窗口原点仍从首帧冻结，父卡零位移保证不回退。
  final ({double left, double top}) rootShellOffset = computeRootShellOffset(
    cursorWorkX: selectionScreenOffset.dx,
    cursorWorkY: selectionScreenOffset.dy,
    screenWorkW: screenWidth,
    screenWorkH: screenHeight,
    cardW: maxWidth,
    cardH: maxHeight,
  );
  final List<Map<String, Object?>> popups = <Map<String, Object?>>[];
  for (int i = 0; i < payloads.length; i++) {
    final GlobalLookupFramePayload p = payloads[i];
    final bool isPanelRoot = layoutMode == 'panel' && p.frame.parentIndex < 0;
    final String settingsJs = buildFrameSettingsJs(
      context: context,
      appModel: appModel,
      result: p.result,
      sentence: p.sentence,
      cardBgAlpha: cardBgAlpha,
      panelRoot: isPanelRoot,
      sentenceHitStart: isPanelRoot ? sentenceHitStart : -1,
      sentenceHitLength: isPanelRoot ? sentenceHitLength : 0,
      sentenceOnly: isPanelRoot && p.sentenceOnly,
    );
    final Map<String, Object?> map = p.frame.toRenderMap();
    map['theme'] = shellTheme;
    // TODO-1231 P1 / TODO-1067 (子4) — a frame has a child popup iff it is not the
    // deepest (last) frame in the stack, mirroring the in-app `index <
    // entries.length - 1` derivation (BUG-434). Carried as its OWN descriptor
    // field (NOT baked into settingsJs) so a nested open/close leaves the parent
    // body byte-identical and the host skips the full re-render; host.js
    // applyHasChildPopup evals only this one boolean inside the frame realm.
    map['hasChildPopup'] = i < payloads.length - 1;
    map['frame'] = _frameRectMap(
      anchorRect: p.anchorRect,
      depth: i,
      screenWidth: screenWidth,
      screenHeight: screenHeight,
      maxWidth: maxWidth,
      maxHeight: maxHeight,
      isVertical: p.isVertical,
      selectionScreenOffset: selectionScreenOffset,
      rootShellOffset: rootShellOffset,
    );
    map['settingsJs'] = settingsJs;
    popups.add(map);
  }
  final Map<String, Object?> payloadObj = <String, Object?>{'popups': popups};
  // spec 2026-07-10 — 仅面板模式携带 layoutMode 键；cascade 载荷字节不变。
  if (layoutMode == 'panel') {
    payloadObj['layoutMode'] = 'panel';
    // 阶段三 — 面板栏悬停显示：仅面板模式且开启时携带，cascade/关闭时载荷不变。
    if (peek) {
      payloadObj['peek'] = true;
    }
  }
  // TODO-1345 (BUG-583 深层根因续) — reserve cascade headroom toward the screen
  // interior so an up/left child lands INSIDE the window origin committed at the
  // first reveal; the host's measureAndReport then never moves the origin when the
  // child appears -> the pinned parent card has ZERO displacement (extends the
  // down-right zero-lurch guarantee to up/left). Only carried when it actually
  // reserves something (< 0), so a down-right / edge lookup sends the pre-fix
  // payload verbatim (Never break userspace).
  if (originFloorLeft < 0 || originFloorTop < 0) {
    payloadObj['originFloor'] = <String, Object?>{
      'left': originFloorLeft,
      'top': originFloorTop,
    };
  }
  final String payloadJson = jsonEncode(payloadObj);
  return 'window.__globalLookupHost && '
      'window.__globalLookupHost.renderStack($payloadJson);';
}

/// Resolves ONE frame's shell rect (CSS px) for the host payload. With a real
/// [anchorRect] it runs the ported hoshi cascade ([computeFrameRect]); with no
/// anchor it falls back to a placeholder fan-out at [kGlobalLookupCascadeStep] *
/// [depth] sized to maxWidth/maxHeight (so a stack is still visibly distinct).
Map<String, Object?> _frameRectMap({
  required Rect? anchorRect,
  required int depth,
  required double screenWidth,
  required double screenHeight,
  required double maxWidth,
  required double maxHeight,
  required bool isVertical,
  Offset selectionScreenOffset = Offset.zero,
  ({double left, double top}) rootShellOffset = (left: 0.0, top: 0.0),
}) {
  if (anchorRect != null && screenWidth > 0 && screenHeight > 0) {
    // TODO-893 v2 (symptom 3) — the host re-anchored the child's word rect to
    // WINDOW-LOCAL CSS px (relative to the shell origin = the cursor), but
    // screenW/H are the work-area dimensions (absolute display domain). Their
    // zero points differ, so feeding a window-local selY straight in mis-decided
    // showBelow near the screen bottom edge (spaceBelow over-estimated) and
    // shoved the parent card off the top. Lift the anchor into the SAME
    // work-area-absolute domain (add the window origin's work-area offset) for
    // the cascade math, then shift the result back to window-local for the host
    // shell. computeFrameRect stays a pure single-domain function (unchanged).
    final Rect shiftedAnchor = anchorRect.shift(selectionScreenOffset);
    final GlobalLookupFrameRect r = computeFrameRect(
      selectionRect: shiftedAnchor,
      screenW: screenWidth,
      screenH: screenHeight,
      maxWidth: maxWidth,
      maxHeight: maxHeight,
      isVertical: isVertical,
    );
    return <String, Object?>{
      'left': r.left - selectionScreenOffset.dx,
      'top': r.top - selectionScreenOffset.dy,
      'width': r.width,
      'height': r.height,
    };
  }
  // TODO-1189 — anchorless fallback. The old diagonal (left=top=offset) IGNORED
  // the writing mode and stepped every layer DOWN-RIGHT, so a vertical-writing
  // cascade drifted over the following kana columns. Step along the writing
  // mode's SECONDARY axis only (never diagonally), mirroring computeFrameRect's
  // real cascade axis: horizontal writing stacks DOWN (top), vertical writing
  // stacks to the RIGHT (left) — the same side computeFrameRect prefers via
  // showOnRight. The root (depth 0) still lands at the window origin (offset 0),
  // so a single-frame lookup is unchanged. This branch is only reached when a
  // frame has no real anchorRect (host failed to re-anchor); with an anchor the
  // geometry comes from computeFrameRect above.
  // TODO-1231（BUG-583/670 续）——anchorless 卡（根卡 depth 0 + 防御性 fan-out）以
  // rootShellOffset 为基底：根卡从「恒钉 window-local (0,0) = 光标+8」改为「光标+8
  // 经工作区钳位」（见 computeRootShellOffset），光标四周空间充足时偏移 (0,0) 逐字节
  // 等于旧几何；防御性 fan-out（host 未能 re-anchor 的子卡）跟随根卡基底以保持贴近。
  final double offset = kGlobalLookupCascadeStep * depth;
  return <String, Object?>{
    'left': rootShellOffset.left + (isVertical ? offset : 0.0),
    'top': rootShellOffset.top + (isVertical ? 0.0 : offset),
    'width': maxWidth,
    'height': maxHeight,
  };
}
