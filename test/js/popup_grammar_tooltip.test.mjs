// 词形变化标签的语法说明浮层（jsdom 真 DOM）。
//
// 弹窗把每一层词形变化渲染成一枚 .deinflection-tag，说明文本来自
// assets/transforms/<lang>.json（经 deinflectionTrace 送达）。桌面上悬停出浮层，
// 触屏上点开 .overlay —— Dart 侧的源码守卫只能看文本，管不到这里的运行时语义：
// 视口收敛算不算对、触屏会不会把浮层粘死在屏幕上，只有真 DOM 能问出来。
import { test } from "node:test";
import assert from "node:assert/strict";
import { JSDOM } from "jsdom";
import { readFileSync } from "node:fs";

const POPUP_URL = new URL("../../fushi/assets/popup/popup.js", import.meta.url);
const popupSrc = readFileSync(POPUP_URL, "utf8");

const VIEWPORT_W = 800;
const VIEWPORT_H = 600;
const TOOLTIP_W = 300;
const TOOLTIP_H = 120;

/// 起一个装好 popup.js 的窗口。
///
/// anchorRect 是被悬停的那枚标签的位置；浮层自身的尺寸固定成
/// TOOLTIP_W×TOOLTIP_H，这样「往左收」「翻到上方」这两条分支才有确定的期望值。
function createPopup(anchorRect) {
  const dom = new JSDOM(
    `<!DOCTYPE html><body>
      <div class="overlay" style="display:none"><div class="overlay-content"></div></div>
      <div id="entries-container"></div>
    </body>`,
    { runScripts: "outside-only", pretendToBeVisual: true },
  );
  const win = dom.window;

  win.flutter_inappwebview = { callHandler: () => {} };
  win.innerWidth = VIEWPORT_W;
  win.innerHeight = VIEWPORT_H;
  // jsdom 的 matchMedia 恒 matches:false，会把每个设备都判成触屏。默认按「能悬停
  // 的桌面」处理，触屏分支由用例自己改回来。
  win.matchMedia = (query) => ({
    media: query,
    matches: query.includes("hover: hover"),
    addListener() {},
    removeListener() {},
  });

  // jsdom 不排版，getBoundingClientRect 恒为 0。按 class 分派出确定的几何：
  // 浮层报固定尺寸，标签报调用方给的锚点位置。
  win.HTMLElement.prototype.getBoundingClientRect = function () {
    if (this.classList.contains("grammar-tooltip")) {
      return {
        x: 0,
        y: 0,
        left: 0,
        top: 0,
        right: TOOLTIP_W,
        bottom: TOOLTIP_H,
        width: TOOLTIP_W,
        height: TOOLTIP_H,
      };
    }
    return anchorRect;
  };

  win.eval(popupSrc);
  return win;
}

function rect(left, top, width = 40, height = 16) {
  return {
    x: left,
    y: top,
    left,
    top,
    width,
    height,
    right: left + width,
    bottom: top + height,
  };
}

test("有语法说明的标签才可点/可悬停", () => {
  const win = createPopup(rect(10, 10));

  const withDescription = win.createDeinflectionTag({
    name: "-て",
    description: "て-form.",
  });
  assert.ok(withDescription.classList.contains("has-description"));
  assert.equal(withDescription.getAttribute("data-description"), "て-form.");
  assert.equal(typeof withDescription.onclick, "function");
  assert.equal(typeof withDescription.onmouseenter, "function");

  // 文本变体归一的回落标签没有说明：不加 has-description（CSS 据此不给指针
  // 手型），也不挂任何处理器，免得点开一个空框。
  const withoutDescription = win.createDeinflectionTag({
    name: "colour → color",
    description: "",
  });
  assert.equal(withoutDescription.classList.contains("has-description"), false);
  assert.equal(withoutDescription.getAttribute("data-description"), null);
  assert.equal(withoutDescription.onclick, null);
  assert.equal(withoutDescription.onmouseenter, null);
});

