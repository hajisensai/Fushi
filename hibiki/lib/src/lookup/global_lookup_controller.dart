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
      final int w0 = (model.popupMaxWidth * model.appUiScale * dpr).round();
      final int h0 = (model.popupMaxHeight * model.appUiScale * dpr).round();
      final bool shown = await GlobalLookupChannel.showAt(
          x: 0, y: 0, width: w0, height: h0, atCursor: true);
      await _renderStack();
      glog('hotkey: showAt(atCursor)=$shown off-screen w0=$w0 h0=$h0 rendered');
      _autoReadFirstEntry(model, result);
      // Safety: if the page never reports a size (render failure), reveal at the
      // provisional size anyway so the card is not stuck invisible off-screen.
      _revealSafety = Timer(const Duration(milliseconds: 450), () {
        if (!_revealed) {
          _revealed = true;
          glog('reveal: SAFETY timeout w=$w0 h=$h0');
          unawaited(GlobalLookupChannel.reveal(width: w0, height: h0));
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
    // Size the bare overlay window from the page's self-measurement
    // (overlaySize = [devicePixelRatio, physicalScrollHeight]). The card fills
    // the viewport (no intrinsic width), so the WIDTH is the in-app logical box
    // (popupMaxWidth * appUiScale) converted to physical px via the monitor DPR;
    // the HEIGHT is the reported physical scrollHeight. Font size / zoom do NOT
    // enter the width — the card reflows inside a fixed box, matching the in-app
    // popup. Native further clamps to the monitor work area.
    if (handler == 'overlaySize') {
      final AppModel? model = _appModel;
      final Object? args = message['args'];
      if (model != null && args is List && args.length >= 2) {
        final double dpr = (args[0] is num) ? (args[0] as num).toDouble() : 1.0;
        final num? physH = args[1] is num ? args[1] as num : null;
        if (dpr > 0 && physH != null && physH > 0) {
          // Faithful to the reader popup: both dimensions are
          // popupMax* × appUiScale, converted to physical px via dpr. WIDTH is
          // fixed; HEIGHT is the content height CAPPED at popupMaxHeight (the
          // card scrolls inside) — without the cap a long entry makes the
          // window fill the whole screen.
          final int width =
              (model.popupMaxWidth * model.appUiScale * dpr).round();
          final double maxHeight =
              model.popupMaxHeight * model.appUiScale * dpr;
          final int height =
              (physH > maxHeight ? maxHeight : physH.toDouble()).round();
          if (!_revealed) {
            // First measurement (off-screen): reveal the card at its final size
            // in one shot — the user never sees the measure→resize jitter.
            _revealed = true;
            _revealSafety?.cancel();
            _lastSentWidth = width;
            _lastSentHeight = height;
            glog('reveal: dpr=$dpr popupMaxWidth=${model.popupMaxWidth} '
                'appUiScale=${model.appUiScale} physH=$physH -> w=$width h=$height');
            unawaited(GlobalLookupChannel.reveal(width: width, height: height));
          } else if (width != _lastSentWidth || height != _lastSentHeight) {
            // Already on-screen (e.g. nested re-lookup changed the content):
            // resize in place. Guarded so the resize→re-measure loop settles.
            _lastSentWidth = width;
            _lastSentHeight = height;
            glog('resize: dpr=$dpr physH=$physH -> w=$width h=$height');
            unawaited(GlobalLookupChannel.resize(width: width, height: height));
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
    // the query as the first arg. Re-search and re-render in place.
    if (handler == 'onLinkClick') {
      final Object? args = message['args'];
      if (args is List && args.isNotEmpty) {
        final String query = args.first?.toString() ?? '';
        if (query.isNotEmpty) {
          unawaited(_lookupNested(query));
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

  Future<void> _lookupNested(String query) async {
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
      _pushChildFrame(query, result);
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
    final String id = _nextFrameId();
    final GlobalLookupFrame root = GlobalLookupFrame(
      id: id,
      query: text,
      parentIndex: -1,
      resultCount: result.entries.length,
    );
    _stack = GlobalLookupStack(<GlobalLookupFrame>[root]);
    _frameResults[id] = result;
  }

  /// Pushes a child frame (nested lookup) whose parent is the current top.
  /// pushLookupFrame drops a no-result lookup, so the stack is unchanged when
  /// [result] is empty (identical object returned). [query] is the clicked
  /// term; [result] its search result.
  void _pushChildFrame(String query, DictionarySearchResult result) {
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
      payloads.add(GlobalLookupFramePayload(frame: frame, result: result));
    }
    if (payloads.isEmpty) {
      return;
    }
    await GlobalLookupChannel.render(buildStackRenderScript(
      context: ctx,
      appModel: model,
      payloads: payloads,
    ));
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
