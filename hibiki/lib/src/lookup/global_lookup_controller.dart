// TODO-617 global lookup overlay — orchestration (Windows).
//
// End-to-end trigger: select text in ANY app, press the global hotkey
// (Ctrl+Alt+D), and the real dictionary card pops up at the cursor without
// stealing focus. Selection is captured by injecting a clean Ctrl+C
// (SelectionCapture); re-pressing the hotkey looks up the new selection (close
// is Esc / click-outside, handled natively).
//
// The main Dart engine owns the dictionary, so this controller does the lookup
// (AppModel.searchDictionary -> popupJson), pushes it to the native overlay
// (GlobalLookupChannel), resolves gaiji bytes (image:// via HoshiDicts) and the
// deferred audio bridge calls (resolveWordAudio / playWordAudio).

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' hide ModifierKey;
import 'package:hibiki/src/lookup/global_lookup_channel.dart';
import 'package:hibiki/src/lookup/global_lookup_layout.dart';
import 'package:hibiki/src/lookup/global_lookup_log.dart';
import 'package:hibiki/src/lookup/global_lookup_render.dart';
import 'package:hibiki/src/lookup/global_lookup_stack.dart';
import 'package:hibiki/src/lookup/selection_capture_ffi.dart';
import 'package:hibiki/src/media/sources/reader_hibiki_source.dart';
import 'package:hibiki/src/models/app_model.dart';
import 'package:hibiki/src/pages/implementations/dictionary_webview_media.dart';
import 'package:hibiki/src/pages/implementations/stat_activity.dart';
import 'package:hibiki/src/utils/misc/error_log_service.dart';
import 'package:hibiki/src/shortcuts/input_binding.dart';
import 'package:hibiki/src/shortcuts/shortcut_action.dart';
import 'package:hibiki/src/shortcuts/shortcut_registry.dart';
import 'package:hibiki/src/utils/misc/lookup_audio_playback.dart';
import 'package:hibiki/src/utils/misc/lookup_auto_read_coordinator.dart';
import 'package:hibiki/src/utils/misc/tts_channel.dart';
import 'package:hibiki_anki/hibiki_anki.dart';
import 'package:hibiki_core/hibiki_core.dart';
import 'package:hibiki_dictionary/hibiki_dictionary.dart';
import 'package:hotkey_manager/hotkey_manager.dart';
import 'package:path/path.dart' as p;

/// Single global overlay per process.
class GlobalLookupController {
  GlobalLookupController._();
  static final GlobalLookupController instance = GlobalLookupController._();

  static bool get isSupported => Platform.isWindows;

  AppModel? _appModel;
  HotKey? _hotKey;
  // TODO-1066 — the live shortcut registry we read the global-lookup hotkey
  // from (was a hard-coded Ctrl+Alt+D). Listened to so a user remapping the
  // key in settings (or a profile switch that reloads bindings) re-registers
  // the OS hotkey immediately, instead of the key being a compile-time const.
  HibikiShortcutRegistry? _registry;
  bool _started = false;
  // TODO-1233 -- optional consumer notified when the overlay is GENUINELY
  // dismissed (foreground hook / click-outside / JS dismiss), so a caller can
  // hang a resume-on-dismiss. The video subtitle lookup (path A) would use this
  // for BUG-072 pause/resume IF it routed through the overlay; today it stays
  // in-app to keep the rich screenshot + sentence-audio mining context the
  // app-agnostic overlay cannot provide (see the TODO-1233 decision). Wired now
  // (the 872 prerequisite) so a future mining-preserving switch can hook it. Not
  // fired for the between-lookups reset (that hide passes notify=false).
  void Function()? onHidden;
  // Last physical size pushed to the overlay; used to converge the page's
  // resize -> re-measure loop (see _onJsMessage 'overlaySize'). Reset per
  // lookup so a new card re-sizes from scratch.
  int _lastSentWidth = -1;
  int _lastSentHeight = -1;
  // TODO-1231 P2 — the last window offset (physical px) pushed via revealStack.
  // The bbox ORIGIN (dx/dy) can change while the SIZE (w/h) stays equal (a
  // left/up cascade that shifts the window without growing it), so the resize
  // de-dup must also fire on a dx/dy change — otherwise the window would not move
  // and the host's commitLayerShift (which pins the root) would never run.
  int _lastSentDx = 0;
  int _lastSentDy = 0;
  // TODO-1231 (BUG-583) — the overlay window's min-corner (bbox origin, CSS px)
  // only ever moves OUTWARD (up/left) within one lookup session, never back
  // inward. Moving it inward on a nested CLOSE slides the window top-left back
  // toward the cursor while the host's compensating commitLayerShift lands ~1
  // frame later (cross DWM/WebView2 boundary), so the pinned root card visibly
  // lurches then snaps back ("消失第二个弹窗时闪"). Holding the origin at its
  // outermost keeps the window top-left + layer shift fixed on close; only the
  // far (bottom/right) edges shrink, which never moves the root card. Reset to
  // "no constraint" (infinity) per fresh hotkey lookup and on dismiss. A
  // down-right cascade keeps the origin at (0,0), so the ratchet is a no-op
  // there (identical to the pre-fix geometry).
  double _ratchetLeft = double.infinity;
  double _ratchetTop = double.infinity;
  // TODO-1345 (BUG-583 深层根因续) — the reserved cascade origin FLOOR for THIS
  // lookup (window-local CSS px, <= 0), computed once from the real screen edges
  // right after showAt and pushed to the host on every renderStack payload. It
  // reserves headroom toward the screen interior so a subsequent up/left child
  // lands inside the window origin committed at the first reveal — the origin then
  // never moves when the child appears, so the pinned parent card has ZERO
  // displacement (the true root fix for the residual BUG-583 parent lurch, which
  // rounds 1-4 could only mask). 0 = no reservation (down-right / cursor at an edge
  // / no work area) -> pre-fix origin. Reset to 0 on a genuine dismiss.
  double _originFloorLeft = 0;
  double _originFloorTop = 0;
  // The overlay renders off-screen until the first self-measurement, then is
  // revealed once at its final size (no on-screen jitter). False = still
  // off-screen / awaiting reveal. Reset per lookup.
  bool _revealed = false;
  Timer? _revealSafety;
  // TODO-1079 (B) — ready-driven reveal safety cadence. Each tick re-checks
  // isWebViewReady before revealing; a not-yet-ready surface reschedules up to
  // _kReadySafetyMaxAttempts times (~450ms each) then reveals as a last resort.
  static const Duration _kReadySafetyStep = Duration(milliseconds: 450);
  static const int _kReadySafetyMaxAttempts = 6;

  // TODO-867 P3b nested stack. The ordered lookup-popup stack (index 0 root
  // ... last = deepest child) drives the host renderStack payload. Each
  // frame's own DictionarySearchResult is held alongside (the pure stack
  // model only carries identity/linkage). _frameSeq mints stable per-frame
  // ids (the stack model never generates random/clock ids, see its docs).
  // TODO-1030 M0 — the current sentence for THIS lookup (UIA context capture),
  // shown as a context banner in the root popup card. Empty when context
  // capture is off / unavailable (clipboard fallback), in which case the banner
  // is not rendered. Reset per lookup in _lookupExternal.
  String _currentSentence = '';

  GlobalLookupStack _stack = GlobalLookupStack.empty;
  final Map<String, DictionarySearchResult> _frameResults =
      <String, DictionarySearchResult>{};
  int _frameSeq = 0;

  // TODO-867 P3c C2 — per-frame anchor rect (window-local CSS px). The root
  // anchor is null (placeholder cascade at window-local origin, the window is
  // already positioned at the cursor); a child's anchor is the clicked word's
  // rect, re-anchored to window-local CSS px by the host shim (global_lookup_
  // host.js anchorRectToScreen) and delivered via onLinkClick args[1]. Fed to
  // computeFrameRect so each child card cascades off its word.
  final Map<String, Rect?> _frameAnchors = <String, Rect?>{};
  // TODO-867 P3c E1/D2 — the cascade layout bounds (window-local CSS px) the
  // off-screen measurement window is sized to. Children cascade WITHIN these
  // bounds; D2's union bbox then reveals/resizes the window to the real extent.
  double _layoutBoundsW = 0;
  double _layoutBoundsH = 0;
  // TODO-893 — the cursor MONITOR work area (CSS px) reported by the native
  // showAt. computeFrameRect's showBelow / clamp must reason about the REAL
  // display, not the off-screen measurement canvas (boundsW/boundsH). Feeding
  // the 2x card canvas made every child cascade up and shoved the parent off
  // the top. 0 = native did not report a work area (fall back to the canvas).
  double _screenWorkW = 0;
  double _screenWorkH = 0;
  // TODO-893 v2 (symptom 3) — the overlay window-local origin's offset from the
  // cursor monitor work-area origin (CSS px). Child anchor rects from the host
  // are window-local; computeFrameRect's screenW/H are work-area dimensions.
  // Adding this offset lifts the anchor into the SAME work-area-absolute domain
  // (same zero point as screenW/H) so showBelow / clamp decide correctly near
  // the screen bottom edge; the render builder shifts the result back to
  // window-local for the host shell. 0 = native did not report a work area.
  double _cursorWorkX = 0;
  double _cursorWorkY = 0;

  /// Wires the overlay assets + reverse handlers + the global trigger hotkey.
  /// Safe to call once after AppModel.initialise() on desktop.
  Future<void> start({required AppModel appModel}) async {
    glog('start: called (supported=$isSupported started=$_started)');
    if (!isSupported || _started) {
      return;
    }
    _started = true;
    _appModel = appModel;

    final String assetsDir = _popupAssetsDir();
    glog('start: assetsDir=$assetsDir');
    await GlobalLookupChannel.prepare(assetsDir);
    GlobalLookupChannel.setHandlers(
      onGetMedia: _resolveMedia,
      onJsMessage: _onJsMessage,
      onOverlayHidden: _onOverlayHidden,
    );

    // TODO-1066 — read the trigger hotkey from the shortcut registry (was a
    // hard-coded Ctrl+Alt+D that bypassed the whole registry, so it never showed
    // up in the settings page and could not be remapped). Register it now and
    // re-register whenever the registry changes (user remap / profile switch).
    _registry = appModel.shortcutRegistry;
    _registry!.addListener(_onRegistryChanged);
    await _registerHotKeyFromRegistry();

    // TODO-1079 — root-cause fix: PREWARM the overlay WebView2 off-screen now,
    // so the first hotkey lookup hits a WARM surface instead of racing a cold
    // create chain (>450ms) against the reveal. Sized to the current card size ×
    // dpr so its off-screen self-measure is at a sane size; the real geometry is
    // applied on the first showAt/reveal. Non-fatal on failure (the lazy create
    // path in showAt still works, just cold). Semantics mirror the in-app
    // keepWebViewWarm hot slot, but for THIS bare overlay window (which
    // webview_prewarm.dart never warmed — that gap was the root cause).
    unawaited(_prewarmOverlay(appModel));
  }

