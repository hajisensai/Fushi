import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:hibiki_dictionary/hibiki_dictionary.dart';
import 'package:hibiki/src/utils/misc/channel_constants.dart';

typedef FloatingDictSearchHandler = Future<DictionarySearchResult?> Function(
    String term);
typedef FloatingDictAnkiHandler = Future<void> Function(
    String word, String reading, String meaning);

class FloatingDictChannel {
  FloatingDictChannel._();

  static const MethodChannel _channel = HibikiChannels.floatingDict;

  static FloatingDictSearchHandler? _onSearch;
  static FloatingDictAnkiHandler? _onAnkiExport;

  static void setEventHandlers({
    required FloatingDictSearchHandler onSearch,
    required FloatingDictAnkiHandler onAnkiExport,
  }) {
    _onSearch = onSearch;
    _onAnkiExport = onAnkiExport;
    _channel.setMethodCallHandler(_handleNativeCall);
  }

  static void clearEventHandlers() {
    _onSearch = null;
    _onAnkiExport = null;
    _channel.setMethodCallHandler(null);
  }

  static Future<void> _handleNativeCall(MethodCall call) async {
    switch (call.method) {
      case 'searchTerm':
        final String term = call.arguments as String? ?? '';
        if (term.trim().isEmpty || _onSearch == null) return;
        final DictionarySearchResult? result = await _onSearch!(term);
        if (result == null || result.entries.isEmpty) {
          await _channel.invokeMethod<void>('searchResult', null);
          return;
        }
        final List<Map<String, String>> entries = result.entries
            .map((e) => <String, String>{
                  'word': e.word,
                  'reading': e.reading,
                  'meaning': DictionaryEntry.meaningToPlainText(e.meaning),
                })
            .toList();
        await _channel.invokeMethod<void>('searchResult', jsonEncode(entries));
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

  static Future<bool> canDrawOverlays() async {
    if (!Platform.isAndroid) return false;
    final bool? result = await _channel.invokeMethod<bool>('canDrawOverlays');
    return result ?? false;
  }

  static Future<bool> show() async {
    if (!Platform.isAndroid) return false;
    final bool? result = await _channel.invokeMethod<bool>('show');
    return result ?? false;
  }

  static Future<void> hide() async {
    if (!Platform.isAndroid) return;
    await _channel.invokeMethod<void>('hide');
  }

  static Future<bool> isShowing() async {
    if (!Platform.isAndroid) return false;
    final bool? result = await _channel.invokeMethod<bool>('isShowing');
    return result ?? false;
  }

  static Future<void> setClipboardMonitoring({required bool enabled}) async {
    if (!Platform.isAndroid) return;
    await _channel.invokeMethod<void>('setClipboardMonitoring', enabled);
  }

  static Future<void> searchTerm(String term) async {
    if (!Platform.isAndroid) return;
    await _channel.invokeMethod<void>('searchTerm', term);
  }

  static Future<void> setSearchText(String text) async {
    if (!Platform.isAndroid) return;
    await _channel.invokeMethod<void>('setSearchText', text);
  }

  static Future<void> sendSearchResult(String? json) async {
    if (!Platform.isAndroid) return;
    await _channel.invokeMethod<void>('searchResult', json);
  }
}
