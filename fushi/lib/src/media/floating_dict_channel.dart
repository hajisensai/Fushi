import 'dart:convert';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter/services.dart';
import 'package:fushi_dictionary/fushi_dictionary.dart';
import 'package:fushi/src/platform/floating_overlay_channel.dart';
import 'package:fushi/src/utils/misc/channel_constants.dart';

typedef FloatingDictSearchHandler =
    Future<DictionarySearchResult?> Function(String term);
typedef FloatingDictAnkiHandler =
    Future<void> Function(String word, String reading, String meaning);
typedef FloatingDictPlayAudioHandler =
    Future<void> Function(String word, String reading);

/// 悬浮词典制卡 payload（`BaseAnkiRepository.mineEntry` 的 rawPayloadJson 形状）。
///
/// 悬浮窗是原生 TextView 窗口，不经 popup.js 的 `buildMinePayload`，只持有降维后的
/// `word / reading / meaning明文`；单词音频必须在这里由调用方经与 app 内同一个解析器
/// （`resolveLookupAudioUrl`）解析后以 [audioRef] 传入（本地路径或 http URL，仓库层按
/// `AnkiAudioRef.classify` 分流），否则 `{audio}` 字段恒空。[audioRef] 为空即不带键。
Map<String, String> buildFloatingDictMinePayload({
  required String word,
  required String reading,
  required String meaning,
  String? audioRef,
}) => <String, String>{
  'expression': word,
  'reading': reading,
  'glossary': DictionaryEntry.meaningToPlainText(meaning),
  if (audioRef != null && audioRef.isNotEmpty) 'audio': audioRef,
};

class FloatingDictChannel extends FloatingOverlayChannel {
  FloatingDictChannel._() : super(FushiChannels.floatingDict);

  static final FloatingDictChannel _instance = FloatingDictChannel._();

  static FloatingDictSearchHandler? _onSearch;
  static FloatingDictAnkiHandler? _onAnkiExport;
  static FloatingDictPlayAudioHandler? _onPlayAudio;

  static void setEventHandlers({
    required FloatingDictSearchHandler onSearch,
    required FloatingDictAnkiHandler onAnkiExport,
    required FloatingDictPlayAudioHandler onPlayAudio,
  }) {
    _onSearch = onSearch;
    _onAnkiExport = onAnkiExport;
    _onPlayAudio = onPlayAudio;
    _instance.channel.setMethodCallHandler(_handleNativeCall);
  }

  static void clearEventHandlers() {
    _onSearch = null;
    _onAnkiExport = null;
    _onPlayAudio = null;
    _instance.channel.setMethodCallHandler(null);
  }

  /// 测试用：直接喂一条 native→Dart 调用，绕过平台通道。
  @visibleForTesting
  static Future<void> debugHandleNativeCall(MethodCall call) =>
      _handleNativeCall(call);

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
            .map(
              (e) => <String, String>{
                'word': e.word,
                'reading': e.reading,
                'meaning': DictionaryEntry.meaningToPlainText(e.meaning),
              },
            )
            .toList();
        await _instance.channel.invokeMethod<void>(
          'searchResult',
          jsonEncode(entries),
        );
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
      case 'playAudio':
        // 悬浮窗 ♪ 按钮：与 app 内自动发音同一条 playLookupAudio 链（启用源 + 顺序）。
        final Map<dynamic, dynamic>? args =
            call.arguments as Map<dynamic, dynamic>?;
        if (args == null || _onPlayAudio == null) return;
        final String word = args['word']?.toString() ?? '';
        if (word.isEmpty) return;
        await _onPlayAudio!(word, args['reading']?.toString() ?? '');
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
    await _instance.channel.invokeMethod<void>(
      'setClipboardMonitoring',
      enabled,
    );
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