  /// TODO-1079 — off-screen prewarm of the overlay WebView2 (see [start]).
  Future<void> _prewarmOverlay(AppModel model) async {
    try {
      final double dpr = _devicePixelRatio();
      final int w = (model.popupMaxWidth * model.appUiScale * dpr).round();
      final int h = (model.popupMaxHeight * model.appUiScale * dpr).round();
      await GlobalLookupChannel.prewarmWebView(width: w, height: h);
      glog('start: overlay prewarm requested w=$w h=$h');
    } catch (e) {
      glog('start: overlay prewarm FAILED (non-fatal): $e');
    }
  }

  /// TODO-1066 — (un)registers the OS-level trigger hotkey from the current
  /// [ShortcutAction.globalExternalLookup] binding in the registry. Unregisters
  /// any previously-registered hotkey first so a remap does not leak the old
  /// combo. The first keyboard binding (there is at most one meaningful global
  /// hotkey) is used; when the action has no keyboard binding (e.g. the user
  /// cleared it, or on a platform with no default) no hotkey is registered and
  /// the feature is simply off until a key is assigned. Non-fatal on failure.
  Future<void> _registerHotKeyFromRegistry() async {
    // Drop the previously-registered hotkey (idempotent: safe when none).
    final HotKey? previous = _hotKey;
    _hotKey = null;
    if (previous != null) {
      try {
        await hotKeyManager.unregister(previous);
      } catch (e) {
        glog('hotkey: unregister previous FAILED (non-fatal): $e');
      }
    }
    final HibikiShortcutRegistry? registry = _registry;
    if (registry == null) {
      return;
    }
    final ShortcutBindingSet set =
        registry.bindingsFor(ShortcutAction.globalExternalLookup);
    if (set.keyboardBindings.isEmpty) {
      glog('hotkey: no keyboard binding for globalExternalLookup — not '
          'registered (feature off until a key is assigned)');
      return;
    }
    final HotKey? hotKey = _hotKeyFromBinding(set.keyboardBindings.first);
    if (hotKey == null) {
      glog('hotkey: binding has no mappable physical key — not registered');
      return;
    }
    _hotKey = hotKey;
    try {
      await hotKeyManager.register(hotKey, keyDownHandler: (_) => _onHotKey());
      glog('hotkey: registered ${set.keyboardBindings.first.displayLabel} '
          'from registry OK');
    } catch (e, st) {
      glog('hotkey: register FAILED: $e');
      // TODO-1086 可见化：全局查词热键注册失败过去只写进 glog 临时诊断文件，用户/开发者
      // 都看不到「应用外查词唤不出来」的真正原因（热键没注册上）。这里额外把失败记进
      // ErrorLogService（用户可见的错误日志页 + 随复制/上传链路带走），让此失败成为可诊断
      // 项而不是静默吞掉。别的注册/系统热键冲突（另一个 app 已占用同一组合键）也会经此暴露。
      ErrorLogService.instance.log(
        'GlobalLookupController.registerHotKey',
        'Failed to register global lookup hotkey '
            '${set.keyboardBindings.first.displayLabel}: $e',
        st,
      );
    }
  }

  /// TODO-1066 — re-registers the OS hotkey when the registry changes (user
  /// remaps the key in settings, or a profile switch reloads bindings). Fire and
  /// forget; failures are logged inside [_registerHotKeyFromRegistry].
  void _onRegistryChanged() {
    unawaited(_registerHotKeyFromRegistry());
  }

  /// TODO-1066 — maps a registry keyboard [binding] to a hotkey_manager [HotKey].
  /// hotkey_manager keys off the USB-HID [PhysicalKeyboardKey]; the registry
  /// stores a logical key + [ModifierKey] set. [InputBinding.physicalKey] reuses
  /// the same logical→physical table the IME fallback uses (US-QWERTY). Returns
  /// null when the logical key has no physical mapping (e.g. game* / numpad keys
  /// that are not valid global hotkeys anyway).
  HotKey? _hotKeyFromBinding(InputBinding binding) {
    final PhysicalKeyboardKey? physical = binding.physicalKey;
    if (physical == null) {
      return null;
    }
    final List<HotKeyModifier> modifiers = <HotKeyModifier>[];
    for (final ModifierKey mod in binding.modifiers) {
      switch (mod) {
        case ModifierKey.ctrl:
          modifiers.add(HotKeyModifier.control);
          break;
        case ModifierKey.shift:
          modifiers.add(HotKeyModifier.shift);
          break;
        case ModifierKey.alt:
          modifiers.add(HotKeyModifier.alt);
          break;
        case ModifierKey.meta:
          modifiers.add(HotKeyModifier.meta);
          break;
      }
    }
    return HotKey(
      key: physical,
      modifiers: modifiers,
      scope: HotKeyScope.system,
    );
  }

  /// Absolute folder that holds popup.html on Windows:
  /// <exeDir>/data/flutter_assets/assets/popup.
  String _popupAssetsDir() => p.join(
        p.dirname(Platform.resolvedExecutable),
        'data',
        'flutter_assets',
        'assets',
        'popup',
      );

  Future<void> _onHotKey() async {
    glog('hotkey: FIRED');
    try {
      // Re-press ALWAYS does a fresh lookup of the current selection (no
      // toggle): the user selects a new word and presses the hotkey expecting
      // the new word, not for the card to vanish. Closing is Esc / click
      // outside (handled natively by the foreground + mouse hooks).
      final AppModel? model = _appModel;
      if (model == null) {
        glog('hotkey: appModel null — abort');
        return;
      }
      // TODO-1079 (D) — collapse native + Dart reveal state to known-hidden
      // BEFORE the (possibly slow) selection capture, so a re-press makes the
      // previous card vanish immediately. _lookupExternal hides again right
      // before showAt (idempotent + cheap: SW_HIDE + unhook), which is what
      // keeps the programmatic lookupText path equally clean.
      // TODO-1233 — notify:false: this is the between-lookups reset, NOT a user
      // dismissal, so it must not fire overlayHidden (which would resume a paused
      // video mid re-lookup).
      GlobalLookupChannel.hide(notify: false);
      // TODO-1030 M0 — when the user opted into context capture, try UI
      // Automation first: it yields the selected term PLUS the sentence it sits
      // in (shown in the popup). On any miss (no UIA text element, non-Windows,
      // channel unavailable) fall back to the clipboard capture (inject Ctrl+C),
      // which yields only the bare selection — never break the existing path.
      String text = '';
      String sentence = '';
      if (model.globalContextCaptureEnabled) {
        final ForegroundSelectionContext? ctx =
            await SelectionCapture.captureForegroundContext();
        if (ctx != null) {
          text = ctx.selectedText.trim();
          sentence = ctx.sentence;
        }
      }
      if (text.isEmpty) {
        // No context (or feature off): fall back to the clipboard selection.
        text =
            (await SelectionCapture.captureForegroundSelection() ?? '').trim();
        sentence = '';
      }
      if (text.isEmpty) {
        glog('hotkey: empty selection — abort');
        return;
      }
      await _lookupExternal(text, sentence: sentence);
    } catch (e, st) {
      glog('hotkey: EXCEPTION $e\n$st');
    }
  }

  /// TODO-872 — programmatic app-external lookup (desktop floating-lyric word
  /// tap etc.). [text] is the already-segmented term; [sentence] is the line it
  /// came from, shown as the root card's context banner and fed to mining's
  /// sentence field ('' = no banner). Opens the SAME overlay card as the global
  /// hotkey, at the OS cursor (the click that triggered this just happened
  /// there — the native floating-lyric strip reports text+index only, no
  /// coordinates). Returns false when the overlay cannot take the lookup
  /// (unsupported platform / [start] never ran / blank term) so the caller
  /// falls back to its existing in-app route — a tap is never silently lost.
  Future<bool> lookupText(String text, {String sentence = ''}) async {
    final String term = text.trim();
    if (!isSupported || !_started || _appModel == null || term.isEmpty) {
      return false;
    }
    glog('lookupText: "$term"');
    // TODO-1268 / BUG — mirror _onHotKey's TODO-1079(D) preamble on the
    // programmatic (desktop floating-lyric tap) path: AWAIT a leading
    // hide(notify:false) so the overlay collapses to a confirmed-hidden state
    // (SW_HIDE + unhook done on the platform thread) BEFORE _lookupExternal
    // re-shows + re-renders. The hotkey path got this reset — plus a real
    // event-loop settle — for free from its async selection-capture round-trip;
    // lookupText fired _lookupExternal with zero latency, so a floating-lyric
    // re-tap (or a tap while a previous card was still revealing) raced the
    // shared reveal state / host content-ready gate and the overlay never
    // emitted overlaySize — the card revealed blank via the READY-SAFETY
    // fallback ("点击悬浮字幕文字没有出现查词窗口"). notify:false so this
    // between-lookups reset is not seen as a user dismissal (TODO-1233).
    await GlobalLookupChannel.hide(notify: false);
    await _lookupExternal(term, sentence: sentence);
    return true;
  }

