// 有声书图片暂停 / 去遮罩「锚点间插图检测」行为测试（jsdom 真实 DOM）。
//
// 为什么需要行为测试：hibiki/test/media/audiobook/image_pause_detection_test.dart
// 是纯源码字符串扫描（断言 bridge 里出现 compareDocumentPosition / querySelectorAll
// 等字符串），只能防「检测机制被整体替换/删除」，无法执行判据、测不出 BUG-724 这类
// compareDocumentPosition 位语义逻辑 bug（当前句 cue 锚点是包含插图的容器时，关系是
// CONTAINED_BY 而非 PRECEDING，旧判据漏检 → 既不暂停也不去遮罩）。此测试从真实 bridge
// 提取 __hoshiImageBetween / __hoshiRevealBlurredBetween，在真实 DOM 上执行判据。
import { test } from "node:test";
import assert from "node:assert/strict";
import { JSDOM } from "jsdom";
import { readFileSync } from "node:fs";

// 相对本测试文件读当前分支的真实 bridge（test/js/ → 仓库根 → hibiki/...）。
const BRIDGE_URL = new URL(
  "../../hibiki/lib/src/media/audiobook/audiobook_bridge.dart",
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

const imageBetweenSrc = extract("__hoshiImageBetween");
const revealBlurredSrc = extract("__hoshiRevealBlurredBetween");

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

/** 检测（暂停）：__hoshiImageBetween 是否命中页面里唯一的 img */
function detects(bodyHtml) {
  const out = runInDom(bodyHtml, imageBetweenSrc, `
    var prev = document.getElementById('cueA');
    var el = document.getElementById('cueB');
    var hit = window.__hoshiImageBetween(prev, el);
    var target = document.querySelector('img');
    document.body.setAttribute('data-result', String(hit === target && target !== null));
  `);
  return out === "true";
}

/** 去遮罩：__hoshiRevealBlurredBetween 是否把 img.blurred 的 blurred 类去掉 */
function reveals(bodyHtml) {
  // __hoshiRevealBlurredBetween 早返回若 __hoshiImageRevealKey 不是函数（bridge:85），
  // 并用 key 决定是否揭开；这里提供返回稳定 key 的 stub + no-op 标记函数。
  const stubs = `
    window.__hoshiImageRevealKey = function(m){ return (m && m.getAttribute && m.getAttribute('src')) || 'key'; };
    window.__hoshiMarkImageRevealed = function(){};
  `;
  const out = runInDom(bodyHtml, stubs + revealBlurredSrc, `
    var prev = document.getElementById('cueA');
    var el = document.getElementById('cueB');
    window.__hoshiRevealBlurredBetween(prev, el);
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
