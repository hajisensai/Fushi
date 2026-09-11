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

// test/js/ → 仓库根 → fushi/assets/popup/popup.js（当前分支真值）。
const POPUP_URL = new URL(
  "../../fushi/assets/popup/popup.js",
  import.meta.url,
);
const src = readFileSync(POPUP_URL, "utf8");
// BUG-1261：sound:// 播放走真实 rewriteDictionaryMediaPath（dict-media.js，app 变体），
// 整段注入以验到最终 image:// URL 的构造，而不是桩出一个假 URL。
const DICT_MEDIA_URL = new URL(
  "../../fushi/assets/popup/dict-media.js",
  import.meta.url,
);
const dictMediaSrc = readFileSync(DICT_MEDIA_URL, "utf8");

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
// BUG-2447：查询词改经 linkVisibleBaseText 取基字（剥 rt/rp/.ruby-rt/.ruby-reserve），
// 与 handler 一起注入——它是 handler 的真实依赖，不桩。
const baseTextSrc = extract("linkVisibleBaseText");

/**
 * 在 jsdom 页面里注入真实 handleGlossaryAnchorClick + 真实 dict-media.js + 桩，
 * 点击首个 <a>，回收结果。
 * 返回 { prevented, linkCalls, externalCalls, playCalls }。
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
    playCalls: [],
  };
  // 桩：记录被调情况。
  win.openExternalLink = (url) => results.externalCalls.push(url);
  win.playWordAudio = (url) => {
    results.playCalls.push(url);
    return Promise.resolve(true);
  };
  win.flutter_inappwebview = {
    callHandler: (name, ...args) => {
      if (name === "onLinkClick") results.linkCalls.push(args);
    },
  };
  // 把真实函数装进这个 window 作用域（它引用 openExternalLink /
  // rewriteDictionaryMediaPath / playWordAudio / window.flutter_inappwebview 这些全局）。
  win.eval(`${dictMediaSrc}\n${baseTextSrc}\n${handlerSrc}\nwindow.__handleGlossaryAnchorClick = handleGlossaryAnchorClick;`);

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

test("BUG-2447 带振假名的交叉引用：查询词只取基字，不混入 rt 读音", () => {
  // 真实形态（明鏡国語辞典 第三版 逆引き 列出的惯用句）：锚内每个汉字都带 <ruby>/<rt>。
  // 裸 textContent = 「足あしが棒ぼうになる」→ Dart 前缀扫描只能命中首字「足」→ 汉字卡，
  // 用户症状「惯用句开头是汉字就进不去、被重定向到那个汉字」。
  const r = clickAnchor(
    `<a href="entry://足が棒になる（あしがぼうになる）">` +
      `<ruby>足<rt>あし</rt></ruby>が<ruby>棒<rt>ぼう</rt></ruby>になる</a>`,
  );
  assert.equal(r.prevented, true);
  assert.equal(r.linkCalls.length, 1);
  assert.equal(r.linkCalls[0][0], "足が棒になる", "查询词必须剥掉 <rt> 振假名");
});

test("BUG-2447 postProcessRuby 之后的 DOM：.ruby-reserve 孪生体与 .ruby-rt 一并剥掉", () => {
  // 点击发生在 postProcessRuby 已跑过的 DOM 上：每个基字被包成 .ruby-unit，rt 挪进
  // .ruby-rt，另克隆一份读音 .ruby-reserve 插在基字**前面**。裸 textContent 此时是
  // 「あし足あしが…」——连首字都不是汉字了，前缀扫描落到「あし」。
  const r = clickAnchor(
    `<a href="entry://足が棒になる">` +
      `<ruby><span class="ruby-unit"><span class="ruby-reserve" aria-hidden="true">あし</span>足` +
      `<span class="ruby-rt"><rt>あし</rt></span></span></ruby>が` +
      `<ruby><span class="ruby-unit"><span class="ruby-reserve" aria-hidden="true">ぼう</span>棒` +
      `<span class="ruby-rt"><rt>ぼう</rt></span></span></ruby>になる</a>`,
  );
  assert.equal(r.linkCalls.length, 1);
  assert.equal(r.linkCalls[0][0], "足が棒になる", "reserve 孪生体与 .ruby-rt 都不是查询词的一部分");
});

test("BUG-2447 <rp> 括号回退与内部空白：不进查询词，词间空格折叠为单个", () => {
  const r = clickAnchor(
    `<a href="entry://x"><ruby>漢<rp>(</rp><rt>かん</rt><rp>)</rp></ruby>字\n  <span>  熟語 </span></a>`,
  );
  assert.equal(r.linkCalls.length, 1);
  assert.equal(r.linkCalls[0][0], "漢字 熟語");
});

test("BUG-767 外链：交给 openExternalLink，不误当查词", () => {
  const r = clickAnchor(`<a href="https://example.com/x">出典</a>`);
  assert.equal(r.prevented, true);
  assert.equal(r.externalCalls.length, 1);
  assert.equal(r.externalCalls[0], "https://example.com/x");
  assert.equal(r.linkCalls.length, 0, "外链不应触发 onLinkClick");
});

test("BUG-1261 发音媒体节点 sound://：阻止导航、不查词，经词典媒体通道播放", () => {
  // 真实形态（OALD）：发音锚点在 data-dictionary 词典容器内（popup.js 渲染 MDX
  // 释义时必设，见 dictWrapper.setAttribute('data-dictionary', ...)）。
  const r = clickAnchor(
    `<div data-dictionary="OALD"><a href="sound://uk/apple.mp3">🔊</a></div>`,
  );
  assert.equal(r.prevented, true, "sound:// 也必须阻止默认导航");
  assert.equal(r.linkCalls.length, 0, "发音节点不是查词目标");
  assert.equal(r.externalCalls.length, 0);
  // 播放守卫：剥掉 sound:// 前缀 → rewriteDictionaryMediaPath → app 内 image://
  // 词典媒体 scheme（与 <img>/gaiji 同一字节通道，四个宿主表面均已注册）。
  assert.equal(r.playCalls.length, 1, "sound:// 点击必须触发一次播放");
  assert.equal(
    r.playCalls[0],
    "image://?dictionary=OALD&path=uk%2Fapple.mp3",
    "播放 URL 应是 image:// 词典媒体 scheme + 编码后的资源路径",
  );
});

test("BUG-1261 sound:// 缺 data-dictionary 容器：只阻止导航，不播放不崩", () => {
  const r = clickAnchor(`<a href="sound://word.mp3">🔊</a>`);
  assert.equal(r.prevented, true);
  assert.equal(r.playCalls.length, 0, "无词典归属时不该盲播");
  assert.equal(r.linkCalls.length, 0);
  assert.equal(r.externalCalls.length, 0);
});

test("BUG-767 空词头（href='#'）：阻止导航，不发空查询", () => {
  const r = clickAnchor(`<a href="#"> </a>`);
  assert.equal(r.prevented, true);
  assert.equal(r.linkCalls.length, 0, "空词头不应触发 onLinkClick");
});