  /// TODO-872 — the shared app-external lookup chain for BOTH triggers (the
  /// global hotkey and the programmatic [lookupText] entry): unconditional
  /// hide → searchDictionary → reset reveal state → seed the stack root →
  /// showAt(atCursor) → renderStack → auto-read → ready-driven reveal safety.
  /// Never throws (logs and swallows, matching the old _onHotKey contract).
  Future<void> _lookupExternal(String text, {required String sentence}) async {
    final AppModel? model = _appModel;
    if (model == null) {
      glog('lookup: appModel null — abort');
      return;
    }
    try {
      // TODO-1079 (D) — reset native + Dart reveal state from zero every
      // lookup. The native visible_/revealed_ and this controller's
      // _revealed used to drift out of sync across lookups (an in-flight
      // Hide() could swallow the next window; a stale revealed_ let the
      // foreground hook self-close the fresh card). An unconditional hide()
      // up front collapses both sides to a known-hidden state before showAt
      // re-arms them, so every lookup starts clean. Cheap (SW_HIDE + unhook)
      // and the prewarmed WebView2 survives it.
      // TODO-1233 — notify:false: same between-lookups reset as _onHotKey; must
      // not look like a user dismissal.
      GlobalLookupChannel.hide(notify: false);
      _currentSentence = sentence;

      final DictionarySearchResult result = await model.searchDictionary(
        searchTerm: text,
        searchWithWildcards: false,
      );
      glog('lookup: searched "$text" -> entries=${result.entries.length}');
      // New card: forget the previous size + reveal state so the overlay
      // re-measures and reveals from scratch.
      _lastSentWidth = -1;
      _lastSentHeight = -1;
      _revealed = false;
      _revealSafety?.cancel();
      // TODO-1231 (BUG-583) — a fresh hotkey lookup starts a new session: drop
      // the origin ratchet so the single root card re-anchors at the cursor
      // (origin 0,0) instead of inheriting a previous cascade's outward min-corner.
      _ratchetLeft = double.infinity;
      _ratchetTop = double.infinity;

      // TODO-867 P3c: a new hotkey lookup RESETS the whole stack to a single
      // root frame. The single-frame card is now stack depth 1 rendered through
      // the host iframe (window.__globalLookupHost.renderStack) — the top-level
      // document is global_lookup_host.html (zero popup.js instance), so there
      // is NO top-level direct render anymore (the old buildOverlayRenderScript
      // path is retired). A no-result lookup still seeds a root frame so
      // its iframe shows popup.js's own no-results card (see _resetStackRoot).
      _resetStackRoot(text, result);
      _recordLookupCount();

      // TODO-1095 — announce a NEW lookup to the host BEFORE the stack render:
      // clear the union-bbox de-dup key (so the fresh card's reveal-driving
      // overlaySize is never suppressed by a stale identical bbox) and re-gate
      // the REUSED root shell's content-ready flag (so the reveal waits for THIS
      // lookup's popupRendered, not the previous card's already-satisfied gate).
      // Sent through the existing render channel (ExecuteScript) so no new native
      // method is needed; the host guard makes it inert until host.js installs.
      await GlobalLookupChannel.render(
          buildBeginLookupScript(kGlobalLookupRootFrameId));

      // Render OFF-SCREEN at the reader-faithful size (popupMax* × appUiScale ×
      // dpr) so the page measures at the correct width straight away; the card
      // is revealed once via overlaySize. dpr is the main window's — the same
      // monitor in the common case; the page reports the authoritative dpr in
      // overlaySize and Reveal uses that. Position natively (GetCursorPos =
      // physical px) to avoid the logical/physical DPI mismatch.
      final double dpr = _devicePixelRatio();
      // TODO-867 P3c E1 — the off-screen measurement window is sized to the
      // cascade LAYOUT BOUNDS (window-local CSS px) so a nested child card has
      // room to cascade beside the root during measurement; D2's union bbox
      // (overlaySize) then reveals/resizes the window down to the real extent.
      // The root card itself stays anchored at the window-local origin (its
      // anchor is null), so a single-frame lookup still reveals exactly at the
      // card size after the bbox trims the bounds — no regression.
      final double cardW = model.popupMaxWidth * model.appUiScale;
      final double cardH = model.popupMaxHeight * model.appUiScale;
      _layoutBoundsW = cardW * kGlobalLookupLayoutBoundsWidthFactor;
      _layoutBoundsH = cardH * kGlobalLookupLayoutBoundsHeightFactor;
      final int w0 = (_layoutBoundsW * dpr).round();
      final int h0 = (_layoutBoundsH * dpr).round();
      final GlobalLookupShowResult shown = await GlobalLookupChannel.showAt(
          x: 0, y: 0, width: w0, height: h0, atCursor: true);
      // TODO-893 — convert the native physical-px work area to CSS px (the
      // cascade layout domain) with the same dpr used for window geometry, so
      // _renderStack's computeFrameRect reasons about the real monitor.
      _screenWorkW = shown.workWidth > 0 ? shown.workWidth / dpr : 0;
      _screenWorkH = shown.workHeight > 0 ? shown.workHeight / dpr : 0;
      // TODO-893 v2 (symptom 3) — same dpr boundary: the native cursor/work
      // offset is physical px; convert to CSS px for the cascade layout domain.
      _cursorWorkX = dpr > 0 ? shown.cursorWorkX / dpr : 0;
      _cursorWorkY = dpr > 0 ? shown.cursorWorkY / dpr : 0;
      // TODO-1345 (BUG-583 深层根因续) — reserve cascade headroom toward the screen
      // interior so a subsequent up/left child lands INSIDE the window origin
      // committed at THIS first reveal; the host then never moves the origin when
      // the child appears -> the pinned parent card has ZERO displacement (the
      // residual BUG-583 lurch rounds 1-4 could only mask). Bounded on-screen (see
      // computeCascadeHeadroomSeed) so it never triggers the C++ RevealStack work-
      // area clamp that would itself move the origin. 0 near an edge / no work area
      // -> pre-fix geometry.
      final ({double left, double top}) floor = computeCascadeHeadroomSeed(
        cursorWorkX: _cursorWorkX,
        cursorWorkY: _cursorWorkY,
        screenWorkW: _screenWorkW,
        screenWorkH: _screenWorkH,
        cardW: cardW,
        cardH: cardH,
      );
      _originFloorLeft = floor.left;
      _originFloorTop = floor.top;
      await _renderStack();
      glog('lookup: showAt(atCursor)=${shown.ok} off-screen w0=$w0 h0=$h0 '
          'workCss=${_screenWorkW}x$_screenWorkH rendered');
      _autoReadFirstEntry(model, result);
      // TODO-1079 (B) — READY-DRIVEN reveal fallback (was a blind 450ms timeout).
      // The real reveal is host-driven (overlaySize -> _applyOverlayBox). This
      // safety only fires when that never arrives (true render failure), and it
      // MUST NOT reveal a WebView2 that has not finished loading — that produced
      // the 'window present but blank' flake when a cold create chain outran the
      // 450ms budget. So the tick reveals only after confirming the surface is
      // ready (webview_ready_ via isWebViewReady); if still loading it reschedules
      // a bounded number of times, then reveals as a last resort so the card is
      // never stuck invisible. Prewarm (A) makes the ready path the common case;
      // this gate is the belt-and-braces for a cold/slow surface.
      final int safeW = (cardW * dpr).round();
      final int safeH = (cardH * dpr).round();
      _scheduleReadyDrivenSafety(safeW, safeH, attempt: 0);
    } catch (e, st) {
      glog('lookup: EXCEPTION $e\n$st');
    }
  }

  /// TODO-1079 (B) — schedules the ready-driven reveal safety. On each 450ms
  /// tick: if the host already revealed (overlaySize path), stop. Else confirm
  /// the overlay WebView2 finished loading (isWebViewReady) before revealing at
  /// the single-card size — a not-yet-ready surface would flash blank. While the
  /// surface is still loading, reschedule up to [_kReadySafetyMaxAttempts] times
  /// (~kReadySafetyStep each), then reveal as an absolute last resort so the card
  /// is never stuck invisible. [attempt] is the current retry index.
  void _scheduleReadyDrivenSafety(int width, int height,
      {required int attempt}) {
    _revealSafety?.cancel();
    _revealSafety = Timer(_kReadySafetyStep, () async {
      if (_revealed) {
        return;
      }
      bool ready;
      try {
        ready = await GlobalLookupChannel.isWebViewReady();
      } catch (_) {
        ready = false;
      }
      if (_revealed) {
        return; // Host revealed while we awaited the readiness check.
      }
      if (ready || attempt >= _kReadySafetyMaxAttempts) {
        _revealed = true;
        glog('reveal: READY-SAFETY (ready=$ready attempt=$attempt) '
            'w=$width h=$height');
        unawaited(GlobalLookupChannel.reveal(width: width, height: height));
        return;
      }
      // Surface still loading — defer instead of revealing blank.
      glog('reveal: READY-SAFETY defer (not ready, attempt=$attempt)');
      _scheduleReadyDrivenSafety(width, height, attempt: attempt + 1);
    });
  }

  /// The main window's device-pixel ratio (monitor scale). Used as the initial
  /// off-screen render width; the page later reports the authoritative dpr.
  double _devicePixelRatio() {
    final BuildContext? ctx = _appModel?.navigatorKey.currentContext;
    if (ctx != null) {
      final double dpr = MediaQuery.maybeOf(ctx)?.devicePixelRatio ?? 0;
      if (dpr > 0) return dpr;
    }
    return WidgetsBinding.instance.platformDispatcher.views.isNotEmpty
        ? WidgetsBinding
            .instance.platformDispatcher.views.first.devicePixelRatio
        : 1.0;
  }

  /// Resolves the bytes for a dictionary media request from the overlay
  /// WebView2. Both custom schemes are routed here (matching the in-app
  /// InAppWebView): `image://?dictionary=..&path=..` (gaiji / <img>) and
  /// `dictmedia://<encoded-path>?dictionary=..` (dictionary <link> stylesheets
  /// and their relative font/bg resources). The two schemes carry the media
  /// path in different positions, so parsing is scheme-aware (see
  /// [resolveGlobalLookupMedia]). The Content-Type is derived natively from the
  /// URL (see global_lookup_window.cpp MediaContentTypeHeader); this side only
  /// supplies the bytes.
  Future<Uint8List> _resolveMedia(String url) async {
    try {
      final GlobalLookupMediaRequest? request = resolveGlobalLookupMedia(url);
      if (request == null) {
        return Uint8List(0);
      }
      final Uint8List? bytes =
          HoshiDicts.instance.getMediaFile(request.dictionary, request.path);
      return bytes ?? Uint8List(0);
    } catch (_) {
      return Uint8List(0);
    }
  }

