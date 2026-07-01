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
  bool hasChildPopup = false,
}) {
  final String settingsJs = buildPopupSettingsJs(
    appModel: appModel,
    theme: Theme.of(context),
    result: result,
    options: const PopupSettingsOptions(globalLookup: true),
  );
  // TODO-1067 (子4) — wire the SAME __hasChildPopup guard the in-app popup uses
  // (BUG-434): when this frame has a child card stacked on top, popup.js's
  // document click handler must post `tapOutside` (close the child) instead of
  // selecting/return when the user taps the parent card body / glossary text.
  // The app-external overlay never set this flag, so tapping the parent card did
  // nothing and the child popup could not be closed. A leaf frame (no child)
  // leaves it false, so TODO-859 (tap card whitespace keeps the layer) still
  // holds. This runs inside the frame's own iframe realm (contentWindow.eval).
  //
  // TODO-1067 (子2) — inject the shared top-pull swipe-close JS
  // (kPopupTopPullReleaseJs) into the overlay iframe too. It was only injected on
  // the in-app popup path; the overlay iframe never received it, so the desktop
  // "swipe down to close" gesture was dead in the app-external window. The JS
  // self-guards against double-install (window.__hoshiTopPullInstalled) and
  // reports through flutter_inappwebview.callHandler('topPullReleased'), which
  // the controller already gates on the enableSwipeToClose preference.
  return '''
    $settingsJs
    window.__hasChildPopup = $hasChildPopup;
    $kPopupTopPullReleaseJs
    if (window.resetSentenceContextMirror) window.resetSentenceContextMirror();
    if (window.resetSelectedDictionaries) window.resetSelectedDictionaries();
    window.renderPopup && window.renderPopup();
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
  });

  final GlobalLookupFrame frame;
  final DictionarySearchResult result;

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
}) {
  // TODO-867 P3c F2 — the host shell (.global-lookup-frame-shell) is built in the
  // TOP-LEVEL host document, which carries no data-theme of its own (the theme
  // vars live INSIDE each iframe). So the shell's dark/light border variant can't
  // read a CSS var; stamp the resolved brightness onto each popup descriptor and
  // host.js sets data-theme on the shell.
  final String shellTheme =
      Theme.of(context).brightness == Brightness.dark ? 'dark' : 'light';
  final List<Map<String, Object?>> popups = <Map<String, Object?>>[];
  for (int i = 0; i < payloads.length; i++) {
    final GlobalLookupFramePayload p = payloads[i];
    final String settingsJs = buildFrameSettingsJs(
      context: context,
      appModel: appModel,
      result: p.result,
      // TODO-1067 (子4) — a frame has a child popup iff it is not the deepest
      // (last) frame in the stack, mirroring the in-app `index < entries.length
      // - 1` derivation (BUG-434). Drives popup.js's __hasChildPopup guard so
      // tapping a parent card closes the child.
      hasChildPopup: i < payloads.length - 1,
    );
    final Map<String, Object?> map = p.frame.toRenderMap();
    map['theme'] = shellTheme;
    map['frame'] = _frameRectMap(
      anchorRect: p.anchorRect,
      depth: i,
      screenWidth: screenWidth,
      screenHeight: screenHeight,
      maxWidth: maxWidth,
      maxHeight: maxHeight,
      isVertical: p.isVertical,
      selectionScreenOffset: selectionScreenOffset,
    );
    map['settingsJs'] = settingsJs;
    popups.add(map);
  }
  final String payloadJson = jsonEncode(<String, Object?>{'popups': popups});
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
  final double offset = kGlobalLookupCascadeStep * depth;
  return <String, Object?>{
    'left': offset,
    'top': offset,
    'width': maxWidth,
    'height': maxHeight,
  };
}
