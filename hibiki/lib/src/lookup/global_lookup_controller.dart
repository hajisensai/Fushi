// TODO-617 global lookup overlay — orchestration (Windows MVP trigger).
//
// Minimal end-to-end trigger so the overlay can be tried by hand: copy a word
// in any app, press the global hotkey (Ctrl+Shift+L), and the dictionary card
// pops up at the cursor. This is the clipboard-based first cut; the true
// Ctrl+C-injection selection capture is M1.
//
// The main Dart engine owns the dictionary, so this controller does the lookup
// (AppModel.searchDictionary -> popupJson) and pushes it to the native overlay
// (GlobalLookupChannel). image:// gaiji bytes are resolved via HoshiDicts.

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:hibiki/src/lookup/global_lookup_channel.dart';
import 'package:hibiki/src/lookup/global_lookup_log.dart';
import 'package:hibiki/src/lookup/global_lookup_render.dart';
import 'package:hibiki/src/lookup/selection_capture_ffi.dart';
import 'package:hibiki/src/models/app_model.dart';
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
      // Re-press toggles the overlay closed (one reliable global close path).
      if (await GlobalLookupChannel.isShowing()) {
        glog('hotkey: already showing — toggle hide');
        await GlobalLookupChannel.hide();
        return;
      }
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
    // Size the window to the rendered card. popup.js reports the unzoomed
    // scrollHeight; multiply by the same zoom the content uses, and base the
    // width on the reader's popup width (380) so it follows the UI-scale +
    // dictionary font-size settings.
    if (handler == 'contentHeight') {
      final AppModel? model = _appModel;
      final Object? args = message['args'];
      if (model != null && args is List && args.isNotEmpty) {
        final num? h = args.first is num ? args.first as num : null;
        if (h != null && h > 0) {
          final double zoom =
              model.appUiScale * (model.dictionaryFontSize / 16.0);
          final int width = (380 * zoom).round();
          final int height = (h * zoom).round() + 8;
          unawaited(GlobalLookupChannel.resize(width: width, height: height));
        }
      }
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
      await _renderResult(result);
      glog('nested: "$query" entries=${result.entries.length}');
    } catch (e, st) {
      glog('nested: EXCEPTION $e\n$st');
    }
  }
}
