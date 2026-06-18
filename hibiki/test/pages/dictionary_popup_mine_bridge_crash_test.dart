import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

// BUG-293: re-mining the same word after deleting its just-mined Anki card must
// not crash the app (闪退).
//
// Root cause is a boundary-contract defect: the `mineEntry` / `updateEntry`
// addJavaScriptHandler callbacks in dictionary_popup_webview.dart are the single
// Dart->native JS-handler bridge for ALL mining surfaces (reader / video /
// dictionary / audiobook). An override (e.g. VideoHibikiPage._mineVideoCard) or
// writeDictionaryMediaCache can THROW during the re-mine media-capture path
// (ffmpeg / window screenshot / WebView2 frame). If the callback lets that
// exception escape, it crosses the native inappwebview JS-handler boundary and
// takes the whole process down — the same crash class as BUG-233, and the same
// "handler must return, never throw" contract BUG-077 fixed for the repo layer.
//
// These callbacks need a real InAppWebView controller to invoke, so the strongest
// landable guard is a source scan that locks the try/catch + ErrorLogService into
// both callback bodies. Removing either wrapper turns this red.
void main() {
  late String source;

  setUpAll(() {
    source = File(
      'lib/src/pages/implementations/dictionary_popup_webview.dart',
    ).readAsStringSync();
  });

  // Extracts the body of an addJavaScriptHandler(handlerName: '<name>', ...)
  // callback by brace-matching from its `callback: (args) async {` open brace.
  String handlerBody(String name) {
    final int hIdx = source.indexOf("handlerName: '$name'");
    expect(hIdx, greaterThanOrEqualTo(0),
        reason: "the '$name' JS handler must be registered");
    final int cbIdx = source.indexOf('callback:', hIdx);
    expect(cbIdx, greaterThan(hIdx));
    final int open = source.indexOf('{', cbIdx);
    expect(open, greaterThan(cbIdx));
    int depth = 0;
    for (int i = open; i < source.length; i++) {
      final String ch = source[i];
      if (ch == '{') depth++;
      if (ch == '}') {
        depth--;
        if (depth == 0) return source.substring(open, i + 1);
      }
    }
    fail("could not brace-match the '$name' callback body");
  }

  void expectGuarded(
    String name, {
    required String fallbackSnippet,
    List<String> guardedSnippets = const <String>[],
  }) {
    final String body = handlerBody(name);
    expect(body.contains('_guardJsBridge') || body.contains('try {'), isTrue,
        reason:
            "the '$name' bridge callback must wrap its body in try/catch so "
            'an escaping exception never crosses the native JS-handler '
            'boundary and crashes the app (BUG-293).');
    expect(
        body.contains('_guardJsBridge') ||
            body.contains('} catch (e, stack) {'),
        isTrue,
        reason: "the '$name' bridge callback must catch the escaping exception "
            'with its stack.');
    expect(body.contains('ErrorLogService.instance'), isTrue,
        reason: "the '$name' bridge callback must surface the cause via "
            'ErrorLogService instead of swallowing it (BUG-089).');
    expect(body.contains('DictPopupWebview.$name'), isTrue,
        reason: "the '$name' handler log tag must identify the exact bridge.");
    expect(body.contains(fallbackSnippet), isTrue,
        reason: "the '$name' bridge callback must return a type-safe fallback "
            'on the failure path.');

    for (final String snippet in guardedSnippets) {
      expect(body.contains(snippet), isTrue,
          reason: "the '$name' handler must guard the throwing work: $snippet");
    }
  }

  test('mineEntry bridge callback never lets an exception cross the boundary',
      () {
    expectGuarded(
      'mineEntry',
      fallbackSnippet: 'MinePopupResult().toJson()',
      guardedSnippets: <String>[
        'writeDictionaryMediaCache(',
        'widget.onMineEntry!(',
      ],
    );
    final String body = handlerBody('mineEntry');
    expect(body.contains('widget.onMineEntry!('), isTrue,
        reason: 'the mineEntry override invocation must be guarded.');
  });

  test('updateEntry bridge callback never lets an exception cross the boundary',
      () {
    expectGuarded(
      'updateEntry',
      fallbackSnippet: 'MinePopupResult().toJson()',
      guardedSnippets: <String>[
        'writeDictionaryMediaCache(',
        'widget.onUpdateEntry!(',
      ],
    );
    final String body = handlerBody('updateEntry');
    expect(body.contains('widget.onUpdateEntry!('), isTrue,
        reason: 'the update-in-place override (green ✓↩ re-mine after delete) '
            'invocation must be guarded.');
  });

  test('lookup/favorite/audio/link bridge callbacks are all boundary-guarded',
      () {
    const Map<String, String> fallbacks = <String, String>{
      'duplicateCheck': 'false',
      'favoriteEntry': 'false',
      'favoriteCheck': 'false',
      'appendSentence': '0',
      'setSentenceContext': '0',
      'clearSentenceDraft': '0',
      'textSelected': 'null',
      'openLink': 'null',
      'onLinkClick': 'null',
      'queryLocalAudio': 'null',
      'resolveWordAudio': 'null',
      'playWordAudio': 'false',
    };

    for (final MapEntry<String, String> entry in fallbacks.entries) {
      expectGuarded(
        entry.key,
        fallbackSnippet: entry.value,
      );
    }
  });

  test('popup chrome bridge callbacks are all boundary-guarded', () {
    const Map<String, String> fallbacks = <String, String>{
      'tapOutside': 'null',
      'scrolledToBottom': 'null',
      'topPullReleased': 'null',
      'popupRendered': 'null',
    };

    for (final MapEntry<String, String> entry in fallbacks.entries) {
      expectGuarded(
        entry.key,
        fallbackSnippet: entry.value,
      );
    }
  });
}
