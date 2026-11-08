// BUG-4232 行为测试（jsdom 真实 DOM 事件传播）：LDOCE5++ V 2-15.mdx 的内置发音点了不响。
//
// 根因：带脚本的词典释义跑在沙箱 iframe 里，沙箱辅助脚本 DICT_SANDBOX_HELPER_JS 只在
// document 冒泡阶段监听点击、且 defaultPrevented 就放弃。LM5Switch.js 在桌面 Chrome UA
// （Windows WebView2 正是）下进入「在线发音」：在 .ldoceEntry 上委托接管
// `a.speaker[href$="mp3"][href*="media"]`，去请求 ldoceonline.com（沙箱 CSP 本就禁网络），
// 然后 jQuery `return false`（= preventDefault + stopPropagation）——sound:// 永远到不了父页面。
// 修复：sound: 链接改在 window 捕获阶段接住（早于词典脚本任何监听），只阻止默认导航不拦传播。
//
// 词条 HTML 取自真实样本（LDOCE5++ V 2-15.mdx 词条「000」）：
//   <a class="speaker brefile fa fa-volume-up" data-src-mp3="/media/english/breProns/ld5_000.mp3"
//      href="sound://media/english/breProns/ld5_000.mp3" ...>
// 词典脚本按 LM5Switch.js onlinePronSetup 的事件语义复刻（委托在 .ldoceEntry、命中即 return false）。
import { test } from "node:test";
import assert from "node:assert/strict";
import { JSDOM } from "jsdom";
import { readFileSync } from "node:fs";

const src = readFileSync(
  new URL("../../fushi/assets/popup/popup.js", import.meta.url),
  "utf8",
);
const literal = src.match(/const DICT_SANDBOX_HELPER_JS = `([\s\S]*?)`;/);
assert.ok(literal, "未能从 popup.js 提取 DICT_SANDBOX_HELPER_JS");
// 按模板字面量求值，得到真正注入 iframe 的脚本文本（\\s → \s 等转义与运行时一致）。
const helperJs = new Function("return `" + literal[1] + "`;")();

const SPEAKER_HREF = "sound://media/english/breProns/ld5_000.mp3";
const ENTRY_HTML =
  '<div class="ldoceEntry"><span class="HWD">000</span>' +
  '<a class="speaker brefile fa fa-volume-up" data-src-mp3="/media/english/breProns/ld5_000.mp3" ' +
  `href="${SPEAKER_HREF}" title="Play British pronunciation of 000"></a>` +
  '<a class="xref" href="entry://zero">zero</a></div>';

/** @returns {{window: any, posted: any[]}} */
function sandbox({ lm5OnlinePron, swallowEntryLinks = false }) {
  const dom = new JSDOM(`<!doctype html><html><body>${ENTRY_HTML}</body></html>`, {
    runScripts: "outside-only",
  });
  const { window } = dom;
  const posted = [];
  // 顶层 jsdom 窗口的 parent 就是自己；截住辅助脚本发往父页面的消息。
  window.postMessage = (message) => posted.push(JSON.parse(JSON.stringify(message)));
  window.ResizeObserver = class { observe() {} };
  // 辅助脚本排在词典脚本之前（与 __dictSandboxDocument 拼文档的顺序一致）。
  window.eval(helperJs);
  if (lm5OnlinePron) {
    window.eval(`
      document.querySelector('.ldoceEntry').addEventListener('click', function (event) {
        var speaker = event.target.closest('a.speaker[href$="mp3"][href*="media"]:not(.loading)');
        if (!speaker) return;
        speaker.classList.add('loading');
        event.preventDefault();      // jQuery 的 return false
        event.stopPropagation();
      });`);
  }
  if (swallowEntryLinks) {
    window.eval(`
      document.querySelector('.ldoceEntry').addEventListener('click', function (event) {
        if (event.target.closest('a.xref')) { event.preventDefault(); event.stopPropagation(); }
      });`);
  }
  return { window, posted };
}

/** @returns {boolean} dispatchEvent 的返回值（false = 默认动作已被阻止） */
function click(window, selector) {
  const event = new window.MouseEvent("click", { bubbles: true, cancelable: true });
  return window.document.querySelector(selector).dispatchEvent(event);
}

const links = (posted) => posted.filter((m) => m.type === "link");

test("LM5Switch 在线发音接管 speaker 并 return false 时，sound:// 仍恰好上报一次", () => {
  const { window, posted } = sandbox({ lm5OnlinePron: true });
  const notPrevented = click(window, "a.speaker");
  assert.equal(notPrevented, false, "sound:// 不能触发默认导航");
  const sent = links(posted);
  assert.equal(sent.length, 1, `应上报一次 sound 链接，实得 ${JSON.stringify(posted)}`);
  assert.equal(sent[0].href, SPEAKER_HREF);
  assert.equal(sent[0].__fushiDictSandbox, 1);
  assert.ok(
    window.document.querySelector("a.speaker").classList.contains("loading"),
    "只阻止默认导航、不拦传播：词典自己的点击逻辑照常执行",
  );
  window.close();
});

test("没有词典脚本接管时，sound:// 也只上报一次（捕获与冒泡不重复）", () => {
  const { window, posted } = sandbox({ lm5OnlinePron: false });
  click(window, "a.speaker");
  const sent = links(posted);
  assert.equal(sent.length, 1);
  assert.equal(sent[0].href, SPEAKER_HREF);
  window.close();
});

test("非 sound 链接：词典脚本 preventDefault 后照旧不上报（交给词典自己处理）", () => {
  const { window, posted } = sandbox({ lm5OnlinePron: false, swallowEntryLinks: true });
  click(window, "a.xref");
  assert.equal(links(posted).length, 0);
  window.close();
});

test("非 sound 链接：无人接管时照旧上报一次查词", () => {
  const { window, posted } = sandbox({ lm5OnlinePron: false });
  click(window, "a.xref");
  const sent = links(posted);
  assert.equal(sent.length, 1);
  assert.equal(sent[0].href, "entry://zero");
  assert.equal(sent[0].text, "zero");
  window.close();
});