test("悬停显示浮层并填入说明，移开后隐藏", () => {
  const win = createPopup(rect(10, 10));
  const tag = win.createDeinflectionTag({
    name: "-て",
    description: "て-form.\nUsage: attach て…",
  });
  win.document.body.appendChild(tag);

  assert.equal(win.document.querySelector(".grammar-tooltip"), null);

  tag.onmouseenter.call(tag);
  const tooltip = win.document.querySelector(".grammar-tooltip");
  assert.ok(tooltip, "浮层应在首次悬停时懒创建");
  assert.equal(tooltip.textContent, "て-form.\nUsage: attach て…");
  assert.equal(tooltip.style.display, "block");

  tag.onmouseleave.call(tag);
  assert.equal(tooltip.style.display, "none");
});

test("浮层懒创建只建一个，重复悬停复用同一节点", () => {
  const win = createPopup(rect(10, 10));
  const first = win.createDeinflectionTag({ name: "-て", description: "A" });
  const second = win.createDeinflectionTag({ name: "-た", description: "B" });
  win.document.body.append(first, second);

  first.onmouseenter.call(first);
  second.onmouseenter.call(second);

  assert.equal(win.document.querySelectorAll(".grammar-tooltip").length, 1);
  assert.equal(win.document.querySelector(".grammar-tooltip").textContent, "B");
});

test("靠右的标签：浮层往左收，不越出视口右缘", () => {
  // 锚点左缘 700 + 浮层宽 300 = 1000 > 视口 800，必须收到 800-300-8 = 492。
  const win = createPopup(rect(700, 100));
  const tag = win.createDeinflectionTag({ name: "-て", description: "A" });
  win.document.body.appendChild(tag);

  tag.onmouseenter.call(tag);
  const tooltip = win.document.querySelector(".grammar-tooltip");

  assert.equal(tooltip.style.left, "492px");
  // 下方放得下（100+16+6+120 = 242 < 600-8），维持在标签下方。
  assert.equal(tooltip.style.top, "122px");
});

test("贴近底部的标签：浮层翻到上方", () => {
  // 锚点 top 520 / bottom 536：下方 536+6+120 = 662 > 600-8，翻到上方
  // 520-120-6 = 394。
  const win = createPopup(rect(100, 520));
  const tag = win.createDeinflectionTag({ name: "-て", description: "A" });
  win.document.body.appendChild(tag);

  tag.onmouseenter.call(tag);
  const tooltip = win.document.querySelector(".grammar-tooltip");

  assert.equal(tooltip.style.top, "394px");
});

test("上下都放不下时维持在下方，不顶出视口外", () => {
  // 一枚比视口还高的锚点：上方 -6-120 < 8 放不下，只能维持在下方并截断。
  const win = createPopup(rect(100, 0, 40, VIEWPORT_H));
  const tag = win.createDeinflectionTag({ name: "-て", description: "A" });
  win.document.body.appendChild(tag);

  tag.onmouseenter.call(tag);
  const tooltip = win.document.querySelector(".grammar-tooltip");

  assert.equal(tooltip.style.top, `${VIEWPORT_H + 6}px`);
});

test("触屏（不能悬停）不显示浮层——否则没有 mouseleave 来收它", () => {
  const win = createPopup(rect(10, 10));
  win.matchMedia = (query) => ({
    media: query,
    matches: false, // (hover: hover) 不成立 = 触屏
    addListener() {},
    removeListener() {},
  });

  const tag = win.createDeinflectionTag({ name: "-て", description: "A" });
  win.document.body.appendChild(tag);

  tag.onmouseenter.call(tag);

  assert.equal(
    win.document.querySelector(".grammar-tooltip"),
    null,
    "触屏 tap 会补发 mouseenter，浮层一旦显示就再没有 mouseleave 收它",
  );
});

test("点击走全屏 overlay（触屏上唯一的查看路径）", () => {
  const win = createPopup(rect(10, 10));
  const tag = win.createDeinflectionTag({
    name: "-て",
    description: "て-form.",
  });
  win.document.body.appendChild(tag);

  tag.onclick.call(tag);

  const overlay = win.document.querySelector(".overlay");
  assert.equal(overlay.style.display, "block");
  assert.equal(
    win.document.querySelector(".overlay-content").textContent,
    "て-form.",
  );
});