  /// TODO-1233 — the native overlay was GENUINELY dismissed (foreground hook /
  /// click-outside / JS 'dismiss'/'tapOutside'). Resets this controller's
  /// reveal/measurement state so the next lookup starts clean (the reveal-safety
  /// timer is cancelled; a stale _revealed would otherwise let the ready-driven
  /// fallback or the box de-dup misbehave on the next card), then notifies the
  /// optional [onHidden] consumer (resume-on-dismiss). NOT called for the
  /// between-lookups reset (that hide passes notify:false, so native suppresses
  /// the callback) — only for a real user dismissal.
  void _onOverlayHidden() {
    _revealSafety?.cancel();
    _revealed = false;
    _lastSentWidth = -1;
    _lastSentHeight = -1;
    _lastSentDx = 0;
    _lastSentDy = 0;
    // TODO-1231 (BUG-583) — clear the origin ratchet on a genuine dismissal so
    // the next session starts unconstrained.
    _ratchetLeft = double.infinity;
    _ratchetTop = double.infinity;
    // TODO-1345 (BUG-583 深层根因续) — clear the reserved cascade floor too so the
    // next lookup re-computes its own from the fresh cursor position.
    _originFloorLeft = 0;
    _originFloorTop = 0;
    glog('overlayHidden: dismissed — reveal state reset');
    onHidden?.call();
  }

  void _onJsMessage(Map<String, Object?> message) {
    final Object? handler = message['handler'];
    glog('js: handler=$handler args=${message['args']}');
    if (handler == 'tapOutside' || handler == 'dismiss') {
      // TODO-867 P3c C3 — a tapOutside stamped with the source layer's frame id
      // (by the host shim) means "tap inside layer L outside its glossary" ->
      // close L's children (point a layer -> close the cards above it). Without
      // a frame id (or when L is the root) fall back to hiding the whole overlay.
      final String? frameId = message['__frameId'] as String?;
      if (handler == 'tapOutside' && frameId != null) {
        final int layerIndex = _layerIndexForFrameId(frameId);
        if (layerIndex >= 0) {
          _stack = closeChildPopupsAndClearSelection(_stack, layerIndex);
          _pruneFrameResults();
          if (_stack.isEmpty) {
            GlobalLookupChannel.hide();
          } else {
            unawaited(_renderStack());
          }
          return;
        }
      }
      GlobalLookupChannel.hide();
      return;
    }
    // TODO-867 P3b nested stack: the host can request closing a specific
    // layer. dismissPopupAt([index]) closes that popup + its children
    // (root index 0 -> whole stack empty -> hide); closeChildPopups([parent])
    // truncates children of a parent (+ clears that parent's selection). Both
    // rebuild the stack via the pure model and re-render. (These are P3c-era
    // host messages; wired now so the stack path is exercised end-to-end.)
    if (handler == 'dismissPopupAt') {
      final int? index = _firstIntArg(message);
      if (index != null) {
        _stack = dismissPopupAt(_stack, index);
        _pruneFrameResults();
        if (_stack.isEmpty) {
          GlobalLookupChannel.hide();
        } else {
          unawaited(_renderStack());
        }
      }
      return;
    }
    if (handler == 'closeChildPopups') {
      final int? parentIndex = _firstIntArg(message);
      if (parentIndex != null) {
        _stack = closeChildPopupsAndClearSelection(_stack, parentIndex);
        _pruneFrameResults();
        unawaited(_renderStack());
      }
      return;
    }
    // TODO-854 M1a-2：顶部下滑关闭。覆盖窗的 kPopupTopPullReleaseJs 识别到顶部
    // 下滑（桌面 pointer/mouse）后 callHandler('topPullReleased')；是否真正关闭
    // 尊重用户「滑动关闭弹窗」(enableSwipeToClose) 偏好——关时忽略，与 in-app
    // 弹窗一致（Windows 默认 false，鼠标框选与下滑同形）。
    if (handler == 'topPullReleased') {
      if (ReaderHibikiSource.instance.enableSwipeToClose) {
        GlobalLookupChannel.hide();
      }
      return;
    }
    // Audio handlers are DEFERRED natively (see global_lookup_window.cpp): the
    // main engine must supply the real reply and resolve the JS promise via
    // resolveBridge(id, value), else the ♪ button hangs. popup.js calls
    // resolveWordAudio({expression,reading}) then playWordAudio({url}).
    if (handler == 'resolveWordAudio' ||
        handler == 'queryLocalAudio' ||
        handler == 'playWordAudio') {
      unawaited(_handleAudioBridge(handler! as String, message));
      return;
    }
    // TODO-1188 — 收藏（☆/★）也是 DEFERRED 桥：popup.js 的 createFavoriteButton
    // await callHandler('favoriteEntry'/'favoriteCheck', {expression, reading})，
    // 需 Dart 落库（FavoriteWords 表）后经 resolveBridge 回传新收藏态，iframe 里的
    // 星标才切换。app 外覆盖窗过去 Dart 侧没有这两个分支（按钮永挂），且 C++ 把它们
    // 当只读即时 null-resolve（回传恒 null）——本次一并接上（C++ 也纳入 deferred，
    // host 桥回程把回复路由回源 iframe）。始终 resolveBridge，即使无 model / 出错，
    // 收藏按钮也不会卡死。
    if (handler == 'favoriteEntry' || handler == 'favoriteCheck') {
      unawaited(_handleFavoriteBridge(handler! as String, message));
      return;
    }
    // TODO-1188 follow-up — 制卡（➕）也是 DEFERRED 桥：popup.js 的 mine 按钮
    // await callHandler('mineEntry', fields) 拿 {ankiConnect,noteId}，再
    // await callHandler('duplicateCheck', {expression,reading}) 拿 bool 把 ➕→✓。
    // app 外覆盖窗过去 Dart 侧没有这两个分支、C++ 又当只读即时 null-resolve（mineEntry
    // 拿 null=没制成、duplicateCheck 拿 null=永不显示已制卡）——本次一并接上，直接调
    // AnkiConnect/AnkiDroid repo（与 in-app DictionaryPageMixin.onMineEntry /
    // checkDuplicate 同一 repo.mineEntry / repo.isDuplicate 路径），resolveBridge 回传
    // 供 popup.js 翻 ✓。始终 resolveBridge，即使无 model / 出错也不卡死按钮。
    if (handler == 'mineEntry') {
      unawaited(_handleMineBridge(message));
      return;
    }
    if (handler == 'duplicateCheck') {
      unawaited(_handleDuplicateBridge(message));
      return;
    }
    // TODO-1225 — 覆写制卡（✓↩）也是 DEFERRED 桥，补上 1188 只做了新建/查重后缺的那半：
    //   - overwriteTargetNoteId：popup.js 查词时若 duplicateCheck 命中已存在卡（且非本
    //     会话最近），await callHandler('overwriteTargetNoteId', {expression,reading}) 拿
    //     一张可覆写的 note id（仅 AnkiSettings.overwriteScope=all 且 AnkiConnect 后端返回
    //     非空），据此把已存在卡提升到 ✓↩「最新可改」态，一点即覆写。
    //   - updateEntry：点 ✓↩ 时 await callHandler('updateEntry', {noteId,fields}) 按 id
    //     真实覆盖字段（不新增卡、不查重、不记账）——与 in-app DictionaryPageMixin
    //     .findOverwriteTargetNoteId / onUpdateEntry 同 repo.findOverwriteTargetNoteId /
    //     repo.updateMinedNote 路径，别发明新协议。
    // 两者过去在 C++ 都被当只读即时 null-resolve（overwriteTargetNoteId 拿 null=永不进
    // ✓↩、updateEntry 拿 null=覆写静默失败），本次一并纳入 deferred 由 Dart 权威回复。
    // minedCardAction（点普通 ✓ 弹「覆写哪张/新增重复/查看」操作面板）仍保持即时 null
    // 降级——它需在前台弹 Flutter 底栏，而 app 外主窗被外部应用挡在后台无法呈现（见
    // C++ 注释），故 app 外覆写只走 overwriteTargetNoteId + updateEntry 的 ✓↩ 就地覆写。
    if (handler == 'overwriteTargetNoteId') {
      unawaited(_handleOverwriteTargetBridge(message));
      return;
    }
    if (handler == 'updateEntry') {
      unawaited(_handleUpdateBridge(message));
      return;
    }
    // TODO-867 P3c D2 — size + place the overlay window from the host's stack
    // self-measurement. The host reports overlaySize = [dpr, box] where box is
    // the UNION bounding box of all card shells in window-local CSS px
    // ({left, top, width, height}); the legacy single-card form [dpr, physH]
    // (physH = physical scrollHeight) is still accepted as a fallback. The
    // window is REVEALED/RESIZED to the bbox: it moves to (cursor + box.left,
    // cursor + box.top) ×dpr and grows to box.width/height ×dpr, while the host
    // shifts its layer by (-box.left, -box.top) so the ROOT card stays pinned at
    // the cursor and the whole cascade fits inside the window (E1).
    if (handler == 'overlaySize') {
      final AppModel? model = _appModel;
      final Object? args = message['args'];
      if (model != null && args is List && args.length >= 2) {
        final double dpr = (args[0] is num) ? (args[0] as num).toDouble() : 1.0;
        if (dpr > 0) {
          final Object? second = args[1];
          if (second is Map) {
            // D2 union bounding box (window-local CSS px) -> place + size window.
            _applyOverlayBox(model, dpr, second.cast<Object?, Object?>());
          } else if (second is num && second > 0) {
            // Legacy single-card form: physical scrollHeight, fixed width.
            _applyOverlayScalar(model, dpr, second.toDouble());
          }
        }
      }
      return;
    }
    // popup.js still emits popupRendered/contentHeight; ignored — overlaySize
    // (which carries the DPR the bare window needs) is the sizing source.
    if (handler == 'popupRendered' || handler == 'contentHeight') {
      return;
    }
    // Nested lookup: two popup.js triggers, IDENTICAL arg shape (args[0] =
    // query, args[1] = clicked word's anchor rect in window-local CSS px, already
    // re-anchored by the host shim global_lookup_host.js so the child cascades
    // off the real word position):
    //   - onLinkClick: headword / kanji-tag / kanji-character / structured href.
    //   - textSelected: TAPPING PLAIN GLOSSARY TEXT — popup.js's
    //     hoshiSelection.selectText -> selection.js callHandler('textSelected',
    //     text, rect). The in-app popup (dictionary_popup_webview) registers
    //     BOTH; the app-external controller used to register only onLinkClick, so
    //     a body tap was silently dropped and "clicking plain text never opens a
    //     lookup" (TODO-893 v2 symptom 1). Both share one dispatch — no special
    //     case.
    if (handler == 'onLinkClick' || handler == 'textSelected') {
      _dispatchNestedLookup(message);
    }
  }

