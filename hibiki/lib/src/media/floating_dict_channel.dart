import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:hibiki_dictionary/hibiki_dictionary.dart';
import 'package:hibiki/src/platform/floating_overlay_channel.dart';
import 'package:hibiki/src/utils/misc/channel_constants.dart';

typedef FloatingDictSearchHandler = Future<DictionarySearchResult?> Function(
    String term);
typedef FloatingDictAnkiHandler = Future<void> Function(
    String word, String reading, String meaning);

class FloatingDictChannel extends FloatingOverlayChannel {
  FloatingDictChannel._() : super(HibikiChannels.floatingDict);

  static final FloatingDictChannel _instance = FloatingDictChannel._();

  static FloatingDictSearchHandler? _onSearch;
  static FloatingDictAnkiHandler? _onAnkiExport;

  static void setEventHandlers({
    required FloatingDictSearchHandler onSearch,
    required FloatingDictAnkiHandler onAnkiExport,
  }) {
    _onSearch = onSearch;
    _onAnkiExport = onAnkiExport;
    _instance.channel.setMethodCallHandler(_handleNativeCall);
  }

  static void clearEventHandlers() {
    _onSearch = null;
    _onAnkiExport = null;
    _instance.channel.setMethodCallHandler(null);
  }

  static Future<void> _handleNativeCall(MethodCall call) async {
    switch (call.method) {
      case 'searchTerm':
        final String term = call.arguments as String? ?? '';
        if (term.trim().isEmpty || _onSearch == null) return;
        final DictionarySearchResult? result = await _onSearch!(term);
        if (result == null || result.entries.isEmpty) {
          await _instance.channel.invokeMethod<void>('searchResult', null);
          return;
        }
        final List<Map<String, String>> entries = result.entries
            .map((e) => <String, String>{
                  'word': e.word,
                  'reading': e.reading,
                  'meaning': DictionaryEntry.meaningToPlainText(e.meaning),
                })
            .toList();
        await _instance.channel
            .invokeMethod<void>('searchResult', jsonEncode(entries));
        break;
      case 'ankiExport':
        final Map<dynamic, dynamic>? args =
            call.arguments as Map<dynamic, dynamic>?;
        if (args == null || _onAnkiExport == null) return;
        await _onAnkiExport!(
          args['word']?.toString() ?? '',
          args['reading']?.toString() ?? '',
          args['meaning']?.toString() ?? '',
        );
        break;
      default:
        break;
    }
  }

  // ---------------------------------------------------------------------------
  // Static delegation — call sites like FloatingDictChannel.show() keep working
  // ---------------------------------------------------------------------------

  static Future<bool> canDrawOverlays() => _instance.canDrawOverlaysImpl();

  static Future<bool> show() => _instance.showImpl();

  static Future<void> hide() => _instance.hideImpl();

  static Future<bool> isShowing() => _instance.isShowingImpl();

  static Future<void> setClipboardMonitoring({required bool enabled}) async {
    if (!_instance.isSupported) return;
    await _instance.channel
        .invokeMethod<void>('setClipboardMonitoring', enabled);
  }

  static Future<void> searchTerm(String term) async {
    if (!_instance.isSupported) return;
    await _instance.channel.invokeMethod<void>('searchTerm', term);
  }

  static Future<void> setSearchText(String text) async {
    if (!_instance.isSupported) return;
    await _instance.channel.invokeMethod<void>('setSearchText', text);
  }

  static Future<void> sendSearchResult(String? json) async {
    if (!_instance.isSupported) return;
    await _instance.channel.invokeMethod<void>('searchResult', json);
  }
}
