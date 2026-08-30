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
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/pages/implementations/popup_settings_injection.dart';
import 'package:fushi_dictionary/fushi_dictionary.dart';
import 'package:fushi/src/lookup/global_lookup_layout.dart';
import 'package:fushi/src/lookup/global_lookup_stack.dart';
import 'package:fushi/src/reader/popup_swipe_close_script.dart';

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
/// clamp, autoExpandRows, all window.* flags) so the two can never drift
/// again. It deliberately omits the in-app load-more / instant-scroll wiring —
/// those belong to the in-app popup, not to an iframe inside the host shell.
///
/// The string is meant to be eval'd INSIDE a frame's contentWindow by
/// global_lookup_host.js injectContent, so every `window.` / `document.`
/// reference targets that frame's own realm.
class GlobalLookupFrameSettingsJs {
  const GlobalLookupFrameSettingsJs({
    required this.staticHeadJs,
    required this.staticTailJs,
    required this.staticRevision,
    required this.entriesJs,
    required this.renderJs,
  });

  final String staticHeadJs;
  final String staticTailJs;
  final int staticRevision;
  final String entriesJs;
  final String renderJs;

  /// Legacy/full-frame form used by source-contract tests and any caller that
  /// deliberately wants one self-contained script. The hot host path sends the
  /// four parts separately so the multi-megabyte font/static body is not copied
  /// across the platform channel on every lookup.
  String get combined => '$staticHeadJs$entriesJs$staticTailJs$renderJs';
}

GlobalLookupFrameSettingsJs buildFrameSettingsJsParts({
  required BuildContext context,
  required AppModel appModel,
  required DictionarySearchResult result,
}) {
  final PopupStaticSettingsJs staticSettings = buildPopupStaticSettingsJs(
    appModel: appModel,
    theme: Theme.of(context),
    options: const PopupSettingsOptions(globalLookup: true),
  );
  final String entriesJs = buildPopupEntriesJs(result);
  // TODO-1231 P1 — `window.__hasChildPopup` is DELIBERATELY NOT part of this body
  // anymore. The flag flips whenever a child card opens/closes on top of THIS
  // frame, but everything else in the body (theme/zoom/entries) is
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
  // self-guards against double-install (window.__fushiTopPullInstalled) and
  // reports through flutter_inappwebview.callHandler('topPullReleased'), which
  // the controller already gates on the enableSwipeToClose preference.
  //
  // 同一帧同一结果下这段 renderJs 跨渲染字节稳定（host 以 settingsJs 变更为
  // 重渲判据）：这里不得再掺任何每次查词都会变的上下文（曾经的句子横幅文本
  // 注入已随桌面剪贴板查词一并移除）。
  const String renderJs = '''
    $kPopupTopPullReleaseJs
    if (window.resetSentenceContextMirror) window.resetSentenceContextMirror();
    if (window.resetSelectedDictionaries) window.resetSelectedDictionaries();
    window.renderPopup && window.renderPopup();
''';
  return GlobalLookupFrameSettingsJs(
    staticHeadJs: staticSettings.head,
    staticTailJs: staticSettings.tail,
    staticRevision: staticSettings.revision,
    entriesJs: entriesJs,
    renderJs: renderJs,
  );
}

String buildFrameSettingsJs({
  required BuildContext context,
  required AppModel appModel,
  required DictionarySearchResult result,
}) =>
    buildFrameSettingsJsParts(
      context: context,
      appModel: appModel,
      result: result,
    ).combined;

/// One stacked lookup card as the host script expects it (TODO-867 P3b/P3c).
/// [frame] supplies the stack identity/linkage (id, parentIndex); [result]
/// supplies the per-frame entries; [anchorRect] is the screen-space CSS px
/// anchor (the cursor for the root, the clicked word for a child) the card
/// cascades off of via [computeFrameRect]. anchorRect null falls back to the
/// placeholder fan-out offset ([kGlobalLookupCascadeStep]).
///
/// BUG-859 — there is deliberately NO vertical-writing flag here: every
/// anchored frame is a word inside a popup card (always horizontal text), so
/// the cascade is always horizontal, mirroring the in-app
/// `base_source_page._layerVerticalWriting` gate (nested-from-popup layers
/// never inherit the book's writing mode).
class GlobalLookupFramePayload {
  const GlobalLookupFramePayload({
    required this.frame,
    required this.result,
    this.anchorRect,
  });

