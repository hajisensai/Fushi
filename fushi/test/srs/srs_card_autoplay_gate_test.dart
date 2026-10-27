// BUG-3546：牌组关了自动播放时，卡面页面自己发起的媒体播放（视频制卡的同步片段
// `oncanplay` → `play()`、`autoplay` 属性）也必须停下，只放行用户在卡面上的点按 / 按键。
//
// - 外壳脚本 [kSrsCardAutoplayGateScript] 在 node 里真的执行（最小 DOM 桩，跑的是生产常量本身）；
// - 生产外壳在真实 headless Chrome（`--autoplay-policy=no-user-gesture-required`，即卡面在
//   Windows / WebView2 上的实际策略）里跑：页面让媒体出声的每条路都被拦、用户点按照常出声；
// - [SrsCardFaceSync] 把牌组开关随换卡下发（开关先于换卡），只改开关也会重放当前这一面。
//
// node / Chrome：本地缺时 skip 并写明原因，CI 上缺一律失败（见 test/helpers/node_runtime.dart）。
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/pages/implementations/srs/srs_card_face.dart';
import 'package:fushi/src/srs/srs_card_autoplay.dart';
import 'package:material_ui/material_ui.dart';

import '../helpers/node_runtime.dart';

void main() {
  final NodeTestRuntime nodeRuntime = NodeTestRuntime.probe();
  final NodeTestRuntime browserRuntime = NodeTestRuntime.probe(
    needsChrome: true,
  );

  group('自动播放闸门脚本（node）', skip: nodeRuntime.skipReason, () {
    /// 最小 DOM 桩：window 捕获监听、HTMLMediaElement 原型、MutationObserver 回调。
    /// `fire(type, trusted, handler)` 模拟一次事件派发：先跑 window 捕获监听，再在
    /// 同一次派发里跑目标上的处理函数（内联 onclick 等）。
    String harness(String body) =>
        '''
const assert = require('node:assert/strict');
globalThis.window = globalThis;
const log = [];
const captureListeners = {};
window.addEventListener = function(type, fn, capture){
  assert.equal(capture, true, '闸门在捕获阶段监听');
  (captureListeners[type] = captureListeners[type] || []).push(fn);
};
function fire(type, trusted, handler){
  const e = { type, isTrusted: trusted };
  (captureListeners[type] || []).forEach(f => f(e));
  if (handler) handler(e);
}
const tick = () => new Promise(r => setTimeout(r, 0));
class HTMLMediaElement {
  constructor(tag){ this.tagName = tag; this.nodeType = 1; this.attrs = {}; this.kids = []; this.autoplay = false; }
  hasAttribute(n){ return Object.prototype.hasOwnProperty.call(this.attrs, n); }
  setAttribute(n, v){ this.attrs[n] = String(v); if (n === 'autoplay') this.autoplay = true; }
  removeAttribute(n){ delete this.attrs[n]; }
  querySelectorAll(){ return []; }
  play(){ log.push('native:' + this.tagName); return Promise.resolve('played'); }
}
window.HTMLMediaElement = HTMLMediaElement;
function media(tag, autoplay){
  const m = new HTMLMediaElement(tag);
  if (autoplay) m.setAttribute('autoplay', '');
  return m;
}
function container(children){
  return {
    nodeType: 1, tagName: 'DIV',
    hasAttribute(){ return false; },
    querySelectorAll(sel){
      assert.equal(sel, 'audio[autoplay],video[autoplay]');
      return children.filter(c => c.hasAttribute('autoplay'));
    },
  };
}
let observerCallback = null;
window.MutationObserver = class {
  constructor(cb){ observerCallback = cb; }
  observe(target, opts){ assert.ok(opts.childList && opts.subtree, '观察整棵子树'); }
};
const existing = [media('VIDEO', true)];
globalThis.document = { documentElement: {}, body: container(existing) };
async function outcome(el){
  try { await el.play(); return 'played'; }
  catch (e) { return e.name; }
}
$kSrsCardAutoplayGateScript
(async () => {
$body
})().catch(e => { console.error(e); process.exit(1); });
''';

    Future<void> runJs(String code) async {
      final Directory dir = Directory.systemTemp.createTempSync('srs-gate-');
      try {
        final File script = File('${dir.path}/verify.js')
          ..writeAsStringSync(code);
        final ProcessResult result = await Process.run(
          nodeRuntime.requireNode(),
          <String>[script.path],
          stdoutEncoding: utf8,
          stderrEncoding: utf8,
        );
        expect(
          result.exitCode,
          0,
          reason: '${result.stdout}\n${result.stderr}',
        );
      } finally {
        dir.deleteSync(recursive: true);
      }
    }

    test('缺省（开）：页面自己 play() 照常放行', () async {
      await runJs(
        harness(r'''
const v = media('VIDEO');
assert.equal(await outcome(v), 'played');
assert.deepEqual(log, ['native:VIDEO']);
'''),
      );
    });

    test(
      '关：canplay / ended / 定时器里的 play() 以 NotAllowedError 拒绝，不碰原生播放',
      () async {
        await runJs(
          harness(r'''
window.__fushiSrsSetAutoplay(false);
const v = media('VIDEO');
// 同步片段的 oncanplay：不是用户输入事件。
let got = null;
fire('canplay', true, () => { got = outcome(v); });
assert.equal(await got, 'NotAllowedError');
assert.equal(await outcome(media('AUDIO')), 'NotAllowedError');
assert.deepEqual(log, [], '原生 play 一次都没调');
'''),
        );
      },
    );

    test('关：用户点按同一次派发里的播放放行（含脚本转手的合成 click），派发结束后复位', () async {
      await runJs(
        harness(r'''
window.__fushiSrsSetAutoplay(false);
const v = media('VIDEO');
let direct = null, nested = null;
fire('click', true, () => {
  direct = outcome(v);
  // Lapis「点例句重播」：可信点按里再 replay.click()（合成、不可信）。
  fire('click', false, () => { nested = outcome(v); });
});
assert.equal(await direct, 'played');
assert.equal(await nested, 'played');
await tick();
await tick();
assert.equal(await outcome(v), 'NotAllowedError', '点按派发结束后不再算手势');
// 不可信（脚本 dispatch）的点按不算手势。
let fake = null;
fire('click', false, () => { fake = outcome(v); });
assert.equal(await fake, 'NotAllowedError');
// 键盘也算用户输入。
let key = null;
fire('keydown', true, () => { key = outcome(v); });
assert.equal(await key, 'played');
'''),
      );
    });

    test('关：摘掉现有与新插入媒体的 autoplay 属性；开着时不动', () async {
      await runJs(
        harness(r'''
// 开着：新插入的 autoplay 保留。
const keep = media('AUDIO', true);
observerCallback([{ addedNodes: [keep] }]);
assert.equal(keep.hasAttribute('autoplay'), true);
// 关的那一刻扫现有内容。
window.__fushiSrsSetAutoplay(false);
assert.equal(existing[0].hasAttribute('autoplay'), false);
assert.equal(existing[0].autoplay, false);
// 之后插入的（换卡 innerHTML / 卡片脚本动态插入）：元素本身与子树里的都摘。
const direct = media('VIDEO', true);
const inner = media('AUDIO', true);
observerCallback([{ addedNodes: [direct, container([inner, media('AUDIO')])] }]);
assert.equal(direct.hasAttribute('autoplay'), false);
assert.equal(inner.hasAttribute('autoplay'), false);
// 再打开：放行页面播放。
window.__fushiSrsSetAutoplay(true);
assert.equal(await outcome(media('VIDEO')), 'played');
'''),
      );
    });

    test('脚本重复注入（外壳重放）不重复包装 play', () async {
      await runJs(
        harness('''
(0, eval)(${jsonEncode(kSrsCardAutoplayGateScript)});
window.__fushiSrsSetAutoplay(false);
let got = null;
fire('click', true, () => { got = media('VIDEO').play(); });
assert.equal(await got, 'played');
assert.deepEqual(log, ['native:VIDEO'], '只包一层');
'''),
      );
    });
  });

  group('SrsCardFaceSync 下发自动播放开关', () {
    SrsCardFaceDocument doc({
      required bool autoplay,
      String body = '<b>Q</b>',
    }) => SrsCardFaceDocument.of(
      SrsCardFace(
        cardId: 'c1',
        showingAnswer: false,
        bodyHtml: body,
        css: '.card{}',
        languageCode: 'ja',
        onBridgeKey: (_) {},
        autoplayMedia: autoplay,
      ),
      dark: false,
      background: const Color(0xFFFFFFFF),
      foreground: const Color(0xFF000000),
      accent: const Color(0xFF6750A4),
      onAccent: const Color(0xFFFFFFFF),
      mediaUrlPrefix: 'https://srs.local/media/',
      themedScrollbar: true,
    );

    test('开关先于换卡下发；只改开关也重放当前这一面；不变不重发', () async {
      final List<String> evaluated = <String>[];
      final SrsCardFaceSync sync = SrsCardFaceSync(
        evaluate: (String source) async {
          evaluated.add(source);
          return true;
        },
        reloadShell: () {},
      );
      sync.shellLoaded();
      sync.update(doc(autoplay: false));
      await Future<void>.delayed(Duration.zero);
      expect(evaluated, hasLength(1));
      final String first = evaluated.single;
      final int gate = first.indexOf(srsCardSetAutoplayScript(autoplay: false));
      expect(gate, greaterThanOrEqualTo(0));
      expect(gate, lessThan(first.indexOf('__fushiSrsSetCard(')));

      // 复习中在牌组设置里打开了自动播放：同一面按新开关重放。
      sync.update(doc(autoplay: true));
      await Future<void>.delayed(Duration.zero);
      expect(evaluated, hasLength(2));
      expect(
        evaluated.last,
        contains(srsCardSetAutoplayScript(autoplay: true)),
      );
      expect(evaluated.last, contains('__fushiSrsSetCard('));

      sync.update(doc(autoplay: true));
      await Future<void>.delayed(Duration.zero);
      expect(evaluated, hasLength(2), reason: '内容与开关都没变不下发');
    });

    test('外壳里闸门脚本排在卡片换内容脚本之前；整份重放也带开关', () {
      final SrsCardFaceDocument d = doc(autoplay: false);
      final String shell = d.shellHtml;
      final int gate = shell.indexOf(kSrsCardAutoplayGateScript);
      expect(gate, greaterThanOrEqualTo(0));
      expect(gate, lessThan(shell.indexOf(kSrsCardShellScript)));
      final String full = d.fullCardScript;
      final int at = full.indexOf(srsCardSetAutoplayScript(autoplay: false));
      expect(at, greaterThanOrEqualTo(0));
      expect(at, lessThan(full.indexOf('__fushiSrsSetCard(')));
    });

    test(
      '真实 Chrome（不要手势即可自动播放）：关时页面出声的每条路都被拦，用户点按照常出声',
      skip: browserRuntime.skipReason,
      () async {
        final String node = browserRuntime.requireNode();
        final Directory temp = Directory.systemTemp.createTempSync(
          'srs-autoplay-',
        );
        try {
          final File payload = File('${temp.path}/payload.json')
            ..writeAsStringSync(
              jsonEncode(<String, String>{
                // 生产外壳（闸门在卡片脚本之前装好）+ 生产的换卡调用（开关先于换卡）。
                'shell': doc(autoplay: false).shellHtml,
                'off': doc(autoplay: false).fullCardScript,
                'on': doc(autoplay: true).fullCardScript,
                // 下一张卡（换卡停掉上一张页内所有在响的媒体，N-JACNGS-K）。
                'next': doc(autoplay: true, body: '<b>Next</b>').fullCardScript,
              }),
            );
          final ProcessResult result = await Process.run(
            node,
            <String>[
              'test/srs/srs_card_autoplay_gate_harness.mjs',
              payload.path,
            ],
            stdoutEncoding: utf8,
            stderrEncoding: utf8,
          ).timeout(const Duration(seconds: 80));
          expect(
            result.exitCode,
            0,
            reason: '${result.stdout}\n${result.stderr}',
          );
          expect(result.stdout, contains('PASS 28 browser checks'));
        } finally {
          temp.deleteSync(recursive: true);
        }
      },
      timeout: const Timeout(Duration(seconds: 90)),
    );
  });
}
