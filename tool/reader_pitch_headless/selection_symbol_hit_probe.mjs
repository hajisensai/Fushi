// BUG-4181 probe: where does a tap on a non-lookup symbol (arrow / gaiji
// <img> / svg / pseudo-element / rt) inside a vertical-rl column land in the
// production hit-test chain?
//
// Runs the production `window.fushiSelection` (verbatim from
// fushi/lib/src/reader/reader_selection_scripts.dart `source()`) in headless
// Chrome via cdp_client.mjs, taps the centre of the element marked id="t" and
// prints, per variant: native caretPositionFromPoint / caretRangeFromPoint,
// getCaretRange, getSelectableCharacterAtPoint, the selection start character
// after selectText(), the lookup text and which bridge handlers fired.
//
// Usage:
//   node tool/reader_pitch_headless/selection_symbol_hit_probe.mjs
// MC=1 lays the body out as multicol (paginated-like). To check a real book,
// paste the paragraph markup from its XHTML into `variants` below with the
// tapped symbol marked id="t" (the probe takes no path arguments on purpose).
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { launchChromeDriver } from './cdp_client.mjs';

const here = path.dirname(fileURLToPath(import.meta.url));
const dart = fs.readFileSync(
  path.resolve(here, '../../fushi/lib/src/reader/reader_selection_scripts.dart'), 'utf8');
const marker = 'static String source() => r"""';
const bodyStart = dart.indexOf(marker) + marker.length;
const selectionJs = dart.substring(bodyStart, dart.indexOf('""";', bodyStart));

const FILLER = '彼女はそう言って、こちらを見た。';
const IMG_ATTRS = ' style="width:1em;height:1em;vertical-align:middle" src="data:image/svg+xml;utf8,' +
  encodeURIComponent('<svg xmlns="http://www.w3.org/2000/svg" width="20" height="20">' +
    '<path d="M10 2v14M4 10l6 6 6-6" stroke="black" fill="none"/></svg>') + '">';

const variants = {
  charOwnElement: '<p>顔の上が<b id="t">↓</b>で、' + FILLER + '</p>',
  gaijiImg: '<p>顔の上が<img id="t" class="gaiji"' + IMG_ATTRS + 'で、' + FILLER + '</p>',
  gaijiImgInSpan: '<p>顔の上が<span class="gaiji"><img id="t"' + IMG_ATTRS + '</span>で、' + FILLER + '</p>',
  textCombine: '<p>顔の上が<span id="t" style="text-combine-upright:all">↓</span>で、' + FILLER + '</p>',
  upright: '<p>顔の上が<span id="t" style="text-orientation:upright">↓</span>で、' + FILLER + '</p>',
  inlineBlock: '<p>顔の上が<span id="t" style="display:inline-block">↓</span>で、' + FILLER + '</p>',
  rubyArrowBase: '<p>顔の上が<ruby id="t">↓<rt>した</rt></ruby>で、' + FILLER + '</p>',
  rtArrow: '<p>顔の<ruby>上<rt id="t">↓</rt></ruby>がで、' + FILLER + '</p>',
  imgInRuby: '<p>顔の上が<ruby><img id="t"' + IMG_ATTRS + '<rt>した</rt></ruby>で、' + FILLER + '</p>',
  inlineSvg: '<p>顔の上が<svg id="t" width="20" height="20" style="vertical-align:middle">' +
    '<path d="M10 2v14" stroke="black"/></svg>で、' + FILLER + '</p>',
  pseudoContent: '<p>顔の上が<span id="t" class="pseudo-arrow"></span>で、' + FILLER + '</p>',
  // The one shape found that does reach the column start: a symbol classified
  // as Japanese (U+FFEC is inside FULLWIDTH_CHARACTER_RANGES) inside a ruby
  // base that starts with 顔 -- selectionStartFor snaps to the ruby segment
  // start by design (chj2rZn89F).
  halfwidthArrowInRubyBase: '<p><ruby>顔の上が<b id="t">￬</b>で<rt>ルビ</rt></ruby>、' + FILLER + '</p>',
};

const css = 'html,body{margin:0;height:400px}' +
  'body{writing-mode:vertical-rl;font:20px/1.8 serif;padding:20px;height:360px;box-sizing:border-box;' +
  (process.env.MC ? 'columns:auto 300px;column-gap:40px;overflow:hidden;' : '') + '}' +
  'p{margin:0}.pseudo-arrow::before{content:"↓"}';

const describe = `function describe(node, offset) {
  if (!node) return null;
  const ch = node.nodeType === 3 ? node.data.slice(offset, offset + 1) : '';
  return node.nodeName + ':' + offset + (ch ? ':' + ch : '');
}`;

const driver = await launchChromeDriver();
try {
  for (const [name, body] of Object.entries(variants)) {
    const html = '<!doctype html><html><head><meta charset="utf-8"><style>' + css +
      '</style></head><body>' + body + '</body></html>';
    const result = await driver.evalOnPage(html, `(() => {
      ${describe}
      const calls = [];
      window.flutter_inappwebview = { callHandler: (...args) => { calls.push(args); } };
      (0, eval)(${JSON.stringify(selectionJs)});
      const target = document.getElementById('t');
      if (!target) return { error: 'no element with id="t"' };
      const rect = target.getBoundingClientRect();
      const x = rect.left + rect.width / 2;
      const y = rect.top + rect.height / 2;
      const S = window.fushiSelection;
      const cp = document.caretPositionFromPoint ? document.caretPositionFromPoint(x, y) : null;
      const cr = document.caretRangeFromPoint ? document.caretRangeFromPoint(x, y) : null;
      const gc = S.getCaretRange(x, y);
      const hit = S.getSelectableCharacterAtPoint(x, y);
      S.clearSelection();
      calls.length = 0;
      S.selectText(x, y, 40, false);
      const st = S.selection;
      const selected = calls.find((c) => c[0] === 'onTextSelected');
      return {
        point: [Math.round(x), Math.round(y)],
        caretPosition: cp && describe(cp.offsetNode, cp.offset),
        caretRange: cr && describe(cr.startContainer, cr.startOffset),
        getCaretRange: gc && describe(gc.startContainer, gc.startOffset),
        hit: hit && describe(hit.node, hit.offset),
        selectionStart: st ? st.startNode.data.slice(st.startOffset, st.startOffset + 1) : null,
        lookupText: selected ? JSON.parse(selected[1]).text : null,
        handlers: calls.map((c) => c[0]).join(','),
      };
    })()`);
    console.log(name.padEnd(26) + JSON.stringify(result));
  }
} finally {
  driver.close();
}
