import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// TODO-1215 guard: dictionary media (gaiji / pitch-accent SVG) rewrite for the
/// browser extension. A real browser has no image:// scheme handler, so the
/// extension rewrites a term's <img src> to the sync server's
/// GET /api/media/dictionary endpoint. This locks the fix in place and keeps the
/// two extension mirrors (bundled assets/ + real source tools/) byte-identical.
///
/// flutter test cwd is the hibiki package root.
void main() {
  const Map<String, String> mirrors = <String, String>{
    'assets': 'assets/browser_extension',
    'tools': '../tools/browser-extension',
  };

  group('extension dict-media rewrite present', () {
    mirrors.forEach((String name, String root) {
      test('[$name] vendor/dict-media.js gates image:// -> http media endpoint',
          () {
        final String src =
            File('$root/vendor/dict-media.js').readAsStringSync();
        // Extension branch: env-gated http rewrite to the server media endpoint.
        expect(src.contains('__hibikiDictMedia'), isTrue,
            reason: '$root dict-media.js missing extension env gate');
        expect(src.contains('/api/media/dictionary'), isTrue,
            reason: '$root dict-media.js missing http media endpoint rewrite');
        // App branch preserved: in-app still emits image:// (must not break app).
        expect(src.contains('image://?dictionary='), isTrue,
            reason: '$root dict-media.js dropped the in-app image:// fallback');
      });

      test('[$name] bridge-shim.js fetches dict media config into window', () {
        final String src = File('$root/bridge-shim.js').readAsStringSync();
        expect(src.contains("type: 'dictMediaConfig'"), isTrue,
            reason: '$root bridge-shim.js does not request dictMediaConfig');
        expect(src.contains('window.__hibikiDictMedia'), isTrue,
            reason:
                '$root bridge-shim.js does not set window.__hibikiDictMedia');
      });

      test('[$name] background.js answers dictMediaConfig with base + token',
          () {
        final String src = File('$root/background.js').readAsStringSync();
        expect(src.contains("msg.type === 'dictMediaConfig'"), isTrue,
            reason: '$root background.js does not handle dictMediaConfig');
        expect(src.contains('sendResponse({ ok: true, base, token })'), isTrue,
            reason:
                '$root background.js dictMediaConfig must return base+token');
      });

      // TODO-1219 P1：Netflix 整集字幕拦截链存在性守卫（数据源 + 解析器 + 跨世界桥 + run_at）。
      test('[$name] netflix-bridge.js hooks manifest & bridges cues', () {
        final String src = File('$root/netflix-bridge.js').readAsStringSync();
        expect(src.contains('JSON.parse'), isTrue,
            reason: '$root netflix-bridge.js missing JSON.parse hook');
        expect(src.contains('timedtexttracks'), isTrue,
            reason: '$root netflix-bridge.js missing timedtexttracks sniff');
        expect(src.contains("__hibikiNf: 'cues'"), isTrue,
            reason: '$root netflix-bridge.js missing cross-world cues bridge');
      });

      test('[$name] subtitle-adapters.js exposes VTT/TTML parsers', () {
        final String src =
            File('$root/subtitle-adapters.js').readAsStringSync();
        expect(src.contains('function parseWebVtt'), isTrue,
            reason: '$root subtitle-adapters.js missing parseWebVtt');
        expect(src.contains('function parseTtml'), isTrue,
            reason: '$root subtitle-adapters.js missing parseTtml');
      });

      test('[$name] content.js receives full-episode cues', () {
        final String src = File('$root/content.js').readAsStringSync();
        expect(src.contains("e.data.__hibikiNf !== 'cues'"), isTrue,
            reason: '$root content.js missing full-episode cues receiver');
        expect(src.contains('hibikiEpisodeCues'), isTrue,
            reason: '$root content.js missing hibikiEpisodeCues store');
      });

      test('[$name] netflix-bridge runs at document_start', () {
        final String src = File('$root/manifest.json').readAsStringSync();
        expect(src.contains('"run_at": "document_start"'), isTrue,
            reason:
                '$root manifest.json netflix-bridge must run at document_start');
      });

      // TODO-1219 P2：字幕列表面板存在性守卫（面板文件 + content.js 契约 + manifest bundle + CSS）。
      test('[$name] subtitle-panel.js builds the Netflix subtitle list panel',
          () {
        final String src = File('$root/subtitle-panel.js').readAsStringSync();
        expect(src.contains("'hibiki-subtitle-panel'"), isTrue,
            reason: '$root subtitle-panel.js missing panel element id');
        expect(src.contains('window.hibikiEpisodeCues'), isTrue,
            reason: '$root subtitle-panel.js must consume hibikiEpisodeCues');
        expect(src.contains("__hibikiNf: 'seek'"), isTrue,
            reason: '$root subtitle-panel.js must reuse the P1 seek bridge');
        expect(src.contains('window.hibikiSubtitlePanelOnCues'), isTrue,
            reason: '$root subtitle-panel.js missing cues-update subscription');
      });

      test('[$name] content.js exposes cues store + lookup entry for the panel',
          () {
        final String src = File('$root/content.js').readAsStringSync();
        expect(src.contains('window.hibikiEpisodeCues = hibikiEpisodeCues'),
            isTrue,
            reason: '$root content.js must expose hibikiEpisodeCues on window');
        expect(src.contains('window.hibikiLookupAtPoint'), isTrue,
            reason:
                '$root content.js must expose hibikiLookupAtPoint for panel row lookup');
        expect(src.contains('window.hibikiSubtitlePanelOnCues'), isTrue,
            reason: '$root content.js must notify the panel on new cues');
      });

      test('[$name] manifest bundles subtitle-panel.js after content.js', () {
        final String src = File('$root/manifest.json').readAsStringSync();
        final int content = src.indexOf('content.js');
        final int panel = src.indexOf('subtitle-panel.js');
        expect(panel > content && content >= 0, isTrue,
            reason:
                '$root manifest.json must list subtitle-panel.js after content.js in the isolated bundle');
      });

      test('[$name] content.css styles the subtitle panel', () {
        final String src = File('$root/vendor/content.css').readAsStringSync();
        expect(src.contains('#hibiki-subtitle-panel'), isTrue,
            reason: '$root vendor/content.css missing subtitle panel styles');
      });
    });
  });

  group('extension mirrors stay byte-identical for TODO-1215 files', () {
    for (final String rel in const <String>[
      'vendor/dict-media.js',
      'bridge-shim.js',
      'background.js',
      // TODO-1219 P1：Netflix 整集字幕拦截链改动的共享文件，纳入字节守卫防两镜像漂移。
      'netflix-bridge.js',
      'subtitle-adapters.js',
      'content.js',
      'manifest.json',
      // TODO-1219 P2：字幕列表面板新增/改动的共享文件，同样纳入字节守卫。
      'subtitle-panel.js',
      'vendor/content.css',
    ]) {
      test(rel, () {
        final List<int> tools =
            File('../tools/browser-extension/$rel').readAsBytesSync();
        final List<int> assets =
            File('assets/browser_extension/$rel').readAsBytesSync();
        expect(assets, tools,
            reason: 'assets/browser_extension/$rel out of sync with tools/');
      });
    }
  });
}
