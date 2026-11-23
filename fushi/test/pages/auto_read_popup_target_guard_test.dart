import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/pages/implementations/dictionary_popup_webview.dart';

import '../helpers/source_guard.dart';

/// BUG-5278：查词自动发音的 WebView 播放目标必须是**本次查词那一层**，并且在真正
/// 要播时才取它的 state。
///
/// 旧实现（`BaseSourcePage._playAutoReadWord`）用「最上层**可见**弹窗」
/// `topPopupState`；自动发音在查词结果一到就触发，这时本层还挂在「等首帧渲染再
/// 翻出」上、不可见 → 顶层查词拿到 null、嵌套查词拿到下面那层旧弹窗，阅读器 / 视频 /
/// 有声书的自动发音从未走上弹窗 `<audio>` 快路径，每次都回落 media_kit（每播重建
/// mpv，首次还要先排完静音预热）——「第一次自动发音要等一会」。
///
/// 端到端行为由 `integration_test/reader_auto_read_popup_webview_itest.dart` 在真
/// WebView2 上咬住；这里是不需要真 app 的那一层。
void main() {
  group('lazyWordAudioPlayer', () {
    test('目标层不在（null）时答 false，交回 Dart 播放器兜底', () async {
      int resolved = 0;
      final Future<bool> Function(String) play =
          DictionaryPopupWebViewState.lazyWordAudioPlayer(() {
            resolved++;
            return null;
          });
      // 构造时不取 state——只在真正要播时取（同一帧新建的层此刻可能还没挂上）。
      expect(resolved, 0);
      expect(await play('data:audio/mpeg;base64,AA=='), isFalse);
      expect(resolved, 1);
    });
  });

  group('自动发音播放目标接线', () {
    final String base = File(
      'lib/src/pages/base_source_page.dart',
    ).readAsStringSync();
    final String mixin = File(
      'lib/src/pages/implementations/dictionary_page_mixin.dart',
    ).readAsStringSync();

    test('BaseSourcePage 自动发音播放的是本次查词的那一层，不是最上层可见弹窗', () {
      final String body = maskComments(
        methodBody(base, 'Future<bool> _playAutoReadWord('),
      );
      expect(
        body.contains('topPopupState'),
        isFalse,
        reason:
            'topPopupState 只认可见层，而自动发音触发时本层尚未翻出——'
            '会拿到 null 或下面那层旧弹窗，自动发音永远回落 media_kit',
      );
      expect(body, contains('lazyWordAudioPlayer('));
      expect(body, contains('item.webViewKey.webViewState'));
    });

    test('BaseSourcePage 查词与原地跳转两处触发都把本层 item 传给自动发音', () {
      final String code = maskComments(base);
      final RegExp call = RegExp(r'_autoReadWord\(\s*item,');
      expect(
        call.allMatches(code).length,
        2,
        reason: '顶层查词（beginTop）与弹窗内原地跳转两处都要绑定本层',
      );
    });

    test('DictionaryPageMixin 在要播时才取本层 state（不在触发当下取）', () {
      final String body = maskComments(
        methodBody(mixin, 'Future<bool> playPopupWordAudio('),
      );
      expect(body, contains('lazyWordAudioPlayer('));
      expect(
        body.contains('popupState?.playWordAudioUrl'),
        isFalse,
        reason: '触发当下取的 state 在同一帧新建的层上可能还是 null',
      );
    });
  });
}