  /// TODO-893 v2 (symptom 1) — shared nested-lookup dispatch for the two popup.js
  /// triggers (`onLinkClick`, `textSelected`) that carry the SAME arg shape:
  /// args[0] = query, args[1] = the clicked word's window-local CSS px anchor
  /// rect (re-anchored by the host shim). Searches and pushes a child frame.
  void _dispatchNestedLookup(Map<String, Object?> message) {
    final Object? args = message['args'];
    if (args is! List || args.isEmpty) {
      return;
    }
    final String query = args.first?.toString() ?? '';
    if (query.isEmpty) {
      return;
    }
    final Rect? anchor =
        (args.length >= 2) ? _anchorRectFromArg(args[1]) : null;
    unawaited(_lookupNested(query, anchor));
  }

  /// Resolves a deferred audio bridge call and pushes the reply back to the
  /// overlay (resolveBridge). Always resolves — even on error / no model — so
  /// the awaiting ♪ button never freezes.
  Future<void> _handleAudioBridge(
      String handler, Map<String, Object?> message) async {
    final int? id = (message['__bridgeId'] is num)
        ? (message['__bridgeId'] as num).toInt()
        : null;
    Object? reply;
    try {
      final AppModel? model = _appModel;
      final Object? args = message['args'];
      final Map<Object?, Object?> data =
          (args is List && args.isNotEmpty && args.first is Map)
              ? (args.first as Map)
              : const <Object?, Object?>{};
      if (model == null) {
        reply = handler == 'playWordAudio' ? false : null;
      } else if (handler == 'playWordAudio') {
        final String url = data['url']?.toString() ?? '';
        final bool ok = url.isEmpty
            ? false
            : await TtsChannel.instance.playAudioRef(
                url,
                volume: ReaderHibikiSource.instance.lookupAudioVolumeGain,
              );
        reply = ok;
      } else {
        // resolveWordAudio / queryLocalAudio -> the configured-source URL.
        final String expression = data['expression']?.toString() ?? '';
        final String reading = data['reading']?.toString() ?? '';
        // Diagnostic: which audio sources are configured/enabled? A null reply
        // with 0 enabled sources = nothing to query (config), not a wiring bug.
        glog('audio: resolve "$expression"/"$reading" '
            'enabled=${model.enabledAudioSources} '
            'configs=${model.audioSourceConfigs.length}');
        reply = expression.isEmpty
            ? null
            : await resolveLookupAudioUrl(model, expression, reading);
      }
    } catch (e, st) {
      glog('audio: EXCEPTION $e\n$st');
      reply = handler == 'playWordAudio' ? false : null;
    }
    if (id != null) {
      glog('audio: $handler -> reply=$reply (id=$id)');
      unawaited(GlobalLookupChannel.resolveBridge(id, reply));
    }
  }

  /// TODO-1188 — resolves a DEFERRED favorite bridge call (favoriteEntry toggles
  /// the FavoriteWords row and returns the NEW state; favoriteCheck just reads the
  /// current state) and pushes the resulting bool back to the overlay iframe via
  /// [GlobalLookupChannel.resolveBridge] so popup.js flips the ☆/★ star. Always
  /// resolves — even on error / no model — so the ☆ button never freezes (mirrors
  /// [_handleAudioBridge]). The DB logic mirrors the in-app
  /// [DictionaryPageMixin.onFavoriteEntry]/[onFavoriteCheck].
  Future<void> _handleFavoriteBridge(
      String handler, Map<String, Object?> message) async {
    final int? id = (message['__bridgeId'] is num)
        ? (message['__bridgeId'] as num).toInt()
        : null;
    bool reply = false;
    try {
      final AppModel? model = _appModel;
      final Object? args = message['args'];
      final Map<Object?, Object?> data =
          (args is List && args.isNotEmpty && args.first is Map)
              ? (args.first as Map)
              : const <Object?, Object?>{};
      final String expression = data['expression']?.toString() ?? '';
      final String reading = data['reading']?.toString() ?? '';
      if (model != null && expression.isNotEmpty) {
        reply = await _toggleOrCheckFavorite(
          model,
          toggle: handler == 'favoriteEntry',
          expression: expression,
          reading: reading,
        );
      }
    } catch (e, st) {
      glog('favorite: EXCEPTION $e\n$st');
      reply = false;
    }
    if (id != null) {
      glog('favorite: $handler -> reply=$reply (id=$id)');
      unawaited(GlobalLookupChannel.resolveBridge(id, reply));
    }
  }

  /// TODO-1188 — favorite toggle ([toggle] true, favoriteEntry) or read ([toggle]
  /// false, favoriteCheck) against the FavoriteWords table. Returns the resulting
  /// favorited state (true = now favorited). Uses [kStatSourceBook] to match the
  /// in-app dictionary default ([DictionaryPageMixin.dictionarySourceType]) so the
  /// (expression, reading, sourceType) uniqueness key is SHARED with in-book
  /// favorites — a word favorited app-out and the same word in the book reader
  /// popup toggle the same row (consistent ★ across surfaces). No toast here: the
  /// main window is backgrounded behind the external app, so the star flip in the
  /// overlay iframe (driven by this returned bool) is the user-visible feedback.
  Future<bool> _toggleOrCheckFavorite(
    AppModel model, {
    required bool toggle,
    required String expression,
    required String reading,
  }) async {
    final HibikiDatabase db = model.database;
    final bool already = await db.isFavoriteWord(
      expression: expression,
      reading: reading,
      sourceType: kStatSourceBook,
    );
    if (!toggle) {
      return already; // favoriteCheck: report the current state, no write.
    }
    if (already) {
      await db.removeFavoriteWord(
        expression: expression,
        reading: reading,
        sourceType: kStatSourceBook,
      );
      return false;
    }
    await db.addFavoriteWord(
      expression: expression,
      reading: reading,
      glossary: '',
      sourceType: kStatSourceBook,
      dateKey: statTodayKey(),
    );
    return true;
  }

  /// TODO-1188 follow-up — resolves a DEFERRED mineEntry bridge call and pushes
  /// the {ankiConnect, noteId} result back to the overlay iframe via
  /// [GlobalLookupChannel.resolveBridge] so popup.js flips the ➕ button
  /// (parseMineResult). Mirrors the in-app [DictionaryPageMixin.onMineEntry].
  /// Always resolves — even on error / no model — so the ➕ button never freezes
  /// (same contract as [_handleFavoriteBridge] / [_handleAudioBridge]).
  Future<void> _handleMineBridge(Map<String, Object?> message) async {
    final int? id = (message['__bridgeId'] is num)
        ? (message['__bridgeId'] as num).toInt()
        : null;
    Map<String, Object?> reply = const <String, Object?>{
      'ankiConnect': false,
      'noteId': null,
    };
    try {
      final AppModel? model = _appModel;
      final Object? args = message['args'];
      final Map<Object?, Object?> raw =
          (args is List && args.isNotEmpty && args.first is Map)
              ? (args.first as Map)
              : const <Object?, Object?>{};
      final Map<String, String> fields = <String, String>{
        for (final MapEntry<Object?, Object?> e in raw.entries)
          e.key.toString(): e.value?.toString() ?? '',
      };
      final String expression = fields['expression'] ?? '';
      if (model != null && expression.isNotEmpty) {
        reply = await _mineEntry(model, fields);
      }
    } catch (e, st) {
      glog('mine: EXCEPTION $e\n$st');
      reply = const <String, Object?>{'ankiConnect': false, 'noteId': null};
    }
    if (id != null) {
      glog('mine: mineEntry -> reply=$reply (id=$id)');
      unawaited(GlobalLookupChannel.resolveBridge(id, reply));
    }
  }

  /// TODO-1188 follow-up — mines [fields] to Anki through the same
  /// [BaseAnkiRepository.mineEntry] path the in-app dictionary popup uses
  /// ([DictionaryPageMixin.onMineEntry]), records the mined-count + mined-sentence
  /// stats on success (source [kStatSourceBook], to match the in-book dictionary
  /// default so the shared uniqueness key + tag category stay consistent across
  /// surfaces), and returns the popup.js-shaped {ankiConnect, noteId} reply.
  ///
  /// Gaiji (外字) bytes are flushed to the Anki media cache first (via
  /// [writeDictionaryMediaCache]) so dictionary media embeds rather than degrading
  /// to alt text — exactly as the in-app mineEntry handler does. App-external
  /// lookup has NO screenshot / sentence-audio media context (the source text
  /// lives in another app), so the card is a plain text/dictionary card; the
  /// word-pronunciation `audio` field is still resolved by popup.js's
  /// buildMinePayload when audio sources are configured. No toast: the main window
  /// is backgrounded behind the external app (Windows Fluttertoast would not
  /// render over it), so the button's ➕→✓ flip — driven by the follow-up
  /// duplicateCheck reading THIS card back — is the user-visible feedback.
  Future<Map<String, Object?>> _mineEntry(
    AppModel model,
    Map<String, String> fields,
  ) async {
    await writeDictionaryMediaCache(fields['dictionaryMedia'] ?? '');
    final BaseAnkiRepository repo =
        model.platformServices.createAnkiRepository();
    final MineOutcome outcome = await repo.mineEntry(
      rawPayloadJson: jsonEncode(fields),
      context: AnkiMiningContext(
        sentence: fields['sentence'] ?? '',
        source: AnkiMiningSource.book,
      ),
    );
    // 与 in-app onMineEntry 同判据：仅 MineResult.success 回 ankiConnect=true + noteId
    // （AnkiConnect 非空进「最新可改」态；AnkiDroid 恒 null=优雅降级）。重复/失败回
    // false+null，随后 popup.js 的 duplicateCheck 若查到已存在仍会把按钮涂成 ✓。
    final bool success = outcome.result == MineResult.success;
    if (success) {
      unawaited(_recordMinedStats(model, fields, outcome.noteId));
    }
    return <String, Object?>{
      'ankiConnect': success,
      'noteId': success ? outcome.noteId : null,
    };
  }

