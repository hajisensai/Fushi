// 浏览器扩展「调整上下文」模态（多句合一制卡）在真 DOM（jsdom）里的行为契约。
//
// app 内这个模态是 Flutter 原生顶层对话框（SentenceContextDialog）；扩展没有原生宿主，
// content.js 把它画在宿主页顶层的独立 shadow host 里（不在查词弹窗容器内——BUG-763/766
// 「画在弹窗内被尺寸/半透明约束」的教训）。这里断言：
//   · 打开即渲染前文/当前句（所查词 <mark> 高亮）/后文 + 计数；
//   · ± 按钮整体替换宿主草稿并重绘（轨首/轨尾封顶后对应「+」禁用）；
//   · 「确认制卡」关窗并回点该词条的制卡按钮（fushiPopupMineEntryByIndex(entryIndex)），
//     草稿保留给制卡消费；
//   · 「取消」/ 背景点击 / Esc 关窗并把草稿还原到开窗时的快照。
import { test } from "node:test";
import assert from "node:assert";
import { JSDOM } from "jsdom";
import { readFileSync } from "node:fs";

const EXT = new URL("../../tools/browser-extension/", import.meta.url);
const src = (name) => readFileSync(new URL(name, EXT), "utf8");

const TRACK = [
  { startMs: 1000, endMs: 2000, text: "第一句" },
  { startMs: 2500, endMs: 3500, text: "第二句" },
  { startMs: 4000, endMs: 5000, text: "第三句 当前" },
  { startMs: 5500, endMs: 6500, text: "第四句" },
];

function createWorld() {
  const dom = new JSDOM(`<!DOCTYPE html><body><video></video></body>`, {
    url: "https://www.netflix.com/watch/81001",
    runScripts: "outside-only",
    pretendToBeVisual: true,
  });
  const win = dom.window;
  // content.js 加载时会挂轮询定时器（字幕采样/收割）——留着会让 node 进程不退出；
  // 模态行为不依赖它们，直接抹掉。chrome API 给最小 stub。
  win.setInterval = () => 0;
  win.clearInterval = () => {};
  win.chrome = {
    runtime: { id: "test", lastError: null, onMessage: { addListener() {} }, sendMessage() {} },
    storage: { local: { get() {}, set() {} }, onChanged: { addListener() {} } },
  };
  Object.defineProperty(win.HTMLMediaElement.prototype, "currentTime", {
    configurable: true,
    get() { return this.__t || 0; },
    set(v) { this.__t = v; },
  });
  win.document.querySelector("video").currentTime = 4.2;
  win.fushiActiveFullTrack = () => ({ lang: "ja", cues: TRACK });
  for (const f of ["subtitle-adapters.js", "vendor/dict-media.js", "popup-size.js",
    "subtitle-providers.js", "content.js"]) {
    win.eval(src(f));
  }
  return win;
}

function modal(win) {
  const host = win.document.getElementById("fushi-ctx-modal-host");
  if (!host) return null;
  const root = host.shadowRoot;
  const buttons = [...root.querySelectorAll("button")];
  return {
    host,
    root,
    boxes: () => [...root.querySelectorAll(".box")].map((b) => b.textContent),
    current: () => root.querySelector(".box.cur"),
    count: () => root.querySelector(".count").textContent,
    button: (label) => {
      const b = [...root.querySelectorAll("button")].find((x) => x.textContent === label);
      assert.ok(b, "缺按钮 " + label);
      return b;
    },
    buttons,
  };
}

