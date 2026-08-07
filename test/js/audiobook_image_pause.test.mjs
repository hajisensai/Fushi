// 有声书图片暂停 / 去遮罩「锚点间插图检测」行为测试（jsdom 真实 DOM）。
//
// 为什么需要行为测试：fushi/test/media/audiobook/image_pause_detection_test.dart
// 是纯源码字符串扫描（断言 bridge 里出现 compareDocumentPosition / querySelectorAll
// 等字符串），只能防「检测机制被整体替换/删除」，无法执行判据、测不出 BUG-724 这类
// compareDocumentPosition 位语义逻辑 bug（当前句 cue 锚点是包含插图的容器时，关系是
// CONTAINED_BY 而非 PRECEDING，旧判据漏检 → 既不暂停也不去遮罩）。此测试从真实 bridge
// 提取 __fushiImageBetween / __fushiRevealBlurredBetween，在真实 DOM 上执行判据。
import { test } from "node:test";
import assert from "node:assert/strict";
import { JSDOM } from "jsdom";
import { readFileSync } from "node:fs";

// 相对本测试文件读当前分支的真实 bridge（test/js/ → 仓库根 → hibiki/...）。
const BRIDGE_URL = new URL(
  "../../fushi/lib/src/media/audiobook/audiobook_bridge.dart",
  import.meta.url,
);
const src = readFileSync(BRIDGE_URL, "utf8");

/** 从 bridge 源码提取指定 window.<name> = function(...){...}; 的完整赋值语句 */
function extract(name) {
  const re = new RegExp(
    "window\\." + name + "\\s*=\\s*function\\s*\\([^)]*\\)\\s*\\{[\\s\\S]*?\\n\\};",
  );
  const m = src.match(re);
  assert.ok(m, `未能从 audiobook_bridge.dart 提取 ${name}`);
  return m[0];
}

const imageBetweenSrc = extract("__fushiImageBetween");
const revealBlurredSrc = extract("__fushiRevealBlurredBetween");

/** 在 jsdom 页面内注入真实函数并执行 runner，返回 body[data-result] 字符串 */
function runInDom(bodyHtml, injectedFns, runner) {
  const script = `
    ${injectedFns}
    (function(){ ${runner} })();
  `;
  const html = `<!DOCTYPE html><body>${bodyHtml}<script>${script}<\/script></body>`;
  const dom = new JSDOM(html, { runScripts: "dangerously" });
  return dom.window.document.body.getAttribute("data-result");
}

/** 检测（暂停）：__fushiImageBetween 是否命中页面里唯一的 img */
function detects(bodyHtml) {
  const out = runInDom(bodyHtml, imageBetweenSrc, `
    var prev = document.getElementById('cueA');
    var el = document.getElementById('cueB');
    var hit = window.__fushiImageBetween(prev, el);
    var target = document.querySelector('img');
    document.body.setAttribute('data-result', String(hit === target && target !== null));
  `);
  return out === "true";
}

/** 去遮罩：__fushiRevealBlurredBetween 是否把 img.blurred 的 blurred 类去掉 */
function reveals(bodyHtml) {
  // __fushiRevealBlurredBetween 早返回若 __fushiImageRevealKey 不是函数（bridge:85），
  // 并用 key 决定是否揭开；这里提供返回稳定 key 的 stub + no-op 标记函数。
  const stubs = `
    window.__fushiImageRevealKey = function(m){ return (m && m.getAttribute && m.getAttribute('src')) || 'key'; };
    window.__fushiMarkImageRevealed = function(){};
  `;
  const out = runInDom(bodyHtml, stubs + revealBlurredSrc, `
    var prev = document.getElementById('cueA');
    var el = document.getElementById('cueB');
    window.__fushiRevealBlurredBetween(prev, el);
    var target = document.querySelector('img');
    document.body.setAttribute('data-result', String(target !== null && !target.classList.contains('blurred')));
  `);
  return out === "true";
}

// 四种排版：img 是否应被判为「上一句 cueA → 当前句 cueB 之间已跨过」
const SCENARIOS = [
  {
    name: "标准排版：img 是两句锚点的兄弟",
    html: `<p id="cueA">句A</p><img class="block-img blurred" src="x.jpg"><p id="cueB">句B</p>`,
    expected: true,
  },
  {
    name: "当前句锚点是包含插图的容器（BUG-724 根因场景）",
    html: `<p id="cueA">句A</p><div id="cueB"><img class="block-img blurred" src="x.jpg"><span>句B文本</span></div>`,
    expected: true,
  },
  {
    name: "上一句锚点是包含插图的容器",
    html: `<div id="cueA"><span>句A文本</span><img class="block-img blurred" src="x.jpg"></div><p id="cueB">句B</p>`,
    expected: true,
  },
  {
    name: "图在区间外（上一句之前）——不应误检测/误揭",
    html: `<img class="block-img blurred" src="x.jpg"><p id="cueA">句A</p><p id="cueB">句B</p>`,
    expected: false,
  },
];

