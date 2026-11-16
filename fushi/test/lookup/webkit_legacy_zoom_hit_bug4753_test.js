// BUG-4753（反馈 lfbYCEfnt7）：macOS 查词页展开明鏡释义，点「昼」查到「間」、点「訪」查到
// 「問」——嵌套查词的起点与点的字差一个。
//
// 根因：弹窗把「界面大小 × 词典字号」写成 documentElement.style.zoom。旧 WebKit（2025-10
// 之前没开 GetBoundingClientRectZoomedEnabled 的 WKWebView）里 Range.getClientRects 按节点
// 的有效 CSS zoom 除过一遍（rect = (client + scroll) / zoom − scroll），而事件 clientX/Y 与
// caretPositionFromPoint 仍是客户区坐标；selection.js 拿客户区的点直接比字框，选中的是
// 字框「缩过之后」盖住这个点的邻字，或者落空。
//
// 这里在 fake DOM 里真执行 assets/popup/selection.js，按两种引擎的规则产出字框：
//   - legacy：探针 zoom:2 与 zoom:1 量出同宽，字框按上式缩；
//   - standard：探针量出 2 倍宽，字框就是客户区坐标（Blink / 新 WebKit / Firefox）。
// 断言两种引擎下点每个字（含字的右半边、页面滚动后）都命中那个字本身；交给宿主的字框
// （getSelectionRect / highlightSelection）与 clientRectOf 给的元素框都回到客户区坐标。
//
// 运行：node fushi/test/lookup/webkit_legacy_zoom_hit_bug4753_test.js

const assert = require('node:assert');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const src = fs.readFileSync(path.join(__dirname, '../../assets/popup/selection.js'), 'utf8');

const CHAR_W = 20;
const LINE_TOP = 120;
const LINE_H = 24;
const LEFT = 40;

function load({ engine, zoom, scrollX, scrollY }) {
  const textNode = { nodeType: 3, textContent: '［感］昼間、人に会ったり訪問したりするときのあいさつの語。', parentElement: null };
  const elements = [];
  function element(tagName, className, styleZoom) {
    const node = {
      nodeType: 1,
      tagName: tagName.toUpperCase(),
      className: className || '',
      parentElement: null,
      childNodes: [],
      shadowRoot: null,
      styleZoom: styleZoom || '1',
      style: { cssText: '' },
      setAttribute() {},
      appendChild(child) { child.parentElement = node; node.childNodes.push(child); return child; },
      removeChild(child) {
        node.childNodes = node.childNodes.filter((c) => c !== child);
        child.parentElement = null;
        return child;
      },
      closest(selector) {
        const parts = selector.split(',').map((s) => s.trim());
        for (let cur = node; cur && cur.nodeType === 1; cur = cur.parentElement) {
          if (parts.some((p) => (p.startsWith('.')
            ? cur.className.split(/\s+/).includes(p.slice(1))
            : cur.tagName.toLowerCase() === p.toLowerCase()))) return cur;
        }
        return null;
      },
      getRootNode() { return documentStub; },
      // clientBox：元素在客户区里的框，按引擎规则报出；没有 clientBox 的是 clientRectsZoomed
      // 的探针：宽 100px，按引擎规则缩放。
      getBoundingClientRect() {
        if (node.clientBox) return reportedRect(node.clientBox);
        const m = /zoom:([\d.]+)/.exec(node.style.cssText);
        const own = m ? parseFloat(m[1]) : 1;
        const width = engine === 'legacy' ? 100 : 100 * own * zoom;
        return { left: 0, top: 0, right: width, bottom: 1, width, height: 1 };
      },
    };
    elements.push(node);
    return node;
  }
  const html = element('html', '', String(zoom));
  const body = element('body');
  const glossary = element('div', 'glossary-content');
  html.appendChild(body);
  body.appendChild(glossary);
  glossary.appendChild(textNode);
  textNode.parentElement = glossary;

  // 第 i 个字在客户区里占 [LEFT + i*W, LEFT + (i+1)*W] × [LINE_TOP, LINE_TOP + LINE_H]。
  function clientCharRect(i) {
    return { left: LEFT + i * CHAR_W, right: LEFT + (i + 1) * CHAR_W, top: LINE_TOP, bottom: LINE_TOP + LINE_H };
  }
  // 引擎从 Range 报出来的字框。
  function reportedCharRect(i) {
    return reportedRect(clientCharRect(i));
  }
  function reportedRect(c) {
    if (engine !== 'legacy') return { ...c, x: c.left, y: c.top, width: c.right - c.left, height: c.bottom - c.top };
    const fx = (v) => (v + scrollX) / zoom - scrollX;
    const fy = (v) => (v + scrollY) / zoom - scrollY;
    const r = { left: fx(c.left), right: fx(c.right), top: fy(c.top), bottom: fy(c.bottom) };
    return { ...r, x: r.left, y: r.top, width: r.right - r.left, height: r.bottom - r.top };
  }

  const documentStub = {
    body,
    documentElement: html,
    createElement: (tag) => element(tag),
    createRange() {
      return {
        setStart(node, offset) { this.startContainer = node; this.startOffset = offset; },
        // 测试只量单字 Range（getSelectionRect）或 1 字的高亮段，按起点取字框即可。
        setEnd(node, offset) { this.endContainer = node; this.endOffset = offset; },
        collapse() {},
        getClientRects() { return this.startContainer === textNode ? [reportedCharRect(this.startOffset)] : []; },
        getBoundingClientRect() { return reportedCharRect(this.startOffset); },
      };
    },
    // caret API 用客户区坐标，给离点最近的字间缝（点在字的右半边 → 下一个字的偏移）。
    caretPositionFromPoint(x, y) {
      if (y < LINE_TOP || y > LINE_TOP + LINE_H) return null;
      const offset = Math.max(0, Math.min(textNode.textContent.length, Math.round((x - LEFT) / CHAR_W)));
      return { offsetNode: textNode, offset };
    },
    elementFromPoint: () => glossary,
    createTreeWalker() { return { currentNode: null, nextNode: () => null, previousNode: () => null }; },
  };
  const window = {
    scrollX,
    scrollY,
    getComputedStyle: (el) => ({ display: 'inline', content: 'none', zoom: el.styleZoom }),
    getSelection: () => ({ removeAllRanges() {} }),
    flutter_inappwebview: { callHandler() {} },
  };
  // CSS Custom Highlight 可用：highlightSelection 只登记高亮、不动 DOM。
  class Highlight { constructor(...ranges) { this.ranges = ranges; } }
  const css = { highlights: { set() {} } };
  window.CSS = css;
  window.Highlight = Highlight;
  const sandbox = {
    window,
    document: documentStub,
    Node: { ELEMENT_NODE: 1, TEXT_NODE: 3 },
    NodeFilter: { SHOW_TEXT: 4, FILTER_ACCEPT: 1, FILTER_REJECT: 2 },
    CSS: css,
    Highlight,
    Map,
    console,
  };
  sandbox.globalThis = sandbox;
  vm.createContext(sandbox);
  vm.runInContext(src, sandbox);  // NOSONAR: harness 在本地 Node 沙箱里执行仓库自身的取词脚本（固定路径读入），无用户可控数据
  return { sel: sandbox.window.fushiSelection, textNode, clientCharRect, html, glossary };
}