  final GlobalLookupFrame frame;
  final DictionarySearchResult result;

  /// Screen-space CSS px anchor rect (selection / clicked word). Null when the
  /// caller has no anchor yet (placeholder cascade offset is used instead).
  final Rect? anchorRect;
}

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

/// 每个**物理宿主**（一个独立的 WebView2 realm：桌面瞬态窗 / galCard 浮窗 /
/// 剪贴板面板各算一个）已经装载好的静态设置版本号集合。
///
/// BUG-1833 起，静态设置段（主题变量 + 词典字体 + 词典样式 + 自定义 CSS + 各种
/// window.* 开关）按 [PopupStaticSettingsJs.revision] 去重：宿主已经装过的版本不再
/// 随渲染负载重发。这件事非做不可——用户导入的词典字体是 `data:` URL 内联的，两个
/// CJK 字体就能让这一段到几十 MB；每次查词重发一遍，等于每次查词都往平台通道里灌
/// 几十 MB、在 WebView2 里解析一遍，然后被宿主按 revision 认出是旧相识、原样丢弃。
///
/// 这个类存在的理由是「让漏做去重在结构上不可能」：去重状态曾经由每个调用方自己
/// 拿 `Map<String, Set<int>>` 拼，而 [buildStackRenderScript] 的对应形参是**可选**
/// 的——于是剪贴板面板那条路径压根没传，整套去重对它完全失效，每次查词（包括每次
/// 在面板里点词的嵌套查词）都重发全量静态段。现在形参必填、待确认版本从返回值带
/// 出，少传一个就是编译错误。
class PopupStaticRevisionCache {
  final Map<String, Set<int>> _byHost = <String, Set<int>>{};

  /// [hostKey] 宿主当前已确认装载的版本集合的**可变副本**。
  ///
  /// 刻意不返回内部集合本身。这个类存在的全部动机就是「别让漏做去重在结构上成为
  /// 可能」，那么把「请不要改写我返回的 Set」这条纪律寄托在一句注释上就是自相矛盾
  /// ——渲染器拿到它之后本来就要往里加本次发出的版本，一不小心加到内部集合上，
  /// 就等于在平台调用还没发生时先记了账。
  Set<int> snapshotFor(String hostKey) => <int>{..._known(hostKey)};

  Set<int> _known(String hostKey) =>
      _byHost.putIfAbsent(hostKey, () => <int>{});

  /// 把本次渲染真正发出去的版本记为「已装载」。
  ///
  /// **必须等平台侧 render 调用成功之后再调**：脚本没送到宿主就先记账，会让后续
  /// 渲染以为宿主已经有这个版本而不再下发，卡片就永远拿不到主题/字体/样式。
  void commit(String hostKey, Set<int> emitted) {
    if (emitted.isEmpty) return;
    _known(hostKey).addAll(emitted);
  }

  /// 宿主自报某个版本没了（整块 WebView 恢复、iframe realm 重建等，见 host.js 的
  /// `staticSettingsRequired`），把它从已装载集合里划掉，下一次渲染重新带上。
  void invalidate(String hostKey, int revision) {
    _byHost[hostKey]?.remove(revision);
  }
}

/// [buildStackRenderScript] 的产物：要执行的脚本，以及**本次真正带上了静态段**的
/// 版本号集合。调用方在平台 render 成功后把后者交给
/// [PopupStaticRevisionCache.commit]。
typedef StackRenderScript = ({String script, Set<int> pendingRevisions});

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
String buildBeginLookupScript(
  String rootId, {
  String source = 'desktop',
  int routeEpoch = 0,
  int lookupEpoch = 0,
}) {
  final String encodedId = jsonEncode(rootId);
  final String encodedRoute = jsonEncode(<String, Object>{
    'source': source,
    'routeEpoch': routeEpoch,
    'lookupEpoch': lookupEpoch,
  });
  return 'window.__globalLookupHost && '
      'window.__globalLookupHost.beginLookup($encodedId, $encodedRoute);';
}