for (const s of SCENARIOS) {
  test(`检测(暂停)：${s.name}`, () => {
    assert.equal(detects(s.html), s.expected);
  });
  test(`去遮罩：${s.name}`, () => {
    assert.equal(reveals(s.html), s.expected);
  });
}

// BUG-891：纯图片章（无 cue 锚点，走 awaitImageChapterPause 停留）用 __fushiRevealAllBlurred
// 揭整章 —— 区间函数 __fushiRevealBlurredBetween 需要 prev→el 两个 cue，纯图片章走不到，
// 音频会停在模糊图上。本用例验证：无任何 cue 段落也能揭开全部 blurred 图，且 gaiji 跳过。
const revealAllSrc = extract("__fushiRevealAllBlurred");

function revealsAll(bodyHtml) {
  const stubs = `
    window.__fushiImageRevealKey = function(m){ return (m && m.getAttribute && m.getAttribute('src')) || 'key'; };
    window.__fushiMarkImageRevealed = function(){};
  `;
  return runInDom(bodyHtml, stubs + revealAllSrc, `
    var n = window.__fushiRevealAllBlurred();
    var blurredLeft = document.querySelectorAll('.blurred').length;
    document.body.setAttribute('data-result', n + '|' + blurredLeft);
  `);
}

test("揭整章(纯图片章)：无 cue 锚点也揭开所有 blurred 图，跳过 gaiji", () => {
  // 纯图片章：两张 blurred 图 + 一个 gaiji（应被 continue 跳过、保持 blurred）。
  const html =
    `<img class="block-img blurred" src="a.jpg">` +
    `<img class="block-img blurred" src="b.jpg">` +
    `<svg class="gaiji blurred"><image href="g.svg"></image></svg>`;
  // revealed=2（a,b；gaiji 不计数），剩 1 个 blurred（gaiji 仍模糊）。
  assert.equal(revealsAll(html), "2|1");
});

test("揭整章：无 blurred 图时安全返回 0", () => {
  assert.equal(revealsAll(`<p>纯文字，无图</p>`), "0|0");
});

// BUG-891 真正根因（诉求1/2「章节正文里的图，音频经过既不暂停也不揭遮罩，被直接无视」）：
// __fushiSasayakiAnchorEl 原为 `if(cueRangesMap){...} else if(cueWrappers){...}`。现代
// WebView __fushiCssHighlightsSupported 恒 true，而 cueRangesMap 从不被填充（applySasayakiCues
// 只 set cueWrappers）→ 第一分支恒进入、找不到 range、return null，cueWrappers 兜底被 else
// 永久跳过 → anchor 恒 null → __fushiImagePauseAdvance 永不调用 → 整条图片暂停+揭遮罩失效。
// 修法：cueRangesMap 未命中就无条件兜底 cueWrappers。本用例锁死这个兜底。
const anchorElSrc = extract("__fushiSentenceAudioAnchorEl");

function resolveAnchorId(cssHighlights, rangeMapEntries) {
  const setup = `
    window.__fushiCssHighlightsSupported = ${cssHighlights};
    window.fushiReader = {
      cueRangesMap: new Map(${rangeMapEntries}),
      cueWrappers: new Map([['K', [document.getElementById('w')]]]),
    };
  `;
  return runInDom(
    `<span id="w" class="fushi-sentence-audio-cue">句</span>`,
    anchorElSrc + setup,
    `var a = window.__fushiSentenceAudioAnchorEl('K');
     document.body.setAttribute('data-result', a ? (a.id || a.nodeName) : 'null');`,
  );
}

test("锚点解析：cssHighlights 开 + cueRangesMap 空 → 兜底 cueWrappers（不是 null）", () => {
  // 生产真实条件。修复前此处返回 'null'（图片暂停+揭遮罩全废）。
  assert.equal(resolveAnchorId("true", ""), "w");
});

test("锚点解析：cssHighlights 关也兜底 cueWrappers", () => {
  assert.equal(resolveAnchorId("false", ""), "w");
});

test("锚点解析：cueRangesMap 命中时优先用 range 的 startContainer（不破坏原路径）", () => {
  // range startContainer 指向 #w 元素本身（nodeType===1 直接返回）。
  assert.equal(
    resolveAnchorId("true", "[['K', [{ startContainer: document.getElementById('w') }]]]"),
    "w",
  );
});
