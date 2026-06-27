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
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:hibiki/src/lookup/global_lookup_channel.dart';
import 'package:hibiki/src/lookup/global_lookup_layout.dart';
import 'package:hibiki/src/lookup/global_lookup_log.dart';
import 'package:hibiki/src/lookup/global_lookup_render.dart';
import 'package:hibiki/src/lookup/global_lookup_stack.dart';
import 'package:hibiki/src/lookup/selection_capture_ffi.dart';
import 'package:hibiki/src/media/sources/reader_hibiki_source.dart';
import 'package:hibiki/src/models/app_model.dart';
import 'package:hibiki/src/utils/misc/lookup_audio_playback.dart';
import 'package:hibiki/src/utils/misc/lookup_auto_read_coordinator.dart';
import 'package:hibiki/src/utils/misc/tts_channel.dart';
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
  bool _started = false;
  // Last physical size pushed to the overlay; used to converge the page's
  // resize -> re-measure loop (see _onJsMessage 'overlaySize'). Reset per
  // lookup so a new card re-sizes from scratch.
  int _lastSentWidth = -1;
  int _lastSentHeight = -1;
  // The overlay renders off-screen until the first self-measurement, then is
  // revealed once at its final size (no on-screen jitter). False = still
  // off-screen / awaiting reveal. Reset per lookup.
  bool _revealed = false;
  Timer? _revealSafety;

  // TODO-867 P3b nested stack. The ordered lookup-popup stack (index 0 root
  // ... last = deepest child) drives the host renderStack payload. Each
  // frame's own DictionarySearchResult is held alongside (the pure stack
  // model only carries identity/linkage). _frameSeq mints stable per-frame
  // ids (the stack model never generates random/clock ids, see its docs).
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
    );

    _hotKey = HotKey(
      key: PhysicalKeyboardKey.keyD,
      modifiers: <HotKeyModifier>[HotKeyModifier.control, HotKeyModifier.alt],
      scope: HotKeyScope.system,
    );
    try {
      await hotKeyManager.register(_hotKey!,
          keyDownHandler: (_) => _onHotKey());
      glog('start: hotkey Ctrl+Alt+D registered OK');
    } catch (e, st) {
      glog('start: hotkey register FAILED: $e\n$st');
    }
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
      // Grab the foreground app's current selection (inject Ctrl+C) — no manual
      // copy needed.
      final String text =
          (await SelectionCapture.captureForegroundSelection() ?? '').trim();
      if (text.isEmpty) {
        glog('hotkey: empty selection — abort');
        return;
      }

      final DictionarySearchResult result = await model.searchDictionary(
        searchTerm: text,
        searchWithWildcards: false,
      );
      glog('hotkey: searched "$text" -> entries=${result.entries.length}');
      // New card: forget the previous size + reveal state so the overlay
      // re-measures and reveals from scratch.
      _lastSentWidth = -1;
      _lastSentHeight = -1;
      _revealed = false;
      _revealSafety?.cancel();

      // TODO-867 P3c: a new hotkey lookup RESETS the whole stack to a single
      // root frame. The single-frame card is now stack depth 1 rendered through
      // the host iframe (window.__globalLookupHost.renderStack) — the top-level
      // document is global_lookup_host.html (zero popup.js instance), so there
      // is NO top-level direct render anymore (the old buildOverlayRenderScript
      // path is retired). A no-result lookup still seeds a root frame so
      // its iframe shows popup.js's own no-results card (see _resetStackRoot).
      _resetStackRoot(text, result);

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
      await _renderStack();
      glog('hotkey: showAt(atCursor)=${shown.ok} off-screen w0=$w0 h0=$h0 '
          'workCss=${_screenWorkW}x$_screenWorkH rendered');
      _autoReadFirstEntry(model, result);
      // Safety: if the page never reports a size (render failure), reveal at the
      // single-card size (NOT the larger measurement bounds w0/h0) so the card is
      // not stuck invisible off-screen and the fallback window is not oversized.
      final int safeW = (cardW * dpr).round();
      final int safeH = (cardH * dpr).round();
      _revealSafety = Timer(const Duration(milliseconds: 450), () {
        if (!_revealed) {
          _revealed = true;
          glog('reveal: SAFETY timeout w=$safeW h=$safeH');
          unawaited(GlobalLookupChannel.reveal(width: safeW, height: safeH));
        }
      });
    } catch (e, st) {
      glog('hotkey: EXCEPTION $e\n$st');
    }
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
    // Nested lookup: clicking a term/kanji in the card emits onLinkClick with
    // the query as args[0] and the clicked word's anchor rect as args[1]. The
    // host shim (global_lookup_host.js) already re-anchored that rect from the
    // child iframe's LOCAL coords to window-local CSS px, so the child card
    // cascades off the real word position. Re-search and push a child frame.
    if (handler == 'onLinkClick') {
      final Object? args = message['args'];
      if (args is List && args.isNotEmpty) {
        final String query = args.first?.toString() ?? '';
        if (query.isNotEmpty) {
          final Rect? anchor =
              (args.length >= 2) ? _anchorRectFromArg(args[1]) : null;
          unawaited(_lookupNested(query, anchor));
        }
      }
    }
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
    final String id = _nextFrameId();
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
    for (final GlobalLookupFrame frame in _stack.frames) {
      final DictionarySearchResult? result = _frameResults[frame.id];
      if (result == null) {
        continue;
      }
      payloads.add(GlobalLookupFramePayload(
        frame: frame,
        result: result,
        anchorRect: _frameAnchors[frame.id],
        isVertical: false,
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
    final int dx = (left * dpr).round();
    final int dy = (top * dpr).round();
    final int w = (width * dpr).round();
    final int h = (height * dpr).round();
    if (!_revealed) {
      _revealed = true;
      _revealSafety?.cancel();
      _lastSentWidth = w;
      _lastSentHeight = h;
      glog('reveal(box): dpr=$dpr box=($left,$top,$width,$height) '
          '-> dx=$dx dy=$dy w=$w h=$h');
      unawaited(
          GlobalLookupChannel.revealStack(dx: dx, dy: dy, width: w, height: h));
    } else if (w != _lastSentWidth || h != _lastSentHeight) {
      _lastSentWidth = w;
      _lastSentHeight = h;
      glog('resize(box): dpr=$dpr box=($left,$top,$width,$height) '
          '-> dx=$dx dy=$dy w=$w h=$h');
      unawaited(
          GlobalLookupChannel.revealStack(dx: dx, dy: dy, width: w, height: h));
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