  /// TODO-1204 — records one lookup on every app-external hotkey / nested lookup
  /// (source [kStatSourceBook]; no book locator — global overlay is not tied to a
  /// book, so it only feeds the stats page "lookup" totals, never a per-book
  /// tile). Best-effort: any failure is logged and swallowed.
  void _recordLookupCount() {
    final AppModel? model = _appModel;
    if (model == null) {
      return;
    }
    // best-effort：连同同步阶段（[AppModel.database] late 字段 getter 在 DB 未初始化时
    // 会抛 LateInitializationError）一起吞掉——查词计数是旁路埋点，绝不打断查词回复。
    try {
      unawaited(model.database
          .addLookupCount(sourceType: kStatSourceBook, dateKey: statTodayKey())
          .catchError((Object e, StackTrace st) {
        glog('lookup-count: EXCEPTION $e\n$st');
      }));
    } catch (e, st) {
      glog('lookup-count: EXCEPTION (sync) $e\n$st');
    }
  }

  /// TODO-1188 follow-up — records one mined-count + one mined-sentence history
  /// row on a successful app-external mine (source [kStatSourceBook]; no book
  /// locator — same as home / standalone lookup, mirrors
  /// [DictionaryPageMixin.recordMined]/[recordMinedSentence]). Best-effort: any
  /// failure is logged and swallowed so a stats hiccup never fails the reply.
  Future<void> _recordMinedStats(
    AppModel model,
    Map<String, String> fields,
    int? noteId,
  ) async {
    try {
      final HibikiDatabase db = model.database;
      final String dateKey = statTodayKey();
      await db.addMiningCount(sourceType: kStatSourceBook, dateKey: dateKey);
      // TODO-1204：并行写 per-book 制卡计数（app 外全局查词无书 → bookKey/title 空，
      // 只进统计页「查词」汇总。addMiningCount 保留不动，Never break userspace）。
      await db.addMineCountPerBook(
          sourceType: kStatSourceBook, dateKey: dateKey);
      await db.addMinedSentence(
        source: kStatSourceBook,
        dateKey: dateKey,
        expression: fields['expression'] ?? '',
        reading: fields['reading'] ?? '',
        glossary: fields['glossary'] ?? '',
        sentence: fields['sentence'] ?? '',
        noteId: noteId,
      );
    } catch (e, st) {
      glog('mine: record stats FAILED (non-fatal): $e\n$st');
    }
  }

  /// TODO-1188 follow-up — resolves a DEFERRED duplicateCheck bridge call
  /// (queries Anki live for whether [expression]/[reading] already has a card via
  /// [BaseAnkiRepository.isDuplicate] — the same repo path in-app checkDuplicate
  /// uses) and pushes the bool back to the overlay iframe so popup.js paints the
  /// ✓ (already mined) / ➕ (mineable) state at lookup time and after a mine.
  /// Always resolves — even on error / no model — so the paint never hangs.
  Future<void> _handleDuplicateBridge(Map<String, Object?> message) async {
    final int? id = (message['__bridgeId'] is num)
        ? (message['__bridgeId'] as num).toInt()
        : null;
    bool reply = false;
    try {
      final AppModel? model = _appModel;
      final Object? args = message['args'];
      final Map<Object?, Object?> data =
          (args is List && args.isNotEmpty && args.first is Map)
              ? (args.first as Map)
              : const <Object?, Object?>{};
      final String expression = data['expression']?.toString() ?? '';
      final String reading = data['reading']?.toString() ?? '';
      if (model != null && expression.isNotEmpty) {
        final BaseAnkiRepository repo =
            model.platformServices.createAnkiRepository();
        reply = await repo.isDuplicate(expression, reading);
      }
    } catch (e, st) {
      glog('duplicate: EXCEPTION $e\n$st');
      reply = false;
    }
    if (id != null) {
      glog('duplicate: duplicateCheck -> reply=$reply (id=$id)');
      unawaited(GlobalLookupChannel.resolveBridge(id, reply));
    }
  }

  /// TODO-1225 — resolves a DEFERRED `overwriteTargetNoteId` probe: reverse-looks
  /// up an EXISTING note id that [expression]/[reading] can overwrite in place via
  /// [BaseAnkiRepository.findOverwriteTargetNoteId] — the SAME path the in-app
  /// popup uses ([DictionaryPageMixin.findOverwriteTargetNoteId]). Only returns a
  /// non-null id when the user set [AnkiSettings.overwriteScope] to `all` AND the
  /// backend (AnkiConnect) can resolve one; otherwise (default `latest` / AnkiDroid)
  /// it stays `null` and popup.js keeps the ordinary +/✓ two-state (Never break
  /// userspace). A real id promotes the earlier card to popup.js's editable ✓↩
  /// state so a single click overwrites it (updateEntry). popup.js expects a BARE
  /// number (or null), so the reply is the raw `int?` — NOT wrapped in a map.
  /// Always resolves — even on error / no model — so the ✓/+ paint never hangs
  /// (mirrors [_handleDuplicateBridge]).
  Future<void> _handleOverwriteTargetBridge(
      Map<String, Object?> message) async {
    final int? id = (message['__bridgeId'] is num)
        ? (message['__bridgeId'] as num).toInt()
        : null;
    int? reply;
    try {
      final AppModel? model = _appModel;
      final Object? args = message['args'];
      final Map<Object?, Object?> data =
          (args is List && args.isNotEmpty && args.first is Map)
              ? (args.first as Map)
              : const <Object?, Object?>{};
      final String expression = data['expression']?.toString() ?? '';
      final String reading = data['reading']?.toString() ?? '';
      if (model != null && expression.isNotEmpty) {
        final BaseAnkiRepository repo =
            model.platformServices.createAnkiRepository();
        reply = await repo.findOverwriteTargetNoteId(expression, reading);
      }
    } catch (e, st) {
      glog('overwrite-target: EXCEPTION $e\n$st');
      reply = null;
    }
    if (id != null) {
      glog('overwrite-target: overwriteTargetNoteId -> reply=$reply (id=$id)');
      unawaited(GlobalLookupChannel.resolveBridge(id, reply));
    }
  }

  /// TODO-1225 — resolves a DEFERRED `updateEntry` bridge call: OVERWRITES an
  /// EXISTING note ([noteId]) in place with freshly-built fields through
  /// [BaseAnkiRepository.updateMinedNote] — the SAME contract the in-app popup uses
  /// ([DictionaryPageMixin.onUpdateEntry]). Reuses the mineEntry field/media path
  /// (flushes gaiji [writeDictionaryMediaCache] first so overwrite carries the same
  /// dictionary media) but does NOT create a new card and does NOT record mining
  /// stats — an overwrite fixes an existing card in place (mirrors the in-app
  /// `describeMineOutcome(overwrite: true)`, which does not count). popup.js's
  /// `updateEntry` sends `{ noteId, fields }` (NOT the flat mineEntry payload), so
  /// the fields live one level down under `fields`. Pushes the popup.js-shaped
  /// {ankiConnect, noteId} reply back so the ✓↩ button refreshes. Always resolves —
  /// even on error / no model / missing note id — so the ✓↩ button never freezes
  /// (same contract as [_handleMineBridge]).
  Future<void> _handleUpdateBridge(Map<String, Object?> message) async {
    final int? id = (message['__bridgeId'] is num)
        ? (message['__bridgeId'] as num).toInt()
        : null;
    Map<String, Object?> reply = const <String, Object?>{
      'ankiConnect': false,
      'noteId': null,
    };
    try {
      final AppModel? model = _appModel;
      final Object? args = message['args'];
      final Map<Object?, Object?> envelope =
          (args is List && args.isNotEmpty && args.first is Map)
              ? (args.first as Map)
              : const <Object?, Object?>{};
      final int? noteId = (envelope['noteId'] is num)
          ? (envelope['noteId'] as num).toInt()
          : null;
      final Object? rawFields = envelope['fields'];
      final Map<Object?, Object?> raw =
          rawFields is Map ? rawFields : const <Object?, Object?>{};
      final Map<String, String> fields = <String, String>{
        for (final MapEntry<Object?, Object?> e in raw.entries)
          e.key.toString(): e.value?.toString() ?? '',
      };
      final String expression = fields['expression'] ?? '';
      if (model != null && noteId != null && expression.isNotEmpty) {
        reply = await _updateEntry(model, noteId, fields);
      }
    } catch (e, st) {
      glog('update: EXCEPTION $e\n$st');
      reply = const <String, Object?>{'ankiConnect': false, 'noteId': null};
    }
    if (id != null) {
      glog('update: updateEntry -> reply=$reply (id=$id)');
      unawaited(GlobalLookupChannel.resolveBridge(id, reply));
    }
  }

  /// TODO-1225 — overwrites note [noteId] with [fields] through the same
  /// [BaseAnkiRepository.updateMinedNote] path the in-app popup uses
  /// ([DictionaryPageMixin.onUpdateEntry]). Flushes gaiji dictionary media first
  /// (as [_mineEntry] does) so the overwrite carries identical media, then updates
  /// by id WITHOUT recording stats (overwrite does not count). Returns the
  /// popup.js-shaped {ankiConnect, noteId} reply (ankiConnect=true + noteId only on
  /// [MineResult.success]; AnkiDroid's default-degrade [updateMinedNote] returns
  /// failure → false+null, keeping the ✓↩ path a no-op there, Never break userspace).
  Future<Map<String, Object?>> _updateEntry(
    AppModel model,
    int noteId,
    Map<String, String> fields,
  ) async {
    await writeDictionaryMediaCache(fields['dictionaryMedia'] ?? '');
    final BaseAnkiRepository repo =
        model.platformServices.createAnkiRepository();
    final MineOutcome outcome = await repo.updateMinedNote(
      noteId: noteId,
      rawPayloadJson: jsonEncode(fields),
      context: AnkiMiningContext(
        sentence: fields['sentence'] ?? '',
        source: AnkiMiningSource.book,
      ),
    );
    final bool success = outcome.result == MineResult.success;
    return <String, Object?>{
      'ankiConnect': success,
      'noteId': success ? outcome.noteId : null,
    };
  }

