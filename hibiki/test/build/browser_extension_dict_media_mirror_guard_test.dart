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

      // TODO-1219 P3：精确窗制卡——面板行制卡用该行整集拦截的精确 [startMs,endMs] 覆盖 DOM 采样窗。
      test('[$name] content.js mines with the panel row precise window', () {
        final String src = File('$root/content.js').readAsStringSync();
        // hibikiEnqueue 优先消费面板行查词设下的精确窗（hibikiPendingCueWindow），否则回落 DOM 采样。
        expect(src.contains('hibikiPendingCueWindow'), isTrue,
            reason:
                '$root content.js must thread a precise cue window for panel-row mining');
        expect(
            src.contains(
                'cw ? { text: cw.text || \'\', startV: cw.startMs, endV: cw.endMs } : hibikiCurrentCueWindowV()'),
            isTrue,
            reason:
                '$root content.js hibikiEnqueue must prefer the precise window over DOM sampling');
        // 录制边距 + 去重不得丢（复核修订 5 红线）。
        expect(
            src.contains(
                'startV: Math.max(0, w.startV - 200), endV: w.endV + 200'),
            isTrue,
            reason: '$root content.js must keep the -200/+200 record margins');
        expect(src.contains('hibikiQueueKey'), isTrue,
            reason: '$root content.js must keep TODO-1222 dedup');
      });

      // TODO-1219 P3：录制前撤推挤——批量录制整标签页前恢复播放器全宽（录制画面不带面板黑边）。
      test('[$name] batch capture suspends and resumes the panel push', () {
        final String src = File('$root/content.js').readAsStringSync();
        expect(src.contains('window.hibikiSubtitlePanelSuspendPush()'), isTrue,
            reason:
                '$root content.js hibikiRunNetflixBatch must un-push the player before capture');
        expect(src.contains('window.hibikiSubtitlePanelResumePush()'), isTrue,
            reason:
                '$root content.js must re-apply the panel push after capture');
        final int suspend = src.indexOf('hibikiSubtitlePanelSuspendPush()');
        final int resume = src.indexOf('hibikiSubtitlePanelResumePush()');
        expect(suspend >= 0 && resume > suspend, isTrue,
            reason:
                '$root content.js must suspend push before capture and resume after');
      });

      test(
          '[$name] subtitle-panel.js exposes push suspend/resume + precise row window',
          () {
        final String src = File('$root/subtitle-panel.js').readAsStringSync();
        expect(src.contains('window.hibikiSubtitlePanelSuspendPush'), isTrue,
            reason:
                '$root subtitle-panel.js must expose SuspendPush for batch capture');
        expect(src.contains('window.hibikiSubtitlePanelResumePush'), isTrue,
            reason:
                '$root subtitle-panel.js must expose ResumePush for batch capture');
        expect(src.contains('st.pushSuspended'), isTrue,
            reason:
                '$root subtitle-panel.js applyPush must be gated while suspended');
        // 行文本查词把该行精确 [startMs,endMs] 传进 hibikiLookupAtPoint。
        expect(
            src.contains(
                'window.hibikiLookupAtPoint(e.clientX, e.clientY, { startMs: cue.startMs, endMs: cue.endMs, text: cue.text })'),
            isTrue,
            reason:
                '$root subtitle-panel.js row lookup must carry the precise cue window');
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
