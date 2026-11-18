import 'dart:ui';

import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/audiobook/audiobook_bridge.dart';

/// 只实现 `evaluateJavascript` 的假 WebView 控制器：记下每次送进来的脚本。
class _RecordingWebViewController implements InAppWebViewController {
  final List<String> sources = <String>[];

  @override
  Future<dynamic> evaluateJavascript({
    required String source,
    ContentWorld? contentWorld,
  }) async {
    sources.add(source);
    return null;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// reader 每装一章文档都调一次 `AudiobookBridge.inject`；样式段 + 4 段常量函数定义
/// 一次平台通道往返送完，不再分 5 次串行 `evaluateJavascript`。
void main() {
  group('AudiobookBridge.inject', () {
    test('样式与全部函数定义一次 evaluateJavascript 送完', () async {
      final _RecordingWebViewController web = _RecordingWebViewController();
      await AudiobookBridge.inject(
        web,
        primaryColor: const Color.fromARGB(255, 12, 34, 56),
      );

      expect(web.sources.length, 1, reason: '每装一章都注入，不该分多次平台通道往返');
      final String script = web.sources.single;
      // 4 段常量函数各自的入口都在。
      for (final String name in <String>[
        'window.__fushiHighlight = function',
        'window.__fushiImagePauseAdvance = function',
        'window.__fushiResetPrevHighlight = function',
        'window.__fushiApplySentenceAudioCues = function',
        'window.__fushiHighlightSentenceAudioCueById = function',
        'window.__sentenceAudioRequestNav = async function',
        'window.__fushiAnnotate = function',
      ]) {
        expect(script.contains(name), isTrue, reason: '缺 $name');
      }
      // 样式段仍按传入的主题色生成。
      expect(script.contains("s.id = '__fushi_audio_css'"), isTrue);
      expect(script.contains('rgba(12, 34, 56, 1.0)'), isTrue);
      expect(script.trimRight().endsWith('void 0;'), isTrue);
    });

    test('换主题色只换样式段', () {
      final String a = AudiobookBridge.buildInjectScript(
        const Color.fromARGB(255, 1, 2, 3),
      );
      final String b = AudiobookBridge.buildInjectScript(
        const Color.fromARGB(255, 200, 100, 50),
      );
      expect(a.contains('rgba(1, 2, 3, 1.0)'), isTrue);
      expect(b.contains('rgba(200, 100, 50, 1.0)'), isTrue);
      expect(b.contains('rgba(1, 2, 3,'), isFalse);
      final int aFns = a.indexOf('window.__fushiImageBetween');
      final int bFns = b.indexOf('window.__fushiImageBetween');
      expect(aFns, greaterThan(0));
      expect(a.substring(aFns), b.substring(bFns));
    });
  });
}
