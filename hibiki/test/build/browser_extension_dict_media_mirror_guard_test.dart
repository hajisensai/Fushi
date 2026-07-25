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

      // TODO-1219 用户诉求②：字幕列表面板默认关闭，由扩展 options 的开关（netflixSubtitlePanel）
      // 驱动；键缺省或非 true 一律不显示。锁死「默认关 + 开关门控」防回归成默认打开。
      test('[$name] subtitle-panel.js is gated off by default via a setting',
          () {
        final String src = File('$root/subtitle-panel.js').readAsStringSync();
        expect(src.contains("'netflixSubtitlePanel'"), isTrue,
            reason:
                '$root subtitle-panel.js must read the netflixSubtitlePanel setting');
        expect(src.contains('enabled: false'), isTrue,
            reason:
                '$root subtitle-panel.js must default the panel to disabled (off)');
        expect(src.contains('if (!st.enabled) return;'), isTrue,
            reason:
                '$root subtitle-panel.js cue hook must no-op while disabled (no panel, no reopen chip)');
        expect(src.contains('readEnabled(applyEnabled)'), isTrue,
            reason:
                '$root subtitle-panel.js must consult the setting on load instead of auto-showing');
        expect(src.contains('chrome.storage.onChanged.addListener'), isTrue,
            reason:
                '$root subtitle-panel.js must react to the toggle live via storage.onChanged');
      });

      test('[$name] options expose the Netflix subtitle-list toggle', () {
        final String html = File('$root/options.html').readAsStringSync();
        final String js = File('$root/options.js').readAsStringSync();
        expect(html.contains('id="nfSubList"'), isTrue,
            reason: '$root options.html missing the subtitle-list toggle');
        expect(js.contains('netflixSubtitlePanel'), isTrue,
            reason:
                '$root options.js must persist the netflixSubtitlePanel setting');
      });

      test(
          '[$name] options start directly with settings, without promotional hero copy',
          () {
        final String html = File('$root/options.html').readAsStringSync();
        final String css = File('$root/options.css').readAsStringSync();
        expect(html.contains('class="hero"'), isFalse,
            reason: '$root options.html must not render the promotional hero');
        expect(html.contains('让字幕留在观看现场'), isFalse,
            reason: '$root options.html must remove the discarded hero copy');
        expect(css.contains('.hero {'), isFalse,
            reason: '$root options.css must not retain dead hero layout rules');
      });

      test('[$name] options expose user-subtitle playback controls', () {
        final String html = File('$root/options.html').readAsStringSync();
        final String js = File('$root/options.js').readAsStringSync();
        for (final String id in <String>[
          'subtitleOverlayEnabled',
          'subtitleDragDropEnabled',
          'subtitleAutoScroll',
          'subtitleAutoPause',
          'subtitleCondensedPlayback',
        ]) {
          expect(html.contains('id="$id"'), isTrue,
              reason: '$root options.html missing $id');
          expect(js.contains(id), isTrue,
              reason: '$root options.js must persist $id');
        }
        expect(js.contains("type: 'connectionStatus'"), isTrue,
            reason: '$root options.js must display live connection health');
      });

      test('[$name] subtitle-panel accepts and renders user subtitles', () {
        final String src = File('$root/subtitle-panel.js').readAsStringSync();
        expect(src.contains("inp.accept = '.srt,.ass,.ssa,.vtt'"), isTrue,
            reason: '$root subtitle-panel.js missing supported file picker');
        expect(src.contains("document.addEventListener('drop'"), isTrue,
            reason: '$root subtitle-panel.js missing drag-and-drop loading');
        expect(src.contains("'hibiki-subtitle-overlay'"), isTrue,
            reason: '$root subtitle-panel.js missing video subtitle overlay');
        expect(src.contains('st.autoPause'), isTrue,
            reason: '$root subtitle-panel.js missing auto-pause mode');
        expect(src.contains('st.condensedPlayback'), isTrue,
            reason: '$root subtitle-panel.js missing condensed playback mode');
      });

      test('[$name] background diagnoses Hibiki/Yomitan port ownership', () {
        final String src = File('$root/background.js').readAsStringSync();
        final String diagnostic =
            File('$root/connection-diagnostics.js').readAsStringSync();
        expect(src.contains("msg.type === 'connectionStatus'"), isTrue,
            reason: '$root background.js missing connectionStatus handler');
        expect(src.contains("'/api/extension/status'"), isTrue,
            reason: '$root background.js must identify Hibiki explicitly');
        expect(src.contains("'/serverVersion'"), isTrue,
            reason: '$root background.js must probe Yomitan API conflicts');
        expect(diagnostic.contains('yomitan-conflict'), isTrue,
            reason: '$root connection diagnostic missing conflict state');
      });

      // TODO-1219 方案 B：字幕列表面板开关也放进扩展 action-popup（点扩展图标即可开），读写同一
      // chrome.storage.local.netflixSubtitlePanel。守卫两镜像的 popup 里都有这个开关且读写正确。
      test('[$name] action-popup exposes the Netflix subtitle-list toggle', () {
        final String html =
            File('$root/vendor/action-popup.html').readAsStringSync();
        final String js =
            File('$root/vendor/action-popup.js').readAsStringSync();
        expect(html.contains('id="hp-nf-sublist"'), isTrue,
            reason: '$root action-popup.html missing the subtitle-list toggle');
        expect(html.contains('面板在视频播放页侧栏'), isTrue,
            reason: '$root action-popup.html missing the toggle hint text');
        expect(js.contains('hibikiReadPanelEnabled'), isTrue,
            reason:
                '$root action-popup.js must read the panel setting via hibikiReadPanelEnabled');
        expect(js.contains("chrome.storage.local.get(['netflixSubtitlePanel']"),
            isTrue,
            reason:
                '$root action-popup.js must backfill the checkbox from netflixSubtitlePanel');
        expect(
            js.contains(
                'chrome.storage.local.set({ netflixSubtitlePanel: nfToggle.checked })'),
            isTrue,
            reason:
                '$root action-popup.js must persist the toggle to netflixSubtitlePanel');
      });

      // TODO-1219 用户诉求①：整集字幕拦截必须与语言无关——harvest 遍历清单里的**每一条**
      // timedtexttracks（用户选哪种字幕语言都在内），绝不硬编码只处理某种语言（如日语）。
      test(
          '[$name] netflix-bridge harvests every language track (no lang filter)',
          () {
        final String src = File('$root/netflix-bridge.js').readAsStringSync();
        expect(
            src.contains(
                'for (var i = 0; i < tracks.length; i++) fetchCues(videoId, tracks[i]);'),
            isTrue,
            reason:
                '$root netflix-bridge.js must harvest every timedtext track, not one language');
        expect(RegExp("['\"]ja['\"]").hasMatch(src), isFalse,
            reason:
                '$root netflix-bridge.js must not hard-code a Japanese-only language filter');
      });

      // TODO-1219 复诉（勾选要刷新 + 面板空列表）根因守卫：主世界 bridge document_start 抓字幕，
      // 隔离世界 content.js document_idle 才注册接收端——先于接收端 post 的 cue 消息永久丢失。
      // bridge 必须存档已抓 cue 并响应 replayCues 重放；content.js 就绪后必须请求重放。
      test('[$name] bridge archives cues and replays them on request', () {
        final String src = File('$root/netflix-bridge.js').readAsStringSync();
        expect(src.contains('cueArchive'), isTrue,
            reason:
                '$root netflix-bridge.js must archive fetched cue payloads');
        expect(src.contains("d.__hibikiNf === 'replayCues'"), isTrue,
            reason:
                '$root netflix-bridge.js must replay archived cues on replayCues');
      });

      test('[$name] content.js requests a cue replay once its receiver is up',
          () {
        final String src = File('$root/content.js').readAsStringSync();
        final int receiver = src.indexOf("e.data.__hibikiNf !== 'cues'");
        final int replay = src.indexOf("{ __hibikiNf: 'replayCues' }");
        expect(receiver >= 0 && replay > receiver, isTrue,
            reason:
                '$root content.js must post replayCues after registering the '
                'cues receiver (injection-order race, TODO-1219)');
      });

      // BUG-769 根因守卫：跨世界自投消息在 file:// 页 opaque origin 下会炸。opaque origin 序列化成
      // 'null'，但 location.origin 返回 'file://' → 二者不匹配 → postMessage 抛 SyntaxError/静默丢弃，
      // 整条 cue 桥（含 replayCues 握手）在 file:// 下死掉 → 面板 store 空、列表空。正确做法：自投一律
      // 用 targetOrigin '/'（仅同源同窗投递，对不透明源恒成立、不做 URL 解析），接收端比对期望源用
      // window.origin（不透明源返回 'null'，与 e.origin 一致）。两镜像、三文件都锁死防回归。
      test('[$name] cross-world postMessage is file:// opaque-origin safe', () {
        const List<String> selfPostFiles = <String>[
          'netflix-bridge.js',
          'subtitle-panel.js',
          'content.js',
        ];
        final RegExp badTarget =
            RegExp(r'postMessage\([^;]*?,\s*(window\.)?location\.origin\s*\)');
        for (final String rel in selfPostFiles) {
          final String src = File('$root/$rel').readAsStringSync();
          expect(badTarget.hasMatch(src), isFalse,
              reason:
                  '$root $rel must not use location.origin as a postMessage '
                  'targetOrigin (BUG-769: throws on file:// opaque origin — '
                  'use a bare-slash targetOrigin instead)');
        }
        // 接收端期望源改用 window.origin，绝不能退回 window.location.origin（file:// 会错序列化成 'file://'）。
        final String bridge =
            File('$root/netflix-bridge.js').readAsStringSync();
        expect(bridge.contains('var ORIGIN = window.origin;'), isTrue,
            reason: '$root netflix-bridge.js receiver must compare against '
                'window.origin (opaque-origin safe), not location.origin');
        expect(bridge.contains('window.location.origin'), isFalse,
            reason:
                '$root netflix-bridge.js must not read window.location.origin '
                '(BUG-769: mis-serializes opaque file:// origin)');
      });

      // TODO-1363 通用化守卫：面板不再是 Netflix 专属——数据源抽象（provider 全在 content.js，
      // 面板消费同一个 store），面板文件不得再按 hostname 早退。
      test('[$name] subtitle-panel.js is universal (no Netflix hostname gate)',
          () {
        final String src = File('$root/subtitle-panel.js').readAsStringSync();
        expect(src.contains('.test(location.hostname)) return;'), isFalse,
            reason:
                '$root subtitle-panel.js must not early-return on non-Netflix '
                'hosts (TODO-1363 universal panel)');
        expect(src.contains('window.hibikiVideoKey'), isTrue,
            reason: '$root subtitle-panel.js must key tracks via the shared '
                'hibikiVideoKey contract');
        expect(src.contains('v.currentTime = ms / 1000'), isTrue,
            reason: '$root subtitle-panel.js must seek generic sites via '
                'video.currentTime (Netflix keeps the DRM bridge)');
      });

      test('[$name] content.js provides universal subtitle providers', () {
        final String src = File('$root/content.js').readAsStringSync();
        expect(src.contains('function hibikiHarvestTextTracks'), isTrue,
            reason: '$root content.js must harvest HTML5 video.textTracks '
                '(generic full-track provider, TODO-1363)');
        expect(src.contains('HIBIKI_LIVE_LANG'), isTrue,
            reason:
                '$root content.js must promote DOM-sampled cues into a live '
                'track (YouTube/self-drawn captions, TODO-1363)');
        expect(src.contains('window.hibikiVideoKey = hibikiVideoKey'), isTrue,
            reason:
                '$root content.js must expose the shared video-key contract');
      });
    });
  });

  group('extension mirrors stay byte-identical for TODO-1215 files', () {
    for (final String rel in const <String>[
      'vendor/dict-media.js',
      'bridge-shim.js',
      'background.js',
      'connection-diagnostics.js',
      // TODO-1219 P1：Netflix 整集字幕拦截链改动的共享文件，纳入字节守卫防两镜像漂移。
      'netflix-bridge.js',
      'subtitle-adapters.js',
      'content.js',
      'manifest.json',
      // TODO-1219 P2：字幕列表面板新增/改动的共享文件，同样纳入字节守卫。
      'subtitle-panel.js',
      'vendor/content.css',
      // TODO-1219：字幕列表面板默认关开关（options UI）——两镜像同步纳入字节守卫。
      'options.html',
      'options.js',
      'options.css',
      // TODO-1219 方案 B：字幕列表面板开关的第二入口（action-popup）——两镜像同步纳入字节守卫。
      'vendor/action-popup.html',
      'vendor/action-popup.js',
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

  // dict-media.js 是「两 vendor 字节一致 + app 语义一致」的特殊形态：vendor 版在
  // rewriteDictionaryMediaPath / rewriteDictLinks 里有正当的扩展环境分叉
  // （TODO-1215 __hibikiDictMedia → /api/media/dictionary），但 constructDictCss
  // （词典自带 CSS 的作用域化，含 at-rule 处理）不允许分叉——历史上 vendor 副本漏掉了
  // app 版的 at-rule 逻辑，扩展里 @font-face/@keyframes/@media 被错误加前缀。
  // 这里逐字符比对三副本的 constructDictCss 函数全文，之后任何单侧改动必红。
  group('constructDictCss stays semantically identical app <-> vendor', () {
    /// 从 [src] 提取 `function constructDictCss(...) { ... }` 全文。
    /// 花括号配对时跳过注释与字符串字面量（函数体里有 `'{'` / `' {'` / `'}'`
    /// 这类含花括号的字符串，裸计数会失衡）。
    String extractConstructDictCss(String src, String label) {
      const String marker = 'function constructDictCss(';
      final int start = src.indexOf(marker);
      expect(start, greaterThanOrEqualTo(0),
          reason: '$label is missing constructDictCss');
      final int braceStart = src.indexOf('{', start);
      expect(braceStart, greaterThan(start),
          reason: '$label constructDictCss has no body');
      int depth = 0;
      int i = braceStart;
      int end = -1;
      while (i < src.length) {
        final String c = src[i];
        if (c == '/' && i + 1 < src.length && src[i + 1] == '/') {
          // 行注释：跳到行尾（注释里有撇号/反引号，不能当字符串处理）。
          final int nl = src.indexOf('\n', i);
          i = nl == -1 ? src.length : nl + 1;
          continue;
        }
        if (c == '/' && i + 1 < src.length && src[i + 1] == '*') {
          final int close = src.indexOf('*/', i + 2);
          i = close == -1 ? src.length : close + 2;
          continue;
        }
        if (c == "'" || c == '"' || c == '`') {
          // 字符串字面量：跳到同类引号（含转义）。
          i++;
          while (i < src.length && src[i] != c) {
            if (src[i] == r'\') i++;
            i++;
          }
          i++;
          continue;
        }
        if (c == '{') {
          depth++;
        } else if (c == '}') {
          depth--;
          if (depth == 0) {
            end = i;
            break;
          }
        }
        i++;
      }
      expect(end, greaterThan(braceStart),
          reason: '$label constructDictCss braces never close — extraction '
              'heuristic broke; update this guard alongside the function.');
      return src.substring(start, end + 1);
    }

    test('app assets/popup vs both extension vendor mirrors', () {
      final String app = extractConstructDictCss(
          File('assets/popup/dict-media.js').readAsStringSync(),
          'assets/popup/dict-media.js');
      for (final MapEntry<String, String> mirror in mirrors.entries) {
        final String vendor = extractConstructDictCss(
            File('${mirror.value}/vendor/dict-media.js').readAsStringSync(),
            '${mirror.value}/vendor/dict-media.js');
        expect(vendor, app,
            reason: '[${mirror.key}] vendor/dict-media.js constructDictCss '
                'drifted from assets/popup/dict-media.js — the scoping/at-rule '
                'logic must stay identical across app and extension (only the '
                'TODO-1215 media-URL rewrite outside this function may fork).');
      }
    });
  });
}