  /// 全局查词查到词后，按用户「自动朗读」(autoReadOnLookup) 偏好自动发音。
  /// 复用主 Dart 查词链路同一去重协调器 (LookupAutoReadCoordinator)，播放走 overlay
  /// 已有的两步音频桥 (resolveLookupAudioUrl -> TtsChannel.playAudioRef)，与手动 ♪
  /// 按钮 (_handleAudioBridge) 同一解析/播放路径，不另起 playLookupAudio 绕过 overlay 桥。
  void _autoReadFirstEntry(AppModel model, DictionarySearchResult result) {
    if (!ReaderHibikiSource.instance.autoReadOnLookup) {
      return;
    }
    if (result.entries.isEmpty) {
      return;
    }
    final DictionaryEntry entry = result.entries.first;
    final String expression = entry.word;
    final String reading = entry.reading;
    if (expression.isEmpty) {
      return;
    }
    unawaited(LookupAutoReadCoordinator.instance.runAutomatic(
      expression: expression,
      reading: reading,
      play: () => _playWordAudio(model, expression, reading),
    ));
  }

  /// overlay 音频桥的两步：解析配置源 URL，再用 overlay 同一播放器播放（与
  /// _handleAudioBridge 的 resolveWordAudio/playWordAudio 逐步一致）。
  Future<void> _playWordAudio(
      AppModel model, String expression, String reading) async {
    final String? url = await resolveLookupAudioUrl(model, expression, reading);
    glog('autoread: resolved url=$url for "$expression"/"$reading"');
    if (url == null || url.isEmpty) {
      return;
    }
    await TtsChannel.instance.playAudioRef(
      url,
      volume: ReaderHibikiSource.instance.lookupAudioVolumeGain,
    );
  }

  Future<void> _lookupNested(String query, Rect? anchorRect) async {
    final AppModel? model = _appModel;
    if (model == null) {
      return;
    }
    try {
      _recordLookupCount();
      // TODO-1190 — the PARENT frame (where the clicked word lives) is the
      // current stack top. Capture its insertion-order index BEFORE pushing the
      // child so we can highlight the searched word in the parent card after the
      // child renders (app-external parity with the in-app popup, which marks the
      // clicked word in the parent via DictionaryPopupWebView.highlightSelection).
      final int parentIndex = _stack.length - 1;
      final DictionarySearchResult result = await model.searchDictionary(
        searchTerm: query,
        searchWithWildcards: false,
      );
      _lastSentWidth = -1;
      _lastSentHeight = -1;
      // TODO-867 P3c: push a CHILD frame onto the stack (parent = current
      // top). pushLookupFrame drops a no-result nested lookup (resultCount<=0),
      // so an empty nested search leaves the stack unchanged (identical object)
      // — no empty child card is stacked. Rendering goes through the host stack
      // (renderStack); there is no top-level direct render anymore.
      _pushChildFrame(query, result, anchorRect);
      await _renderStack();
      glog('nested: "$query" entries=${result.entries.length}');
      // TODO-1190 — mark the searched word inside the PARENT card's popup.js
      // realm (host.highlightFrame -> hoshiSelection.highlightSelection). Only
      // when the child search matched something; count = the matched char length
      // (same source the in-app lookupHighlightCharCount reads). No-op host-side
      // on a bad index / non-positive count.
      final int highlightCount = result.entries.isEmpty
          ? 0
          : model.targetLanguage.getFinalHighlightLength(
              result: result,
              searchTerm: query,
            );
      if (parentIndex >= 0 && highlightCount > 0) {
        await GlobalLookupChannel.render(
            buildHighlightFrameScript(parentIndex, highlightCount));
      }
      _autoReadFirstEntry(model, result);
    } catch (e, st) {
      glog('nested: EXCEPTION $e\n$st');
    }
  }

  /// Resets the stack to a single root frame for a fresh hotkey lookup. The
  /// root is ALWAYS seeded (even on a no-result lookup): the user explicitly
  /// invoked the lookup, so its card must show — popup.js inside the root iframe
  /// renders its own no-results state from window._noResultsMessage. Only NESTED
  /// children drop on no result (see _pushChildFrame), so a click on a word with
  /// no entries does not stack an empty child. [text] is the query, [result] its
  /// search result. Builds the root frame directly (not via pushLookupFrame,
  /// which would drop a no-result root). resultCount stays accurate for
  /// diagnostics/linkage.
  void _resetStackRoot(String text, DictionarySearchResult result) {
    _frameResults.clear();
    _frameAnchors.clear();
    // TODO-1095 — the root frame keeps a STABLE id across hotkey lookups so the
    // host REUSES the already-loaded root iframe (re-inject settingsJs, re-render
    // in place) instead of tearing it down + rebuilding a cold iframe every
    // lookup. beginLookup (sent in _onHotKey) re-gates the reused shell so the
    // reveal still waits for the NEW card's render. Nested children keep minting
    // monotonic ids (they are genuinely added/removed).
    const String id = kGlobalLookupRootFrameId;
    final GlobalLookupFrame root = GlobalLookupFrame(
      id: id,
      query: text,
      parentIndex: -1,
      resultCount: result.entries.length,
    );
    _stack = GlobalLookupStack(<GlobalLookupFrame>[root]);
    _frameResults[id] = result;
    // Root anchor stays null: the window is positioned at the cursor, so the
    // root card sits at the window-local origin (no cascade for the root).
    _frameAnchors[id] = null;
  }

  /// Pushes a child frame (nested lookup) whose parent is the current top.
  /// pushLookupFrame drops a no-result lookup, so the stack is unchanged when
  /// [result] is empty (identical object returned). [query] is the clicked
  /// term; [result] its search result.
  void _pushChildFrame(
      String query, DictionarySearchResult result, Rect? anchorRect) {
    final int parentIndex = _stack.length - 1;
    final String id = _nextFrameId();
    final GlobalLookupFrame child = GlobalLookupFrame(
      id: id,
      query: query,
      parentIndex: parentIndex,
      resultCount: result.entries.length,
    );
    final GlobalLookupStack next = pushLookupFrame(_stack, child);
    if (!identical(next, _stack)) {
      _stack = next;
      _frameResults[id] = result;
      // The clicked word window-local CSS px rect (re-anchored by the host
      // shim) so this child cascades off it via computeFrameRect.
      _frameAnchors[id] = anchorRect;
    }
  }

  /// Mints a stable, monotonic per-frame id. The pure stack model never
  /// generates random/clock ids (so it stays testable); the controller owns
  /// id minting here.
  String _nextFrameId() => 'frame-${_frameSeq++}';

  /// Drops cached results for frames no longer in the stack (after a close /
  /// truncate), so the result map does not leak removed layers.
  void _pruneFrameResults() {
    final Set<String> live =
        _stack.frames.map((GlobalLookupFrame f) => f.id).toSet();
    _frameResults.removeWhere((String id, _) => !live.contains(id));
    _frameAnchors.removeWhere((String id, _) => !live.contains(id));
  }

  /// Extracts the first int argument from a host JS message (args[0]).
  /// Returns null when absent / non-numeric.
  int? _firstIntArg(Map<String, Object?> message) {
    final Object? args = message['args'];
    if (args is List && args.isNotEmpty) {
      final Object? first = args.first;
      if (first is num) {
        return first.toInt();
      }
      if (first is String) {
        return int.tryParse(first);
      }
    }
    return null;
  }

  /// Builds the host stack render payload from the current stack + per-frame
  /// results and pushes it to the overlay (TODO-867 P3b). Inert until P3c
  /// injects global_lookup_host.js (the script is guarded by
  /// `window.__globalLookupHost &&`), so the live single-frame overlay is
  /// unaffected today. Frames whose result was pruned are skipped.
  Future<void> _renderStack() async {
    final BuildContext? ctx = _appModel?.navigatorKey.currentContext;
    final AppModel? model = _appModel;
    if (ctx == null || model == null || _stack.isEmpty) {
      return;
    }
    final List<GlobalLookupFramePayload> payloads =
        <GlobalLookupFramePayload>[];
    // TODO-938 — pop the cascade left/right when the last-active reader is a
    // vertical-writing book; null (no book open / lookup over another app)
    // falls back to the horizontal cascade. Same判据 as the in-app reader.
    final bool isVertical = isVerticalFromWritingMode(
        ReaderHibikiSource.readerSettings?.writingMode);
    for (final GlobalLookupFrame frame in _stack.frames) {
      final DictionarySearchResult? result = _frameResults[frame.id];
      if (result == null) {
        continue;
      }
      // TODO-1030 M0 — only the ROOT frame (the hotkey lookup itself) carries
      // the captured sentence banner; nested child lookups (clicked words) have
      // no sentence context, so they render without a banner.
      final bool isRoot = frame.id == kGlobalLookupRootFrameId;
      payloads.add(GlobalLookupFramePayload(
        frame: frame,
        result: result,
        anchorRect: _frameAnchors[frame.id],
        isVertical: isVertical,
        sentence: isRoot ? _currentSentence : '',
      ));
    }
    if (payloads.isEmpty) {
      return;
    }
    // maxWidth/maxHeight are the single card size; children cascade and D2 bbox
    // trims the window down to the real extent.
    final double cardW = model.popupMaxWidth * model.appUiScale;
    final double cardH = model.popupMaxHeight * model.appUiScale;
    // TODO-893 — screenWidth/screenHeight MUST be the real monitor work area
    // (CSS px), NOT the off-screen measurement canvas (_layoutBounds*). The
    // canvas is only ~2x the card, so computeFrameRect's showBelow (spaceBelow
    // >= height) was almost always false -> every child cascaded UP and pushed
    // the parent card off the top of the window. Feeding the true screen lets
    // showBelow correctly decide whether the word's card fits below on screen.
    // Fall back to the measurement canvas only when native reported no work
    // area (e.g. monitor query failed).
    final double screenW = pickScreenDim(_screenWorkW, _layoutBoundsW, cardW);
    final double screenH = pickScreenDim(_screenWorkH, _layoutBoundsH, cardH);
    await GlobalLookupChannel.render(buildStackRenderScript(
      context: ctx,
      appModel: model,
      payloads: payloads,
      screenWidth: screenW,
      screenHeight: screenH,
      maxWidth: cardW,
      maxHeight: cardH,
      // TODO-893 v2 (symptom 3) — lift window-local child anchors into the
      // work-area-absolute domain (shared zero point with screenW/H) before the
      // cascade math, then the builder shifts the result back to window-local.
      selectionScreenOffset: Offset(_cursorWorkX, _cursorWorkY),
      // TODO-1345 (BUG-583 深层根因续) — this lookup's reserved cascade floor so the
      // host commits the headroom-covered origin from the first reveal (an up/left
      // child then never moves the origin -> zero parent displacement).
      originFloorLeft: _originFloorLeft,
      originFloorTop: _originFloorTop,
    ));
  }