const cases = [];
for (const engine of ['legacy', 'standard']) {
  for (const zoom of [1, 1.25, 0.8, 1.5]) {
    for (const [scrollX, scrollY] of [[0, 0], [0, 180]]) cases.push({ engine, zoom, scrollX, scrollY });
  }
}

function assertClientRect(actual, expected, label) {
  assert.ok(actual, `${label} must return a rect`);
  const near = (a, b) => Math.abs(a - b) < 1e-6;
  const ok = near(actual.x, expected.left) && near(actual.y, expected.top) &&
    near(actual.width, expected.right - expected.left) && near(actual.height, expected.bottom - expected.top);
  assert.ok(ok, `${label}: got ${JSON.stringify(actual)}, want client ${JSON.stringify(expected)}`);
}

let checked = 0;
const detected = [];
for (const c of cases) {
  const { sel, textNode, clientCharRect, html, glossary } = load(c);
  const text = textNode.textContent;
  for (const target of ['昼', '間', '訪', '問', 'り', '語']) {
    const i = text.indexOf(target);
    const r = clientCharRect(i);
    const y = (r.top + r.bottom) / 2;
    // 字的左四分之一、正中、右四分之一（右半边是 caret 落到下一个字的那一侧）。
    for (const x of [r.left + CHAR_W * 0.25, (r.left + r.right) / 2, r.right - CHAR_W * 0.25]) {
      const hit = sel.getCharacterAtPoint(x, y);
      const label = `${c.engine} zoom=${c.zoom} scroll=${c.scrollY}: click ${target} at x=${x}`;
      assert.ok(hit, `${label} must hit a character`);
      assert.strictEqual(hit.node, textNode, label);
      assert.strictEqual(text[hit.offset], target, `${label} hit ${text[hit.offset]}`);
      checked++;

      // 交给宿主锚嵌套弹窗的字框必须是客户区坐标（宿主拿它和 WebView 视口比）。
      sel.selection = { ranges: [{ node: textNode, start: hit.offset, end: hit.offset + 1 }] };
      assertClientRect(sel.getSelectionRect(x, y), r, `${label} getSelectionRect`);
      assertClientRect(sel.highlightSelection(1), r, `${label} highlightSelection`);
    }
  }
  // 弹窗里按视口定位的浮层 / 上报给宿主的元素框（popup.js __fushiClientRect）。
  const box = { left: LEFT, top: LINE_TOP, right: LEFT + 600, bottom: LINE_TOP + LINE_H };
  glossary.clientBox = box;
  assertClientRect(sel.clientRectOf(glossary), box, `${c.engine} zoom=${c.zoom} clientRectOf`);
  delete glossary.clientBox;
  // 探针量完必须摘干净，不在宿主文档里留节点。
  assert.strictEqual(html.childNodes.length, 1, 'zoom probes must be removed after measuring');
  detected.push([c.engine, sel.rectsZoomed]);
}

// 探针只量一次：引擎类型缓存住，且判对。
for (const [engine, rectsZoomed] of detected) {
  assert.strictEqual(rectsZoomed, engine !== 'legacy', `${engine} engine detected`);
}

console.log(`all assertions passed (${checked} clicks)`);