/// Builds the lightweight physical-stack truncate command used by close/back.
/// The surviving iframe realms already own the correct entries, render body and
/// measured card DOM, so only their stable id prefix crosses the platform
/// boundary. A full [buildStackRenderScript] remains the recovery/content-change
/// path; this command is only emitted in response to a message from the live
/// host that is being truncated.
String buildRetainStackScript(Iterable<String> frameIds) {
  final String encodedIds = jsonEncode(frameIds.toList(growable: false));
  return 'window.__globalLookupHost && '
      'window.__globalLookupHost.retainStack($encodedIds);';
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

/// BUG-1127 — builds the host `playWordAudioInFrame(frameId, url, token)` script
/// that drives the overlay auto-read through the popup's own HTML5 `<audio>`
/// (the unified fast path, 9855c3e4f), replacing the libmpv stop→load→play
/// round-trip the app-external overlay was left on. The target is the STABLE
/// root frame ([kGlobalLookupRootFrameId]): its popup.js realm is prewarmed at
/// startup and REUSED across lookups (TODO-1095), so playback needs no cold
/// iframe wait — audio is realm-agnostic (`new Audio(url)`), only the loaded
/// realm matters, not the frame the entry renders in. The iframe reports the
/// real `audio.play()` outcome back as a `wordAudioPlayed` [token] message
/// (host-stamped bridge), mirroring the in-app `wordAudioPlayed` handler
/// contract (BUG-1093). Inert when the host is not installed (guarded).
String buildPlayWordAudioScript(String frameId, String url, int token) {
  final String encodedId = jsonEncode(frameId);
  final String encodedUrl = jsonEncode(url);
  return 'window.__globalLookupHost && '
      'window.__globalLookupHost.playWordAudioInFrame('
      '$encodedId, $encodedUrl, $token);';
}

/// Builds the full stack render script for the host (TODO-867 P3b/P3c).
/// Serialises every frame into the `{ popups: [...] }` payload
/// global_lookup_host.js renderStack consumes, then calls
/// window.__globalLookupHost.renderStack(...).
///
/// Each popup carries: id, parentIndex, a real cascade `frame` rect
/// (left/top/width/height, CSS px) computed from the payload's anchorRect via
/// [computeFrameRect], plus a static revision and the per-lookup entries/render
/// bodies. Only a revision unknown to the physical host carries the static
/// head/tail (which may include a multi-megabyte font). The single-frame overlay
/// path was retired in commit-2 (the top-level document is now
/// global_lookup_host.html); a single frame is stack depth 1 rendered the SAME
/// way as a nested card through renderStack — this is the only render path.
///
/// [screenWidth]/[screenHeight] and [maxWidth]/[maxHeight] are CSS / logical px
/// (NOT physical — see global_lookup_layout coordinate rule): the dpr boundary
/// is the C++ window geometry, never this layout math.
StackRenderScript buildStackRenderScript({
  required BuildContext context,
  required AppModel appModel,
  required List<GlobalLookupFramePayload> payloads,
  required double screenWidth,
  required double screenHeight,
  required double maxWidth,
  required double maxHeight,
  Offset selectionScreenOffset = Offset.zero,
  // Desktop reserves its HWND origin toward the monitor edge. galCard passes
  // zero for both floors: with a non-zero game root origin, reserving back to
  // the viewport's top-left would create a mostly-transparent near-viewport
  // union instead of allowing the live surface to grow only where a child lands.
  double originFloorLeft = 0,
  double originFloorTop = 0,
  // BUG-1835 — screenWidth/Height is the FULL game viewport while maxWidth/
  // Height remains the SINGLE-CARD cap. The gal route uses the same above/below,
  // anchor-side height fitting as the in-app dictionary layer; otherwise a
  // nearly full-height child is clamped across the selected word. Keep this
  // opt-in so the desktop global-lookup cascade remains unchanged.
  bool fitNestedHeightToAnchorSide = false,
  // BUG-1833 — static settings revisions already acknowledged by this physical
  // host. The stable root iframe survives lookup-to-lookup, so a custom font
  // (two CJK faces already run to tens of MB once base64-inlined) must not ride
  // the platform message on every lookup. Unknown/new frames still receive a
  // self-contained static payload.
  //
  // 这两个参数**必填**，而且是同一件事的两半：从哪个宿主的账本上查（[hostKey]），
  // 查到的账本是谁（[staticRevisions]）。曾经它们是带默认值的可选参数，剪贴板面板
  // 那条调用路径就那么静默地一个都没传，去重对它完全失效——每次查词重发几十 MB。
  // 必填之后，少传就是编译错误。本次真正发出去的版本从返回值的 pendingRevisions
  // 带出，调用方在 render 成功后 commit。
  required PopupStaticRevisionCache staticRevisions,
  required String hostKey,
}) {
  // 本次渲染开始时宿主已装载的版本（副本）；下面每发出一个新版本就往里加，
  // 同一次调用内的后续帧据此不再重复携带同一份静态段。
  final Set<int> availableStaticRevisions =
      staticRevisions.snapshotFor(hostKey);
  final Set<int> emittedStaticRevisions = <int>{};
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
    final GlobalLookupFrameSettingsJs settings = buildFrameSettingsJsParts(
      context: context,
      appModel: appModel,
      result: p.result,
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
      selectionScreenOffset: selectionScreenOffset,
      rootShellOffset: rootShellOffset,
      fitNestedHeightToAnchorSide: fitNestedHeightToAnchorSide,
    );
    map['staticRevision'] = settings.staticRevision;
    map['entriesJs'] = settings.entriesJs;
    map['renderJs'] = settings.renderJs;
    if (!availableStaticRevisions.contains(settings.staticRevision)) {
      map['staticHeadJs'] = settings.staticHeadJs;
      map['staticTailJs'] = settings.staticTailJs;
      emittedStaticRevisions.add(settings.staticRevision);
      availableStaticRevisions.add(settings.staticRevision);
    }
    popups.add(map);
  }
  final Map<String, Object?> payloadObj = <String, Object?>{
    'popups': popups,
  };
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
  return (
    script: 'window.__globalLookupHost && '
        'window.__globalLookupHost.renderStack($payloadJson);',
    pendingRevisions: emittedStaticRevisions,
  );
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
  Offset selectionScreenOffset = Offset.zero,
  ({double left, double top}) rootShellOffset = (left: 0.0, top: 0.0),
  bool fitNestedHeightToAnchorSide = false,
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
    // BUG-859 — isVertical is ALWAYS false: the anchor is a word inside a popup
    // card (horizontal text), so the child cascades above/below it, mirroring
    // the in-app nested gate (base_source_page._layerVerticalWriting). The
    // former TODO-938/BUG-453 writingMode wiring put vertical-book users' child
    // cards left/right of the word at a fixed maxHeight (wrong position).
    final GlobalLookupFrameRect r = computeFrameRect(
      selectionRect: shiftedAnchor,
      screenW: screenWidth,
      screenH: screenHeight,
      maxWidth: maxWidth,
      maxHeight: maxHeight,
      isVertical: false,
      // Desktop keeps the historical full-work-area nested height.  The
      // game-card route opts into the in-app contract: a horizontal nested card
      // lives wholly above or below the selected word and shrinks to that side.
      // The game work area is the FULL viewport, not the single-card cap, so the
      // child may legitimately extend outside the root card's current union.
      // A direct-active host expands/repositions its already-visible HWND around
      // the frozen root; only the bitmap fallback needs an off-screen resize +
      // captureReady handshake. This flag guarantees placement, not zero resize.
      fitHeightToAnchorSide: depth <= 0 || fitNestedHeightToAnchorSide,
    );
    return <String, Object?>{
      'left': r.left - selectionScreenOffset.dx,
      'top': r.top - selectionScreenOffset.dy,
      'width': r.width,
      'height': r.height,
    };
  }
  // TODO-1189 / BUG-859 — anchorless fallback steps every layer DOWN only
  // (never diagonally), mirroring computeFrameRect's real cascade axis. The
  // cascade is always horizontal (see the BUG-859 note on
  // [GlobalLookupFramePayload]), so the former vertical (rightward) fan-out
  // branch is gone. The root (depth 0) still lands at the window origin
  // (offset 0), so a single-frame lookup is unchanged. This branch is only
  // reached when a frame has no real anchorRect (host failed to re-anchor);
  // with an anchor the geometry comes from computeFrameRect above.
  // TODO-1231（BUG-583/670 续）——anchorless 卡（根卡 depth 0 + 防御性 fan-out）以
  // rootShellOffset 为基底：根卡从「恒钉 window-local (0,0) = 光标+8」改为「光标+8
  // 经工作区钳位」（见 computeRootShellOffset），光标四周空间充足时偏移 (0,0) 逐字节
  // 等于旧几何；防御性 fan-out（host 未能 re-anchor 的子卡）跟随根卡基底以保持贴近。
  final double offset = kGlobalLookupCascadeStep * depth;
  return <String, Object?>{
    'left': rootShellOffset.left,
    'top': rootShellOffset.top + offset,
    'width': maxWidth,
    'height': maxHeight,
  };
}