  /// TODO-867 P3c C2 — parses the onLinkClick anchor arg ({x,y,width,height} in
  /// window-local CSS px, re-anchored by the host shim) into a [Rect]. Returns
  /// null when the arg is absent/malformed (the render layer then falls back to
  /// the placeholder cascade offset).
  Rect? _anchorRectFromArg(Object? arg) {
    if (arg is! Map) {
      return null;
    }
    double? num2(Object? v) => (v is num) ? v.toDouble() : null;
    final double? x = num2(arg['x']);
    final double? y = num2(arg['y']);
    final double? w = num2(arg['width']);
    final double? h = num2(arg['height']);
    if (x == null || y == null || w == null || h == null) {
      return null;
    }
    return Rect.fromLTWH(x, y, w, h);
  }

  /// TODO-867 P3c C3 — insertion-order index (stack depth, 0 = root) of the frame
  /// with [frameId], or -1 when unknown. The host stamps tapOutside with the
  /// frame id; Dart maps it to the layer index for closeChildPopups.
  int _layerIndexForFrameId(String frameId) {
    final List<GlobalLookupFrame> frames = _stack.frames;
    for (int i = 0; i < frames.length; i++) {
      if (frames[i].id == frameId) {
        return i;
      }
    }
    return -1;
  }

  /// TODO-867 P3c D2/E1 — reveals/resizes the window to the host union bounding
  /// box [box] (window-local CSS px {left,top,width,height}). Converts to
  /// physical px via [dpr] at this C++ window boundary (the layout math itself is
  /// CSS px). The window moves by (box.left, box.top) x dpr off the cursor anchor
  /// and grows to box.width/height x dpr; the host shifted its layer by
  /// (-box.left, -box.top) so the root card stays pinned at the cursor.
  void _applyOverlayBox(AppModel model, double dpr, Map<Object?, Object?> box) {
    double? num2(Object? v) => (v is num) ? v.toDouble() : null;
    final double left = num2(box['left']) ?? 0;
    final double top = num2(box['top']) ?? 0;
    final double width = num2(box['width']) ?? 0;
    final double height = num2(box['height']) ?? 0;
    if (width <= 0 || height <= 0) {
      return;
    }
    // TODO-1231 (BUG-583) — ratchet the origin outward-only so a nested close
    // never slides the window top-left back inward (which raced the host's
    // compensating layer shift across the DWM/WebView2 boundary and lurched the
    // pinned root card). The ratcheted box holds the outermost min-corner seen
    // this session and recomputes width/height so the window still covers the
    // real content extent (maxRight/maxBottom) from that held origin.
    final RatchetedOverlayBox ratcheted = ratchetOverlayOrigin(
      left: left,
      top: top,
      width: width,
      height: height,
      prevLeft: _ratchetLeft,
      prevTop: _ratchetTop,
    );
    _ratchetLeft = ratcheted.left;
    _ratchetTop = ratcheted.top;
    final int dx = (ratcheted.left * dpr).round();
    final int dy = (ratcheted.top * dpr).round();
    final int w = (ratcheted.width * dpr).round();
    final int h = (ratcheted.height * dpr).round();
    if (!_revealed) {
      _revealed = true;
      _revealSafety?.cancel();
      _lastSentWidth = w;
      _lastSentHeight = h;
      _lastSentDx = dx;
      _lastSentDy = dy;
      glog('reveal(box): dpr=$dpr box=($left,$top,$width,$height) '
          'ratchet=(${ratcheted.left},${ratcheted.top}) '
          '-> dx=$dx dy=$dy w=$w h=$h');
      unawaited(GlobalLookupChannel.revealStack(
          dx: dx,
          dy: dy,
          width: w,
          height: h,
          left: ratcheted.left,
          top: ratcheted.top));
    } else if (w != _lastSentWidth ||
        h != _lastSentHeight ||
        dx != _lastSentDx ||
        dy != _lastSentDy) {
      _lastSentWidth = w;
      _lastSentHeight = h;
      _lastSentDx = dx;
      _lastSentDy = dy;
      glog('resize(box): dpr=$dpr box=($left,$top,$width,$height) '
          'ratchet=(${ratcheted.left},${ratcheted.top}) '
          '-> dx=$dx dy=$dy w=$w h=$h');
      unawaited(GlobalLookupChannel.revealStack(
          dx: dx,
          dy: dy,
          width: w,
          height: h,
          left: ratcheted.left,
          top: ratcheted.top));
    }
  }

  /// TODO-867 P3c — legacy single-card sizing (host reported [dpr, physH] rather
  /// than a bbox): reveal/resize at the fixed card width x capped physical
  /// scrollHeight, exactly as before D2. Kept as a fallback so a frame that
  /// somehow reports the scalar form still sizes correctly.
  void _applyOverlayScalar(AppModel model, double dpr, double physH) {
    final int width = (model.popupMaxWidth * model.appUiScale * dpr).round();
    final double maxHeight = model.popupMaxHeight * model.appUiScale * dpr;
    final int height = (physH > maxHeight ? maxHeight : physH).round();
    if (!_revealed) {
      _revealed = true;
      _revealSafety?.cancel();
      _lastSentWidth = width;
      _lastSentHeight = height;
      glog('reveal(scalar): dpr=$dpr physH=$physH -> w=$width h=$height');
      unawaited(GlobalLookupChannel.reveal(width: width, height: height));
    } else if (width != _lastSentWidth || height != _lastSentHeight) {
      _lastSentWidth = width;
      _lastSentHeight = height;
      glog('resize(scalar): dpr=$dpr physH=$physH -> w=$width h=$height');
      unawaited(GlobalLookupChannel.resize(width: width, height: height));
    }
  }
}

/// A parsed dictionary-media request from the overlay WebView2.
///
/// The overlay (app-external global lookup) registers the SAME two custom
/// schemes the in-app InAppWebView does (see
/// `dictionary_webview_media.dart` `dictionaryMediaCustomSchemes`):
///   - `image://?dictionary=<name>&path=<path>` — gaiji / <img> bytes; the
///     Content-Type is the image type for the path's extension.
///   - `dictmedia://<encoded-path>?dictionary=<name>` — a dictionary's <link>
///     stylesheet (and its relative font/bg resources); the path lives in the
///     URL **host** (percent-encoded) and the Content-Type is `text/css`.
///
/// This is a pure, dependency-free parse so it can be unit-tested directly.
class GlobalLookupMediaRequest {
  const GlobalLookupMediaRequest({
    required this.dictionary,
    required this.path,
    required this.contentType,
  });

  final String dictionary;
  final String path;

  /// The HTTP Content-Type the resource should be served as. Mirrors the in-app
  /// `dictionary_webview_media.dart` MIME logic and the native overlay's
  /// `MediaContentTypeHeader`, so the same bytes get the same type on every
  /// surface.
  final String contentType;
}

/// Normalises a dictionary media path the same way the in-app
/// `dictionary_webview_media.dart` `_normalizeMediaPath` does: trims, converts
/// back-slashes to forward, and strips any leading slashes.
String _normalizeGlobalLookupMediaPath(String path) {
  return path.trim().replaceAll('\\', '/').replaceFirst(RegExp(r'^/+'), '');
}

/// Returns the image MIME type for [path]'s extension, mirroring the in-app
/// `_mimeTypeForPath`.
String _globalLookupImageMime(String path) {
  final String ext = path.split('.').last.toLowerCase();
  switch (ext) {
    case 'png':
      return 'image/png';
    case 'jpg':
    case 'jpeg':
      return 'image/jpeg';
    case 'gif':
      return 'image/gif';
    case 'webp':
      return 'image/webp';
    case 'svg':
      return 'image/svg+xml';
    default:
      return 'application/octet-stream';
  }
}

/// Parses an overlay media [url] into (dictionary, path, contentType),
/// scheme-aware, matching the in-app `dictionary_webview_media.dart` parsing
/// exactly. Returns null when the scheme is unsupported or the required fields
/// are missing/empty (the caller then serves a 404 by returning no bytes).
GlobalLookupMediaRequest? resolveGlobalLookupMedia(String url) {
  final Uri uri;
  try {
    uri = Uri.parse(url);
  } catch (_) {
    return null;
  }

  if (uri.scheme == 'image') {
    final String dictionary = uri.queryParameters['dictionary'] ?? '';
    final String path =
        _normalizeGlobalLookupMediaPath(uri.queryParameters['path'] ?? '');
    if (dictionary.isEmpty || path.isEmpty) {
      return null;
    }
    return GlobalLookupMediaRequest(
      dictionary: dictionary,
      path: path,
      contentType: _globalLookupImageMime(path),
    );
  }

  if (uri.scheme == 'dictmedia') {
    final String dictionary = uri.queryParameters['dictionary'] ?? '';
    // The path is the percent-encoded URL host (matching the in-app
    // `Uri.decodeComponent(url.host)` parse).
    final String path = _normalizeGlobalLookupMediaPath(
      Uri.decodeComponent(uri.host),
    );
    if (dictionary.isEmpty || path.isEmpty) {
      return null;
    }
    return GlobalLookupMediaRequest(
      dictionary: dictionary,
      path: path,
      contentType: 'text/css',
    );
  }

  return null;
}
