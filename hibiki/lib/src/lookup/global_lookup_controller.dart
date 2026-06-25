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
import 'package:hibiki/src/lookup/selection_capture_ffi.dart';
import 'package:hibiki/src/media/sources/reader_hibiki_source.dart';
import 'package:hibiki/src/models/app_model.dart';
import 'package:hibiki/src/utils/misc/lookup_audio_playback.dart';
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
      // New card: forget the previous size so overlaySize re-applies fully.
      _lastSentWidth = -1;
      _lastSentHeight = -1;

      // Always show — popup.js renders a no-results card when there are no
      // entries (matches the in-app popup). Position natively (GetCursorPos =
      // physical px) to avoid the logical/physical DPI mismatch.
      final bool shown =
          await GlobalLookupChannel.showAt(x: 0, y: 0, atCursor: true);
      await _renderResult(result);
      glog('hotkey: showAt(atCursor)=$shown rendered');
    } catch (e, st) {
      glog('hotkey: EXCEPTION $e\n$st');
    }
  }

  /// Resolves gaiji bytes for an image://?dictionary=..&path=.. request.
  Future<Uint8List> _resolveMedia(String url) async {
    try {
      final Uri uri = Uri.parse(url);
      final String dict = uri.queryParameters['dictionary'] ?? '';
      final String path = uri.queryParameters['path'] ?? '';
      if (dict.isEmpty || path.isEmpty) {
        return Uint8List(0);
      }
      final Uint8List? bytes = HoshiDicts.instance.getMediaFile(dict, path);
      return bytes ?? Uint8List(0);
    } catch (_) {
      return Uint8List(0);
    }
  }

  /// Builds the full settings+entries render script (theme colours, zoom, dict
  /// filters, CSS, gaiji, no-results message) and pushes it to the overlay.
  Future<void> _renderResult(DictionarySearchResult result) async {
    final BuildContext? ctx = _appModel?.navigatorKey.currentContext;
    final AppModel? model = _appModel;
    if (ctx == null || model == null) {
      // Fallback: render just the entries so something still shows.
      await GlobalLookupChannel.render(
        'window.lookupEntries = ${result.popupJson ?? '[]'};'
        ' window.renderPopup && window.renderPopup();',
      );
      return;
    }
    await GlobalLookupChannel.render(buildOverlayRenderScript(
      context: ctx,
      appModel: model,
      result: result,
    ));
  }

  void _onJsMessage(Map<String, Object?> message) {
    final Object? handler = message['handler'];
    glog('js: handler=$handler args=${message['args']}');
    if (handler == 'tapOutside' || handler == 'dismiss') {
      GlobalLookupChannel.hide();
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
        final double dpr =
            (args[0] is num) ? (args[0] as num).toDouble() : 1.0;
        final num? physH = args[1] is num ? args[1] as num : null;
        if (dpr > 0 && physH != null && physH > 0) {
          final int width =
              (model.popupMaxWidth * model.appUiScale * dpr).round();
          final int height = physH.round();
          // Converge: only push when the target actually changed, so the
          // resize -> re-measure loop settles instead of ping-ponging.
          if (width != _lastSentWidth || height != _lastSentHeight) {
            _lastSentWidth = width;
            _lastSentHeight = height;
            glog('resize: dpr=$dpr popupMaxWidth=${model.popupMaxWidth} '
                'appUiScale=${model.appUiScale} physH=$physH -> w=$width h=$height');
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
    final int? id =
        (message['__bridgeId'] is num) ? (message['__bridgeId'] as num).toInt() : null;
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
      await _renderResult(result);
      glog('nested: "$query" entries=${result.entries.length}');
    } catch (e, st) {
      glog('nested: EXCEPTION $e\n$st');
    }
  }
}
