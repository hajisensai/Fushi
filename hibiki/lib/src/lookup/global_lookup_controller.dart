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

import 'dart:io';

import 'package:flutter/services.dart';
import 'package:hibiki/src/lookup/global_lookup_channel.dart';
import 'package:hibiki/src/lookup/selection_capture_ffi.dart';
import 'package:hibiki/src/models/app_model.dart';
import 'package:hibiki_dictionary/hibiki_dictionary.dart';
import 'package:hotkey_manager/hotkey_manager.dart';
import 'package:path/path.dart' as p;
import 'package:screen_retriever/screen_retriever.dart';

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
    if (!isSupported || _started) {
      return;
    }
    _started = true;
    _appModel = appModel;

    await GlobalLookupChannel.prepare(_popupAssetsDir());
    GlobalLookupChannel.setHandlers(
      onGetMedia: _resolveMedia,
      onJsMessage: _onJsMessage,
    );

    _hotKey = HotKey(
      key: PhysicalKeyboardKey.keyL,
      modifiers: <HotKeyModifier>[HotKeyModifier.control, HotKeyModifier.shift],
      scope: HotKeyScope.system,
    );
    await hotKeyManager.register(_hotKey!, keyDownHandler: (_) => _onHotKey());
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
    final AppModel? model = _appModel;
    if (model == null) {
      return;
    }
    // Grab the foreground app's current selection (inject Ctrl+C) — no manual
    // copy needed.
    final String text =
        (await SelectionCapture.captureForegroundSelection() ?? '').trim();
    if (text.isEmpty) {
      return;
    }

    final DictionarySearchResult result = await model.searchDictionary(
      searchTerm: text,
      searchWithWildcards: false,
    );
    final String? popupJson = result.popupJson;
    if (popupJson == null || popupJson.isEmpty) {
      return;
    }

    final Offset cursor = await screenRetriever.getCursorScreenPoint();
    await GlobalLookupChannel.showAt(
      x: cursor.dx.round() + 8,
      y: cursor.dy.round() + 8,
    );
    await GlobalLookupChannel.render(popupJson);
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

  void _onJsMessage(Map<String, Object?> message) {
    // M0: just observe. dismiss/audio handlers land in M2/M3.
    final Object? handler = message['handler'];
    if (handler == 'tapOutside' || handler == 'dismiss') {
      GlobalLookupChannel.hide();
    }
  }
}