test("打开：前文/当前句(高亮所查词)/后文 + 计数；确认制卡回点该词条并保留草稿", () => {
  const win = createWorld();
  const mined = [];
  win.fushiPopupMineEntryByIndex = (idx) => { mined.push(idx); return true; };
  win.fushiOpenSentenceContextModal({ entryIndex: 2, matched: "当前" });
  let m = modal(win);
  assert.ok(m, "模态必须挂在宿主页顶层（独立 shadow host）");
  assert.deepStrictEqual(m.boxes(), ["（无）", "第三句 当前", "（无）"]);
  assert.strictEqual(m.current().querySelector("mark").textContent, "当前", "所查词高亮");
  assert.strictEqual(m.count(), "已选择 0 句");

  m.button("前加一句").click();
  m = modal(win);
  assert.deepStrictEqual(m.boxes(), ["第二句", "第三句 当前", "（无）"]);
  assert.strictEqual(m.count(), "已选择 1 句");
  m.button("后加一句").click();
  m.button("后加一句").click(); // 轨尾只剩一句：封顶
  m = modal(win);
  assert.deepStrictEqual(m.boxes(), ["第二句", "第三句 当前", "第四句"]);
  assert.strictEqual(m.button("后加一句").disabled, true, "到轨尾「+」禁用（诚实反馈）");
  assert.strictEqual(m.button("前加一句").disabled, false);

  m.button("确认制卡").click();
  assert.strictEqual(win.document.getElementById("fushi-ctx-modal-host"), null, "确认后关窗");
  assert.deepStrictEqual(mined, [2], "回点第 entryIndex 个词条的制卡按钮");
  const p = win.fushiSentenceContextPreview({});
  assert.strictEqual(p.total, 2, "草稿保留给随后的制卡消费（制卡成功才归零）");
  assert.strictEqual(win.fushiMineContext().contextSentence, "第二句\n第三句 当前\n第四句");
});

test("取消 / 背景点击 / Esc：关窗并还原到开窗时的草稿快照", () => {
  const win = createWorld();
  win.fushiSetSentenceContext(1, 0);
  win.fushiOpenSentenceContextModal({ entryIndex: 0, matched: "" });
  let m = modal(win);
  m.button("前退一句").click();
  m.button("后加一句").click();
  assert.strictEqual(win.fushiSentenceContextPreview({}).total, 1);
  m = modal(win);
  m.button("取消").click();
  assert.strictEqual(win.document.getElementById("fushi-ctx-modal-host"), null);
  let p = win.fushiSentenceContextPreview({});
  assert.deepStrictEqual([p.prev.length, p.next.length], [1, 0], "取消还原快照 1/0");

  win.fushiOpenSentenceContextModal({ entryIndex: 0, matched: "" });
  m = modal(win);
  m.button("后加一句").click();
  m = modal(win);
  m.root.querySelector(".bg").dispatchEvent(new win.MouseEvent("click", { bubbles: true }));
  assert.strictEqual(win.document.getElementById("fushi-ctx-modal-host"), null, "背景点击关窗");
  p = win.fushiSentenceContextPreview({});
  assert.deepStrictEqual([p.prev.length, p.next.length], [1, 0]);

  win.fushiOpenSentenceContextModal({ entryIndex: 0, matched: "" });
  m = modal(win);
  m.button("前退一句").click();
  m = modal(win);
  m.host.dispatchEvent(new win.KeyboardEvent("keydown", { key: "Escape", bubbles: true }));
  assert.strictEqual(win.document.getElementById("fushi-ctx-modal-host"), null, "Esc 关窗");
  p = win.fushiSentenceContextPreview({});
  assert.deepStrictEqual([p.prev.length, p.next.length], [1, 0]);
});

test("模态开着时按键不漏给宿主页（网飞空格=播放/暂停）", () => {
  const win = createWorld();
  let leaked = 0;
  win.document.addEventListener("keydown", () => { leaked++; });
  win.fushiOpenSentenceContextModal({ entryIndex: 0, matched: "" });
  const m = modal(win);
  m.root.querySelector("button").dispatchEvent(
    new win.KeyboardEvent("keydown", { key: " ", bubbles: true, composed: true }));
  assert.strictEqual(leaked, 0, "空格在模态里按下不得冒泡到 document");
  assert.ok(win.document.getElementById("fushi-ctx-modal-host"), "非 Esc 键不关窗");
});

test("重复打开：只保留一个模态实例", () => {
  const win = createWorld();
  win.fushiOpenSentenceContextModal({ entryIndex: 0, matched: "" });
  win.fushiOpenSentenceContextModal({ entryIndex: 0, matched: "" });
  assert.strictEqual(win.document.querySelectorAll("#fushi-ctx-modal-host").length, 1);
});
