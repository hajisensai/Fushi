// BUG-767 行为测试（jsdom 真实 DOM）：MDX 词典条目里的交叉引用（類義語 等）点击后
// 面板空白。
//
// 根因：MDX 原始 HTML 的 `<a href="entry://词（読み）">词</a>` 经 innerHTML 注入到
// .glossary-content，既没挂结构化内容那套 onclick，结果 WebView 也没有导航拦截。裸点击 →
// 浏览器对结果框架发起默认导航到无法解析的 entry:// URL → 已渲染词条 DOM 全被销毁 → 白屏。
// 修复：popup.js 的文档点击委托把 glossary 内的锚点统一交给具名函数
// handleGlossaryAnchorClick——preventDefault 阻止默认导航（根因），内部交叉引用用可见词头
// textContent 作查询词转成 onLinkClick 重查。
//
// 为什么用行为测试而非源码扫描：核心不变式是「点击既阻止了默认导航、又用干净词头触发重查」，
// 只有真在 DOM 上执行 handleGlossaryAnchorClick 才能同时验到 preventDefault 与 onLinkClick 的
// 参数。锚文本取自本 bug 的真实样本（大修館 四字熟語辞典 T4jiJuk.mdx）：
//   <a href="entry://一栄一辱（いちえい-いちじょく）">一栄一辱</a><span>…furigana…</span>
// href 带读音噪声、振假名是锚外兄弟 span，故查询词必须来自 textContent（干净词头）而非 href。
import { test } from "node:test";
import assert from "node:assert/strict";
import { JSDOM } from "jsdom";
import { readFileSync } from "node:fs";

// test/js/ → 仓库根 → hibiki/assets/popup/popup.js（当前分支真值）。
const POPUP_URL = new URL(
  "../../hibiki/assets/popup/popup.js",
  import.meta.url,
);
const src = readFileSync(POPUP_URL, "utf8");

// 提取 `function handleGlossaryAnchorClick(...) { ... }` 整段。函数体内的闭合大括号都带缩进
// （`    }` / `    });`），唯一顶格的 `\n}` 是函数收尾，非贪婪匹配到它即止。
function extract(name) {
  const re = new RegExp(
    "function " + name + "\\s*\\([^)]*\\)\\s*\\{[\\s\\S]*?\\n\\}",
  );
  const m = src.match(re);
  assert.ok(m, `未能从 popup.js 提取 ${name}`);
  return m[0];
}

const handlerSrc = extract("handleGlossaryAnchorClick");

/**
 * 在 jsdom 页面里注入真实 handleGlossaryAnchorClick + 桩，点击首个 <a>，回收结果。
 * 返回 { prevented, linkCalls, externalCalls, extHitCalls }。
 */
function clickAnchor(anchorHtml) {
  const dom = new JSDOM(
    `<!DOCTYPE html><body><div class="glossary-content">${anchorHtml}</div></body>`,
    { runScripts: "outside-only" },
  );
  const win = dom.window;
  const results = {
    prevented: false,
    linkCalls: [],
    externalCalls: [],
    extHitCalls: 0,
  };
  // 桩：记录被调情况。
  win.openExternalLink = (url) => results.externalCalls.push(url);
  win.markGlobalLookupExtHit = () => {
    results.extHitCalls++;
  };
  win.flutter_inappwebview = {
    callHandler: (name, ...args) => {
      if (name === "onLinkClick") results.linkCalls.push(args);
    },
  };
  // 把真实函数装进这个 window 作用域（它引用 openExternalLink / markGlobalLookupExtHit /
  // window.flutter_inappwebview 这些全局）。
  win.eval(`${handlerSrc}\nwindow.__handleGlossaryAnchorClick = handleGlossaryAnchorClick;`);

  const anchor = win.document.querySelector("a[href]");
  assert.ok(anchor, "测试 fixture 缺少 <a href>");
  const fakeEvent = {
    preventDefault: () => {
      results.prevented = true;
    },
  };
  win.__handleGlossaryAnchorClick(fakeEvent, anchor);
  return results;
}

test("BUG-767 类义语交叉引用：阻止默认导航 + 用干净词头触发 onLinkClick 重查", () => {
  // 真实样本：href 带读音、振假名在锚外兄弟 span。
  const r = clickAnchor(
    `<a href="entry://一栄一辱（いちえい-いちじょく）">一栄一辱</a>` +
      `<span style="font-size:50%;">いちえい<br/>いちじょく</span>`,
  );
  // 根因守卫：必须 preventDefault，否则结果框架被导走→白屏。
  assert.equal(r.prevented, true, "未 preventDefault——默认导航会把结果框架导走导致白屏");
  // 重查守卫：用干净词头（textContent），不是 href 里带读音的 entry:// 目标。
  assert.equal(r.linkCalls.length, 1, "应触发且仅触发一次 onLinkClick 重查");
  assert.equal(r.linkCalls[0][0], "一栄一辱", "查询词应为干净词头 textContent");
  assert.equal(r.externalCalls.length, 0, "内部引用不应当作外链打开");
});

test("BUG-767 外链：交给 openExternalLink，不误当查词", () => {
  const r = clickAnchor(`<a href="https://example.com/x">出典</a>`);
  assert.equal(r.prevented, true);
  assert.equal(r.externalCalls.length, 1);
  assert.equal(r.externalCalls[0], "https://example.com/x");
  assert.equal(r.linkCalls.length, 0, "外链不应触发 onLinkClick");
});

test("BUG-767 发音媒体节点 sound://：阻止导航但不查词", () => {
  const r = clickAnchor(`<a href="sound://word.spx">🔊</a>`);
  assert.equal(r.prevented, true, "sound:// 也必须阻止默认导航");
  assert.equal(r.linkCalls.length, 0, "发音节点不是查词目标");
  assert.equal(r.externalCalls.length, 0);
});

test("BUG-767 空词头（href='#'）：阻止导航，不发空查询", () => {
  const r = clickAnchor(`<a href="#"> </a>`);
  assert.equal(r.prevented, true);
  assert.equal(r.linkCalls.length, 0, "空词头不应触发 onLinkClick");
});
